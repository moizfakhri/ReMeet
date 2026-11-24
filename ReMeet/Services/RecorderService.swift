import AVFoundation
import AppKit
import CoreAudio
import Foundation
import Observation
import ReMeetKit

/// Owns the current recording: starts and stops a RecordingSession, follows default-device
/// and call-app microphone changes (AirPods handoff), evaluates live audio health, publishes
/// levels and elapsed time, and appends notes.
@MainActor
@Observable
final class RecorderService {
    enum State: Equatable {
        case idle
        case starting
        case recording
        case stopping
    }

    private(set) var state: State = .idle
    private(set) var elapsed: TimeInterval = 0
    private(set) var micLevel: Float = 0
    private(set) var systemLevel: Float = 0
    private(set) var inputDevice: AudioDeviceInfo?
    private(set) var outputDevice: AudioDeviceInfo?
    /// "switched at 18:02" style note after the input device changed mid-recording.
    private(set) var lastInputSwitch: (name: String, at: TimeInterval)?
    /// Transient 3.2s toast shown on the floating pill when AirPods or another mic takes over.
    private(set) var deviceSwitchToast: String?
    private(set) var recentEvents: [SessionEvent] = []
    private(set) var errorMessage: String?
    /// Actionable live audio issue (silent call tap, muted mic, wrong input, stalled Bluetooth).
    private(set) var activeAudioIssue: AudioHealthIssue?
    /// Non-fatal problem string during a recording (low disk or `activeAudioIssue.detail`).
    private(set) var warning: String?
    private(set) var folder: MeetingFolder?
    private(set) var startDate: Date?
    private(set) var title = MeetingMeta.defaultTitle
    private(set) var notes: [MeetingNote] = []

    var isRecording: Bool { state == .recording }
    var isBusy: Bool { state == .starting || state == .stopping }
    var isBluetoothInput: Bool {
        guard let id = inputDevice?.id else { return false }
        return CoreAudioUtil.isBluetooth(id)
    }

    var onFinished: ((MeetingFolder) -> Void)?
    var onWillStop: (() -> Void)?
    var onDiscarded: (() -> Void)?
    var onStarted: ((MeetingFolder) -> Void)?
    var onScopeSwitchedToAllApps: (() -> Void)?

    var meetingsRoot: URL = MeetingFolder.defaultRoot
    var meetingProcessFilter: (() -> [AudioObjectID])?

    @ObservationIgnored private let deviceMonitor = DefaultDeviceMonitor()
    @ObservationIgnored private var session: RecordingSession?
    @ObservationIgnored private var elapsedTimer: Timer?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var diskWarning: String?
    @ObservationIgnored private var dismissedIssues: Set<AudioHealthIssue.Kind> = []

    @ObservationIgnored private var heardCallAudio = false
    @ObservationIgnored private var heardMicSpeech = false
    @ObservationIgnored private var heardMicSignal = false

    @ObservationIgnored var visibleLevelMeters = 0 {
        didSet {
            if visibleLevelMeters == 0 {
                micLevel = 0
                systemLevel = 0
            }
        }
    }

