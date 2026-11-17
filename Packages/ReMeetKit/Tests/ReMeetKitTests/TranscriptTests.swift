import Foundation
import Testing
@testable import ReMeetKit

struct TranscriptTests {
    @Test func normalizeByFirstAppearance() {
        let raw = [SpeechSegment(start: 10, end: 12, speaker: "S7"),
                   SpeechSegment(start: 2, end: 5, speaker: "S3"),
                   SpeechSegment(start: 13, end: 14, speaker: "S3")]
        let out = SpeakerNormalizer.normalize(raw)
        #expect(out.map(\.speaker) == ["speaker_1", "speaker_2", "speaker_1"])
        #expect(out.map(\.start) == [2, 10, 13])
    }

    @Test func turnsMergeDropPadAndSplit() {
        var options = TurnBuilder.Options()
        options.maxDuration = 30
        let segments = [
            SpeechSegment(start: 1.0, end: 3.0, speaker: "a"),
            SpeechSegment(start: 3.5, end: 5.0, speaker: "a"),   // gap 0.5: merged
            SpeechSegment(start: 5.2, end: 6.0, speaker: "b"),   // other speaker
            SpeechSegment(start: 9.0, end: 9.2, speaker: "a"),   // 0.2 s blip: dropped
            SpeechSegment(start: 20, end: 85, speaker: "b"),     // 65 s: split into 30/30/5
        ]
        let turns = TurnBuilder.turns(from: segments, source: .system, audioDuration: 84, options: options)
        #expect(turns.count == 5)
        #expect(turns[0] == Turn(start: 0.8, end: 5.2, speaker: "a", source: .system))
        #expect(turns[1].speaker == "b" && abs(turns[1].start - 5.0) < 1e-9)
        #expect(turns[2].start == 19.8 && turns[2].end == 50.2)
        #expect(turns[4].end == 84)  // clamped to the audio length
        // Padding never goes below zero.
        let early = TurnBuilder.turns(from: [SpeechSegment(start: 0.05, end: 2, speaker: "x")], source: .mic, audioDuration: 10)
        #expect(early[0].start == 0)
    }

    @Test func stitchSortsAndTidies() {
        let mic = TranscriptSegment(start: 5, end: 6, speaker: "you", text: "  Agreed.\n Let's  go ", source: .mic)
        let call = TranscriptSegment(start: 5, end: 7, speaker: "speaker_1", text: "Same time", source: .system)
        let early = TranscriptSegment(start: 1, end: 2, speaker: "speaker_1", text: "Hi", source: .system)
        let empty = TranscriptSegment(start: 3, end: 4, speaker: "you", text: "   ", source: .mic)
        let out = Stitcher.stitch([call, mic, empty, early])
        #expect(out.map(\.text) == ["Hi", "Agreed. Let's go", "Same time"])
    }

    @Test func notesInterleaveByTime() {
        let segs = [TranscriptSegment(start: 10, end: 12, speaker: "you", text: "a", source: .mic),
                    TranscriptSegment(start: 20, end: 22, speaker: "speaker_1", text: "b", source: .system)]
        let notes = [MeetingNote(t: 15, text: "n1", kind: .note), MeetingNote(t: 5, text: "", kind: .bookmark),
                     MeetingNote(t: 30, text: "late", kind: .action)]
        let items = Stitcher.interleave(segs, notes: notes)
        #expect(items.map(\.time) == [5, 10, 15, 20, 30])
    }

    @Test func markdown() {
        let t = Transcript(engine: "x", segments: [
            TranscriptSegment(start: 718, end: 731, speaker: "speaker_1", text: "Move 3.2.", source: .system),
            TranscriptSegment(start: 731, end: 733, speaker: "speaker_1", text: "Agreed?", source: .system),
            TranscriptSegment(start: 734, end: 738, speaker: "you", text: "Yes.", source: .mic),
        ])
        let md = TranscriptMarkdown.render(t, notes: [MeetingNote(t: 733.5, text: "Ask Tom", kind: .note)],
                                           speakers: SpeakerNames(names: ["speaker_1": "Priya"]), title: "Sync")
        #expect(md.contains("**Priya** 11:58\nMove 3.2.\nAgreed?"))
        #expect(md.contains("> **Your note 12:13** Ask Tom"))
        #expect(md.contains("**You** 12:14\nYes."))
        #expect(!md.contains("\n\n\n"))
    }
}

struct WordErrorRateTests {
    @Test func wer() {
        #expect(WordErrorRate.compute(reference: "Hello, world!", hypothesis: "hello world") == 0)
        #expect(WordErrorRate.compute(reference: "the cat sat", hypothesis: "the bat sat") == 1.0 / 3)
        #expect(WordErrorRate.compute(reference: "the cat sat", hypothesis: "the cat") == 1.0 / 3)
        #expect(WordErrorRate.compute(reference: "a b", hypothesis: "a x b y") == 1.0)
        #expect(WordErrorRate.compute(reference: "Let's go", hypothesis: "lets go") == 0)
    }
}
