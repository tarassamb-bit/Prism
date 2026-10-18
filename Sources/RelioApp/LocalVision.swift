import Foundation
import CoreGraphics
import ImageIO

/// The vision model names and locates the subject; optical tracking handles motion.
/// The server binds only to loopback and receives frames from this Mac.
actor LocalVision {
    static let shared = LocalVision()
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Relio/Models/Qwen3-VL-2B")
    }
    static var isInstalled: Bool {
        ["model.gguf", "projector.gguf"].allSatisfy {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }
    private var process: Process?
    private let port = 18187
    private var lastSubject = ""

    private func start() async throws {
        if process?.isRunning == true { return }
        guard Self.isInstalled else { throw URLError(.fileDoesNotExist) }
        let runner = Process()
        runner.executableURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".llama-app/llama")
        runner.arguments = ["serve", "-m", Self.directory.appendingPathComponent("model.gguf").path,
            "--mmproj", Self.directory.appendingPathComponent("projector.gguf").path,
            "--host", "127.0.0.1", "--port", "\(port)", "-c", "4096", "-np", "1",
            "--image-max-tokens", "768", "--no-webui"]
        runner.standardOutput = FileHandle.nullDevice
        runner.standardError = FileHandle.nullDevice
        try runner.run()
        process = runner
        for _ in 0..<120 {
            guard runner.isRunning else { throw URLError(.cannotConnectToHost) }
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!)
            request.timeoutInterval = 1
            if let (_, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200 { return }
            try await Task.sleep(for: .milliseconds(500))
        }
        runner.terminate()
        process = nil
        throw URLError(.timedOut)
    }

    struct Subject {
        let box: CGRect
        let preserveWholeFrame: Bool
    }

    func subject(in image: CGImage, newScene: Bool) async -> Subject? {
        do {
            try await start()
            if newScene { lastSubject = "" }
            let data = NSMutableData()
            guard let encoder = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(encoder, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            guard CGImageDestinationFinalize(encoder) else { return nil }
            let prompt = """
            Choose the main meaningful subject to keep centered in a vertical video crop. Identify the speaker, character, demonstrated object, or primary visualization. Ignore decorative stars, logos, mouse cursors, window chrome and subtitles. For charts, maps, satellite imagery, diagrams, slides and dashboards where labels or several panels matter, use layout fit and preserve the whole image. Use layout track only for a single person or compact object that can safely fill a vertical crop. Previous subject in this scene: \(lastSubject.isEmpty ? "none" : lastSubject).
            Return only JSON: {"subject":"brief name","layout":"fit or track","bbox":[x_min,y_min,x_max,y_max]}. Coordinates are integers from 0 to 1000, with origin at the top left of the image. Give a tight bounding box for the chosen subject.
            """
            let body: [String: Any] = ["messages": [["role": "user", "content": [
                ["type": "text", "text": prompt],
                ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\((data as Data).base64EncodedString())"]]
            ]]], "temperature": 0, "max_tokens": 150, "stream": false]
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.timeoutInterval = 90
            let (answer, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let result = try JSONSerialization.jsonObject(with: answer) as? [String: Any],
                  let choices = result["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let content = message["content"] as? String,
                  let first = content.firstIndex(of: "{"), let last = content.lastIndex(of: "}"),
                  let object = try JSONSerialization.jsonObject(with: Data(content[first...last].utf8)) as? [String: Any],
                  let box = object["bbox"] as? [Double], box.count == 4,
                  box.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1000 }),
                  box[2] > box[0], box[3] > box[1] else { return nil }
            lastSubject = object["subject"] as? String ?? ""
            return Subject(box: CGRect(x: box[0] / 1000, y: 1 - box[3] / 1000,
                          width: (box[2] - box[0]) / 1000, height: (box[3] - box[1]) / 1000),
                           preserveWholeFrame: object["layout"] as? String == "fit")
        } catch { return nil }
    }
}
