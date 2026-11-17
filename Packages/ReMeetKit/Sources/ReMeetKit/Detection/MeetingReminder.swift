import Foundation

/// A calendar event as the reminder logic sees it (filled from EventKit by the app).
public struct CalendarMeeting: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    /// Other people invited (not counting you).
    public var attendeeNames: [String]
    /// You declined it.
    public var declined: Bool
    /// URL, location and notes, searched for a video-call link.
    public var linkText: String

    public init(id: String, title: String, start: Date, end: Date, isAllDay: Bool = false,
                attendeeNames: [String] = [], declined: Bool = false, linkText: String = "") {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.attendeeNames = attendeeNames
        self.declined = declined
        self.linkText = linkText
    }

    /// The call service in the event's link, if any ("Teams", "Zoom", ...).
    public var callService: String? { MeetingReminder.callService(in: linkText) }
}

/// When to say "starting soon: record it?", modelled on Granola and Notion: a reminder a
/// minute before a meeting that has other people or a call link, and a call detected on the
/// mic named after the calendar event it belongs to.
public enum MeetingReminder {
    /// How long before the start the reminder shows.
    public static let lead: TimeInterval = 60
    /// A call that starts up to this long after (or 5 min before) an event's start belongs to it.
    public static let joinWindow: TimeInterval = 15 * 60

    /// Worth a reminder: not all-day, not declined, and either someone else is invited or
    /// there is a call link (a solo "Zoom with Sam" block counts; "Focus time" does not).
    public static func isMeeting(_ event: CalendarMeeting) -> Bool {
        !event.isAllDay && !event.declined && (!event.attendeeNames.isEmpty || event.callService != nil)
    }

    /// The next reminder: the earliest meeting whose start is still ahead (or began less than a
    /// minute ago, so a reminder missed by a sleeping Mac still shows), not yet reminded.
    /// `fireAt` is `start - lead`, never earlier than `now`.
    public static func next(_ events: [CalendarMeeting], now: Date, reminded: Set<String>)
        -> (event: CalendarMeeting, fireAt: Date)? {
        events
            .filter { isMeeting($0) && !reminded.contains($0.id) && $0.start.timeIntervalSince(now) > -lead }
            .min { $0.start < $1.start }
            .map { ($0, max(now, $0.start.addingTimeInterval(-lead))) }
    }

    /// The calendar meeting a call starting `now` most likely belongs to: one starting within
    /// the next 5 minutes or that started up to 15 minutes ago, closest start first.
    public static func event(forCallAt now: Date, in events: [CalendarMeeting]) -> CalendarMeeting? {
        events
            .filter { isMeeting($0) && $0.start.timeIntervalSince(now) <= 5 * 60 && now.timeIntervalSince($0.start) <= joinWindow }
            .min { abs($0.start.timeIntervalSince(now)) < abs($1.start.timeIntervalSince(now)) }
    }

    /// Recognizes the join links of the common call services.
    public static func callService(in text: String) -> String? {
        let lower = text.lowercased()
        let services: [(String, [String])] = [
            ("Teams", ["teams.microsoft.com/l/meetup-join", "teams.live.com/meet", "teams.microsoft.com/meet"]),
            ("Zoom", ["zoom.us/j/", "zoom.us/my/", "zoomgov.com/j/"]),
            ("Google Meet", ["meet.google.com/"]),
            ("Webex", ["webex.com/meet", "webex.com/join", ".webex.com/"]),
            ("FaceTime", ["facetime.apple.com/join"]),
            ("Slack", ["app.slack.com/huddle"]),
        ]
        return services.first { $0.1.contains(where: lower.contains) }?.0
    }
}
