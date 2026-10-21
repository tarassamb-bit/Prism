import Foundation

/// The optional Prism account (Supabase email + password). When signed in, each finished export adds one row of stats
/// (date, Shorts, seconds, quality) that the website shows. No video, transcript or file name ever leaves the Mac.
@MainActor @Observable
final class Account {
    /// The project's public (publishable) key: safe to ship, because Row Level Security limits every user to their own rows.
    static let projectURL = URL(string: "https://isdplhahgggundbohmlr.supabase.co")!
    static let publishableKey = "sb_publishable_ATTcp2-mrca0swMStHHdYQ_Le851b8l"
    static let statsPage = URL(string: "https://tarassamb-bit.github.io/prism-website/#account")!
    private static let keychainService = "Relio.Account"

    private(set) var email: String?
    var status = ""
    private(set) var isWorking = false
    var isSignedIn: Bool { email != nil }

    init() {
        if let saved = Self.savedSession() { email = saved.email }
    }

    func signIn(email: String, password: String) async {
        await authenticate(path: "auth/v1/token?grant_type=password", email: email, password: password)
    }

    func signUp(email: String, password: String) async {
        await authenticate(path: "auth/v1/signup", email: email, password: password)
    }

    func signOut() {
        try? GeminiKeyStore.save("", service: Self.keychainService)
        email = nil
        status = "Signed out. Exports are no longer counted."
    }

    /// Adds one export to the account's stats. Failures never affect the export; they only show in Settings.
    func recordExport(shortCount: Int, seconds: Double, quality: String) async {
        guard isSignedIn, shortCount > 0, let token = await accessToken() else { return }
        var request = Self.request("rest/v1/exports")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["short_count": shortCount, "seconds": seconds, "quality": quality])
        if case .failure(let message) = await Self.send(request) { status = "Could not add this export to your stats: \(message)" }
    }

    // MARK: Supabase

    private struct Session: Codable { var email: String; var refreshToken: String }

    private func authenticate(path: String, email: String, password: String) async {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, password.count >= 6 else { status = "Enter your email and a password of at least 6 characters."; return }
        isWorking = true
        defer { isWorking = false }
        var request = Self.request(path)
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["email": email, "password": password])
        switch await Self.send(request) {
        case .failure(let message): status = message
        case .success(let body):
            // Sign-up without a session means Supabase sent a confirmation email first.
            guard store(body, email: email) else { status = "Check your inbox to confirm your email, then sign in."; return }
            status = "Signed in. Each export now adds to your stats."
        }
    }

    /// A fresh access token from the saved refresh token. Supabase rotates refresh tokens, so the new one is saved each time.
    private func accessToken() async -> String? {
        guard let saved = Self.savedSession() else { email = nil; return nil }
        var request = Self.request("auth/v1/token?grant_type=refresh_token")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["refresh_token": saved.refreshToken])
        switch await Self.send(request) {
        case .success(let body):
            guard store(body, email: saved.email), let token = body["access_token"] as? String else { return nil }
            return token
        case .failure(let message):
            status = "Your sign-in expired (\(message)). Sign in again to keep counting exports."
            signOutKeepingStatus()
            return nil
        }
    }

    private func signOutKeepingStatus() {
        try? GeminiKeyStore.save("", service: Self.keychainService)
        email = nil
    }

    /// Saves the session from an auth response; false when the response has none.
    private func store(_ body: [String: Any], email: String) -> Bool {
        guard let refresh = body["refresh_token"] as? String,
              let data = try? JSONEncoder().encode(Session(email: email, refreshToken: refresh)) else { return false }
        do { try GeminiKeyStore.save(String(decoding: data, as: UTF8.self), service: Self.keychainService) }
        catch { status = error.localizedDescription; return false }
        self.email = email
        return true
    }

    private static func savedSession() -> Session? {
        let text = GeminiKeyStore.read(service: keychainService)
        return text.isEmpty ? nil : try? JSONDecoder().decode(Session.self, from: Data(text.utf8))
    }

    private static func request(_ path: String) -> URLRequest {
        var request = URLRequest(url: URL(string: path, relativeTo: projectURL)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue(publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private enum Reply { case success([String: Any]), failure(String) }

    private static func send(_ request: URLRequest) async -> Reply {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let reason = body["msg"] ?? body["error_description"] ?? body["message"] ?? "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"
                return .failure("\(reason)")
            }
            return .success(body)
        } catch { return .failure(error.localizedDescription) }
    }
}
