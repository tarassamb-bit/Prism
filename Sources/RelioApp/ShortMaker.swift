import Foundation
import AVFoundation
import Speech
import NaturalLanguage
import CryptoKit
import Vision
import AppKit
import CoreImage

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
    case permissionDenied
    case permissionRestricted
    case unavailableOnDevice
    case noSpeech
    case recognitionFailed
    case invalidRange

    var message: String {
        switch self {
        case .permissionDenied:
            "Enable Speech Recognition for Prism in System Settings, then try again."
        case .permissionRestricted:
            "Speech Recognition is restricted on this Mac."
        case .unavailableOnDevice:
            "On-device speech recognition is unavailable for the current language on this Mac."
        case .noSpeech:
            "No speech was detected in this Short. Check the audio and spoken language."
        case .recognitionFailed:
            "Speech recognition failed. Check its availability and try again."
        case .invalidRange:
            "The Short has an invalid time range. Adjust its start and duration, then try again."
        }
    }
}

struct CaptionGenerationResult {
    var cues: [TimedCaption]
    var issue: CaptionGenerationIssue?
    var words: [TimedSpeechWord] = []
    var notice: String? = nil
}

private struct VisualMomentSample: Sendable {
    var time: Double
    var interest: Double
    var labels: [String]
    var motion: Double
    var luminance: [UInt8]?
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

    static func analyze(_ url: URL) async throws -> ShortResult {
        try await analyze(url, requestedDuration: 45, count: 1, sourceRegion: .entireVideo)[0]
    }

    /// `languageHint` is existing caption text; it picks the recognizer language instead of the Mac's.
    static func captions(for url: URL, start: Double, duration: Double, languageHint: String? = nil) async -> CaptionGenerationResult {
        guard start.isFinite, duration.isFinite, start >= 0, duration > 0 else {
            return .init(cues: [], issue: .invalidRange)
        }
        let transcription = await transcribe(url, interval: (start, start + duration), locale: languageHint.flatMap(speechLocale(forText:)))
        let cues = transcription.cues.compactMap { cue -> TimedCaption? in
            let cueEnd = cue.start + cue.duration
            guard cueEnd > start, cue.start < start + duration else { return nil }
            let clippedStart = max(start, cue.start)
            let clippedEnd = min(start + duration, cueEnd)
            return TimedCaption(text: cue.text, start: clippedStart - start, duration: max(0.15, clippedEnd - clippedStart))
        }
        let words = transcription.words.compactMap { word -> TimedSpeechWord? in
            let end = word.start + word.duration
            guard end > start, word.start < start + duration,
                  word.start >= start - 0.01, end <= start + duration + 0.01 else { return nil }
            return .init(text: word.text, start: word.start - start, duration: word.duration)
        }
        return .init(cues: cues, issue: cues.isEmpty ? transcription.issue ?? .noSpeech : nil, words: words)
    }

