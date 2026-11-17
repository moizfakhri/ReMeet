import Foundation
import Observation
import ReMeetKit

/// One pipeline stage. Runs off the main actor; must be safe to cancel at any point,
/// because the stage simply runs again from meta.json's status next time.
protocol StageRunner: Sendable {
    func run(_ folder: MeetingFolder, progress: @escaping @Sendable (Double) -> Void) async throws
    /// Free models and memory (a recording started, or the queue is empty).
    func unload() async
}

extension StageRunner {
    func unload() async {}
}

/// Runs blocking work on a background thread and passes cancellation through
/// (a plain Task.detached would ignore the caller being cancelled).
func runDetached<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    let task = Task.detached(priority: .utility) { try work() }
    return try await withTaskCancellationHandler {
        try await task.value
    } onCancel: {
        task.cancel()
    }
}

/// Thrown by a stage that cannot run yet (a model still downloading). The meeting keeps its
/// status and is retried when `ProcessingQueue.retryWaiting()` runs; it is not a failure.
struct StageWaiting: Error, LocalizedError {
    var reason: String
    var errorDescription: String? { reason }
}

/// A Stop the user asked for. The on-device summary checks this between passes.
/// Cancelling that pass directly aborts the app, so the flag is how Stop reaches it.
enum PipelineStop {
    private static let lock = NSLock()
    private static var ids: Set<String> = []

    static func request(_ id: String) {
        lock.lock()
        ids.insert(id)
        lock.unlock()
    }

    static func clear(_ id: String) {
        lock.lock()
        ids.remove(id)
        lock.unlock()
    }

    static func isRequested(_ id: String) -> Bool {
        lock.lock()
        let value = ids.contains(id)
        lock.unlock()
        return value
    }
}

struct CompressRunner: StageRunner {
    func run(_ folder: MeetingFolder, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await runDetached { try AudioCompressor.compress(folder, progress: progress) }
    }
}

/// Processes meetings one at a time, each from its meta.json status to the end.
/// Pauses (and unloads models) while a recording is active.
@MainActor
@Observable
final class ProcessingQueue {
    struct Activity: Equatable {
        var folder: MeetingFolder
        var stage: PipelineStage
        var progress: Double?
    }

    private(set) var current: Activity?
    private(set) var pending: [MeetingFolder] = []
    private(set) var isPaused = false
    /// Meetings parked until a model is ready, with the reason shown in the processing view.
    private(set) var waiting: [MeetingFolder: String] = [:]
    /// Shown after Stop put a finished meeting back. Cleared when that meeting runs again.
    private(set) var notices: [MeetingFolder: String] = [:]
    /// Stop was pressed and the current step has not let go yet.
    private(set) var stoppingFolder: MeetingFolder?

    /// Stages that can run. A stage without a runner stops processing for now (later phases
    /// add them); a meeting then waits at that status.
    @ObservationIgnored var runners: [PipelineStage: StageRunner] = [.compress: CompressRunner()]
    @ObservationIgnored var onChange: ((MeetingFolder) -> Void)?
    @ObservationIgnored var onFinished: ((MeetingFolder, MeetingMeta) -> Void)?
    /// The transcript is written (the summary may still be running).
    @ObservationIgnored var onTranscribed: ((MeetingFolder, MeetingMeta) -> Void)?
    @ObservationIgnored var onFailed: ((MeetingFolder, MeetingFailure) -> Void)?

    @ObservationIgnored private var worker: Task<Void, Never>?
    /// Identifies the live worker, so a cancelled one finishing late changes nothing.
    @ObservationIgnored private var workerID = UUID()

    func enqueue(_ folder: MeetingFolder) {
        removed.remove(folder)
        guard !pending.contains(folder), current?.folder != folder else { return }
        waiting.removeValue(forKey: folder)
        pending.append(folder)
        kick()
    }

