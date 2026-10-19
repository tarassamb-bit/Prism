import Foundation
import AVFoundation
import CryptoKit
import AppKit
import CoreImage
import os

struct ShortResult {
    let start: Double
    let duration: Double
    let caption: String
    let captions: [TimedCaption]
    let cropKeyframes: [CropKeyframe]
    let speechWords: [TimedSpeechWord]
    var analysisWarning: String? = nil
    var suggestedTitle: String? = nil
    var selectionReason: String? = nil
    var fitToFrame: Bool = false
}

enum CaptionGenerationIssue {
    case noSpeech

    var message: String {
        switch self {
        case .noSpeech:
            "No speech was detected in this Short. Check the audio and spoken language."
        }
    }
}

struct CaptionGenerationResult {
    var cues: [TimedCaption]
    var issue: CaptionGenerationIssue?
    var words: [TimedSpeechWord] = []
    var notice: String? = nil
}

enum ShortMaker {
    enum SourceRegion: String, CaseIterable, Identifiable {
        case entireVideo, firstHalf, lastHalf, custom
        var id: String { rawValue }
        var title: String {
            switch self {
            case .entireVideo: "Entire video"
            case .firstHalf: "First half"
            case .lastHalf: "Last half"
            case .custom: "Custom range"
            }
        }
        func interval(videoDuration: Double, customStart: Double? = nil, customEnd: Double? = nil) throws -> (start: Double, end: Double) {
            guard videoDuration.isFinite, videoDuration > 0 else { throw Failure.invalidRange }
            switch self {
            case .entireVideo: return (0, videoDuration)
            case .firstHalf: return (0, videoDuration / 2)
            case .lastHalf: return (videoDuration / 2, videoDuration)
            case .custom:
                guard let start = customStart, let end = customEnd,
                      start.isFinite, end.isFinite, start >= 0, end > start,
                      end <= videoDuration else { throw Failure.invalidRange }
                return (start, end)
            }
        }
    }

    enum Failure: LocalizedError {
        case noVideo, cannotExport, invalidRange, destinationExists
        var errorDescription: String? {
            switch self {
            case .noVideo: "No playable video track was found."
            case .cannotExport: "The video encoder could not complete the render."
            case .invalidRange: "The edit contains an invalid time range. Choose a range within the source video."
            case .destinationExists: "A file already exists at the export destination. Choose another filename."
            }
        }
    }

