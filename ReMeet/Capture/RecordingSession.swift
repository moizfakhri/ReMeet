import AVFoundation
import Foundation
import ReMeetKit

/// One recording. Control methods run on the main thread; audio arrives from real-time
/// threads into two lock-free queues and is drained, resampled and written on `writerQueue`.
final class RecordingSession {
    let folder: MeetingFolder
    let startDate: Date
    private let startHostTime: UInt64
    private let micQueue = ChunkQueue()
    private let systemQueue = ChunkQueue()
    private let micCapture: MicCapture
    private let systemCapture: SystemAudioCapture
    private let writerQueue = DispatchQueue(label: "com.moizfakhri.ReMeet.writer", qos: .userInitiated)
    private var micWriter: TrackWriter
    private var systemWriter: TrackWriter
    private var drainTimer: DispatchSourceTimer?
    private var lastLevelPost: UInt64 = 0
    private var pendingMicPeak: Float = 0
    private var pendingSystemPeak: Float = 0
    private(set) var meta: MeetingMeta
    private var micRestartWork: DispatchWorkItem?
    private var systemRebuildWork: DispatchWorkItem?
    private var micRetryCount = 0
    private var isStopping = false

    /// Peak levels (0...1 linear) for mic and call, delivered on main roughly 20 times a second.
    var onLevels: ((Float, Float) -> Void)?
    /// Every event that is also written to meta.json, delivered on main.
    var onEvent: ((SessionEvent) -> Void)?
    /// Audio could not be written (disk full ...), delivered on main once per track.
    var onWriteError: ((String) -> Void)?
    private var reportedWriteFailure: Set<String> = []

    enum SessionError: LocalizedError {
        case nothingToRecord(String)
        var errorDescription: String? {
            switch self {
            case .nothingToRecord(let detail): "Neither the microphone nor the call audio could be started (\(detail))."
            }
        }
    }

    /// Seconds on the audio timeline (host clock, the same clock as both files). Unlike the
    /// wall clock it does not advance while the Mac sleeps, so notes stay aligned (audit H3).
    var elapsedSeconds: Double {
        let now = mach_absolute_time()
        return now > startHostTime ? AVAudioTime.seconds(forHostTime: now - startHostTime) : 0
    }

    init(folder: MeetingFolder, startDate: Date, title: String, titleIsUserSet: Bool = false, sourceApp: String?,
         input: AudioDeviceInfo?, output: AudioDeviceInfo?) throws {
        self.folder = folder
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        self.startDate = startDate
        startHostTime = mach_absolute_time()
        micWriter = try TrackWriter(url: folder.file(.micWAV), startHostTime: startHostTime)
        systemWriter = try TrackWriter(url: folder.file(.systemWAV), startHostTime: startHostTime)
        micCapture = MicCapture(queue: micQueue)
        systemCapture = SystemAudioCapture(queue: systemQueue)
        meta = MeetingMeta(title: title, status: .recording, startTime: startDate, startHostTime: startHostTime,
                           devices: .init(initialInput: input, initialOutput: output))
        meta.sourceApp = sourceApp
        // A calendar event's name is kept; "Zoom call" and the like may be replaced by the summary.
        meta.titleIsUserSet = titleIsUserSet
        meta.clock = "Both files start at startHostTime (mach_absolute_time). Sample N of either file is startTime + N/48000 s."
    }

    /// Renames the meeting while it is recording (the title field in the menu bar).
    func setTitle(_ title: String) {
        meta.title = title
        meta.titleIsUserSet = true
        writeMeta()
    }

    /// Records the call app when a reminder- or shortcut-started recording joins the call.
    func setSourceAppIfUnset(_ bundleID: String) {
        guard meta.sourceApp == nil else { return }
        meta.sourceApp = bundleID
        writeMeta()
    }

