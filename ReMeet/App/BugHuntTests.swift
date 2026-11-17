import AVFoundation
import AppKit
import ReMeetKit

/// `--selftest bughunt <case> [args]`: end-to-end reproductions for the 2026-11-03 bug hunt.
/// Each case prints PASS when the behaviour is correct, FAIL when the bug is present.
@MainActor
enum BugHuntTests {
    static func run(model: AppModel) async {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "bughunt"), i + 1 < args.count else {
            return SelfTest.check(false, "usage: --selftest bughunt <case>")
        }
        let rest = Array(args[(i + 2)...])
        switch args[i + 1] {
        case "reloadthen": await reloadThen()
        case "regenerate": await regenerateDuringSummary(model: model, source: rest.first)
        case "eventtitle": await eventTitleKept(model: model, source: rest.first)
        case "noaudio": await reprocessWithoutAudio(model: model, source: rest.first)
        case "callwarning": await callAudioWarning(model: model)
        case "queuedrain": await queueDrainAndRemove()
        default: SelfTest.check(false, "unknown bughunt case \(args[i + 1])")
        }
    }

    /// A copy of a finished meeting in a temporary storage folder.
    static func copyMeeting(_ source: String?) -> MeetingFolder? {
        guard let source else { return nil }
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent("remeet-bughunt-\(UUID())")
        let meetings = storage.appendingPathComponent("meetings")
        try? FileManager.default.createDirectory(at: meetings, withIntermediateDirectories: true)
        let src = URL(fileURLWithPath: source, isDirectory: true)
        let dst = meetings.appendingPathComponent(src.lastPathComponent, isDirectory: true)
        guard (try? FileManager.default.copyItem(at: src, to: dst)) != nil else { return nil }
        return MeetingFolder(url: dst)
    }

    // MARK: - Library reload drops the launch callback

    /// Launch calls `library.reload { enqueuePending }`. Any other reload before that scan
    /// finishes (a refresh of a folder not in the list yet, Keep audio cleanup, a recording
    /// starting) used to drop the callback, so pending meetings were never queued.
    private static func reloadThen() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("remeet-reload-\(UUID())/meetings")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for _ in 0..<3 { _ = try? SelfTest.makeTestMeeting(seconds: 0.2, 0.2, root: root) }
        let library = MeetingLibrary(root: root)
        var ran = false
        library.reload { ran = true }
        library.reload()
        for _ in 0..<30 where !ran { await SelfTest.pause(0.1) }
        SelfTest.check(ran, "reload's completion runs even when another reload starts before the scan ends")
        SelfTest.check(library.items.count == 3, "library has the 3 meetings (\(library.items.count))")
        // The launch sequence itself: queue pending meetings after the scan, with a refresh of
        // a folder the list does not have yet (it falls back to a reload) right after.
        let queue = ProcessingQueue()
        queue.pause()
        library.reloadNow()
        _ = try? SelfTest.makeTestMeeting(seconds: 0.2, 0.2, root: root)
        library.reload { queue.enqueuePending(in: library) }
        library.refresh(MeetingFolder(url: root.appendingPathComponent("not-listed-yet")))
        for _ in 0..<30 where queue.pending.count < 4 { await SelfTest.pause(0.1) }
        SelfTest.check(queue.pending.count == 4, "launch queues all 4 pending meetings (\(queue.pending.count))")
    }

    // MARK: - Regenerate while the summary is being written

    /// Counts how many `complete` calls run at once on the real built-in model.
    actor CountingSummarizer: Summarizer {
        nonisolated let kind = SummaryBackendKind.builtIn
        let inner: Summarizer
        private(set) var active = 0
        private(set) var maxActive = 0
        private(set) var calls = 0
        init(inner: Summarizer) { self.inner = inner }
        func modelName() async -> String { await inner.modelName() }
        func contextTokens() async -> Int { await inner.contextTokens() }
        func complete(system: String, user: String) async throws -> String {
            active += 1
            calls += 1
            maxActive = max(maxActive, active)
            defer { active -= 1 }
            return try await inner.complete(system: system, user: user)
        }
        func unload() async { await inner.unload() }
    }

    /// Reprocess and Regenerate on the meeting that is being processed. `enqueue` skipped the
    /// kick when the cancelled meeting was already back in `pending`, so the queue stalled.
    /// During the summary itself the generation must not be cancelled (that aborts the app,
    /// see `pause()`): the rerun waits for it instead, so two never run at once.
    private static func regenerateDuringSummary(model: AppModel, source: String?) async {
        guard let folder = copyMeeting(source) else { return SelfTest.check(false, "usage: bughunt regenerate <meeting folder>") }
        defer { try? FileManager.default.removeItem(at: folder.url.deletingLastPathComponent().deletingLastPathComponent()) }
        guard let inner = try? model.makeSummarizer(.builtIn) else { return SelfTest.check(false, "built-in summary model installed") }
        let counting = CountingSummarizer(inner: inner)
        let queue = ProcessingQueue()
        for (stage, runner) in model.speechRunners() {
            if var transcribe = runner as? TranscribeRunner {
                transcribe.useSonnet = false
                queue.runners[stage] = transcribe
            } else {
                queue.runners[stage] = runner
            }
        }
        queue.runners[.summarize] = SummarizeRunner(summarizer: { _ in counting }, customInstructions: { "" }, useSonnet: false)
        let started = Date()
        func waitUntil(_ label: String, _ condition: () async -> Bool) async -> Bool {
            while Date().timeIntervalSince(started) < 300 {
                if await condition() { return true }
                await SelfTest.pause(0.1)
            }
            print("  timed out waiting for \(label)")
            return false
        }
        func status() -> String { (try? folder.readMeta().status.rawValue) ?? "?" }

        // 1. Reprocess while it is transcribing.
        _ = try? folder.updateMeta { $0.rewind(to: .diarize) }
        queue.enqueue(folder)
        guard await waitUntil("transcribe", { queue.current?.stage == .transcribe }) else { return SelfTest.check(false, "reached transcribe") }
        print(String(format: "  %.1f s: Reprocess during transcribe", Date().timeIntervalSince(started)))
        queue.reprocess(folder, from: .diarize)
        let ranAgain = await waitUntil("diarize again", { queue.current?.stage == .diarize || status() == "compressed" })
        SelfTest.check(ranAgain, "Reprocess during transcribe starts it again (status \(status()), pending \(queue.pending.count))")

        // 2. Regenerate while the summary is being written.
        guard await waitUntil("generation", { await counting.active == 1 }) else { return SelfTest.check(false, "summary generation started") }
        await SelfTest.pause(1)
        print(String(format: "  %.1f s: Regenerate during the summary", Date().timeIntervalSince(started)))
        queue.reprocess(folder, from: .summarize) { $0.processing.requestedSummaryBackend = .builtIn }
        _ = await waitUntil("idle", {
            let calls = await counting.calls
            return status() == "summarized" && !queue.isBusy && queue.pending.isEmpty && calls >= 2
        })
        await SelfTest.pause(1)
        let meta = try? folder.readMeta()
        let maxActive = await counting.maxActive
        let calls = await counting.calls
        print(String(format: "  %.1f s: calls %d, most at once %d, status %@", Date().timeIntervalSince(started), calls, maxActive, status()))
        SelfTest.check(maxActive == 1, "never two generations on the GPU at once (\(maxActive))")
        SelfTest.check(calls == 2, "the summary is written again after the running one finishes (\(calls) generations)")
        SelfTest.check(meta?.status == .summarized && queue.pending.isEmpty, "meeting ends summarized, queue empty")
        await queue.prepareToTerminate()
        await model.drainInferenceForTermination()
    }

    // MARK: - A meeting named after its calendar event keeps that name

    /// Recording from a calendar reminder names the meeting after the event. The summary
    /// then replaced it with the model's own title, because the event title was stored as an
    /// automatic one (`titleIsUserSet` false).
    private static func eventTitleKept(model: AppModel, source: String?) async {
        guard let folder = copyMeeting(source) else { return SelfTest.check(false, "usage: bughunt eventtitle <meeting folder>") }
        defer { try? FileManager.default.removeItem(at: folder.url.deletingLastPathComponent().deletingLastPathComponent()) }
        // Record 2 s for real from the reminder path (mic + call tap, into -storageFolder), and
        // take the title fields it wrote.
        let event = CalendarMeeting(id: "e1", title: "Weekly sync with Priya", start: Date(), end: Date().addingTimeInterval(1800),
                                    attendeeNames: ["Priya"])
        model.startRecording(for: nil, event: event)
        for _ in 0..<50 where !model.recorder.isRecording { await SelfTest.pause(0.1) }
        let live = model.recorder.folder
        await SelfTest.pause(2)
        model.recorder.stop()
        for _ in 0..<100 where model.recorder.state != .idle { await SelfTest.pause(0.1) }
        let recorded = try? live?.readMeta()
        if let live { try? FileManager.default.removeItem(at: live.url) }
        print("  recording from the reminder: title \"\(recorded?.title ?? "?")\", titleIsUserSet = \(recorded?.titleIsUserSet ?? false)")
        // A prompt-started call without an event keeps a placeholder the summary may replace.
        model.startRecording(for: MeetingApp.match("us.zoom.xos"))
        for _ in 0..<50 where !model.recorder.isRecording { await SelfTest.pause(0.1) }
        let zoomFolder = model.recorder.folder
        await SelfTest.pause(1)
        model.recorder.stop()
        for _ in 0..<100 where model.recorder.state != .idle { await SelfTest.pause(0.1) }
        let zoom = try? zoomFolder?.readMeta()
        if let zoomFolder { try? FileManager.default.removeItem(at: zoomFolder.url) }
        SelfTest.check(zoom?.title == "Zoom call" && zoom?.titleIsUserSet == false, "a Zoom call without an event stays replaceable (\(zoom?.title ?? "?"))")
        _ = try? folder.updateMeta {
            $0.title = event.title
            $0.titleIsUserSet = recorded?.titleIsUserSet ?? false
            $0.rewind(to: .summarize)
        }
        let queue = ProcessingQueue()
        queue.runners[.summarize] = model.summarizeRunner()
        queue.enqueue(folder)
        let started = Date()
        while Date().timeIntervalSince(started) < 300 {
            await SelfTest.pause(0.5)
            if (try? folder.readMeta().status) == .summarized || (try? folder.readMeta().status) == .failed { break }
        }
        let meta = try? folder.readMeta()
        let summary = try? folder.read(MeetingSummary.self, .summary)
        print("  summary title \"\(summary?.title ?? "?")\", meeting title \"\(meta?.title ?? "?")\"")
        SelfTest.check(meta?.status == .summarized, "summarized")
        SelfTest.check(meta?.title == event.title, "meeting keeps its calendar name after the summary")
        await queue.prepareToTerminate()
        await model.drainInferenceForTermination()
    }

    // MARK: - Reprocess after Keep audio removed the audio

    /// Keep audio removes the audio of old meetings but keeps the transcript. Reprocess then
    /// rewound to compression, which failed with "no audio" and left the meeting failed.
    private static func reprocessWithoutAudio(model: AppModel, source: String?) async {
        guard let folder = copyMeeting(source) else { return SelfTest.check(false, "usage: bughunt noaudio <meeting folder>") }
        defer { try? FileManager.default.removeItem(at: folder.url.deletingLastPathComponent().deletingLastPathComponent()) }
        for file in AudioRetention.audioFiles { try? FileManager.default.removeItem(at: folder.file(file)) }
        for (stage, runner) in model.speechRunners() { model.queue.runners[stage] = runner }
        model.queue.runners[.summarize] = model.summarizeRunner()
        let before = try? folder.readMeta()
        let words = { ((try? folder.read(Transcript.self, .transcript)) ?? nil)?.segments.reduce(0) { $0 + $1.text.split(separator: " ").count } ?? 0 }
        let wordsBefore = words()
        print("  before: status \(before?.status.rawValue ?? "?"), transcript words \(wordsBefore)")
        model.reprocess(folder)
        for _ in 0..<600 {
            await SelfTest.pause(0.2)
            if model.queue.current == nil, model.queue.pending.isEmpty { break }
        }
        let meta = try? folder.readMeta()
        print("  after: status \(meta?.status.rawValue ?? "?") \(meta?.failure.map { "\($0.stage.rawValue): \($0.message)" } ?? "")")
        let summary = try? folder.read(MeetingSummary.self, .summary)
        print("  transcript words after: \(words()), summary: \(summary?.summary.first?.text ?? "none")")
        SelfTest.check(meta?.status != .failed, "Reprocess without audio does not turn a finished meeting into a failed one")
        SelfTest.check(words() == wordsBefore, "the transcript is kept (\(wordsBefore) -> \(words()) words)")
        SelfTest.check(summary.map { !$0.summary.contains { $0.text.contains("No speech") } } ?? false, "the summary is rewritten from the kept transcript")
        // Any other path that reruns speech on it (e.g. a rewind to compression) must not wipe it either.
        model.queue.reprocess(folder, from: .compress)
        for _ in 0..<100 {
            await SelfTest.pause(0.2)
            if model.queue.current == nil, model.queue.pending.isEmpty { break }
        }
        let forced = try? folder.readMeta()
        print("  forced rerun from compression: \(forced?.status.rawValue ?? "?") \(forced?.failure?.message ?? "")")
        SelfTest.check(words() == wordsBefore, "a forced rerun keeps the transcript too (\(words()) words)")
        await model.drainInferenceForTermination()
    }

    // MARK: - "Isn't hearing the call audio" warning

    /// "Meeting apps only" records only meeting apps, so music playing in another app is
    /// correctly not recorded. The silent-call check counted that app as "playing" and
    /// told the user to fix a permission that was fine. Records for real (mic + call tap)
    /// for 22 s while afplay plays a quiet tone; run with `-storageFolder <tmp>`.
    private static func callAudioWarning(model: AppModel) async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("remeet-warn-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let tone = root.appendingPathComponent("tone.wav")
        try? SelfTest.writeTone(tone, seconds: 30, hz: 440)
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = ["-v", "0.03", tone.path]
        try? player.run()
        defer { player.terminate() }
        UserDefaults.standard.set(RecordingScope.meetingApps.rawValue, forKey: SettingsKey.recordingScope)
        defer { UserDefaults.standard.removeObject(forKey: SettingsKey.recordingScope) }
        await SelfTest.pause(0.5)
        model.startRecording(for: nil)
        for _ in 0..<50 where !model.recorder.isRecording { await SelfTest.pause(0.1) }
        guard model.recorder.isRecording else { return SelfTest.check(false, "recording started") }
        await SelfTest.pause(22)
        let warning = model.recorder.warning
        print("  warning after 22 s: \(warning ?? "none")")
        SelfTest.check(warning == nil, "no permission warning when only a non-meeting app is playing in Meeting apps only")
        model.recorder.stop()
        for _ in 0..<100 where model.recorder.state != .idle { await SelfTest.pause(0.1) }
    }

    // MARK: - Pause/resume draining, deferred rewind callbacks, and trash removal

    private static func queueDrainAndRemove() async {
        actor SlowTranscribeGate {
            var active = 0
            var maxActive = 0
            var unloadsWhileActive = 0
            func enter() async throws {
                active += 1
                maxActive = max(maxActive, active)
                defer { active -= 1 }
                // Ignore task cancellation briefly, like an in-flight GPU turn.
                await withCheckedContinuation { cont in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.35) { cont.resume() }
                }
                try Task.checkCancellation()
            }
            func unload() {
                if active > 0 { unloadsWhileActive += 1 }
            }
        }
        struct MockTranscribe: StageRunner {
            let gate: SlowTranscribeGate
            func run(_ folder: MeetingFolder, progress: @escaping @Sendable (Double) -> Void) async throws {
                try await gate.enter()
            }
            func unload() async { await gate.unload() }
        }
        struct MockSummarize: StageRunner {
            let delay: Double
            func run(_ folder: MeetingFolder, progress: @escaping @Sendable (Double) -> Void) async throws {
                await withCheckedContinuation { cont in
                    DispatchQueue.global().asyncAfter(deadline: .now() + delay) { cont.resume() }
                }
            }
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("remeet-qdrain-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let gate = SlowTranscribeGate()
        let queue = ProcessingQueue()
        queue.runners = [.transcribe: MockTranscribe(gate: gate), .summarize: MockSummarize(delay: 0.25)]
        var finishedCount = 0
        var failedCount = 0
        queue.onFinished = { _, _ in finishedCount += 1 }
        queue.onFailed = { _, _ in failedCount += 1 }

        // 1. pause() -> immediate resume() while cancelled transcribe turn is still draining.
        let m1 = MeetingFolder.makeNew(in: root, start: Date(), title: "m1")
        try? FileManager.default.createDirectory(at: m1.url, withIntermediateDirectories: true)
        try? m1.writeMeta(MeetingMeta(title: "m1", status: .diarized, startTime: Date()))
        queue.enqueue(m1)
        for _ in 0..<40 where queue.current?.folder != m1 { await SelfTest.pause(0.02) }
        queue.pause()
        queue.resume()
        for _ in 0..<60 where queue.isBusy || !queue.pending.isEmpty { await SelfTest.pause(0.05) }
        let maxActive = await gate.maxActive
        let unloadsWhileActive = await gate.unloadsWhileActive
        SelfTest.check(maxActive == 1, "pause/resume waits for draining worker; max concurrent = \(maxActive)")
        SelfTest.check(unloadsWhileActive == 0, "unload never races an active worker (\(unloadsWhileActive))")
        SelfTest.check(finishedCount == 1, "m1 finishes once (\(finishedCount))")

        // 2. reprocess during .summarize skips premature onFinished on the superseded run.
        finishedCount = 0
        let m2 = MeetingFolder.makeNew(in: root, start: Date(), title: "m2")
        try? FileManager.default.createDirectory(at: m2.url, withIntermediateDirectories: true)
        try? m2.writeMeta(MeetingMeta(title: "m2", status: .transcribed, startTime: Date()))
        queue.enqueue(m2)
        for _ in 0..<40 where queue.current?.folder != m2 { await SelfTest.pause(0.02) }
        queue.reprocess(m2, from: .summarize)
        for _ in 0..<60 where queue.isBusy || !queue.pending.isEmpty { await SelfTest.pause(0.05) }
        SelfTest.check(finishedCount == 1, "deferred rewind during summarize fires onFinished only once (\(finishedCount))")

        // 3. remove() on a trashed meeting suppresses callbacks.
        finishedCount = 0
        let m3 = MeetingFolder.makeNew(in: root, start: Date(), title: "m3")
        try? FileManager.default.createDirectory(at: m3.url, withIntermediateDirectories: true)
        try? m3.writeMeta(MeetingMeta(title: "m3", status: .transcribed, startTime: Date()))
        queue.enqueue(m3)
        for _ in 0..<40 where queue.current?.folder != m3 { await SelfTest.pause(0.02) }
        try? FileManager.default.removeItem(at: m3.url)
        queue.remove(m3)
        for _ in 0..<60 where queue.isBusy || !queue.pending.isEmpty { await SelfTest.pause(0.05) }
        SelfTest.check(finishedCount == 0 && failedCount == 0, "trashed meeting fires neither onFinished (\(finishedCount)) nor onFailed (\(failedCount))")
    }
}