    static func analyze(
        _ url: URL,
        requestedDuration: Double,
        count: Int,
        sourceRegion: SourceRegion,
        customStart: Double? = nil,
        customEnd: Double? = nil,
        excluding: [SourceInterval] = [],
        gemini: GeminiConfiguration,
        videoType: VideoType = .general,
        cachedTranscript: SentenceTranscript? = nil,
        onTranscript: @escaping @Sendable (SentenceTranscript) -> Void = { _ in },
        generationProgress: @escaping @Sendable (Double, String) -> Void = { _, _ in }
    ) async throws -> [ShortResult] {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0, !(try await asset.loadTracks(withMediaType: .video)).isEmpty else { throw Failure.noVideo }
        let interval = try sourceRegion.interval(videoDuration: duration, customStart: customStart, customEnd: customEnd)
        guard !excluding.contains(where: { $0.start <= interval.start && $0.end >= interval.end }) else { throw GeminiSelection.Failure.noDistinctClips }
        let clipDuration = min(max(1, requestedDuration), interval.end - interval.start)
        let targetCount = min(max(1, count), 10)
        let hasAudio = !(try await asset.loadTracks(withMediaType: .audio)).isEmpty
        generationProgress(0, "Preparing audio for Gemini")
        let transcript: [TimedCaption]
        if !hasAudio {
            transcript = []
        } else if let saved = cachedTranscript?.cues(covering: interval) {
            // Saved by an earlier run on this video: no audio upload and no transcription cost.
            generationProgress(0.55, "Using the saved transcript")
            transcript = saved
        } else {
            // An earlier run that failed partway saved the stretch it finished; only the rest is transcribed again.
            let resumed = cachedTranscript.flatMap { saved -> SentenceTranscript? in
                guard saved.start <= interval.start + 0.01, saved.end > interval.start + 1, saved.end < interval.end else { return nil }
                return saved.cues(covering: (interval.start, saved.end)).map { SentenceTranscript(start: interval.start, end: saved.end, cues: $0) }
            }
            let from = resumed?.end ?? interval.start
            let kept = resumed?.cues ?? []
            let fresh = try await GeminiSelection.transcribeSentences(url: url, interval: (from, interval.end), configuration: gemini, progress: { fraction in
                let overall = (from - interval.start + fraction * (interval.end - from)) / (interval.end - interval.start)
                generationProgress(0.55 * overall, "Gemini · transcribing audio · \(Int(overall * 100))%")
            }, finished: { cues, end in
                onTranscript(SentenceTranscript(start: interval.start, end: end, cues: kept + cues))
            })
            transcript = kept + fresh
            onTranscript(SentenceTranscript(start: interval.start, end: interval.end, cues: transcript))
        }
        generationProgress(0.55, "Selecting distinct moments")
        var videoType = videoType
        if videoType == .auto {
            generationProgress(0.55, "Gemini · recognizing the kind of video")
            // Detection reads the transcript; a silent source keeps the general behavior.
            videoType = transcript.isEmpty ? .general : await GeminiSelection.detectVideoType(cues: transcript, configuration: gemini)
            generationProgress(0.55, "Gemini · \(videoType.title)")
        }
        generationProgress(0.55, "Gemini · choosing complete stories and layouts")
        let clips = try await GeminiSelection.select(url: url, cues: transcript, interval: interval,
                                                    targetDuration: clipDuration, count: targetCount, configuration: gemini, excluding: excluding,
                                                    guidance: videoType.selectionGuidance, progress: { fraction, stage in
                                                        generationProgress(0.55 + 0.15 * fraction, stage)
                                                    })
        var planned = clips.map { (start: $0.start, duration: $0.end - $0.start, fit: $0.layout == "fit", title: $0.title, reason: $0.reason) }
        // Screens and gameplay lose their edges in a vertical crop, whatever the picker suggested.
        if videoType.forcesFit { planned = planned.map { ($0.start, $0.duration, true, $0.title, $0.reason) } }
        let picks = planned
        let sentenceTimingNote = GeminiSelection.sentenceTimingNotice
        let finished = OSAllocatedUnfairLock(initialState: 0)
        let reportStep: @Sendable (String) -> Void = { stage in
            let done = finished.withLock { $0 += 1; return $0 }
            generationProgress(0.70 + 0.29 * min(1, Double(done) / Double(targetCount * 2)), stage)
        }
        // Picks are prepared a wave at a time, side by side: exact boundaries, word timing and the nearest pauses.
        // They are accepted in Gemini's order; a pick that now overlaps an earlier one gives way to the next backup.
        var accepted: [(candidate: Int, range: PreparedShort)] = []
        var wordAlignmentAvailable = true
        var next = 0
        while accepted.count < targetCount, next < planned.count {
            try Task.checkCancellation()
            let wave = Array(next..<min(planned.count, next + targetCount - accepted.count))
            next += wave.count
            let aligning = wordAlignmentAvailable
            let prepared = try await concurrentMap(wave) { index in
                let candidate = picks[index]
                let shot = try await prepareShort(url: url, start: candidate.start, duration: candidate.duration, transcript: transcript,
                                                  interval: interval, clipDuration: clipDuration, aligning: aligning, gemini: gemini)
                reportStep("Aligning speech and pauses · Short \(index + 1)")
                return (index, shot)
            }
            for (index, shot) in prepared {
                if shot.alignmentFailed { wordAlignmentAvailable = false }
                guard excluding.allSatisfy({ !TranscriptSelection.overlaps(start: shot.start, duration: shot.duration, otherStart: $0.start, otherDuration: $0.end - $0.start) }),
                      accepted.allSatisfy({ !TranscriptSelection.overlaps(start: shot.start, duration: shot.duration, otherStart: $0.range.start, otherDuration: $0.range.duration) })
                else { continue }
                accepted.append((index, shot))
                if accepted.count == targetCount { break }
            }
        }
        let results: [ShortResult] = try await concurrentMap(accepted) { candidateIndex, shot in
            let candidate = picks[candidateIndex]
            let start = shot.start, actualDuration = shot.duration
            let captionSource = !shot.words.isEmpty ? GeminiSelection.captionCues(shot.words, interval: (start, start + actualDuration)) : TranscriptSelection.sentenceCaptionGroups(shot.referenceCues)
            let captions = captionSource.compactMap { cue -> TimedCaption? in
                let cueEnd = cue.start + cue.duration
                let clipEnd = start + actualDuration
                guard cueEnd > start, cue.start < clipEnd else { return nil }
                let clippedStart = max(0, cue.start - start)
                let clippedEnd = min(actualDuration, cueEnd - start)
                return TimedCaption(text: cue.text, start: clippedStart, duration: max(0.15, clippedEnd - clippedStart))
            }
            let words = shot.words.compactMap { word -> TimedSpeechWord? in
                guard word.start >= start - 0.01, word.start + word.duration <= start + actualDuration + 0.01 else { return nil }
                return .init(text: word.text, start: word.start - start, duration: word.duration)
            }
            let cropKeyframes: [CropKeyframe] = candidate.fit
                ? [.init(time: 0, position: 0.5, preserveWholeFrame: true), .init(time: actualDuration, position: 0.5, preserveWholeFrame: true)]
                : await SubjectFramer.analyze(url, start: start, duration: actualDuration, zoom: 1.08, configuration: gemini, speech: captions)
            reportStep("Gemini · framing the subject")
            let warning = shot.referenceCues.isEmpty || !shot.words.isEmpty ? nil : sentenceTimingNote
            let title = candidate.title.map { String($0.prefix(100)) } ?? captions.first.map { String($0.text.prefix(100)) }
            return ShortResult(start: start, duration: actualDuration, caption: "", captions: captions,
                cropKeyframes: cropKeyframes, speechWords: words, analysisWarning: warning,
                suggestedTitle: title, selectionReason: candidate.reason.map { String($0.prefix(400)) }, fitToFrame: candidate.fit)
        }
        if results.isEmpty {
            // Returning the beginning of the source here made a failed analysis
            // look like a successful Short, even when that opening was filler.
            // Keep the user's existing edits intact and ask them to retry with a
            // different range instead of silently inventing a selection.
            if !excluding.isEmpty { throw GeminiSelection.Failure.noDistinctClips }
            throw GeminiSelection.Failure.noStrongClips
        }
        try Task.checkCancellation()
        generationProgress(1, "Shorts ready")
        return results.sorted { $0.start < $1.start }
    }

    /// A pick's final source range with the word timing and sentence captions found for it.
    struct PreparedShort: Sendable {
        let start: Double
        let duration: Double
        let words: [TimedSpeechWord]
        let referenceCues: [TimedCaption]
        let alignmentFailed: Bool
    }

    /// Turns Gemini's rough clip into exact boundaries: whole sentences, no filler at the edges, a little breathing room,
    /// no cut word, and both ends moved into the nearest pause in the audio.
    static func prepareShort(url: URL, start: Double, duration: Double, transcript: [TimedCaption], interval: (start: Double, end: Double),
                             clipDuration: Double, aligning: Bool, gemini: GeminiConfiguration) async throws -> PreparedShort {
        let phraseCut = TranscriptSelection.phraseRange(start: start, duration: duration, cues: transcript, interval: interval)
        // Cloud cues are whole sentences, so a Short never starts or stops in the middle of one.
        let sentences = TranscriptSelection.completeSentences(
            start: phraseCut.start, duration: phraseCut.duration, cues: transcript, interval: interval,
            minDuration: max(1, clipDuration * 0.65), maxDuration: min(90, clipDuration * 1.5))
        let snapped = TranscriptSelection.trimmedFiller(start: sentences.start, duration: sentences.duration, cues: transcript,
                                                        minDuration: max(1, clipDuration * 0.65))
        let phrase = TranscriptSelection.paddedPhraseRange(start: snapped.start, duration: snapped.duration, cues: transcript, interval: interval)
        let referenceCues = transcript.filter { cue in
            let middle = cue.start + cue.duration / 2
            return middle >= snapped.start && middle <= snapped.start + snapped.duration
        }
        var clipWords: [TimedSpeechWord] = []
        var alignmentFailed = false
        if !referenceCues.isEmpty, aligning {
            do {
                let proposed = try await GeminiSelection.transcribe(url: url,
                    interval: (max(interval.start, phrase.start - 0.5), min(interval.end, phrase.start + phrase.duration + 0.5)),
                    configuration: gemini, reference: referenceCues)
                let inside = proposed.filter { $0.start >= phrase.start - 0.01 && $0.start + $0.duration <= phrase.start + phrase.duration + 0.01 }
                if TranscriptSelection.alignmentIsReliable(inside, reference: referenceCues) { clipWords = inside }
            } catch {
                try Task.checkCancellation()
                alignmentFailed = true
            }
        }
        let whole = speechSafeRange(start: phrase.start, duration: phrase.duration, words: clipWords, interval: interval)
        let safe = strongOpening(start: whole.start, duration: whole.duration, words: clipWords, minDuration: max(1, clipDuration * 0.65))
        let quiet = await silenceSnapped(url: url, start: safe.start, duration: safe.duration, interval: interval, words: clipWords)
        return PreparedShort(start: quiet.start, duration: quiet.duration, words: clipWords, referenceCues: referenceCues, alignmentFailed: alignmentFailed)
    }

