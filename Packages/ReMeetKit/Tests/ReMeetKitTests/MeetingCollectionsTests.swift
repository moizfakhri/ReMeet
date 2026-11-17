import Foundation
import Testing
@testable import ReMeetKit

struct MeetingCollectionsTests {
    @Test func metaKeepsTheFolderAndOldFilesHaveNone() throws {
        var meta = MeetingMeta(title: "Team sync", status: .summarized, startTime: Date(timeIntervalSince1970: 0))
        meta.collectionID = "lab-a"
        let decoded = try JSONCoding.decoder().decode(MeetingMeta.self, from: JSONCoding.encoder().encode(meta))
        #expect(decoded.collectionID == "lab-a")
        let old = #"{"title":"Old","startTime":"1970-01-01T00:00:00Z","status":"summarized"}"#
        #expect(try JSONCoding.decoder().decode(MeetingMeta.self, from: Data(old.utf8)).collectionID == nil)
    }

    @Test func fileRoundTripAndContextLookup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("collections-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let meetings = root.appendingPathComponent("meetings")
        try FileManager.default.createDirectory(at: meetings, withIntermediateDirectories: true)
        let folder = MeetingFolder.makeNew(in: meetings, start: Date(), title: "Sync")
        let file = CollectionsFile(for: folder)
        #expect(file.url == root.appendingPathComponent("collections.json"))
        #expect(file.load().isEmpty)
        try file.save([MeetingCollection(id: "lab-a", name: "Projects", context: "  Priya leads releases; we focus on payments.\n")])
        var meta = MeetingMeta(title: "Sync", status: .transcribed, startTime: Date())
        #expect(file.context(for: meta).isEmpty)
        meta.collectionID = "lab-a"
        #expect(file.context(for: meta) == "Priya leads releases; we focus on payments.")
        #expect(file.name(for: meta) == "Projects")
        meta.collectionID = "deleted-folder"
        #expect(file.context(for: meta).isEmpty && file.name(for: meta) == nil)
    }

    @Test func contextGoesIntoThePromptAndCopyForAI() {
        let input = SummaryPrompt.Input(title: "Sync", date: Date(), duration: 60,
                                        lines: [.init(t: 1, speaker: "Priya", text: "Loop closure works.")],
                                        notes: [], folderContext: "Projects; Payments rollout.")
        #expect(SummaryPrompt.user(input).contains("Background from the person who recorded this (use it to understand names, projects and terms; do not summarize it): Projects; Payments rollout."))
        #expect(!SummaryPrompt.user(SummaryPrompt.Input(title: "Sync", date: Date(), duration: 60, lines: [], notes: [])).contains("Background"))

        var meta = MeetingMeta(title: "Sync", status: .summarized, startTime: Date())
        meta.collectionID = "lab-a"
        let text = AIContextMarkdown.render(meta: meta, transcript: nil, notes: [], summary: nil, speakers: SpeakerNames(),
                                            collection: MeetingCollection(id: "lab-a", name: "Projects", context: "Payments rollout."))
        #expect(text.contains("- Folder: Projects"))
        #expect(text.contains("## Context (written by me about this group of meetings)\nPayments rollout."))
    }

    @Test func dragPayloadRoundTrip() {
        for drag in [SidebarDrag.meeting("/Users/me/ReMeet/meetings/a b"), .collection("lab-a")] {
            #expect(SidebarDrag(payload: drag.payload) == drag)
        }
        #expect(SidebarDrag(payload: "some dragged text") == nil)
    }

    @Test func showMoreKeepsTheSelectedRow() {
        let items = Array(1...9)
        let collapsed = SidebarList.visible(items, limit: 5, showAll: false)
        #expect(collapsed.rows == [1, 2, 3, 4, 5] && collapsed.hidden == 4)
        let selected = SidebarList.visible(items, limit: 5, showAll: false) { $0 == 8 }
        #expect(selected.rows == [1, 2, 3, 4, 5, 8] && selected.hidden == 3)
        #expect(SidebarList.visible(items, limit: 5, showAll: true).hidden == 0)
        #expect(SidebarList.visible([1, 2], limit: 5, showAll: false).rows == [1, 2])
        // Exactly at the limit: nothing to hide, no "Show more".
        #expect(SidebarList.visible(Array(1...5), limit: 5, showAll: false).hidden == 0)
    }

    @Test func reorderFolders() {
        let list = ["a", "b", "c"].map { MeetingCollection(id: $0, name: $0) }
        func ids(_ moving: String, _ target: String) -> [String] {
            SidebarList.reordered(list, moving: moving, before: target).map(\.id)
        }
        #expect(ids("c", "a") == ["c", "a", "b"])   // up: lands before the target
        #expect(ids("a", "c") == ["b", "c", "a"])   // down: lands after, so last is reachable
        #expect(ids("a", "a") == ["a", "b", "c"])
        #expect(ids("x", "a") == ["a", "b", "c"])
    }
}
