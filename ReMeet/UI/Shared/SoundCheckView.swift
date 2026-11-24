import AVFoundation
import AppKit
import ReMeetKit
import SwiftUI

/// Standalone level bars for `LevelProbe` (does not increment `RecorderService.visibleLevelMeters`).
struct ProbeLevelBars: View {
    var level: Float
    var count: Int = 24
    var tint: Color = Theme.accent

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<count, id: \.self) { index in
                let lit = Float(index) < level * Float(count)
                Capsule()
                    .fill(lit ? tint : Theme.line)
                    .frame(width: 4)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Audio level")
        .accessibilityValue("\(Int(level * 100)) percent")
    }
}

/// Interactive Pre-Meeting Sound Check: tests active microphone (including AirPods HFP auto-follow +
/// 3-second voice loopback playback) and verifies System Audio permission end-to-end by playing a
/// gentle external chime through macOS's process tap.
struct SoundCheckCard: View {
    @Environment(AppModel.self) private var model
    var probe: LevelProbe
    var compact: Bool = false
    var autoStart: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 14) {
            headerRow

            // Track 1: Active Microphone ("You")
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: micSymbol)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(probe.isInputMuted ? .orange : Theme.accent)
                    Text(micTitle)
                        .font(.system(size: compact ? 12 : 13, weight: .semibold))
                        .foregroundStyle(Theme.fg)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    micStatusBadge
                }

                HStack(spacing: 8) {
                    ProbeLevelBars(
                        level: probe.micLevel,
                        count: compact ? 18 : 26,
                        tint: probe.isInputMuted ? .orange : Theme.accent
                    )
                    .frame(height: 10)

                    Spacer(minLength: 4)

                    Button {
                        ensureAuthorizedAndRun { probe.runVoiceLoopbackTest() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: voiceButtonSymbol)
                                .font(.system(size: 10.5, weight: .semibold))
                            Text(voiceButtonTitle)
                                .font(.system(size: 11.5, weight: .medium))
                                .lineLimit(1)
                        }
                        .foregroundStyle(Theme.fg)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Theme.surface, in: Capsule())
                        .overlay(Capsule().stroke(Theme.line))
                    }
                    .buttonStyle(.plain)
                    .disabled(model.recorder.isRecording || isRecordingLoopback)
                    .help("Records 3 seconds from your active mic / AirPods and plays it right back so you can verify clarity")
                }

                if probe.isInputMuted {
                    HStack(spacing: 6) {
                        Text("Your microphone is muted in macOS Control Center / Sound settings.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Sound Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!)
                        }
                        .controlSize(.mini)
                    }
                } else if case .failed(let msg) = probe.voiceCheckState {
                    Text(msg).font(.caption).foregroundStyle(.orange)
                }
            }
            .padding(compact ? 9 : 11)
            .background(Theme.mark.opacity(0.42), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            // Track 2: Call Audio ("Others")
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(probe.chimeState == .blocked ? .orange : Theme.accent)
                    Text(outputTitle)
                        .font(.system(size: compact ? 12 : 13, weight: .semibold))
                        .foregroundStyle(Theme.fg)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    callStatusBadge
                }

                HStack(spacing: 8) {
                    ProbeLevelBars(
                        level: probe.systemLevel,
                        count: compact ? 18 : 26,
                        tint: probe.chimeState == .blocked ? .orange : Theme.accent
                    )
                    .frame(height: 10)

                    Spacer(minLength: 4)

                    Button {
                        ensureAuthorizedAndRun { probe.runCallAudioTest() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: probe.chimeState == .playing ? "waveform" : "bell.and.waves.left.and.right")
                                .font(.system(size: 10.5, weight: .semibold))
                            Text(probe.chimeState == .playing ? "Testing…" : "Test Call Audio")
                                .font(.system(size: 11.5, weight: .medium))
                                .lineLimit(1)
                        }
                        .foregroundStyle(Theme.fg)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Theme.surface, in: Capsule())
                        .overlay(Capsule().stroke(Theme.line))
                    }
                    .buttonStyle(.plain)
                    .disabled(model.recorder.isRecording || probe.chimeState == .playing)
                    .help("Plays a brief system chime and verifies ReMeet's call-audio tap hears it")
                }

                if probe.chimeState == .blocked {
                    HStack(spacing: 6) {
                        Text("Call audio didn't come through. Enable ReMeet in System Audio Recording.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Allow…") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
                        }
                        .controlSize(.mini)
                    }
                }
            }
            .padding(compact ? 9 : 11)
            .background(Theme.mark.opacity(0.42), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            if let error = probe.micError ?? probe.systemError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !compact {
                Text("Put your AirPods in anytime during this check—ReMeet automatically follows your active headset and verifies its sample rate.")
                    .font(.caption)
                    .foregroundStyle(Theme.fg2)
            }
        }
        .onAppear {
            if autoStart, !model.recorder.isRecording, SnapshotRenderer.requestedDirectory == nil {
                ensureAuthorizedAndRun { probe.start() }
            }
        }
        .onChange(of: model.recorder.isRecording) { _, recording in
            if recording { probe.stop() }
        }
        .onDisappear {
            if SnapshotRenderer.requestedDirectory == nil {
                probe.stop()
            }
        }
    }

    private var headerRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("Sound Check")
                    .font(.system(size: compact ? 12.5 : 14, weight: .semibold))
                    .foregroundStyle(Theme.fg)
                if !compact {
                    Text("Verify your mic & call capture before your meeting starts")
                        .font(.caption)
                        .foregroundStyle(Theme.fg2)
                }
            }
            Spacer()
            Button(probe.isRunning ? "Stop Monitor" : "Start Monitor") {
                if probe.isRunning {
                    probe.stop()
                } else {
                    ensureAuthorizedAndRun { probe.start() }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(model.recorder.isRecording)
        }
    }

    private var micSymbol: String {
        let lower = (probe.inputDevice?.name ?? "").lowercased()
        if lower.contains("airpods") { return "airpodspro" }
        if probe.isBluetoothInput { return "headphones" }
        return probe.isInputMuted ? "mic.slash.fill" : "mic.fill"
    }

    private var micTitle: String {
        guard let dev = probe.inputDevice else { return "You · No microphone" }
        let khz = dev.nominalSampleRate > 0 ? " · \(Int((dev.nominalSampleRate / 1000).rounded())) kHz" : ""
        return "You · \(dev.name)\(compact ? "" : khz)"
    }

    private var outputTitle: String {
        guard let dev = probe.outputDevice else { return "Call · System Output" }
        return "Call · \(dev.name)"
    }

    @ViewBuilder
    private var micStatusBadge: some View {
        if probe.isInputMuted {
            statusPill("Muted", color: .orange, icon: "exclamationmark.triangle.fill")
        } else if probe.heardMicSpeech {
            statusPill(compact ? "Clear" : "Clear (\(Int(probe.peakMicDB.rounded())) dB)", color: Theme.accent, icon: "checkmark.circle.fill")
        } else if probe.isRunning {
            Text("Speak…")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.fg2)
        } else {
            Text("Ready")
                .font(.system(size: 11))
                .foregroundStyle(Theme.fg3)
        }
    }

    @ViewBuilder
    private var callStatusBadge: some View {
        if probe.heardSystemAudio || probe.chimeState == .verified {
            statusPill("Verified", color: Theme.accent, icon: "checkmark.circle.fill")
        } else if probe.chimeState == .playing {
            Text("Listening…")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.fg2)
        } else if probe.chimeState == .blocked {
            statusPill("Blocked", color: .orange, icon: "exclamationmark.triangle.fill")
        } else {
            Text("Click Test")
                .font(.system(size: 11))
                .foregroundStyle(Theme.fg3)
        }
    }

    private func statusPill(_ text: String, color: Color, icon: String) -> some View {
        HStack(spacing: 3.5) {
            Image(systemName: icon)
                .font(.system(size: 10.5, weight: .semibold))
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6.5)
        .padding(.vertical, 2)
        .background(color.opacity(0.14), in: Capsule())
    }

    private var isRecordingLoopback: Bool {
        if case .recording = probe.voiceCheckState { return true }
        return false
    }

    private var voiceButtonSymbol: String {
        switch probe.voiceCheckState {
        case .recording: "record.circle.fill"
        case .playing: "stop.fill"
        case .idle, .failed: "waveform.badge.mic"
        }
    }

    private var voiceButtonTitle: String {
        switch probe.voiceCheckState {
        case .recording(let left): "Speak (\(left)s)…"
        case .playing: "Playing…"
        case .idle, .failed: compact ? "3s Voice" : "3s Voice Check"
        }
    }

    private func ensureAuthorizedAndRun(_ action: @escaping @MainActor () -> Void) {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    if granted, !model.recorder.isRecording { action() }
                }
            }
        } else if !model.recorder.isRecording {
            action()
        }
    }
}

