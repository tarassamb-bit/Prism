import Foundation
import AVFoundation
import AppKit

@main struct VerifySpeechWorkflow {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let artifacts = URL(fileURLWithPath: CommandLine.arguments[2])
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        let store = try ProjectStore(root: root)
        guard let project = try store.load(ProjectData.self, key: "project") else { fatalError("No project") }
        precondition(project.segments.count == 2, "Expected the two independent synthetic stories")
        let expected = [("electricity", "my electricity bill", "new equipment."), ("tomato", "here is a mistake", "a calendar.")]
        let outputs = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Exports"), includingPropertiesForKeys: nil).filter { $0.pathExtension == "mp4" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        precondition(outputs.count == 2)
        for (index, segment) in project.segments.enumerated() {
            let text = (segment.captions ?? []).map(\.text).joined(separator: " ").lowercased()
            precondition(text.hasPrefix(expected[index].1) && text.hasSuffix(expected[index].2), "Story hook or payoff is missing: \(text)")
            precondition(segment.suggestedTitle?.isEmpty == false)
            if segment.speechWords?.isEmpty != false {
                precondition(segment.captionNotice?.contains("sentence timing") == true, "Approximate captions must be labelled")
            }
            precondition(segment.selectionReason?.isEmpty == false)
            precondition(!(segment.captions ?? []).isEmpty)
            precondition((segment.speechWords ?? []).allSatisfy { $0.start >= -0.01 && $0.start + $0.duration <= segment.duration + 0.01 })
            let asset = AVURLAsset(url: outputs[index])
            let duration = try await asset.load(.duration).seconds
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let size = try await tracks[0].load(.naturalSize)
            precondition(size.width == 1080 && size.height == 1920 && abs(duration - segment.duration) < 0.15)
            let audio = try await asset.loadTracks(withMediaType: .audio)
            precondition(!audio.isEmpty)
            let reader = try AVAssetReader(asset: asset)
            let decoded = AVAssetReaderTrackOutput(track: audio[0], outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
            reader.add(decoded)
            precondition(reader.startReading() && decoded.copyNextSampleBuffer() != nil)
            reader.cancelReading()
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let frame = try generator.copyCGImage(at: CMTime(seconds: 3, preferredTimescale: 600), actualTime: nil)
            try NSBitmapImageRep(cgImage: frame).representation(using: .png, properties: [:])!.write(to: artifacts.appendingPathComponent("speech-short-\(index + 1).png"))
            print("PASS spoken story \(index + 1): complete hook/payoff, captions, title, source bounds, 1080×1920 MP4, \(duration)s, decoded audio")
        }
    }
}
