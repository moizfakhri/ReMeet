import Foundation
import Testing
@testable import ReMeetKit

struct MeetingMetaTests {
    private func fixture(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    }

    @Test func phase0FileDecodesAsRecorded() throws {
        let meta = try JSONCoding.read(MeetingMeta.self, from: fixture("phase0-meta"))
        #expect(meta.schemaVersion == 0)
        #expect(meta.status == .recorded)
        #expect(meta.nextStage == .compress)
        #expect(meta.title == MeetingMeta.defaultTitle)
        #expect(meta.events.count == 3)
        #expect(meta.mic?.fileName == "mic.wav")
        #expect(meta.devices.initialInput?.name == "MacBook Pro Microphone")
        #expect(abs(meta.effectiveDuration - 27.04) < 0.01)
    }

    @Test func roundTripKeepsEverything() throws {
        var meta = MeetingMeta(title: "Weekly sync", startTime: Date(timeIntervalSince1970: 1_793_000_000.5),
                               startHostTime: 42)
        meta.events.append(SessionEvent(time: meta.startTime, offsetSeconds: 0.1, type: "mic_started", detail: "x"))
        meta.markFailed(.transcribe, message: "boom", at: Date(timeIntervalSince1970: 1_793_000_100))
        let data = try JSONCoding.encoder().encode(meta)
        let back = try JSONCoding.decoder().decode(MeetingMeta.self, from: data)
        #expect(back == meta)
        #expect(String(decoding: data, as: UTF8.self).contains("\"status\" : \"failed\""))
    }

    @Test func statusWalk() {
        var meta = MeetingMeta(startTime: Date())
        #expect(meta.nextStage == nil)  // still recording
        meta.status = .recorded
        var order: [PipelineStage] = []
        while let stage = meta.nextStage {
            order.append(stage)
            meta.markCompleted(stage, seconds: 1.234)
        }
        #expect(order == [.compress, .diarize, .transcribe, .summarize])
        #expect(meta.status == .summarized)
        #expect(meta.completedStages == PipelineStage.allCases)
        #expect(meta.processing.stageSeconds["compress"] == 1.2)
    }

    @Test func failureResumesAtFailedStage() {
        var meta = MeetingMeta(status: .diarized, startTime: Date())
        meta.markFailed(.transcribe, message: "model missing")
        #expect(meta.status == .failed)
        #expect(meta.nextStage == .transcribe)
        #expect(meta.completedStages == [.compress, .diarize])
        #expect(!meta.isProcessingPending)
        meta.markCompleted(.transcribe)
        #expect(meta.failure == nil)
        #expect(meta.nextStage == .summarize)
    }

    @Test func rewindOnlyGoesBack() {
        var meta = MeetingMeta(status: .summarized, startTime: Date())
        meta.rewind(to: .summarize)
        #expect(meta.status == .transcribed)
        meta.rewind(to: .diarize)
        #expect(meta.status == .compressed)
        meta.rewind(to: .summarize)  // would skip diarize and transcribe: ignored
        #expect(meta.status == .compressed)
        meta.rewind(to: .compress)
        #expect(meta.status == .recorded)

        var failed = MeetingMeta(status: .compressed, startTime: Date())
        failed.markFailed(.diarize, message: "x")
        failed.rewind(to: .summarize)
        #expect(failed.status == .failed)
        failed.rewind(to: .diarize)
        #expect(failed.status == .compressed && failed.failure == nil)

        var recording = MeetingMeta(startTime: Date())
        recording.rewind(to: .compress)
        #expect(recording.status == .recording)
    }

    @Test func folderNamingAndSlug() throws {
        #expect(MeetingFolder.slug("Weekly product sync") == "weekly-product-sync")
        #expect(MeetingFolder.slug("  1:1 with Sára!! ") == "1-1-with-sara")
        #expect(MeetingFolder.slug("会議") == "meeting")
        #expect(MeetingFolder.slug(String(repeating: "word ", count: 20)).count <= 40)
        #expect(MeetingFolder.slug("Supercalifragilisticexpialidocious-and-even-more-letters-here") .count <= 40)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let start = Date(timeIntervalSince1970: 1_793_000_000)  // 2026-10-26 ...
        let utc = TimeZone(identifier: "UTC")!
        let first = MeetingFolder.makeNew(in: root, start: start, title: "Client kickoff", timeZone: utc)
        #expect(first.name.hasSuffix("_client-kickoff"))
        #expect(first.name.count == "yyyy-MM-dd_HHmm".count + "_client-kickoff".count)
        try FileManager.default.createDirectory(at: first.url, withIntermediateDirectories: true)
        let second = MeetingFolder.makeNew(in: root, start: start, title: "Client kickoff", timeZone: utc)
        #expect(second.name == first.name + "-2")

        try first.writeMeta(MeetingMeta(title: "Client kickoff", startTime: start))
        try first.updateMeta { $0.status = .recorded }
        #expect(try first.readMeta().status == .recorded)
        // An old file rewritten through the folder becomes the current schema.
        var legacy = try first.readMeta()
        legacy.schemaVersion = 0
        try first.writeMeta(legacy)
        #expect(try first.readMeta().schemaVersion == MeetingMeta.currentSchemaVersion)
        #expect(MeetingFolder.scan(root: root) == [first])
    }

    @Test func stopReturnsToTheFilesThatWereFullyWritten() {
        #expect(MeetingRecovery.restoredStatus(hasSummary: true, hasTranscript: true, hasDiarization: true, hasModelAudio: true) == .summarized)
        #expect(MeetingRecovery.restoredStatus(hasSummary: false, hasTranscript: true, hasDiarization: true, hasModelAudio: true) == .transcribed)
        #expect(MeetingRecovery.restoredStatus(hasSummary: true, hasTranscript: false, hasDiarization: true, hasModelAudio: true) == .diarized)
        #expect(MeetingRecovery.restoredStatus(hasSummary: false, hasTranscript: false, hasDiarization: true, hasModelAudio: true) == .diarized)
        #expect(MeetingRecovery.restoredStatus(hasSummary: false, hasTranscript: false, hasDiarization: false, hasModelAudio: true) == .compressed)
        #expect(MeetingRecovery.restoredStatus(hasSummary: false, hasTranscript: false, hasDiarization: false, hasModelAudio: false) == nil)
    }

    @Test func failureDismissal() throws {
        var meta = MeetingMeta(status: .diarized, startTime: Date())
        meta.markFailed(.transcribe, message: "x")
        #expect(meta.hasActiveFailure)
        meta.failure?.dismissed = true
        #expect(!meta.hasActiveFailure)
        // Old files without "dismissed" decode as not dismissed.
        let json = #"{"stage":"diarize","message":"No speech detected in audio","time":"2026-11-03T03:52:32.388Z"}"#
        let failure = try JSONCoding.decoder().decode(MeetingFailure.self, from: Data(json.utf8))
        #expect(failure.dismissed == false && failure.stage == .diarize)
        // Retrying (a new failure or completion) clears it.
        meta.markCompleted(.transcribe)
        #expect(!meta.hasActiveFailure && meta.failure == nil)
    }

    @Test func concurrentUpdatesAreNotLost() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("conc-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = MeetingFolder.makeNew(in: root, start: Date(), title: "x")
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        try folder.writeMeta(MeetingMeta(startTime: Date()))
        DispatchQueue.concurrentPerform(iterations: 200) { i in
            _ = try? folder.updateMeta {
                $0.events.append(SessionEvent(time: Date(), offsetSeconds: Double(i), type: "t", detail: ""))
            }
        }
        #expect(try folder.readMeta().events.count == 200)
    }
}