    /// Everything on disk that still has work to do (launch, after a recording).
    func enqueuePending(in library: MeetingLibrary) {
        for item in library.items.reversed() where item.meta.isProcessingPending { enqueue(item.folder) }
    }

    /// Retry after a failure: the meeting resumes at the stage that failed.
    func retry(_ folder: MeetingFolder) {
        notices.removeValue(forKey: folder)
        PipelineStop.clear(folder.id)
        enqueue(folder)
    }

    func clearNotice(_ folder: MeetingFolder) {
        notices.removeValue(forKey: folder)
    }

    /// Stop the current transcription or summary. A finished transcript and summary stay.
    /// The on-device summary is not killed mid-pass: that aborts the app. It stops at the
    /// next safe point. Sonnet's command is ended immediately.
    func stop(_ folder: MeetingFolder) {
        let wasPending = pending.contains(folder)
        let wasWaiting = waiting[folder] != nil
        pending.removeAll { $0 == folder }
        waiting.removeValue(forKey: folder)
        if rewindAfterCurrent?.folder == folder { rewindAfterCurrent = nil }
        guard current?.folder == folder else {
            if wasPending || wasWaiting { settleStop(folder, stage: (try? folder.readMeta())?.nextStage ?? .transcribe) }
            return
        }
        PipelineStop.request(folder.id)
        ClaudeSonnet.stop(.pipeline)
        stoppingFolder = folder
        onChange?(folder)
        // Summarize owns a Metal pass. Cancelling that task aborts the process, so it
        // notices the flag after the current pass. Every other stage can be cancelled.
        if current?.stage != .summarize {
            cancelCurrent(reenqueue: false)
        }
    }

    /// Run `stage` (and everything after it) again. `prepare` changes meta.json together
    /// with the rewind (Regenerate's chosen backend).
    func reprocess(_ folder: MeetingFolder, from stage: PipelineStage,
                   prepare: ((inout MeetingMeta) -> Void)? = nil) {
        removed.remove(folder)
        waiting.removeValue(forKey: folder)
        notices.removeValue(forKey: folder)
        PipelineStop.clear(folder.id)
        if current?.folder == folder, current?.stage == .summarize {
            // Cancelling the summary mid-generation aborts the app (see `pause`): let it finish,
            // then rewind and run again (the worker applies this when it returns).
            rewindAfterCurrent = (folder, stage, prepare)
            return
        }
        if current?.folder == folder {
            cancelCurrent(reenqueue: false)
        }
        rewind(folder, to: stage, prepare: prepare)
        kick()
    }

    private func rewind(_ folder: MeetingFolder, to stage: PipelineStage, prepare: ((inout MeetingMeta) -> Void)?) {
        _ = try? folder.updateMeta {
            $0.rewind(to: stage)
            prepare?(&$0)
        }
        onChange?(folder)
        // At the front: the user asked for this one now. `enqueue` alone skipped the kick when
        // the cancelled meeting was already back in `pending`, which stalled the queue.
        pending.removeAll { $0 == folder }
        pending.insert(folder, at: 0)
    }

    /// Regenerate/Reprocess asked for while the summary of the same meeting was being written.
    @ObservationIgnored private var rewindAfterCurrent: (folder: MeetingFolder, stage: PipelineStage,
                                                         prepare: ((inout MeetingMeta) -> Void)?)?
    /// Cancelled workers still finishing; no new worker starts until they have.
    @ObservationIgnored private var drainingTasks: [UUID: Task<Void, Never>] = [:]
    /// Folders trashed while a stage was in flight; their worker exits silently without callbacks.
    @ObservationIgnored private var removed: Set<MeetingFolder> = []

    /// Stops tracking a trashed meeting so it will not continue processing or post notifications.
    func remove(_ folder: MeetingFolder) {
        pending.removeAll { $0 == folder }
        waiting.removeValue(forKey: folder)
        if rewindAfterCurrent?.folder == folder {
            rewindAfterCurrent = nil
        }
        guard current?.folder == folder else { return }
        removed.insert(folder)
        if current?.stage != .summarize {
            cancelCurrent(reenqueue: false)
        }
    }

