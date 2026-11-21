import Foundation
import Testing
@testable import ReMeetKit

@Suite struct MeetingExporterTests {
    @Test func filenameAndRenderedMarkdownIncludeFrontmatterAndCheckboxes() throws {
        let tz = TimeZone(secondsFromGMT: 0)!
        let start = Date(timeIntervalSince1970: 1_795_185_000) // 2026-11-20 14:30:00 UTC
        var meta = MeetingMeta(title: "Weekly Product Sync", status: .summarized, startTime: start)
        meta.durationSeconds = 1800
        meta.sourceApp = "com.microsoft.teams2"

        let name = MeetingExporter.filename(meta: meta, timeZone: tz)
        #expect(name == "2026-11-20_14-30_weekly-product-sync.md")

        let transcript = Transcript(engine: "Parakeet", segments: [
            TranscriptSegment(start: 2, end: 8, speaker: "you", text: "Let's ship the export.", source: .mic),
            TranscriptSegment(start: 9, end: 15, speaker: "speaker_1", text: "Sounds good.", source: .system),
        ])
        let summary = MeetingSummary(
            title: "Weekly Product Sync",
            summary: [SummaryPoint(text: "Agreed to ship Markdown export.")],
            decisions: [SummaryPoint(text: "Use per-folder export directories.")],
            actionItems: [
                ActionItem(owner: "Alex", task: "Review PR", due: "Friday", done: false),
                ActionItem(owner: "You", task: "Write tests", due: nil, done: true),
            ],
            openQuestions: [SummaryPoint(text: "Need index file?")]
        )
        let notes = [MeetingNote(t: 10, text: "Check performance", kind: .note)]
        let speakers = SpeakerNames(names: ["speaker_1": "Alex"])
        let collection = MeetingCollection(name: "Platform Team", context: "Core backend and API team.",
                                           exportDirectoryPath: "/tmp/platform")

        let md = MeetingExporter.render(meta: meta, meetingID: "2026-11-20_1430_weekly-product-sync",
                                        transcript: transcript, notes: notes, summary: summary,
                                        speakers: speakers, collection: collection, timeZone: tz)
        #expect(md.hasPrefix("---\n"))
        #expect(md.contains("title: \"Weekly Product Sync\""))
        #expect(md.contains("folder: \"Platform Team\""))
        #expect(md.contains("call_app: \"Teams\""))
        #expect(md.contains("- \"You\""))
        #expect(md.contains("- \"Alex\""))
        #expect(md.contains("## Folder context\nCore backend and API team."))
        #expect(md.contains("- [ ] Review PR (owner: Alex) (due: Friday)"))
        #expect(md.contains("- [x] Write tests (owner: You)"))
        #expect(md.contains("[0:02] You: Let's ship the export."))
        #expect(md.contains("[0:09] Alex: Sounds good."))
    }

    @Test func syncWritesUpdatesOnRenameAndCleansUpWhenMovedOut() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("remeet-export-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let meetingsRoot = root.appendingPathComponent("meetings", isDirectory: true)
        let exportA = root.appendingPathComponent("export-a", isDirectory: true)
        let exportB = root.appendingPathComponent("export-b", isDirectory: true)
        try FileManager.default.createDirectory(at: meetingsRoot, withIntermediateDirectories: true)

        let start = Date(timeIntervalSince1970: 1_795_185_000)
        let tz = TimeZone(secondsFromGMT: 0)!
        let folder = MeetingFolder.makeNew(in: meetingsRoot, start: start, title: "Initial sync", timeZone: tz)
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        var meta = MeetingMeta(title: "Initial sync", status: .summarized, startTime: start)
        meta.collectionID = "col-a"
        try folder.writeMeta(meta)
        try folder.write(Transcript(engine: "Parakeet", segments: [
            TranscriptSegment(start: 0, end: 5, speaker: "you", text: "Hello world.", source: .mic)
        ]), .transcript)

        let colA = MeetingCollection(id: "col-a", name: "Folder A", context: "Context A",
                                     exportDirectoryPath: exportA.path)
        let colB = MeetingCollection(id: "col-b", name: "Folder B", context: "Context B",
                                     exportDirectoryPath: exportB.path)

        // 1. First sync creates file in exportA and records exportedMarkdownPath.
        let firstURL = try MeetingExporter.sync(folder, collection: colA, timeZone: tz)
        #expect(firstURL?.lastPathComponent == "2026-11-20_14-30_initial-sync.md")
        #expect(firstURL != nil && FileManager.default.fileExists(atPath: firstURL!.path))
        #expect((try folder.readMeta()).exportedMarkdownPath == firstURL?.path)

        // 2. Re-syncing same title overwrites in place (no -2 duplicate).
        let secondURL = try MeetingExporter.sync(folder, collection: colA, timeZone: tz)
        #expect(secondURL == firstURL)

        // 3. Renaming replaces old file instead of leaving a stale copy.
        try folder.updateMeta { $0.title = "Renamed Meeting" }
        let renamedURL = try MeetingExporter.sync(folder, collection: colA, timeZone: tz)
        #expect(renamedURL?.lastPathComponent == "2026-11-20_14-30_renamed-meeting.md")
        #expect(!FileManager.default.fileExists(atPath: firstURL!.path))
        #expect(FileManager.default.fileExists(atPath: renamedURL!.path))

        // 4. Moving to Folder B moves export from exportA to exportB.
        try folder.updateMeta { $0.collectionID = colB.id }
        let movedURL = try MeetingExporter.sync(folder, collection: colB, timeZone: tz)
        #expect(movedURL?.deletingLastPathComponent().path == exportB.path)
        #expect(!FileManager.default.fileExists(atPath: renamedURL!.path))
        #expect(FileManager.default.fileExists(atPath: movedURL!.path))

        // 5. Moving out of any exported folder cleans up the exported file.
        try folder.updateMeta { $0.collectionID = nil }
        let cleared = try MeetingExporter.sync(folder, collection: nil, timeZone: tz)
        #expect(cleared == nil)
        #expect(!FileManager.default.fileExists(atPath: movedURL!.path))
        #expect((try folder.readMeta()).exportedMarkdownPath == nil)
    }

    @Test func legacyCollectionJSONDecodesWithoutExportDirectoryPath() throws {
        let json = #"[{"id":"1","name":"Lab","context":"Notes"}]"#
        let decoded = try JSONDecoder().decode([MeetingCollection].self, from: Data(json.utf8))
        #expect(decoded.count == 1)
        #expect(decoded[0].exportDirectoryPath == nil)
    }
}
