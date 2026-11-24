import Foundation

/// Live audio diagnostic surfaced during a recording when one or both tracks are silent,
/// muted, blocked by macOS permissions, stalled after a Bluetooth switch, or mismatched.
public struct AudioHealthIssue: Equatable, Sendable, Identifiable {
    public enum Kind: String, Equatable, Sendable {
        case micFailedToStart
        case systemTapFailed
        case streamStalled
        case callAudioBlocked
        case meetingScopeNoMatch
        case micMutedInOS
        case micDeviceMismatch
        case micFlatlineZeroes
        case bothTracksSilent
    }

    public enum QuickAction: Equatable, Sendable {
        case openSystemAudioSettings
        case openMicSettings
        case switchToAllAppsScope
        case followMeetingMic
        case restartCapture
    }

    public var kind: Kind
    public var pillLabel: String
    public var title: String
    public var detail: String
    public var action: QuickAction?

    public var id: String { kind.rawValue }

    public init(kind: Kind, pillLabel: String, title: String, detail: String, action: QuickAction? = nil) {
        self.kind = kind
        self.pillLabel = pillLabel
        self.title = title
        self.detail = detail
        self.action = action
    }

    public var actionTitle: String? {
        switch action {
        case .openSystemAudioSettings: "Open System Settings"
        case .openMicSettings: "Mic Settings"
        case .switchToAllAppsScope: "Capture All Apps"
        case .followMeetingMic: "Use Call Mic"
        case .restartCapture: "Reconnect Audio"
        case nil: nil
        }
    }
}

/// Snapshot of live capture telemetry evaluated once per second while recording.
public struct AudioHealthTelemetry: Equatable, Sendable {
    public var elapsedSeconds: Double
    public var micDeviceName: String
    public var isBluetoothInput: Bool
    public var isInputMutedInOS: Bool
    public var micStartError: String?
    public var systemStartError: String?
    public var secondsSinceLastMicChunk: Double
    public var secondsSinceLastSystemChunk: Double
    /// True once mic peak exceeded speech floor (~ -48 dBFS, `0.004`).
    public var heardMicSpeech: Bool
    /// True once mic delivered any non-zero thermal/room signal (`> 0.00002`), proving ADC isn't dead zeroes.
    public var heardMicSignal: Bool
    /// True once call tap delivered any sound (`> 0.0005`).
    public var heardCallAudio: Bool
    /// Another app on the Mac is currently outputting audio (`isRunningOutput`).
    public var otherAppPlayingAudio: Bool
    /// Recording scope is `.meetingApps` rather than `.allApps`.
    public var scopeIsMeetingAppsOnly: Bool
    /// Number of running meeting-app processes included in the process-filtered tap.
    public var matchedMeetingProcessCount: Int
    /// Set when an active call app (e.g. Zoom) is capturing from a different mic than ReMeet's current input.
    public var mismatchedCallAppMic: (appName: String, micName: String)?

    public static func == (lhs: AudioHealthTelemetry, rhs: AudioHealthTelemetry) -> Bool {
        lhs.elapsedSeconds == rhs.elapsedSeconds
            && lhs.micDeviceName == rhs.micDeviceName
            && lhs.isBluetoothInput == rhs.isBluetoothInput
            && lhs.isInputMutedInOS == rhs.isInputMutedInOS
            && lhs.micStartError == rhs.micStartError
            && lhs.systemStartError == rhs.systemStartError
            && lhs.secondsSinceLastMicChunk == rhs.secondsSinceLastMicChunk
            && lhs.secondsSinceLastSystemChunk == rhs.secondsSinceLastSystemChunk
            && lhs.heardMicSpeech == rhs.heardMicSpeech
            && lhs.heardMicSignal == rhs.heardMicSignal
            && lhs.heardCallAudio == rhs.heardCallAudio
            && lhs.otherAppPlayingAudio == rhs.otherAppPlayingAudio
            && lhs.scopeIsMeetingAppsOnly == rhs.scopeIsMeetingAppsOnly
            && lhs.matchedMeetingProcessCount == rhs.matchedMeetingProcessCount
            && lhs.mismatchedCallAppMic?.appName == rhs.mismatchedCallAppMic?.appName
            && lhs.mismatchedCallAppMic?.micName == rhs.mismatchedCallAppMic?.micName
    }

