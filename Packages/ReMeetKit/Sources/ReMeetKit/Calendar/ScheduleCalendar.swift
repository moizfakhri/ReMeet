import Foundation

/// Computes smart Monday-Sunday focus windows ("This Week" vs "Upcoming Week" on weekends/Friday evening)
/// and calendar grid dates for the Schedule tab.
public enum ScheduleWeekFocus {
    public struct FocusWindow: Equatable, Sendable {
        public var weekStart: Date
        public var weekEnd: Date
        public var title: String
        public var dateRangeLabel: String
        public var isUpcomingWeek: Bool
        public var isCurrentWeek: Bool

        public init(weekStart: Date,
                    weekEnd: Date,
                    title: String,
                    dateRangeLabel: String,
                    isUpcomingWeek: Bool,
                    isCurrentWeek: Bool) {
            self.weekStart = weekStart
            self.weekEnd = weekEnd
            self.title = title
            self.dateRangeLabel = dateRangeLabel
            self.isUpcomingWeek = isUpcomingWeek
            self.isCurrentWeek = isCurrentWeek
        }
    }

    public static func mondayFirstCalendar(from base: Calendar = .current) -> Calendar {
        var cal = base
        cal.firstWeekday = 2 // Monday
        cal.minimumDaysInFirstWeek = 4
        return cal
    }

    public static func defaultFocus(now: Date = Date(),
                                    events: [CalendarMeeting],
                                    calendar: Calendar = .current) -> FocusWindow {
        let cal = mondayFirstCalendar(from: calendar)
        let currentStart = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? cal.startOfDay(for: now)
        let currentEnd = cal.date(byAdding: .day, value: 7, to: currentStart) ?? currentStart.addingTimeInterval(7 * 86_400)

        let weekday = cal.component(.weekday, from: now) // 1 = Sun, 6 = Fri, 7 = Sat
        let hour = cal.component(.hour, from: now)
        let remainingThisWeek = events.contains {
            MeetingReminder.hasOnlineMeetingPlatform($0)
                && $0.end > now
                && $0.start < currentEnd
                && $0.end > currentStart
        }

        let isWeekend = (weekday == 1 || weekday == 7)
        let isFridayEvening = (weekday == 6 && hour >= 17)
        let rollToNext = (isWeekend || isFridayEvening) && !remainingThisWeek

        if rollToNext {
            let nextStart = currentEnd
            let nextEnd = cal.date(byAdding: .day, value: 7, to: nextStart) ?? nextStart.addingTimeInterval(7 * 86_400)
            return FocusWindow(
                weekStart: nextStart,
                weekEnd: nextEnd,
                title: "Upcoming Week",
                dateRangeLabel: formatRange(start: nextStart, end: nextEnd, calendar: cal),
                isUpcomingWeek: true,
                isCurrentWeek: false
            )
        }

        return FocusWindow(
            weekStart: currentStart,
            weekEnd: currentEnd,
            title: "This Week",
            dateRangeLabel: formatRange(start: currentStart, end: currentEnd, calendar: cal),
            isUpcomingWeek: false,
            isCurrentWeek: true
        )
    }

    public static func window(weekOffset: Int,
                              now: Date = Date(),
                              events: [CalendarMeeting],
                              calendar: Calendar = .current) -> FocusWindow {
        let cal = mondayFirstCalendar(from: calendar)
        let base = defaultFocus(now: now, events: events, calendar: cal)
        if weekOffset == 0 { return base }

        let targetStart = cal.date(byAdding: .day, value: weekOffset * 7, to: base.weekStart)
            ?? base.weekStart.addingTimeInterval(Double(weekOffset * 7) * 86_400)
        let targetEnd = cal.date(byAdding: .day, value: 7, to: targetStart)
            ?? targetStart.addingTimeInterval(7 * 86_400)

        let currentStart = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? cal.startOfDay(for: now)
        let nextStart = cal.date(byAdding: .day, value: 7, to: currentStart) ?? currentStart.addingTimeInterval(7 * 86_400)
        let prevStart = cal.date(byAdding: .day, value: -7, to: currentStart) ?? currentStart.addingTimeInterval(-7 * 86_400)

        let isCurrent = cal.isDate(targetStart, inSameDayAs: currentStart)
        let isNext = cal.isDate(targetStart, inSameDayAs: nextStart)
        let isPrev = cal.isDate(targetStart, inSameDayAs: prevStart)

        let title: String
        if isCurrent {
            title = "This Week"
        } else if isNext {
            title = "Upcoming Week"
        } else if isPrev {
            title = "Last Week"
        } else {
            title = "Week of \(targetStart.formatted(.dateTime.month(.abbreviated).day()))"
        }

        return FocusWindow(
            weekStart: targetStart,
            weekEnd: targetEnd,
            title: title,
            dateRangeLabel: formatRange(start: targetStart, end: targetEnd, calendar: cal),
            isUpcomingWeek: isNext,
            isCurrentWeek: isCurrent
        )
    }

