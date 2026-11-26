import Foundation

/// One invited participant on a calendar event.
public struct CalendarAttendee: Codable, Equatable, Sendable, Hashable, Identifiable {
    public enum Status: String, Codable, Sendable, Hashable {
        case accepted
        case tentative
        case declined
        case pending
    }

    public var name: String
    public var email: String?
    public var isOrganizer: Bool
    public var status: Status

    public var id: String {
        if let email = email?.lowercased(), !email.isEmpty { return email }
        return name.lowercased()
    }

    public init(name: String, email: String? = nil, isOrganizer: Bool = false, status: Status = .accepted) {
        let cleanedEmail = email?
            .replacingOccurrences(of: "mailto:", with: "", options: [.caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedEmail = (cleanedEmail?.isEmpty == false) ? cleanedEmail : nil
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty || trimmedName.contains("@"), let normalizedEmail {
            self.name = Self.humanizedName(fromEmail: normalizedEmail)
        } else {
            let normalized = PersonName.parse(trimmedName).canonicalDisplayName
            self.name = normalized.isEmpty ? trimmedName : normalized
        }
        self.email = normalizedEmail
        self.isOrganizer = isOrganizer
        self.status = status
    }

    /// Turns `priya.patel@acme.io` into `"Priya Patel"` when the calendar invite has no display name.
    public static func humanizedName(fromEmail email: String) -> String {
        let local = email.split(separator: "@").first.map(String.init) ?? email
        let stripped = local.split(separator: "+").first.map(String.init) ?? local
        let parts = stripped
            .split { $0 == "." || $0 == "_" || $0 == "-" }
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return email }
        return parts.map { part in
            guard let first = part.first else { return part }
            return String(first).uppercased() + part.dropFirst().lowercased()
        }.joined(separator: " ")
    }

    private static let personalDomains: Set<String> = [
        "gmail.com", "googlemail.com", "icloud.com", "me.com", "mac.com",
        "outlook.com", "hotmail.com", "live.com", "msn.com", "yahoo.com",
        "proton.me", "protonmail.com", "fastmail.com", "hey.com", "aol.com",
        "calendar.google.com", "group.calendar.google.com",
    ]

    /// Company / domain hint from a work email (`priya@stripe.com` -> `"Stripe"`), nil for personal mail.
    public var inferredOrganization: String? {
        guard let email = email?.lowercased(),
              let at = email.lastIndex(of: "@") else { return nil }
        let domain = String(email[email.index(after: at)...])
        guard !domain.isEmpty, !Self.personalDomains.contains(domain),
              !domain.hasSuffix(".calendar.google.com") else { return nil }
        let labels = domain.split(separator: ".").map(String.init)
        guard let root = labels.dropLast().last ?? labels.first, root.count >= 2 else { return nil }
        if root.count <= 3 { return root.uppercased() }
        return root.prefix(1).uppercased() + root.dropFirst()
    }
}

/// A calendar event from Apple Calendar (EventKit) or a subscribed Google/iCal `.ics` feed.
public struct CalendarMeeting: Codable, Equatable, Sendable, Identifiable, Hashable {
    public enum SourceKind: String, Codable, Sendable, Hashable {
        case appleCalendar
        case icsFeed
    }

    public var id: String
    public var uid: String?
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    /// Other people invited (not counting you).
    public var attendeeNames: [String]
    /// Structured attendee list with emails and RSVP statuses.
    public var attendees: [CalendarAttendee]
    /// You declined it.
    public var declined: Bool
    /// URL, location and notes, searched for a video-call link.
    public var linkText: String
    /// Clean description/agenda text for display in the Schedule view.
    public var notes: String
    /// Calendar source label, e.g. "Work (Google)" or "Google Calendar (.ics)".
    public var calendarName: String?
    public var sourceKind: SourceKind
    public var organizerName: String?

