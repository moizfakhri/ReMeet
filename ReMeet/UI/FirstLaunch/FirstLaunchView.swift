import AppKit
import AVFoundation
import KeyboardShortcuts
import ReMeetKit
import SwiftUI
import UserNotifications

/// Shown once: permissions with live meters, model downloads, where things are.
/// Closing it at any point is fine; downloads continue and transcripts wait for them.
struct FirstLaunchView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var step = 0
    @State private var probe = LevelProbe()
    @State private var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var notificationsAllowed: Bool?

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: permissions
                case 1: models
                default: tour
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(32)

            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<3) { i in
                        Circle().fill(i == step ? Theme.accent : Theme.line).frame(width: 7, height: 7)
                    }
                }
                Spacer()
                if step > 0 { Button("Back") { step -= 1 } }
                Button(step == 2 ? "Done" : "Continue") {
                    if step == 2 { finish() } else { step += 1 }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 18)
        }
        .frame(width: 600, height: 520)
        .background(Theme.surface)
        .onAppear { NSApp.activate() }
        .onChange(of: step) { _, new in
            if new == 1 { model.models.downloadMissing(model.requiredModels) }
            if new != 0 { probe.stop() }
        }
        .onChange(of: model.recorder.isRecording) { _, recording in
            if recording { probe.stop() }
        }
        .onDisappear {
            probe.stop()
            // Snapshot renders must not mark the real first launch as done (audit M4).
            if SnapshotRenderer.requestedDirectory == nil {
                UserDefaults.standard.set(true, forKey: SettingsKey.hasCompletedFirstLaunch)
            }
        }
    }

    // MARK: - Step 1

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Welcome to ReMeet").font(Fonts.title)
            Text("ReMeet records your side and the call as two tracks, then transcribes and summarizes them on this Mac. It needs two permissions.")
                .foregroundStyle(Theme.fg2)
                .fixedSize(horizontal: false, vertical: true)

            PermissionRow(title: "Microphone", detail: "Your voice, from whatever input your Mac is using.",
                          granted: micStatus == .authorized, level: probe.micLevel) {
                AVCaptureDevice.requestAccess(for: .audio) { _ in
                    DispatchQueue.main.async {
                        micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
                        probe.stop()
                        if !model.recorder.isRecording { probe.start() }
                    }
                }
            }
            PermissionRow(title: "Call audio", detail: "What the other people say. Click Test to play a quick chime and verify.",
                          granted: probe.heardSystemAudio, level: probe.systemLevel, buttonTitle: "Test") {
                if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                    AVCaptureDevice.requestAccess(for: .audio) { _ in
                        DispatchQueue.main.async {
                            micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
                            if !model.recorder.isRecording { probe.runCallAudioTest() }
                        }
                    }
                } else {
                    micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
                    if !model.recorder.isRecording { probe.runCallAudioTest() }
                }
            }
            PermissionRow(title: "Notifications", detail: "Tells you when a summary is ready.",
                          granted: notificationsAllowed == true, level: nil) {
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    DispatchQueue.main.async { notificationsAllowed = granted }
                }
            }
            if micStatus == .denied {
                Text("Microphone access is off. Turn on ReMeet in System Settings > Privacy & Security > Microphone.")
                    .font(.callout).foregroundStyle(.orange)
            }
            Text("If the call meter stays flat while audio plays: System Settings > Privacy & Security > Screen & System Audio Recording > System Audio Recording Only, turn on ReMeet.")
                .font(.caption)
                .foregroundStyle(Theme.fg3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            if micStatus == .authorized, SnapshotRenderer.requestedDirectory == nil { probe.start() }
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                let allowed = settings.authorizationStatus == .authorized
                DispatchQueue.main.async { notificationsAllowed = allowed }
            }
        }
    }

    // MARK: - Step 2

    private var models: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Downloading the models").font(Fonts.title)
            Text("Everything runs on this Mac, so ReMeet downloads its speech and summary models once (about \(totalBytes.byteString)). You can close this window; recordings work right away and their transcripts wait until the models are here.")
                .foregroundStyle(Theme.fg2)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(model.requiredModels) { id in
                ModelRow(id: id)
            }
        }
    }

    private var totalBytes: Int64 {
        model.requiredModels.reduce(0) { $0 + $1.approximateBytes }
    }

    // MARK: - Step 3

    private var tour: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Where things are").font(Fonts.title)
            TourRow(symbol: "waveform", title: "Menu bar",
                    detail: "ReMeet lives in the menu bar (top right). It turns into a red dot and a timer while recording.")
            TourRow(symbol: "record.circle", title: "\(KeyboardShortcuts.Name.toggleRecording.hint)  Start or stop recording",
                    detail: "Works from any app. ReMeet follows your Mac's current mic and never switches it.")
            TourRow(symbol: "square.and.pencil", title: "\(KeyboardShortcuts.Name.addNote.hint)  Add a note",
                    detail: "Return saves a note, ⌘Return an action item, an empty Return a bookmark. Your notes shape the summary.")
            TourRow(symbol: "doc.text", title: "⌘O  Open ReMeet",
                    detail: "Summaries, transcripts and playback for every meeting.")
            Text("Shortcuts can be changed in Settings.")
                .font(.callout).foregroundStyle(Theme.fg2)
        }
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: SettingsKey.hasCompletedFirstLaunch)
        probe.stop()
        dismissWindow(id: WindowID.welcome)
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let level: Float?
    var buttonTitle: String = "Allow"
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 18))
                .foregroundStyle(granted ? Theme.accent : Theme.fg3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.callout).foregroundStyle(Theme.fg2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let level {
                ProbeLevelBars(level: level, count: 10).frame(width: 60, height: 10)
            }
            if !granted {
                Button(buttonTitle, action: action)
            }
        }
    }
}

struct ModelRow: View {
    @Environment(AppModel.self) private var model
    let id: ModelID
    var allowDelete = false
    @State private var confirmDelete = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(id.displayName).font(.system(size: 13.5, weight: .semibold))
                Text("\(id.detail) · \(sizeText)").font(.caption).foregroundStyle(Theme.fg2)
            }
            Spacer()
            switch model.models.state(id) {
            case .ready:
                Label("Ready", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Theme.accent)
                    .font(.callout)
                if allowDelete {
                    Button("Delete…") { confirmDelete = true }
                }
            case .downloading(let p):
                ProgressView(value: p).frame(width: 140)
                Text("\(Int(p * 100))%").font(.caption.monospacedDigit()).frame(width: 34, alignment: .trailing)
                Button("Cancel") { model.models.cancel(id) }
            case .missing:
                Button("Download") { model.models.download(id) }
            case .failed(let message):
                Text(message).font(.caption).foregroundStyle(.orange).lineLimit(2).frame(maxWidth: 200)
                Button("Retry") { model.models.download(id) }
            }
        }
        .confirmationDialog("Delete \(id.displayName)?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { model.models.delete(id) }
        } message: {
            Text("New meetings will wait at this step until you download it again.")
        }
    }

    private var sizeText: String {
        model.models.isReady(id) ? model.models.sizeOnDisk(id).byteString : "about \(id.approximateBytes.byteString)"
    }
}

private struct TourRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 18))
                .foregroundStyle(Theme.accent)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.callout).foregroundStyle(Theme.fg2).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