    /// Runs `transform` on every item, at most `limit` at a time, and returns the results in the items' order.
    static func concurrentMap<T: Sendable, R: Sendable>(_ items: [T], limit: Int = 3,
                                                        _ transform: @escaping @Sendable (T) async throws -> R) async throws -> [R] {
        var results = [R?](repeating: nil, count: items.count)
        try await withThrowingTaskGroup(of: (Int, R).self) { group in
            var next = 0
            func startNext() {
                guard next < items.count else { return }
                let index = next, item = items[next]
                next += 1
                group.addTask { (index, try await transform(item)) }
            }
            for _ in 0..<max(1, limit) { startNext() }
            while let (index, result) = try await group.next() {
                results[index] = result
                startNext()
            }
        }
        return results.compactMap { $0 }
    }

    /// Moves a Short's start and end into the nearest pause in its audio, so it never opens or closes on a clipped sound.
    /// The start may move up to 0.5 s earlier or 0.15 s later, the end 0.15 s earlier or 0.5 s later, never past `interval`
    /// or into a timed word. Without audio or a clear pause nearby, the range stays as it is.
    static func silenceSnapped(url: URL, start: Double, duration: Double, interval: (start: Double, end: Double),
                               words: [TimedSpeechWord] = []) async -> (start: Double, duration: Double) {
        let end = start + duration
        let from = max(interval.start, start - 0.6), to = min(interval.end, end + 0.6)
        guard to > from, let levels = audioLevels(url: url, from: from, to: to), levels.count > 20 else { return (start, duration) }
        let frame = 0.01
        // 50 ms smoothing ignores the tiny gaps inside a word.
        let smooth = levels.indices.map { index in
            let window = levels[max(0, index - 2)...min(levels.count - 1, index + 2)]
            return window.reduce(0, +) / Float(window.count)
        }
        let median = smooth.sorted()[smooth.count / 2]
        let threshold = max(0.003, median * 0.2)
        func time(_ index: Int) -> Double { from + (Double(index) + 0.5) * frame }
        func insideWord(_ t: Double) -> Bool { words.contains { $0.start + 0.02 < t && $0.start + $0.duration - 0.02 > t } }
        func nearestQuiet(to target: Double, from low: Double, to high: Double) -> Double? {
            smooth.indices.filter { time($0) >= low && time($0) <= high && smooth[$0] <= threshold && !insideWord(time($0)) }
                .min { abs(time($0) - target) < abs(time($1) - target) }.map(time)
        }
        let newStart = nearestQuiet(to: start, from: max(interval.start, start - 0.5), to: start + 0.15) ?? start
        let newEnd = nearestQuiet(to: end, from: end - 0.15, to: min(interval.end, end + 0.5)) ?? end
        guard newEnd - newStart > 0.5 else { return (start, duration) }
        return (newStart, newEnd - newStart)
    }

