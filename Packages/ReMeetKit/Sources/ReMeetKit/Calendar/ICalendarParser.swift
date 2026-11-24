import Foundation

/// A subscribed iCal / Google Calendar `.ics` feed stored in `calendar-feeds.json`.
public struct ICSFeedSubscription: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var urlString: String
    public var isEnabled: Bool
    public var lastSyncedAt: Date?
    public var lastEventCount: Int
    public var lastError: String?

    public init(id: String = UUID().uuidString,
                name: String = "",
                urlString: String,
                isEnabled: Bool = true,
                lastSyncedAt: Date? = nil,
                lastEventCount: Int = 0,
                lastError: String? = nil) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.urlString = Self.normalizeURLString(urlString)
        self.isEnabled = isEnabled
        self.lastSyncedAt = lastSyncedAt
        self.lastEventCount = lastEventCount
        self.lastError = lastError
    }

    public var resolvedURL: URL? {
        URL(string: Self.normalizeURLString(urlString))
    }

    public static func normalizeURLString(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("webcal://") {
            return "https://" + trimmed.dropFirst("webcal://".count)
        }
        return trimmed
    }
}

public struct ICSFeedsFile: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public static func url(beside meetingsRoot: URL) -> URL {
        meetingsRoot.deletingLastPathComponent().appendingPathComponent("calendar-feeds.json")
    }

    public func load() -> [ICSFeedSubscription] {
        (try? JSONCoding.read([ICSFeedSubscription].self, from: url)) ?? []
    }

    public func save(_ feeds: [ICSFeedSubscription]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONCoding.write(feeds, to: url)
    }
}

/// Lightweight RFC 5545 `.ics` parser for Google Calendar, Outlook, Fastmail, and iCloud feeds.
/// Handles line unfolding, timezones (`Z` and `TZID`), Google Meet `X-GOOGLE-CONFERENCE`,
/// attendees, `STATUS:CANCELLED`, `EXDATE`, `RECURRENCE-ID` overrides, and common `RRULE`s.
public enum ICalendarParser {
    public struct ParsedFeed: Equatable, Sendable {
        public var calendarName: String?
        public var events: [CalendarMeeting]

        public init(calendarName: String?, events: [CalendarMeeting]) {
            self.calendarName = calendarName
            self.events = events
        }
    }

    private struct Property {
        var name: String
        var params: [String: String]
        var value: String
    }

    private struct RawEvent {
        var uid: String = UUID().uuidString
        var summary: String = ""
        var description: String = ""
        var location: String = ""
        var url: String = ""
        var conference: String = ""
        var status: String = "CONFIRMED"
        var start: Date?
        var end: Date?
        var isAllDay = false
        var timeZone: TimeZone = .current
        var rrule: String?
        var exdates: [Date] = []
        var recurrenceID: Date?
        var organizerName: String?
        var organizerEmail: String?
        var attendees: [RawAttendee] = []
    }

    private struct RawAttendee {
        var name: String
        var email: String?
        var partStat: String
        var isOrganizer: Bool
    }

    public static func parse(_ text: String,
                             windowStart: Date,
                             windowEnd: Date,
                             fallbackCalendarName: String? = nil,
                             selfEmails: Set<String> = [],
                             defaultTimeZone: TimeZone = .current) -> ParsedFeed {
        let lines = unfold(text)
        var calendarName: String?
        var calTimeZone = defaultTimeZone
        var inEvent = false
        var current: [Property] = []
        var rawEvents: [RawEvent] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            let upper = trimmed.uppercased()
            if upper == "BEGIN:VEVENT" {
                inEvent = true
                current = []
                continue
            }
            if upper == "END:VEVENT" {
                if inEvent, let built = buildRawEvent(from: current, defaultTimeZone: calTimeZone) {
                    rawEvents.append(built)
                }
                inEvent = false
                current = []
                continue
            }
            guard let prop = parseProperty(line) else { continue }
            if inEvent {
                current.append(prop)
            } else if prop.name == "X-WR-CALNAME" {
                let unescaped = unescape(prop.value).trimmingCharacters(in: .whitespacesAndNewlines)
                if !unescaped.isEmpty { calendarName = unescaped }
            } else if prop.name == "X-WR-TIMEZONE", let tz = TimeZone(identifier: prop.value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                calTimeZone = tz
            }
        }

