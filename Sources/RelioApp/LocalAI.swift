import Foundation

struct LocalAICommand {
    let action: String
    let arguments: [String]
}

enum LocalAIEngine {
    static let modelName = "Qwen3 0.6B"
    static var modelURL: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Relio/Models/Qwen3-0.6B/Qwen3-0.6B-Q8_0.gguf") }
    static var runtimeURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".llama-app/llama") }
    static var isInstalled: Bool { FileManager.default.fileExists(atPath: modelURL.path) && FileManager.default.isExecutableFile(atPath: runtimeURL.path) }

    static func interpret(_ request: String, projectSummary: String, conversation: String) async throws -> LocalAICommand {
        let prompt = """
        /no_think You are Relio AI, a helpful general assistant that can also control a video editor. Convert an editing request into exactly one pipe-delimited command. For any general conversation, question, brainstorming, explanation, or request unrelated to changing the video, use CHAT| followed by your useful natural-language answer. Do not turn casual conversation into a video edit. No explanation outside the command.
        Commands: OVERLAY|text|start_seconds|duration_seconds; SUBTITLES; TRIM|duration_seconds; START|seconds; SHORT|duration_seconds; MUTE; UNMUTE; REMOVE_OVERLAY; REMOVE_SUBTITLES; REMOVE_TEXT; EXPORT; UNDO; CHAT|short helpful answer.
        Meanings: title and overlay mean manually placed visible text. Subtitles mean timed speech transcription. REMOVE_OVERLAY clears manual text only; REMOVE_SUBTITLES clears speech captions only; REMOVE_TEXT clears both.
        Examples: hello there => CHAT|Hi! Tell me what you want changed in the video. Put hello on screen for the first 10 seconds => OVERLAY|hello|0|10. Add title Welcome at 5 seconds for 3 seconds => OVERLAY|Welcome|5|3. Add subtitles underneath => SUBTITLES. Remove the title => REMOVE_OVERLAY. Remove the subtitles => REMOVE_SUBTITLES. Get rid of all writing on the video => REMOVE_TEXT. Make the clip twelve seconds long => TRIM|12. Silence the sound => MUTE. Bring the sound back => UNMUTE. Save the finished movie => EXPORT.
        Project: \(projectSummary)
        Recent conversation: \(conversation)
        Final user: \(request.replacingOccurrences(of: "\n", with: " "))
        """
        let output = try await run(prompt)
        let actions = ["OVERLAY", "SUBTITLES", "TRIM", "START", "SHORT", "MUTE", "UNMUTE", "REMOVE_OVERLAY", "REMOVE_SUBTITLES", "REMOVE_TEXT", "EXPORT", "UNDO", "CHAT"]
        guard let line = output.components(separatedBy: .newlines).reversed().first(where: { row in actions.contains(where: { row.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix($0) }) }) else {
            throw NSError(domain: "RelioAI", code: 2, userInfo: [NSLocalizedDescriptionKey: "The model did not return an edit command."])
        }
        let parts = line.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "|")
        var command = LocalAICommand(action: parts[0].uppercased(), arguments: Array(parts.dropFirst()))
        let lower = request.lowercased()
        let textWords = ["text", "writing", "words", "caption", "title", "overlay"]
        let removeWords = ["remove", "delete", "get rid", "take off", "no more", "hide", "turn off", "don't show", "do not show"]
        let audioWords = ["audio", "sound", "voice", "music", "mute", "silent"]
        let restoreWords = ["back", "restore", "return", "unmute", "turn on", "bring back"]
        let overlayCues = ["overlay", "text", "title", "caption", "word", "write", "show", "put", "add"]
        if lower.contains("subtitle") && removeWords.contains(where: lower.contains) {
            command = .init(action: "REMOVE_SUBTITLES", arguments: [])
        } else if lower.contains("subtitle") {
            command = .init(action: "SUBTITLES", arguments: [])
        } else if audioWords.contains(where: lower.contains) && restoreWords.contains(where: lower.contains) {
            command = .init(action: "UNMUTE", arguments: [])
        } else if textWords.contains(where: lower.contains) && removeWords.contains(where: lower.contains) {
            let removesOverlay = ["title", "overlay", "on-screen text"].contains(where: lower.contains)
            command = .init(action: removesOverlay ? "REMOVE_OVERLAY" : "REMOVE_TEXT", arguments: [])
        } else if command.action == "MUTE" && !audioWords.contains(where: lower.contains) {
            command = .init(action: "CHAT", arguments: ["I’m not confident that request is about audio. Please describe the edit once more."])
        } else if command.action == "OVERLAY" && !overlayCues.contains(where: lower.contains) {
            command = .init(action: "CHAT", arguments: ["Hi! Tell me what you want changed in the video."])
        }
        if command.action == "CHAT" {
            let answer = try await generalAnswer(request, conversation: conversation)
            return .init(action: "CHAT", arguments: [answer])
        }
        return command
    }

    /// Uses the installed text model to score transcript windows for narrative value.
    /// Scores are strictly parsed; callers retain their heuristic ranking on any failure.
    static func scoreMoments(_ moments: [String]) async -> [Double]? {
        guard isInstalled, !moments.isEmpty else { return nil }
        let numbered = moments.enumerated().map { "\($0.offset): \($0.element)" }.joined(separator: "\n")
        let prompt = """
        /no_think Rank video transcript excerpts for a compelling, self-contained short clip. Judge concrete story progress, a clear payoff or reveal, surprising insight, emotional energy, and whether the excerpt makes sense without missing context. Penalize greetings, setup without payoff, repetition, and incomplete fragments. For every excerpt return one integer 0 to 10. Return ONLY a JSON array of integers in the original order, with exactly \(moments.count) scores.
        Excerpts:\n\(numbered)
        """
        do {
            let output = try await run(prompt, tokens: max(48, moments.count * 5))
            guard let first = output.firstIndex(of: "["), let last = output.lastIndex(of: "]"), first <= last,
                  let data = String(output[first...last]).data(using: .utf8),
                  let scores = try JSONSerialization.jsonObject(with: data) as? [Int],
                  scores.count == moments.count, scores.allSatisfy({ (0...10).contains($0) }) else { return nil }
            return scores.map { Double($0) / 10 }
        } catch { return nil }
    }

    private static func generalAnswer(_ request: String, conversation: String) async throws -> String {
        let prompt = """
        /no_think You are Relio AI, a friendly and concise general assistant. Answer the user's question directly and naturally using well-known facts. Keep factual answers brief. If unsure, say you are unsure instead of inventing names or events. You may discuss any ordinary topic. Do not mention command formats or video editing unless asked.
        Recent conversation: \(conversation)
        User: \(request.replacingOccurrences(of: "\n", with: " "))
        """
        let raw = try await run(prompt, tokens: 180)
        let answerSource: String
        if let userRange = raw.range(of: "\nUser:", options: .backwards),
           let endOfUserLine = raw[userRange.upperBound...].firstIndex(of: "\n") {
            answerSource = String(raw[raw.index(after: endOfUserLine)...])
        } else if let promptRange = raw.range(of: "\n> ", options: .backwards),
                  let endOfPromptLine = raw[promptRange.upperBound...].firstIndex(of: "\n") {
            answerSource = String(raw[raw.index(after: endOfPromptLine)...])
        } else { answerSource = raw }
        let answerLines = answerSource.components(separatedBy: .newlines).prefix { !$0.hasPrefix("[ Prompt:") && !$0.hasPrefix("Exiting") }
            .filter { !$0.isEmpty && !$0.hasPrefix("[Start thinking]") && !$0.hasPrefix("[End thinking]") }
        let answer = answerLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return answer.isEmpty ? "I’m here. What would you like to talk about?" : answer
    }

    private static func run(_ prompt: String, tokens: Int = 80) async throws -> String {
        guard isInstalled else { throw NSError(domain: "RelioAI", code: 1, userInfo: [NSLocalizedDescriptionKey: "Relio AI model is not installed."]) }
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process(); let pipe = Pipe()
            process.executableURL = runtimeURL
            process.arguments = ["cli", "-m", modelURL.path, "-p", prompt, "-n", "\(tokens)", "--temp", "0", "--single-turn", "--simple-io", "--no-display-prompt"]
            process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            // Drain while inference runs: waiting until termination can fill the pipe and deadlock.
            let reader = Task.detached { pipe.fileHandleForReading.readDataToEndOfFile() }
            process.terminationHandler = { process in
                Task {
                let data = await reader.value
                if process.terminationStatus == 0 { continuation.resume(returning: String(decoding: data, as: UTF8.self)) }
                else { continuation.resume(throwing: NSError(domain: "RelioAI", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "Local model inference failed."])) }
            }
                }
            do {
                try process.run()
                pipe.fileHandleForWriting.closeFile()
                DispatchQueue.global().asyncAfter(deadline: .now() + 120) {
                    if process.isRunning { process.terminate() }
                }
            } catch {
                pipe.fileHandleForWriting.closeFile()
                continuation.resume(throwing: error)
            }
        }
    }
}
