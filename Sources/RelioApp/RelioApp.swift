import SwiftUI
import AVKit
import AppKit

struct RelioChatMessage: Identifiable {
    let id = UUID()
    let isUser: Bool
    let text: String
}

@main
struct RelioApp: App {
    @State private var model = AppModel()
    @AppStorage(PrismAppearance.storageKey) private var appearance = PrismAppearance.dark
    init() { Prism.registerFonts() }
    var body: some Scene {
        WindowGroup("Prism") {
            ContentView(model: model)
                .frame(minWidth: 1100, minHeight: 720)
                .preferredColorScheme(appearance.colorScheme)
                .font(Prism.text(13))
                .foregroundStyle(Prism.text)
                .buttonStyle(.prismSecondary)
        }
    }
}

@MainActor @Observable
final class AppModel {
    enum Screen { case home, create, importSource, editor, settings }
    var screen: Screen = .home {
        didSet { if screen == .editor { isStartingNewVideo = false } }
    }
    var isStartingNewVideo = false
    /// The preview fills the app window.
    var isPlayerExpanded = false
    /// The Short the current player shows; its captions are drawn over the live preview.
    var previewSegment: EditSegment?
    var project: ProjectData?
    var message = "Create a project to begin."
    var isBusy = false
    var generationProgress: Double? = nil
    var generationStage = ""
    private var generationTask: Task<Void, Never>?
    func cancelGeneration() {
        guard generationTask != nil else { return }
        generationStage = "Cancelling…"
        generationTask?.cancel()
    }

    var player: AVPlayer?
    var selection: UUID?
    var previewShortID: UUID?
    var previewRevision = 0
    var exportedFiles: [URL] = []
    var isPreviewLoading = false
    var previewError: String?
    private var subjectTrackingRevision: Int?
    var projectURL: URL?
    var store: ProjectStore?
    let machine = MachineProfile.detect()
    var creatorPreferences = ""
    var sourcePath = ""
    var useGemini = UserDefaults.standard.bool(forKey: "shorts.useGemini")
    var geminiModel = UserDefaults.standard.string(forKey: "shorts.geminiModel") ?? "gemini-3.1-flash-lite"
    var geminiKey = ""
    var revealedGeminiKey = ""
    private var cachedGeminiKey = ""
    private var didLoadGeminiKeyFromKeychain = false
    var isGeminiKeySaved = UserDefaults.standard.bool(forKey: "shorts.geminiKeySaved")
    var isEditingGeminiKey = false
    var isShowingGeminiKey = false
    // Do not query Keychain while the app is launching. On macOS this can raise
    // an access dialog before the user has chosen to use Cloud AI.
    var geminiKeyStatus = UserDefaults.standard.bool(forKey: "shorts.geminiKeySaved")
        ? "Your API key is saved securely in Keychain. For security, the saved value stays hidden."
        : "Add a Google AI Studio API key to enable Cloud AI."
    var isTestingGemini = false
    var shortCount = 3
    var shortDuration = 30.0
    var shortSourceRegion = ShortMaker.SourceRegion.entireVideo
    var shortCaptionStyle: CaptionStyle = .classic
    var customStartMinutes = "0"
    var customEndMinutes = ""
    var shortsSource: MediaItem? {
        guard !isStartingNewVideo else { return nil }
        return project?.media.first(where: { $0.id == selection && $0.kind == "video" }) ?? project?.media.first(where: { $0.kind == "video" })
    }
    func minuteSeconds(_ text: String) -> Double? {
        guard let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")), value.isFinite else { return nil }
        let seconds = value * 60
        return seconds.isFinite ? seconds : nil
    }
    var customRangeError: String? {
        guard shortSourceRegion == .custom else { return nil }
        guard let video = shortsSource else { return "Import a video first." }
        guard let start = minuteSeconds(customStartMinutes), let end = minuteSeconds(customEndMinutes) else { return "Enter valid start and end times in minutes." }
        guard start >= 0, end <= video.duration else { return "Times must be between 0 and \(String(format: "%.3f", video.duration / 60)) minutes (the video’s duration)." }
        guard end > start else { return "End time must be after start time." }
        return nil
    }
    func resetSourceRange(for video: MediaItem) {
        shortSourceRegion = .entireVideo
        customStartMinutes = "0"
        // Round down so a displayed value never exceeds the actual source duration.
        customEndMinutes = String(format: "%.6f", floor(video.duration / 60 * 1_000_000) / 1_000_000)
    }
    var chatInput = ""
    var chatMessages: [RelioChatMessage] = [
        .init(isUser: false, text: "Tell me what you want to make. I can analyze the imported video, plan a Short, and prepare it for export.")
    ]
    var editHistory: [[EditSegment]] = []
    var editingAIName: String { useGemini ? "Gemini" : LocalAIEngine.modelName }
    var aiModelName: String { useGemini ? "Gemini · cloud" : LocalAIEngine.isInstalled ? LocalAIEngine.modelName : "Not installed" }
    var recentProjectPaths: [String] = UserDefaults.standard.stringArray(forKey: "recentProjects") ?? []
    let libraryURL: URL