    /// Loudness (RMS) of the audio in 10 ms frames, read as 16 kHz mono; nil when the file has no readable audio.
    static func audioLevels(url: URL, from: Double, to: Double) -> [Float]? {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first, let reader = try? AVAssetReader(asset: asset) else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false
        ])
        reader.timeRange = CMTimeRange(start: CMTime(seconds: from, preferredTimescale: 16_000), end: CMTime(seconds: to, preferredTimescale: 16_000))
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            _ = chunk.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            samples += chunk
        }
        guard reader.status == .completed, !samples.isEmpty else { return nil }
        return stride(from: 0, to: samples.count, by: 160).map { first in
            let frame = samples[first..<min(samples.count, first + 160)]
            return (frame.reduce(0) { $0 + $1 * $1 } / Float(frame.count)).squareRoot()
        }
    }

    /// Drops up to three throat-clearing words ("So", "Um", "And", "Okay") from a Short's first line, so it opens on its
    /// hook. Needs real word timing; the cut lands 0.08 s before the next word and the Short keeps `minDuration`.
    // shortcut: English filler words only; add per-language lists if non-English sources matter.
    static func strongOpening(start: Double, duration: Double, words: [TimedSpeechWord], minDuration: Double) -> (start: Double, duration: Double) {
        // Only words that are filler at the start of a line; "like", "now", "then" and "right" often carry meaning there.
        let weak: Set<String> = ["so", "and", "but", "um", "uh", "erm", "okay", "ok", "well", "anyway", "alright", "yeah"]
        let end = start + duration
        let spoken = words.filter { $0.start >= start - 0.05 && $0.start < end }.sorted { $0.start < $1.start }
        func bare(_ word: TimedSpeechWord) -> String { word.text.lowercased().filter { $0.isLetter } }
        var dropped = 0
        while dropped < min(3, spoken.count - 1), weak.contains(bare(spoken[dropped])) { dropped += 1 }
        guard dropped > 0 else { return (start, duration) }
        let newStart = max(start, spoken[dropped].start - 0.08)
        guard end - newStart >= minDuration else { return (start, duration) }
        return (newStart, end - newStart)
    }

    static func speechSafeRange(
        start: Double,
        duration: Double,
        words: [TimedSpeechWord],
        interval: (start: Double, end: Double)
    ) -> (start: Double, duration: Double) {
        guard !words.isEmpty else { return (start, duration) }
        var safeStart = start
        if let cutWord = words.first(where: { $0.start + 0.02 < safeStart && $0.start + $0.duration - 0.02 > safeStart }) {
            let wordEnd = cutWord.start + cutWord.duration
            safeStart = cutWord.start >= interval.start ? max(interval.start, cutWord.start - 0.025) : min(interval.end, wordEnd + 0.025)
        }
        var safeEnd = min(interval.end, start + duration)
        if let cutWord = words.first(where: { $0.start + 0.02 < safeEnd && $0.start + $0.duration - 0.02 > safeEnd }) {
            let wordEnd = cutWord.start + cutWord.duration
            safeEnd = wordEnd <= interval.end ? min(interval.end, wordEnd + 0.04) : max(safeStart + 0.1, cutWord.start)
        }
        guard safeEnd > safeStart else { return (start, duration) }
        return (safeStart, safeEnd - safeStart)
    }

    static func analyzeSubjectPath(_ url: URL, start: Double, duration: Double, zoom: Double = 1.08, configuration: GeminiConfiguration,
                                   speech: [TimedCaption] = []) async -> [CropKeyframe] {
        await SubjectFramer.analyze(url, start: start, duration: duration, zoom: zoom, configuration: configuration, speech: speech)
    }

    /// Renders kept between edits (finished previews and Fit backgrounds), so repeats don't re-render.
    /// The README generator points it at its own work folder so it never touches the app's cache.
    nonisolated(unsafe) static var renderCacheDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("RelioRenderCache")

    static func renderCacheURL(_ key: String, prefix: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return renderCacheDirectory.appendingPathComponent("\(prefix)-\(digest).mp4")
    }

    /// Each cached file is a full-length Short, so keep only the newest ones.
    static func pruneRenderCache(keeping limit: Int = 24) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: renderCacheDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for (file, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(limit) { try? FileManager.default.removeItem(at: file) }
    }

    /// Output quality for exported Shorts. Every Short is composed at 1080×1920; the preset sets the file's size and codec.
    enum ExportQuality: String, CaseIterable, Identifiable, Sendable {
        case full, compact, small
        var id: String { rawValue }
        var title: String {
            switch self {
            case .full: "1080p · H.264"
            case .compact: "1080p · HEVC"
            case .small: "720p · H.264"
            }
        }
        var detail: String {
            switch self {
            case .full: "Best quality. Plays everywhere."
            case .compact: "Same quality, smaller files. Plays on recent phones and apps."
            case .small: "Smallest files, fastest to send."
            }
        }
        var resolution: String { self == .small ? "720 × 1280" : "1080 × 1920" }
        var preset: String {
            switch self {
            case .full: AVAssetExportPreset1920x1080
            case .compact: AVAssetExportPresetHEVC1920x1080
            case .small: AVAssetExportPreset1280x720
            }
        }
    }

    static func export(source: URL, segment: EditSegment, destination: URL, quality: ExportQuality = .full) async throws {
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw Failure.destinationExists }
        let (composition, videoComposition) = try await makeComposition(source: source, segment: segment, live: false)
        if let captions = captionLayer(for: segment) {
            let parent = CALayer(); parent.frame = captions.frame
            let video = CALayer(); video.frame = parent.frame
            parent.addSublayer(video)
            parent.addSublayer(captions)
            videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: video, in: parent)
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".relio-\(UUID()).mp4")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let session = AVAssetExportSession(asset: composition, presetName: quality.preset) else { throw Failure.cannotExport }
        session.videoComposition = videoComposition
        session.outputURL = temporary
        session.outputFileType = .mp4
        nonisolated(unsafe) let running = session
        await withTaskCancellationHandler { await running.export() } onCancel: { running.cancelExport() }
        try Task.checkCancellation()
        if session.status != .completed { throw session.error ?? Failure.cannotExport }
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    /// A live preview of `export`: the same composition, played at once instead of rendering a file first.
    /// Captions are shown separately with `captionLayer(for:)`, because players can't use an animation tool.
    @MainActor static func previewItem(source: URL, segment: EditSegment) async throws -> AVPlayerItem {
        let (composition, videoComposition) = try await makeComposition(source: source, segment: segment, live: true)
        let item = AVPlayerItem(asset: composition)
        item.videoComposition = videoComposition
        return item
    }

    /// The picture and sound of a Short. `live` draws the Fit background frame by frame during playback;
    /// export pre-renders it to a cached file instead. Both use `blurredFitFrame`.
    private static func makeComposition(source: URL, segment: EditSegment, live: Bool) async throws
        -> sending (AVMutableComposition, AVMutableVideoComposition) {
        let asset = AVURLAsset(url: source)
        let sourceDuration = try await asset.load(.duration).seconds
        guard segment.start.isFinite, segment.duration.isFinite, segment.start >= 0,
              segment.duration > 0, sourceDuration.isFinite,
              segment.start + segment.duration <= sourceDuration + 0.001,
              (segment.captionStart ?? 0).isFinite,
              (segment.captionDuration ?? segment.duration).isFinite else { throw Failure.invalidRange }
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.noVideo }
        let composition = AVMutableComposition()
        guard let composedVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw Failure.cannotExport }
        let range = CMTimeRange(start: CMTime(seconds: segment.start, preferredTimescale: 600), duration: CMTime(seconds: segment.duration, preferredTimescale: 600))
        try composedVideo.insertTimeRange(range, of: videoTrack, at: .zero)
        if segment.isMuted != true,
           let audioTrack = try await asset.loadTracks(withMediaType: .audio).first,
           let composedAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try composedAudio.insertTimeRange(range, of: audioTrack, at: .zero)
        }
        let natural = try await videoTrack.load(.naturalSize)
        let preferred = try await videoTrack.load(.preferredTransform)
        let transformed = CGRect(origin: .zero, size: natural).applying(preferred)
        let oriented = CGSize(width: abs(transformed.width), height: abs(transformed.height))
        let target = CGSize(width: 1080, height: 1920)
        guard oriented.width > 0, oriented.height > 0 else { throw Failure.noVideo }
        let isSplit = segment.splitScreen == true
        let usesBlurredFitBackground = !isSplit && segment.fitToFrame == true && oriented.width / oriented.height > target.width / target.height
        // Split and blurred Fit frames are drawn with Core Image instead of a layer transform.
        let drawsFrames = isSplit || usesBlurredFitBackground
        let draw: @Sendable (CIImage) -> CIImage
        let centers = segment.splitCenters ?? []
        // preferredTransform is in y-down video space; Core Image is y-up, so mirror it or rotated
        // phone video comes out upside down. The drawing code re-normalizes the translation.
        let upright = CGAffineTransform(a: preferred.a, b: -preferred.b, c: -preferred.c, d: preferred.d, tx: preferred.tx, ty: -preferred.ty)
        if isSplit { draw = { image in ShortMaker.splitScreenFrame(image, transform: upright, centers: centers) } }
        else { draw = { image in ShortMaker.blurredFitFrame(image, transform: upright) } }
        if drawsFrames && !live {
            // The drawn picture depends only on the layout and source range, so caption and style edits reuse it.
            let cached = isSplit
                ? renderCacheURL("split-v3|\(source.path)|\(segment.start)|\(segment.duration)|\(centers)", prefix: "split")
                : renderCacheURL("fit-v3|\(source.path)|\(segment.start)|\(segment.duration)", prefix: "fit")
            if !FileManager.default.fileExists(atPath: cached.path) {
                try FileManager.default.createDirectory(at: renderCacheDirectory, withIntermediateDirectories: true)
                let intermediate = renderCacheDirectory.appendingPathComponent(".relio-fit-\(UUID()).mp4")
                defer { try? FileManager.default.removeItem(at: intermediate) }
                try await renderFrames(asset: asset, track: videoTrack, range: range, outputURL: intermediate, draw: draw)
                try? FileManager.default.moveItem(at: intermediate, to: cached) // fails only if a parallel render stored it first
                pruneRenderCache()
            }
            let blurredAsset = AVURLAsset(url: cached)
            guard let blurredTrack = try await blurredAsset.loadTracks(withMediaType: .video).first else { throw Failure.cannotExport }
            try composedVideo.removeTimeRange(CMTimeRange(start: .zero, duration: range.duration))
            try composedVideo.insertTimeRange(CMTimeRange(start: .zero, duration: range.duration), of: blurredTrack, at: .zero)
        }
        let baseScale = segment.fitToFrame == true
            ? min(target.width / oriented.width, target.height / oriented.height)
            : max(target.width / oriented.width, target.height / oriented.height)
        let scale = baseScale * (segment.fitToFrame == true ? 1 : min(2, max(1, segment.cropZoom ?? 1.08)))
        let normalized = preferred.concatenating(CGAffineTransform(translationX: -transformed.minX, y: -transformed.minY))
        let baseTransform = normalized.concatenating(CGAffineTransform(scaleX: scale, y: scale)).concatenating(CGAffineTransform(translationX: (target.width - oriented.width * scale) / 2, y: (target.height - oriented.height * scale) / 2))
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: segment.duration, preferredTimescale: 600))
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: composedVideo)
        let panDistance = drawsFrames || segment.fitToFrame == true || oriented.width / oriented.height < 1.2
            ? 0 : max(0, oriented.width * scale - target.width)
        if panDistance > 2 {
            if let trackedPath = segment.cropKeyframes {
                let bias = (segment.cropPosition ?? 0.5) - 0.5
                let path = trackedPath
                    .filter { $0.time.isFinite && $0.position.isFinite }
                    .map { CropKeyframe(time: min(segment.duration, max(0, $0.time)), position: min(1, max(0, $0.position + bias)), isSceneCut: $0.isSceneCut, preserveWholeFrame: $0.preserveWholeFrame) }
                    .sorted { $0.time < $1.time }
                if path.isEmpty {
                    let position = min(1, max(0, segment.cropPosition ?? 0.5))
                    let offset = panDistance * (0.5 - position)
                    layer.setTransform(baseTransform.concatenating(CGAffineTransform(translationX: offset, y: 0)), at: .zero)
                } else {
                    var completePath = path
                    if let first = path.first, first.time > 0 { completePath.insert(.init(time: 0, position: first.position, preserveWholeFrame: first.preserveWholeFrame), at: 0) }
                    if let last = path.last, last.time < segment.duration { completePath.append(.init(time: segment.duration, position: last.position, preserveWholeFrame: last.preserveWholeFrame)) }
                    // Eased at render time, so saved paths, older Shorts and hand-set focus points all move smoothly.
                    let smoothPath = SubjectFramer.eased(completePath)
                    for pair in zip(smoothPath, smoothPath.dropFirst()) where pair.1.time > pair.0.time {
                        let fromOffset = panDistance * (0.5 - pair.0.position)
                        let toOffset = panDistance * (0.5 - pair.1.position)
                        let fitScale = min(target.width / oriented.width, target.height / oriented.height)
                        let fitTransform = normalized.concatenating(CGAffineTransform(scaleX: fitScale, y: fitScale)).concatenating(CGAffineTransform(translationX: (target.width - oriented.width * fitScale) / 2, y: (target.height - oriented.height * fitScale) / 2))
                        let from = pair.0.preserveWholeFrame == true ? fitTransform : baseTransform.concatenating(CGAffineTransform(translationX: fromOffset, y: 0))
                        let to = pair.1.preserveWholeFrame == true ? fitTransform : baseTransform.concatenating(CGAffineTransform(translationX: toOffset, y: 0))
                        if pair.1.isSceneCut == true {
                            layer.setTransform(from, at: CMTime(seconds: pair.0.time, preferredTimescale: 600))
                            layer.setTransform(to, at: CMTime(seconds: pair.1.time, preferredTimescale: 600))
                        } else {
                            layer.setTransformRamp(fromStart: from, toEnd: to, timeRange: CMTimeRange(
                                start: CMTime(seconds: pair.0.time, preferredTimescale: 600),
                                duration: CMTime(seconds: pair.1.time - pair.0.time, preferredTimescale: 600)
                            ))
                        }
                    }
                }
            } else {
                let position = min(1, max(0, segment.cropPosition ?? 0.5))
                let offset = panDistance * (0.5 - position)
                layer.setTransform(baseTransform.concatenating(CGAffineTransform(translationX: offset, y: 0)), at: .zero)
            }
        } else {
            layer.setTransform(drawsFrames ? .identity : baseTransform, at: .zero)
        }
        let videoComposition = AVMutableVideoComposition()
        instruction.layerInstructions = [layer]
        videoComposition.instructions = [instruction]
        videoComposition.renderSize = target
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        if drawsFrames && live {
            let fit = AVMutableVideoComposition(asset: composition) { request in
                request.finish(with: draw(request.sourceImage), context: nil)
            }
            fit.renderSize = target
            fit.frameDuration = videoComposition.frameDuration
            return (composition, fit)
        }
        return (composition, videoComposition)
    }

    /// Captions and the text overlay as layers in 1080×1920 video coordinates, timed from AVCoreAnimationBeginTimeAtZero.
    static func captionLayer(for segment: EditSegment) -> CALayer? {
        guard !(segment.captions ?? []).isEmpty || !segment.caption.isEmpty else { return nil }
        let parent = CALayer(); parent.frame = CGRect(x: 0, y: 0, width: 1080, height: 1920)
        let captions = segment.captions ?? []
        let position = segment.captionPosition ?? .bottom
        let y = position.y
        let scale = (segment.captionSize ?? .medium).scale
        let pops = segment.captionAnimated == true
        // The on-screen text overlay moves out of the subtitles' way.
        let overlayY: CGFloat = captions.isEmpty ? 220 : position == .top ? 330 : 1450
        let style = (segment.captionStyle ?? .classic).resolved
        // Word-following styles need real word timings; estimated timings would mark the wrong word.
        let timedWords = style.usesWordTiming || style == .boldCaps ? (segment.speechWords ?? []) : []
        for cue in captions {
            let cueWords = timedWords.filter {
                $0.start >= cue.start - 0.02 && $0.start + $0.duration <= cue.start + cue.duration + 0.02
            }.sorted { $0.start < $1.start }
            guard !cueWords.isEmpty, normalizedCaptionWords(cueWords.map(\.text)) == normalizedCaptionWords([cue.text]) else {
                addCaption(cue.text, start: cue.start, duration: cue.duration, total: segment.duration, y: y, style: style,
                           scale: scale, pops: pops, to: parent)
                continue
            }
            func end(of index: Int) -> Double { index + 1 < cueWords.count ? cueWords[index + 1].start : cue.start + cue.duration }
            switch style {
            case .boldCaps:
                for first in stride(from: 0, to: cueWords.count, by: 3) {
                    let group = cueWords[first..<min(first + 3, cueWords.count)]
                    addCaption(group.map(\.text).joined(separator: " "), start: group.first!.start,
                               duration: max(0.01, end(of: group.endIndex - 1) - group.first!.start),
                               total: segment.duration, y: y, style: style, scale: scale, pops: pops, to: parent)
                }
            case .oneWord:
                for (index, word) in cueWords.enumerated() {
                    addCaption(word.text, start: word.start, duration: max(0.01, end(of: index) - word.start),
                               total: segment.duration, y: y, style: style, scale: scale, pops: pops, to: parent)
                }
            case .viral, .highlightBox, .podcast:
                for (index, word) in cueWords.enumerated() {
                    // Only a new line pops; a moving highlight inside the same line must not bounce on every word.
                    addCaption(cue.text, start: word.start, duration: max(0.01, end(of: index) - word.start),
                               total: segment.duration, y: y, highlightedWord: index, style: style,
                               scale: scale, pops: pops && index == 0, to: parent)
                }
            default:
                addCaption(cue.text, start: cue.start, duration: cue.duration, total: segment.duration, y: y, style: style,
                           scale: scale, pops: pops, to: parent)
            }
        }
        if !segment.caption.isEmpty {
            addCaption(segment.caption, start: segment.captionStart ?? 0,
                       duration: segment.captionDuration ?? segment.duration, total: segment.duration,
                       y: overlayY, to: parent)
        }
        return parent
    }

    /// One Fit frame at 1080×1920: the whole source, centered over a blurred, zoomed copy of itself.
    static func blurredFitFrame(_ source: CIImage, transform: CGAffineTransform) -> CIImage {
        let renderSize = CGSize(width: 1080, height: 1920)
        let canvas = CGRect(origin: .zero, size: renderSize)
        let transformed = source.transformed(by: transform)
        let transformedBounds = CGRect(origin: .zero, size: source.extent.size).applying(transform)
        let normalized = transformed.transformed(by: CGAffineTransform(translationX: -transformedBounds.minX,
                                                                          y: -transformedBounds.minY))
        let extent = CGRect(origin: .zero, size: CGSize(width: transformedBounds.width, height: transformedBounds.height))
        // A heavy blur keeps no fine detail, so blur at 1/8 size and scale up: same look, far less GPU work.
        let blurScale: CGFloat = 0.125
        let backgroundScale = max(renderSize.width / extent.width, renderSize.height / extent.height) * 1.08 * blurScale
        let background = normalized
            .transformed(by: CGAffineTransform(scaleX: backgroundScale, y: backgroundScale))
            .transformed(by: CGAffineTransform(translationX: (renderSize.width * blurScale - extent.width * backgroundScale) / 2,
                                                y: (renderSize.height * blurScale - extent.height * backgroundScale) / 2))
            .clampedToExtent()
            .applyingGaussianBlur(sigma: 36 * blurScale)
            .cropped(to: CGRect(x: 0, y: 0, width: renderSize.width * blurScale, height: renderSize.height * blurScale))
            .transformed(by: CGAffineTransform(scaleX: 1 / blurScale, y: 1 / blurScale))
            .clampedToExtent()
            .cropped(to: canvas)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.68, kCIInputContrastKey: 1.04, kCIInputBrightnessKey: -0.08])
        let foregroundScale = min(renderSize.width / extent.width, renderSize.height / extent.height)
        let foreground = normalized
            .transformed(by: CGAffineTransform(scaleX: foregroundScale, y: foregroundScale))
            .transformed(by: CGAffineTransform(translationX: (renderSize.width - extent.width * foregroundScale) / 2,
                                                y: (renderSize.height - extent.height * foregroundScale) / 2))
        return foreground.composited(over: background).cropped(to: canvas)
    }

    /// Face centers from sampled frames → the two speakers' horizontal centers, left first; nil unless two clear groups exist.
    static func splitCenters(fromFaceXs xs: [Double]) -> [Double]? {
        let sorted = xs.filter { $0.isFinite && (0...1).contains($0) }.sorted()
        guard sorted.count >= 2 else { return nil }
        let gaps = zip(sorted, sorted.dropFirst()).enumerated().map { ($0.offset, $0.element.1 - $0.element.0) }
        guard let widest = gaps.max(by: { $0.1 < $1.1 }), widest.1 >= 0.15 else { return nil }
        let left = sorted[...widest.0], right = sorted[(widest.0 + 1)...]
        return [left.reduce(0, +) / Double(left.count), right.reduce(0, +) / Double(right.count)]
    }

    /// Asks Gemini where the two people sit across a Short, left first; nil unless two clear groups of faces exist.
    static func findSplitCenters(_ url: URL, start: Double, duration: Double, configuration: GeminiConfiguration) async -> [Double]? {
        let images = await Task.detached(priority: .utility) { () -> [CGImage] in
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 512, height: 512)
            return (0..<8).compactMap { index in
                try? generator.copyCGImage(at: CMTime(seconds: start + duration * (Double(index) + 0.5) / 8, preferredTimescale: 600), actualTime: nil)
            }
        }.value
        guard !images.isEmpty, let located = await SubjectFramer.locate(images, configuration: configuration) else { return nil }
        return splitCenters(fromFaceXs: located.frames.flatMap(\.faces))
    }

    /// One split-screen frame at 1080×1920: the left speaker fills the top, the right speaker the bottom.
    /// Each panel shows a half-width window centered on its speaker (`centers`), or on the left/right quarter.
    static func splitScreenFrame(_ source: CIImage, transform: CGAffineTransform, centers: [Double] = []) -> CIImage {
        let canvas = CGRect(x: 0, y: 0, width: 1080, height: 1920)
        let bounds = CGRect(origin: .zero, size: source.extent.size).applying(transform)
        let oriented = source.transformed(by: transform)
            .transformed(by: CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
        let half = CGSize(width: bounds.width / 2, height: bounds.height)
        let panel = CGSize(width: 1080, height: 960)
        let scale = max(panel.width / half.width, panel.height / half.height)
        // Core Image's origin is bottom-left, so the top panel starts at y 960.
        func windowX(_ center: Double) -> CGFloat {
            min(bounds.width - half.width, max(0, CGFloat(center) * bounds.width - half.width / 2))
        }
        func place(fromX x: CGFloat, atY y: CGFloat) -> CIImage {
            oriented.cropped(to: CGRect(x: x, y: 0, width: half.width, height: half.height))
                .transformed(by: CGAffineTransform(translationX: -x, y: 0))
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .transformed(by: CGAffineTransform(translationX: (panel.width - half.width * scale) / 2,
                                                   y: y + (panel.height - half.height * scale) / 2))
                .cropped(to: CGRect(x: 0, y: y, width: panel.width, height: panel.height))
        }
        let top = centers.count == 2 ? windowX(centers[0]) : 0
        let bottom = centers.count == 2 ? windowX(centers[1]) : half.width
        return place(fromX: top, atY: 960)
            .composited(over: place(fromX: bottom, atY: 0))
            .composited(over: CIImage(color: .black).cropped(to: canvas))
            .cropped(to: canvas)
    }

    private static func renderFrames(asset: AVAsset, track: AVAssetTrack, range: CMTimeRange,
                                     outputURL: URL, draw: (CIImage) -> CIImage) async throws {
        let renderSize = CGSize(width: 1080, height: 1920)
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = range
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw Failure.cannotExport }
        reader.add(output)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(renderSize.width),
            AVVideoHeightKey: Int(renderSize.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000]
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(renderSize.width),
            kCVPixelBufferHeightKey as String: Int(renderSize.height),
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true
        ])
        guard writer.canAdd(input) else { throw Failure.cannotExport }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? Failure.cannotExport }
        guard reader.startReading() else { throw reader.error ?? Failure.cannotExport }
        writer.startSession(atSourceTime: .zero)

        let ciContext = CIContext(options: [.cacheIntermediates: false])
        let canvas = CGRect(origin: .zero, size: renderSize)
        var frameCount = 0
        // The final Short is 30 fps; drawing every frame of a 60 fps source would double the work for nothing.
        let frameInterval = 1.0 / 30
        var nextOutputTime = 0.0
        while let sample = output.copyNextSampleBuffer() {
            if Task.isCancelled { reader.cancelReading(); writer.cancelWriting(); throw CancellationError() }
            let outputSeconds = CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(sample), range.start).seconds
            if outputSeconds < nextOutputTime - frameInterval * 0.25 { continue }
            nextOutputTime += frameInterval
            while nextOutputTime <= outputSeconds { nextOutputTime += frameInterval }
            while !input.isReadyForMoreMediaData {
                if Task.isCancelled { reader.cancelReading(); writer.cancelWriting(); throw CancellationError() }
                try await Task.sleep(for: .milliseconds(4))
            }
            guard let sourceBuffer = CMSampleBufferGetImageBuffer(sample), let pool = adaptor.pixelBufferPool else {
                reader.cancelReading(); writer.cancelWriting(); throw Failure.cannotExport
            }
            var destinationBuffer: CVPixelBuffer?
            let allocation = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &destinationBuffer)
            guard allocation == kCVReturnSuccess, let destinationBuffer else {
                reader.cancelReading(); writer.cancelWriting(); throw Failure.cannotExport
            }
            ciContext.render(draw(CIImage(cvPixelBuffer: sourceBuffer)), to: destinationBuffer,
                             bounds: canvas, colorSpace: CGColorSpaceCreateDeviceRGB())
            let sourceTime = CMSampleBufferGetPresentationTimeStamp(sample)
            let outputTime = CMTimeSubtract(sourceTime, range.start)
            guard adaptor.append(destinationBuffer, withPresentationTime: outputTime) else {
                reader.cancelReading(); writer.cancelWriting(); throw writer.error ?? Failure.cannotExport
            }
            frameCount += 1
        }
        guard reader.status == .completed, frameCount > 0 else {
            writer.cancelWriting(); throw reader.error ?? Failure.cannotExport
        }
        input.markAsFinished()
        await withCheckedContinuation { continuation in writer.finishWriting { continuation.resume() } }
        guard writer.status == .completed else { throw writer.error ?? Failure.cannotExport }
    }

    private static func addCaption(_ text: String, start: Double, duration: Double, total: Double, y: CGFloat,
                                   highlightedWord: Int? = nil, style: CaptionStyle = .classic, scale: CGFloat = 1,
                                   pops: Bool = false, to parent: CALayer) {
        guard start.isFinite, duration.isFinite, total > 0, start < total, duration > 0,
              let image = captionImage(text, highlightedWord: highlightedWord, style: style, scale: scale) else { return }
        let captionLayer = CALayer()
        captionLayer.frame = CGRect(x: 70, y: y, width: 940, height: CGFloat(image.height))
        captionLayer.contents = image
        let overlayStart = max(0, min(start, total))
        let overlayDuration = min(duration, total - overlayStart)
        captionLayer.opacity = 0
        let visibility = CAKeyframeAnimation(keyPath: "opacity")
        visibility.values = [0, 1, 0, 0]
        visibility.keyTimes = [0, NSNumber(value: overlayStart / total), NSNumber(value: (overlayStart + overlayDuration) / total), 1]
        visibility.calculationMode = .discrete
        visibility.beginTime = AVCoreAnimationBeginTimeAtZero
        visibility.duration = total
        visibility.fillMode = .both
        visibility.isRemovedOnCompletion = false
        captionLayer.add(visibility, forKey: "captionVisibility")
        if pops {
            let pop = CAKeyframeAnimation(keyPath: "transform.scale")
            pop.values = [0.8, 1.08, 1]
            pop.keyTimes = [0, 0.6, 1]
            pop.duration = min(0.2, overlayDuration)
            // Zero means "now" to Core Animation; video timelines need the AVFoundation constant instead.
            pop.beginTime = overlayStart > 0 ? overlayStart : AVCoreAnimationBeginTimeAtZero
            pop.fillMode = .both
            pop.isRemovedOnCompletion = false
            captionLayer.add(pop, forKey: "captionPop")
        }
        parent.addSublayer(captionLayer)
    }

    /// A sample of each subtitle style, drawn by the same code as exported captions so the picker matches the video.
    static func captionPreview(_ style: CaptionStyle) -> CGImage? {
        let image: CGImage? = switch style.resolved {
        case .oneWord: captionImage("Hello", style: style)
        case .viral, .highlightBox, .podcast: captionImage("Hello everyone", highlightedWord: 0, style: style)
        default: captionImage("Hello everyone", style: style)
        }
        return image.flatMap { trimmedToContent($0, padding: 14) } ?? image
    }

    /// Crops away the transparent margin so a small preview shows the text large.
    private static func trimmedToContent(_ image: CGImage, padding: Int) -> CGImage? {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 8 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        // The buffer's rows run top-down, which matches CGImage cropping.
        let box = CGRect(x: max(0, minX - padding), y: max(0, minY - padding),
                         width: min(width, maxX + padding + 1) - max(0, minX - padding),
                         height: min(height, maxY + padding + 1) - max(0, minY - padding))
        return image.cropping(to: box)
    }

    /// One caption image, 940 px wide, for any subtitle style. `highlightedWord` marks the spoken word.
    private static func captionImage(_ text: String, highlightedWord: Int? = nil, style: CaptionStyle = .classic, scale k: CGFloat = 1) -> CGImage? {
        let style = style.resolved
        let height = Int(((style == .boldCaps ? 300 : 210) * k).rounded())
        // Draw at exactly the pixels export uses; NSImage focus would render 2× on Retina and scale down.
        guard let context = CGContext(data: nil, width: 940, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let bounds = NSRect(x: 24, y: 30 * k, width: 892, height: CGFloat(height) - 45 * k)
        let shown = style == .boldCaps ? text.uppercased() : text
        let highlight: NSRange? = highlightedWord.flatMap { index in
            let ranges = (try? NSRegularExpression(pattern: "\\S+"))?.matches(in: shown, range: NSRange(location: 0, length: (shown as NSString).length)) ?? []
            return ranges.indices.contains(index) ? ranges[index].range : nil
        }

        switch style {
        case .minimal:
            // Calm text on a soft dark band sized to the words.
            let words = NSAttributedString(string: shown, attributes: [.font: NSFont.systemFont(ofSize: 46 * k, weight: .semibold),
                                                                       .foregroundColor: NSColor.white, .paragraphStyle: paragraph])
            let size = words.boundingRect(with: NSSize(width: bounds.width - 48 * k, height: bounds.height),
                                          options: [.usesLineFragmentOrigin, .usesFontLeading]).size
            let textWidth = ceil(size.width) + 2, textHeight = ceil(size.height)
            let band = NSRect(x: bounds.midX - textWidth / 2 - 24 * k, y: bounds.maxY - textHeight - 20 * k,
                              width: textWidth + 48 * k, height: textHeight + 20 * k)
            NSColor.black.withAlphaComponent(0.62).setFill()
            NSBezierPath(roundedRect: band, xRadius: 18 * k, yRadius: 18 * k).fill()
            words.draw(in: NSRect(x: band.minX + 24 * k, y: band.minY + 10 * k, width: textWidth, height: textHeight))
        case .podcast:
            // White text with a soft shadow; the spoken word in green.
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.85)
            shadow.shadowBlurRadius = 10 * k
            shadow.shadowOffset = NSSize(width: 0, height: -2 * k)
            let words = NSMutableAttributedString(string: shown, attributes: [.font: NSFont.systemFont(ofSize: 56 * k, weight: .bold),
                                                                              .foregroundColor: NSColor.white, .paragraphStyle: paragraph, .shadow: shadow])
            if let highlight {
                words.addAttribute(.foregroundColor, value: NSColor(srgbRed: 0.22, green: 0.89, blue: 0.49, alpha: 1), range: highlight)
            }
            words.draw(in: bounds)
        default:
            // Simple, Viral, Highlight box, Bold caps and One word: heavy white text with a black outline.
            let size: CGFloat = (style == .oneWord ? 104 : style == .boldCaps ? 76 : 66) * k
            let radius: CGFloat = (style == .oneWord ? 5 : style == .boldCaps ? 4 : 3) * k
            let font = NSFont.systemFont(ofSize: size, weight: .heavy)
            // The outline is the text repeated in black around the edge. A stroke instead would cut into the
            // counters of letters such as e and a, leaving stray lines inside them.
            let outline = NSAttributedString(string: shown, attributes: [.font: font, .foregroundColor: NSColor.black, .paragraphStyle: paragraph])
            for step in 0..<16 {
                let angle = CGFloat(step) * .pi / 8
                outline.draw(in: bounds.offsetBy(dx: cos(angle) * radius, dy: sin(angle) * radius))
            }
            let fill = NSMutableAttributedString(string: shown, attributes: [.font: font, .foregroundColor: NSColor.white, .paragraphStyle: paragraph])
            if let highlight {
                if style == .highlightBox {
                    fill.addAttributes([.backgroundColor: NSColor.yellow, .foregroundColor: NSColor.black], range: highlight)
                } else {
                    fill.addAttribute(.foregroundColor, value: NSColor.yellow, range: highlight)
                }
            }
            fill.draw(in: bounds)
        }
        return context.makeImage()
    }

    private static func normalizedCaptionWords(_ words: [String]) -> [String] {
        words.flatMap { $0.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init) }
    }
}

private extension NSShadow {
    func also(_ configure: (NSShadow) -> Void) -> NSShadow { configure(self); return self }
}
