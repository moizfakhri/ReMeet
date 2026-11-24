import KeyboardShortcuts
import ReMeetKit
import SwiftUI

/// The recording pill, which morphs into the note field.
struct BubbleView: View {
    let controller: BubbleController
    @Bindable var state: BubbleState
    var body: some View {
        // The glass is a sibling of the level meter, not its background. Levels arrive
        // 20 times a second; redrawing glassEffect on each of those kept the floating
        // bar repainting at display rate. Not a GlassEffectContainer: on macOS 27 a
        // focused text field inside one hangs the main thread (bubble self-test).
        // Everything is pinned to the bubble's fixed corner, so resizing the window never
        // moves it on screen; the controller animates `expanded`.
        let size = state.expanded ? BubbleController.expandedSize : BubbleController.collapsedSize
        let corner: Alignment = state.anchorTrailing ? .topTrailing : .topLeading
        ZStack(alignment: corner) {
            GlassPlate(size: size)
                .equatable()
            ZStack(alignment: corner) {
                if state.expanded {
                    NoteField(controller: controller, state: state)
                        .transition(Self.fade(delay: 0.1))
                } else if let seconds = state.callEndCountdown {
                    CallEndedPill(controller: controller, seconds: seconds)
                        .transition(Self.fade(delay: 0.12))
                } else {
                    Pill(controller: controller)
                        .transition(Self.fade(delay: 0.12))
                }
            }
            .frame(width: size.width - 2 * BubbleController.margin, height: size.height - 2 * BubbleController.margin, alignment: corner)
            .clipShape(GlassPlate.shape)
        }
        .padding(BubbleController.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: corner)
    }

    /// The outgoing content leaves fast and the incoming one waits for the glass to make
    /// room, so pill and note text are never on screen together.
    private static func fade(delay: Double) -> AnyTransition {
        .asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.16).delay(delay)),
                    removal: .opacity.animation(.easeIn(duration: 0.08)))
    }
}

/// Glass only depends on its size, so level ticks do not redraw it. One shape for both
/// states: a 40 pt tall rect with 20 pt corners is already the capsule, so the morph is a
/// plain size animation.
private struct GlassPlate: View, Equatable {
    static let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
    var size: CGSize

    var body: some View {
        Self.shape
            .fill(.clear)
            .glassEffect(.regular, in: Self.shape)
            .frame(width: size.width - 2 * BubbleController.margin, height: size.height - 2 * BubbleController.margin)
    }
}

/// Stacked micro-bars on the collapsed pill: top row = `You` (mic), bottom row = `Call` (others),
/// so neither track can mask silence on the other.
private struct DualPillMeters: View {
    var micLevel: Float
    var callLevel: Float
    var hasIssue: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            barRow(level: micLevel, count: 7)
            barRow(level: callLevel, count: 7)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Mic and call audio levels")
        .accessibilityValue("Mic \(Int(micLevel * 100)) percent, Call \(Int(callLevel * 100)) percent")
        .onAppear { model.recorder.visibleLevelMeters += 1 }
        .onDisappear { model.recorder.visibleLevelMeters = max(0, model.recorder.visibleLevelMeters - 1) }
    }

    private func barRow(level: Float, count: Int) -> some View {
        HStack(spacing: 2) {
            ForEach(0..<count, id: \.self) { index in
                let lit = Float(index) < level * Float(count)
                Capsule()
                    .fill(lit ? Theme.accent : (hasIssue ? Color.orange.opacity(0.32) : Theme.line))
                    .frame(width: 4, height: 5)
            }
        }
    }
}

private struct Pill: View {
    let controller: BubbleController
    @Environment(AppModel.self) private var model