    init() {
        let app = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Relio")
        libraryURL = app.appendingPathComponent("Library")
        try? FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: libraryURL.appendingPathComponent("Projects"), withIntermediateDirectories: true)
        let globals = try? ProjectStore(root: app)
        creatorPreferences = (try? globals?.load(String.self, key: "creatorPreferences")) ?? ""
        restoreSavedProjects()
        screen = .home
    }
    func saveGeminiKey() {
        do {
            try GeminiKeyStore.save(geminiKey)
            let saved = !geminiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            cachedGeminiKey = geminiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            didLoadGeminiKeyFromKeychain = true
            isGeminiKeySaved = saved
            UserDefaults.standard.set(saved, forKey: "shorts.geminiKeySaved")
            if saved {
                // Request Keychain access at save time, when the user expects setup prompts.
                // Cache the just-entered key so tests and edits don't re-prompt in this session.
                let accessGranted = GeminiKeyStore.read() == cachedGeminiKey
                geminiKeyStatus = accessGranted
                    ? "Saved securely. Choose Always Allow in the macOS prompt to avoid future prompts."
                    : "Saved securely. macOS access is pending; choose Always Allow when prompted."
            } else {
                geminiKeyStatus = "Saved key removed."
                cachedGeminiKey = ""
            }
            if saved { useGemini = true; UserDefaults.standard.set(true, forKey: "shorts.useGemini") }
            geminiKey = ""
            isEditingGeminiKey = false
            isShowingGeminiKey = false
            revealedGeminiKey = ""
        } catch { geminiKeyStatus = error.localizedDescription }
    }
    func editGeminiKey() {
        geminiKey = ""
        isShowingGeminiKey = false
        revealedGeminiKey = ""
        isEditingGeminiKey = true
    }
    func cancelGeminiKeyEdit() {
        geminiKey = ""
        isEditingGeminiKey = false
    }
    func toggleGeminiKeyVisibility() {
        if isShowingGeminiKey {
            revealedGeminiKey = ""
            isShowingGeminiKey = false
            return
        }
        let savedKey = geminiAPIKey()
        guard !savedKey.isEmpty else {
            geminiKeyStatus = "Could not read the saved key from Keychain. You can replace it here."
            return
        }
        revealedGeminiKey = savedKey
        isShowingGeminiKey = true
    }
    func geminiAPIKey() -> String {
        guard !didLoadGeminiKeyFromKeychain else { return cachedGeminiKey }
        cachedGeminiKey = GeminiKeyStore.read()
        didLoadGeminiKeyFromKeychain = true
        return cachedGeminiKey
    }
    func testGeminiKey() {
        guard !isTestingGemini else { return }
        let key = geminiAPIKey()
        guard !key.isEmpty else { geminiKeyStatus = "Save a Google AI Studio key first."; return }
        let configuration = GeminiConfiguration(apiKey: key, model: geminiModel)
        isTestingGemini = true
        geminiKeyStatus = "Testing Gemini access…"
        Task {
            defer { isTestingGemini = false }
            do {
                struct Check: Decodable { let ok: Bool }
                let result: Check = try await GeminiSelection.generate(parts: [["text": "Return ok true."]],
                    schema: ["type": "OBJECT", "properties": ["ok": ["type": "BOOLEAN"]], "required": ["ok"]], configuration: configuration)
                geminiKeyStatus = result.ok ? "Connected. Gemini is ready for cloud editing." : "Gemini returned an unexpected response."
            } catch { geminiKeyStatus = error.localizedDescription }
        }
    }
    func create() {
        guard !isBusy else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let name = "Video \(formatter.string(from: .now))"
        let url = libraryURL.appendingPathComponent("Projects").appendingPathComponent("\(name).relio")
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: url.appendingPathComponent("Media"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: url.appendingPathComponent("Exports"), withIntermediateDirectories: true)
            projectURL = url
            store = try ProjectStore(root: url)
            player?.pause()
            player = nil
            selection = nil
            previewShortID = nil
            isPreviewLoading = false
            previewError = nil
            previewRevision += 1
            sourcePath = ""
            editHistory = []
            exportedFiles = []
            chatMessages = []
            project = ProjectData(name: name)
            try save()
            UserDefaults.standard.set(url.path, forKey: "lastProject")
            remember(url)
            screen = .editor
            message = "Import a long video to make your first Short."
        } catch { message = "Could not create project: \(error.localizedDescription)" }
    }
    func startLongVideoToShort() {
        guard !isBusy else { return }
        player?.pause()
        isStartingNewVideo = true
        screen = .importSource
        sourcePath = ""
        message = "Upload a video to begin."

    }
    func openProject() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowedContentTypes = []
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }
    func open(_ url: URL) {
        guard !isBusy else { return }
        do {
            let s = try ProjectStore(root: url)
            guard var p = try s.load(ProjectData.self, key: "project") else { throw ProjectStore.StoreError.database }
            // Resolve managed assets relative to the project when a project folder is moved.
            for index in p.media.indices {
                let relocated = url.appendingPathComponent("Media").appendingPathComponent(URL(fileURLWithPath: p.media[index].path).lastPathComponent)
                if FileManager.default.fileExists(atPath: relocated.path) { p.media[index].path = relocated.path }
                if let thumbnail = p.media[index].thumbnail {
                    let relocatedThumbnail = url.appendingPathComponent("Thumbnails").appendingPathComponent(URL(fileURLWithPath: thumbnail).lastPathComponent)
                    if FileManager.default.fileExists(atPath: relocatedThumbnail.path) { p.media[index].thumbnail = relocatedThumbnail.path }
                }
            }
            editHistory = []; exportedFiles = []; chatMessages = []; store = s; project = p; projectURL = url; selection = p.media.first?.id
            UserDefaults.standard.set(url.path, forKey: "lastProject")
            remember(url)
            screen = .editor
            selectPreview(nil)
            message = "Project ready."
        } catch { message = "Could not open project: \(error.localizedDescription)" }
    }
    private func remember(_ url: URL) {
        recentProjectPaths.removeAll { $0 == url.path }
        recentProjectPaths.insert(url.path, at: 0)
        UserDefaults.standard.set(recentProjectPaths, forKey: "recentProjects")
    }
    private func restoreSavedProjects() {
        let fileManager = FileManager.default
        var paths = recentProjectPaths.filter { fileManager.fileExists(atPath: $0) }
        let knownPaths = Set(paths)
        let projectsDirectory = libraryURL.appendingPathComponent("Projects", isDirectory: true)
        let folders = (try? fileManager.contentsOfDirectory(at: projectsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        let recovered = folders.compactMap { folder -> (String, Date)? in
            guard folder.pathExtension == "relio",
                  fileManager.fileExists(atPath: folder.appendingPathComponent("project.sqlite").path),
                  !knownPaths.contains(folder.path),
                  let projectStore = try? ProjectStore(root: folder),
                  let project = try? projectStore.load(ProjectData.self, key: "project") else { return nil }
            return (folder.path, project.created)
        }.sorted { $0.1 > $1.1 }
        paths.append(contentsOf: recovered.map(\.0))
        recentProjectPaths = paths
        UserDefaults.standard.set(paths, forKey: "recentProjects")
    }
    func save() throws { if let project { try store?.save(project, key: "project") } }

    /// Bumped when a project changes from Home, so its card reloads.
    var projectListRevision = 0

    func renameProject(at path: String, to newTitle: String) {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        do {
            // The open project is saved from memory, so change it there or the next save would undo the rename.
            if projectURL?.path == path, project != nil {
                project?.title = title
                try save()
            } else {
                let projectStore = try ProjectStore(root: URL(fileURLWithPath: path))
                guard var stored = try projectStore.load(ProjectData.self, key: "project") else { throw ProjectStore.StoreError.database }
                stored.title = title
                try projectStore.save(stored, key: "project")
            }
            projectListRevision += 1
            message = "Renamed project to “\(title)”."
        } catch { message = "Could not rename project: \(error.localizedDescription)" }
    }

    /// Moves the project folder to the Trash, where it can still be restored.
    func deleteProject(at path: String) {
        guard !isBusy else { return }
        if projectURL?.path == path {
            player?.pause(); player = nil
            project = nil; store = nil; projectURL = nil; editHistory = []; previewSegment = nil
            UserDefaults.standard.removeObject(forKey: "lastProject")
        }
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
            recentProjectPaths.removeAll { $0 == path }
            UserDefaults.standard.set(recentProjectPaths, forKey: "recentProjects")
            message = "Moved the project to the Trash."
        } catch { message = "Could not delete project: \(error.localizedDescription)" }
    }
    func importVideo() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in self.importSource(url) }
        }
    }
    func importFromPath() {
        let expanded = NSString(string: sourcePath.trimmingCharacters(in: .whitespacesAndNewlines)).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        guard FileManager.default.fileExists(atPath: url.path) else {
            message = "No file exists at that path."
            return
        }
        importSource(url)
    }
    func importSource(_ url: URL) {
        guard !isBusy else { return }
        let allowed = ["mov", "mp4", "m4v", "avi"]
        guard allowed.contains(url.pathExtension.lowercased()) else {
            message = "Choose a MOV, MP4, M4V, or AVI video."
            return
        }
        if isStartingNewVideo || projectURL == nil {
            create()
            guard screen == .editor else { return }
            screen = .importSource
        }
        guard let projectURL else { return }
        sourcePath = url.path
        importVideo(from: url, into: projectURL)
    }
    private func importVideo(from url: URL, into projectURL: URL) {
        let returnToEditor = screen == .editor
        isBusy = true; message = "Copying video into your Prism library…"
        Task {
            let mediaDirectory = projectURL.appendingPathComponent("Media")
            try? FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
            let copiedURL = uniqueDestination(for: url, in: mediaDirectory)
            do {
                try await Task.detached(priority: .userInitiated) {
                    let input = try FileHandle(forReadingFrom: url)
                    defer { try? input.close() }
                    guard FileManager.default.createFile(atPath: copiedURL.path, contents: nil) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                    let output = try FileHandle(forWritingTo: copiedURL)
                    defer { try? output.close() }
                    while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty {
                        try output.write(contentsOf: data)
                    }
                }.value
            } catch {
                try? FileManager.default.removeItem(at: copiedURL)
                message = "Could not copy video: \(error.localizedDescription)"
                isBusy = false
                return
            }
            message = "Reading video metadata and creating thumbnail…"
            let item = await MediaEngine.inspect(copiedURL, thumbnailDirectory: projectURL.appendingPathComponent("Thumbnails"))
            if let item {
                project?.media.append(item)
                selection = item.id
                resetSourceRange(for: item)
                player = AVPlayer(url: copiedURL)
                do { try save() } catch {
                    project?.media.removeAll { $0.id == item.id }
                    try? FileManager.default.removeItem(at: copiedURL)
                    message = "Could not save import: \(error.localizedDescription)"
                    isBusy = false
                    return
                }
                previewShortID = nil
                screen = returnToEditor ? .editor : .importSource
                message = returnToEditor ? "Video imported. Add a clip or create Shorts." : "Video imported. Choose your settings, then press Continue."
            } else { try? FileManager.default.removeItem(at: copiedURL); message = "This video format could not be opened." }
            isBusy = false

        }
    }
    private func uniqueDestination(for source: URL, in directory: URL) -> URL {
        let base = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        var destination = directory.appendingPathComponent(source.lastPathComponent)
        var index = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = directory.appendingPathComponent("\(base) \(index).\(ext)")
            index += 1
        }
        return destination
    }
    func makeShort(requestedDuration: Double? = nil) {
        guard let video = project?.media.first(where: { $0.id == selection }) ?? project?.media.first(where: { $0.kind == "video" }) else { return }
        makeShorts(for: video, count: 1, duration: requestedDuration ?? shortDuration, sourceRegion: .entireVideo)
    }
    func continueImport() {
        guard !isBusy, selection != nil else { return }
        screen = .editor
        makeConfiguredShorts()
    }

    func selectPreview(_ shortID: UUID?) {
        if subjectTrackingRevision != nil {
            subjectTrackingRevision = nil
            isBusy = false
        }
        previewShortID = shortID
        previewError = nil
        isPreviewLoading = false
        previewRevision += 1
        let revision = previewRevision
        player?.pause()
        guard let video = project?.media.first(where: { $0.id == shortID.flatMap { id in project?.segments.first(where: { $0.id == id })?.mediaID } }) ?? project?.media.first(where: { $0.id == selection }) else { return }
        guard let shortID, let segment = project?.segments.first(where: { $0.id == shortID }) else {
            previewSegment = nil
            player = AVPlayer(url: URL(fileURLWithPath: video.path))
            return
        }
        selection = video.id
        player = nil
        isPreviewLoading = true
        if segment.cropTrackingVersion != SubjectFramer.version {
            isBusy = true
            subjectTrackingRevision = revision
            message = "Tracking the main visual subject…"
            Task {
                let path = await ShortMaker.analyzeSubjectPath(
                    URL(fileURLWithPath: video.path), start: segment.start, duration: segment.duration, zoom: segment.cropZoom ?? 1.08, useSemanticModel: !useGemini
                )
                guard revision == previewRevision, subjectTrackingRevision == revision,
                      let index = project?.segments.firstIndex(where: { $0.id == shortID }) else { return }
                project?.segments[index].cropKeyframes = path
                project?.segments[index].cropTrackingVersion = SubjectFramer.version
                do {
                    try save()
                    subjectTrackingRevision = nil
                    isBusy = false
                    message = path.isEmpty ? "No clear subject found. The crop will stay steady." : "Subject tracking ready."
                    selectPreview(shortID)
                } catch {
                    subjectTrackingRevision = nil
                    isBusy = false
                    isPreviewLoading = false
                    message = "Could not save subject tracking: \(error.localizedDescription)"
                }
            }
            return
        }
        Task {
            do {
                // Plays the edit live instead of rendering a file first, so switching Shorts is instant.
                let item = try await ShortMaker.previewItem(source: URL(fileURLWithPath: video.path), segment: segment)
                guard revision == previewRevision else { return }
                previewSegment = segment
                player = AVPlayer(playerItem: item)
                isPreviewLoading = false
            } catch {
                guard revision == previewRevision else { return }
                isPreviewLoading = false
                previewError = error.localizedDescription
                message = "Could not preview Short: \(error.localizedDescription)"
            }
        }
    }

    func makeConfiguredShorts() {
        guard let video = project?.media.first(where: { $0.id == selection }) ?? project?.media.first(where: { $0.kind == "video" }) else { return }
        makeShorts(for: video, count: shortCount, duration: shortDuration, sourceRegion: shortSourceRegion)
    }
    private func makeShorts(for video: MediaItem, count: Int, duration: Double, sourceRegion: ShortMaker.SourceRegion) {
        guard !isBusy else { return }
        if sourceRegion == .custom, let error = customRangeError { message = error; return }
        let customStart = sourceRegion == .custom ? minuteSeconds(customStartMinutes) : nil
        let customEnd = sourceRegion == .custom ? minuteSeconds(customEndMinutes) : nil
        let configuration: GeminiConfiguration?
        if useGemini {
            let key = geminiAPIKey()
            guard !key.isEmpty else { message = "Add and save your Gemini key in Settings first."; return }
            configuration = .init(apiKey: key, model: geminiModel)
        } else { configuration = nil }
        isBusy = true; generationProgress = 0; generationStage = "Preparing video"; message = "Preparing video analysis…"
        let sourceURL = URL(fileURLWithPath: video.path)
        let usedRanges = (project?.segments ?? []).filter { $0.mediaID == video.id }.map { SourceInterval(start: $0.start, end: $0.start + $0.duration) }
        generationTask = Task {
            do {
                let results = try await ShortMaker.analyze(
                    sourceURL,
                    requestedDuration: duration,
                    count: count,
                    sourceRegion: sourceRegion,
                    customStart: customStart, customEnd: customEnd,
                    excluding: usedRanges,
                    gemini: configuration,
                    progress: { completed, total in
                        Task { @MainActor in
                            if completed >= total {
                                self.message = configuration != nil ? "Gemini is analyzing stories and layouts…" : video.hasAudio == true
                                    ? "Transcribing speech and ranking moments…"
                                    : "Ranking visually interesting moments…"
                            } else {
                                self.message = "Analyzing video frames · \(min(completed + 1, total)) of \(total)…"
                            }
                        }
                    },
                    generationProgress: { fraction, stage in
                        Task { @MainActor in
                            guard self.generationProgress != nil, self.generationStage != "Cancelling…" else { return }
                            self.generationProgress = max(self.generationProgress ?? 0, fraction)
                            self.generationStage = stage
                        }
                    }
                )
                try Task.checkCancellation()
                var candidates: [EditSegment] = results.map {
                    .init(mediaID: video.id, start: $0.start, duration: $0.duration, caption: $0.caption,
                          fitToFrame: $0.fitToFrame, captions: $0.captions, cropKeyframes: $0.cropKeyframes, cropTrackingVersion: SubjectFramer.version,
                          speechWords: $0.speechWords, suggestedTitle: $0.suggestedTitle, selectionReason: $0.selectionReason,
                          captionNotice: $0.analysisWarning, captionStyle: shortCaptionStyle)
                }
                // Viral highlights need word timing; Gemini's often fails verification, so measure it on this Mac.
                if configuration != nil, shortCaptionStyle == .viral {
                    for index in candidates.indices where candidates[index].speechWords?.isEmpty != false && candidates[index].captions?.isEmpty == false {
                        try Task.checkCancellation()
                        generationStage = "Timing words on this Mac · Short \(index + 1) of \(candidates.count)"
                        let local = await ShortMaker.captions(for: sourceURL, start: candidates[index].start, duration: candidates[index].duration,
                                                              languageHint: candidates[index].captions?.map(\.text).joined(separator: " "))
                        guard !local.words.isEmpty else { continue }
                        candidates[index].captions = local.cues
                        candidates[index].speechWords = local.words
                        candidates[index].captionNotice = nil
                    }
                }
                let fresh = try appendGeneratedShorts(candidates)
                guard !fresh.isEmpty else {
                    message = "No new distinct moments were found in this range. Your existing clips were kept. Try another region or length."
                    generationProgress = nil; generationTask = nil; isBusy = false
                    return
                }
                let actualLength = results.first?.duration ?? duration
                message = "Analyzed the video and created \(fresh.count) Shorts at about \(formatSeconds(actualLength)) each. Framing follows the main subject, holds steady while it is framed, and resets on scene cuts. Review and export."
                let warning = results.compactMap(\.analysisWarning).first
                if configuration != nil { message = "Gemini selected \(fresh.count) complete clip ranges and layouts. Review framing and captions before export." }
                if let warning { message += " " + warning }
                chatMessages.append(.init(isUser: false, text: message))
                selectPreview(fresh.first?.id)
            } catch {
                message = Task.isCancelled ? "Generation cancelled. Your existing clips were kept." : "Analysis failed: \(error.localizedDescription)"
            }
            generationProgress = nil
            generationTask = nil
            isBusy = false
        }
    }
    /// Commit a generated batch atomically; regenerating never discards a user's previous work.
    @discardableResult
    func appendGeneratedShorts(_ candidates: [EditSegment]) throws -> [EditSegment] {
        guard project != nil else { return [] }
        let previous = project?.segments ?? []
        var fresh: [EditSegment] = []
        for candidate in candidates {
            if (previous + fresh).allSatisfy({ existing in
                existing.mediaID != candidate.mediaID || !TranscriptSelection.overlaps(start: candidate.start, duration: candidate.duration,
                    otherStart: existing.start, otherDuration: existing.duration)
            }) { fresh.append(candidate) }
        }
        guard !fresh.isEmpty else { return [] }
        project?.segments = previous + fresh
        do { try save() } catch { project?.segments = previous; throw error }
        editHistory.append(previous)
        return fresh
    }
    func export() {
        guard !isBusy else { return }
        guard let segments = project?.segments, !segments.isEmpty else { return }
        guard let projectURL else { return }
        let media = project?.media ?? []
        let projectName = project?.name ?? "Prism"
        let exports = projectURL.appendingPathComponent("Exports")
        try? FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        exportedFiles = []
        isBusy = true; message = segments.count == 1 ? "Rendering Short locally…" : "Rendering \(segments.count) Shorts locally…"
        Task {
            do {
                var exportedCount = 0
                for (index, originalSegment) in segments.enumerated() {
                    var segment = originalSegment
                    guard let video = media.first(where: { $0.id == segment.mediaID }) else { throw ShortMaker.Failure.noVideo }
                    if segment.cropTrackingVersion != SubjectFramer.version {
                        message = "Tracking subject in Short \(index + 1) of \(segments.count)…"
                        segment.cropKeyframes = await ShortMaker.analyzeSubjectPath(
                            URL(fileURLWithPath: video.path), start: segment.start, duration: segment.duration, zoom: segment.cropZoom ?? 1.08, useSemanticModel: !useGemini
                        )
                        segment.cropTrackingVersion = SubjectFramer.version
                        if let storedIndex = project?.segments.firstIndex(where: { $0.id == segment.id }) {
                            project?.segments[storedIndex].cropKeyframes = segment.cropKeyframes
                            project?.segments[storedIndex].cropTrackingVersion = SubjectFramer.version
                            try save()
                        }
                    }
                    message = "Rendering Short \(index + 1) of \(segments.count)…"
                    let suffix = segments.count == 1 ? "" : " \(index + 1)"
                    let destination = uniqueDestination(for: URL(fileURLWithPath: "\(projectName) Short\(suffix).mp4"), in: exports)
                    try await ShortMaker.export(source: URL(fileURLWithPath: video.path), segment: segment, destination: destination)
                    exportedFiles.append(destination)
                    exportedCount += 1
                }
                message = segments.count == 1 ? "Exported Short to Exports." : "Exported \(exportedCount) Shorts to Exports."
            }
            catch {
                let completed = exportedFiles.count
                message = completed == 0
                    ? "Export failed: \(error.localizedDescription)"
                    : "Export stopped after \(completed) of \(segments.count) Shorts. Completed files are in Exports. \(error.localizedDescription)"
            }
            isBusy = false
        }
    }
    func revealExports() {
        guard let projectURL else { return }
        let exports = projectURL.appendingPathComponent("Exports")
        try? FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        if exportedFiles.isEmpty {
            NSWorkspace.shared.open(exports)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(exportedFiles)
        }
    }
    func revealLibrary() {
        NSWorkspace.shared.activateFileViewerSelecting([libraryURL])
    }
    private func rememberEdit() { editHistory.append(project?.segments ?? []) }
    private func formatSeconds(_ value: Double) -> String {
        value.rounded() == value ? "\(Int(value)) seconds" : String(format: "%.1f seconds", value)
    }
    private func number(in text: String, after words: [String]) -> Double? {
        for word in words {
            guard let range = text.range(of: word) else { continue }
            let tail = String(text[range.upperBound...])
            if let match = tail.range(of: #"\d+(?:\.\d+)?"#, options: .regularExpression) { return Double(tail[match]) }
        }
        if let match = text.range(of: #"\d+(?:\.\d+)?\s*(?:seconds?|secs?|s)\b"#, options: .regularExpression) {
            let value = text[match].replacingOccurrences(of: #"[^0-9.]"#, with: "", options: .regularExpression)
            return Double(value)
        }
        return nil
    }
    private func overlayInstruction(in text: String) -> (caption: String, start: Double, duration: Double?)? {
        let lower = text.lowercased()
        let markers = ["text overlay", "add text", "put text", "show text", "write text"]
        guard let marker = markers.first(where: { lower.contains($0) }),
              let markerRange = lower.range(of: marker) else { return nil }
        let originalTail = String(text[markerRange.upperBound...])
        let lowerTail = originalTail.lowercased()
        let timingMarkers = [" in the first ", " in first ", " for the first ", " for first ", " during the first ", " during first ", " from ", " at "]
        var cutOffset = originalTail.count
        var timingTail = ""
        for timing in timingMarkers {
            if let found = lowerTail.range(of: timing) {
                let offset = lowerTail.distance(from: lowerTail.startIndex, to: found.lowerBound)
                guard offset < cutOffset else { continue }
                cutOffset = offset
                timingTail = String(lowerTail[found.lowerBound...])
            }
        }
        let cut = originalTail.index(originalTail.startIndex, offsetBy: cutOffset)
        var caption = String(originalTail[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["saying ", "that says ", "with ", ": "] where caption.lowercased().hasPrefix(prefix) {
            caption = String(caption.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        caption = caption.trimmingCharacters(in: CharacterSet(charactersIn: " \"“”'"))
        guard !caption.isEmpty else { return nil }
        let value = number(in: timingTail, after: ["first", "from", "at"])
        if timingTail.contains(" at ") || timingTail.hasPrefix("at ") {
            return (caption, value ?? 0, nil)
        }
        return (caption, 0, value)
    }
    private func ensureSegment() -> Bool {
        if project?.segments.isEmpty == false { return true }
        guard let video = project?.media.first(where: { $0.kind == "video" }) else { return false }
        rememberEdit()
        project?.segments = [.init(mediaID: video.id, duration: min(video.duration, 30))]
        return true
    }
    private func applyEdit(_ change: (inout EditSegment, MediaItem) -> String?) -> String? {
        guard ensureSegment(),
              let index = project?.segments.firstIndex(where: { $0.id == previewShortID }) ?? project?.segments.indices.first,
              var segment = project?.segments[index],
              let video = project?.media.first(where: { $0.id == segment.mediaID }) else { return nil }
        rememberEdit()
        guard let reply = change(&segment, video) else { editHistory.removeLast(); return nil }
        project?.segments[index] = segment
        do { try save(); selectPreview(segment.id); message = reply; return reply }
        catch {
            if let previous = editHistory.popLast() { project?.segments = previous }
            return "Could not save the edit: \(error.localizedDescription)"
        }
    }
    func setFraming(fit: Bool) {
        guard !isBusy else { return }
        if let reply = applyEdit({ segment, _ in
            segment.fitToFrame = fit
            if fit { segment.cropZoom = 1 }
            return fit ? "The full source frame will be visible in the vertical video." : "The vertical crop follows the saved focus path."
        }) { message = reply }
    }

    func holdFramingAtCenter() {
        guard !isBusy else { return }
        _ = applyEdit { segment, _ in
            segment.cropPosition = 0.5
            segment.cropKeyframes = []
            segment.cropTrackingVersion = SubjectFramer.version
            return "Framing centered and held steady. Re-track subject to follow movement."
        }
    }

    func regenerateSelectedSubtitles() {
        guard !isBusy, let segment = activeSegment,
              let video = project?.media.first(where: { $0.id == segment.mediaID }) else {
            message = "Select a Short before generating subtitles."
            return
        }
        let segmentID = segment.id
        let configuration: GeminiConfiguration?
        if useGemini {
            let key = geminiAPIKey()
            guard !key.isEmpty else { message = "Save your Google AI Studio key in Settings first."; return }
            configuration = .init(apiKey: key, model: geminiModel)
        } else { configuration = nil }
        isBusy = true
        message = configuration == nil ? "Transcribing this Short locally…" : "Gemini is transcribing this Short…"
        Task {
            var result: CaptionGenerationResult
            do {
                if let configuration {
                    let cloud = try await GeminiSelection.regenerateCaptions(url: URL(fileURLWithPath: video.path),
                        interval: (segment.start, segment.start + segment.duration), configuration: configuration)
                    let relativeWords = cloud.words.map { TimedSpeechWord(text: $0.text, start: $0.start - segment.start, duration: $0.duration) }
                    let relativeCues = cloud.cues.map { TimedCaption(text: $0.text, start: $0.start - segment.start, duration: $0.duration) }
                    result = .init(cues: relativeCues, issue: relativeCues.isEmpty ? .noSpeech : nil, words: relativeWords, notice: cloud.notice)
                } else {
                    result = await ShortMaker.captions(for: URL(fileURLWithPath: video.path), start: segment.start, duration: segment.duration)
                }
            } catch {
                isBusy = false
                message = "Could not transcribe Short: \(error.localizedDescription)"
                return
            }
            // Gemini word timestamps often fail verification; measure word timing from the audio on this Mac instead.
            if configuration != nil, result.words.isEmpty, !result.cues.isEmpty {
                message = "Measuring word timing on this Mac…"
                let local = await ShortMaker.captions(for: URL(fileURLWithPath: video.path), start: segment.start, duration: segment.duration,
                                                      languageHint: result.cues.map(\.text).joined(separator: " "))
                if !local.words.isEmpty {
                    result = local
                } else {
                    let reason = "Word timing on this Mac failed: \(local.issue?.message ?? CaptionGenerationIssue.noSpeech.message)"
                    result.notice = [result.notice, reason].compactMap { $0 }.joined(separator: " ")
                }
            }
            guard previewShortID == segmentID,
                  let index = project?.segments.firstIndex(where: { $0.id == segmentID }) else {
                isBusy = false
                return
            }
            guard !result.cues.isEmpty else {
                isBusy = false
                message = result.issue?.message ?? "Speech recognition couldn't create subtitles. Try again."
                return
            }
            editHistory.append(project?.segments ?? [])
            project?.segments[index].captions = result.cues
            project?.segments[index].speechWords = result.words
            project?.segments[index].captionNotice = result.notice
            do {
                try save()
                isBusy = false
                selectPreview(segmentID)
                message = "Added \(result.cues.count) timed subtitle phrases." + (result.notice.map { " " + $0 } ?? "")
            } catch {
                if let previous = editHistory.popLast() { project?.segments = previous }
                isBusy = false
                message = "Could not save subtitles: \(error.localizedDescription)"
            }
        }
    }

    var activeSegment: EditSegment? {
        project?.segments.first(where: { $0.id == previewShortID })
    }

    func undoFromEditor() { guard !isBusy else { return }; message = undoEdit() }

    func removeShort(_ id: UUID) {
        guard !isBusy, let index = project?.segments.firstIndex(where: { $0.id == id }) else { return }
        let wasPreviewed = previewShortID == id
        let previousSelection = project?.segments.first(where: { $0.id != id })?.id
        rememberEdit()
        project?.segments.remove(at: index)
        do {
            try save()
            if wasPreviewed { selectPreview(previousSelection) }
            message = "Removed Short. Use Undo to restore it."
        } catch {
            if let previous = editHistory.popLast() { project?.segments = previous }
            message = "Could not remove Short: \(error.localizedDescription)"
        }
    }

    func toggleSelectedAudio() {
        guard !isBusy, activeSegment != nil else { return }
        if let reply = applyEdit({ segment, _ in
            segment.isMuted = segment.isMuted != true
            return segment.isMuted == true ? "Clip audio muted." : "Source audio restored."
        }) { message = reply }
    }

    func setSelectedCaptionStyle(_ style: CaptionStyle) {
        guard !isBusy, activeSegment != nil else { return }
        if let reply = applyEdit({ segment, _ in
            segment.captionStyle = style
            return style == .viral ? "Viral captions: each spoken word turns yellow." : "Simple captions applied."
        }) { message = reply }
    }

    /// Replaces caption wording only; timings stay. An empty line removes that caption.
    func updateSelectedCaptionTexts(_ texts: [String]) {
        guard !isBusy, let cues = activeSegment?.captions, texts.count == cues.count else { return }
        if let reply = applyEdit({ segment, _ in
            segment.captions = zip(cues, texts).compactMap { cue, text in
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : TimedCaption(text: trimmed, start: cue.start, duration: cue.duration)
            }
            return "Caption text saved."
        }) { message = reply }
    }

    func updateSelectedEdit(start: Double, duration: Double, caption: String, captionStart: Double, captionDuration: Double,
                            cropZoom: Double = 1.08, cropPosition: Double = 0.5) {
        guard !isBusy, activeSegment != nil else { return }
        if let reply = applyEdit({ segment, media in
            guard start.isFinite, duration.isFinite, captionStart.isFinite, captionDuration.isFinite, cropZoom.isFinite, cropPosition.isFinite,
                  start >= 0, duration > 0, start + duration <= media.duration + 0.001,
                  cropZoom >= 1, cropZoom <= 1.5, cropPosition >= 0, cropPosition <= 1 else { return nil }
            let oldSourceStart = segment.start
            let absoluteWords = (segment.speechWords ?? []).map {
                TimedSpeechWord(text: $0.text, start: oldSourceStart + $0.start, duration: $0.duration)
            }
            var finalStart = start
            if let cutWord = absoluteWords.first(where: { $0.start + 0.02 < finalStart && $0.start + $0.duration - 0.02 > finalStart }) {
                finalStart = max(0, cutWord.start)
            }
            var finalEnd = min(media.duration, finalStart + duration)
            if let cutWord = absoluteWords.first(where: { $0.start + 0.02 < finalEnd && $0.start + $0.duration - 0.02 > finalEnd }) {
                let wordEnd = cutWord.start + cutWord.duration
                finalEnd = wordEnd <= media.duration ? wordEnd + 0.04 : max(finalStart + 0.1, cutWord.start)
                finalEnd = min(media.duration, finalEnd)
            }
            let finalDuration = finalEnd - finalStart
            guard finalDuration > 0, captionStart.isFinite, captionDuration > 0 else { return nil }
            let finalCaptionStart = min(max(0, captionStart), max(0, finalDuration - 0.05))
            let finalCaptionDuration = min(captionDuration, finalDuration - finalCaptionStart)
            guard finalCaptionDuration > 0 else { return nil }
            if let currentCaptions = segment.captions {
                segment.captions = currentCaptions.compactMap { cue in
                    let absoluteStart = oldSourceStart + cue.start
                    let absoluteEnd = absoluteStart + cue.duration
                    let clippedStart = max(finalStart, absoluteStart)
                    let clippedEnd = min(finalEnd, absoluteEnd)
                    guard clippedEnd > clippedStart else { return nil }
                    return TimedCaption(text: cue.text, start: clippedStart - finalStart, duration: clippedEnd - clippedStart)
                }
            }
            segment.speechWords = absoluteWords.compactMap { word in
                let end = word.start + word.duration
                guard word.start >= finalStart - 0.01, end <= finalEnd + 0.01 else { return nil }
                return TimedSpeechWord(text: word.text, start: word.start - finalStart, duration: word.duration)
            }
            if let currentPath = segment.cropKeyframes, !currentPath.isEmpty {
                let points = currentPath.map { CropKeyframe(time: oldSourceStart + $0.time, position: $0.position, isSceneCut: $0.isSceneCut, preserveWholeFrame: $0.preserveWholeFrame) }.sorted { $0.time < $1.time }
                func position(at time: Double) -> Double? {
                    guard let first = points.first, let last = points.last else { return nil }
                    if time <= first.time { return first.position }
                    if time >= last.time { return last.position }
                    guard let rightIndex = points.firstIndex(where: { $0.time >= time }), rightIndex > 0 else { return nil }
                    let left = points[rightIndex - 1]
                    let right = points[rightIndex]
                    if right.isSceneCut == true && time < right.time { return left.position }
                    let fraction = (time - left.time) / max(0.001, right.time - left.time)
                    return left.position + (right.position - left.position) * fraction
                }
                var rebased = points.compactMap { point -> CropKeyframe? in
                    guard point.time > finalStart, point.time < finalEnd else { return nil }
                    return .init(time: point.time - finalStart, position: point.position, isSceneCut: point.isSceneCut, preserveWholeFrame: point.preserveWholeFrame)
                }
                if let firstPosition = position(at: finalStart) { rebased.insert(.init(time: 0, position: firstPosition), at: 0) }
                if let lastPosition = position(at: finalEnd) { rebased.append(.init(time: finalDuration, position: lastPosition)) }
                segment.cropKeyframes = rebased
            }
            segment.start = finalStart
            segment.duration = finalDuration
            segment.caption = caption
            segment.cropZoom = cropZoom
            segment.cropPosition = cropPosition
            segment.captionStart = finalCaptionStart
            segment.captionDuration = finalCaptionDuration
            return abs(finalStart - start) > 0.005 || abs(finalDuration - duration) > 0.005
                ? "Clip changes saved on complete speech boundaries (\(formatSeconds(finalDuration)))."
                : "Clip changes saved."
        }) { message = reply }
        else { message = "Choose valid clip and text ranges within the source and clip duration." }
    }

    func adjustCropKeyframe(from sourceTime: Double, to targetTime: Double, position: Double, insert: Bool) {
        guard !isBusy, let activeSegment else { return }
        guard sourceTime.isFinite, targetTime.isFinite, position.isFinite,
              targetTime >= 0, targetTime <= activeSegment.duration, position >= 0, position <= 1 else { return }
        _ = applyEdit { segment, _ in
            var points = segment.cropKeyframes ?? [
                CropKeyframe(time: 0, position: segment.cropPosition ?? 0.5),
                CropKeyframe(time: segment.duration, position: segment.cropPosition ?? 0.5)
            ]
            if insert {
                if let nearest = points.indices.min(by: { abs(points[$0].time - targetTime) < abs(points[$1].time - targetTime) }),
                   abs(points[nearest].time - targetTime) < 0.18 {
                    points[nearest].position = position
                } else {
                    points.append(.init(time: targetTime, position: position))
                }
            } else if let nearest = points.indices.min(by: { abs(points[$0].time - sourceTime) < abs(points[$1].time - sourceTime) }) {
                points[nearest] = .init(time: targetTime, position: position)
            }
            points = points
                .filter { $0.time.isFinite && $0.position.isFinite }
                .map { .init(time: min(segment.duration, max(0, $0.time)), position: min(1, max(0, $0.position))) }
                .sorted { $0.time < $1.time }
            var unique: [CropKeyframe] = []
            for point in points {
                if let last = unique.last, abs(last.time - point.time) < 0.02 {
                    unique[unique.count - 1] = point
                } else { unique.append(point) }
            }
            segment.cropKeyframes = unique
            return insert ? "Subject focus point added." : "Subject focus point moved."
        }
    }

    func retrackSelectedSubject() {
        guard !isBusy, let clip = activeSegment,
              let index = project?.segments.firstIndex(where: { $0.id == clip.id }) else { return }
        project?.segments[index].cropTrackingVersion = 0
        do {
            try save()
            selectPreview(clip.id)
        } catch {
            message = "Could not refresh subject tracking: \(error.localizedDescription)"
        }
    }

    func addManualClip() {
        guard !isBusy, let video = project?.media.first(where: { $0.id == selection }), video.duration > 0 else { return }
        let time = previewShortID == nil ? player?.currentTime().seconds ?? 0 : 0
        let start = min(max(0, time.isFinite ? time : 0), max(0, video.duration - 1))
        let previous = project?.segments ?? []
        let clip = EditSegment(mediaID: video.id, start: start, duration: min(shortDuration, video.duration - start))
        rememberEdit()
        project?.segments.append(clip)
        do {
            try save()
            selectPreview(clip.id)
            message = "Clip added. Adjust its timing in the inspector."
        } catch {
            project?.segments = previous
            editHistory.removeLast()
            message = "Could not save clip: \(error.localizedDescription)"
        }
    }

    func seekPreview(to seconds: Double) {
        guard seconds.isFinite else { return }
        let limit = activeSegment?.duration ?? project?.media.first(where: { $0.id == selection })?.duration ?? 0
        player?.seek(to: CMTime(seconds: max(0, min(seconds, limit)), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func sendChat(_ suggestedText: String? = nil) {
        guard !isBusy else { return }
        let text = (suggestedText ?? chatInput).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        chatInput = ""
        chatMessages.append(.init(isUser: true, text: text))
        guard project?.media.isEmpty == false else {
            chatMessages.append(.init(isUser: false, text: "Import a video first, then I can edit it."))
            return
        }
        let configuration: GeminiConfiguration?
        if useGemini {
            let key = geminiAPIKey()
            guard !key.isEmpty else {
                message = "Save your Google AI Studio key in Settings first."
                chatMessages.append(.init(isUser: false, text: message))
                return
            }
            configuration = .init(apiKey: key, model: geminiModel)
        } else { configuration = nil }
        isBusy = true
        message = useGemini ? "Gemini is planning your edit…" : "\(LocalAIEngine.modelName) is thinking locally…"
        Task {
            do {
                let media = project?.media.first
                let segment = activeSegment ?? project?.segments.first
                let summary = "video \(formatSeconds(media?.duration ?? 0)); current edit \(formatSeconds(segment?.duration ?? 0)); caption \(segment?.caption ?? "none")"
                let conversation = chatMessages.dropLast().suffix(6).map { ($0.isUser ? "User: " : "Assistant: ") + $0.text }.joined(separator: " / ")
                let command: LocalAICommand
                if let configuration {
                    let remote = try await GeminiSelection.interpret(text, summary: summary, conversation: conversation, configuration: configuration)
                    command = .init(action: remote.action, arguments: remote.arguments)
                } else {
                    command = try await LocalAIEngine.interpret(text, projectSummary: summary, conversation: conversation)
                }
                isBusy = false
                executeAICommand(command, originalRequest: text)
                return
            } catch {
                isBusy = false
                if configuration != nil {
                    message = "Gemini could not plan this edit: \(error.localizedDescription)"
                    chatMessages.append(.init(isUser: false, text: message))
                } else { handleFallback(text) }
                return
            }
        }
    }

    private func executeAICommand(_ command: LocalAICommand, originalRequest: String) {
        func value(_ index: Int) -> Double? {
            guard command.arguments.indices.contains(index), let value = Double(command.arguments[index].trimmingCharacters(in: .whitespaces)), value.isFinite else { return nil }
            return value
        }
        switch command.action {
        case "OVERLAY":
            guard let caption = command.arguments.first, !caption.isEmpty else { handleFallback(originalRequest); return }
            let start = value(1) ?? 0; let duration = value(2)
            let reply = applyEdit { segment, _ in
                segment.caption = caption
                segment.captionStart = min(max(0, start), segment.duration)
                segment.captionDuration = min(duration ?? (segment.duration - (segment.captionStart ?? 0)), segment.duration - (segment.captionStart ?? 0))
                let end = (segment.captionStart ?? 0) + (segment.captionDuration ?? segment.duration)
                return "\(editingAIName) added “\(caption)” from \(formatSeconds(segment.captionStart ?? 0)) to \(formatSeconds(end))."
            }
            chatMessages.append(.init(isUser: false, text: reply ?? "I couldn't apply that overlay."))
        case "TRIM":
            guard let duration = value(0) else { handleFallback(originalRequest); return }
            let reply = applyEdit { segment, video in segment.duration = max(0.25, min(duration, video.duration - segment.start)); return "\(editingAIName) trimmed the edit to \(formatSeconds(segment.duration))." }
            chatMessages.append(.init(isUser: false, text: reply ?? "I couldn't trim the edit."))
        case "START":
            guard let start = value(0) else { handleFallback(originalRequest); return }
            let reply = applyEdit { segment, video in segment.start = max(0, min(start, video.duration - 0.25)); segment.duration = min(segment.duration, video.duration - segment.start); return "\(editingAIName) moved the edit to \(formatSeconds(segment.start))." }
            chatMessages.append(.init(isUser: false, text: reply ?? "I couldn't move the edit."))
        case "SHORT": makeShort(requestedDuration: value(0))
        case "SUBTITLES":
            chatMessages.append(.init(isUser: false, text: "I’m transcribing the selected Short using your Auto Shorts settings and adding timed subtitles."))
            regenerateSelectedSubtitles()
        case "MUTE":
            let reply = applyEdit { segment, _ in segment.isMuted = true; return "\(editingAIName) muted the audio." }
            chatMessages.append(.init(isUser: false, text: reply ?? "I couldn't mute the edit."))
        case "UNMUTE":
            let reply = applyEdit { segment, _ in segment.isMuted = false; return "\(editingAIName) restored the source audio." }
            chatMessages.append(.init(isUser: false, text: reply ?? "I couldn't restore the audio."))
        case "REMOVE_OVERLAY":
            let reply = applyEdit { segment, _ in segment.caption = ""; segment.captionStart = 0; segment.captionDuration = nil; return "\(editingAIName) removed the text overlay. Speech subtitles are unchanged." }
            chatMessages.append(.init(isUser: false, text: reply ?? "I couldn't remove the text overlay."))
        case "REMOVE_SUBTITLES":
            let reply = applyEdit { segment, _ in segment.captions = []; return "\(editingAIName) removed the speech subtitles. The text overlay is unchanged." }
            chatMessages.append(.init(isUser: false, text: reply ?? "I couldn't remove the speech subtitles."))
        case "REMOVE_TEXT":
            let reply = applyEdit { segment, _ in segment.caption = ""; segment.captions = []; segment.captionStart = 0; segment.captionDuration = nil; return "\(editingAIName) removed the text overlay and speech subtitles." }
            chatMessages.append(.init(isUser: false, text: reply ?? "I couldn't remove the text."))
        case "EXPORT": chatMessages.append(.init(isUser: false, text: "\(editingAIName) is exporting the current edit.")); export()
        case "UNDO":
            chatMessages.append(.init(isUser: false, text: undoEdit()))
        case "CHAT":
            chatMessages.append(.init(isUser: false, text: command.arguments.joined(separator: "|")))
            message = "\(editingAIName) answered."
        default: handleFallback(originalRequest)
        }
    }

    private func undoEdit() -> String {
        guard let previous = editHistory.last else { return "There isn’t an edit to undo yet." }
        let current = project?.segments ?? []
        project?.segments = previous
        do {
            try save()
            editHistory.removeLast()
            let restoredSelection = previous.contains(where: { $0.id == previewShortID }) ? previewShortID : previous.first?.id
            selectPreview(restoredSelection)
            return "Undone. I restored the previous timeline edit."
        } catch {
            project?.segments = current
            return "Could not save undo: \(error.localizedDescription)"
        }
    }

    private func handleFallback(_ text: String) {
        let request = text.lowercased()
        if request == "undo" || request.contains("undo last") {
            chatMessages.append(.init(isUser: false, text: undoEdit()))
        } else if let overlay = overlayInstruction(in: text) {
            let reply = applyEdit { segment, _ in
            segment.caption = overlay.caption
                segment.captionStart = min(overlay.start, segment.duration)
                segment.captionDuration = min(overlay.duration ?? (segment.duration - (segment.captionStart ?? 0)), segment.duration - (segment.captionStart ?? 0))
                let start = segment.captionStart ?? 0
                let length = segment.captionDuration ?? segment.duration
                return "Done — I added “\(overlay.caption)” from \(formatSeconds(start)) to \(formatSeconds(start + length))."
            }
            chatMessages.append(.init(isUser: false, text: reply ?? "I couldn't add that text overlay."))
        } else if request.contains("remove subtitles") || request.contains("delete subtitles") || request.contains("remove speech captions")
                    || request.contains("hide subtitles") || request.contains("don't show subtitles") || request.contains("do not show subtitles") {
            let reply = applyEdit { segment, _ in segment.captions = []; return "Done — I removed the speech subtitles. The text overlay is unchanged." }
            chatMessages.append(.init(isUser: false, text: reply ?? "I couldn't remove the speech subtitles."))
        } else if request.contains("remove title") || request.contains("delete title") || request.contains("remove overlay") || request.contains("delete overlay")
                    || request.contains("hide title") || request.contains("hide overlay") {
            let reply = applyEdit { segment, _ in segment.caption = ""; segment.captionStart = 0; segment.captionDuration = nil; return "Done — I removed the text overlay. Speech subtitles are unchanged." }
            chatMessages.append(.init(isUser: false, text: reply ?? "I couldn't remove the text overlay."))
        } else if request.contains("remove caption") || request.contains("delete caption") || request.contains("no caption") || request.contains("remove text") {
            let reply = applyEdit { segment, _ in segment.caption = ""; segment.captions = []; segment.captionStart = 0; segment.captionDuration = nil; return "Done — I removed the text overlay and speech subtitles." }
            chatMessages.append(.init(isUser: false, text: reply ?? "I couldn't change the captions."))
        } else if request.contains("caption to ") || request.contains("text to ") {
            let marker = request.contains("caption to ") ? "caption to " : "text to "
            let caption = String(text[text.lowercased().range(of: marker)!.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: " \"“”'"))
            let reply = caption.isEmpty ? nil : applyEdit { segment, _ in segment.caption = caption; segment.captionStart = 0; segment.captionDuration = segment.duration; return "Done — I changed the on-screen caption to “\(caption)”." }
            chatMessages.append(.init(isUser: false, text: reply ?? "Tell me the caption text after “caption to”."))
        } else if request.contains("unmute") || request.contains("restore audio") {
            let reply = applyEdit { segment, _ in segment.isMuted = false; return "Done — I restored the source audio." }
            chatMessages.append(.init(isUser: false, text: reply ?? "I couldn't restore the audio."))
        } else if request.contains("mute") || request.contains("remove audio") || request.contains("no audio") {
            let reply = applyEdit { segment, _ in segment.isMuted = true; return "Done — I muted the audio. The next export will be silent." }
            chatMessages.append(.init(isUser: false, text: reply ?? "I couldn't mute this edit."))
        } else if request.contains("start at") || request.contains("begin at") {
            let value = number(in: request, after: ["start at", "begin at"])
            let reply = value.flatMap { newStart in applyEdit { segment, video in
                segment.start = max(0, min(newStart, max(0, video.duration - 0.25)))
                segment.duration = min(segment.duration, video.duration - segment.start)
                return "Done — the edit now starts at \(formatSeconds(segment.start))."
            }}
            chatMessages.append(.init(isUser: false, text: reply ?? "Tell me a start time, for example “start at 12 seconds”."))
        } else if request.contains("make it") || request.contains("trim to") || request.contains("duration") {
            let value = number(in: request, after: ["make it", "trim to", "duration"])
            let reply = value.flatMap { newDuration in applyEdit { segment, video in
                segment.duration = max(0.25, min(newDuration, video.duration - segment.start))
                return "Done — I trimmed the edit to \(formatSeconds(segment.duration))."
            }}
            chatMessages.append(.init(isUser: false, text: reply ?? "Tell me a duration, for example “make it 20 seconds”."))
        } else if request.contains("short") || request.contains("analy") || request.contains("best moment") {
            chatMessages.append(.init(isUser: false, text: "I’m analyzing the video locally and looking for a complete moment."))
            makeShort(requestedDuration: number(in: request, after: ["short", "make", "create"]))
        } else if request.contains("export") {
            let reply = project?.segments.isEmpty == false
                ? "I’m exporting the current edit as an MP4 into this project's Exports folder."
                : "Create a Short first, then I can prepare it for export."
            chatMessages.append(.init(isUser: false, text: reply))
            if project?.segments.isEmpty == false { export() }
        } else if request.contains("caption") {
            let reply: String
            if let segment = project?.segments.first {
                reply = segment.captions?.isEmpty == false
                    ? "This Short already has generated speech subtitles on the Text track."
                    : "This Short has no generated speech subtitles yet. Select it and choose Transcribe in the Clip inspector."
            } else {
                reply = "Create a Short and I’ll add detected speech to the Captions track."
            }
            chatMessages.append(.init(isUser: false, text: reply))
        } else {
            chatMessages.append(.init(isUser: false, text: "I can create or trim a Short, move its start time, change or remove captions, mute audio, undo an edit, and export. Try “make it 12 seconds”."))
        }
    }
}

private struct PointerFeedback: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false
    @State private var pointingCursorIsPushed = false

    @ViewBuilder
    func body(content: Content) -> some View {
        let feedback = content
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovering = hovering && isEnabled
                if #unavailable(macOS 15.0) {
                    if hovering && isEnabled && !pointingCursorIsPushed {
                        NSCursor.pointingHand.push()
                        pointingCursorIsPushed = true
                    } else if (!hovering || !isEnabled) && pointingCursorIsPushed {
                        NSCursor.pop()
                        pointingCursorIsPushed = false
                    }
                }
            }
            .onDisappear {
                if pointingCursorIsPushed {
                    NSCursor.pop()
                    pointingCursorIsPushed = false
                }
            }
            .brightness(isHovering ? 0.08 : 0)
            .scaleEffect(isHovering ? 1.015 : 1)
            .animation(.easeOut(duration: 0.12), value: isHovering)
        if #available(macOS 15.0, *) {
            feedback.pointerStyle(isEnabled ? .link : .default)
        } else {
            feedback
        }
    }
}

private extension View {
    func pointerFeedback() -> some View { modifier(PointerFeedback()) }
}

private struct ResourceRefreshOption: Identifiable {
    let title: String
    let seconds: Double
    var id: Double { seconds }
}

private struct SettingsCategoryTile: View {
    let title: String
    let detail: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    Image(systemName: icon)
                        .font(Prism.text(20, .medium))
                        .foregroundStyle(Prism.accent)
                        .frame(width: 38, height: 38)
                        .background(Prism.surface2, in: RoundedRectangle(cornerRadius: 12))
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Prism.accent)
                            .accessibilityHidden(true)
                    }
                }
                Text(title).font(Prism.text(14, .medium))
                Text(detail).font(Prism.text(10)).foregroundStyle(Prism.textSecondary).lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(width: 190, height: 136, alignment: .leading)
            .background(isSelected ? Prism.accent.opacity(0.15) : Prism.surface1, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(isSelected ? Prism.accent : Prism.surface2, lineWidth: isSelected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .pointerFeedback()
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var isDropTarget = false
    @State private var sidebarCollapsed = false
    @State private var choosingCaptions = false
    @State private var showAllProjects = false
    @State private var showUnfinishedProjects = false
    @State private var projectShortCounts: [String: Int] = [:]
    @State private var renameProjectPath: String?
    @State private var renameText = ""
    @State private var deleteProjectPath: String?
    @State private var statsProject: ProjectPath?
    @AppStorage(PrismAppearance.storageKey) var appearance = PrismAppearance.dark
    @AppStorage("editor.leftSidebarWidth") var leftSidebarWidth = 248.0
    @AppStorage("editor.rightSidebarWidth") var rightSidebarWidth = 282.0
    @AppStorage("system.resourceRefreshSeconds") private var resourceRefreshSeconds = 60.0
    @State private var selectedSettingsCategory: SettingsCategory = .aiCloud
    private let resourceRefreshOptions: [ResourceRefreshOption] = [
        .init(title: "1 second", seconds: 1), .init(title: "5 seconds", seconds: 5),
        .init(title: "10 seconds", seconds: 10), .init(title: "30 seconds", seconds: 30),
        .init(title: "1 minute", seconds: 60), .init(title: "5 minutes", seconds: 300),
        .init(title: "10 minutes", seconds: 600), .init(title: "15 minutes", seconds: 900),
        .init(title: "30 minutes", seconds: 1_800), .init(title: "45 minutes", seconds: 2_700),
        .init(title: "60 minutes", seconds: 3_600)
    ]
    private enum SettingsCategory { case aiCloud, systemResources }
    var body: some View {
        HStack(spacing: 0) {
            if model.screen != .editor { sidebar.frame(width: sidebarCollapsed ? 76 : 252) }
            VStack(spacing: 0) {
                if model.screen == .editor { editorHeader } else { topbar }
                if model.screen == .home { dashboard }
                else if model.screen == .create { creationModes }
                else if model.screen == .importSource { sourceImport }
                else if model.screen == .settings { settingsPage }
                else { editingWorkspace }
            }
        }
        .background(Prism.surface0)
        .overlay {
            if model.isPlayerExpanded, model.screen == .editor, let player = model.player {
                expandedPlayer(player)
            }
        }
        .tint(Prism.accent)
        .animation(.easeInOut(duration: 0.2), value: sidebarCollapsed)
    }
    /// Fills the app window (not macOS full screen), so it opens and closes instantly.
    func expandedPlayer(_ player: AVPlayer) -> some View {
        ZStack(alignment: .topTrailing) {
            Color.black
            RelioPlayerView(player: player, captionSegment: model.previewSegment, showsControls: true)
            Button { model.isPlayerExpanded = false } label: {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(Prism.text(13, .medium)).foregroundStyle(.white)
                    .frame(width: 34, height: 34).background(.black.opacity(0.6), in: Circle())
            }
            .buttonStyle(.plain).padding(16)
            .keyboardShortcut(.cancelAction)
            .help("Exit full view · Esc").accessibilityLabel("Exit full view")
        }
        .onDisappear { model.isPlayerExpanded = false }
    }
    var sidebar: some View {
        VStack(alignment: .leading, spacing: 17) {
            if sidebarCollapsed {
                Button { sidebarCollapsed = false } label: {
                    Image(systemName: "sidebar.right").font(Prism.text(18)).frame(maxWidth: .infinity)
                }.buttonStyle(.plain).pointerFeedback().help("Expand sidebar")
            } else {
                HStack(spacing: 10) {
                    PrismMark().frame(height: 24)
                    Text("Prism").font(Prism.display(24)).tracking(-0.5)
                    Spacer()
                    Button { sidebarCollapsed = true } label: { Image(systemName: "sidebar.left") }
                        .buttonStyle(.plain).pointerFeedback().foregroundStyle(Prism.textSecondary).help("Collapse sidebar")
                }
        Text(model.useGemini ? "Your video editor · Cloud AI" : "Your video editor · On-device AI").font(Prism.text(12)).foregroundStyle(Prism.textSecondary)
            }
            Divider().padding(.vertical, 8)
            sidebarButton("Home", icon: "house.fill", selected: model.screen == .home) { model.screen = .home }
            sidebarButton("Create Shorts", icon: "plus.square.fill", selected: model.screen == .importSource, prominent: true) { model.startLongVideoToShort() }
            if let project = model.project {
                sidebarButton("Editor", icon: "film.stack.fill", selected: model.screen == .editor) { model.screen = .editor }
                if !sidebarCollapsed {
                    Divider()
                    Text("Media · \(project.media.count)").font(Prism.text(12, .medium)).foregroundStyle(Prism.textSecondary)
                    ForEach(project.media) { item in
                        Button { model.selection = item.id; model.selectPreview(nil) } label: {
                            HStack { Image(systemName: "film"); Text(item.name).lineLimit(1) }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain).pointerFeedback()
                    }
                    Button("＋  Import video") { model.importVideo() }.pointerFeedback()
                }
            }
            Spacer()
            sidebarButton("Settings", icon: "gearshape.fill", selected: model.screen == .settings) { model.screen = .settings }
            TimelineView(.periodic(from: .now, by: min(3_600, max(1, resourceRefreshSeconds)))) { _ in
                let machine = MachineProfile.detect()
                if sidebarCollapsed {
                    ZStack {
                        Circle().stroke(Prism.border, lineWidth: 4)
                        Circle()
                            .trim(from: 0, to: machine.memoryUsage)
                            .stroke(Prism.text, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        VStack(spacing: 0) {
                            Text("\(Int(machine.memoryUsage * 100))%")
                                .font(Prism.display(10))
                            Text("RAM").font(Prism.text(7, .medium)).foregroundStyle(Prism.textSecondary)
                        }
                    }
                    .frame(width: 44, height: 44)
                    .frame(maxWidth: .infinity)
                    .help("RAM used: \(String(format: "%.1f", machine.memoryUsedGB)) of \(machine.memoryGB) GB · Storage free: \(machine.freeGB) of \(machine.storageGB) GB")
                    .accessibilityLabel("RAM \(Int(machine.memoryUsage * 100)) percent used; \(machine.freeGB) gigabytes of storage free")
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("System resources").font(Prism.text(11, .medium)).foregroundStyle(Prism.textSecondary)
                        VStack(spacing: 5) {
                            HStack(spacing: 6) {
                                Image(systemName: "memorychip").foregroundStyle(Prism.textSecondary)
                                Text("RAM used").foregroundStyle(Prism.textSecondary)
                                Spacer(minLength: 3)
                                Text("\(String(format: "%.1f", machine.memoryUsedGB)) / \(machine.memoryGB) GB")
                                    .foregroundStyle(Prism.textSecondary).monospacedDigit()
                            }.font(Prism.text(11, .medium))
                            PrismProgressLine(value: machine.memoryUsage)
                        }
                        VStack(spacing: 5) {
                            HStack(spacing: 6) {
                                Image(systemName: "internaldrive").foregroundStyle(Prism.textSecondary)
                                Text("Storage free").foregroundStyle(Prism.textSecondary)
                                Spacer(minLength: 3)
                                Text("\(machine.freeGB) / \(machine.storageGB) GB")
                                    .foregroundStyle(Prism.textSecondary).monospacedDigit()
                            }.font(Prism.text(11, .medium))
                            PrismProgressLine(value: machine.freeStorageRatio)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                    .help("RAM and available storage refresh every \(resourceRefreshLabel)")
                }
            }
        }
        .padding(sidebarCollapsed ? 14 : 24)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Prism.surface1)
    }
    func sidebarButton(_ title: String, icon: String, selected: Bool = false, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if sidebarCollapsed {
                Image(systemName: icon).frame(maxWidth: .infinity)
            } else {
                Label(title, systemImage: icon)
                    .font(prominent || selected ? Prism.text(14, .medium) : Prism.text(14))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain).pointerFeedback()
        .padding(.horizontal, 12)
        .padding(.vertical, prominent ? 13 : 10)
        .foregroundStyle(prominent ? Prism.ink : Prism.text)
        .background(prominent ? Prism.action : (selected ? Prism.surface2 : .clear), in: RoundedRectangle(cornerRadius: 8))
        .help(title)
    }
    var topbar: some View {
        HStack {
            Text(model.screen == .settings ? "Settings" : model.screen == .home ? "Home" : (model.screen == .create || model.screen == .importSource ? "Create Shorts" : (model.project?.displayTitle ?? "Editor"))).font(Prism.display(18))
            Spacer()
            if model.isBusy { ProgressView().controlSize(.small) }
            if model.screen == .editor || model.screen == .importSource { Text(model.message).font(Prism.text(12)).foregroundStyle(Prism.textSecondary).lineLimit(1) }
            AppearanceSwitch(selection: $appearance).padding(.leading, 12)
        }.padding(20)
    }
    var settingsPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Settings").font(Prism.display(32))
                Text("Choose a category to configure Prism.")
                    .foregroundStyle(Prism.textSecondary)
            }
            HStack(spacing: 14) {
                SettingsCategoryTile(title: "AI & Cloud", detail: "Provider, key, and model", icon: "sparkles", isSelected: selectedSettingsCategory == .aiCloud) {
                    withAnimation(.easeInOut(duration: 0.2)) { selectedSettingsCategory = .aiCloud }
                }
                SettingsCategoryTile(title: "System resources", detail: "RAM and storage updates", icon: "chart.bar.xaxis", isSelected: selectedSettingsCategory == .systemResources) {
                    withAnimation(.easeInOut(duration: 0.2)) { selectedSettingsCategory = .systemResources }
                }
            }
            ScrollView {
                Group {
                    if selectedSettingsCategory == .aiCloud {
                        VStack(alignment: .leading, spacing: 18) {
                        Label("AI & Cloud", systemImage: "sparkles").font(Prism.display(20))
                        Toggle("Use cloud AI", isOn: $model.useGemini)
                            .onChange(of: model.useGemini) { _, value in UserDefaults.standard.set(value, forKey: "shorts.useGemini") }
                        Text(model.useGemini ? "Gemini handles clip selection, transcription, subtitles and editor chat." : "Prism uses on-device analysis. Turn on cloud AI to use Gemini.")
                            .font(Prism.text(13)).foregroundStyle(Prism.textSecondary)
                        Divider()
                        Text("Google AI Studio API key").font(Prism.text(14, .medium))
                        HStack(spacing: 10) {
                            Image(systemName: model.isGeminiKeySaved ? "checkmark.shield.fill" : "key.fill")
                                .foregroundStyle(model.isGeminiKeySaved ? Prism.accent : Prism.textSecondary)
                            Text(model.isGeminiKeySaved ? "API key saved securely" : "No API key saved")
                                .font(Prism.text(13, .medium))
                            Spacer()
                            if model.isGeminiKeySaved {
                                Text("Hidden for security").font(Prism.text(12)).foregroundStyle(Prism.textSecondary)
                            }
                        }
                        .padding(12)
                        .background(Prism.surface1, in: RoundedRectangle(cornerRadius: 12))
                        if model.isGeminiKeySaved {
                            HStack(spacing: 10) {
                                Image(systemName: model.isEditingGeminiKey ? "key.fill" : "lock.fill")
                                    .foregroundStyle(Prism.textSecondary)
                                if model.isEditingGeminiKey {
                                    SecureField("Enter a new API key", text: $model.geminiKey)
                                        .textFieldStyle(.plain)
                                } else if model.isShowingGeminiKey {
                                    ScrollView(.horizontal) {
                                        Text(model.revealedGeminiKey)
                                            .font(Prism.mono(13))
                                            .textSelection(.enabled)
                                            .lineLimit(1)
                                            .fixedSize(horizontal: true, vertical: false)
                                    }
                                } else {
                                    Text(String(repeating: "•", count: 24))
                                        .font(Prism.mono(13))
                                        .foregroundStyle(Prism.textSecondary)
                                }
                                Spacer(minLength: 0)
                                if model.isEditingGeminiKey {
                                    Button("Cancel") { model.cancelGeminiKeyEdit() }
                                        .buttonStyle(.borderless)
                                    Button("Save") { model.saveGeminiKey() }
                                        .buttonStyle(.prismPrimary)
                                        .disabled(model.geminiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isTestingGemini)
                                } else {
                                    Button { model.toggleGeminiKeyVisibility() } label: {
                                        Image(systemName: model.isShowingGeminiKey ? "eye.slash" : "eye")
                                    }
                                    .buttonStyle(.borderless)
                                    .help(model.isShowingGeminiKey ? "Hide API key" : "Show API key")
                                    .accessibilityLabel(model.isShowingGeminiKey ? "Hide API key" : "Show API key")
                                    Button { model.editGeminiKey() } label: {
                                        Image(systemName: "pencil")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Edit API key")
                                    .accessibilityLabel("Edit API key")
                                }
                            }
                            .padding(11)
                            .background(Prism.surface2, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Prism.surface2, lineWidth: 1))
                        } else {
                            HStack(spacing: 10) {
                                Image(systemName: "key.fill").foregroundStyle(Prism.textSecondary)
                                SecureField("Paste your API key", text: $model.geminiKey)
                                    .textFieldStyle(.plain)
                                Button("Save key") { model.saveGeminiKey() }
                                    .buttonStyle(.prismPrimary)
                                    .disabled(model.geminiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isTestingGemini)
                            }
                            .padding(11)
                            .background(Prism.surface2, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Prism.surface2, lineWidth: 1))
                        }
                        HStack {
                            Button(model.isTestingGemini ? "Testing…" : "Test connection") { model.testGeminiKey() }
                                .disabled(model.isTestingGemini)
                            if model.isGeminiKeySaved {
                                Button("Remove saved key", role: .destructive) { model.geminiKey = ""; model.saveGeminiKey() }
                                    .disabled(model.isTestingGemini || model.isEditingGeminiKey)
                            }
                        }
                        Text(model.geminiKeyStatus).font(Prism.text(12)).foregroundStyle(Prism.textSecondary)
                        Link("Get a key from Google AI Studio", destination: URL(string: "https://aistudio.google.com/apikey")!)
                        Divider()
                        HStack(alignment: .center, spacing: 18) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Gemini model").font(Prism.text(14, .medium))
                                Text("The default is recommended. Change it if you prefer.")
                                    .font(Prism.text(12)).foregroundStyle(Prism.textSecondary)
                            }
                            Spacer(minLength: 8)
                            Picker("Gemini model", selection: $model.geminiModel) {
                                Text("Gemini 3.1 Flash-Lite · Recommended").tag("gemini-3.1-flash-lite")
                                Text("Gemini 3.5 Flash-Lite · Low cost").tag("gemini-3.5-flash-lite")
                                Text("Gemini 3.6 Flash · Higher capability").tag("gemini-3.6-flash")
                            }
                            .pickerStyle(.menu)
                            .onChange(of: model.geminiModel) { _, value in UserDefaults.standard.set(value, forKey: "shorts.geminiModel") }
                        }
                        Text("Cloud AI sends audio, transcripts and sampled frames to Google. Chat sends your request, recent conversation and edit summary. Google API charges may apply. Video rendering and subject tracking run on your Mac.")
                            .font(Prism.text(12)).foregroundStyle(Prism.textSecondary).fixedSize(horizontal: false, vertical: true)
                        }
                        .disabled(model.isBusy)
                    } else {
                        TimelineView(.periodic(from: .now, by: min(3_600, max(1, resourceRefreshSeconds)))) { _ in
                            let machine = MachineProfile.detect()
                            VStack(alignment: .leading, spacing: 20) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Label("System resources", systemImage: "chart.bar.xaxis").font(Prism.display(20))
                                    Text("Monitor this Mac and choose how often the sidebar refreshes.")
                                        .font(Prism.text(13)).foregroundStyle(Prism.textSecondary)
                                }
                                HStack(spacing: 14) {
                                    resourceSummary(title: "Memory used", value: "\(String(format: "%.1f", machine.memoryUsedGB)) / \(machine.memoryGB) GB", fraction: machine.memoryUsage, tint: .purple)
                                    resourceSummary(title: "Storage available", value: "\(machine.freeGB) / \(machine.storageGB) GB", fraction: machine.freeStorageRatio, tint: Color(red: 0.12, green: 0.78, blue: 0.90))
                                }
                                Divider()
                                HStack(alignment: .center, spacing: 18) {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text("Sidebar update frequency").font(Prism.text(14, .medium))
                                        Text("Choose from 1 second to 60 minutes.").font(Prism.text(12)).foregroundStyle(Prism.textSecondary)
                                    }
                                    Spacer(minLength: 8)
                                    Picker("Refresh interval", selection: $resourceRefreshSeconds) {
                                        ForEach(resourceRefreshOptions) { option in
                                            Text(option.title).tag(option.seconds)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .accessibilityLabel("System resource refresh interval")
                                }
                            }
                            .padding(24)
                            .background(Prism.surface1, in: RoundedRectangle(cornerRadius: 16))
                        }
                    }
                }
                .frame(maxWidth: 1000, alignment: .leading)
            }
            .frame(maxWidth: 1000, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func resourceSummary(title: String, value: String, fraction: Double, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(Prism.text(13)).foregroundStyle(Prism.textSecondary)
            Text(value).font(Prism.display(20))
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Prism.surface2)
                    Capsule().fill(tint).frame(width: geometry.size.width * min(1, max(0, fraction)))
                }
            }
            .frame(height: 7)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Prism.surface1, in: RoundedRectangle(cornerRadius: 12))
    }

    private var resourceRefreshLabel: String {
        resourceRefreshOptions.first(where: { $0.seconds == resourceRefreshSeconds })?.title ?? "1 minute"
    }

    var dashboard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                HStack(spacing: 14) {
                    Button { model.startLongVideoToShort() } label: {
                        HStack(spacing: 20) {
                            Image(systemName: "plus.square.fill").font(Prism.text(29, .medium))
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Start creating").font(Prism.display(22))
                                Text("One in. Many out. Choose a video and Prism finds the moments worth sharing.")
                                    .font(Prism.text(13, .medium)).opacity(0.82)
                            }
                            Spacer(minLength: 12)
                            Image(systemName: "arrow.up.right").font(Prism.text(18, .medium))
                        }
                        .padding(.horizontal, 24)
                        .frame(maxWidth: .infinity, minHeight: 104)
                        .contentShape(RoundedRectangle(cornerRadius: 16))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Prism.ink)
                    .background(Prism.action, in: RoundedRectangle(cornerRadius: 16))
                    .pointerFeedback()
                }

                // Uploads that never got Shorts are kept but tucked away; until counts load, every project shows.
                let finished = model.recentProjectPaths.filter { (projectShortCounts[$0] ?? 1) > 0 }
                let unfinished = model.recentProjectPaths.filter { projectShortCounts[$0] == 0 }
                HStack(alignment: .firstTextBaseline) {
                    Text("Projects").font(Prism.display(22))
                    Spacer()
                    if !unfinished.isEmpty {
                        Button { showUnfinishedProjects.toggle() } label: {
                            HStack(spacing: 6) {
                                Text(showUnfinishedProjects ? "Hide unfinished" : "Show \(unfinished.count) unfinished")
                                Image(systemName: showUnfinishedProjects ? "chevron.up" : "chevron.down").font(Prism.text(11, .medium))
                            }
                        }
                            .buttonStyle(.prismGhost)
                            .help("Projects where a video was uploaded but no Shorts were made")
                    }
                }
                if model.recentProjectPaths.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "rectangle.stack").font(Prism.text(34)).foregroundStyle(Prism.textSecondary)
                        Text("Your projects will appear here").font(Prism.text(14, .medium))
                        Text("Create a Short to start your first project.").foregroundStyle(Prism.textSecondary)
                    }.frame(maxWidth: .infinity).padding(48).background(Prism.surface1, in: RoundedRectangle(cornerRadius: 16))
                } else {
                    // Newest first; two rows keep Home calm, the rest are one click away.
                    let visible = showAllProjects ? finished : Array(finished.prefix(12))
                    projectGrid(visible)
                    if finished.count > 12 {
                        // Outlined with a chevron so it reads as "more below", not as a heading.
                        Button { showAllProjects.toggle() } label: {
                            HStack(spacing: 6) {
                                Text(showAllProjects ? "Show fewer" : "Show all \(finished.count) projects")
                                Image(systemName: showAllProjects ? "chevron.up" : "chevron.down").font(Prism.text(11, .medium))
                            }
                        }
                            .buttonStyle(.prismSecondary)
                    }
                    if showUnfinishedProjects && !unfinished.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Unfinished").font(Prism.display(18))
                            Text("A video was uploaded, but no Shorts were made yet.").font(Prism.text(12)).foregroundStyle(Prism.textSecondary)
                        }.padding(.top, 8)
                        projectGrid(unfinished)
                    }
                }
            }.padding(24).frame(maxWidth: 1800, alignment: .leading).frame(maxWidth: .infinity)
        }
        .task(id: model.recentProjectPaths) { projectShortCounts = await Self.shortCounts(model.recentProjectPaths) }
        .alert("Rename project", isPresented: Binding(get: { renameProjectPath != nil }, set: { if !$0 { renameProjectPath = nil } })) {
            TextField("Project name", text: $renameText)
            Button("Rename") {
                if let path = renameProjectPath { model.renameProject(at: path, to: renameText) }
                renameProjectPath = nil
            }
            .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) { renameProjectPath = nil }
        }
        .confirmationDialog("Move this project to the Trash?", isPresented: Binding(get: { deleteProjectPath != nil }, set: { if !$0 { deleteProjectPath = nil } }), titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) {
                if let path = deleteProjectPath { model.deleteProject(at: path) }
                deleteProjectPath = nil
            }
            Button("Cancel", role: .cancel) { deleteProjectPath = nil }
        } message: {
            Text("Its Shorts, exports and imported video go to the Trash. You can restore the project from there.")
        }
        .sheet(item: $statsProject) { project in ProjectStatsView(path: project.path) }
    }
    func beginRename(_ path: String) {
        let stored = try? ProjectStore(root: URL(fileURLWithPath: path)).load(ProjectData.self, key: "project")
        renameText = stored?.displayTitle ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        renameProjectPath = path
    }
    func projectGrid(_ paths: [String]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 12)], alignment: .leading, spacing: 14) {
            ForEach(paths, id: \.self) { path in
                RecentProjectCard(path: path, revision: model.projectListRevision) { model.open(URL(fileURLWithPath: path)) }
                    .contextMenu {
                        Button { beginRename(path) } label: { Label("Rename…", systemImage: "pencil") }
                        Button { statsProject = ProjectPath(path: path) } label: { Label("Show stats", systemImage: "chart.bar") }
                        Divider()
                        Button(role: .destructive) { deleteProjectPath = path } label: { Label("Move to Trash", systemImage: "trash") }
                    }
            }
        }
    }
    /// How many Shorts each project has, read off the main thread.
    nonisolated static func shortCounts(_ paths: [String]) async -> [String: Int] {
        await Task.detached(priority: .utility) {
            var counts: [String: Int] = [:]
            for path in paths {
                guard let store = try? ProjectStore(root: URL(fileURLWithPath: path)),
                      let project = try? store.load(ProjectData.self, key: "project") else { continue }
                counts[path] = project.segments.count
            }
            return counts
        }.value
    }
    var creationModes: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 8) {
                Text("What do you want Prism to create?").font(Prism.display(36))
                Text("Choose a starting point. Your media stays inside your Prism library.").font(Prism.text(16)).foregroundStyle(Prism.textSecondary)
            }
            HStack(spacing: 18) {
                creationCard(
                    icon: "rectangle.portrait.and.arrow.forward",
                    eyebrow: "Long → short",
                    title: "Long video into a Short",
                    detail: "Find a strong moment, crop it vertically, add captions, and export.",
                    action: { model.startLongVideoToShort() }
                )
                creationCard(
                    icon: "photo.on.rectangle.angled",
                    eyebrow: "Video + photos → short",
                    title: "Photos and videos into a Short",
                    detail: "Turn a collection of moments into a polished short-form story.",
                    comingSoon: true,
                    action: {}
                )
                creationCard(
                    icon: "rectangle.stack.badge.play",
                    eyebrow: "Video + photos → long",
                    title: "Photos and videos into a long video",
                    detail: "Build a longer story from your clips, photos, audio, and music.",
                    comingSoon: true,
                    action: {}
                )
            }
            Spacer()
            Button { model.screen = .home } label: { Label("Back to Home", systemImage: "chevron.left") }
                .buttonStyle(.plain).pointerFeedback().foregroundStyle(Prism.textSecondary)
        }
        .padding(38)
        .frame(maxWidth: 1200, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity)
    }
    var sourceImport: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 8) {
                    Text(model.shortsSource == nil ? "Step 1 of 4 · Choose video"
                         : choosingCaptions ? "Step 3 of 4 · Choose captions" : "Step 2 of 4 · Set up Shorts")
                        .font(Prism.text(12, .medium)).foregroundStyle(Prism.textSecondary)
                    Text(model.shortsSource == nil ? "Add your long video"
                         : choosingCaptions ? "Choose your captions" : "Choose your Short settings")
                        .font(Prism.display(36))
                    Text(model.shortsSource == nil ? "Upload a video first. Then choose clip lengths and which part to analyze."
                         : choosingCaptions ? "Pick how speech appears on your Shorts. You can change it for each Short in the editor."
                         : "Your video is ready. Choose how to turn it into Shorts.")
                        .font(Prism.text(16)).foregroundStyle(Prism.textSecondary)
                }
                if let video = model.shortsSource, choosingCaptions {
                    captionChoice
                    HStack {
                        Button { choosingCaptions = false } label: { Label("Back to settings", systemImage: "chevron.left") }
                            .controlSize(.large).pointerFeedback()
                        Spacer()
                        Button("Analyze and create Shorts") { model.continueImport() }
                            .buttonStyle(.prismPrimary).pointerFeedback()
                            .disabled(model.isBusy || model.customRangeError != nil)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Captions for \(video.name)")
                } else if let video = model.shortsSource {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(video.name, systemImage: "checkmark.circle.fill").foregroundStyle(Prism.accent)
                        Text("Video duration: \(clock(video.duration)) · \(String(format: "%.2f", video.duration / 60)) minutes")
                            .foregroundStyle(Prism.textSecondary)
                        Button("Choose a different video") { model.importVideo() }.pointerFeedback()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(18)
                    .background(Prism.surface1, in: RoundedRectangle(cornerRadius: 16))
                    shortsConfiguration
                    Button { choosingCaptions = true } label: { Label("Next: Choose captions", systemImage: "chevron.right") }
                        .buttonStyle(.prismPrimary).pointerFeedback()
                        .disabled(model.isBusy || model.customRangeError != nil)
                } else {
                    videoUploadControls
                }
                Button { model.screen = .home } label: { Label("Back to Home", systemImage: "chevron.left") }
                    .buttonStyle(.plain).pointerFeedback().foregroundStyle(Prism.textSecondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(model.isBusy)
            .padding(30).frame(maxWidth: 920, alignment: .top).frame(maxWidth: .infinity)
        }
        .onAppear {
            choosingCaptions = false
            if model.customEndMinutes.isEmpty, let video = model.shortsSource { model.resetSourceRange(for: video) }
        }
        .onChange(of: model.selection) { _, _ in
            choosingCaptions = false
            if let video = model.shortsSource { model.resetSourceRange(for: video) }
        }
    }
    var shortsConfiguration: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text("Shorts settings").font(Prism.text(12, .medium)).foregroundStyle(Prism.textSecondary)
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 7) {
                        Label("How many", systemImage: "square.stack.3d.up")
                            .font(Prism.text(12)).foregroundStyle(Prism.textSecondary)
                        Stepper("\(model.shortCount) Shorts", value: $model.shortCount, in: 1...10)
                            .font(Prism.text(13, .medium))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 7) {
                        Label("Approx. length", systemImage: "clock")
                            .font(Prism.text(12)).foregroundStyle(Prism.textSecondary)
                        Picker("Approximate Short length", selection: $model.shortDuration) {
                            ForEach([15.0, 30.0, 45.0, 60.0], id: \.self) { seconds in
                                Text("\(Int(seconds)) seconds").tag(seconds)
                            }
                        }
                        .labelsHidden().pickerStyle(.menu)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 7) {
                        Label("Take clips from", systemImage: "timeline.selection")
                            .font(Prism.text(12)).foregroundStyle(Prism.textSecondary)
                        Picker("Choose video section", selection: $model.shortSourceRegion) {
                            ForEach(ShortMaker.SourceRegion.allCases) { region in
                                Text(region.title).tag(region)
                            }
                        }
                        .labelsHidden().pickerStyle(.menu)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if model.shortSourceRegion == .custom {
                    customRangeFields
                }
                Text("Prism will analyze frames and available speech, then suggest up to \(model.shortCount) distinct moments of about \(Int(model.shortDuration)) seconds in the \(model.shortSourceRegion.title.lowercased()). Review every pick before exporting.")
                    .font(Prism.text(12)).foregroundStyle(Prism.textSecondary)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Prism.surface1, in: RoundedRectangle(cornerRadius: 16))

    }
    var captionChoice: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                captionCard(.classic, title: "Simple", detail: "White text with a black outline. No background.")
                captionCard(.viral, title: "Viral highlight", detail: "Same look. Each spoken word turns yellow as it is said.")
            }
            if model.shortCaptionStyle == .viral {
                Text("Highlights follow speech timing. If a clip has no reliable word timing, its captions appear without highlights.")
                    .font(Prism.text(12)).foregroundStyle(Prism.textSecondary)
            }
        }
    }
    func captionCard(_ style: CaptionStyle, title: String, detail: String) -> some View {
        let selected = model.shortCaptionStyle == style
        return Button { model.shortCaptionStyle = style } label: {
            VStack(alignment: .leading, spacing: 12) {
                CaptionStyleSample(highlight: style == .viral)
                    .frame(maxWidth: .infinity).frame(height: 120)
                    .background(Color.gray.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                Label(title, systemImage: selected ? "checkmark.circle.fill" : "circle").font(Prism.text(14, .medium))
                Text(detail).font(Prism.text(12)).foregroundStyle(Prism.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Prism.surface2 : Prism.surface1, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(selected ? Color.accentColor : .clear, lineWidth: 2))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain).pointerFeedback()
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
    var customRangeFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Start (minutes)").font(Prism.text(12)).foregroundStyle(Prism.textSecondary)
                    TextField("Start in minutes", text: $model.customStartMinutes).textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading) {
                    Text("End (minutes)").font(Prism.text(12)).foregroundStyle(Prism.textSecondary)
                    TextField("End in minutes", text: $model.customEndMinutes).textFieldStyle(.roundedBorder)
                }
            }
            if let error = model.customRangeError {
                Label(error, systemImage: "exclamationmark.circle").font(Prism.text(12)).foregroundStyle(Prism.amber)
            } else if let video = model.shortsSource,
                      let range = try? model.shortSourceRegion.interval(videoDuration: video.duration,
                          customStart: model.minuteSeconds(model.customStartMinutes), customEnd: model.minuteSeconds(model.customEndMinutes)) {
                Text("Analyze \(clock(range.start)) to \(clock(range.end)) · \(clock(range.end - range.start)) selected")
                    .font(Prism.text(12)).foregroundStyle(Prism.textSecondary)
            }
        }
    }
    var videoUploadControls: some View {
        VStack(spacing: 20) {
            VStack(spacing: 18) {
                Image(systemName: isDropTarget ? "arrow.down.circle.fill" : "arrow.down.doc.fill")
                    .font(Prism.text(58)).foregroundStyle(Prism.text)
                Text(isDropTarget ? "Drop to import" : "Drag and drop your video here").font(Prism.display(20))
                Text("MOV, MP4, M4V, or AVI").font(Prism.text(12)).foregroundStyle(Prism.textSecondary)
                Button("Browse files") { model.importVideo() }.buttonStyle(.prismPrimary).pointerFeedback()
            }
            .frame(maxWidth: .infinity, minHeight: 270)
            .background(isDropTarget ? Prism.accent.opacity(0.12) : Prism.surface1, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(style: StrokeStyle(lineWidth: 2, dash: [10, 8])).foregroundStyle(isDropTarget ? Prism.accent : Prism.border))
            .dropDestination(for: URL.self, action: { urls, _ in
                guard let url = urls.first else { return false }
                model.importSource(url)
                return true
            }, isTargeted: { isDropTarget = $0 })
            VStack(alignment: .leading, spacing: 6) {
                Text("Or paste a file path").font(Prism.text(12, .medium)).foregroundStyle(Prism.textSecondary)
                HStack(spacing: 10) {
                    TextField("/Users/you/Movies/my-video.mp4", text: $model.sourcePath)
                        .textFieldStyle(.plain).font(Prism.mono(13)).padding(13)
                        .background(Prism.surface2, in: RoundedRectangle(cornerRadius: 12))
                        .onSubmit { model.importFromPath() }
                    Button("Import path") { model.importFromPath() }
                        .buttonStyle(.prismPrimary)
                        .pointerFeedback()
                        .disabled(model.sourcePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text("Prism copies the selected video into your private Prism library.").font(Prism.text(12)).foregroundStyle(Prism.textSecondary)
            }

        }
    }
    func creationCard(icon: String, eyebrow: String, title: String, detail: String, comingSoon: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Image(systemName: icon).font(Prism.text(32)).foregroundStyle(Prism.text)
                    Spacer()
                    if comingSoon {
                        Text("Coming soon").font(Prism.text(11, .medium)).padding(.horizontal, 9).padding(.vertical, 5)
                            .background(Prism.surface2, in: Capsule()).foregroundStyle(Prism.textSecondary)
                    } else {
                        Image(systemName: "arrow.up.right").foregroundStyle(Prism.textSecondary)
                    }
                }
                Spacer()
                Text(eyebrow).font(Prism.text(12, .medium)).foregroundStyle(Prism.textSecondary)
                Text(title).font(Prism.display(24)).multilineTextAlignment(.leading)
                Text(detail).font(Prism.text(13)).foregroundStyle(Prism.textSecondary).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
            .frame(maxWidth: .infinity, minHeight: 330, alignment: .leading)
            .background(
                Prism.surface1,
                in: RoundedRectangle(cornerRadius: 16)
            )
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Prism.border, lineWidth: 1))
            .opacity(comingSoon ? 0.72 : 1)
        }
        .buttonStyle(.plain).pointerFeedback()
        .disabled(comingSoon)
    }
    var selectedMedia: MediaItem? { model.project?.media.first(where: { $0.id == model.selection }) }

    func clock(_ seconds: Double) -> String { String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60) }
}