    public init(elapsedSeconds: Double,
                micDeviceName: String = "Microphone",
                isBluetoothInput: Bool = false,
                isInputMutedInOS: Bool = false,
                micStartError: String? = nil,
                systemStartError: String? = nil,
                secondsSinceLastMicChunk: Double = 0,
                secondsSinceLastSystemChunk: Double = 0,
                heardMicSpeech: Bool = false,
                heardMicSignal: Bool = false,
                heardCallAudio: Bool = false,
                otherAppPlayingAudio: Bool = false,
                scopeIsMeetingAppsOnly: Bool = false,
                matchedMeetingProcessCount: Int = 0,
                mismatchedCallAppMic: (appName: String, micName: String)? = nil) {
        self.elapsedSeconds = elapsedSeconds
        self.micDeviceName = micDeviceName
        self.isBluetoothInput = isBluetoothInput
        self.isInputMutedInOS = isInputMutedInOS
        self.micStartError = micStartError
        self.systemStartError = systemStartError
        self.secondsSinceLastMicChunk = secondsSinceLastMicChunk
        self.secondsSinceLastSystemChunk = secondsSinceLastSystemChunk
        self.heardMicSpeech = heardMicSpeech
        self.heardMicSignal = heardMicSignal
        self.heardCallAudio = heardCallAudio
        self.otherAppPlayingAudio = otherAppPlayingAudio
        self.scopeIsMeetingAppsOnly = scopeIsMeetingAppsOnly
        self.matchedMeetingProcessCount = matchedMeetingProcessCount
        self.mismatchedCallAppMic = mismatchedCallAppMic
    }
}