    var body: some View {
        let recorder = model.recorder
        HStack(spacing: 8) {
            HStack(spacing: 9) {
                DualPillMeters(
                    micLevel: recorder.micLevel,
                    callLevel: recorder.systemLevel,
                    hasIssue: recorder.activeAudioIssue != nil
                )
                .frame(width: 42, height: 14)

                Text(TimeFormat.timer(recorder.elapsed))
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(Theme.fg)
                    .lineLimit(1)
                    .fixedSize()

                if let flash = controller.state.pinnedConfirmation {
                    Text(flash)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .lineLimit(1)
                } else if let toast = recorder.deviceSwitchToast {
                    HStack(spacing: 3.5) {
                        Image(systemName: recorder.isBluetoothInput ? "airpodspro" : "mic.fill")
                            .font(.system(size: 10, weight: .semibold))
                        Text(toast)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(Theme.accent)
                } else if let issue = recorder.activeAudioIssue {
                    HStack(spacing: 3.5) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10, weight: .semibold))
                        Text(issue.pillLabel)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.orange)
                } else if !recorder.notes.isEmpty {
                    Text("\(recorder.notes.count) note\(recorder.notes.count == 1 ? "" : "s")")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.fg2)
                        .fixedSize()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { controller.openNoteField() }
            Button(action: controller.pinMoment) {
                Image(systemName: controller.state.pinnedConfirmation != nil ? "pin.fill" : "pin")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(controller.state.pinnedConfirmation != nil ? Theme.accent : Theme.fg2)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("Mark this moment (\(KeyboardShortcuts.Name.markMoment.hint))")
            .accessibilityLabel("Mark this moment")
            Button(action: controller.hidePill) {
                Image(systemName: "eye.slash")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.fg2)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("Hide the pill (\(KeyboardShortcuts.Name.toggleBubble.hint)). Bring it back with the same shortcut or from the menu bar.")
            .accessibilityLabel("Hide recording pill")
            Button(action: controller.stopRecording) {
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(.white)
                    .frame(width: 9, height: 9)
                    .frame(width: 24, height: 24)
                    .background(Theme.recordingFill, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Stop recording (\(KeyboardShortcuts.Name.toggleRecording.hint))")
            .accessibilityLabel("Stop recording")
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(width: BubbleController.pillCard.width, height: BubbleController.pillCard.height)
    }
}

/// The pill while the call has ended: a countdown to the automatic stop and a way out.
private struct CallEndedPill: View {
    let controller: BubbleController
    let seconds: Int

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Call ended")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.fg)
                Text("Stops in \(seconds) s")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(Theme.fg2)
                    .contentTransition(.numericText(countsDown: true))
            }
            .fixedSize()
            Spacer(minLength: 0)
            // The capsule is part of the label, so the whole tinted pill is clickable (a plain
            // button styled from outside was only clickable on its text).
            Button(action: controller.keepRecording) {
                Text("Keep recording")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Theme.mark, in: Capsule())
                    .contentShape(Capsule())
            }
                .buttonStyle(.plain)
                .accessibilityHint("Stops ReMeet from ending this recording automatically")
            Button(action: controller.stopRecording) {
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(.white)
                    .frame(width: 9, height: 9)
                    .frame(width: 24, height: 24)
                    .background(Theme.recordingFill, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Stop now")
            .accessibilityLabel("Stop recording now")
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(width: BubbleController.pillCard.width, height: BubbleController.pillCard.height)
        .animation(.default, value: seconds)
    }
}

private struct NoteField: View {
    let controller: BubbleController
    @Bindable var state: BubbleState
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(Theme.recording).frame(width: 7, height: 7)
                Text("Note at \(TimeFormat.clock(state.openedAt))")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.fg2)
                Spacer()
                Text(TimeFormat.timer(model.recorder.elapsed))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.fg3)
                Button(action: controller.stopRecording) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.white)
                        .frame(width: 8, height: 8)
                        .frame(width: 22, height: 22)
                        .background(Theme.recordingFill, in: Circle())
                }
                .buttonStyle(.plain)
                .help("Stop recording (\(KeyboardShortcuts.Name.toggleRecording.hint))")
                .accessibilityLabel("Stop recording")
            }

            if let issue = model.recorder.activeAudioIssue {
                LiveAudioIssueBanner(
                    issue: issue,
                    compact: true,
                    onAction: { model.recorder.performAudioIssueAction($0) },
                    onDismiss: { model.recorder.dismissAudioIssue(issue.kind) }
                )
            }

            TextField("Type a note, or press Return for a bookmark", text: $state.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(1...3)
                .focused($focused)
                .onKeyPress(.return, phases: .down) { press in
                    controller.submit(command: press.modifiers.contains(.command))
                    return .handled
                }
                .onKeyPress(.escape) {
                    controller.cancel()
                    return .handled
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Theme.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 4) {
                ForEach(model.recorder.notes.suffix(2).reversed()) { note in
                    HStack(spacing: 8) {
                        Text(TimeFormat.clock(note.t))
                            .font(Fonts.monoSmall)
                            .foregroundStyle(Theme.fg3)
                        Text(note.displayText)
                            .font(.system(size: 12))
                            .foregroundStyle(note.kind == .bookmark ? Theme.fg2 : Theme.fg)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if note.kind == .action {
                            NoteKindBadge(text: "Action")
                        } else if note.kind == .bookmark {
                            Image(systemName: "bookmark.fill").font(.system(size: 10)).foregroundStyle(Theme.accent)
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)

            HStack(spacing: 14) {
                ShortcutHint("↩ Save")
                ShortcutHint("⌘↩ Action item")
                ShortcutHint("esc Close")
            }
        }
        .padding(14)
        .frame(width: BubbleController.noteCard.width, height: BubbleController.noteCard.height)
        .onAppear { focused = true }
        .onChange(of: state.focusRequest) { focused = true }
    }
}

struct NoteKindBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Theme.mark, in: Capsule())
    }
}
