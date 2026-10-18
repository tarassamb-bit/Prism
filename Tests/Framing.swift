import Foundation
import AVFoundation
import AppKit

@main struct FramingChecks {
    static func main() async throws {
        func sample(_ time: Double, _ x: Double, cut: Double? = nil) -> FramingSample {
            .init(time: time, subject: CGRect(x: x - 0.035, y: 0.3, width: 0.07, height: 0.4), cutTime: cut)
        }
        let size = CGSize(width: 640, height: 360)
        let still = (0..<30).map { sample(Double($0) * 0.12, 0.5 + ($0.isMultiple(of: 2) ? 0.003 : -0.003)) }
        let steady = SubjectFramer.plan(still, duration: 3.6, imageSize: size, zoom: 1.08)
        precondition((steady.map(\.position).max()! - steady.map(\.position).min()!) < 0.01, "A stationary subject must not create camera wobble")
        let fast = (0..<12).map { sample(Double($0) * 0.12, 0.2 + min(1, Double($0) / 5) * 0.6) }
        let follow = SubjectFramer.plan(fast, duration: 1.44, imageSize: size, zoom: 1.08)
        let visible = (1080.0 / (640 * (1920.0 / 360) * 1.08))
        for point in follow where point.time < 1.32 {
            let x = 0.2 + min(1, point.time / 0.12 / 5) * 0.6
            let center = visible / 2 + point.position * (1 - visible)
            precondition(abs(x - center) < visible / 2, "Camera lost a fast moving subject")
        }
        let cutSamples = [sample(0, 0.2), sample(0.5, 0.2), sample(1, 0.8, cut: 0.95), sample(1.5, 0.8)]
        let cuts = SubjectFramer.plan(cutSamples, duration: 2, imageSize: size, zoom: 1.08)
        let cut = cuts.first { $0.isSceneCut == true }!
        precondition(cut.time == 0.95 && cut.position > 0.85, "New shot was averaged with the previous shot")
        let legacy = try JSONDecoder().decode(CropKeyframe.self, from: Data("{\"time\":0,\"position\":0.5}".utf8))
        precondition(legacy.isSceneCut == nil)
        print("PASS steady framing, fast subject containment, scene cut isolation, legacy projects")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RelioFraming-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("bars.mov")
        try await makeBars(source)
        let output = root.appendingPathComponent("cut.mp4")
        let segment = EditSegment(mediaID: UUID(), duration: 2, cropKeyframes: [
            .init(time: 0, position: 0), .init(time: 1, position: 1, isSceneCut: true), .init(time: 2, position: 1)
        ])
        try await ShortMaker.export(source: source, segment: segment, destination: output)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: output))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        for time in [0.6, 0.93, 1.07, 1.4] {
            let frame = try generator.copyCGImage(at: CMTime(seconds: time, preferredTimescale: 600), actualTime: nil)
            let image = NSBitmapImageRep(cgImage: frame)
            let color = image.colorAt(x: frame.width / 2, y: frame.height / 2)!.usingColorSpace(.deviceRGB)!
            if time < 1 { precondition(color.redComponent > 0.8 && color.blueComponent < 0.2, "Export panned before the cut") }
            else { precondition(color.blueComponent > 0.8 && color.redComponent < 0.2, "Export failed to switch on the cut") }
        }
        print("PASS rendered MP4 holds before a cut and switches immediately after it")
        if CommandLine.arguments.count >= 4 {
            let footage = URL(fileURLWithPath: CommandLine.arguments[1])
            let start = Double(CommandLine.arguments[2])!
            let duration = Double(CommandLine.arguments[3])!
            let path = await ShortMaker.analyzeSubjectPath(footage, start: start, duration: duration)
            let json = try JSONEncoder().encode(path)
            try json.write(to: root.appendingPathComponent("subject-path.json"))
            let review = root.appendingPathComponent("real-footage.mp4")
            try await ShortMaker.export(source: footage, segment: EditSegment(mediaID: UUID(), start: start, duration: duration, cropKeyframes: path), destination: review)
            print("REAL: \(path.count) points, \(path.filter { $0.isSceneCut == true }.count) scene cuts, positions \(path.map(\.position).min() ?? 0)...\(path.map(\.position).max() ?? 0)")
            print("REVIEW: \(review.path)")
        }
        print("ARTIFACTS: \(root.path)")
    }

    static func makeBars(_ url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 640, AVVideoHeightKey: 360])
        let attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 640, kCVPixelBufferHeightKey as String: 360,
            kCVPixelBufferCGImageCompatibilityKey as String: true]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attributes)
        writer.add(input)
        precondition(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for index in 0..<60 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(10)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, 640, 360, kCVPixelFormatType_32ARGB, attributes as CFDictionary, &buffer)
            let pixel = buffer!
            CVPixelBufferLockBaseAddress(pixel, [])
            let context = CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: 640, height: 360, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixel), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
            for (x, color) in [(0, NSColor.red), (213, NSColor.green), (426, NSColor.blue)] {
                context.setFillColor(color.cgColor)
                context.fill(CGRect(x: x, y: 0, width: 214, height: 360))
            }
            CVPixelBufferUnlockBaseAddress(pixel, [])
            precondition(adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(index), timescale: 30)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        precondition(writer.status == .completed)
    }
}
