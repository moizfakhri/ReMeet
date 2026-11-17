import Foundation
import Testing
@testable import ReMeetKit

struct SummaryParserTests {
    let notes = [MeetingNote(t: 760, text: "Ask Tom about refund API", kind: .note),
                 MeetingNote(t: 852, text: "Budget cap is 40k", kind: .action),
                 MeetingNote(t: 1265, text: "", kind: .bookmark)]

    @Test func parsesWellFormedReply() throws {
        let reply = """
        {"title": "Weekly sync",
         "summary": [{"text": "Release moves to 17 Nov.", "t": "11:58"}],
         "decisions": [{"text": "Variant B ships.", "t": "24:50"}],
         "action_items": [{"owner": "Priya", "task": "Email partners", "due": "Wed", "t": "12:20"},
                          {"owner": null, "task": "Confirm the budget cap is 40k", "due": null, "t": "14:15"}],
         "open_questions": [],
         "your_notes": [{"t": "12:40", "note": "Ask Tom about refund API", "context": "Tom said it exists."}]}
        """
        let s = try SummaryParser.parse(reply, notes: notes, fallbackTitle: "x")
        #expect(s.title == "Weekly sync")
        #expect(s.summary == [SummaryPoint(text: "Release moves to 17 Nov.", t: 718)])
        #expect(s.actionItems.count == 2)  // the action note is already covered by the second item
        #expect(s.actionItems[1].owner == nil && s.actionItems[1].due == nil)
        #expect(s.yourNotes.count == 3)
        #expect(s.yourNotes[0].context == "Tom said it exists.")
        #expect(s.yourNotes[2].note == "Bookmark")
    }

    @Test func toleratesFencesThinkingAndStrings() throws {
        let reply = """
        <think>let me think</think>
        Here are the notes:
        ```json
        {"summary": ["A", "B", "C", "D", "E", "F", "G"], "decisions": "none", "action_items": ["Send deck"],
         "open_questions": [{"question": "Who owns QA?"}], "your_notes": []}
        ```
        """
        let s = try SummaryParser.parse(reply, notes: [], fallbackTitle: "Fallback")
        #expect(s.title == "Fallback")
        #expect(s.summary.count == 6)            // capped at 6
        #expect(s.decisions.isEmpty)
        #expect(s.actionItems == [ActionItem(task: "Send deck")])
        #expect(s.openQuestions.first?.text == "Who owns QA?")
    }

    @Test func enforcesNotesWhenModelForgets() throws {
        let s = try SummaryParser.parse(#"{"title":"t","summary":[],"action_items":[]}"#, notes: notes, fallbackTitle: "t")
        #expect(s.yourNotes.map(\.t) == [760, 852, 1265])
        #expect(s.actionItems == [ActionItem(owner: "You", task: "Budget cap is 40k", t: 852)])
    }

    @Test func dropsContextThatEchoesThePrompt() throws {
        let reply = #"{"title":"t","summary":[],"your_notes":[{"t":"0:12","note":"this is important","context":"The person who recorded this took these notes during the meeting."}]}"#
        let s = try SummaryParser.parse(reply, notes: [MeetingNote(t: 12, text: "this is important", kind: .note)], fallbackTitle: "t")
        #expect(s.yourNotes.count == 1 && s.yourNotes[0].context.isEmpty)
    }

    @Test func rejectsNonJSON() {
        #expect(throws: SummaryParser.ParseError.noJSON) {
            try SummaryParser.parse("Sorry, I can't help with that.", notes: [], fallbackTitle: "x")
        }
        #expect(throws: SummaryParser.ParseError.invalid("not valid JSON")) {
            try SummaryParser.parse("{title: broken}", notes: [], fallbackTitle: "x") }
    }

    @Test func times() {
        #expect(SummaryParser.time("12:34") == 754)
        #expect(SummaryParser.time("[1:02:03]") == 3723)
        #expect(SummaryParser.time(754) == 754)
        #expect(SummaryParser.time("null") == nil)
        #expect(SummaryParser.time(nil) == nil)
    }
}

struct SummaryPromptTests {
    func lines(_ minutes: Int, wordsPerLine: Int = 40) -> [SummaryPrompt.TranscriptLine] {
        (0..<(minutes * 4)).map { i in
            SummaryPrompt.TranscriptLine(t: Double(i * 15), speaker: i % 2 == 0 ? "You" : "Priya",
                                         text: String(repeating: "word ", count: wordsPerLine))
        }
    }