    /// Clears queued work from a previous storage folder before loading the new one.
    func resetForStorageChange() {
        pending.removeAll()
        waiting.removeAll()
        rewindAfterCurrent = nil
        if let current, current.stage != .summarize {
            removed.insert(current.folder)
            cancelCurrent(reenqueue: false)
        }
    }

    /// A model finished downloading: try the parked meetings again.
    func retryWaiting() {
        let folders = Array(waiting.keys)
        waiting = [:]
        for folder in folders { enqueue(folder) }
    }

    func pause() {
        isPaused = true
        // Summarize is the stage that owns the MLX generation thread. Cancelling it
        // pops a live Metal command encoder and aborts the process
        // (ReMeet-2026-11-03-003113, same family as 2026-11-02-235833). Let that
        // stage finish; the worker unloads once it returns, and `isPaused` stops
        // the next meeting from starting. Other stages are safe to cancel.
        if current?.stage == .summarize { return }
        let cancelled = cancelCurrent()
        let draining = Array(drainingTasks.values)
        let runners = Array(self.runners.values)
        // Wait for the cancelled worker to leave generate/unload before clearing models —
        // parallel unload during MLX generation was aborting the process (Metal SIGSEGV).
        Task { [weak self] in
            await cancelled?.value
            for task in draining { await task.value }
            guard let self, self.isPaused, self.worker == nil, self.drainingTasks.isEmpty else { return }
            for runner in runners { await runner.unload() }
        }
    }

    func resume() {
        isPaused = false
        kick()
    }

    func isWorking(on folder: MeetingFolder) -> Bool { current?.folder == folder }

    /// True while a pipeline worker is alive (including a summarize generation or draining cancel).
    var isBusy: Bool { worker != nil || current != nil || !drainingTasks.isEmpty }

    /// Stop accepting new work, let the current stage and any draining cancelled workers finish
    /// (do not cancel — cancelling mlx-swift-lm mid-token leaves Metal command encoders half-open
    /// and aborts on quit), then unload models so the process may exit safely.
    func prepareToTerminate() async {
        isPaused = true
        rewindAfterCurrent = nil
        while worker != nil || !drainingTasks.isEmpty {
            if let task = worker {
                await task.value
            }
            for task in Array(drainingTasks.values) {
                await task.value
            }
        }
        worker = nil
        current = nil
        let runners = Array(self.runners.values)
        for runner in runners { await runner.unload() }
    }

    // MARK: - Private

    @discardableResult
    private func cancelCurrent(reenqueue: Bool = true) -> Task<Void, Never>? {
        guard let current else { return nil }
        let task = worker
        worker?.cancel()
        worker = nil
        workerID = UUID()
        if reenqueue {
            // Put it back at the front; its status says where to pick up.
            pending.removeAll { $0 == current.folder }
            pending.insert(current.folder, at: 0)
        }
        self.current = nil
        if let task {
            // Cancelled stages exit at their next checkpoint (a transcribe turn can take seconds
            // on the GPU); track them so no new worker starts until this one has returned.
            let drainID = UUID()
            drainingTasks[drainID] = task
            Task { [weak self] in
                await task.value
                self?.drainingTasks.removeValue(forKey: drainID)
                self?.kick()
            }
        }
        return task
    }