/// Pure, deterministic evaluator for live recording health. Every issue clears automatically
/// the moment valid audio arrives on the affected track, unless explicitly dismissed by kind.
public enum AudioHealthEvaluator {
    public static func evaluate(_ t: AudioHealthTelemetry,
                                dismissed: Set<AudioHealthIssue.Kind> = []) -> AudioHealthIssue? {
        func allow(_ kind: AudioHealthIssue.Kind) -> Bool { !dismissed.contains(kind) }

        // 1. Hard start failure on either stream (after 4s of retry window for AirPods HFP).
        if t.elapsedSeconds >= 4, let err = t.micStartError, allow(.micFailedToStart) {
            return AudioHealthIssue(
                kind: .micFailedToStart,
                pillLabel: "No mic",
                title: "Microphone isn't recording",
                detail: "ReMeet couldn't open \(t.micDeviceName) (\(err)). Check your input device or reconnect AirPods.",
                action: .restartCapture
            )
        }
        if t.elapsedSeconds >= 4, let err = t.systemStartError, allow(.systemTapFailed) {
            return AudioHealthIssue(
                kind: .systemTapFailed,
                pillLabel: "No call tap",
                title: "Call audio capture failed to start",
                detail: "ReMeet couldn't tap system audio (\(err)). Only your microphone is being recorded.",
                action: .restartCapture
            )
        }

        // 2. OS / Hardware Mute on the active microphone.
        if t.elapsedSeconds >= 5, t.isInputMutedInOS, allow(.micMutedInOS) {
            return AudioHealthIssue(
                kind: .micMutedInOS,
                pillLabel: "Mic muted",
                title: "\(t.micDeviceName) is muted in macOS",
                detail: "Unmute your microphone in the menu bar / Control Center so your side of the conversation is recorded.",
                action: .openMicSettings
            )
        }

        // 3. Stream stalled mid-call (no audio buffers delivered for >= 6s while active).
        let systemExpected = !t.scopeIsMeetingAppsOnly || t.matchedMeetingProcessCount > 0
        if t.elapsedSeconds >= 7,
           (t.secondsSinceLastMicChunk >= 6 || (systemExpected && t.secondsSinceLastSystemChunk >= 6)),
           allow(.streamStalled) {
            let which = t.secondsSinceLastMicChunk >= 6 ? t.micDeviceName : "Call audio"
            return AudioHealthIssue(
                kind: .streamStalled,
                pillLabel: "Audio paused",
                title: "\(which) stopped sending audio",
                detail: t.isBluetoothInput
                    ? "Bluetooth headset profile may still be switching. ReMeet is reconnecting automatically."
                    : "The audio device stopped delivering samples. Click Reconnect Audio if this persists.",
                action: .restartCapture
            )
        }

        // 4. "Meeting apps only" scope is active, 0 meeting apps matched, yet another app is playing sound!
        if t.elapsedSeconds >= 8,
           t.scopeIsMeetingAppsOnly,
           t.matchedMeetingProcessCount == 0,
           !t.heardCallAudio,
           t.otherAppPlayingAudio,
           allow(.meetingScopeNoMatch) {
            return AudioHealthIssue(
                kind: .meetingScopeNoMatch,
                pillLabel: "No call app",
                title: "Call audio isn't matching a known meeting app",
                detail: "Scope is set to \u{201C}Meeting apps only\u{201D}, and another app is playing sound. Switch to All Apps so nothing is missed.",
                action: .switchToAllAppsScope
            )
        }

        // 5. System Audio Recording permission off / silent tap while another app plays audio (8s instead of 20s!).
        if t.elapsedSeconds >= 8,
           !t.heardCallAudio,
           t.otherAppPlayingAudio,
           systemExpected,
           allow(.callAudioBlocked) {
            return AudioHealthIssue(
                kind: .callAudioBlocked,
                pillLabel: "Call silent",
                title: "ReMeet isn't hearing the call audio",
                detail: "Enable ReMeet in System Settings → Privacy & Security → Screen & System Audio Recording → System Audio Recording Only.",
                action: .openSystemAudioSettings
            )
        }

        // 6. Active call app is using a DIFFERENT mic (e.g. AirPods in Zoom while macOS Default is MacBook Mic)
        //    and ReMeet hasn't heard speech on its current mic.
        if t.elapsedSeconds >= 6,
           let mismatch = t.mismatchedCallAppMic,
           !t.heardMicSpeech,
           allow(.micDeviceMismatch) {
            return AudioHealthIssue(
                kind: .micDeviceMismatch,
                pillLabel: "Wrong mic?",
                title: "\(mismatch.appName) is using \(mismatch.micName)",
                detail: "ReMeet is recording \(t.micDeviceName). Switch to \(mismatch.micName) so your voice comes through clearly.",
                action: .followMeetingMic
            )
        }

        // 7. Microphone flatlined at exact digital zero (`0.0`) for 12s (closed clamshell lid, dead USB mic, wedged HFP).
        if t.elapsedSeconds >= 12,
           !t.heardMicSignal,
           allow(.micFlatlineZeroes) {
            return AudioHealthIssue(
                kind: .micFlatlineZeroes,
                pillLabel: "Mic silent",
                title: "Zero signal from \(t.micDeviceName)",
                detail: "Your microphone is sending complete digital silence (lid closed, hardware mute switch, or disconnected headset).",
                action: .restartCapture
            )
        }

        // 8. 25 seconds into a recording and neither mic speech nor call audio has been heard yet.
        if t.elapsedSeconds >= 25,
           !t.heardMicSpeech,
           !t.heardCallAudio,
           allow(.bothTracksSilent) {
            return AudioHealthIssue(
                kind: .bothTracksSilent,
                pillLabel: "No audio yet",
                title: "No voice or call audio detected yet",
                detail: "Both your mic (\(t.micDeviceName)) and call audio have been quiet so far. Speak or check your audio devices to confirm.",
                action: .openMicSettings
            )
        }

        return nil
    }
}
