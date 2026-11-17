import Foundation
import Testing
@testable import ReMeetKit

struct SummaryMarkdownTests {
    @Test func rendersAllSectionsAndHidesEmpty() throws {
        var meta = MeetingMeta(title: "Weekly product sync", status: .summarized,
                               startTime: Date(timeIntervalSince1970: 1_793_620_800))  // 2 Nov 2026 11:00 UTC
        meta.durationSeconds = 48 * 60
        let summary = MeetingSummary(
            title: "Weekly product sync",
            summary: [SummaryPoint(text: "Release 3.2 moves to 17 Nov.", t: 718)],
            decisions: [SummaryPoint(text: "Variant B becomes the default.")],
            actionItems: [ActionItem(owner: "Priya", task: "Send the new date to partners", due: "Wed"),
                          ActionItem(task: "Write the refunds FAQ", done: true)],
            openQuestions: [],
            yourNotes: [NoteContext(t: 760, note: "Ask Tom about refund API", context: "The endpoint exists.")])
        let notes = [MeetingNote(t: 760, text: "Ask Tom about refund API", kind: .note)]
        let md = SummaryMarkdown.render(summary, meta: meta, notes: notes, timeZone: TimeZone(identifier: "UTC")!)

        #expect(md.hasPrefix("# Weekly product sync\n"))
        #expect(md.contains("· 48 min"))
        #expect(md.contains("## Summary\n- Release 3.2 moves to 17 Nov. (11:58)"))
        #expect(md.contains("- [ ] Send the new date to partners — Priya, Wed"))
        #expect(md.contains("- [x] Write the refunds FAQ\n"))
        #expect(md.contains("- **12:40** Ask Tom about refund API: The endpoint exists."))
        #expect(md.contains("## Decisions\n- Variant B becomes the default."))
        #expect(!md.contains("Open questions"))
    }

    @Test func summaryJSONUsesSnakeCase() throws {
        let s = MeetingSummary(title: "x", actionItems: [ActionItem(task: "t")], openQuestions: [SummaryPoint(text: "q")])
        let json = String(decoding: try JSONCoding.encoder().encode(s), as: UTF8.self)
        #expect(json.contains("\"action_items\"") && json.contains("\"open_questions\"") && json.contains("\"your_notes\""))
        let back = try JSONCoding.decoder().decode(MeetingSummary.self, from: Data(json.utf8))
        #expect(back == s)
    }

    @Test func speakerNames() {
        var names = SpeakerNames()
        #expect(names.displayName(for: "you") == "You")
        #expect(names.displayName(for: "speaker_2") == "Speaker 2")
        names.names["speaker_2"] = "Priya"
        #expect(names.displayName(for: "speaker_2") == "Priya")
        names.names["speaker_2"] = "  "
        #expect(names.displayName(for: "speaker_2") == "Speaker 2")
    }

    @Test func omitsTrailingColonWhenNoteContextIsEmpty() {
        let meta = MeetingMeta(title: "Quick check", status: .summarized, startTime: Date(timeIntervalSince1970: 1_793_620_800))
        let notes = [MeetingNote(t: 10, text: "Follow up", kind: .note)]
        let summary = MeetingSummary(title: "Quick check",
                                     yourNotes: [NoteContext(t: 10, note: "Follow up", context: "")])
        let md = SummaryMarkdown.render(summary, meta: meta, notes: notes, timeZone: TimeZone(identifier: "UTC")!)
        #expect(md.contains("- **0:10** Follow up\n"))
        #expect(!md.contains("Follow up:"))
    }

    @Test func itemIDsDistinguishOwnersAndTimes() {
        let a = ActionItem(owner: "Priya", task: "Review PR", t: 10)
        let b = ActionItem(owner: "Sam", task: "Review PR", t: 20)
        #expect(a.id != b.id)
        let p1 = SummaryPoint(text: "Agreed", t: 10)
        let p2 = SummaryPoint(text: "Agreed", t: 40)
        #expect(p1.id != p2.id)
    }

    @Test func rewriteMarkdownSyncsTitleNotesAndSpeakers() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("remeet-md-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = MeetingFolder.makeNew(in: root, start: Date(timeIntervalSince1970: 1_793_620_800), title: "Old title")
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        try folder.writeMeta(MeetingMeta(title: "New title", status: .summarized, startTime: Date(timeIntervalSince1970: 1_793_620_800)))
        try folder.write(Transcript(engine: "test", segments: [
            TranscriptSegment(start: 5, end: 9, speaker: "speaker_1", text: "Ship it.", source: .system),
        ]), .transcript)
        try folder.write(SpeakerNames(names: ["speaker_1": "Priya"]), .speakers)
        try NotesFile(url: folder.file(.notes)).save([MeetingNote(t: 6, text: "Confirm rollout", kind: .action)])
        try folder.write(MeetingSummary(title: "Old title",
                                        actionItems: [ActionItem(owner: "Priya", task: "Confirm rollout", done: true)]), .summary)

        folder.rewriteMarkdown()
        let transcriptMD = try String(contentsOf: folder.file(.transcriptMarkdown), encoding: .utf8)
        let summaryMD = try String(contentsOf: folder.file(.summaryMarkdown), encoding: .utf8)
        #expect(transcriptMD.hasPrefix("# New title: transcript\n"))
        #expect(transcriptMD.contains("**Priya** 0:05"))
        #expect(summaryMD.hasPrefix("# New title\n"))
        #expect(summaryMD.contains("- [x] Confirm rollout — Priya"))
        #expect(summaryMD.contains("- **0:06** Confirm rollout (action)"))
    }
}
