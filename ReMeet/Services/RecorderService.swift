import AVFoundation
import AppKit
import CoreAudio
import Foundation
import Observation
import ReMeetKit

/// Owns the current recording: starts and stops a RecordingSession, follows default-device
/// changes, publishes levels and elapsed time, and appends notes. No UI code; the menu bar,
/// note bubble and meeting window all observe this one object.
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
    private(set) var recentEvents: [SessionEvent] = []
    private(set) var errorMessage: String?
    /// Non-fatal problem during a recording (silent call track, low disk), shown in the panel.
    private(set) var warning: String?
    private(set) var folder: MeetingFolder?
    private(set) var startDate: Date?
    private(set) var title = MeetingMeta.defaultTitle
    private(set) var notes: [MeetingNote] = []

    var isRecording: Bool { state == .recording }
    var isBusy: Bool { state == .starting || state == .stopping }

    /// Called after a recording has been stopped and meta.json says "recorded".
    var onFinished: ((MeetingFolder) -> Void)?
    /// Called just before a recording stops, while notes can still be saved (the bubble
    /// flushes a half-typed note here; audit C3).
    var onWillStop: (() -> Void)?
    /// Called after a discarded recording was moved to the Trash.
    var onDiscarded: (() -> Void)?
    /// Called right after capture starts (the pipeline pauses and unloads models).
    var onStarted: ((MeetingFolder) -> Void)?

    var meetingsRoot: URL = MeetingFolder.defaultRoot
    /// Set for "meeting apps only": the process objects the call tap may include.
    var meetingProcessFilter: (() -> [AudioObjectID])?

    @ObservationIgnored private let deviceMonitor = DefaultDeviceMonitor()
    @ObservationIgnored private var session: RecordingSession?
    @ObservationIgnored private var elapsedTimer: Timer?
    /// Level meters currently on screen. Levels are only published while one is visible,
    /// so a recording with no meter showing costs no UI work.
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

    /// `titleIsFinal`: the title is a real name (the calendar event's), not a placeholder the
    /// summary may replace.
    func start(title: String? = nil, titleIsFinal: Bool = false, sourceApp: String? = nil) {
        guard state == .idle else { return }
        errorMessage = nil
        warning = nil
        // ~700 MB per hour of WAV until compression (audit H5).
        let free = Self.freeBytes(at: meetingsRoot)
        if let free, free < 300_000_000 {
            errorMessage = "Not enough disk space to record (\(Int64(free).byteString) free). Free some space and try again."
            return
        }
        if let free, free < 2_000_000_000 {
            warning = "Low disk space: \(Int64(free).byteString) free, about \(free / 700_000_000) hours of recording."
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            beginSession(title: title, titleIsFinal: titleIsFinal, sourceApp: sourceApp)
        case .notDetermined:
            state = .starting
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    self.state = .idle
                    if granted { self.beginSession(title: title, titleIsFinal: titleIsFinal, sourceApp: sourceApp) } else { self.showMicDenied() }
                }
            }
        default:
            showMicDenied()
        }
    }

    /// Stops and finalizes both WAV files. `completion` runs on main once meta.json is written.
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

    /// Stops and moves the meeting folder to the Trash (the menu bar's confirmed Discard).
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

    /// Meeting apps opened or quit while recording ("meeting apps only").
    func meetingProcessesChanged() {
        session?.meetingProcessesChanged()
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

    /// Seconds on the audio timeline for a note field opened now (nil when not recording).
    /// Host clock, like the audio, so notes stay aligned even after the Mac slept.
    func noteTimestamp() -> Double? {
        guard isRecording, let session else { return nil }
        return (max(0, session.elapsedSeconds) * 10).rounded() / 10
    }

    /// Appends to notes.json right away.
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

    /// Sample state for SnapshotRenderer only; never called in normal use.
    func debugSetPreview(recording: Bool) {
        guard session == nil else { return }
        if recording {
            state = .recording
            elapsed = 23 * 60 + 41
            micLevel = 0.62
            systemLevel = 0.81
            title = "Client kickoff"
            notes = [MeetingNote(t: 852, text: "Budget cap is 40k, not 50k", kind: .action),
                     MeetingNote(t: 1265, text: "", kind: .bookmark)]
            lastInputSwitch = ("AirPods Pro", 18 * 60 + 2)
        } else {
            resetAfterStop()
            lastInputSwitch = nil
        }
    }

    // MARK: - Private

    private func beginSession(title requestedTitle: String?, titleIsFinal: Bool, sourceApp: String?) {
        let start = Date()
        let title = requestedTitle ?? MeetingMeta.defaultTitle
        let folder = MeetingFolder.makeNew(in: meetingsRoot, start: start,
                                           title: requestedTitle ?? "meeting")
        do {
            let session = try RecordingSession(folder: folder, startDate: start, title: title,
                                               titleIsUserSet: titleIsFinal && requestedTitle != nil,
                                               sourceApp: sourceApp, input: inputDevice, output: outputDevice)
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
            self.session = session
            self.title = title
            self.folder = folder
            self.startDate = start
            try session.start()
            state = .recording
            elapsed = 0
            // Once per second, on the second boundary: the timer shows whole seconds, and every
            // menu bar label change makes SwiftUI rebuild the main menu.
            heardCallAudio = false
            let timer = Timer(fire: start.addingTimeInterval(1), interval: 1, repeats: true) { [weak self, weak session] _ in
                MainActor.assumeIsolated {
                    guard let self, let session else { return }
                    self.elapsed = session.elapsedSeconds.rounded()
                    if Int(self.elapsed) % 10 == 0 { self.checkCallAudio() }
                }
            }
            timer.tolerance = 0.05
            RunLoop.main.add(timer, forMode: .common)
            elapsedTimer = timer
            onStarted?(folder)
        } catch {
            errorMessage = "Could not start recording: \(error.localizedDescription)"
            // Nothing usable was captured: stop and remove the half-made folder, so it does not
            // turn into a failed meeting later (audit C4).
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

    /// True once the call track delivered sound in this recording.
    @ObservationIgnored private var heardCallAudio = false

    /// A call track that stays silent while another app is playing sound usually means System
    /// Audio Recording is not allowed (common after an ad-hoc rebuild); say so (audit H2).
    private func checkCallAudio() {
        guard isRecording, elapsed >= 20, !heardCallAudio else { return }
        let processes = AudioProcessMonitor.processes()
        let playing: Bool
        if let filter = meetingProcessFilter {
            let included = Set(filter())
            playing = processes.contains { $0.isRunningOutput && included.contains($0.object) }
        } else {
            playing = processes.contains { $0.isRunningOutput && !$0.bundleID.isEmpty }
        }
        if playing {
            warning = "ReMeet isn't hearing the call audio. Check System Settings > Privacy & Security > Screen & System Audio Recording > System Audio Recording Only, and turn on ReMeet."
            session?.logWarning("system_audio_silent", "call track silent for \(Int(elapsed)) s while another app plays audio")
        }
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
        session = nil
        folder = nil
        startDate = nil
        state = .idle
        micLevel = 0
        systemLevel = 0
        elapsed = 0
        notes = []
        title = MeetingMeta.defaultTitle
        if warning?.hasPrefix("ReMeet isn't hearing") == true { warning = nil }
    }

    private func defaultDeviceChanged(_ kind: DefaultDeviceMonitor.Kind) {
        switch kind {
        case .input:
            let old = inputDevice
            inputDevice = CoreAudioUtil.defaultInputDevice().map(CoreAudioUtil.deviceInfo)
            if old != inputDevice {
                session?.defaultInputChanged(from: old, to: inputDevice)
                if isRecording { lastInputSwitch = (inputDevice?.name ?? "No input", elapsed) }
            }
        case .output:
            let old = outputDevice
            outputDevice = CoreAudioUtil.defaultOutputDevice().map(CoreAudioUtil.deviceInfo)
            if old != outputDevice { session?.defaultOutputChanged(from: old, to: outputDevice) }
        }
    }

    /// Peak-hold meter with decay, mapped from -60...0 dBFS to 0...1.
    private func updateLevels(mic: Float, system: Float) {
        if system > 0.0005, !heardCallAudio {
            heardCallAudio = true
            if warning?.hasPrefix("ReMeet isn't hearing") == true { warning = nil }
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
