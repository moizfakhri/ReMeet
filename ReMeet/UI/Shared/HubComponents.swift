import AVFoundation
import AppKit
import Observation
import ReMeetKit
import SwiftUI

/// High-contrast solid Fern primary button (`5.7:1` white-on-green in both Light and Dark mode).
struct AccentCapsuleButton: View {
    let title: String
    var systemImage: String? = nil
    var small = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: small ? 11 : 12, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: small ? 12 : 13, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, small ? 10 : 13)
            .padding(.vertical, small ? 5 : 6.5)
            .background(Theme.accentFill, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Accessible circular avatar using OKLCH hues derived deterministically from a person's name.
struct PersonAvatarView: View {
    let initials: String
    let hueIndex: Int
    var size: CGFloat = 32
    var hasVoiceprint = false

    @Environment(\.colorScheme) private var colorScheme

    init(profile: PersonProfile, size: CGFloat = 32, hasVoiceprint: Bool = false) {
        self.initials = profile.initials
        self.hueIndex = profile.hueIndex
        self.size = size
        self.hasVoiceprint = hasVoiceprint
    }

    init(name: String, size: CGFloat = 32, hasVoiceprint: Bool = false) {
        self.initials = PersonProfile.initials(for: name)
        self.hueIndex = PersonProfile.stableHueIndex(for: name)
        self.size = size
        self.hasVoiceprint = hasVoiceprint
    }

    var body: some View {
        let pair = PersonAvatarPalette.colors(index: hueIndex, isDark: colorScheme == .dark)
        let bg = Color(sRGBLinear: pair.background)
        let fg = Color(sRGBLinear: pair.foreground)
        ZStack(alignment: .bottomTrailing) {
            Circle()
                .fill(bg)
                .overlay(Circle().stroke(fg.opacity(0.22), lineWidth: 1))
                .frame(width: size, height: size)
                .overlay {
                    Text(initials)
                        .font(.system(size: round(size * 0.39), weight: .semibold, design: .rounded))
                        .foregroundStyle(fg)
                        .lineLimit(1)
                }
            if hasVoiceprint {
                Circle()
                    .fill(Theme.surface)
                    .frame(width: max(12, size * 0.38), height: max(12, size * 0.38))
                    .overlay {
                        Image(systemName: "waveform")
                            .font(.system(size: max(7.5, size * 0.22), weight: .bold))
                            .foregroundStyle(Theme.accent)
                    }
                    .offset(x: 2, y: 2)
                    .help("Voiceprint saved — recognized automatically in recordings")
            }
        }
    }
}

extension Color {
    fileprivate init(sRGBLinear c: RGBA) {
        self.init(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a)
    }

    static func speakerHue(_ hueIndex: Int, isDark: Bool) -> Color {
        let pair = PersonAvatarPalette.colors(index: hueIndex, isDark: isDark)
        return Color(sRGBLinear: pair.foreground)
    }
}

/// Semantic category badge for Key Moment tile cards.
struct MomentKindPill: View {
    let kind: KeyMoment.Kind
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let style = colors(isDark: colorScheme == .dark)
        HStack(spacing: 4) {
            Image(systemName: kind.symbol)
                .font(.system(size: 9.5, weight: .semibold))
            Text(kind.label)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(style.fg)
        .padding(.horizontal, 7.5)
        .padding(.vertical, 2.5)
        .background(style.bg, in: Capsule())
        .overlay(Capsule().stroke(style.fg.opacity(0.20)))
    }

    private func colors(isDark: Bool) -> (bg: Color, fg: Color) {
        let hue: Double = switch kind {
        case .pinned: 55       // warm amber
        case .decision: 150    // Fern green
        case .commitment: 235  // crisp cobalt
        case .takeaway: 295    // plum/violet
        case .question: 28     // terracotta
        }
        if isDark {
            return (
                bg: Color(sRGBLinear: OKLCH(0.27, 0.055, hue).srgb),
                fg: Color(sRGBLinear: OKLCH(0.84, 0.095, hue).srgb)
            )
        } else {
            return (
                bg: Color(sRGBLinear: OKLCH(0.94, 0.035, hue).srgb),
                fg: Color(sRGBLinear: OKLCH(0.36, 0.095, hue).srgb)
            )
        }
    }
}

/// Plays a standalone audio snippet (`audio.m4a`) from `[start, end)` for Moment cards outside a meeting detail window.
@MainActor
@Observable
final class ExcerptAudioPlayer {
    private(set) var playingID: String?
    private let player = AVPlayer()
    private var token = 0

    func toggle(id: String, audioURL: URL, start: Double, end: Double) {
        if playingID == id {
            stop()
            return
        }
        guard FileManager.default.fileExists(atPath: audioURL.path) else { return }
        token += 1
        let mine = token
        playingID = id
        let duration = max(1.0, end - start)
        player.replaceCurrentItem(with: AVPlayerItem(url: audioURL))
        let target = CMTime(seconds: max(0, start), preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            guard mine == self.token else { return }
            self.player.play()
            try? await Task.sleep(for: .seconds(duration))
            guard mine == self.token else { return }
            self.stop()
        }
    }

    func stop() {
        token += 1
        player.pause()
        playingID = nil
    }
}

/// Interactive row for cross-meeting promises in People, Schedule Prep Briefs, and Commitments Radar.
struct CommitmentRowView: View {
    let item: CommitmentItem
    var showOwner = true
    var showMeeting = true
    var availableReminderLists: [ReminderListInfo] = []
    var remindersConnected = false
    let onToggle: (Bool) -> Void
    let onOpenMeeting: () -> Void
    var onDismiss: (() -> Void)? = nil
    var onSendToReminders: ((String?) -> Void)? = nil
    var onUnlinkReminder: ((Bool) -> Void)? = nil
    @State private var hovering = false

    var body: some View {
        let done = item.actionItem.done
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Toggle("", isOn: Binding(get: { done }, set: onToggle))
                .toggleStyle(.checkbox)
                .labelsHidden()

            VStack(alignment: .leading, spacing: 3) {
                Text(item.actionItem.task)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(done ? Theme.fg3 : Theme.fg)
                    .strikethrough(done, color: Theme.fg3)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    if showOwner {
                        Text(item.ownerLabel)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(item.direction == .mine ? Theme.accent : Theme.fg2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(item.direction == .mine ? Theme.mark : Theme.bg, in: Capsule())
                    }
                    if let due = item.actionItem.due, !due.isEmpty {
                        Text("Due \(due)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.fg2)
                    }
                    if showMeeting {
                        Button(action: onOpenMeeting) {
                            HStack(spacing: 3) {
                                Text(item.meetingTitle)
                                    .lineLimit(1)
                                if let t = item.actionItem.t {
                                    Text("· \(TimeFormat.clock(t))")
                                        .monospacedDigit()
                                }
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 9, weight: .semibold))
                            }
                            .font(.system(size: 11.5))
                            .foregroundStyle(hovering ? Theme.accent : Theme.fg3)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Spacer(minLength: 4)

            if let onSendToReminders {
                remindersControl(onSend: onSendToReminders)
            }

            if let onDismiss, hovering {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.fg3)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Dismiss action item")
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(Theme.bg.opacity(0.65), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line))
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private func remindersControl(onSend: @escaping (String?) -> Void) -> some View {
        if let rid = item.actionItem.reminderID, !rid.isEmpty {
            let listLabel = item.actionItem.reminderListName ?? "Reminders"
            Menu {
                if !availableReminderLists.isEmpty {
                    Section("Move to list") {
                        ForEach(availableReminderLists) { list in
                            Button {
                                onSend(list.id)
                            } label: {
                                if list.id == item.actionItem.reminderListID {
                                    Label(list.title, systemImage: "checkmark")
                                } else {
                                    Text(list.title)
                                }
                            }
                        }
                    }
                }
                Divider()
                Button("Open Apple Reminders") {
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.reminders") {
                        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                    }
                }
                if let onUnlinkReminder {
                    Button("Unlink from ReMeet") { onUnlinkReminder(false) }
                    Button("Delete from Apple Reminders", role: .destructive) { onUnlinkReminder(true) }
                }
            } label: {
                HStack(spacing: 3.5) {
                    Image(systemName: "checklist")
                        .font(.system(size: 9.5, weight: .semibold))
                    Text(listLabel)
                        .font(.system(size: 10.5, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 7)
                .padding(.vertical, 2.5)
                .background(Theme.mark, in: Capsule())
                .overlay(Capsule().stroke(Theme.accent.opacity(0.25)))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Synced to Apple Reminders list \u{201C}\(listLabel)\u{201D} — click to move or manage")
        } else if hovering || !remindersConnected {
            Menu {
                Button("Send to default list") { onSend(nil) }
                if !availableReminderLists.isEmpty {
                    Divider()
                    Section("Choose list") {
                        ForEach(availableReminderLists) { list in
                            Button(list.title) { onSend(list.id) }
                        }
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "checklist")
                        .font(.system(size: 10, weight: .medium))
                    Text("Remind")
                        .font(.system(size: 10.5, weight: .medium))
                }
                .foregroundStyle(Theme.fg2)
                .padding(.horizontal, 6.5)
                .padding(.vertical, 2)
                .background(Theme.surface, in: Capsule())
                .overlay(Capsule().stroke(Theme.line))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
            .help("Send this action item to Apple Reminders")
        }
    }
}

/// Wrapping horizontal layout that never forces a narrow pane wider than its proposed width.
struct WrappingFlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let childProposal = ProposedViewSize(width: maxWidth.isFinite ? maxWidth : nil, height: nil)
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(childProposal)
            if maxWidth.isFinite, x + size.width > maxWidth, x > 0 {
                usedWidth = max(usedWidth, x - spacing)
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
        usedWidth = max(usedWidth, max(0, x - spacing))
        let totalHeight = subviews.isEmpty ? 0 : (y + rowHeight)
        return CGSize(width: maxWidth.isFinite ? maxWidth : usedWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxLineWidth = max(1, bounds.width)
        let childProposal = ProposedViewSize(width: maxLineWidth, height: nil)
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let measured = subview.sizeThatFits(childProposal)
            let clampedWidth = min(measured.width, maxLineWidth)
            if x + clampedWidth > bounds.maxX + 0.5, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y),
                          proposal: ProposedViewSize(width: clampedWidth, height: measured.height))
            rowHeight = max(rowHeight, measured.height)
            x += clampedWidth + spacing
        }
    }
}

/// Width-aware scroll container that scales padding & content width to the current pane so detail
/// views never clip horizontally in narrow windows or side-by-side inspector layouts.
struct ResponsiveDocumentScroll<Content: View>: View {
    var maxWidth: CGFloat = 660
    var topPadding: CGFloat = 24
    var bottomPadding: CGFloat = 48
    @ViewBuilder let content: (_ availableWidth: CGFloat) -> Content

    var body: some View {
        GeometryReader { geo in
            let available = max(1, geo.size.width)
            let horizontalPadding: CGFloat = available < 460 ? 16 : (available < 600 ? 24 : 36)
            let innerWidth = min(maxWidth, max(200, available - horizontalPadding * 2))
            ScrollView {
                content(innerWidth)
                    .frame(width: innerWidth, alignment: .leading)
                    .padding(.top, topPadding)
                    .padding(.bottom, bottomPadding)
                    .frame(width: available, alignment: .center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.surface)
        }
    }
}