private struct ProjectPath: Identifiable {
    let path: String
    var id: String { path }
}

private struct ProjectStats: Sendable {
    var title: String
    var created: Date
    var shortCount: Int
    var shortsSeconds: Double
    var exportCount: Int
    var sourceName: String?
    var sourceSeconds: Double?
    var resolution: String?
    var bytes: Int64
}

/// Read-only facts about one project, opened from its right-click menu on Home.
private struct ProjectStatsView: View {
    let path: String
    @Environment(\.dismiss) private var dismiss
    @State private var stats: ProjectStats?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let stats {
                Text(stats.title).font(Prism.display(20)).lineLimit(2)
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                    row("Shorts", "\(stats.shortCount)")
                    row("Total length of Shorts", Self.clock(stats.shortsSeconds), mono: true)
                    row("Exported videos", "\(stats.exportCount)")
                    if let name = stats.sourceName { row("Source video", name) }
                    if let seconds = stats.sourceSeconds { row("Source length", Self.clock(seconds), mono: true) }
                    if let resolution = stats.resolution { row("Resolution", resolution) }
                    row("Created", stats.created.formatted(date: .abbreviated, time: .shortened))
                    row("Size on disk", ByteCountFormatter.string(fromByteCount: stats.bytes, countStyle: .file))
                }
            } else if failed {
                Text("Could not read this project.").foregroundStyle(Prism.textSecondary)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            }
            HStack {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                    .buttonStyle(.prismSecondary)
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.prismPrimary).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
        .font(Prism.text(13))
        .foregroundStyle(Prism.text)
        .background(Prism.surface1)
        .task { await load() }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String, mono: Bool = false) -> some View {
        GridRow {
            Text(label).foregroundStyle(Prism.textSecondary)
            Text(value).font(mono ? Prism.mono(13) : Prism.text(13, .medium)).lineLimit(1).truncationMode(.middle)
        }
    }

    private func load() async {
        let projectPath = path
        let loaded = await Task.detached(priority: .utility) { () -> ProjectStats? in
            let root = URL(fileURLWithPath: projectPath)
            guard let project = try? ProjectStore(root: root).load(ProjectData.self, key: "project") else { return nil }
            let video = project.media.first(where: { $0.kind == "video" })
            let manager = FileManager.default
            let exports = (try? manager.contentsOfDirectory(at: root.appendingPathComponent("Exports"), includingPropertiesForKeys: nil)) ?? []
            var bytes: Int64 = 0
            if let files = manager.enumerator(at: root, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) {
                while let file = files.nextObject() as? URL {
                    bytes += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
                }
            }
            return ProjectStats(title: project.displayTitle, created: project.created, shortCount: project.segments.count,
                                shortsSeconds: project.segments.reduce(0) { $0 + $1.duration },
                                exportCount: exports.filter { $0.pathExtension.lowercased() == "mp4" }.count,
                                sourceName: video?.name, sourceSeconds: video?.duration,
                                resolution: video.flatMap { $0.width > 0 ? "\($0.width) × \($0.height)" : nil }, bytes: bytes)
        }.value
        stats = loaded
        failed = loaded == nil
    }

    private static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60) }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct RecentProjectSummary: Sendable {
    var title: String
    var duration: Double?
    var shortCount: Int
    var created: Date?
    var poster: CGImage?
}

