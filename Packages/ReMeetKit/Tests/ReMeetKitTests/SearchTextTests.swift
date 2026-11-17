import Foundation
import Testing
@testable import ReMeetKit

struct SearchTextTests {
    @Test func queries() {
        #expect(SearchText.ftsQuery("refund API") == "\"refund\"* AND \"api\"*")
        #expect(SearchText.ftsQuery("  ") == nil)
        // FTS syntax in user input is neutralised.
        #expect(SearchText.ftsQuery("title:\"x\" OR NEAR(") == "\"title\"* AND \"x\"* AND \"or\"* AND \"near\"*")
        #expect(SearchText.ftsQuery("Q4 planning") == "\"q4\"* AND \"planning\"*")
    }

    @Test func documentCollectsEverything() {
        let meta = MeetingMeta(title: "Weekly sync", startTime: Date())
        let doc = SearchText.document(
            meta: meta,
            notes: [MeetingNote(t: 1, text: "Ask Tom", kind: .note), MeetingNote(t: 2, text: "", kind: .bookmark)],
            transcript: Transcript(engine: "x", segments: [TranscriptSegment(start: 0, end: 1, speaker: "speaker_1", text: "Refunds", source: .system)]),
            summary: MeetingSummary(title: "x", summary: [SummaryPoint(text: "Release moves")], actionItems: [ActionItem(owner: "Priya", task: "Email")]),
            speakers: SpeakerNames(names: ["speaker_1": "Priya"]))
        #expect(doc.title == "Weekly sync")
        #expect(doc.notes == "Ask Tom")
        #expect(doc.transcript == "Priya: Refunds")
        #expect(doc.summary.contains("Release moves") && doc.summary.contains("Priya: Email"))
    }
}
