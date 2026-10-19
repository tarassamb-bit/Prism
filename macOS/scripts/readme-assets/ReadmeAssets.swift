import AppKit
import AVFoundation
import AVKit
import SwiftUI

/// Builds the README images from a generated demo library: the real app views, the real Short renderer, and brand art.
/// Run it through scripts/readme-assets.sh, which points the home folder at a throwaway directory.
@main struct ReadmeAssets {
    struct DemoShort {
        enum Layout { case fill(Double), fit, split([Double]) }
        let title: String
        let start: Double
        let duration: Double
        let layout: Layout
        let style: CaptionStyle
        let speech: [String]
        let reason: String
    }
    struct DemoProject {
        let title: String
        let file: String
        let scenes: [(time: Double, scene: DemoFootage.Scene)]
        let duration: Double
        let hoursAgo: Double
        let shorts: [DemoShort]
        /// Source ranges rendered for README images besides the Shorts themselves.
        var extraRendered: [ClosedRange<Double>] = []
    }

    static let podcastShorts = [
        DemoShort(title: "The edit that doubled our watch time", start: 186, duration: 31.4, layout: .split([0.276, 0.724]), style: .podcast,
                  speech: ["We cut the first thirty seconds of every episode.", "Watch time doubled in a month.", "Nobody missed the intro."],
                  reason: "Opens on a concrete result, shows the change, and ends on the payoff."),
        DemoShort(title: "Why we stopped chasing trends", start: 604.2, duration: 29.8, layout: .fill(0.5), style: .viral,
                  speech: ["Most creators chase trends too late.", "The trend is gone before the edit is done.", "Make the thing only you can make."],
                  reason: "A strong claim in the first line and a quotable ending that lands on its own."),
        DemoShort(title: "The three-second hook test", start: 1190.5, duration: 34.2, layout: .split([0.276, 0.724]), style: .boldCaps,
                  speech: ["Here is the test we run on every Short.", "Mute it and watch three seconds.", "Would you keep watching?"],
                  reason: "A clear promise up front and a test anyone can try, finished in one breath."),
        DemoShort(title: "What nobody tells you about consistency", start: 1502, duration: 26.5, layout: .fill(0.5), style: .highlightBox,
                  speech: ["Consistency is not posting every day.", "It is keeping one promise to your viewers."],
                  reason: "Reframes a familiar idea in the opening line and resolves it in the last."),
        DemoShort(title: "Our worst episode taught us the most", start: 2210.4, duration: 38, layout: .split([0.276, 0.724]), style: .classic,
                  speech: ["Our worst episode had four hundred views.", "It taught us more than our best one.", "We finally listened to the comments."],
                  reason: "A surprising number as the hook and a lesson that needs no earlier context.")
    ]

    static let projects: [DemoProject] = [
        DemoProject(title: "The long take, episode 42", file: "the-long-take-042.mov",
                    scenes: [(0, .podcast), (600, .podcastCloseLeft), (640, .podcast), (1500, .podcastCloseRight), (1530, .podcast)],
                    duration: 2538, hoursAgo: 2, shorts: podcastShorts, extraRendered: [609...614]),
        DemoProject(title: "Swift concurrency in ten minutes", file: "swift-concurrency.mov", scenes: [(0, .tutorial)], duration: 712, hoursAgo: 26,
                    shorts: [DemoShort(title: "Three lines that rank a whole video", start: 214, duration: 28.6, layout: .fit, style: .classic,
                                       speech: ["Three lines turn a transcript into ranked moments.", "Transcribe, score, and refine."],
                                       reason: "One complete step with its result, readable because the whole screen stays in frame.")]
                    + filler(2, from: 300)),
        DemoProject(title: "A week of trams in Lisbon", file: "lisbon-trams.mov", scenes: [(0, .vlog)], duration: 1087, hoursAgo: 50, shorts: filler(4, from: 60)),
        DemoProject(title: "Any% speedrun, new personal best", file: "speedrun-pb.mov", scenes: [(0, .gaming)], duration: 3821, hoursAgo: 75, shorts: filler(6, from: 120)),
        DemoProject(title: "Why cities glow at night", file: "cities-at-night.mov", scenes: [(0, .explainer)], duration: 866, hoursAgo: 98, shorts: filler(3, from: 40)),
        DemoProject(title: "Pricing your first product", file: "pricing-talk.mov", scenes: [(0, .lecture)], duration: 1665, hoursAgo: 146, shorts: filler(4, from: 90))
    ]