/// One project as a compact row: a frame from its first Short, its title, Short count and creation date.
/// Projects cut from the same video share a source, so the source's thumbnail and name can't tell them apart.
private struct RecentProjectCard: View {
    let path: String
    /// Changes when the project is renamed from Home, so the card reloads.
    var revision = 0
    let action: () -> Void
    @State private var summary: RecentProjectSummary?

    private var fallbackTitle: String {
        URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }

    private var details: String {
        guard let summary else { return " " }
        let shorts = summary.shortCount == 0 ? "No Shorts yet" : summary.shortCount == 1 ? "1 Short" : "\(summary.shortCount) Shorts"
        guard let created = summary.created else { return shorts }
        return shorts + " · " + created.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                ZStack {
                    if let poster = summary?.poster {
                        Image(decorative: poster, scale: 1).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle().fill(Prism.surface2)
                        Image(systemName: "play.rectangle.fill").font(Prism.text(34)).foregroundStyle(Prism.textSecondary)
                    }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .bottomTrailing) {
                    if let duration = summary?.duration {
                        Text(Self.clock(duration))
                            .font(Prism.display(10).monospacedDigit()).foregroundStyle(Prism.paper)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 8))
                            .padding(6)
                    }
                }
                Text(summary?.title ?? fallbackTitle)
                    .font(Prism.text(12, .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .topLeading)
                Text(details)
                    .font(Prism.text(9, .medium))
                    .foregroundStyle(Prism.textSecondary)
                    .lineLimit(1)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Prism.surface1, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .pointerFeedback()
        .accessibilityLabel("Open \(summary?.title ?? fallbackTitle), \(details)")
        .task(id: "\(path)#\(revision)") { await loadSummary() }
    }

    private static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60) }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func loadSummary() async {
        let projectPath = path
        let loaded = await Task.detached(priority: .utility) { () -> RecentProjectSummary in
            let root = URL(fileURLWithPath: projectPath)
            guard let store = try? ProjectStore(root: root),
                  let project = try? store.load(ProjectData.self, key: "project") else {
                return RecentProjectSummary(title: root.deletingPathExtension().lastPathComponent, duration: nil, shortCount: 0, created: nil, poster: nil)
            }
            let video = project.media.first(where: { $0.kind == "video" })
            let firstShort = project.segments.first
            var poster: CGImage?
            if let video {
                // Moved projects keep their media inside the project folder.
                let stored = URL(fileURLWithPath: video.path)
                let source = FileManager.default.fileExists(atPath: stored.path) ? stored
                    : root.appendingPathComponent("Media").appendingPathComponent(stored.lastPathComponent)
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: source))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 480, height: 270)
                let time = firstShort.map { $0.start + min(1, $0.duration / 2) } ?? 1
                poster = try? generator.copyCGImage(at: CMTime(seconds: time, preferredTimescale: 600), actualTime: nil)
            }
            return RecentProjectSummary(title: project.displayTitle, duration: video?.duration, shortCount: project.segments.count,
                                        created: project.created, poster: poster)
        }.value
        guard !Task.isCancelled else { return }
        summary = loaded
    }
}

