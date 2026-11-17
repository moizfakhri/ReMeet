import Foundation
import Testing
@testable import ReMeetKit

struct AudioRetentionTests {
    @Test func rules() {
        let now = Date(timeIntervalSince1970: 100 * 86_400)
        var old = MeetingMeta(status: .summarized, startTime: now.addingTimeInterval(-40 * 86_400))
        old.durationSeconds = 3600
        #expect(AudioRetention.shouldRemoveAudio(old, keepDays: 30, now: now))
        #expect(!AudioRetention.shouldRemoveAudio(old, keepDays: 0, now: now))      // Forever
        #expect(!AudioRetention.shouldRemoveAudio(old, keepDays: 90, now: now))
        var failed = old
        failed.markFailed(.summarize, message: "x")
        #expect(!AudioRetention.shouldRemoveAudio(failed, keepDays: 30, now: now))  // can still be retried
        var pending = old
        pending.status = .compressed
        #expect(!AudioRetention.shouldRemoveAudio(pending, keepDays: 30, now: now))
    }

    @Test func cleanRemovesOnlyAudio() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ret-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let folder = MeetingFolder.makeNew(in: root, start: now.addingTimeInterval(-60 * 86_400), title: "old")
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        var meta = MeetingMeta(status: .summarized, startTime: now.addingTimeInterval(-60 * 86_400))
        meta.durationSeconds = 60
        try folder.writeMeta(meta)
        for file in [MeetingFolder.File.audio, .mic16k, .summary, .transcript] { try Data("x".utf8).write(to: folder.file(file)) }
        #expect(AudioRetention.clean(root: root, keepDays: 30, now: now) == [folder])
        #expect(!folder.exists(.audio) && !folder.exists(.mic16k))
        #expect(folder.exists(.summary) && folder.exists(.transcript) && folder.exists(.meta))
        #expect(try folder.readMeta().events.last?.type == "audio_removed")
        #expect(AudioRetention.clean(root: root, keepDays: 30, now: now).isEmpty)   // nothing left to do
        #expect(AudioRetention.clean(root: root, keepDays: 0, now: now).isEmpty)
    }
}