    func start() throws {
        startDrainTimer()
        micCapture.onConfigurationChange = { [weak self] in
            self?.log("mic_engine_configuration_change", "AVAudioEngine reported a configuration change")
            self?.scheduleMicRestart()
        }
        // A mic that is not ready yet (AirPods mid-connect, no input) must not cost the whole
        // recording: record the call and keep retrying the mic (audit C4).
        var micError: String?
        do {
            let mic = try micCapture.start()
            log("mic_started", describe(mic))
        } catch {
            micError = error.localizedDescription
            log("mic_start_failed", "\(error.localizedDescription); retrying")
            scheduleMicRestart(after: 1.0)
        }
        var systemError: String?
        do {
            let system = try systemCapture.start()
            log("system_tap_started", "\(describe(system)), \(systemCapture.scopeDescription)")
        } catch {
            systemError = "\(error)"
            log("system_tap_failed", "\(error)")
        }
        writeMeta()
        if let micError, let systemError {
            throw SessionError.nothingToRecord("mic: \(micError); call audio: \(systemError)")
        }
    }

    /// The Mac is going to sleep / woke up. Devices go away during sleep; on wake the mic is
    /// restarted and the tap rebuilt. The host clock (and so both files) skips the sleep.
    /// A warning raised by the recorder (silent call track ...), kept in meta.json.
    func logWarning(_ type: String, _ detail: String) {
        guard !meta.events.contains(where: { $0.type == type }) else { return }
        log(type, detail)
    }

    func systemWillSleep() {
        log("system_sleep", "Mac going to sleep")
    }

    func systemDidWake() {
        guard !isStopping else { return }
        log("system_wake", "restarting mic and call capture")
        micRetryCount = 0
        scheduleMicRestart(after: 1.0)
        scheduleSystemRebuild()
    }

    /// "Meeting apps only": called before start() with the process objects to tap.
    func setProcessFilter(_ filter: @escaping () -> [AudioObjectID]) {
        systemCapture.processFilter = filter
    }

    /// The set of meeting-app processes changed while recording (filter mode only).
    func meetingProcessesChanged() {
        guard !isStopping, systemCapture.processFilter != nil else { return }
        do {
            let info = try systemCapture.rebuildTap()
            log("system_tap_rescoped", "\(describe(info)), \(systemCapture.scopeDescription)")
        } catch {
            log("system_tap_rescope_failed", "\(error)")
        }
    }

    func defaultInputChanged(from old: AudioDeviceInfo?, to new: AudioDeviceInfo?) {
        log("default_input_changed", "\(old?.name ?? "none") -> \(new?.name ?? "none")")
        scheduleMicRestart()
    }

    func defaultOutputChanged(from old: AudioDeviceInfo?, to new: AudioDeviceInfo?) {
        log("default_output_changed", "\(old?.name ?? "none") -> \(new?.name ?? "none")")
        scheduleSystemRebuild()
    }

    func stop(input: AudioDeviceInfo?, output: AudioDeviceInfo?, completion: @escaping () -> Void) {
        guard !isStopping else { return }
        isStopping = true
        micRestartWork?.cancel()
        systemRebuildWork?.cancel()
        micCapture.onConfigurationChange = nil
        micCapture.stop()
        systemCapture.stop()
        let endDate = Date()

        writerQueue.async { [self] in
            drainTimer?.cancel()
            drainTimer = nil
            drain()
            let micStats = micWriter.finish(droppedChunks: micQueue.droppedChunks)
            let systemStats = systemWriter.finish(droppedChunks: systemQueue.droppedChunks)
            DispatchQueue.main.async { [self] in
                meta.endTime = endDate
                // The audio length, not the wall clock (which includes any sleep) (audit M1).
                let written = max(micStats.durationSeconds, systemStats.durationSeconds)
                meta.durationSeconds = written > 0 ? written : endDate.timeIntervalSince(startDate)
                meta.mic = micStats
                meta.system = systemStats
                meta.devices.finalInput = input
                meta.devices.finalOutput = output
                meta.status = .recorded
                log("recording_stopped", String(format: "mic %.1f s, system %.1f s written",
                                                 micStats.durationSeconds, systemStats.durationSeconds))
                completion()
            }
        }
    }

