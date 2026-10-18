import Foundation
import AVFoundation
import AppKit

@main struct RealVideoTest {
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else { fatalError("Usage: real-video-test SOURCE OUTPUT_DIRECTORY") }
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        let root = URL(fileURLWithPath: CommandLine.arguments[2])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let projectRoot = root.appendingPathComponent("Downloads video.relio")
        let mediaDirectory = projectRoot.appendingPathComponent("Media")
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        let managed = mediaDirectory.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: managed)
        guard let media = await MediaEngine.inspect(managed, thumbnailDirectory: projectRoot.appendingPathComponent("Thumbnails")) else { fatalError("Real video import failed") }
        print("IMPORT: \(media.width)×\(media.height), \(media.duration)s, audio=\(media.hasAudio == true)")
        fflush(stdout)
        let results = try await ShortMaker.analyze(managed, requestedDuration: 30, count: 3, sourceRegion: .entireVideo, transcriptionEnabled: false)
        let segments = results.map { EditSegment(mediaID: media.id, start: $0.start, duration: $0.duration, caption: $0.caption) }
        let project = ProjectData(name: "Downloads video test", media: [media], segments: segments)
        let store = try ProjectStore(root: projectRoot)
        try store.save(project, key: "project")
        guard let loaded = try store.load(ProjectData.self, key: "project") else { fatalError("Reopen failed") }
        precondition(loaded.segments == segments)
        print("ANALYSIS: \(segments.count) Shorts; persistence passed")
        fflush(stdout)
        for (index, segment) in segments.enumerated() {
            let output = projectRoot.appendingPathComponent("Exports/Short \(index + 1).mp4")
            try await ShortMaker.export(source: managed, segment: segment, destination: output)
            let asset = AVURLAsset(url: output)
            let duration = try await asset.load(.duration).seconds
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { fatalError("Missing output video") }
            let size = try await track.load(.naturalSize)
            let audio = try await asset.loadTracks(withMediaType: .audio)
            precondition(size.width == 1080 && size.height == 1920)
            precondition(abs(duration - segment.duration) < 0.2)
            precondition(!audio.isEmpty == (media.hasAudio == true))
            if let audioTrack = audio.first {
                let reader = try AVAssetReader(asset: asset)
                let decoded = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
                reader.add(decoded)
                precondition(reader.startReading())
                guard let sample = decoded.copyNextSampleBuffer() else { fatalError("Audio could not decode") }
                precondition(CMSampleBufferGetNumSamples(sample) > 0)
                reader.cancelReading()
            }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            let image = try generator.copyCGImage(at: CMTime(seconds: min(2, duration / 2), preferredTimescale: 600), actualTime: nil)
            let bitmap = NSBitmapImageRep(cgImage: image)
            try bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85])!.write(to: root.appendingPathComponent("Short-\(index + 1).jpg"))
            print("PASS Short \(index + 1): source \(segment.start)s, output \(duration)s, audio \(!audio.isEmpty), caption \(!segment.caption.isEmpty), \(output.path)")
            fflush(stdout)
        }
        if var fitted = segments.first {
            fitted.fitToFrame = true
            let output = projectRoot.appendingPathComponent("Exports/Short 1 full frame.mp4")
            try await ShortMaker.export(source: managed, segment: fitted, destination: output)
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: output))
            let image = try generator.copyCGImage(at: CMTime(seconds: 2, preferredTimescale: 600), actualTime: nil)
            let bitmap = NSBitmapImageRep(cgImage: image)
            try bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85])!.write(to: root.appendingPathComponent("Short-1-full-frame.jpg"))
            print("PASS full-frame alternative: \(output.path)")
        }
        let report = "Source: \(source.path)\nDuration: \(media.duration) seconds\nSize: \(media.width) × \(media.height)\nAudio: \(media.hasAudio == true)\nShorts: \(segments.count)\nSpeech recognition: not tested (terminal privacy attribution prevents authorization; fallback selection tested)\nImport, save/reopen, selection, render, dimensions, duration, audio track presence and frame decoding passed.\n"
        try report.write(to: root.appendingPathComponent("results.txt"), atomically: true, encoding: .utf8)
    }
}
