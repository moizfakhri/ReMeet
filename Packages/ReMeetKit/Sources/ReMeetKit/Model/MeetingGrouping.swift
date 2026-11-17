import Foundation

/// Sidebar sections: Today / Yesterday / This week / Earlier.
public enum MeetingGroup: String, CaseIterable, Sendable {
    case today = "Today"
    case yesterday = "Yesterday"
    case thisWeek = "This week"
    case earlier = "Earlier"

    /// "This week" means the last 7 days before yesterday, not the calendar week, so a
    /// Monday morning still shows last Thursday's meeting there.
    public static func group(for date: Date, now: Date, calendar: Calendar = .current) -> MeetingGroup {
        let startOfToday = calendar.startOfDay(for: now)
        if date >= startOfToday { return .today }
        let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday)!
        if date >= startOfYesterday { return .yesterday }
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: startOfToday)!
        return date >= weekAgo ? .thisWeek : .earlier
    }

    /// Groups items in the given order (callers sort newest first), dropping empty groups.
    public static func grouped<T>(_ items: [T], date: (T) -> Date, now: Date,
                                  calendar: Calendar = .current) -> [(MeetingGroup, [T])] {
        var buckets: [MeetingGroup: [T]] = [:]
        for item in items {
            buckets[group(for: date(item), now: now, calendar: calendar), default: []].append(item)
        }
        return allCases.compactMap { g in buckets[g].map { (g, $0) } }
    }
}