    // MARK: - Device changes

    /// Debounced so that the engine notification and the default-device notification
    /// for the same AirPods switch cause one restart, about 0.3 s after the change.
    private func scheduleMicRestart(after delay: TimeInterval = 0.3) {
        guard !isStopping else { return }
        micRestartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.restartMic() }
        micRestartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func restartMic() {
        guard !isStopping else { return }
        do {
            let info = try micCapture.start()
            micRetryCount = 0
            log("mic_restarted", describe(info))
        } catch {
            micRetryCount += 1
            if micRetryCount <= 10 || micRetryCount % 30 == 0 {
                log("mic_restart_failed", "attempt \(micRetryCount): \(error.localizedDescription)")
            }
            // Every second at first, then every 10 s for as long as the recording runs.
            scheduleMicRestart(after: micRetryCount < 10 ? 1.0 : 10.0)
        }
    }

    private func scheduleSystemRebuild() {
        guard !isStopping else { return }
        systemRebuildWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rebuildSystem() }
        systemRebuildWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func rebuildSystem() {
        guard !isStopping else { return }
        do {
            let info = try systemCapture.rebuild()
            log("system_tap_rebuilt", describe(info))
        } catch {
            log("system_tap_rebuild_failed", "\(error)")
        }
    }

    // MARK: - Writer queue

    private func startDrainTimer() {
        let timer = DispatchSource.makeTimerSource(queue: writerQueue)
        timer.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20), leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.drain() }
        drainTimer = timer
        timer.resume()
    }

    private func drain() {
        micQueue.drain { pendingMicPeak = max(pendingMicPeak, micWriter.append($0)) }
        systemQueue.drain { pendingSystemPeak = max(pendingSystemPeak, systemWriter.append($0)) }
        for writer in [micWriter, systemWriter] where writer.writeFailures > 0 {
            let name = writer.stats.fileName, message = writer.lastWriteError ?? "unknown error"
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.reportedWriteFailure.contains(name) else { return }
                self.reportedWriteFailure.insert(name)
                self.log("write_failed", "\(name): \(message)")
                self.onWriteError?(message)
            }
        }

        let now = mach_absolute_time()
        if AVAudioTime.seconds(forHostTime: now - lastLevelPost) >= 0.05 {
            lastLevelPost = now
            let levels = (pendingMicPeak, pendingSystemPeak)
            pendingMicPeak = 0
            pendingSystemPeak = 0
            DispatchQueue.main.async { [weak self] in self?.onLevels?(levels.0, levels.1) }
        }
    }

    // MARK: - Metadata

    private func log(_ type: String, _ detail: String) {
        let now = mach_absolute_time()
        let offset = now > startHostTime ? AVAudioTime.seconds(forHostTime: now - startHostTime) : 0
        let event = SessionEvent(time: Date(), offsetSeconds: (offset * 1000).rounded() / 1000,
                                 type: type, detail: detail)
        meta.events.append(event)
        writeMeta()
        onEvent?(event)
    }

    private func writeMeta() {
        do {
            try folder.writeMeta(meta)
        } catch {
            NSLog("ReMeet: failed to write meta.json: %@", error.localizedDescription)
        }
    }

    private func describe(_ info: MicCapture.StartInfo) -> String {
        "\(info.device?.name ?? "default input") at \(Int(info.sampleRate)) Hz, \(info.channels) ch"
    }

    private func describe(_ info: SystemAudioCapture.StartInfo) -> String {
        guard info.sampleRate > 0 else {
            return "no tap yet (default out \(info.outputDevice?.name ?? "none"))"
        }
        return "tap-only aggregate (default out \(info.outputDevice?.name ?? "none")), tap at \(Int(info.sampleRate)) Hz, \(info.channels) ch"
    }
}
