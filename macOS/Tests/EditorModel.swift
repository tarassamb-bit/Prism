import Foundation
import AVFoundation
import AppKit

@main struct EditorModelTest {
    @MainActor static func main() async throws {
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RelioEditorTest-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        guard let media = await MediaEngine.inspect(source, thumbnailDirectory: root) else { fatalError("Fixture unavailable") }
        let store = try ProjectStore(root: root)
        precondition(AppModel.exportFileName(title: "Oil: \"what's\" next?/now") == "Oil what's next now"
                     && AppModel.exportFileName(title: " .. ") == nil && AppModel.exportFileName(title: nil) == nil
                     && AppModel.exportFileName(title: String(repeating: "a", count: 200))?.count == 80,
                     "Export names must drop path and Finder-unsafe characters")
        print("PASS export file names come from Short titles")
        precondition(AppModel.failureKind(GeminiSelection.Failure.request(503)) == .temporary
                     && AppModel.failureKind(GeminiSelection.StageFailure(stage: "Audio transcription at 3m 0s", underlying: GeminiSelection.Failure.request(503))) == .temporary
                     && AppModel.failureKind(URLError(.notConnectedToInternet)) == .temporary
                     && AppModel.failureKind(GeminiSelection.Failure.request(403)) == .settings
                     && AppModel.failureKind(GeminiSelection.Failure.noStrongClips) == .noMoments
                     && AppModel.failureKind(ShortMaker.Failure.noVideo) == .other,
                     "A busy server must never be reported as a problem with the video or its range")
        print("PASS failed runs are explained by cause: busy server, settings, range or other")
        let model = AppModel()
        // No saved key: previews must not track subjects with the person's real Gemini key.
        model.didLoadGeminiKeyFromKeychain = true
        let folderModel = AppModel()
        folderModel.recentProjectPaths = ["/p/one.relio", "/p/two.relio"]
        let podcasts = folderModel.createFolder(named: "  Podcasts  ")!, other = folderModel.createFolder(named: "Other")!
        precondition(folderModel.createFolder(named: "   ") == nil)
        folderModel.moveProject("/p/one.relio", toFolder: podcasts)
        folderModel.moveProject("/p/one.relio", toFolder: other)
        folderModel.moveProject("not a project", toFolder: other)
        precondition(folderModel.projectFolders.first { $0.id == podcasts }?.projectPaths.isEmpty == true
                     && folderModel.projectFolders.first { $0.id == other }?.projectPaths == ["/p/one.relio"],
                     "A project lives in one folder at a time, and unknown drops are ignored")
        folderModel.renameFolder(other, to: "Satellite")
        folderModel.deleteFolder(other)
        precondition(folderModel.projectFolders.map(\.name) == ["Podcasts"] && folderModel.recentProjectPaths.count == 2,
                     "Deleting a folder keeps its projects")
        folderModel.deleteFolder(podcasts)
        print("PASS Home folders: create, move, one folder per project, rename, delete keeps projects")
        model.startLongVideoToShort()
        precondition(model.screen == .importSource && model.projectURL == nil && model.shortsSource == nil,
                     "Starting upload must not create an empty project or show previous footage")
        model.screen = .editor
        model.store = store
        model.projectURL = root
        model.project = ProjectData(name: "Editor test", media: [media])
        model.selection = media.id
        model.resetSourceRange(for: media)
        model.shortSourceRegion = .custom
        precondition(model.customRangeError == nil)
        model.customEndMinutes = "1000"
        precondition(model.customRangeError != nil, "Custom end must not exceed the imported video")
        model.makeConfiguredShorts()
        precondition(!model.isBusy && model.project?.segments.isEmpty == true, "Invalid range must block generation before AI calls")
        model.customEndMinutes = "NaN"
        precondition(model.customRangeError != nil)
        model.resetSourceRange(for: media)
        model.makeConfiguredShorts()
        precondition(!model.isBusy && model.generationError?.kind == .settings, "A missing key must open the Settings popup, not \"No Shorts found\"")
        model.generationError = nil
        print("PASS imported duration initializes the custom range and invalid minutes block generation")
        let generated = EditSegment(mediaID: media.id, start: 0, duration: 1, fitToFrame: true, suggestedTitle: "First story", selectionReason: "A specific hook and payoff.", captionNotice: "Sentence timing notice", captionStyle: .viral)
        _ = try model.appendGeneratedShorts([generated])
        let distinct = EditSegment(mediaID: media.id, start: 2, duration: 1)
        let appended = try model.appendGeneratedShorts([generated, distinct, distinct])
        precondition(appended.count == 1 && model.project?.segments.count == 2 && model.project?.segments.first?.id == generated.id,
                     "Generation must retain earlier work and reject duplicate candidates")
        let persisted = try store.load(ProjectData.self, key: "project")
        precondition(persisted?.segments.count == 2 && model.editHistory.last?.count == 1)
        precondition(persisted?.segments.first?.suggestedTitle == "First story" && persisted?.segments.first?.fitToFrame == true &&
                     persisted?.segments.first?.captionNotice == "Sentence timing notice" && persisted?.segments.first?.captionStyle == .viral)
        let undoCount = model.editHistory.count
        do {
            _ = try model.appendGeneratedShorts([EditSegment(mediaID: media.id, start: .nan, duration: 1)])
            preconditionFailure("Unencodable generated edits must not be committed")
        } catch { }
        precondition(model.project?.segments.count == 2 && model.editHistory.count == undoCount,
                     "Failed persistence must restore both clips and undo state")
        model.project?.segments = []
        model.editHistory = []
        try model.save()
        print("PASS generated batches preserve previous edits, deduplicate and persist undo history")
        // Manual clips keep their saved framing; this does not make API calls.
        model.shortDuration = 3
        model.addManualClip()
        await waitForPreview(model)
        precondition(model.project?.segments.count == 1 && model.activeSegment?.duration == 3)
        let first = model.activeSegment!.id
        model.addManualClip()
        await waitForPreview(model)
        let second = model.activeSegment!.id
        precondition(first != second && model.project?.segments.count == 2)
        model.updateSelectedEdit(start: 0.5, duration: 2, caption: "Inspector test", captionStart: 0.5, captionDuration: 1)
        await waitForPreview(model)
        precondition(model.project?.segments.first?.duration == 3)
        precondition(model.activeSegment?.start == 0.5 && model.activeSegment?.caption == "Inspector test")
        model.updateSelectedEdit(start: 0.5, duration: 2, caption: "Inspector test", captionStart: 0.5, captionDuration: 1, cropPosition: 0.85)
        precondition(abs((model.activeSegment?.cropPosition ?? 0) - 0.85) < 0.001, "Crop position was not applied")
        let saved = try store.load(ProjectData.self, key: "project")
        precondition(saved?.segments.last?.caption == "Inspector test" && abs((saved?.segments.last?.cropPosition ?? 0) - 0.85) < 0.001,
                     "Crop position was not persisted")
        // Focus points land where they are clicked despite the tracking offset, and edits keep scene cuts.
        let focusIndex = model.project!.segments.firstIndex { $0.id == model.activeSegment!.id }!
        model.project!.segments[focusIndex].cropKeyframes = [CropKeyframe(time: 0, position: 0.5),
                                                             CropKeyframe(time: 1, position: 0.2, isSceneCut: true), CropKeyframe(time: 2, position: 0.2)]
        model.adjustCropKeyframe(from: 1.5, to: 1.5, position: 0.6, insert: true)
        await waitForPreview(model)
        let focused = model.activeSegment!
        let clicked = focused.cropKeyframes?.first { abs($0.time - 1.5) < 0.01 }
        precondition(clicked.map { abs($0.position + (focused.cropPosition ?? 0.5) - 0.5 - 0.6) < 0.001 } == true,
                     "A focus point must show where it was clicked, offset included")
        precondition(focused.cropKeyframes?.contains { $0.time == 1 && $0.isSceneCut == true } == true, "Adding a focus point must keep scene cuts")
        print("PASS focus points honor the tracking offset and keep scene cuts")
        let legacySegment = try JSONDecoder().decode(EditSegment.self, from: Data("{\"mediaID\":\"\(media.id.uuidString)\",\"duration\":3}".utf8))
        precondition(legacySegment.cropPosition == 0.5, "Legacy project crop position should default to center")
        model.updateSelectedEdit(start: -1, duration: 2, caption: "Invalid", captionStart: 0, captionDuration: 1)
        precondition(model.activeSegment?.caption == "Inspector test")
        // Captions tab: the style survives clip edits; text edits keep timing and drop cleared lines.
        let captionedID = model.activeSegment!.id
        let captionedIndex = model.project!.segments.firstIndex { $0.id == captionedID }!
        model.project!.segments[captionedIndex].captions = [TimedCaption(text: "hello there", start: 0, duration: 0.5),
                                                            TimedCaption(text: "remove me", start: 0.5, duration: 0.5)]
        model.setSelectedCaptionStyle(.viral)
        await waitForPreview(model)
        model.updateSelectedEdit(start: 0.5, duration: 2, caption: "Inspector test", captionStart: 0.5, captionDuration: 1, cropPosition: 0.85)
        await waitForPreview(model)
        precondition(model.activeSegment?.captionStyle == .viral, "Clip edits must not reset the caption style")
        model.updateSelectedCaptionTexts(["Hello there!", "  "])
        await waitForPreview(model)
        precondition(model.activeSegment?.captions == [TimedCaption(text: "Hello there!", start: 0, duration: 0.5)],
                     "Caption text edits must keep timing and remove cleared lines")
        let captionSaved = try store.load(ProjectData.self, key: "project")?.segments.first { $0.id == captionedID }
        precondition(captionSaved?.captionStyle == .viral && captionSaved?.captions?.map(\.text) == ["Hello there!"],
                     "Caption style and text must be persisted")
        print("PASS captions tab: style survives clip edits, text edits keep timing and persist")
        model.toggleSelectedAudio()
        await waitForPreview(model)
        precondition(model.activeSegment?.isMuted == true)
        model.setFraming(fit: true)
        await waitForPreview(model)
        precondition(model.activeSegment?.fitToFrame == true)
        model.undoFromEditor()
        await waitForPreview(model)
        precondition(model.project?.segments.last?.fitToFrame != true && model.activeSegment?.id == second)
        model.selectPreview(second)
        await waitForPreview(model)
        model.seekPreview(to: 0.75)
        try await Task.sleep(for: .milliseconds(300))
        precondition(abs((model.player?.currentTime().seconds ?? -10) - 0.75) < 0.1)
        model.isBusy = true
        model.addManualClip()
        model.toggleSelectedAudio()
        model.undoFromEditor()
        precondition(model.project?.segments.count == 2 && model.activeSegment?.isMuted == true)
        model.isBusy = false
        model.chooseExport()
        precondition(model.exportChoice?.shortIDs.count == 2 && model.exportChoice?.includeSource == false
                     && model.exportChoice?.folder.path.contains("/Downloads/Prism/") == true, "Export must default to every Short in Downloads › Prism")
        model.chooseExport(only: second)
        precondition(model.exportChoice?.shortIDs == [second], "Export this Short must tick only that Short")
        // A folder that can't be created keeps the card open with the reason, and nothing starts.
        try Data("not a folder".utf8).write(to: root.appendingPathComponent("blocker"))
        model.chooseExport()
        model.exportChoice?.folder = root.appendingPathComponent("blocker").appendingPathComponent("Exports")
        model.export(model.exportChoice!)
        precondition(!model.isBusy && model.exportChoice?.error?.contains("Could not use this folder") == true,
                     "An unusable export folder must be explained on the card")
        model.chooseExport()
        model.exportChoice?.folder = root.appendingPathComponent("Exports")
        model.exportChoice?.includeSource = true
        model.export(model.exportChoice!)
        precondition(model.exportChoice == nil, "The export card must close when exporting starts")
        let deadline = Date().addingTimeInterval(45)
        while model.isBusy && Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        precondition(!model.isBusy && model.message.contains("Exported"), model.message)
        let outputs = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Exports"), includingPropertiesForKeys: nil)
        precondition(outputs.filter { $0.pathExtension == "mp4" }.count == 2 && outputs.contains { $0.lastPathComponent == source.lastPathComponent },
                     "Both Shorts and the main video must be exported: \(outputs.map(\.lastPathComponent))")
        for output in outputs {
            let asset = AVURLAsset(url: output)
            let duration = try await asset.load(.duration).seconds
            precondition(duration > 0)
            if output.lastPathComponent.contains("Short 2") {
                let audio = try await asset.loadTracks(withMediaType: .audio)
                precondition(audio.isEmpty, "Muted clip contains audio")
            } else if media.hasAudio == true {
                let audio = try await asset.loadTracks(withMediaType: .audio)
                precondition(!audio.isEmpty, "Source audio was lost")
            }
        }
        model.player?.pause()
        model.player = nil
        print("PASS editor actions: add clips, select second clip, trim/text, crop position persistence and legacy default, reject invalid range, mute, framing, undo, seek, busy guards, save/reopen, export both clips")
        // Renaming the open project changes it in memory too, so a later save keeps the new name.
        let revision = model.projectListRevision
        model.renameProject(at: root.path, to: "  My oil Shorts  ")
        try model.save()
        precondition(model.project?.displayTitle == "My oil Shorts" && model.projectListRevision == revision + 1,
                     "Rename must trim the name and refresh the project card")
        let renamed = try store.load(ProjectData.self, key: "project")
        precondition(renamed?.displayTitle == "My oil Shorts", "Rename must persist")
        model.renameProject(at: root.path, to: "   ")
        precondition(model.project?.title == "My oil Shorts", "A blank name must not replace the project name")
        print("PASS rename the open project: trimmed, saved, kept after later saves, blank names ignored")
        precondition(model.lastExportFolder != nil)
        model.open(root)
        precondition(model.project != nil && model.lastExportFolder == nil, "Opening a project must forget the previous project's export folder")
        print("PASS opening a project resets where Exports points")
        print("This tests model actions directly; it does not automate desktop clicks.")
    }
    @MainActor static func waitForPreview(_ model: AppModel) async {
        let deadline = Date().addingTimeInterval(30)
        while model.isPreviewLoading && Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        precondition(!model.isPreviewLoading && model.previewError == nil, model.previewError ?? "Preview timed out")
    }
}