/// Modal Sound Check sheet launched from Schedule / Walk-In Prep Briefs before joining a call.
struct SoundCheckSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var probe: LevelProbe

    init(probe: LevelProbe? = nil) {
        _probe = State(initialValue: probe ?? LevelProbe())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SoundCheckCard(probe: probe, compact: false, autoStart: probe.chimeState == .idle && !probe.isRunning)

            HStack {
                Spacer()
                AccentCapsuleButton(title: "Done", systemImage: "checkmark") {
                    probe.stop()
                    dismiss()
                }
            }
        }
        .padding(22)
        .frame(width: 470)
        .background(Theme.surface)
    }
}

/// Shared actionable live-recording audio warning card used in Menu Bar, Live Recording view, and Expanded Pill.
struct LiveAudioIssueBanner: View {
    let issue: AudioHealthIssue
    var compact: Bool = false
    let onAction: (AudioHealthIssue.QuickAction) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: compact ? 11 : 12, weight: .semibold))
                    .foregroundStyle(.orange)
                Text(issue.title)
                    .font(.system(size: compact ? 12 : 13, weight: .semibold))
                    .foregroundStyle(Theme.fg)
                    .lineLimit(compact ? 1 : 2)
                Spacer(minLength: 4)
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.fg3)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help("Dismiss warning")
            }

            if !compact {
                Text(issue.detail)
                    .font(.caption)
                    .foregroundStyle(Theme.fg2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let action = issue.action, let title = issue.actionTitle {
                HStack(spacing: 8) {
                    Button {
                        onAction(action)
                    } label: {
                        Text(title)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(Color.orange, in: Capsule())
                    }
                    .buttonStyle(.plain)

                    if compact {
                        Text(issue.detail)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.fg2)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(compact ? 8 : 11)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.orange.opacity(0.35), lineWidth: 1)
        )
    }
}