    init() {
        inputDevice = CoreAudioUtil.defaultInputDevice().map(CoreAudioUtil.deviceInfo)
        outputDevice = CoreAudioUtil.defaultOutputDevice().map(CoreAudioUtil.deviceInfo)
        deviceMonitor.onChange = { [weak self] kind in
            MainActor.assumeIsolated { self?.defaultDeviceChanged(kind) }
        }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.session?.systemWillSleep() }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.session?.systemDidWake() }
        }
    }

    func toggle() {
        switch state {
        case .idle: start()
        case .recording: stop()
        case .starting, .stopping: break
        }
    }

    func start(title: String? = nil, titleIsFinal: Bool = false, sourceApp: String? = nil,
               calendarEvent: CalendarMeeting? = nil) {
        guard state == .idle else { return }
        errorMessage = nil
        diskWarning = nil
        activeAudioIssue = nil
        warning = nil
        dismissedIssues = []

        let free = Self.freeBytes(at: meetingsRoot)
        if let free, free < 300_000_000 {
            errorMessage = "Not enough disk space to record (\(Int64(free).byteString) free). Free some space and try again."
            return
        }
        if let free, free < 2_000_000_000 {
            diskWarning = "Low disk space: \(Int64(free).byteString) free, about \(free / 700_000_000) hours of recording."
            warning = diskWarning
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            beginSession(title: title, titleIsFinal: titleIsFinal, sourceApp: sourceApp, calendarEvent: calendarEvent)
        case .notDetermined:
            state = .starting
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    self.state = .idle
                    if granted {
                        self.beginSession(title: title, titleIsFinal: titleIsFinal, sourceApp: sourceApp, calendarEvent: calendarEvent)
                    } else {
                        self.showMicDenied()
                    }
                }
            }
        default:
            showMicDenied()
        }
    }

    func stop(completion: (() -> Void)? = nil) {
        guard let session, state == .recording else {
            completion?()
            return
        }
        onWillStop?()
        state = .stopping
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        session.stop(input: inputDevice, output: outputDevice) { [weak self] in
            guard let self else { return }
            let folder = session.folder
            self.resetAfterStop()
            self.onFinished?(folder)
            completion?()
        }
    }

    func discard() {
        guard let session, state == .recording else { return }
        state = .stopping
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        session.stop(input: inputDevice, output: outputDevice) { [weak self] in
            guard let self else { return }
            try? FileManager.default.trashItem(at: session.folder.url, resultingItemURL: nil)
            self.resetAfterStop()
            self.onDiscarded?()
        }
    }

    func meetingProcessesChanged() {
        session?.meetingProcessesChanged()
        checkCallAppMicFollow()
    }

    /// Called when `AudioProcessMonitor` reports a change in processes using audio input.
    /// If Zoom/Teams/Chrome switched onto AirPods (or another mic) inside its own settings,
    /// ReMeet follows that active microphone automatically.
    func checkCallAppMicFollow() {
        guard isRecording, let session else { return }
        if let callMic = CoreAudioUtil.activeMeetingAppInputDevice() {
            session.preferredInputChanged(to: callMic.device)
        }
    }

    func adoptSourceApp(_ bundleID: String) {
        session?.setSourceAppIfUnset(bundleID)
    }

    func setTitle(_ newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != title else { return }
        title = trimmed
        session?.setTitle(trimmed)
    }

    func noteTimestamp() -> Double? {
        guard isRecording, let session else { return nil }
        return (max(0, session.elapsedSeconds) * 10).rounded() / 10
    }

    func addNote(_ note: MeetingNote) {
        guard let folder else { return }
        notes.append(note)
        notes.sort { $0.t < $1.t }
        do {
            try NotesFile(url: folder.file(.notes)).append(note)
        } catch {
            errorMessage = "Could not save note: \(error.localizedDescription)"
        }
    }

    // MARK: - Live Audio Issue Quick Actions

    func performAudioIssueAction(_ action: AudioHealthIssue.QuickAction) {
        switch action {
        case .openSystemAudioSettings:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
        case .openMicSettings:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!)
        case .switchToAllAppsScope:
            meetingProcessFilter = nil
            session?.switchToAllAppsScope()
            onScopeSwitchedToAllApps?()
            dismissedIssues.remove(.meetingScopeNoMatch)
            evaluateAudioHealth()
        case .followMeetingMic, .restartCapture:
            session?.forceReconnect()
            evaluateAudioHealth()
        }
    }

    func dismissAudioIssue(_ kind: AudioHealthIssue.Kind) {
        dismissedIssues.insert(kind)
        evaluateAudioHealth()
    }

    func debugSetPreview(recording: Bool, issue: AudioHealthIssue? = nil) {
        guard session == nil else { return }
        if recording {
            state = .recording
            elapsed = 23 * 60 + 41
            micLevel = 0.62
            systemLevel = issue?.kind == .callAudioBlocked ? 0.0 : 0.81
            title = "Client kickoff"
            notes = [MeetingNote(t: 852, text: "Budget cap is 40k, not 50k", kind: .action),
                     MeetingNote(t: 1265, text: "", kind: .bookmark)]
            inputDevice = AudioDeviceInfo(id: 72, uid: "airpods-pro", name: "AirPods Pro", nominalSampleRate: 24_000)
            lastInputSwitch = ("AirPods Pro", 18 * 60 + 2)
            activeAudioIssue = issue
            warning = issue?.detail
        } else {
            resetAfterStop()
            lastInputSwitch = nil
        }
    }

    // MARK: - Private

    private func beginSession(title requestedTitle: String?, titleIsFinal: Bool, sourceApp: String?,
                              calendarEvent: CalendarMeeting? = nil) {
        let start = Date()
        let title = requestedTitle ?? MeetingMeta.defaultTitle
        let folder = MeetingFolder.makeNew(in: meetingsRoot, start: start,
                                           title: requestedTitle ?? "meeting")
        do {
            let initialInput = CoreAudioUtil.activeMeetingAppInputDevice()?.device
                ?? CoreAudioUtil.defaultInputDevice().map(CoreAudioUtil.deviceInfo)
            inputDevice = initialInput
            outputDevice = CoreAudioUtil.defaultOutputDevice().map(CoreAudioUtil.deviceInfo)

            let session = try RecordingSession(folder: folder, startDate: start, title: title,
                                               titleIsUserSet: titleIsFinal && requestedTitle != nil,
                                               sourceApp: sourceApp, calendarEvent: calendarEvent,
                                               input: initialInput, output: outputDevice)
            session.preferredMicDeviceID = {
                CoreAudioUtil.activeMeetingAppInputDevice()?.device.id
            }
            session.onMicDeviceStarted = { [weak self] dev in
                MainActor.assumeIsolated {
                    guard let self, let dev else { return }
                    let previousID = self.inputDevice?.id
                    let previousName = self.inputDevice?.name
                    self.inputDevice = dev
                    if self.elapsed >= 1.5, previousID != nil, previousName != dev.name {
                        self.lastInputSwitch = (dev.name, self.elapsed)
                        self.showDeviceSwitchToast(dev.name)
                        // Reset per-device mute/flatline tracking for the newly attached mic.
                        self.heardMicSignal = false
                        self.dismissedIssues.remove(.micFlatlineZeroes)
                        self.dismissedIssues.remove(.micMutedInOS)
                    }
                }
            }
            session.onLevels = { [weak self] mic, system in
                MainActor.assumeIsolated { self?.updateLevels(mic: mic, system: system) }
            }
            session.onWriteError = { [weak self] message in
                MainActor.assumeIsolated {
                    self?.errorMessage = "ReMeet can't write the recording (\(message)). Is the disk full?"
                }
            }
            session.onEvent = { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.recentEvents.append(event)
                    if self.recentEvents.count > 50 { self.recentEvents.removeFirst(self.recentEvents.count - 50) }
                }
            }
            if let meetingProcessFilter { session.setProcessFilter(meetingProcessFilter) }
            recentEvents = []
            notes = []
            lastInputSwitch = nil
            deviceSwitchToast = nil
            heardCallAudio = false
            heardMicSpeech = false
            heardMicSignal = false
            self.session = session
            self.title = title
            self.folder = folder
            self.startDate = start
            try session.start()
            state = .recording
            elapsed = 0

            let timer = Timer(fire: start.addingTimeInterval(1), interval: 1, repeats: true) { [weak self, weak session] _ in
                MainActor.assumeIsolated {
                    guard let self, let session else { return }
                    self.elapsed = session.elapsedSeconds.rounded()
                    session.checkStreamLiveness()
                    // Evaluate audio health every 2 seconds (or immediately once >= 4s).
                    if Int(self.elapsed) >= 4, Int(self.elapsed) % 2 == 0 {
                        self.evaluateAudioHealth()
                    }
                }
            }
            timer.tolerance = 0.05
            RunLoop.main.add(timer, forMode: .common)
            elapsedTimer = timer
            onStarted?(folder)
        } catch {
            errorMessage = "Could not start recording: \(error.localizedDescription)"
            let failedFolder = folder
            if let session = self.session {
                session.stop(input: inputDevice, output: outputDevice) {
                    try? FileManager.default.removeItem(at: failedFolder.url)
                }
            } else {
                try? FileManager.default.removeItem(at: failedFolder.url)
            }
            self.session = nil
            self.folder = nil
            state = .idle
        }
    }

    private func showDeviceSwitchToast(_ deviceName: String) {
        toastTask?.cancel()
        deviceSwitchToast = "Mic: \(deviceName)"
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled else { return }
            self?.deviceSwitchToast = nil
        }
    }

    /// Evaluates live capture telemetry off Core Audio process/device flags (takes < 0.2 ms).
    private func evaluateAudioHealth() {
        guard isRecording, let session else {
            activeAudioIssue = nil
            warning = diskWarning
            return
        }
        let processes = AudioProcessMonitor.processes()
        let filterObjects = meetingProcessFilter?() ?? []
        let includedSet = Set(filterObjects)
        let scopeOnly = meetingProcessFilter != nil

        let anyAppPlaying = processes.contains { $0.isRunningOutput && !$0.bundleID.isEmpty }
        let effectivePlaying: Bool
        if scopeOnly, !includedSet.isEmpty {
            effectivePlaying = processes.contains { $0.isRunningOutput && includedSet.contains($0.object) }
        } else {
            effectivePlaying = anyAppPlaying
        }

        let currentMic = session.currentMicDevice ?? inputDevice
        let micID = currentMic?.id
        let isMuted = micID.map(CoreAudioUtil.isInputMuted) ?? false
        let isBT = micID.map(CoreAudioUtil.isBluetooth) ?? false

        var mismatch: (appName: String, micName: String)?
        if let callMic = CoreAudioUtil.activeMeetingAppInputDevice(),
           let currentID = micID,
           callMic.device.id != currentID {
            mismatch = (callMic.app.name, callMic.device.name)
        }

        let gaps = session.secondsSinceLastChunks
        let telemetry = AudioHealthTelemetry(
            elapsedSeconds: elapsed,
            micDeviceName: currentMic?.name ?? "Microphone",
            isBluetoothInput: isBT,
            isInputMutedInOS: isMuted,
            micStartError: session.micStartError,
            systemStartError: session.systemStartError,
            secondsSinceLastMicChunk: gaps.mic,
            secondsSinceLastSystemChunk: gaps.system,
            heardMicSpeech: heardMicSpeech,
            heardMicSignal: heardMicSignal,
            heardCallAudio: heardCallAudio,
            otherAppPlayingAudio: scopeOnly && includedSet.isEmpty ? anyAppPlaying : effectivePlaying,
            scopeIsMeetingAppsOnly: scopeOnly,
            matchedMeetingProcessCount: includedSet.count,
            mismatchedCallAppMic: mismatch
        )

        let nextIssue = AudioHealthEvaluator.evaluate(telemetry, dismissed: dismissedIssues)
        if nextIssue != activeAudioIssue {
            activeAudioIssue = nextIssue
            if let nextIssue {
                session.logWarning("audio_health_\(nextIssue.kind.rawValue)", nextIssue.detail)
            }
        }
        warning = activeAudioIssue?.detail ?? diskWarning
    }

    private static func freeBytes(at url: URL) -> Int? {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe.deleteLastPathComponent()
        }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage.map(Int.init)
    }

    private func resetAfterStop() {
        toastTask?.cancel()
        deviceSwitchToast = nil
        session = nil
        folder = nil
        startDate = nil
        state = .idle
        micLevel = 0
        systemLevel = 0
        elapsed = 0
        notes = []
        title = MeetingMeta.defaultTitle
        activeAudioIssue = nil
        diskWarning = nil
        warning = nil
        dismissedIssues = []
        inputDevice = CoreAudioUtil.defaultInputDevice().map(CoreAudioUtil.deviceInfo)
        outputDevice = CoreAudioUtil.defaultOutputDevice().map(CoreAudioUtil.deviceInfo)
    }

    private func defaultDeviceChanged(_ kind: DefaultDeviceMonitor.Kind) {
        switch kind {
        case .input:
            let old = inputDevice
            let fresh = CoreAudioUtil.defaultInputDevice().map(CoreAudioUtil.deviceInfo)
            if !isRecording {
                inputDevice = fresh
            } else if old != fresh {
                session?.defaultInputChanged(from: old, to: fresh)
            }
        case .output:
            let old = outputDevice
            let fresh = CoreAudioUtil.defaultOutputDevice().map(CoreAudioUtil.deviceInfo)
            outputDevice = fresh
            if old != fresh { session?.defaultOutputChanged(from: old, to: fresh) }
        }
    }

    /// Peak-hold meter with decay, mapped from -60...0 dBFS to 0...1.
    private func updateLevels(mic: Float, system: Float) {
        var clearedAnything = false
        if mic > 0.00002, !heardMicSignal {
            heardMicSignal = true
            if activeAudioIssue?.kind == .micFlatlineZeroes { clearedAnything = true }
        }
        if mic > 0.004, !heardMicSpeech {
            heardMicSpeech = true
            if activeAudioIssue?.kind == .bothTracksSilent || activeAudioIssue?.kind == .micDeviceMismatch {
                clearedAnything = true
            }
        }
        if system > 0.0005, !heardCallAudio {
            heardCallAudio = true
            if activeAudioIssue?.kind == .callAudioBlocked || activeAudioIssue?.kind == .bothTracksSilent {
                clearedAnything = true
            }
        }
        if activeAudioIssue?.kind == .streamStalled, (mic > 0 || system > 0) {
            clearedAnything = true
        }
        if clearedAnything {
            evaluateAudioHealth()
        }

        guard visibleLevelMeters > 0 else { return }
        micLevel = max(Self.meterValue(mic), micLevel * 0.8)
        systemLevel = max(Self.meterValue(system), systemLevel * 0.8)
    }

    private static func meterValue(_ peak: Float) -> Float {
        guard peak > 0 else { return 0 }
        let db = 20 * log10(peak)
        return min(max((db + 60) / 60, 0), 1)
    }

    private func showMicDenied() {
        errorMessage = "Microphone access is off. Turn on ReMeet in System Settings > Privacy & Security > Microphone."
    }
}
