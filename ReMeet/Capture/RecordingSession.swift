import AVFoundation
import CoreAudio
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
    private var bluetoothSettleWork: DispatchWorkItem?
    private var systemRebuildWork: DispatchWorkItem?
    private var micRetryCount = 0
    private var isStopping = false

    private let healthLock = NSLock()
    private var _lastMicChunkUptime: Double = ProcessInfo.processInfo.systemUptime
    private var _lastSystemChunkUptime: Double = ProcessInfo.processInfo.systemUptime
    private(set) var micStartError: String?
    private(set) var systemStartError: String?
    private(set) var systemHasActiveTap = false
    private(set) var currentMicDevice: AudioDeviceInfo?

    /// Optional resolver returning an input device a meeting app (Zoom/Meet/Teams) already has open.
    var preferredMicDeviceID: (() -> AudioDeviceID?)?
    /// Peak levels (0...1 linear) for mic and call, delivered on main roughly 20 times a second.
    var onLevels: ((Float, Float) -> Void)?
    /// Fired on main whenever MicCapture binds/restarts onto an input device.
    var onMicDeviceStarted: ((AudioDeviceInfo?) -> Void)?
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

    var elapsedSeconds: Double {
        let now = mach_absolute_time()
        return now > startHostTime ? AVAudioTime.seconds(forHostTime: now - startHostTime) : 0
    }

    var secondsSinceLastChunks: (mic: Double, system: Double) {
        let now = ProcessInfo.processInfo.systemUptime
        return healthLock.withLock {
            (max(0, now - _lastMicChunkUptime), max(0, now - _lastSystemChunkUptime))
        }
    }

    init(folder: MeetingFolder, startDate: Date, title: String, titleIsUserSet: Bool = false, sourceApp: String?,
         calendarEvent: CalendarMeeting? = nil,
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
        if let calendarEvent {
            meta.calendarEventID = calendarEvent.id
            meta.calendarAttendees = calendarEvent.attendees
            meta.calendarJoinURL = calendarEvent.joinURL?.absoluteString
            meta.calendarName = calendarEvent.calendarName
        }
        meta.titleIsUserSet = titleIsUserSet
        meta.clock = "Both files start at startHostTime (mach_absolute_time). Sample N of either file is startTime + N/48000 s."
    }

    func setTitle(_ title: String) {
        meta.title = title
        meta.titleIsUserSet = true
        writeMeta()
    }

    func setSourceAppIfUnset(_ bundleID: String) {
        guard meta.sourceApp == nil else { return }
        meta.sourceApp = bundleID
        writeMeta()
    }

    func start() throws {
        let now = ProcessInfo.processInfo.systemUptime
        healthLock.withLock {
            _lastMicChunkUptime = now
            _lastSystemChunkUptime = now
        }
        startDrainTimer()
        micCapture.onConfigurationChange = { [weak self] in
            self?.log("mic_engine_configuration_change", "AVAudioEngine reported a configuration change")
            self?.scheduleMicRestart()
        }
        do {
            let mic = try micCapture.start(preferredDeviceID: preferredMicDeviceID?())
            micStartError = nil
            currentMicDevice = mic.device
            onMicDeviceStarted?(mic.device)
            log("mic_started", describe(mic))
            if let id = mic.device?.id, CoreAudioUtil.isBluetooth(id) {
                scheduleBluetoothSettleCheck()
            }
        } catch {
            micStartError = error.localizedDescription
            log("mic_start_failed", "\(error.localizedDescription); retrying")
            scheduleMicRestart(after: 1.0)
        }
        do {
            let system = try systemCapture.start()
            systemStartError = nil
            systemHasActiveTap = system.sampleRate > 0
            log("system_tap_started", "\(describe(system)), \(systemCapture.scopeDescription)")
        } catch {
            systemStartError = "\(error)"
            systemHasActiveTap = false
            log("system_tap_failed", "\(error)")
        }
        writeMeta()
        if let micErr = micStartError, let sysErr = systemStartError {
            throw SessionError.nothingToRecord("mic: \(micErr); call audio: \(sysErr)")
        }
    }

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
        let now = ProcessInfo.processInfo.systemUptime
        healthLock.withLock {
            _lastMicChunkUptime = now
            _lastSystemChunkUptime = now
        }
        micRetryCount = 0
        scheduleMicRestart(after: 1.0)
        scheduleSystemRebuild()
    }

    func setProcessFilter(_ filter: @escaping () -> [AudioObjectID]) {
        systemCapture.processFilter = filter
    }

    /// Switches a running "meeting apps only" session to tap all call audio immediately.
    func switchToAllAppsScope() {
        guard !isStopping else { return }
        systemCapture.processFilter = nil
        do {
            let info = try systemCapture.rebuildTap()
            systemStartError = nil
            systemHasActiveTap = info.sampleRate > 0
            resetSystemWatchdog()
            log("system_tap_switched_all_apps", describe(info))
        } catch {
            systemStartError = "\(error)"
            log("system_tap_rescope_failed", "\(error)")
        }
    }

    /// Manual or automatic full audio reconnect (rebuilds both MicCapture and SystemAudioCapture).
    func forceReconnect() {
        guard !isStopping else { return }
        micRetryCount = 0
        restartMic()
        rebuildSystem()
    }

    /// Periodic 1 Hz watchdog check: recovers wedged Bluetooth HFP / Core Audio streams automatically.
    func checkStreamLiveness() {
        guard !isStopping, elapsedSeconds >= 4 else { return }
        let gaps = secondsSinceLastChunks
        if micStartError == nil, (!micCapture.isRunning || gaps.mic >= 4.2) {
            log("mic_watchdog_restart", String(format: "no mic buffers for %.1f s; restarting", gaps.mic))
            resetMicWatchdog()
            scheduleMicRestart(after: 0.1)
        }
        if systemStartError == nil, systemHasActiveTap, gaps.system >= 4.8 {
            log("system_watchdog_rebuild", String(format: "no call tap buffers for %.1f s; rebuilding", gaps.system))
            resetSystemWatchdog()
            scheduleSystemRebuild()
        }
    }

    func meetingProcessesChanged() {
        guard !isStopping, systemCapture.processFilter != nil else { return }
        do {
            let info = try systemCapture.rebuildTap()
            systemStartError = nil
            systemHasActiveTap = info.sampleRate > 0
            resetSystemWatchdog()
            log("system_tap_rescoped", "\(describe(info)), \(systemCapture.scopeDescription)")
        } catch {
            systemStartError = "\(error)"
            log("system_tap_rescope_failed", "\(error)")
        }
    }

    func defaultInputChanged(from old: AudioDeviceInfo?, to new: AudioDeviceInfo?) {
        log("default_input_changed", "\(old?.name ?? "none") -> \(new?.name ?? "none")")
        let isBT = new.map { CoreAudioUtil.isBluetooth($0.id) } ?? false
        // Bluetooth headsets take slightly longer to finish SCO/BLE-Audio HFP negotiation.
        scheduleMicRestart(after: isBT ? 0.45 : 0.3)
        if isBT { scheduleBluetoothSettleCheck() }
    }

    /// Triggered when the active meeting app switches its own input device (e.g. inside Zoom's mic menu).
    func preferredInputChanged(to new: AudioDeviceInfo) {
        guard currentMicDevice?.id != new.id else { return }
        log("call_app_mic_followed", "\(currentMicDevice?.name ?? "none") -> \(new.name)")
        let isBT = CoreAudioUtil.isBluetooth(new.id)
        scheduleMicRestart(after: isBT ? 0.45 : 0.25)
        if isBT { scheduleBluetoothSettleCheck() }
    }

    func defaultOutputChanged(from old: AudioDeviceInfo?, to new: AudioDeviceInfo?) {
        log("default_output_changed", "\(old?.name ?? "none") -> \(new?.name ?? "none")")
        scheduleSystemRebuild()
    }

    func stop(input: AudioDeviceInfo?, output: AudioDeviceInfo?, completion: @escaping () -> Void) {
        guard !isStopping else { return }
        isStopping = true
        micRestartWork?.cancel()
        bluetoothSettleWork?.cancel()
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
                let written = max(micStats.durationSeconds, systemStats.durationSeconds)
                meta.durationSeconds = written > 0 ? written : endDate.timeIntervalSince(startDate)
                meta.mic = micStats
                meta.system = systemStats
                meta.devices.finalInput = currentMicDevice ?? input
                meta.devices.finalOutput = output
                meta.status = .recorded
                log("recording_stopped", String(format: "mic %.1f s, system %.1f s written",
                                                 micStats.durationSeconds, systemStats.durationSeconds))
                completion()
            }
        }
    }

    // MARK: - Device changes & Bluetooth Settle

    private func scheduleMicRestart(after delay: TimeInterval = 0.3) {
        guard !isStopping else { return }
        micRestartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.restartMic() }
        micRestartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// AirPods often report 48 kHz A2DP for ~0.5–1.5s before dropping to 24 kHz / 16 kHz HFP.
    /// Re-verify sample rate & chunk flow 1.6s after a Bluetooth switch.
    private func scheduleBluetoothSettleCheck() {
        bluetoothSettleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isStopping else { return }
            let gaps = self.secondsSinceLastChunks
            if let dev = self.currentMicDevice {
                let liveRate = CoreAudioUtil.double(dev.id, kAudioDevicePropertyNominalSampleRate) ?? dev.nominalSampleRate
                if (liveRate > 0 && abs(liveRate - dev.nominalSampleRate) > 100) || gaps.mic >= 1.2 || !self.micCapture.isRunning {
                    self.log("bluetooth_hfp_settle_restart", "re-syncing AirPods/Bluetooth stream (\(Int(dev.nominalSampleRate)) -> \(Int(liveRate)) Hz)")
                    self.restartMic()
                    self.rebuildSystem()
                }
            }
        }
        bluetoothSettleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }

    private func restartMic() {
        guard !isStopping else { return }
        do {
            let info = try micCapture.start(preferredDeviceID: preferredMicDeviceID?())
            micRetryCount = 0
            micStartError = nil
            currentMicDevice = info.device
            resetMicWatchdog()
            onMicDeviceStarted?(info.device)
            log("mic_restarted", describe(info))
        } catch {
            micRetryCount += 1
            micStartError = error.localizedDescription
            if micRetryCount <= 10 || micRetryCount % 30 == 0 {
                log("mic_restart_failed", "attempt \(micRetryCount): \(error.localizedDescription)")
            }
            scheduleMicRestart(after: micRetryCount < 10 ? 1.0 : 10.0)
        }
    }

    private func scheduleSystemRebuild() {
        guard !isStopping else { return }
        systemRebuildWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rebuildSystem() }
        systemRebuildWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func rebuildSystem() {
        guard !isStopping else { return }
        do {
            let info = try systemCapture.rebuild()
            systemStartError = nil
            systemHasActiveTap = info.sampleRate > 0
            resetSystemWatchdog()
            log("system_tap_rebuilt", describe(info))
        } catch {
            systemStartError = "\(error)"
            systemHasActiveTap = false
            log("system_tap_rebuild_failed", "\(error)")
        }
    }

    private func resetMicWatchdog() {
        let now = ProcessInfo.processInfo.systemUptime
        healthLock.withLock { _lastMicChunkUptime = now }
    }

    private func resetSystemWatchdog() {
        let now = ProcessInfo.processInfo.systemUptime
        healthLock.withLock { _lastSystemChunkUptime = now }
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
        var sawMic = false
        var sawSystem = false
        micQueue.drain {
            sawMic = true
            pendingMicPeak = max(pendingMicPeak, micWriter.append($0))
        }
        systemQueue.drain {
            sawSystem = true
            pendingSystemPeak = max(pendingSystemPeak, systemWriter.append($0))
        }
        if sawMic || sawSystem {
            let uptime = ProcessInfo.processInfo.systemUptime
            healthLock.withLock {
                if sawMic { _lastMicChunkUptime = uptime }
                if sawSystem { _lastSystemChunkUptime = uptime }
            }
        }
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