    public init(id: String,
                uid: String? = nil,
                title: String,
                start: Date,
                end: Date,
                isAllDay: Bool = false,
                attendeeNames: [String] = [],
                attendees: [CalendarAttendee]? = nil,
                declined: Bool = false,
                linkText: String = "",
                notes: String = "",
                calendarName: String? = nil,
                sourceKind: SourceKind = .appleCalendar,
                organizerName: String? = nil) {
        self.id = id
        self.uid = uid
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        if let attendees {
            self.attendees = attendees
            if attendeeNames.isEmpty {
                self.attendeeNames = attendees
                    .filter { $0.status != .declined }
                    .map(\.name)
                    .filter { !$0.isEmpty }
            } else {
                self.attendeeNames = attendeeNames
            }
        } else {
            self.attendeeNames = attendeeNames
            self.attendees = attendeeNames.map { raw in
                if raw.contains("@") {
                    return CalendarAttendee(name: "", email: raw)
                }
                return CalendarAttendee(name: raw)
            }
        }
        self.declined = declined
        self.linkText = linkText
        self.notes = notes
        self.calendarName = calendarName
        self.sourceKind = sourceKind
        self.organizerName = organizerName
    }

    /// The call service in the event's link or notes, if any ("Teams", "Zoom", "Google Meet", ...).
    public var callService: String? {
        MeetingReminder.callService(in: linkText)
            ?? MeetingReminder.callService(in: notes)
            ?? MeetingReminder.locationPlatformHint(in: linkText)
    }

    /// Direct clickable meeting URL parsed from the event's URL, location, or description.
    public var joinURL: URL? {
        MeetingReminder.joinURL(in: linkText) ?? MeetingReminder.joinURL(in: notes)
    }

    /// Normalized title key so recurring instances ("Weekly Sync - Nov 24") group as one series.
    public var seriesKey: String { MeetingReminder.seriesKey(for: title) }

    /// Suggested call speaker count (non-declined other participants), when 1...8.
    public var expectedCallSpeakersHint: Int? {
        let active = attendees.filter { $0.status != .declined }.count
        let count = active > 0 ? active : attendeeNames.count
        return (1...8).contains(count) ? count : nil
    }
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
        !event.isAllDay && !event.declined && (!event.attendeeNames.isEmpty || !event.attendees.isEmpty || event.callService != nil)
    }

    /// True only when an event is on a recognized online call platform (Zoom, Teams, Meet, Webex, etc.),
    /// filtering out classes, lectures, study blocks, and physical-only calendar entries from Schedule.
    public static func hasOnlineMeetingPlatform(_ event: CalendarMeeting) -> Bool {
        !event.isAllDay && !event.declined && event.callService != nil
    }

