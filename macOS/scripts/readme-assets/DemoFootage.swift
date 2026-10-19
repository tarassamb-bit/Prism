import AppKit
import AVFoundation

/// Flat illustrated stand-in footage for the README: no real people and no third-party video.
enum DemoFootage {
    enum Scene { case podcast, podcastCloseLeft, podcastCloseRight, tutorial, vlog, gaming, explainer, lecture }

    static let width = 1920, height = 1080

    /// Writes a video that holds each scene from its start time until the next one, with a silent soundtrack; the file
    /// lasts `duration`. Ranges in `dense` get a steady 10 fps, which the Short renderer needs; elsewhere frames are sparse.
    static func write(_ scenes: [(time: Double, scene: Scene)], duration: Double, dense: [ClosedRange<Double>] = [],
                      to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 48_000])
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferCGImageCompatibilityKey as String: true, kCVPixelBufferCGBitmapContextCompatibilityKey as String: true]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: attributes)
        writer.add(video)
        writer.add(audio)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)

        var frameTimes = Set(scenes.map(\.time) + [duration - 0.5])
        for range in dense { frameTimes.formUnion(stride(from: range.lowerBound, to: range.upperBound, by: 0.1).map { ($0 * 10).rounded() / 10 }) }
        let chunk = 4.0
        // Video frames and audio chunks go in time order, so the writer can interleave the two tracks.
        let events = (frameTimes.filter { $0 >= 0 && $0 < duration }.map { (time: $0, isAudio: false) }
            + stride(from: 0, to: duration, by: chunk).map { (time: $0, isAudio: true) }).sorted { $0.time < $1.time }
        var buffers: [Scene: CVPixelBuffer] = [:]
        let silence = try SilentAudio()
        for event in events {
            let input = event.isAudio ? audio : video
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            let appended: Bool
            if event.isAudio {
                appended = audio.append(try silence.buffer(at: event.time, seconds: min(chunk, duration - event.time)))
            } else {
                let scene = scenes.last { $0.time <= event.time + 0.001 }?.scene ?? scenes[0].scene
                if buffers[scene] == nil { buffers[scene] = try pixelBuffer(scene, pool: adaptor.pixelBufferPool) }
                appended = adaptor.append(buffers[scene]!, withPresentationTime: CMTime(seconds: event.time, preferredTimescale: 600))
            }
            guard appended else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        }
        video.markAsFinished()
        audio.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: duration, preferredTimescale: 600))
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    /// 16-bit mono silence at 44.1 kHz, as ready sample buffers.
    private struct SilentAudio {
        let format: CMAudioFormatDescription
        init() throws {
            var description = AudioStreamBasicDescription(mSampleRate: 44_100, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked, mBytesPerPacket: 2,
                mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
            var format: CMAudioFormatDescription?
            guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                                 magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr,
                  let format else { throw CocoaError(.fileWriteUnknown) }
            self.format = format
        }
        func buffer(at time: Double, seconds: Double) throws -> CMSampleBuffer {
            let frames = max(1, Int(seconds * 44_100))
            var block: CMBlockBuffer?
            guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: frames * 2, blockAllocator: nil,
                                                     customBlockSource: nil, offsetToData: 0, dataLength: frames * 2,
                                                     flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
                  let block, CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: frames * 2) == noErr
            else { throw CocoaError(.fileWriteUnknown) }
            var sample: CMSampleBuffer?
            guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: format,
                    sampleCount: frames, presentationTimeStamp: CMTime(value: Int64((time * 44_100).rounded()), timescale: 44_100),
                    packetDescriptions: nil, sampleBufferOut: &sample) == noErr, let sample else { throw CocoaError(.fileWriteUnknown) }
            return sample
        }
    }

    private static func pixelBuffer(_ scene: Scene, pool: CVPixelBufferPool?) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        if let pool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) }
        guard let pixel = buffer else { throw CocoaError(.fileWriteUnknown) }
        CVPixelBufferLockBaseAddress(pixel, [])
        defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(pixel), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { throw CocoaError(.fileWriteUnknown) }
        draw(scene, in: context)
        return pixel
    }

    /// Draws one 1920×1080 frame with a top-left origin.
    static func draw(_ scene: Scene, in context: CGContext) {
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        switch scene {
        case .podcast: podcast()
        case .podcastCloseLeft: zoomed(on: CGPoint(x: 530, y: 520), scale: 2.1) { podcast() }
        case .podcastCloseRight: zoomed(on: CGPoint(x: 1390, y: 520), scale: 2.1) { podcast() }
        case .tutorial: tutorial()
        case .vlog: vlog()
        case .gaming: gaming()
        case .explainer: explainer()
        case .lecture: lecture()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: Drawing helpers

    private static func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
    private static func fill(_ path: NSBezierPath, _ hex: UInt32, _ alpha: CGFloat = 1) { color(hex, alpha).setFill(); path.fill() }
    private static func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ hex: UInt32, radius: CGFloat = 0, alpha: CGFloat = 1) {
        fill(NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: radius, yRadius: radius), hex, alpha)
    }
    private static func oval(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat, _ hex: UInt32, alpha: CGFloat = 1) {
        fill(NSBezierPath(ovalIn: NSRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2)), hex, alpha)
    }
    private static func polygon(_ points: [CGPoint], _ hex: UInt32, alpha: CGFloat = 1) {
        let path = NSBezierPath()
        path.move(to: points[0])
        points.dropFirst().forEach { path.line(to: $0) }
        path.close()
        fill(path, hex, alpha)
    }
    private static func stroke(_ points: [CGPoint], _ hex: UInt32, width: CGFloat) {
        let path = NSBezierPath()
        path.move(to: points[0])
        points.dropFirst().forEach { path.line(to: $0) }
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        color(hex).setStroke()
        path.stroke()
    }
    /// Points on an ellipse; 270° is the top because y grows downward.
    private static func arc(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, from start: CGFloat, to end: CGFloat) -> [CGPoint] {
        stride(from: start, through: end, by: 3).map { CGPoint(x: cx + r * cos($0 * .pi / 180), y: cy + r * sin($0 * .pi / 180)) }
    }
    private static func rotatedRect(center: CGPoint, size: CGSize, radius: CGFloat, degrees: CGFloat, _ hex: UInt32) {
        let path = NSBezierPath(roundedRect: NSRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height),
                                xRadius: radius, yRadius: radius)
        var transform = AffineTransform(translationByX: center.x, byY: center.y)
        transform.rotate(byDegrees: degrees)
        path.transform(using: transform)
        fill(path, hex)
    }
    private static func text(_ string: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat, _ hex: UInt32,
                             font: String? = nil, weight: NSFont.Weight = .regular, alpha: CGFloat = 1) {
        let face = font.flatMap { NSFont(name: $0, size: size) } ?? NSFont.systemFont(ofSize: size, weight: weight)
        (string as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: face, .foregroundColor: color(hex, alpha)])
    }
    private static func zoomed(on point: CGPoint, scale: CGFloat, _ body: () -> Void) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -point.x, y: -point.y)
        body()
        context.restoreGState()
    }
    private static func scaled(at point: CGPoint, _ scale: CGFloat, _ body: () -> Void) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x: point.x, y: point.y)
        context.scaleBy(x: scale, y: scale)
        body()
        context.restoreGState()
    }

    // MARK: People

    enum Hair { case short(UInt32), afro(UInt32), bun(UInt32) }

    /// A flat waist-up person; the head's center is the origin and the head is about 200pt tall.
    private static func person(skin: UInt32, shade: UInt32, hair: Hair, shirt: UInt32, headphones: Bool) {
        rect(-200, 130, 400, 420, shirt, radius: 120)
        rect(-34, 60, 68, 100, shade, radius: 20)
        switch hair {
        case .afro(let tone):
            oval(0, -34, 122, 104, tone)
            for angle in stride(from: 160.0, through: 380.0, by: 22.0) {
                oval(cos(angle * .pi / 180) * 104, -30 + sin(angle * .pi / 180) * 90, 46, 46, tone)
            }
        case .short(let tone), .bun(let tone):
            if case .bun = hair { oval(0, -118, 42, 38, tone) }
            oval(0, -26, 90, 80, tone)
        }
        oval(-82, 10, 14, 22, shade)
        oval(82, 10, 14, 22, shade)
        oval(0, 16, 80, 88, skin)
        if case .short(let tone) = hair { polygon([CGPoint(x: -82, y: -30), CGPoint(x: 40, y: -60), CGPoint(x: 84, y: -10), CGPoint(x: 70, y: -66), CGPoint(x: -60, y: -74)], tone) }
        if case .bun(let tone) = hair { polygon([CGPoint(x: -84, y: -12), CGPoint(x: -20, y: -58), CGPoint(x: 84, y: -14), CGPoint(x: 66, y: -70), CGPoint(x: -66, y: -70)], tone) }
        oval(-30, 14, 8, 10, 0x2A1F1A)
        oval(30, 14, 8, 10, 0x2A1F1A)
        rect(-44, -10, 28, 7, 0x2A1F1A, radius: 3.5, alpha: 0.85)
        rect(16, -10, 28, 7, 0x2A1F1A, radius: 3.5, alpha: 0.85)
        stroke(arc(0, 34, 24, from: 25, to: 155), 0x7A3328, width: 6)
        if headphones {
            stroke(arc(0, 6, 104, from: 192, to: 348), 0x1E1E22, width: 18)
            rect(-118, -26, 36, 76, 0x1E1E22, radius: 14)
            rect(82, -26, 36, 76, 0x1E1E22, radius: 14)
        }
    }

    private static func microphone(arm: [CGPoint], capsule: CGPoint, degrees: CGFloat) {
        stroke(arm, 0x18181B, width: 12)
        rotatedRect(center: capsule, size: CGSize(width: 56, height: 124), radius: 28, degrees: degrees, 0x232326)
        rotatedRect(center: capsule, size: CGSize(width: 40, height: 6), radius: 3, degrees: degrees, 0x3A3A40)
    }

    // MARK: Scenes

    private static func podcast() {
        rect(0, 0, 1920, 1080, 0x1B3A42)
        // Night window with a skyline.
        rect(800, 110, 320, 480, 0x203A55, radius: 150)
        for (index, height) in [140.0, 210, 120, 250, 170, 200, 130].enumerated() {
            let x = 820 + CGFloat(index) * 42
            rect(x, 590 - height, 40, height, 0x14283B)
            for row in 0..<Int(height / 34) where (index + row) % 3 != 0 {
                rect(x + 10, 590 - height + 16 + CGFloat(row) * 34, 8, 10, 0xF2C14E, alpha: 0.85)
            }
        }
        oval(1050, 220, 26, 26, 0xF6F3EC, alpha: 0.9)
        let frame = NSBezierPath(roundedRect: NSRect(x: 800, y: 110, width: 320, height: 480), xRadius: 150, yRadius: 150)
        frame.lineWidth = 18
        color(0x0F2229).setStroke()
        frame.stroke()
        stroke([CGPoint(x: 960, y: 120), CGPoint(x: 960, y: 590)], 0x0F2229, width: 10)
        // Acoustic slat panels behind each host.
        for panel in [CGFloat(300), 1160] {
            rect(panel, 150, 460, 650, 0x3E2A1E, radius: 10)
            for slat in 0..<10 { rect(panel + 16 + CGFloat(slat) * 44, 166, 30, 618, slat.isMultiple(of: 2) ? 0x8B5E3C : 0x7A5233, radius: 6) }
        }
        // Shelf, books and a plant under the window.
        rect(820, 618, 280, 16, 0x5B4030, radius: 4)
        for (index, book) in [(0xE0B04B as UInt32, 78.0), (0x4F7CAC, 92), (0xB85450, 70), (0xF6F3EC, 84)].enumerated() {
            rect(900 + CGFloat(index) * 26, 618 - book.1, 22, book.1, book.0, radius: 3)
        }
        rect(840, 560, 48, 58, 0xC4664A, radius: 8)
        for leaf in [(-30.0, -30.0), (0, -48), (28, -26), (-14, -12), (18, -8)] { oval(864 + leaf.0, 552 + leaf.1, 22, 34, 0x4E8B5C) }
        rect(1030, 556, 54, 62, 0x26262A, radius: 8)
        oval(1057, 588, 16, 16, 0x45454C)
        // Floor lamp and a tall plant at the edges.
        oval(130, 300, 230, 230, 0xFFE2A0, alpha: 0.08)
        stroke([CGPoint(x: 130, y: 240), CGPoint(x: 130, y: 830)], 0x26262A, width: 10)
        polygon([CGPoint(x: 85, y: 160), CGPoint(x: 175, y: 160), CGPoint(x: 210, y: 250), CGPoint(x: 50, y: 250)], 0xF0D9A8)
        rect(1720, 700, 110, 110, 0xC4664A, radius: 14)
        for leaf in [(-50.0, -120.0), (0, -170), (46, -110), (-70, -40), (60, -40), (-10, -80)] { oval(1775 + leaf.0, 700 + leaf.1, 34, 70, 0x3F7A50) }
        // Hosts.
        scaled(at: CGPoint(x: 530, y: 470), 1) {
            person(skin: 0xE2A786, shade: 0xC98F70, hair: .short(0x3A2A20), shirt: 0xD69A3A, headphones: true)
        }
        scaled(at: CGPoint(x: 1390, y: 470), 1) {
            person(skin: 0x8A5A3C, shade: 0x744A30, hair: .afro(0x1B1716), shirt: 0x4F7CAC, headphones: true)
        }
        microphone(arm: [CGPoint(x: 740, y: 810), CGPoint(x: 700, y: 640), CGPoint(x: 660, y: 600)], capsule: CGPoint(x: 640, y: 556), degrees: -24)
        microphone(arm: [CGPoint(x: 1180, y: 810), CGPoint(x: 1220, y: 640), CGPoint(x: 1260, y: 600)], capsule: CGPoint(x: 1280, y: 556), degrees: 24)
        // Desk and what sits on it.
        rect(0, 800, 1920, 280, 0x3A291E)
        rect(0, 792, 1920, 18, 0x5B4030)
        rect(860, 736, 54, 64, 0xF6F3EC, radius: 8)
        stroke(arc(914, 768, 18, from: -80, to: 80), 0xF6F3EC, width: 8)
        rect(1250, 690, 290, 112, 0xC9CDD3, radius: 12)
        oval(1395, 744, 16, 16, 0xB0B5BD)
        rotatedRect(center: CGPoint(x: 420, y: 790), size: CGSize(width: 150, height: 40), radius: 4, degrees: -6, 0xF6F3EC)
    }

    private static func tutorial() {
        rect(0, 0, 1920, 1080, 0x16181D)
        rect(0, 0, 380, 1080, 0x1C1F25)
        rect(380, 0, 1540, 70, 0x1C1F25)
        rect(400, 14, 250, 56, 0x16181D, radius: 8)
        text("Shorts.swift", 428, 28, size: 24, 0xD7DAE0)
        text("Clips.swift", 690, 28, size: 24, 0x7D8590)
        text("PRISMDEMO", 36, 34, size: 20, 0x7D8590, weight: .semibold)
        for (index, file) in ["Sources", "   Shorts.swift", "   Clips.swift", "   Gemini.swift", "   Render.swift", "Tests", "   ShortsTests.swift"].enumerated() {
            if index == 1 { rect(14, 82 + CGFloat(index) * 46, 352, 42, 0x2B3A55, radius: 6) }
            text(file, 36, 90 + CGFloat(index) * 46, size: 23, index == 1 ? 0xE6E9EF : 0x9AA3B0)
        }
        let lines: [[(String, UInt32)]] = [
            [("import", 0xFF7AB2), (" Foundation", 0xD7DAE0)],
            [],
            [("/// One long video in, a few complete Shorts out.", 0x6C7986)],
            [("func", 0xFF7AB2), (" makeShorts", 0x67B7FF), ("(from video: ", 0xD7DAE0), ("URL", 0xD0A8FF), (") ", 0xD7DAE0), ("async throws", 0xFF7AB2), (" -> [", 0xD7DAE0), ("Short", 0xD0A8FF), ("] {", 0xD7DAE0)],
            [("    let", 0xFF7AB2), (" transcript = ", 0xD7DAE0), ("try await", 0xFF7AB2), (" gemini.transcribe(video)", 0xD7DAE0)],
            [("    let", 0xFF7AB2), (" windows = transcript.windows(seconds: ", 0xD7DAE0), ("90", 0xD9C97C), (")", 0xD7DAE0)],
            [("    let", 0xFF7AB2), (" ranked = ", 0xD7DAE0), ("try await", 0xFF7AB2), (" gemini.score(windows)", 0xD7DAE0)],
            [("    return", 0xFF7AB2), (" try await", 0xFF7AB2), (" ranked.prefix(", 0xD7DAE0), ("3", 0xD9C97C), (").asyncMap { window ", 0xD7DAE0), ("in", 0xFF7AB2)],
            [("        try await", 0xFF7AB2), (" gemini.refine(window)", 0xD7DAE0)],
            [("    }", 0xD7DAE0)],
            [("}", 0xD7DAE0)]
        ]
        for (index, line) in lines.enumerated() {
            let y = 112 + CGFloat(index) * 54
            text("\(index + 1)", 410, y, size: 26, 0x4B5263, font: "JetBrainsMono-Regular")
            var x: CGFloat = 470
            for token in line {
                text(token.0, x, y, size: 26, token.1, font: "JetBrainsMono-Regular")
                x += CGFloat(token.0.count) * 15.6
            }
        }
        rect(470, 112 + 4 * 54 - 4, 1380, 50, 0x67B7FF, radius: 6, alpha: 0.08)
        // Presenter camera bubble.
        oval(1720, 870, 170, 170, 0xF6F3EC)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        NSBezierPath(ovalIn: NSRect(x: 1556, y: 706, width: 328, height: 328)).addClip()
        rect(1556, 706, 328, 328, 0x2C4A52)
        scaled(at: CGPoint(x: 1720, y: 850), 0.8) {
            person(skin: 0xE2A786, shade: 0xC98F70, hair: .short(0x3A2A20), shirt: 0xD69A3A, headphones: false)
        }
        context.restoreGState()
    }

    private static func vlog() {
        rect(0, 0, 1920, 1080, 0x8EC5E6)
        oval(1640, 170, 86, 86, 0xFFD166)
        let buildings: [(CGFloat, CGFloat, UInt32)] = [(0, 330, 0xF2C6B4), (300, 250, 0x9CCFCB), (560, 380, 0xF4DDA1), (900, 290, 0xE7A9A0), (1180, 360, 0xB8D3EA), (1500, 270, 0xF2C6B4), (1760, 340, 0x9CCFCB)]
        for (index, building) in buildings.enumerated() {
            let next = index + 1 < buildings.count ? buildings[index + 1].0 : 1920
            let top = 860 - building.1 - 200
            polygon([CGPoint(x: building.0 - 10, y: top), CGPoint(x: (building.0 + next) / 2, y: top - 70), CGPoint(x: next + 10, y: top)], 0xC8553D)
            rect(building.0, top, next - building.0, 860 - top, building.2)
            for row in 0..<4 { for column in 0..<Int((next - building.0 - 40) / 90) {
                rect(building.0 + 40 + CGFloat(column) * 90, top + 50 + CGFloat(row) * 110, 44, 66, 0x3F5E73, radius: 4, alpha: 0.75)
            } }
        }
        rect(0, 860, 1920, 220, 0x6A6560)
        stroke([CGPoint(x: 0, y: 960), CGPoint(x: 1920, y: 960)], 0x9A948D, width: 6)
        stroke([CGPoint(x: 0, y: 1010), CGPoint(x: 1920, y: 1010)], 0x9A948D, width: 6)
        // Tram.
        stroke([CGPoint(x: 900, y: 520), CGPoint(x: 1000, y: 440), CGPoint(x: 1100, y: 520)], 0x2A2A2A, width: 6)
        rect(760, 520, 640, 420, 0xF2B233, radius: 40)
        rect(760, 820, 640, 90, 0xF6F3EC, radius: 0)
        for window in 0..<5 { rect(796 + CGFloat(window) * 120, 580, 96, 150, 0xDDEEF5, radius: 10) }
        rect(1300, 580, 70, 240, 0xC9A034, radius: 10)
        oval(880, 960, 46, 46, 0x2A2A2A)
        oval(1280, 960, 46, 46, 0x2A2A2A)
        text("28", 1180, 532, size: 40, 0x2A2A2A, weight: .bold)
        scaled(at: CGPoint(x: 380, y: 560), 1.35) {
            person(skin: 0x8A5A3C, shade: 0x744A30, hair: .afro(0x1B1716), shirt: 0xE9EEF2, headphones: false)
            stroke([CGPoint(x: -120, y: 140), CGPoint(x: -90, y: 420)], 0x5B4636, width: 22)
        }
    }

    private static func gaming() {
        rect(0, 0, 1920, 1080, 0x6B8CFF)
        for cloud in [(260.0, 230.0), (980, 250), (1420, 320)] {
            oval(cloud.0, cloud.1, 90, 46, 0xFFFFFF)
            oval(cloud.0 + 70, cloud.1 - 20, 70, 50, 0xFFFFFF)
            oval(cloud.0 - 70, cloud.1 + 6, 60, 36, 0xFFFFFF)
        }
        for row in 0..<3 { for column in 0..<32 {
            rect(CGFloat(column) * 60, 900 + CGFloat(row) * 60, 58, 58, row == 0 ? 0xC6602A : 0xA44E22)
        } }
        for column in 0..<5 {
            rect(700 + CGFloat(column) * 62, 560, 60, 60, column == 2 ? 0xF2B233 : 0xB5532A)
            if column == 2 { text("?", 718 + CGFloat(column) * 62, 566, size: 46, 0x7A3E12, weight: .heavy) }
        }
        for coin in [760.0, 840, 920, 1000] { oval(coin, 470, 18, 26, 0xFFD34E) }
        rect(1300, 740, 140, 160, 0x3FAE49)
        rect(1284, 720, 172, 50, 0x55C95F, radius: 4)
        // A blocky hero.
        rect(400, 760, 80, 40, 0xD8342C)
        rect(392, 800, 96, 60, 0x2A55C9)
        rect(408, 860, 30, 40, 0x6B3A1E)
        rect(442, 860, 30, 40, 0x6B3A1E)
        rect(410, 724, 60, 40, 0xF0B48A)
        text("SCORE 004200    COINS ×17    WORLD 1-3    TIME 312", 60, 30, size: 34, 0xFFFFFF, font: "JetBrainsMono-Medium")
        rect(1540, 90, 340, 250, 0x2B2D42, radius: 8)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        NSBezierPath(rect: NSRect(x: 1540, y: 90, width: 340, height: 250)).addClip()
        scaled(at: CGPoint(x: 1710, y: 220), 0.85) {
            person(skin: 0x8A5A3C, shade: 0x744A30, hair: .afro(0x1B1716), shirt: 0x5A3E8C, headphones: true)
        }
        context.restoreGState()
    }

    private static func explainer() {
        rect(0, 0, 1920, 1080, 0x0B1626)
        polygon([CGPoint(x: 0, y: 260), CGPoint(x: 520, y: 180), CGPoint(x: 900, y: 320), CGPoint(x: 1300, y: 240), CGPoint(x: 1920, y: 380),
                 CGPoint(x: 1920, y: 1080), CGPoint(x: 0, y: 1080)], 0x12233A)
        var seed: UInt64 = 42
        func random() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 33) / CGFloat(1 << 31) }
        for cluster in [(380.0, 520.0, 160.0), (900, 640, 220), (1420, 520, 180), (640, 860, 140), (1220, 880, 120), (1700, 760, 110)] {
            for _ in 0..<260 {
                let angle = random() * 2 * .pi, distance = pow(random(), 1.8) * cluster.2
                let size = 2 + random() * 5
                oval(cluster.0 + cos(angle) * distance * 1.4, cluster.1 + sin(angle) * distance * 0.8, size, size,
                     random() > 0.3 ? 0xFFC95C : 0xFFF1C9, alpha: 0.35 + random() * 0.6)
            }
        }
        rect(80, 880, 860, 130, 0x0E0F14, radius: 12, alpha: 0.85)
        text("Why cities glow at night", 116, 900, size: 46, 0xF6F3EC, weight: .semibold)
        text("Night lights seen from orbit", 116, 958, size: 28, 0x9AA3B0)
    }

    private static func lecture() {
        rect(0, 0, 1920, 1080, 0xD9D4C7)
        rect(0, 900, 1920, 180, 0xBDB6A8)
        rect(150, 90, 1120, 700, 0xB8B2A6, radius: 10)
        rect(166, 106, 1088, 668, 0xFAFAF7, radius: 6)
        text("Price × volume", 230, 140, size: 54, 0x2E3A59, weight: .semibold)
        stroke([CGPoint(x: 260, y: 260), CGPoint(x: 260, y: 700), CGPoint(x: 1180, y: 700)], 0x2E3A59, width: 7)
        for (index, value) in [0.35, 0.55, 0.9, 0.7, 0.45].enumerated() {
            let barHeight = 400 * CGFloat(value)
            rect(320 + CGFloat(index) * 170, 700 - barHeight, 110, barHeight, index == 2 ? 0xD8553F : 0x2F6DB5, radius: 4)
        }
        for (index, label) in ["$9", "$19", "$29", "$49", "$99"].enumerated() {
            text(label, 375 + CGFloat(index) * 170 - CGFloat(label.count) * 10, 712, size: 34, 0x2E3A59)
        }
        scaled(at: CGPoint(x: 1560, y: 400), 1.3) {
            person(skin: 0xE2A786, shade: 0xC98F70, hair: .bun(0x5A3A26), shirt: 0x2F4858, headphones: false)
        }
    }
}