    static func analyze(
        _ url: URL,
        requestedDuration: Double,
        count: Int,
        sourceRegion: SourceRegion,
        customStart: Double? = nil,
        customEnd: Double? = nil,
        excluding: [SourceInterval] = [],
        transcriptionEnabled: Bool = true,
        gemini: GeminiConfiguration? = nil,
        videoType: VideoType = .general,
        cachedTranscript: SentenceTranscript? = nil,
        onTranscript: @escaping @Sendable (SentenceTranscript) -> Void = { _ in },
        progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in },
        generationProgress: @escaping @Sendable (Double, String) -> Void = { _, _ in }
    ) async throws -> [ShortResult] {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0, !(try await asset.loadTracks(withMediaType: .video)).isEmpty else { throw Failure.noVideo }
        let interval = try sourceRegion.interval(videoDuration: duration, customStart: customStart, customEnd: customEnd)
        guard !excluding.contains(where: { $0.start <= interval.start && $0.end >= interval.end }) else { throw GeminiSelection.Failure.noDistinctClips }
        let clipDuration = min(max(1, requestedDuration), interval.end - interval.start)
        let latestStart = max(interval.start, interval.end - clipDuration)
        let targetCount = min(max(1, count), 10)
        let hasAudio = !(try await asset.loadTracks(withMediaType: .audio)).isEmpty
        let sampleStep = max(0.5, (interval.end - interval.start) / 240)
        let visualSamples: [VisualMomentSample] = gemini != nil ? [] : await analyzeVisualFrames(url, interval: interval, step: sampleStep, progress: { done, total in
            progress(done, total)
            generationProgress(0.4 * Double(done) / Double(max(1, total)), "Scanning video frames")
        })
        generationProgress(gemini == nil ? 0.4 : 0, gemini == nil ? "Transcribing speech" : "Preparing audio for Gemini")
        let transcription: CaptionGenerationResult
        if let gemini, hasAudio, transcriptionEnabled {
            if let saved = cachedTranscript?.cues(covering: interval) {
                // Saved by an earlier run on this video: no audio upload and no transcription cost.
                generationProgress(0.55, "Using the saved transcript")
                transcription = .init(cues: saved, issue: nil, words: [])
            } else {
                let sentences = try await GeminiSelection.transcribeSentences(url: url, interval: interval, configuration: gemini, progress: { fraction in
                    generationProgress(0.55 * fraction, "Gemini · transcribing audio · \(Int(fraction * 100))%")
                })
                onTranscript(SentenceTranscript(start: interval.start, end: interval.end, cues: sentences))
                transcription = .init(cues: sentences, issue: nil, words: [])
            }
        } else if hasAudio && transcriptionEnabled {
            transcription = await transcribe(url, interval: interval, progress: { fraction in
                generationProgress(0.4 + 0.15 * fraction, "Transcribing speech · \(Int(fraction * 100))%")
            })
        } else {
            transcription = .init(cues: [], issue: nil)
        }
        generationProgress(0.55, "Selecting distinct moments")
        let transcript = transcription.cues
        var videoType = videoType
        if videoType == .auto {
            if let gemini, !transcript.isEmpty {
                generationProgress(0.55, "Gemini · recognizing the kind of video")
                videoType = await GeminiSelection.detectVideoType(cues: transcript, configuration: gemini)
                generationProgress(0.55, "Gemini · \(videoType.title)")
            } else {
                // Detection needs the cloud transcript; on-device runs keep the general behavior.
                videoType = .general
            }
        }
        let scanStep = max(sampleStep, min(5.0, clipDuration / 8))
        var candidateStarts = stride(from: interval.start, through: latestStart, by: scanStep).map { $0 }
        candidateStarts += transcript.map { min(latestStart, max(interval.start, $0.start)) }
        candidateStarts = Array(Set(candidateStarts.map { (max(interval.start, min(latestStart, $0)) * 10).rounded() / 10 })).sorted()

        candidateStarts = candidateStarts.filter { start in excluding.allSatisfy { used in
            !TranscriptSelection.overlaps(start: start, duration: clipDuration, otherStart: used.start, otherDuration: used.end - used.start)
        } }
        let baseRanked = candidateStarts.map { start -> (start: Double, score: Double) in
            let end = start + clipDuration
            let window = visualSamples.filter { $0.time >= start && $0.time < end }
            let visualScore: Double
            if window.isEmpty { visualScore = 0 }
            else {
                let meanInterest = window.map(\.interest).reduce(0, +) / Double(window.count)
                let variety = Double(Set(window.compactMap(\.labels.first)).count) / Double(max(1, min(window.count, 6)))
                let meanMotion = window.map(\.motion).reduce(0, +) / Double(window.count)
                let peakMotion = window.map(\.motion).max() ?? 0
                let motionScore = min(1, meanMotion * 0.7 + peakMotion * 0.3)
                visualScore = min(1, meanInterest * 0.58 + min(1, variety) * 0.17 + motionScore * 0.25)
            }
            let speech = transcript.filter { $0.start + $0.duration > start && $0.start < end }
            let speechCoverage = min(1, speech.reduce(0) { $0 + $1.duration } / max(1, clipDuration * 0.45))
            let speechEmphasis = min(1, Double(speech.reduce(0) { $0 + score($1.text) }) / 70)
            return (start, visualScore * 0.72 + speechCoverage * 0.18 + speechEmphasis * 0.10)
        }.sorted { $0.score > $1.score }

        // OpenShorts-inspired coarse-to-fine selection: score overlapping transcript
        // windows across the entire selected region before refining individual clips.
        var ranked = baseRanked
        if gemini == nil, transcriptionEnabled, !transcript.isEmpty, LocalAIEngine.isInstalled {
            generationProgress(0.55, "Ranking transcript windows")
            let windows = TranscriptSelection.windows(transcript, interval: interval)
            if let scores = await TranscriptSelection.scoreWindows(windows, scorer: { await LocalAIEngine.scoreMoments($0) }) {
                ranked = baseRanked.map { candidate in
                    let end = candidate.start + clipDuration
                    let matches = zip(windows, scores).filter {
                        $0.0.start < end && $0.0.end > candidate.start
                    }
                    let weight = matches.reduce(0.0) { $0 + max(0, min(end, $1.0.end) - max(candidate.start, $1.0.start)) }
                    let narrative = matches.reduce(0.0) {
                        $0 + $1.1 * max(0, min(end, $1.0.end) - max(candidate.start, $1.0.start))
                    } / max(0.001, weight)
                    return (candidate.start, candidate.score * 0.65 + narrative * 0.35)
                }.sorted { $0.score == $1.score ? $0.start < $1.start : $0.score > $1.score }
            }
            // Spread the detail pass across distinct moments instead of spending
            // the model context on many near-identical overlapping candidates.
            var shortlist: [(start: Double, score: Double)] = []
            for candidate in ranked {
                let hasSpeech = transcript.contains {
                    $0.start >= candidate.start && $0.start + $0.duration <= candidate.start + clipDuration &&
                    !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                guard hasSpeech else { continue }
                if shortlist.allSatisfy({ !TranscriptSelection.overlaps(start: candidate.start, duration: clipDuration,
                                                                       otherStart: $0.start, otherDuration: clipDuration) }) {
                    shortlist.append(candidate)
                }
                if shortlist.count == 24 { break }
            }
            let excerpts = shortlist.map { candidate in
                transcript.filter { $0.start >= candidate.start && $0.start + $0.duration <= candidate.start + clipDuration }
                    .map(\.text).joined(separator: " ")
            }
            if let detailScores = await TranscriptSelection.scoreWindows(
                zip(shortlist, excerpts).map { .init(start: $0.0.start, end: $0.0.start + clipDuration, text: $0.1) },
                scorer: { await LocalAIEngine.scoreMoments($0) }) {
                let details = Dictionary(uniqueKeysWithValues: zip(shortlist.map(\.start), detailScores))
                // Only refine scored candidates; compare them first, then retain
                // the coarse ranking as fallback if fewer disjoint clips fit.
                let refined: [(start: Double, score: Double)] = shortlist.map { candidate in
                    let detail = details[candidate.start] ?? 0
                    return (start: candidate.start, score: candidate.score * 0.65 + detail * 0.35)
                }.sorted { $0.score == $1.score ? $0.start < $1.start : $0.score > $1.score }
                ranked = refined + ranked.filter { details[$0.start] == nil }
            }
        }

        var planned = ranked.map { (start: $0.start, duration: clipDuration, fit: false, title: nil as String?, reason: nil as String?) }
        if let gemini {
            generationProgress(0.55, "Gemini · choosing complete stories and layouts")
            let clips = try await GeminiSelection.select(url: url, cues: transcript, interval: interval,
                                                        targetDuration: clipDuration, count: targetCount, configuration: gemini, excluding: excluding,
                                                        guidance: videoType.selectionGuidance, progress: { fraction, stage in
                                                            generationProgress(0.55 + 0.15 * fraction, stage)
                                                        })
            planned = clips.map { (start: $0.start, duration: $0.end - $0.start, fit: $0.layout == "fit", title: $0.title, reason: $0.reason) }
        }
        // Screens and gameplay lose their edges in a vertical crop, whatever the picker suggested.
        if videoType.forcesFit { planned = planned.map { ($0.start, $0.duration, true, $0.title, $0.reason) } }
        var results: [ShortResult] = []
        var wordAlignmentAvailable = true
        let sentenceTimingNote = GeminiSelection.sentenceTimingNotice
        for candidate in planned {
            try Task.checkCancellation()
            let phraseCut = TranscriptSelection.phraseRange(start: candidate.start, duration: candidate.duration,
                                                           cues: transcript, interval: interval)
            // Cloud cues are whole sentences, so a Short never starts or stops in the middle of one.
            let whole = gemini == nil ? phraseCut : TranscriptSelection.completeSentences(
                start: phraseCut.start, duration: phraseCut.duration, cues: transcript, interval: interval,
                minDuration: max(1, clipDuration * 0.65), maxDuration: min(90, clipDuration * 1.5))
            let snapped = TranscriptSelection.trimmedFiller(start: whole.start, duration: whole.duration, cues: transcript,
                                                            minDuration: max(1, clipDuration * 0.65))
            let phrase = gemini != nil ? TranscriptSelection.paddedPhraseRange(start: snapped.start, duration: snapped.duration,
                                                                               cues: transcript, interval: interval) : snapped
            let referenceCues = transcript.filter { cue in
                let middle = cue.start + cue.duration / 2
                return middle >= snapped.start && middle <= snapped.start + snapped.duration
            }
            var clipWords: [TimedSpeechWord]
            var alignmentWarning: String?
            if let gemini, !referenceCues.isEmpty, wordAlignmentAvailable {
                generationProgress(0.70 + 0.29 * Double(results.count) / Double(targetCount), "Aligning speech · Short \(results.count + 1) of \(targetCount)")
                do {
                    let proposed = try await GeminiSelection.transcribe(url: url,
                        interval: (max(interval.start, phrase.start - 0.5), min(interval.end, phrase.start + phrase.duration + 0.5)),
                        configuration: gemini, reference: referenceCues)
                    let inside = proposed.filter { $0.start >= phrase.start - 0.01 && $0.start + $0.duration <= phrase.start + phrase.duration + 0.01 }
                    if TranscriptSelection.alignmentIsReliable(inside, reference: referenceCues) {
                        clipWords = inside
                    } else {
                        clipWords = []
                        alignmentWarning = sentenceTimingNote
                    }
                } catch {
                    try Task.checkCancellation()
                    wordAlignmentAvailable = false
                    clipWords = []
                    alignmentWarning = sentenceTimingNote
                }
            } else {
                clipWords = transcription.words
                if gemini != nil && !referenceCues.isEmpty { alignmentWarning = sentenceTimingNote }
            }
            let range = speechSafeRange(start: phrase.start, duration: phrase.duration, words: clipWords, interval: interval)
            let start = range.start
            let actualDuration = range.duration
            guard excluding.allSatisfy({ !TranscriptSelection.overlaps(start: start, duration: actualDuration, otherStart: $0.start, otherDuration: $0.end - $0.start) }) else { continue }
            guard results.allSatisfy({ !TranscriptSelection.overlaps(start: start, duration: actualDuration, otherStart: $0.start, otherDuration: $0.duration) }) else { continue }
            let captionSource = !clipWords.isEmpty ? GeminiSelection.captionCues(clipWords, interval: (start, start + actualDuration)) : (gemini == nil ? transcript : TranscriptSelection.sentenceCaptionGroups(referenceCues))
            let captions = captionSource.compactMap { cue -> TimedCaption? in
                let cueEnd = cue.start + cue.duration
                let clipEnd = start + actualDuration
                guard cueEnd > start, cue.start < clipEnd else { return nil }
                let clippedStart = max(0, cue.start - start)
                let clippedEnd = min(actualDuration, cueEnd - start)
                return TimedCaption(text: cue.text, start: clippedStart, duration: max(0.15, clippedEnd - clippedStart))
            }
            let words = clipWords.compactMap { word -> TimedSpeechWord? in
                guard word.start >= start - 0.01, word.start + word.duration <= start + actualDuration + 0.01 else { return nil }
                return .init(text: word.text, start: word.start - start, duration: word.duration)
            }
            let completedClips = results.count
            let cropKeyframes: [CropKeyframe] = candidate.fit ? [.init(time: 0, position: 0.5, preserveWholeFrame: true), .init(time: actualDuration, position: 0.5, preserveWholeFrame: true)] : await SubjectFramer.analyze(url, start: start, duration: actualDuration, zoom: 1.08, useSemanticModel: gemini == nil, progress: { fraction in
                generationProgress((gemini == nil ? 0.55 : 0.70) + (gemini == nil ? 0.44 : 0.29) * (Double(completedClips) + fraction) / Double(targetCount), "Tracking subject · Short \(completedClips + 1) of \(targetCount)")
            })
            let resultWarning = alignmentWarning ?? transcription.issue?.message
            let resultTitle = candidate.title.map { String($0.prefix(100)) } ?? captions.first.map { String($0.text.prefix(100)) }
            var notes: [String] = []
            if let reason = candidate.reason { notes.append(String(reason.prefix(400))) }
            let result = ShortResult(start: start, duration: actualDuration, caption: "", captions: captions,
                cropKeyframes: cropKeyframes, speechWords: words, analysisWarning: resultWarning,
                suggestedTitle: resultTitle, selectionReason: notes.isEmpty ? nil : notes.joined(separator: "\n\n"), fitToFrame: candidate.fit)
            results.append(result)
            if results.count == targetCount { break }
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

    private static func analyzeVisualFrames(
        _ url: URL,
        interval: (start: Double, end: Double),
        step: Double,
        progress: @escaping @Sendable (Int, Int) -> Void
    ) async -> [VisualMomentSample] {
        let worker = Task.detached(priority: .utility) { () async -> [VisualMomentSample] in
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 640, height: 360)
            let count = max(1, Int(ceil((interval.end - interval.start) / step)))
            var samples: [VisualMomentSample] = []
            for index in 0..<count {
                if Task.isCancelled { return [] }
                if index.isMultiple(of: 5) { progress(index, count) }
                let time = min(interval.end - 0.05, interval.start + Double(index) * step + step / 2)
                guard let image = try? generator.copyCGImage(at: CMTime(seconds: max(0, time), preferredTimescale: 600), actualTime: nil) else {
                    progress(index + 1, count)
                    continue
                }
                let luminance = luminanceGrid(image)
                let motion: Double
                if let luminance, let previous = samples.last?.luminance {
                    let difference = zip(luminance, previous).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) }
                    motion = min(1, difference / Double(luminance.count) / 255 * 8)
                } else {
                    motion = 0
                }
                let classification = VNClassifyImageRequest()
                let people = VNDetectHumanRectanglesRequest()
                let faces = VNDetectFaceRectanglesRequest()
                do {
                    try VNImageRequestHandler(cgImage: image).perform([classification, people, faces])
                } catch {
                    progress(index + 1, count)
                    continue
                }
                let labels = (classification.results ?? []).prefix(6).map(\.identifier)
                let labelConfidence = (classification.results ?? []).prefix(3).map(\.confidence).reduce(0, +) / 3
                let personConfidence = (people.results ?? []).map(\.confidence).max() ?? 0
                let faceConfidence = (faces.results ?? []).map(\.confidence).max() ?? 0
                let subject = max(personConfidence, faceConfidence)
                let interest = min(1, Double(subject) * 0.62 + Double(labelConfidence) * 0.38)
                samples.append(.init(time: time, interest: interest, labels: labels, motion: motion, luminance: luminance))
                progress(index + 1, count)
            }
            for index in samples.indices {
                if index > 0 {
                    let before = Set(samples[index - 1].labels)
                    let after = Set(samples[index].labels)
                    let union = before.union(after).count
                    let change = union == 0 ? 0 : 1 - Double(before.intersection(after).count) / Double(union)
                    samples[index].interest = min(1, samples[index].interest * 0.78 + change * 0.22)
                }
            }
            return samples
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private static func cropPosition(forSubjectX x: Double, imageWidth: Int, imageHeight: Int) -> Double {
        guard imageWidth > 0, imageHeight > 0 else { return 0.5 }
        let targetWidth = 1080.0
        let targetHeight = 1920.0
        let scale = max(targetWidth / Double(imageWidth), targetHeight / Double(imageHeight)) * 1.08
        let visibleWidth = min(1, targetWidth / (Double(imageWidth) * scale))
        let minCenter = visibleWidth / 2
        return min(1, max(0, (min(1 - minCenter, max(minCenter, x)) - minCenter) / max(0.001, 1 - visibleWidth)))
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

    /// Moves a chosen range's cuts onto whole words and returns that range's words and caption groups,
    /// both relative to the new start. Nil when no word falls inside it.
    static func snappedToWords(start: Double, duration: Double, words absolute: [TimedSpeechWord], sourceDuration: Double)
        -> (start: Double, duration: Double, cues: [TimedCaption], words: [TimedSpeechWord])? {
        let range = speechSafeRange(start: start, duration: duration, words: absolute, interval: (0, sourceDuration))
        let inside = absolute.filter { $0.start >= range.start - 0.01 && $0.start + $0.duration <= range.start + range.duration + 0.01 }
        guard !inside.isEmpty else { return nil }
        let words = inside.map { TimedSpeechWord(text: $0.text, start: $0.start - range.start, duration: $0.duration) }
        return (range.start, range.duration, captionGroups(words), words)
    }

    /// Measures word timing on this Mac for a Short Gemini already chose, then snaps its cuts to whole words.
    /// A little speech on each side is transcribed too, so a word cut by either edge is seen in full.
    static func retimedOnDevice(url: URL, start: Double, duration: Double, sourceDuration: Double, languageHint: String?) async
        -> (start: Double, duration: Double, cues: [TimedCaption], words: [TimedSpeechWord])? {
        let windowStart = max(0, start - 1.5)
        let windowEnd = min(sourceDuration, start + duration + 1.5)
        let local = await captions(for: url, start: windowStart, duration: windowEnd - windowStart, languageHint: languageHint)
        let absolute = local.words.map { TimedSpeechWord(text: $0.text, start: $0.start + windowStart, duration: $0.duration) }
        return snappedToWords(start: start, duration: duration, words: absolute, sourceDuration: sourceDuration)
    }

    static func analyzeSubjectPath(_ url: URL, start: Double, duration: Double, zoom: Double = 1.08, useSemanticModel: Bool = true) async -> [CropKeyframe] {
        await SubjectFramer.analyze(url, start: start, duration: duration, zoom: zoom, useSemanticModel: useSemanticModel)
    }

    private static func luminanceGrid(_ image: CGImage) -> [UInt8]? {
        let width = 24
        let height = 14
        guard let colorSpace = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let data = context.data else { return nil }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Array(UnsafeBufferPointer(start: data.bindMemory(to: UInt8.self, capacity: width * height), count: width * height))
    }

    private static func score(_ text: String) -> Int {
        let lower = text.lowercased()
        let words = lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let hooks = ["wow", "wait", "look", "finally", "found", "secret", "amazing", "incredible", "impossible", "suddenly", "actually", "best", "worst", "why", "how"]
        let fillers = ["um", "uh", "erm", "hmm"]
        let hookScore = words.filter { hooks.contains(String($0)) }.count * 3
        let fillerPenalty = words.filter { fillers.contains(String($0)) }.count * 2
        return max(0, min(words.count, 12) + hookScore + (text.contains("?") ? 5 : 0) + (text.contains("!") ? 7 : 0) - fillerPenalty)
    }

    /// Short, overlapping local recognition requests avoid the long-file failures
    /// that otherwise silently leave an entire recording without a transcript.
    /// An on-device recognizer locale for the dominant language of `text`, preferring the Mac's own region.
    static func speechLocale(forText text: String) -> Locale? {
        guard let language = NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue else { return nil }
        let supported = SFSpeechRecognizer.supportedLocales().filter { $0.language.languageCode?.identifier == language }
        let preferred = ["\(language)-\(Locale.current.region?.identifier ?? "")", "\(language)-US", "\(language)-\(language.uppercased())"]
        return preferred.lazy.compactMap { id in supported.first { $0.identifier.replacingOccurrences(of: "_", with: "-") == id } }.first
            ?? supported.min { $0.identifier < $1.identifier }
    }

    private static func transcribe(_ url: URL, interval: (start: Double, end: Double), locale: Locale? = nil,
                                   progress: @escaping @Sendable (Double) -> Void = { _ in }) async -> CaptionGenerationResult {
        let asset = AVURLAsset(url: url)
        guard let sourceDuration = try? await asset.load(.duration).seconds,
              sourceDuration.isFinite else { return .init(cues: [], issue: .recognitionFailed) }
        let end = min(sourceDuration, interval.end)
        var offset = max(0, interval.start)
        var words: [TimedSpeechWord] = []
        var issue: CaptionGenerationIssue?
        while offset < end {
            if Task.isCancelled { return .init(cues: [], issue: .recognitionFailed) }
            let length = min(45, end - offset)
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("relio-speech-\(UUID()).m4a")
            defer { try? FileManager.default.removeItem(at: temp) }
            guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                return .init(cues: [], issue: .recognitionFailed)
            }
            exporter.timeRange = CMTimeRange(start: CMTime(seconds: offset, preferredTimescale: 600),
                                             duration: CMTime(seconds: length, preferredTimescale: 600))
            exporter.outputURL = temp; exporter.outputFileType = .m4a
            await exporter.export()
            guard exporter.status == .completed else { return .init(cues: [], issue: .recognitionFailed) }
            let result = await transcribeChunk(temp, locale: locale)
            if let failure = result.issue {
                issue = failure
                // Permission and model failures cannot improve in a later chunk.
                if case .noSpeech = failure { } else { return .init(cues: [], issue: failure) }
            }
            let next = offset + max(1, length - 1)
            let cutoff = next + 0.5
            words += result.words.compactMap { word in
                let absolute = offset + word.start
                guard absolute >= interval.start, absolute + word.duration <= end + 0.01,
                      absolute >= (words.last.map { $0.start + $0.duration - 0.02 } ?? interval.start),
                      offset + length >= end || absolute < cutoff else { return nil }
                return TimedSpeechWord(text: word.text, start: absolute, duration: word.duration)
            }
            progress(min(1, (offset + length - interval.start) / max(1, end - interval.start)))
            if offset + length >= end { break }
            offset = next
        }
        return .init(cues: captionGroups(words), issue: words.isEmpty ? issue ?? .noSpeech : nil, words: words)
    }

    static func captionGroups(_ words: [TimedSpeechWord]) -> [TimedCaption] {
        var result: [TimedCaption] = []
        var group: [TimedSpeechWord] = []
        func flush() {
            guard let first = group.first, let last = group.last else { return }
            result.append(.init(text: group.map(\.text).joined(separator: " "), start: first.start,
                                duration: max(0.01, last.start + last.duration - first.start)))
            group.removeAll(keepingCapacity: true)
        }
        for word in words {
            if let last = group.last, word.start - last.start - last.duration > 0.5 { flush() }
            group.append(word)
            if group.count == 4 || (word.text.last.map { ".!?…".contains($0) } ?? false) { flush() }
        }
        flush()
        return result
    }

    private static func transcribeChunk(_ url: URL, locale: Locale? = nil) async -> CaptionGenerationResult {
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        switch status {
        case .denied: return .init(cues: [], issue: .permissionDenied)
        case .restricted: return .init(cues: [], issue: .permissionRestricted)
        case .notDetermined: return .init(cues: [], issue: .permissionDenied)
        case .authorized: break
        @unknown default: return .init(cues: [], issue: .permissionRestricted)
        }
        guard let recognizer = locale.flatMap({ SFSpeechRecognizer(locale: $0) }) ?? SFSpeechRecognizer(), recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else {
            return .init(cues: [], issue: .unavailableOnDevice)
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        return await withCheckedContinuation { continuation in
            var resumed = false
            recognizer.recognitionTask(with: request) { result, error in
                if result?.isFinal == true || error != nil {
                    guard !resumed else { return }; resumed = true
                    guard error == nil else {
                        continuation.resume(returning: .init(cues: [], issue: .recognitionFailed))
                        return
                    }
                    let segments = result?.bestTranscription.segments ?? []
                    var groups: [TimedCaption] = []
                    var current: [SFTranscriptionSegment] = []
                    func flush() {
                        guard let first = current.first, let last = current.last else { return }
                        let text = current.map(\.substring).joined(separator: " ")
                        let duration = max(0.35, last.timestamp + last.duration - first.timestamp)
                        groups.append(TimedCaption(text: text, start: first.timestamp, duration: duration))
                        current.removeAll(keepingCapacity: true)
                    }
                    for word in segments {
                        current.append(word)
                        let punctuationEndsThought = word.substring.last.map { ".!?…".contains($0) } ?? false
                        if current.count >= 5 || punctuationEndsThought { flush() }
                    }
                    flush()
                    let words = segments.map { TimedSpeechWord(text: $0.substring, start: $0.timestamp, duration: $0.duration) }
                    continuation.resume(returning: .init(cues: captionGroups(words), issue: words.isEmpty ? .noSpeech : nil, words: words))
                }
            }
        }
    }

    /// Renders kept between edits (finished previews and Fit backgrounds), so repeats don't re-render.
    static let renderCacheDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("RelioRenderCache")

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

    static func export(source: URL, segment: EditSegment, destination: URL) async throws {
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
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPreset1920x1080) else { throw Failure.cannotExport }
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
        if isSplit { draw = { image in ShortMaker.splitScreenFrame(image, transform: preferred, centers: centers) } }
        else { draw = { image in ShortMaker.blurredFitFrame(image, transform: preferred) } }
        if drawsFrames && !live {
            // The drawn picture depends only on the layout and source range, so caption and style edits reuse it.
            let cached = isSplit
                ? renderCacheURL("split-v2|\(source.path)|\(segment.start)|\(segment.duration)|\(centers)", prefix: "split")
                : renderCacheURL("fit-v2|\(source.path)|\(segment.start)|\(segment.duration)", prefix: "fit")
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
                    for pair in zip(completePath, completePath.dropFirst()) where pair.1.time > pair.0.time {
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

    /// Looks for two people across a Short and returns where each sits, left first.
    static func findSplitCenters(_ url: URL, start: Double, duration: Double) async -> [Double]? {
        await Task.detached(priority: .utility) { () -> [Double]? in
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 640, height: 640)
            var xs: [Double] = []
            for index in 0..<8 {
                let time = start + duration * (Double(index) + 0.5) / 8
                guard let image = try? generator.copyCGImage(at: CMTime(seconds: time, preferredTimescale: 600), actualTime: nil) else { continue }
                let faces = VNDetectFaceRectanglesRequest()
                try? VNImageRequestHandler(cgImage: image).perform([faces])
                xs += (faces.results ?? []).filter { $0.confidence > 0.5 }.map { Double($0.boundingBox.midX) }
            }
            return splitCenters(fromFaceXs: xs)
        }.value
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