        let resolvedCalendarName = calendarName ?? fallbackCalendarName
        let normalizedSelf = Set(selfEmails.map { $0.lowercased() })
        // Collect overridden recurrence dates per UID so master RRULE expansion skips them.
        var overriddenByUID: [String: Set<Int>] = [:]
        for raw in rawEvents {
            if let rid = raw.recurrenceID {
                overriddenByUID[raw.uid, default: []].insert(Int((rid.timeIntervalSince1970 / 60).rounded()))
            }
        }

        var meetings: [CalendarMeeting] = []
        for raw in rawEvents {
            if raw.status.uppercased() == "CANCELLED" { continue }
            guard let baseStart = raw.start else { continue }
            let duration = max(0, (raw.end ?? baseStart.addingTimeInterval(raw.isAllDay ? 86_400 : 1800)).timeIntervalSince(baseStart))
            let occurrences: [Date]
            if let rrule = raw.rrule, raw.recurrenceID == nil {
                let overrides = overriddenByUID[raw.uid] ?? []
                occurrences = expandRRule(rrule, start: baseStart, duration: duration,
                                          timeZone: raw.timeZone, exdates: raw.exdates,
                                          overriddenMinutes: overrides,
                                          windowStart: windowStart, windowEnd: windowEnd)
            } else {
                let baseEnd = baseStart.addingTimeInterval(duration)
                occurrences = (baseEnd >= windowStart && baseStart <= windowEnd) ? [baseStart] : []
            }

            let (attendees, selfDeclined) = resolveAttendees(raw: raw, selfEmails: normalizedSelf, calendarName: calendarName)
            let linkParts = [raw.conference, raw.url, raw.location, raw.description]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let linkText = linkParts.joined(separator: "\n")

            for occStart in occurrences {
                let occEnd = occStart.addingTimeInterval(duration)
                let id = "\(raw.uid)@\(Int(occStart.timeIntervalSince1970))"
                meetings.append(CalendarMeeting(
                    id: id,
                    uid: raw.uid,
                    title: raw.summary.isEmpty ? "Untitled event" : raw.summary,
                    start: occStart,
                    end: occEnd,
                    isAllDay: raw.isAllDay,
                    attendees: attendees,
                    declined: selfDeclined,
                    linkText: linkText,
                    notes: cleanDescription(raw.description),
                    calendarName: resolvedCalendarName,
                    sourceKind: .icsFeed,
                    organizerName: raw.organizerName
                ))
            }
        }

