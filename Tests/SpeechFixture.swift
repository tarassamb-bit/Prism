import Foundation
import AVFoundation

@main struct SpeechFixture {
    static func main() async throws {
        let audioURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let picturesURL = URL(fileURLWithPath: CommandLine.arguments[2])
        let destination = URL(fileURLWithPath: CommandLine.arguments[3])
        let audio = AVURLAsset(url: audioURL)
        let pictures = AVURLAsset(url: picturesURL)
        let duration = try await audio.load(.duration)
        let pictureDuration = try await pictures.load(.duration)
        let composition = AVMutableComposition()
        let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        let sound = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
        let inputVideo = try await pictures.loadTracks(withMediaType: .video)[0]
        let inputAudio = try await audio.loadTracks(withMediaType: .audio)[0]
        var time = CMTime.zero
        while time < duration {
            let length = CMTimeMinimum(pictureDuration, duration - time)
            try video.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: inputVideo, at: time)
            time = time + length
        }
        try sound.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: inputAudio, at: .zero)
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPreset640x480) else { fatalError("No encoder") }
        export.outputURL = destination
        export.outputFileType = .mp4
        await export.export()
        guard export.status == .completed else { throw export.error! }
        print("Synthetic speech fixture: \(duration.seconds) seconds, \(destination.path)")
    }
}