    @Test func promptCarriesNotesAndRules() {
        let input = SummaryPrompt.Input(title: "Sync", date: Date(timeIntervalSince1970: 0), duration: 600,
                                        lines: lines(2), notes: [MeetingNote(t: 30, text: "Ship it", kind: .action),
                                                                 MeetingNote(t: 40, text: "", kind: .bookmark)],
                                        customInstructions: "Keep it under 6 bullets.")
        let text = SummaryPrompt.user(input)
        #expect(text.contains("- [0:30] ACTION: Ship it"))
        #expect(text.contains("- [0:40] BOOKMARK: (bookmarked this moment)"))
        #expect(text.contains("[0:15] Priya: word"))
        #expect(text.contains("Also: Keep it under 6 bullets."))
        #expect(text.contains("\"your_notes\""))
    }

    @Test func chunkingKeepsSmallMeetingsWhole() {
        #expect(TranscriptChunker.chunks(lines(10), maxTokens: 24_000).count == 1)
    }

    @Test func chunkingSplitsByTimeAndBudget() {
        let long = lines(60)  // 240 lines of ~50 tokens = ~12k tokens
        let byTime = TranscriptChunker.chunks(long, maxTokens: 100_000)
        #expect(byTime.count == 1)  // fits: no split even though it is long
        let tight = TranscriptChunker.chunks(long, maxTokens: 5_000)
        #expect(tight.count >= 3)
        #expect(tight.flatMap { $0 } == long)  // nothing lost or reordered
        for piece in tight {
            #expect(piece.last!.t - piece.first!.t < 15 * 60)
            #expect(piece.reduce(0) { $0 + SummaryPrompt.estimateTokens($1.rendered) + 1 } <= 3_500)
        }
    }

    @Test func notesForChunkNeverDropsBoundaryNotes() {
        let pieces: [[SummaryPrompt.TranscriptLine]] = [
            [.init(t: 5, speaker: "You", text: "Start"), .init(t: 880, speaker: "Priya", text: "Long turn")],
            [.init(t: 912, speaker: "You", text: "Part two"), .init(t: 1790, speaker: "Priya", text: "More")],
            [.init(t: 1810, speaker: "You", text: "Wrap up")],
        ]
        let notes = [
            MeetingNote(t: 1, text: "Before speech", kind: .note),
            MeetingNote(t: 895, text: "During last turn of chunk 0", kind: .action),
            MeetingNote(t: 912, text: "Exact start of chunk 1", kind: .note),
            MeetingNote(t: 1805, text: "Between chunk 1 and 2", kind: .bookmark),
            MeetingNote(t: 1900, text: "After last turn", kind: .note),
        ]
        let partitioned = pieces.indices.map { TranscriptChunker.notesForChunk(notes, pieces: pieces, index: $0) }
        #expect(partitioned[0].map(\.t) == [1, 895])
        #expect(partitioned[1].map(\.t) == [912, 1805])
        #expect(partitioned[2].map(\.t) == [1900])
        #expect(partitioned.flatMap { $0 } == notes)
    }

    @Test func mergePromptCarriesNotesContextAndCustomInstructions() {
        let input = SummaryPrompt.Input(
            title: "Roadmap",
            date: Date(timeIntervalSince1970: 0),
            duration: 3600,
            lines: lines(2),
            notes: [MeetingNote(t: 895, text: "Ship API v2", kind: .action)],
            customInstructions: "Use British spelling.",
            folderContext: "Priya leads platform.")
        let merged = SummaryPrompt.merge(partials: [#"{"summary":[]}"#, #"{"summary":[]}"#], input: input)
        #expect(merged.contains("Priya leads platform."))
        #expect(merged.contains("- [14:55] ACTION: Ship API v2"))
        #expect(merged.contains("Also: Use British spelling."))
    }
}

struct SummaryTimeLinkerTests {
    @Test func linksByWordOverlapAndKeepsExistingTimes() {
        let lines = [SummaryPrompt.TranscriptLine(t: 1, speaker: "A", text: "The payments fix needs another week of testing."),
                     SummaryPrompt.TranscriptLine(t: 46, speaker: "A", text: "The onboarding test lifted retention, so variant B ships to everyone."),
                     SummaryPrompt.TranscriptLine(t: 58, speaker: "You", text: "Perfect.")]
        var s = MeetingSummary(title: "t",
                               summary: [SummaryPoint(text: "Onboarding test lifted retention; variant B ships."),
                                         SummaryPoint(text: "Payments fix needs a week of testing.", t: 5),
                                         SummaryPoint(text: "Weather was nice.")],
                               actionItems: [ActionItem(task: "Finish payments testing")])
        SummaryTimeLinker.link(&s, lines: lines)
        #expect(s.summary[0].t == 46)
        #expect(s.summary[1].t == 5)      // model's own time kept
        #expect(s.summary[2].t == nil)    // nothing similar: no link
        #expect(s.actionItems[0].t == 1)
    }
}
