import Foundation
import Testing
@testable import ReMeetKit

struct AIContextMarkdownTests {
    let utc = TimeZone(identifier: "UTC")!

    func meta() -> MeetingMeta {
        var meta = MeetingMeta(title: "Release planning", status: .summarized, startTime: Date(timeIntervalSince1970: 1_793_700_000))
        meta.durationSeconds = 1_800
        meta.sourceApp = "us.zoom.xos"
        return meta
    }

    let transcript = Transcript(engine: "x", segments: [
        TranscriptSegment(start: 5, end: 8, speaker: "speaker_1", text: "We move the release", source: .system),
        TranscriptSegment(start: 8.5, end: 9, speaker: "speaker_1", text: "a week.", source: .system),
        TranscriptSegment(start: 12, end: 14, speaker: "you", text: "Priya, can you email partners?", source: .mic),
        TranscriptSegment(start: 75, end: 78, speaker: "speaker_2", text: "Refunds are fine.", source: .system),
    ])

    @Test func headerNotesAndTranscript() {
        let notes = [MeetingNote(t: 20, text: "Send the deck", kind: .action),
                     MeetingNote(t: 10, text: "Check refunds", kind: .note),
                     MeetingNote(t: 30, text: "", kind: .bookmark)]
        let text = AIContextMarkdown.render(meta: meta(), transcript: transcript, notes: notes, summary: nil,
                                            speakers: SpeakerNames(names: ["speaker_1": "Priya"]), timeZone: utc)
        #expect(text.hasPrefix("# Meeting: Release planning\n"))
        #expect(text.contains("- Call app: Zoom"))
        #expect(text.contains("- Speakers: Priya, You (the person who recorded this), Speaker 2"))
        // Notes in time order, kinds spelled out.
        #expect(text.contains("- [0:10] Check refunds\n- [0:20] Action item: Send the deck\n- [0:30] Bookmarked this moment"))
        // One line per turn; same-speaker segments merged; renamed speaker used.
        #expect(text.contains("[0:05] Priya: We move the release a week.\n[0:12] You: Priya, can you email partners?\n[1:15] Speaker 2: Refunds are fine."))
        #expect(!text.contains("## Summary"))
    }

    @Test func summaryIncludedWhenPresent() {
        let summary = MeetingSummary(title: "t", summary: [SummaryPoint(text: "Release moves a week.", t: 5)],
                                     decisions: [SummaryPoint(text: "Ship on the 18th.", t: nil)],
                                     actionItems: [ActionItem(owner: "Priya", task: "Email partners", due: "Wed", done: false, t: 12)])
        let text = AIContextMarkdown.render(meta: meta(), transcript: transcript, notes: [], summary: summary,
                                            speakers: SpeakerNames(), timeZone: utc)
        #expect(text.contains("- Release moves a week.\n\nDecisions:\n- Ship on the 18th.\n\nAction items:\n- Email partners (owner: Priya) (due: Wed)"))
        // The transcript still follows the summary.
        #expect(text.range(of: "## Summary")!.lowerBound < text.range(of: "## Transcript")!.lowerBound)
    }

    @Test func noTranscriptYet() {
        let text = AIContextMarkdown.render(meta: meta(), transcript: nil, notes: [], summary: nil,
                                            speakers: SpeakerNames(), timeZone: utc)
        #expect(text.hasSuffix("## Transcript\n(No transcript yet.)\n"))
        #expect(!text.contains("Speakers:"))
    }

    /// A note retagged as Bookmark in the meeting window keeps its text, and Copy for AI
    /// must show it (bug hunt 2026-11-03: it printed "Bookmarked this moment" instead).
    @Test func bookmarkWithTextKeepsText() {
        let notes = [MeetingNote(t: 40, text: "Pricing slide", kind: .bookmark)]
        let text = AIContextMarkdown.render(meta: meta(), transcript: transcript, notes: notes, summary: nil,
                                            speakers: SpeakerNames(), timeZone: utc)
        #expect(text.contains("- [0:40] Bookmark: Pricing slide"))
    }
}
