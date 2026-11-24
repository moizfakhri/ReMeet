import AppKit
import KeyboardShortcuts
import ReMeetKit
import SwiftUI

/// "Record this meeting?" A small non-activating panel in the top-right corner, shown when a
/// meeting app starts using the mic (named after the calendar event it belongs to, if any)
/// or a minute before a calendar meeting. It never records on its own; it goes away when the
/// app stops using the mic, after a while, or on Not now.
@MainActor
final class MeetingPromptController {
    private var panel: BubblePanel?
    private var hideWork: DispatchWorkItem?
    private(set) var app: MeetingApp?
    private(set) var event: CalendarMeeting?
    var onRecord: ((MeetingApp?, CalendarMeeting?) -> Void)?
    var onDismiss: ((MeetingApp?, CalendarMeeting?) -> Void)?

    /// A meeting app took the mic.
    func show(_ app: MeetingApp, event: CalendarMeeting? = nil) {
        present(app: app, event: event, hideAfter: 60)
    }

    /// A calendar meeting is about to start. Stays up through a typical lobby wait.
    func remind(_ event: CalendarMeeting) {
        present(app: app, event: event, hideAfter: max(120, event.start.timeIntervalSinceNow + 10 * 60))
    }

    private func present(app: MeetingApp?, event: CalendarMeeting?, hideAfter: TimeInterval) {
        self.app = app
        self.event = event
        // Card plus clear margin, so the glass shadow is not cut off by the window edge.
        let margin = BubbleController.margin
        let size = CGSize(width: 340 + 2 * margin, height: 108 + 2 * margin)
        let visible = NSScreen.main?.visibleFrame ?? .zero
        let frame = BubbleGeometry.defaultFrame(size: size, visibleFrame: visible, margin: 16 - margin)
        let panel = self.panel ?? BubblePanel(contentRect: frame)
        panel.setFrame(frame, display: false)
        panel.contentView = NSHostingView(rootView: PromptView(app: app, event: event, record: { [weak self] in
            self?.hide()
            self?.onRecord?(app, event)
        }, dismiss: { [weak self] in
            self?.hide()
            self?.onDismiss?(app, event)
        }).tint(Theme.accentFill))
        self.panel = panel
        panel.orderFrontRegardless()
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + hideAfter, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        panel?.orderOut(nil)
        app = nil
        event = nil
    }

    var isVisible: Bool { panel?.isVisible ?? false }
}

private struct PromptView: View {
    let app: MeetingApp?
    let event: CalendarMeeting?
    let record: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: app == nil ? "calendar" : "waveform").foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    if app == nil, event != nil {
                        TimelineView(.periodic(from: .now, by: 15)) { context in
                            Text(headline(at: context.date))
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.fg)
                                .lineLimit(1)
                        }
                    } else {
                        Text(headline(at: Date()))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.fg)
                            .lineLimit(1)
                    }
                    if let detail {
                        Text(detail)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.fg2)
                            .lineLimit(1)
                    }
                }
            }
            HStack(spacing: 8) {
                Button(action: record) {
                    HStack(spacing: 6) {
                        Text("Record this meeting")
                        Text(KeyboardShortcuts.Name.toggleRecording.hint).font(.system(size: 11)).opacity(0.8)
                    }
                    .fixedSize()
                }
                .buttonStyle(.glassProminent)
                if let event {
                    Button("Brief") {
                        dismiss()
                        AppModel.shared.openSchedule(selecting: event.id)
                    }
                    .buttonStyle(.glass)
                }
                Button("Not now", action: dismiss)
                    .buttonStyle(.glass)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.clear)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .padding(BubbleController.margin)
    }

    /// Mic: "Teams is using your microphone". Calendar: "Weekly sync starts in 1 min".
    private func headline(at now: Date) -> String {
        if let app { return "\(app.name) is using your microphone" }
        guard let event else { return "Record this meeting?" }
        let name = event.title.isEmpty ? "Your meeting" : event.title
        let delta = event.start.timeIntervalSince(now)
        let minutes = Int((delta / 60).rounded())
        if minutes >= 1 { return "\(name) starts in \(minutes) min" }
        let elapsed = Int((-delta / 60).rounded(.down))
        if elapsed >= 2 { return "\(name) started \(elapsed) min ago" }
        return "\(name) is starting"
    }

    private var detail: String? {
        var parts: [String] = []
        if let event {
            if app != nil, !event.title.isEmpty { parts.append(event.title) }
            if let service = event.callService { parts.append(service) }
            let people = event.attendeeNames.count
            if people > 0 { parts.append(people == 1 ? "with \(event.attendeeNames[0])" : "\(people + 1) people") }
        }
        let micName = CoreAudioUtil.activeMeetingAppInputDevice()?.device.name
            ?? AppModel.shared.recorder.inputDevice?.name
        if let micName, !micName.isEmpty {
            parts.append(micName)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