    public static func weekDays(startingAt weekStart: Date, calendar: Calendar = .current) -> [Date] {
        let cal = mondayFirstCalendar(from: calendar)
        return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: weekStart) }
    }

    public static func monthGridDays(containing date: Date, calendar: Calendar = .current) -> [Date] {
        let cal = mondayFirstCalendar(from: calendar)
        let comps = cal.dateComponents([.year, .month], from: date)
        guard let monthStart = cal.date(from: comps),
              let dayRange = cal.range(of: .day, in: .month, for: monthStart),
              let monthEnd = cal.date(byAdding: .day, value: dayRange.count - 1, to: monthStart) else {
            return []
        }
        let gridStart = cal.dateInterval(of: .weekOfYear, for: monthStart)?.start ?? monthStart
        let endWeekStart = cal.dateInterval(of: .weekOfYear, for: monthEnd)?.start ?? monthEnd
        let gridEnd = cal.date(byAdding: .day, value: 7, to: endWeekStart) ?? endWeekStart.addingTimeInterval(7 * 86_400)

        var days: [Date] = []
        var cursor = gridStart
        while cursor < gridEnd && days.count < 42 {
            days.append(cursor)
            guard let next = cal.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return days
    }

    private static func formatRange(start: Date, end: Date, calendar: Calendar) -> String {
        let inclusiveEnd = calendar.date(byAdding: .day, value: -1, to: end) ?? end.addingTimeInterval(-86_400)
        let startStr = start.formatted(.dateTime.month(.abbreviated).day())
        let endStr = inclusiveEnd.formatted(.dateTime.month(.abbreviated).day())
        return "\(startStr) – \(endStr)"
    }
}

/// Connects upcoming meetings in the focused week to open action items & promises so the user
/// sees exactly what to focus on before their calls.
public struct WeekFocusPlan: Equatable, Sendable {
    public struct MeetingGroup: Equatable, Sendable, Identifiable {
        public var event: CalendarMeeting
        public var yourItems: [CommitmentItem]
        public var theirItems: [CommitmentItem]
        public var hasRecording: Bool

        public var id: String { event.id }
        public var totalCount: Int { yourItems.count + theirItems.count }

        public init(event: CalendarMeeting,
                    yourItems: [CommitmentItem],
                    theirItems: [CommitmentItem],
                    hasRecording: Bool = false) {
            self.event = event
            self.yourItems = yourItems
            self.theirItems = theirItems
            self.hasRecording = hasRecording
        }
    }

    public var window: ScheduleWeekFocus.FocusWindow
    public var weekEvents: [CalendarMeeting]
    public var remainingEvents: [CalendarMeeting]
    public var actionGroups: [MeetingGroup]
    public var eventIDsWithActionItems: Set<String>
    public var otherRecentMine: [CommitmentItem]

    public var totalFocusActionItems: Int {
        actionGroups.reduce(0) { $0 + $1.totalCount }
    }

    public static func build(window: ScheduleWeekFocus.FocusWindow,
                             events: [CalendarMeeting],
                             snapshots: [MeetingSnapshot],
                             people: [PersonSummary],
                             recorderName: String = "",
                             now: Date = Date()) -> WeekFocusPlan {
        let weekEvents = events
            .filter {
                MeetingReminder.hasOnlineMeetingPlatform($0)
                    && $0.start < window.weekEnd
                    && $0.end > window.weekStart
            }
            .sorted { $0.start < $1.start }

        let remainingEvents = weekEvents.filter { $0.end >= now }
        let targetEvents = remainingEvents.isEmpty ? weekEvents : remainingEvents

        var groups: [MeetingGroup] = []
        var eventIDs: Set<String> = []
        var linkedIDs: Set<String> = []

        for event in targetEvents {
            let brief = MeetingPrepBrief.build(
                for: event,
                snapshots: snapshots,
                people: people,
                recorderName: recorderName,
                now: now
            )
            let recorded = snapshots.contains { snap in
                if snap.meta.calendarEventID == event.id { return true }
                return abs(snap.meta.startTime.timeIntervalSince(event.start)) <= 20 * 60
                    && MeetingReminder.seriesKey(for: snap.meta.title) == event.seriesKey
            }
            if !brief.yourOpenPromises.isEmpty || !brief.theirOpenPromises.isEmpty {
                eventIDs.insert(event.id)
                for item in brief.yourOpenPromises { linkedIDs.insert(item.id) }
                for item in brief.theirOpenPromises { linkedIDs.insert(item.id) }
                groups.append(MeetingGroup(
                    event: event,
                    yourItems: brief.yourOpenPromises,
                    theirItems: brief.theirOpenPromises,
                    hasRecording: recorded
                ))
            }
        }

        let allCommitments = CommitmentsRadar.build(from: snapshots, recorderName: recorderName, now: now)
        let otherRecentMine = allCommitments.filter { item in
            !item.actionItem.done
                && item.relevance == .mine
                && item.ageDays <= 30
                && !linkedIDs.contains(item.id)
        }

        return WeekFocusPlan(
            window: window,
            weekEvents: weekEvents,
            remainingEvents: remainingEvents,
            actionGroups: groups,
            eventIDsWithActionItems: eventIDs,
            otherRecentMine: otherRecentMine
        )
    }
}