    static func filler(_ count: Int, from start: Double) -> [DemoShort] {
        (0..<count).map { DemoShort(title: "Moment \($0 + 1)", start: start + Double($0) * 120, duration: 30, layout: .fit, style: .classic,
                                    speech: ["A complete moment."], reason: "") }
    }

    @MainActor static func main() async throws {
        let work = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        precondition(support.path.hasPrefix(work.path), "Run scripts/readme-assets.sh: the demo library must stay out of your real one.")
        let domain = ProcessInfo.processInfo.processName
        UserDefaults.standard.removePersistentDomain(forName: domain)
        defer { UserDefaults.standard.removePersistentDomain(forName: domain) }
        let fonts = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: "packaging/Fonts"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "ttf" }
        CTFontManagerRegisterFontURLs(fonts as CFArray, .process, true, nil)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)

        print("Writing demo footage and projects")
        let library = support.appendingPathComponent("Relio/Library/Projects")
        var saved: [(url: URL, data: ProjectData)] = []
        for project in projects { saved.append(try await makeProject(project, in: library)) }
        let podcast = saved[0], tutorial = saved[1], vlog = saved[2]
        let podcastVideo = URL(fileURLWithPath: podcast.data.media[0].path)

        print("Rendering Shorts with the real exporter")
        let renders = work.appendingPathComponent("renders")
        try FileManager.default.createDirectory(at: renders, withIntermediateDirectories: true)
        var shortFrames: [NSImage] = []
        for (index, segment) in podcast.data.segments.enumerated() {
            shortFrames.append(try await frame(of: segment, source: podcastVideo, at: 1.5, in: renders.appendingPathComponent("podcast-\(index).mp4")))
        }
        let fitFrame = try await frame(of: tutorial.data.segments[0], source: URL(fileURLWithPath: tutorial.data.media[0].path), at: 1.5,
                                       in: renders.appendingPathComponent("fit.mp4"))
        var captionTiles: [(image: NSImage, name: String, detail: String)] = []
        for style in CaptionStyle.allCases {
            var segment = EditSegment(mediaID: podcast.data.media[0].id, start: 610, duration: 2.4)
            segment.cropKeyframes = [.init(time: 0, position: 0.5), .init(time: 2.4, position: 0.5)]
            segment.cropTrackingVersion = SubjectFramer.version
            segment.captionStyle = style
            segment.captionPosition = .middle
            let words = timedWords(["This changed how we edit."], from: 0.2, pace: 0.3)
            segment.speechWords = words
            segment.captions = GeminiSelection.captionCues(words)
            let image = try await frame(of: segment, source: podcastVideo, at: 0.95, in: renders.appendingPathComponent("style-\(style.rawValue).mp4"))
            captionTiles.append((crop(image, top: 560, height: 800), style.title, style.detail))
        }

        print("Rendering app screens")
        let model = AppModel()
        model.isGeminiKeySaved = true
        model.screen = .home
        let home = try await capture(appRoot(model), size: NSSize(width: 1440, height: 900), settle: 2.5)

        show(vlog, in: model)
        model.resetSourceRange(for: vlog.data.media[0])
        model.shortCount = 4
        model.shortDuration = 45
        model.screen = .importSource
        model.message = "Your video is ready. Choose how to turn it into Shorts."
        let create = try await capture(appRoot(model), size: NSSize(width: 1440, height: 900), settle: 2)

        show(podcast, in: model)
        model.screen = .editor
        model.message = "Gemini selected 5 complete clip ranges and layouts. Review framing and captions before export."
        let selected = podcast.data.segments[1]
        model.selectPreview(selected.id)
        for _ in 0..<100 where model.player == nil || model.isPreviewLoading { try await Task.sleep(for: .milliseconds(100)) }
        model.player?.pause()
        model.seekPreview(to: 1.5)
        let editorHost = NSHostingView(rootView: appRoot(model))
        let editorRep = try await capture(editorHost, size: NSSize(width: 1440, height: 900), settle: 2.5)
        // Video layers don't draw offscreen; paint the same exported frame into the player, as the live preview shows it.
        let editor = paintPlayer(in: editorRep, host: editorHost, frame: shortFrames[1])

        print("Composing brand images")
        let clips = podcast.data.segments.map { (start: $0.start / podcast.data.media[0].duration, length: $0.duration / podcast.data.media[0].duration) }
        let filmstrip = try await sourceFrames(podcastVideo, times: [30, 300, 615, 900, 1200, 1515, 1800, 2100, 2400])
        try save(try await capture(HeroArt(editor: editor, clips: clips), size: NSSize(width: 1280, height: 660)), width: 1600, to: output.appendingPathComponent("hero.png"))
        try save(try await capture(ScreenArt(screen: editor), size: NSSize(width: 1440, height: 900)), width: 1600, to: output.appendingPathComponent("editor.png"))
        try save(try await capture(ScreenArt(screen: NSImage(cgImage: home.cgImage!, size: NSSize(width: 1440, height: 900))), size: NSSize(width: 1440, height: 900)), width: 1200, to: output.appendingPathComponent("home.png"))
        try save(try await capture(ScreenArt(screen: NSImage(cgImage: create.cgImage!, size: NSSize(width: 1440, height: 900))), size: NSSize(width: 1440, height: 900)), width: 1200, to: output.appendingPathComponent("create.png"))
        try save(try await capture(LayoutsArt(shorts: [
            (shortFrames[1], "Fill", "0:30", "The crop follows the speaker and resets on every camera cut."),
            (fitFrame, "Fit", "0:29", "The whole frame over a blurred fill, for screens, slides and games."),
            (shortFrames[0], "Split", "0:31", "Two speakers stacked, one in each half, captions in between.")
        ]), size: nil), width: 1600, to: output.appendingPathComponent("layouts.png"))
        try save(try await capture(CaptionsArt(tiles: captionTiles), size: nil), width: 1600, to: output.appendingPathComponent("captions.png"))
        try save(try await capture(PipelineArt(filmstrip: filmstrip, clips: clips, shorts: shortFrames), size: nil), width: 1600,
                 to: output.appendingPathComponent("pipeline.png"))
        try save(try await capture(PaletteArt(), size: nil), width: 1600, to: output.appendingPathComponent("brand.png"))
        print("Wrote README images to \(output.path)")
    }

    // MARK: Demo library

    static func makeProject(_ demo: DemoProject, in library: URL) async throws -> (url: URL, data: ProjectData) {
        let folder = library.appendingPathComponent("\(demo.title).relio")
        let media = folder.appendingPathComponent("Media")
        for directory in [media, folder.appendingPathComponent("Exports"), folder.appendingPathComponent("Thumbnails")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let video = media.appendingPathComponent(demo.file)
        let rendered = demo.shorts.map { $0.start - 1...$0.start + $0.duration + 1 } + demo.extraRendered
        try await DemoFootage.write(demo.scenes, duration: demo.duration, dense: rendered, to: video)
        guard let item = await MediaEngine.inspect(video, thumbnailDirectory: folder.appendingPathComponent("Thumbnails")) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let segments = demo.shorts.map { short -> EditSegment in
            var segment = EditSegment(mediaID: item.id, start: short.start, duration: short.duration)
            let words = timedWords(short.speech, from: 0.4, pace: 0.34)
            segment.speechWords = words
            segment.captions = GeminiSelection.captionCues(words)
            segment.captionStyle = short.style
            segment.suggestedTitle = short.title
            segment.selectionReason = short.reason.isEmpty ? nil : short.reason
            segment.cropTrackingVersion = SubjectFramer.version
            switch short.layout {
            case .fill(let position):
                segment.cropKeyframes = [.init(time: 0, position: position), .init(time: short.duration, position: position)]
            case .fit:
                segment.fitToFrame = true
                segment.cropKeyframes = [.init(time: 0, position: 0.5, preserveWholeFrame: true),
                                         .init(time: short.duration, position: 0.5, preserveWholeFrame: true)]
            case .split(let centers):
                segment.splitScreen = true
                segment.splitCenters = centers
                segment.captionPosition = .middle
            }
            return segment
        }
        let data = ProjectData(name: demo.title, media: [item], segments: segments,
                               created: Date.now.addingTimeInterval(-demo.hoursAgo * 3600), title: demo.title)
        try ProjectStore(root: folder).save(data, key: "project")
        return (folder, data)
    }

    /// Word timings at a steady speaking pace, with a short pause after each sentence.
    static func timedWords(_ sentences: [String], from start: Double, pace: Double) -> [TimedSpeechWord] {
        var time = start
        var words: [TimedSpeechWord] = []
        for sentence in sentences {
            for word in sentence.split(separator: " ") {
                let length = pace * 0.6 + Double(word.count) * pace * 0.08
                words.append(.init(text: String(word), start: time, duration: length))
                time += length + 0.05
            }
            time += 0.35
        }
        return words
    }

    @MainActor static func show(_ project: (url: URL, data: ProjectData), in model: AppModel) {
        model.store = try? ProjectStore(root: project.url)
        model.projectURL = project.url
        model.project = project.data
        model.selection = project.data.media.first?.id
    }

    // MARK: Rendering

    @MainActor static func appRoot(_ model: AppModel) -> some View {
        ContentView(model: model)
            .frame(width: 1440, height: 900)
            .preferredColorScheme(.dark)
            .font(Prism.text(13))
            .foregroundStyle(Prism.text)
            .buttonStyle(.prismSecondary)
    }

    @MainActor static func capture<V: View>(_ view: V, size: NSSize?, settle: Double = 0.6) async throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view)
        return try await capture(host, size: size ?? host.fittingSize, settle: settle)
    }

    /// Lays a view out in an offscreen dark window and draws it at the screen's backing scale.
    @MainActor static func capture(_ host: NSView, size: NSSize, settle: Double) async throws -> NSBitmapImageRep {
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -8000, y: -8000))
        window.orderFrontRegardless()
        try await Task.sleep(for: .seconds(settle))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
        host.cacheDisplay(in: host.bounds, to: rep)
        window.orderOut(nil)
        return rep
    }

    /// Paints an exported Short frame into the player area, aspect-fit on black like AVPlayerView.
    @MainActor static func paintPlayer(in rep: NSBitmapImageRep, host: NSView, frame: NSImage) -> NSImage {
        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(rep)
        guard let player = find(AVPlayerView.self, in: host), let cgFrame = frame.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let base = rep.cgImage,
              let context = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { print("Player view not found; editor screen keeps its empty player"); return image }
        let scale = CGFloat(base.width) / host.bounds.width
        let rect = player.convert(player.bounds, to: host)
        let y = host.isFlipped ? host.bounds.height - rect.maxY : rect.minY
        let target = CGRect(x: rect.minX * scale, y: y * scale, width: rect.width * scale, height: rect.height * scale)
        context.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
        context.setFillColor(NSColor.black.cgColor)
        context.fill(target)
        context.interpolationQuality = .high
        context.draw(cgFrame, in: AVMakeRect(aspectRatio: CGSize(width: cgFrame.width, height: cgFrame.height), insideRect: target))
        guard let composed = context.makeImage() else { return image }
        return NSImage(cgImage: composed, size: host.bounds.size)
    }

    static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for child in view.subviews { if let match = find(type, in: child) { return match } }
        return nil
    }

    /// Exports a Short with the app's renderer and returns one frame of it.
    static func frame(of segment: EditSegment, source: URL, at time: Double, in destination: URL) async throws -> NSImage {
        try? FileManager.default.removeItem(at: destination)
        try await ShortMaker.export(source: source, segment: segment, destination: destination)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: destination))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    static func sourceFrames(_ url: URL, times: [Double]) async throws -> [NSImage] {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.maximumSize = CGSize(width: 480, height: 270)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        var frames: [NSImage] = []
        for time in times {
            let image = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
            frames.append(NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)))
        }
        return frames
    }

    /// A full-width band of a 1080×1920 frame, measured from the top.
    static func crop(_ image: NSImage, top: CGFloat, height: CGFloat) -> NSImage {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let band = cg.cropping(to: CGRect(x: 0, y: top, width: CGFloat(cg.width), height: height)) else { return image }
        return NSImage(cgImage: band, size: NSSize(width: band.width, height: band.height))
    }

    static func save(_ rep: NSBitmapImageRep, width: Int, to url: URL) throws {
        guard let source = rep.cgImage else { throw CocoaError(.fileWriteUnknown) }
        let height = Int((Double(source.height) * Double(width) / Double(source.width)).rounded())
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw CocoaError(.fileWriteUnknown) }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage(),
              let png = NSBitmapImageRep(cgImage: scaled).representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url, options: .atomic)
    }
}
