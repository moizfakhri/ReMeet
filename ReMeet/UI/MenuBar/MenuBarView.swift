import KeyboardShortcuts
import ReMeetKit
import SwiftUI

/// The menu bar popover: idle (start + recent) or recording (title, timer, levels, stop).
struct MenuBarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.recorder.isRecording || model.recorder.state == .stopping {
                RecordingPanel()
            } else {
                IdlePanel()
            }
            if let error = model.recorder.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(Theme.recordingLabel)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }
            ExtraRows()
            Divider().padding(.horizontal, 8)
            FooterRows()
        }
        .frame(width: 320)
        .padding(.vertical, 6)
    }
}

// MARK: - Idle

private struct IdlePanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                model.toggleRecording()
            } label: {
                HStack {
                    Label("Start recording", systemImage: "record.circle")
                    Spacer()
                    Text(KeyboardShortcuts.Name.toggleRecording.hint).font(.system(size: 11.5)).opacity(0.8)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(model.recorder.isBusy)
            .keyboardShortcut("r", modifiers: [.option, .command])

            Text(sourceLine)
                .font(.caption)
                .foregroundStyle(Theme.fg2)
                .lineLimit(1)

            RecentMeetings()
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private var sourceLine: String {
        let mic = model.recorder.inputDevice?.name ?? "No microphone"
        let scope = RecordingScope(rawValue: UserDefaults.standard.string(forKey: SettingsKey.recordingScope) ?? "") ?? .allApps
        return "\(mic) · \(scope == .allApps ? "all call audio" : "meeting apps only")"
    }
}

private struct RecentMeetings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let recent = Array(model.library.items.prefix(3))
        if !recent.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("Recent")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.fg3)
                    .padding(.top, 4)
                ForEach(recent) { item in
                    MenuRow {
                        model.openMeetings(selecting: item.folder)
                    } label: {
                        Text(item.meta.title).lineLimit(1)
                        Spacer()
                        MeetingStatusText(meta: item.meta, compact: true)
                    }
                }
            }
        }
    }
}

// MARK: - Recording

private struct RecordingPanel: View {
    @Environment(AppModel.self) private var model
    @State private var title = ""
    @State private var confirmingDiscard = false
    @FocusState private var titleFocused: Bool

    var body: some View {
        let recorder = model.recorder
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle().fill(Theme.recording).frame(width: 8, height: 8)
                TextField("Meeting title", text: $title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .semibold))
                    .focused($titleFocused)
                    .onSubmit { recorder.setTitle(title) }
                    .onChange(of: titleFocused) { _, focused in
                        if !focused { recorder.setTitle(title) }
                    }
                ShortcutHint("Rename")
            }

            Text(TimeFormat.timer(recorder.elapsed))
                .font(Fonts.timer)
                .monospacedDigit()
                .foregroundStyle(Theme.fg)

            VStack(alignment: .leading, spacing: 6) {
                LevelRow(label: "You", level: recorder.micLevel)
                LevelRow(label: "Call", level: recorder.systemLevel)
            }

            Text(micLine)
                .font(.caption)
                .foregroundStyle(Theme.fg2)
                .lineLimit(1)

            HStack(spacing: 8) {
                Button {
                    model.addNoteShortcut()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.pencil")
                        Text("Note")
                        Text(KeyboardShortcuts.Name.addNote.hint).font(.system(size: 11)).foregroundStyle(Theme.fg3)
                    }
                    .fixedSize()
                }
                .buttonStyle(.glass)
                .keyboardShortcut("n", modifiers: [.option, .command])

                Button {
                    recorder.stop()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "stop.fill")
                        Text("Stop")
                        Text(KeyboardShortcuts.Name.toggleRecording.hint).font(.system(size: 11)).opacity(0.8)
                    }
                    .fixedSize()
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.recordingFill)
                .keyboardShortcut("r", modifiers: [.option, .command])
                .disabled(recorder.state == .stopping)

                Spacer()
                if recorder.notes.count > 0 {
                    Text("\(recorder.notes.count) note\(recorder.notes.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(Theme.fg2)
                }
            }

            if let seconds = model.bubble.state.callEndCountdown {
                HStack {
                    Text("Call ended · stops in \(seconds) s")
                        .font(.caption)
                        .foregroundStyle(Theme.fg2)
                    Spacer()
                    Button("Keep recording") { model.keepRecordingAfterCallEnd() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }

            Button(model.bubble.isVisible ? "Hide recording pill" : "Show recording pill") {
                if model.bubble.isVisible {
                    model.bubble.hidePill()
                } else {
                    model.bubble.showPill()
                }
            }
            .buttonStyle(.borderless)
            .font(.caption)

            if confirmingDiscard {
                HStack {
                    Text("Delete this recording?")
                        .font(.callout)
                    Spacer()
                    Button("Cancel") { confirmingDiscard = false }
                    Button("Discard", role: .destructive) {
                        confirmingDiscard = false
                        recorder.discard()
                    }
                    .tint(Theme.recordingFill)
                }
            } else {
                Button("Discard recording…") { confirmingDiscard = true }
                    .buttonStyle(.link)
                    .font(.caption)
                    .foregroundStyle(Theme.fg2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .onAppear { title = recorder.title }
    }

    private var micLine: String {
        let recorder = model.recorder
        let name = recorder.inputDevice?.name ?? "No microphone"
        if let change = recorder.lastInputSwitch {
            return "\(change.name) · switched at \(TimeFormat.clock(change.at))"
        }
        return name
    }
}

/// Live level as a row of small bars in the accent color. No implicit animation: levels
/// arrive 20 times a second, and animating them kept the UI rendering continuously.
/// While visible it tells the recorder to publish levels (they are not computed for UI
/// otherwise).
struct LevelBars: View {
    var level: Float
    var count = 16
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<count, id: \.self) { index in
                let lit = Float(index) < level * Float(count)
                Capsule()
                    .fill(lit ? Theme.accent : Theme.line)
                    .frame(width: 4)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Level")
        .accessibilityValue("\(Int(level * 100)) percent")
        .onAppear { model.recorder.visibleLevelMeters += 1 }
        .onDisappear { model.recorder.visibleLevelMeters = max(0, model.recorder.visibleLevelMeters - 1) }
    }
}

private struct LevelRow: View {
    let label: String
    let level: Float

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.callout)
                .foregroundStyle(Theme.fg2)
                .frame(width: 34, alignment: .leading)
            LevelBars(level: level, count: 28)
                .frame(height: 10)
        }
    }
}