    /// Stop finished. A meeting that already had a transcript and summary goes back to that.
    /// Anything else stays failed at this step so Retry is on screen and it does not start itself.
    private func settleStop(_ folder: MeetingFolder, stage: PipelineStage) {
        PipelineStop.clear(folder.id)
        if stoppingFolder == folder { stoppingFolder = nil }
        let restored = MeetingRecovery.restoredStatus(
            hasSummary: folder.exists(.summary),
            hasTranscript: folder.exists(.transcript),
            hasDiarization: folder.exists(.diarization),
            hasModelAudio: folder.exists(.mic16k) || folder.exists(.system16k) || folder.exists(.audio))
        if restored == .summarized {
            _ = try? folder.updateMeta {
                $0.status = .summarized
                $0.failure = nil
            }
            notices[folder] = "Stopped. The previous transcript and summary are still here. Regenerate runs it again."
        } else {
            _ = try? folder.updateMeta {
                $0.markFailed(stage, message: "Stopped. Retry runs this step again. The recording and anything already saved stay.")
            }
        }
        onChange?(folder)
    }

    private func kick() {
        guard worker == nil, drainingTasks.isEmpty, !isPaused, !pending.isEmpty else { return }
        let folder = pending.removeFirst()
        let id = UUID()
        workerID = id
        // Background priority: processing must never compete with a call or the UI.
        worker = Task(priority: .utility) { [weak self] in
            await self?.process(folder)
            guard let self else { return }
            if self.workerID == id || self.current?.folder != folder {
                self.removed.remove(folder)
            }
            guard self.workerID == id else { return }
            self.worker = nil
            self.current = nil
            if let request = self.rewindAfterCurrent, request.folder == folder {
                self.rewindAfterCurrent = nil
                self.rewind(folder, to: request.stage, prepare: request.prepare)
            }
            if self.pending.isEmpty || self.isPaused {
                // Idle, or a recording started mid-summary: drop models once the token
                // loop has actually returned (not from a concurrent cancel).
                let runners = Array(self.runners.values)
                for runner in runners { await runner.unload() }
            }
            self.kick()
        }
    }

    private func process(_ folder: MeetingFolder) async {
        while !Task.isCancelled {
            guard !removed.contains(folder),
                  let meta = try? folder.readMeta(),
                  let stage = meta.nextStage else { return }
            if PipelineStop.isRequested(folder.id) {
                settleStop(folder, stage: stage)
                return
            }
            // A failed meeting runs only when explicitly retried (enqueued); otherwise skip.
            guard let runner = runners[stage] else { return }
            current = Activity(folder: folder, stage: stage, progress: nil)
            onChange?(folder)
            let started = Date()
            do {
                try await runner.run(folder) { value in
                    Task { @MainActor in
                        guard self.current?.folder == folder, self.current?.stage == stage else { return }
                        self.current?.progress = value
                    }
                }
                try Task.checkCancellation()
                guard !removed.contains(folder), folder.exists(.meta) else { return }
                if rewindAfterCurrent?.folder == folder { return }
                let updated = try folder.updateMeta { $0.markCompleted(stage, seconds: Date().timeIntervalSince(started)) }
                onChange?(folder)
                if stage == .transcribe { onTranscribed?(folder, updated) }
                if updated.status == .summarized { onFinished?(folder, updated) }
            } catch is CancellationError {
                if PipelineStop.isRequested(folder.id) { settleStop(folder, stage: stage) }
                return
            } catch let wait as StageWaiting {
                guard !removed.contains(folder), folder.exists(.meta) else { return }
                waiting[folder] = wait.reason
                onChange?(folder)
                return
            } catch {
                if PipelineStop.isRequested(folder.id) {
                    settleStop(folder, stage: stage)
                    return
                }
                if Task.isCancelled || removed.contains(folder) || !folder.exists(.meta) { return }
                if rewindAfterCurrent?.folder == folder { return }
                let message = error.localizedDescription
                let failure = MeetingFailure(stage: stage, message: message)
                _ = try? folder.updateMeta { $0.markFailed(stage, message: message) }
                onChange?(folder)
                onFailed?(folder, failure)
                return
            }
        }
        if PipelineStop.isRequested(folder.id) {
            let stage = (try? folder.readMeta())?.nextStage ?? .transcribe
            settleStop(folder, stage: stage)
        }
    }
}
