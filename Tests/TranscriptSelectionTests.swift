import Foundation

@main struct TranscriptSelectionTests {
    static func main() async {
        let cues = (0..<120).map { TimedCaption(text: "Phrase \($0).", start: Double($0 * 10), duration: 8) }
        let windows = TranscriptSelection.windows(cues.reversed(), interval: (0, 1200))
        precondition(windows.first?.start == 0 && windows.last?.end == 1198)
        precondition(cues.allSatisfy { cue in windows.contains { $0.start <= cue.start && $0.end >= cue.start + cue.duration } })
        precondition(zip(windows, windows.dropFirst()).allSatisfy { $0.start < $1.start && $1.start < $0.end })
        let restricted = TranscriptSelection.windows(cues, interval: (300, 600))
        precondition(restricted.allSatisfy { $0.start >= 300 && $0.end <= 600 })
        precondition(TranscriptSelection.windows([], interval: (0, 10)).isEmpty)
        precondition(TranscriptSelection.batches(Array(0..<9)).map(\.count) == [3, 3, 3])
        precondition(TranscriptSelection.batches(Array(0..<5)).map(\.count) == [3, 2])
        let scored = await TranscriptSelection.scoreWindows(windows) { batch in batch.map { $0.contains("Phrase 119.") ? 1 : 0 } }
        precondition(scored?.count == windows.count && scored?.last == 1, "Tail must receive model scoring")
        var calls = 0
        let failed = await TranscriptSelection.scoreWindows(windows) { batch in
            calls += 1
            return calls == 2 ? nil : batch.map { _ in 0.5 }
        }
        precondition(failed == nil, "Never blend partially scored windows")
        let malformed = await TranscriptSelection.scoreWindows(windows) { _ in [Double.nan] }
        precondition(malformed == nil)
        precondition(TranscriptSelection.overlaps(start: 0, duration: 60, otherStart: 35, otherDuration: 60))
        precondition(!TranscriptSelection.overlaps(start: 0, duration: 60, otherStart: 60, otherDuration: 30))
        precondition(TranscriptSelection.overlaps(start: 0, duration: 60, otherStart: 10, otherDuration: 10))
        let phrase = TranscriptSelection.phraseRange(start: 10.4, duration: 30, cues: cues, interval: (0, 1200))
        precondition(phrase.start == 10 && phrase.start + phrase.duration == 38)
        let fallback = TranscriptSelection.phraseRange(start: 90, duration: 10, cues: [], interval: (0, 100))
        precondition(fallback.start == 90 && fallback.duration == 10)
        let bounded = TranscriptSelection.phraseRange(start: 580, duration: 30, cues: cues, interval: (300, 600))
        precondition(bounded.start >= 300 && bounded.start + bounded.duration <= 600)
        let reference = [TimedCaption(text: "Here is a clear opening.", start: 10, duration: 2),
                         TimedCaption(text: "Finish with the useful payoff.", start: 12, duration: 3)]
        let aligned = reference.map(\.text).joined(separator: " ").split(separator: " ").enumerated().map {
            TimedSpeechWord(text: String($0.element), start: 10 + Double($0.offset) * 0.4, duration: 0.3)
        }
        precondition(TranscriptSelection.alignmentIsReliable(aligned, reference: reference))
        precondition(!TranscriptSelection.alignmentIsReliable(Array(aligned.dropLast(2)), reference: reference), "Missing payoff must reject word alignment")
        let drifting = aligned.map { TimedSpeechWord(text: $0.text, start: $0.start + 4, duration: $0.duration) }
        precondition(!TranscriptSelection.alignmentIsReliable(drifting, reference: reference), "Correct words on the wrong clock must be rejected")
        let grouped = TranscriptSelection.sentenceCaptionGroups(reference)
        precondition(grouped.map(\.text).joined(separator: " ") == reference.map(\.text).joined(separator: " "))
        let padded = TranscriptSelection.paddedPhraseRange(start: 10, duration: 5,
            cues: [.init(text: "previous", start: 8, duration: 1.8), .init(text: "next", start: 15.2, duration: 2)], interval: (0, 20))
        precondition(abs(padded.start - 9.9) < 0.001 && abs(padded.start + padded.duration - 15.1) < 0.001)
        print("PASS transcript coverage, region bounds, balanced batches, tail scoring, model failure, overlap filtering and phrase cuts")
    }
}