        meetings.sort { $0.start < $1.start }
        return ParsedFeed(calendarName: resolvedCalendarName, events: meetings)
    }

    // MARK: - Line unfolding & property parsing

    private static func unfold(_ text: String) -> [String] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var out: [String] = []
        for raw in normalized.components(separatedBy: "\n") {
            if let first = raw.first, (first == " " || first == "\t"), !out.isEmpty {
                out[out.count - 1].append(contentsOf: raw.dropFirst())
            } else {
                out.append(raw)
            }
        }
        return out
    }

    private static func parseProperty(_ line: String) -> Property? {
        // Split at the first colon outside quotes.
        var inQuotes = false
        var colonIndex: String.Index?
        for idx in line.indices {
            let ch = line[idx]
            if ch == "\"" { inQuotes.toggle() }
            else if ch == ":", !inQuotes {
                colonIndex = idx
                break
            }
        }
        guard let colon = colonIndex else { return nil }
        let left = String(line[..<colon])
        let value = String(line[line.index(after: colon)...])
        let segments = splitSemicolonsOutsideQuotes(left)
        guard let rawName = segments.first?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
              !rawName.isEmpty else { return nil }
        var params: [String: String] = [:]
        for param in segments.dropFirst() {
            guard let eq = param.firstIndex(of: "=") else { continue }
            let key = param[..<eq].trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            var val = param[param.index(after: eq)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if val.hasPrefix("\""), val.hasSuffix("\""), val.count >= 2 {
                val = String(val.dropFirst().dropLast())
            }
            params[key] = val
        }
        return Property(name: rawName, params: params, value: value)
    }

    private static func splitSemicolonsOutsideQuotes(_ s: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        for ch in s {
            if ch == "\"" {
                inQuotes.toggle()
                current.append(ch)
            } else if ch == ";", !inQuotes {
                parts.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        parts.append(current)
        return parts
    }

    private static func unescape(_ raw: String) -> String {
        var out = ""
        var iterator = raw.makeIterator()
        while let ch = iterator.next() {
            if ch == "\\", let next = iterator.next() {
                switch next {
                case "n", "N": out.append("\n")
                case ",": out.append(",")
                case ";": out.append(";")
                case "\\": out.append("\\")
                default: out.append(next)
                }
            } else {
                out.append(ch)
            }
        }
        return out
    }

    private static func cleanDescription(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        // Google Calendar often wraps Meet boilerplate in `-::~:~::~:~...`; strip noisyHTML/markers cleanly.
        var cleaned = text
        if let marker = cleaned.range(of: "-::~:~::~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~::~:~::-") {
            cleaned = String(cleaned[..<marker.lowerBound])
        }
        cleaned = cleaned.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Event construction

    private static func buildRawEvent(from props: [Property], defaultTimeZone: TimeZone) -> RawEvent? {
        var ev = RawEvent()
        ev.timeZone = defaultTimeZone
        for prop in props {
            switch prop.name {
            case "UID":
                let v = unescape(prop.value).trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty { ev.uid = v }
            case "SUMMARY":
                ev.summary = unescape(prop.value).trimmingCharacters(in: .whitespacesAndNewlines)
            case "DESCRIPTION":
                ev.description = unescape(prop.value)
            case "LOCATION":
                ev.location = unescape(prop.value)
            case "URL":
                ev.url = unescape(prop.value)
            case "X-GOOGLE-CONFERENCE":
                ev.conference = unescape(prop.value)
            case "STATUS":
                ev.status = prop.value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            case "DTSTART":
                if let parsed = parseDate(prop, fallbackTZ: defaultTimeZone) {
                    ev.start = parsed.date
                    ev.isAllDay = parsed.allDay
                    ev.timeZone = parsed.timeZone
                }
            case "DTEND":
                if let parsed = parseDate(prop, fallbackTZ: ev.timeZone) {
                    ev.end = parsed.date
                }
            case "RECURRENCE-ID":
                if let parsed = parseDate(prop, fallbackTZ: ev.timeZone) {
                    ev.recurrenceID = parsed.date
                }
            case "EXDATE":
                let tz = prop.params["TZID"].flatMap(resolveTimeZone) ?? ev.timeZone
                for item in prop.value.split(separator: ",") {
                    if let parsed = parseDateValue(String(item), valueParam: prop.params["VALUE"], tz: tz) {
                        ev.exdates.append(parsed.date)
                    }
                }
            case "RRULE":
                ev.rrule = prop.value.trimmingCharacters(in: .whitespacesAndNewlines)
            case "ORGANIZER":
                let email = extractEmail(prop.value)
                let cn = prop.params["CN"].map(unescape) ?? ""
                ev.organizerEmail = email
                ev.organizerName = cn.isEmpty ? email.map(CalendarAttendee.humanizedName(fromEmail:)) : cn
            case "ATTENDEE":
                // Skip room resources (`CUTYPE=RESOURCE` / `CUTYPE=ROOM`).
                let cutype = prop.params["CUTYPE"]?.uppercased() ?? "INDIVIDUAL"
                if cutype == "ROOM" || cutype == "RESOURCE" { continue }
                let email = extractEmail(prop.value)
                let cn = prop.params["CN"].map(unescape) ?? ""
                let stat = prop.params["PARTSTAT"]?.uppercased() ?? "NEEDS-ACTION"
                let role = prop.params["ROLE"]?.uppercased() ?? ""
                ev.attendees.append(RawAttendee(name: cn, email: email, partStat: stat, isOrganizer: role == "CHAIR"))
            default:
                break
            }
        }
        guard ev.start != nil else { return nil }
        return ev
    }

    private static func extractEmail(_ raw: String) -> String? {
        let cleaned = unescape(raw)
            .replacingOccurrences(of: "mailto:", with: "", options: [.caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.contains("@"), !cleaned.hasSuffix("calendar.google.com") else { return nil }
        return cleaned
    }

    private static func resolveAttendees(raw: RawEvent,
                                         selfEmails: Set<String>,
                                         calendarName: String?) -> ([CalendarAttendee], Bool) {
        var selfCandidates = selfEmails
        if let cal = calendarName?.lowercased(), cal.contains("@") {
            selfCandidates.insert(cal.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        var selfDeclined = false
        var list: [CalendarAttendee] = []
        var seen: Set<String> = []

        for item in raw.attendees {
            let lowerEmail = item.email?.lowercased()
            if let lowerEmail, selfCandidates.contains(lowerEmail) {
                if item.partStat == "DECLINED" { selfDeclined = true }
                continue
            }
            let status: CalendarAttendee.Status = switch item.partStat {
            case "ACCEPTED": .accepted
            case "TENTATIVE": .tentative
            case "DECLINED": .declined
            default: .pending
            }
            let isOrg = item.isOrganizer || (lowerEmail != nil && lowerEmail == raw.organizerEmail?.lowercased())
            let attendee = CalendarAttendee(name: item.name, email: item.email, isOrganizer: isOrg, status: status)
            guard !attendee.name.isEmpty, !seen.contains(attendee.id) else { continue }
            seen.insert(attendee.id)
            list.append(attendee)
        }

        if let orgEmail = raw.organizerEmail, !selfCandidates.contains(orgEmail.lowercased()) {
            let org = CalendarAttendee(name: raw.organizerName ?? "", email: orgEmail, isOrganizer: true, status: .accepted)
            if !org.name.isEmpty, !seen.contains(org.id) {
                list.insert(org, at: 0)
            }
        }
        return (list, selfDeclined)
    }

    // MARK: - Dates & RRULE expansion

    private static func resolveTimeZone(_ id: String) -> TimeZone? {
        if let tz = TimeZone(identifier: id) { return tz }
        // Common Windows timezone aliases seen in Outlook/Teams invites inside Google Calendar feeds.
        let windowsMap: [String: String] = [
            "Eastern Standard Time": "America/New_York",
            "Central Standard Time": "America/Chicago",
            "Mountain Standard Time": "America/Denver",
            "Pacific Standard Time": "America/Los_Angeles",
            "GMT Standard Time": "Europe/London",
            "W. Europe Standard Time": "Europe/Berlin",
            "Romance Standard Time": "Europe/Paris",
            "India Standard Time": "Asia/Kolkata",
            "UTC": "UTC",
        ]
        return windowsMap[id].flatMap(TimeZone.init(identifier:))
    }

    private static func parseDate(_ prop: Property, fallbackTZ: TimeZone) -> (date: Date, allDay: Bool, timeZone: TimeZone)? {
        let tz = prop.params["TZID"].flatMap(resolveTimeZone) ?? fallbackTZ
        return parseDateValue(prop.value, valueParam: prop.params["VALUE"], tz: tz)
    }

    private static func parseDateValue(_ raw: String, valueParam: String?, tz: TimeZone) -> (date: Date, allDay: Bool, timeZone: TimeZone)? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let digitsOnly = s.filter(\.isNumber)
        if valueParam?.uppercased() == "DATE" || (s.count == 8 && digitsOnly.count == 8) {
            guard let y = Int(s.prefix(4)),
                  let m = Int(s.dropFirst(4).prefix(2)),
                  let d = Int(s.dropFirst(6).prefix(2)) else { return nil }
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = tz
            guard let date = cal.date(from: DateComponents(year: y, month: m, day: d, hour: 0, minute: 0, second: 0)) else { return nil }
            return (date, true, tz)
        }
        let isUTC = s.uppercased().hasSuffix("Z")
        let effectiveTZ = isUTC ? TimeZone(secondsFromGMT: 0)! : tz
        let clean = isUTC ? String(s.dropLast()) : s
        let parts = clean.split(separator: "T")
        guard parts.count == 2, parts[0].count == 8, parts[1].count >= 6,
              let y = Int(parts[0].prefix(4)),
              let m = Int(parts[0].dropFirst(4).prefix(2)),
              let d = Int(parts[0].dropFirst(6).prefix(2)),
              let hh = Int(parts[1].prefix(2)),
              let mm = Int(parts[1].dropFirst(2).prefix(2)),
              let ss = Int(parts[1].dropFirst(4).prefix(2)) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = effectiveTZ
        guard let date = cal.date(from: DateComponents(year: y, month: m, day: d, hour: hh, minute: mm, second: ss)) else { return nil }
        return (date, false, tz)
    }

    private static func expandRRule(_ rrule: String,
                                    start: Date,
                                    duration: TimeInterval,
                                    timeZone: TimeZone,
                                    exdates: [Date],
                                    overriddenMinutes: Set<Int>,
                                    windowStart: Date,
                                    windowEnd: Date) -> [Date] {
        var map: [String: String] = [:]
        for item in rrule.split(separator: ";") {
            let kv = item.split(separator: "=", maxSplits: 1)
            if kv.count == 2 {
                map[kv[0].uppercased()] = String(kv[1]).uppercased()
            }
        }
        guard let freq = map["FREQ"] else {
            return (start.addingTimeInterval(duration) >= windowStart && start <= windowEnd) ? [start] : []
        }
        let interval = max(1, map["INTERVAL"].flatMap(Int.init) ?? 1)
        let maxCount = map["COUNT"].flatMap(Int.init)
        let until = map["UNTIL"].flatMap { parseDateValue($0, valueParam: nil, tz: timeZone)?.date }
        let byDays: [Int] = (map["BYDAY"] ?? "")
            .split(separator: ",")
            .compactMap { token in
                let suffix = String(token.suffix(2))
                return switch suffix {
                case "SU": 1
                case "MO": 2
                case "TU": 3
                case "WE": 4
                case "TH": 5
                case "FR": 6
                case "SA": 7
                default: nil
                }
            }

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let excludedMinutes = Set(exdates.map { Int(($0.timeIntervalSince1970 / 60).rounded()) }).union(overriddenMinutes)
        let timeComps = cal.dateComponents([.hour, .minute, .second], from: start)

        var results: [Date] = []
        var totalGenerated = 0
        let hardCeiling = min(until ?? windowEnd, windowEnd)
        guard start <= hardCeiling else { return [] }

        if freq == "WEEKLY", !byDays.isEmpty {
            // Walk week by week from the week containing `start`.
            let startOfFirstWeek = cal.dateInterval(of: .weekOfYear, for: start)?.start ?? start
            var weekIndex = 0
            while weekIndex < 520 {
                guard let weekBase = cal.date(byAdding: .weekOfYear, value: weekIndex * interval, to: startOfFirstWeek) else { break }
                if weekBase > hardCeiling.addingTimeInterval(7 * 86_400) { break }
                for offset in 0..<7 {
                    guard let dayDate = cal.date(byAdding: .day, value: offset, to: weekBase) else { continue }
                    let weekday = cal.component(.weekday, from: dayDate)
                    guard byDays.contains(weekday) else { continue }
                    var comps = cal.dateComponents([.year, .month, .day], from: dayDate)
                    comps.hour = timeComps.hour
                    comps.minute = timeComps.minute
                    comps.second = timeComps.second
                    guard let candidate = cal.date(from: comps), candidate >= start else { continue }
                    if let until, candidate > until { return results }
                    totalGenerated += 1
                    if let maxCount, totalGenerated > maxCount { return results }
                    let minuteBucket = Int((candidate.timeIntervalSince1970 / 60).rounded())
                    if !excludedMinutes.contains(minuteBucket),
                       candidate.addingTimeInterval(duration) >= windowStart,
                       candidate <= windowEnd {
                        results.append(candidate)
                    }
                }
                weekIndex += 1
            }
            return results
        }

        let component: Calendar.Component = switch freq {
        case "DAILY": .day
        case "WEEKLY": .weekOfYear
        case "MONTHLY": .month
        case "YEARLY": .year
        default: .weekOfYear
        }

        var step = 0
        while step < 1000 {
            guard let candidate = cal.date(byAdding: component, value: step * interval, to: start) else { break }
            if candidate > hardCeiling { break }
            if let until, candidate > until { break }
            totalGenerated += 1
            if let maxCount, totalGenerated > maxCount { break }
            let minuteBucket = Int((candidate.timeIntervalSince1970 / 60).rounded())
            if !excludedMinutes.contains(minuteBucket),
               candidate.addingTimeInterval(duration) >= windowStart,
               candidate <= windowEnd {
                results.append(candidate)
            }
            step += 1
        }
        return results
    }
}