// MARK: - Shared rows

/// Processing row (stage + progress) and failed meetings with Retry / Dismiss.
private struct ExtraRows: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let failed = model.failedMeetings
        if model.queue.current != nil || !failed.isEmpty || model.recorder.warning != nil {
            VStack(alignment: .leading, spacing: 8) {
                if let warning = model.recorder.warning {
                    Label(warning, systemImage: "speaker.slash")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let activity = model.queue.current {
                    let title = model.library.item(for: activity.folder)?.meta.title ?? "Meeting"
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(title).font(.callout.weight(.medium)).lineLimit(1)
                            Spacer()
                            if model.queue.pending.count > 0 {
                                Text("+\(model.queue.pending.count) waiting").font(.caption).foregroundStyle(Theme.fg2)
                            }
                        }
                        HStack(spacing: 8) {
                            Text(activity.stage.displayName).font(.caption).foregroundStyle(Theme.fg2)
                            if let p = activity.progress {
                                ProgressView(value: p).controlSize(.small)
                            } else {
                                ProgressView().controlSize(.small)
                            }
                            Spacer()
                            Button(model.queue.stoppingFolder == activity.folder ? "Stopping…" : "Stop") {
                                model.queue.stop(activity.folder)
                            }
                            .controlSize(.small)
                            .disabled(model.queue.stoppingFolder == activity.folder)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                ForEach(failed) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Text(item.meta.title).font(.callout.weight(.medium)).lineLimit(1)
                        }
                        Text("\(item.meta.failure?.stage.displayName ?? "Processing") failed: \(item.meta.failure?.message ?? "")")
                            .font(.caption).foregroundStyle(Theme.fg2).lineLimit(2)
                        HStack {
                            Button("Retry") { model.retryFailed(item.folder) }
                            Button("Open") { model.openMeetings(selecting: item.folder) }
                            Button("Dismiss") { model.dismissFailure(item.folder) }
                        }
                        .controlSize(.small)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
    }
}

private struct FooterRows: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuRow { model.openMeetings() } label: {
                Text("Open ReMeet")
                Spacer()
                ShortcutHint("⌘O")
            }
            .keyboardShortcut("o", modifiers: .command)
            MenuRow { model.openSettings() } label: {
                Text("Settings…")
                Spacer()
                ShortcutHint("⌘,")
            }
            .keyboardShortcut(",", modifiers: .command)
            MenuRow { NSApp.terminate(nil) } label: {
                Text("Quit ReMeet")
                Spacer()
                ShortcutHint("⌘Q")
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
    }
}

/// A full-width, menu-like row with a hover highlight.
struct MenuRow<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) { label() }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
                .background(hovering ? Theme.mark : .clear, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Time for finished meetings, stage text otherwise ("Transcribing", "Failed").
struct MeetingStatusText: View {
    let meta: MeetingMeta
    var compact = false

    var body: some View {
        switch meta.status {
        case .recording:
            HStack(spacing: 4) {
                Circle().fill(Theme.recording).frame(width: 6, height: 6)
                Text("Recording")
            }
            .font(.caption)
            .foregroundStyle(Theme.recordingLabel)
        case .failed:
            Label("Failed", systemImage: "exclamationmark.triangle.fill")
                .labelStyle(.titleAndIcon)
                .font(.caption)
                .foregroundStyle(.orange)
        case .summarized:
            Text(timeText).font(.caption).foregroundStyle(Theme.fg2).monospacedDigit()
        default:
            Text(meta.nextStage?.displayName ?? "")
                .font(.caption)
                .foregroundStyle(Theme.fg2)
        }
    }

    private var timeText: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(meta.startTime) {
            return meta.startTime.formatted(date: .omitted, time: .shortened)
        }
        return meta.startTime.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }
}