struct RelioPlayerView: NSViewRepresentable {
    let player: AVPlayer
    /// The Short being previewed; its export caption layers are drawn over the live video.
    var captionSegment: EditSegment? = nil
    var showsControls = false
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = showsControls ? .floating : .none
        view.videoGravity = .resizeAspect
        view.player = player
        attachCaptions(to: view)
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player {
            view.player = player
            attachCaptions(to: view)
        }
    }
    private func attachCaptions(to view: AVPlayerView) {
        guard let overlay = view.contentOverlayView else { return }
        overlay.subviews.forEach { $0.removeFromSuperview() }
        guard let item = player.currentItem, let segment = captionSegment,
              let captions = ShortMaker.captionLayer(for: segment) else { return }
        let captionView = PreviewCaptionView(item: item, captions: captions)
        captionView.frame = overlay.bounds
        captionView.autoresizingMask = [.width, .height]
        overlay.addSubview(captionView)
    }
}

/// Export's caption layers over the live preview: synced to playback and scaled to the displayed 9:16 video.
final class PreviewCaptionView: NSView {
    private let sync: AVSynchronizedLayer
    private let captions: CALayer
    init(item: AVPlayerItem, captions: CALayer) {
        sync = AVSynchronizedLayer(playerItem: item)
        self.captions = captions
        super.init(frame: .zero)
        wantsLayer = true
        captions.anchorPoint = .zero
        sync.addSublayer(captions)
        layer?.addSublayer(sync)
    }
    required init?(coder: NSCoder) { nil }
    // Clicks go through to the player controls.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        let video = AVMakeRect(aspectRatio: CGSize(width: 1080, height: 1920), insideRect: bounds)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sync.frame = video
        captions.position = .zero
        captions.setAffineTransform(CGAffineTransform(scaleX: video.width / 1080, y: video.height / 1920))
        CATransaction.commit()
    }
}

