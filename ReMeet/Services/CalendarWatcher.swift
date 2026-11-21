import AppKit
import EventKit
import Foundation
import ReMeetKit

/// Reads the next day of events from macOS Calendar (which includes Google, Outlook/Exchange
/// and iCloud calendars added in System Settings > Internet Accounts) and fires one reminder
/// a minute before each meeting. No polling: one timer for the next reminder, rescheduled
/// when the calendar changes or the Mac wakes.
@MainActor
final class CalendarWatcher {
    var onReminder: ((CalendarMeeting) -> Void)?
    private(set) var events: [CalendarMeeting] = []
    private let store = EKEventStore()
    private var reminded: Set<String> = []
    private var timer: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    /// Self-tests set this to feed events without touching the real calendar.
    var source: (() -> [CalendarMeeting])?

    static var hasAccess: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }
    static var notDetermined: Bool { EKEventStore.authorizationStatus(for: .event) == .notDetermined }
    static var accessDenied: Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        return status == .denied || status == .restricted || status == .writeOnly
    }

    /// Asks for Calendar access (once; macOS remembers the answer). Returns whether granted.
    func requestAccess() async -> Bool {
        if Self.hasAccess { return true }
        return (try? await store.requestFullAccessToEvents()) ?? false
    }

    func start() {
        stop()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        })
        reload()
    }

    private var reloadTask: Task<Void, Never>?

    func stop() {
        timer?.cancel()
        timer = nil
        reloadTask?.cancel()
        reloadTask = nil
        observers.forEach {
            NotificationCenter.default.removeObserver($0)
            NSWorkspace.shared.notificationCenter.removeObserver($0)
        }
        observers = []
        events = []
    }

    /// The calendar meeting a call detected now belongs to, if any.
    func eventForCall(at date: Date = Date()) -> CalendarMeeting? {
        MeetingReminder.event(forCallAt: date, in: events)
    }

    /// The user is already recording (or chose Record from the mic prompt): no reminder for it.
    func markReminded(_ id: String) {
        reminded.insert(id)
        schedule()
    }

    func reload() {
        reloadTask?.cancel()
        if let source {
            events = source()
            schedule()
            return
        }
        guard Self.hasAccess else {
            events = []
            schedule()
            return
        }
        // EventKit fetches can take 50–300 ms; keep them off the main thread at launch and
        // on background iCloud/Google calendar sync notifications.
        let store = self.store
        reloadTask = Task { [weak self] in
            let fetched = await Task.detached(priority: .utility) { () -> [CalendarMeeting] in
                let now = Date()
                let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-3600),
                                                         end: now.addingTimeInterval(24 * 3600), calendars: nil)
                return store.events(matching: predicate).map(Self.meeting)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.events = fetched
            self.schedule()
        }
    }

    private func schedule() {
        timer?.cancel()
        let now = Date()
        // Re-read at least every 6 hours, so tomorrow's events get scheduled without polling.
        let refresh = now.addingTimeInterval(6 * 3600)
        let next = MeetingReminder.next(events, now: now, reminded: reminded)
        let fireAt = min(next?.fireAt ?? refresh, refresh)
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, fireAt.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self else { return }
            if let next, fireAt == next.fireAt {
                self.reminded.insert(next.event.id)
                self.onReminder?(next.event)
                self.schedule()
            } else {
                self.reload()
            }
        }
    }

    private nonisolated static func meeting(_ event: EKEvent) -> CalendarMeeting {
        let others = (event.attendees ?? []).filter { !$0.isCurrentUser }
        let me = event.attendees?.first { $0.isCurrentUser }
        let link = [event.url?.absoluteString, event.location, event.notes].compactMap { $0 }.joined(separator: "\n")
        return CalendarMeeting(
            id: (event.calendarItemExternalIdentifier ?? event.eventIdentifier ?? UUID().uuidString)
                + "@\(event.startDate.timeIntervalSince1970)",
            title: (event.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            start: event.startDate, end: event.endDate, isAllDay: event.isAllDay,
            attendeeNames: others.compactMap { $0.name ?? $0.url.absoluteString.replacingOccurrences(of: "mailto:", with: "") },
            declined: me?.participantStatus == .declined,
            linkText: link)
    }
}
