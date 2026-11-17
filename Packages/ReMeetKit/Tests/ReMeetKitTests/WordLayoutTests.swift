import Foundation
import Testing
@testable import ReMeetKit

struct WordLayoutTests {
    @Test func realTimesAreKeptWhenEachWordHasOne() {
        let timed = [
            TranscriptWord(text: "old", start: 1.0, end: 1.4),
            TranscriptWord(text: "words", start: 1.4, end: 2.0),
        ]
        let laid = WordLayout.words(text: "hello there", start: 1, end: 2, timed: timed)
        #expect(laid.map(\.text) == ["hello", "there"])
        #expect(laid.map(\.start) == [1.0, 1.4])
        #expect(WordLayout.activeIndex(at: 1.4, words: laid) == 1)
    }

    @Test func aTurnWithOnlyAStartSpreadsWordsEvenly() {
        let laid = WordLayout.words(text: "one two three four", start: 10, end: 14, timed: [])
        #expect(laid.map(\.start) == [10, 11, 12, 13])
        #expect(laid.map(\.end) == [11, 12, 13, 14])
        #expect(WordLayout.activeIndex(at: 14, words: laid) == 3)
        #expect(WordLayout.words(text: "  ", start: 0, end: 1, timed: []).isEmpty)
    }

    @Test func aChangedSentenceFallsBackToAnEvenSpread() {
        let timed = [TranscriptWord(text: "only", start: 0, end: 1)]
        let laid = WordLayout.words(text: "two words", start: 0, end: 2, timed: timed)
        #expect(laid.map(\.text) == ["two", "words"])
        #expect(laid[0].start == 0)
        #expect(laid[1].end == 2)
    }

    @Test func anOldTranscriptWithoutWordTimesStillDecodes() throws {
        let json = #"{"start":1,"end":2,"speaker":"speaker_1","text":"hello","source":"system"}"#
        let segment = try JSONDecoder().decode(TranscriptSegment.self, from: Data(json.utf8))
        #expect(segment.words.isEmpty)
        #expect(segment.text == "hello")
    }

    @Test func aSelectionNamesOnePerson() {
        #expect(VoiceClip.speaker(["speaker_1", "speaker_1"]) == "speaker_1")
        #expect(VoiceClip.speaker(["speaker_1", "you"]) == nil)
        #expect(VoiceClip.speaker([]) == nil)
    }
}