    /// Next online-platform meeting eligible for a 1-minute join/record reminder.
    public static func nextOnlineMeeting(_ events: [CalendarMeeting], now: Date, reminded: Set<String>)
        -> (event: CalendarMeeting, fireAt: Date)? {
        events
            .filter { hasOnlineMeetingPlatform($0) && !reminded.contains($0.id) && $0.start.timeIntervalSince(now) > -lead }
            .min { $0.start < $1.start }
            .map { ($0, max(now, $0.start.addingTimeInterval(-lead))) }
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

    /// Matches a recorded meeting (`startTime`, `title`) to a calendar event even retroactively.
    public static func matchingEvent(startTime: Date, title: String, calendarEventID: String? = nil,
                                     in events: [CalendarMeeting]) -> CalendarMeeting? {
        if let calendarEventID, let exact = events.first(where: { $0.id == calendarEventID }) {
            return exact
        }
        let candidates = events.filter {
            !$0.isAllDay && abs($0.start.timeIntervalSince(startTime)) <= 30 * 60
        }
        let targetKey = seriesKey(for: title)
        if !targetKey.isEmpty, targetKey != "untitled meeting", targetKey != "meeting" {
            if let titled = candidates.first(where: { seriesKey(for: $0.title) == targetKey }) {
                return titled
            }
        }
        return candidates
            .filter { isMeeting($0) && abs($0.start.timeIntervalSince(startTime)) <= 15 * 60 }
            .min { abs($0.start.timeIntervalSince(startTime)) < abs($1.start.timeIntervalSince(startTime)) }
    }

    private static let servicePatterns: [(name: String, substrings: [String])] = [
        ("Teams", ["teams.microsoft.com/l/meetup-join", "teams.live.com/meet", "teams.microsoft.com/meet", "teams.microsoft.com/dl/launcher"]),
        ("Zoom", ["zoom.us/j/", "zoom.us/my/", "zoomgov.com/j/", "zoom.us/w/", "zoom.us/s/", "zoommtg://"]),
        ("Google Meet", ["meet.google.com/"]),
        ("Webex", ["webex.com/meet", "webex.com/join", ".webex.com/"]),
        ("FaceTime", ["facetime.apple.com/join"]),
        ("Slack", ["app.slack.com/huddle", "slack.com/huddle"]),
        ("Discord", ["discord.gg/", "discord.com/channels/"]),
        ("Amazon Chime", ["chime.aws/"]),
        ("GoTo Meeting", ["gotomeet.me/", "gotomeeting.com/join", "meet.goto.com/"]),
        ("Whereby", ["whereby.com/"]),
        ("Jitsi", ["meet.jit.si/"]),
        ("RingCentral", ["meetings.ringcentral.com/", "v.ringcentral.com/"]),
        ("BlueJeans", ["bluejeans.com/"]),
        ("Gather", ["app.gather.town/"]),
    ]

    /// Recognizes explicit platform labels placed in the location/link field (e.g. "Microsoft Teams Meeting")
    /// when a calendar server strips the underlying URL. Not run against free-form event titles or notes.
    public static func locationPlatformHint(in linkText: String) -> String? {
        let lower = linkText.lowercased()
        let hints: [(name: String, phrases: [String])] = [
            ("Teams", ["microsoft teams meeting", "teams meeting"]),
            ("Zoom", ["zoom meeting"]),
            ("Google Meet", ["google meet"]),
            ("Webex", ["webex meeting"]),
        ]
        return hints.first { $0.phrases.contains(where: lower.contains) }?.name
    }

    /// Recognizes the join links of the common call services.
    public static func callService(in text: String) -> String? {
        let lower = text.lowercased()
        return servicePatterns.first { $0.substrings.contains(where: lower.contains) }?.name
    }

    /// Extracts the first concrete video-call join URL from event location/notes/URL text.
    public static func joinURL(in text: String) -> URL? {
        guard !text.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = detector.matches(in: text, options: [], range: range)
        var fallback: URL?
        for match in matches {
            guard let url = match.url,
                  let scheme = url.scheme?.lowercased(),
                  scheme == "https" || scheme == "http" || scheme == "zoommtg" else { continue }
            let abs = url.absoluteString.lowercased()
            if servicePatterns.contains(where: { $0.substrings.contains(where: abs.contains) }) {
                return url
            }
            if fallback == nil { fallback = url }
        }
        return nil
    }

    /// Normalizes a meeting title so recurring instances match across weeks.
    public static func seriesKey(for title: String) -> String {
        let lower = title.lowercased()
            .replacingOccurrences(of: #"\b\d{4}-\d{2}-\d{2}\b"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\b(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\s+\d{1,2}(,?\s*\d{4})?\b"#,
                                  with: "", options: .regularExpression)
        let words = lower.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return words.joined(separator: " ")
    }

    /// Deduplicates events coming from both Apple Calendar (EventKit) and subscribed `.ics` feeds.
    public static func deduplicate(_ events: [CalendarMeeting]) -> [CalendarMeeting] {
        var result: [CalendarMeeting] = []
        var seenUIDStart: Set<String> = []
        var seenTitleStart: Set<String> = []
        // Prefer Apple Calendar entries first when identical (often carry native RSVP status),
        // or whichever entry has richer attendees/join URL.
        let ordered = events.sorted { a, b in
            if a.start != b.start { return a.start < b.start }
            let aScore = (a.attendees.count * 2) + (a.joinURL != nil ? 2 : 0) + (a.sourceKind == .appleCalendar ? 1 : 0)
            let bScore = (b.attendees.count * 2) + (b.joinURL != nil ? 2 : 0) + (b.sourceKind == .appleCalendar ? 1 : 0)
            return aScore > bScore
        }
        for event in ordered {
            let bucket = Int((event.start.timeIntervalSince1970 / 60).rounded())
            if let uid = event.uid?.lowercased(), !uid.isEmpty {
                let key = "\(uid)#\(bucket)"
                if seenUIDStart.contains(key) { continue }
                seenUIDStart.insert(key)
            }
            let titleKey = "\(seriesKey(for: event.title))#\(bucket)"
            if !event.title.isEmpty, seenTitleStart.contains(titleKey) { continue }
            if !event.title.isEmpty { seenTitleStart.insert(titleKey) }
            result.append(event)
        }
        return result.sorted { $0.start < $1.start }
    }
}
