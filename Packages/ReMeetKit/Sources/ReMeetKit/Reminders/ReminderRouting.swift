import Foundation

/// Metadata describing an editable Apple Reminders list (`EKCalendar`).
public struct ReminderListInfo: Codable, Equatable, Sendable, Identifiable, Hashable {
    public var id: String
    public var title: String
    public var accountTitle: String
    public var isDefault: Bool

    public init(id: String, title: String, accountTitle: String = "", isDefault: Bool = false) {
        self.id = id
        self.title = title
        self.accountTitle = accountTitle
        self.isDefault = isDefault
    }
}

/// Pure routing, formatting, and deep-linking rules for Apple Reminders integration.
/// Hierarchy: Per-Action-Item -> Per-Meeting -> Per-Folder -> Global Default -> System Default.
public enum ReminderRouting {
    public static func resolveListID(itemListID: String?,
                                     meetingListID: String?,
                                     folder: MeetingCollection?,
                                     globalDefaultListID: String?,
                                     fallbackListID: String?) -> String? {
        if let itemListID, !itemListID.isEmpty { return itemListID }
        if let meetingListID, !meetingListID.isEmpty { return meetingListID }
        if let folder, !folder.remindersDisabled, let folderList = folder.remindersListID, !folderList.isEmpty {
            return folderList
        }
        if let globalDefaultListID, !globalDefaultListID.isEmpty { return globalDefaultListID }
        return (fallbackListID?.isEmpty == false) ? fallbackListID : nil
    }

    public static func resolveListLabel(meetingMeta: MeetingMeta?,
                                        folder: MeetingCollection?,
                                        globalDefaultListName: String?,
                                        mirrorFolders: Bool = false) -> String {
        if let name = meetingMeta?.remindersListName, !name.isEmpty { return name }
        if let folder {
            if folder.remindersDisabled { return "Auto-sync off" }
            if let name = folder.remindersListName, !name.isEmpty { return name }
            if mirrorFolders, !folder.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return folder.name
            }
        }
        if let globalDefaultListName, !globalDefaultListName.isEmpty { return globalDefaultListName }
        return "Reminders"
    }

    public static func mirroredFolderListName(itemListID: String?,
                                              meetingListID: String?,
                                              folder: MeetingCollection?,
                                              mirrorFolders: Bool) -> String? {
        guard mirrorFolders,
              (itemListID ?? "").isEmpty,
              (meetingListID ?? "").isEmpty,
              let folder,
              !folder.remindersDisabled,
              (folder.remindersListID ?? "").isEmpty else {
            return nil
        }
        let trimmed = folder.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func shouldAutoSync(item: ActionItem,
                                      relevance: CommitmentItem.Relevance,
                                      meetingMeta: MeetingMeta,
                                      folder: MeetingCollection?,
                                      globalAutoSync: Bool,
                                      includeWaitingOnOthers: Bool) -> Bool {
        guard globalAutoSync, !item.done, !item.dismissed else { return false }
        // Folder-level opt-out unless the user explicitly chose a list on the meeting or item.
        if folder?.remindersDisabled == true,
           (meetingMeta.remindersListID ?? "").isEmpty,
           (item.reminderListID ?? "").isEmpty {
            return false
        }
        switch relevance {
        case .mine:
            return true
        case .relatedToMe:
            return includeWaitingOnOthers
        case .others:
            return false
        }
    }

    public static func formatTitle(item: ActionItem, relevance: CommitmentItem.Relevance) -> String {
        let task = item.task.trimmingCharacters(in: .whitespacesAndNewlines)
        if relevance == .relatedToMe,
           let owner = item.owner?.trimmingCharacters(in: .whitespacesAndNewlines),
           !owner.isEmpty,
           owner.caseInsensitiveCompare("You") != .orderedSame {
            return "Follow up with \(owner): \(task)"
        }
        return task
    }

    public static func formatNotes(meetingTitle: String,
                                   meetingDate: Date,
                                   folderName: String?,
                                   owner: String?,
                                   timestamp: Double?) -> String {
        var lines: [String] = []
        let dateStr = meetingDate.formatted(date: .abbreviated, time: .shortened)
        lines.append("From ReMeet · \(meetingTitle) (\(dateStr))")
        if let folderName, !folderName.isEmpty {
            lines.append("Folder: \(folderName)")
        }
        if let owner, !owner.isEmpty, owner.caseInsensitiveCompare("You") != .orderedSame {
            lines.append("Owner: \(owner)")
        }
        if let timestamp {
            lines.append("Timestamp: \(TimeFormat.clock(timestamp))")
        }
        return lines.joined(separator: "\n")
    }

    public static func deepLinkURL(folderID: String, timestamp: Double?) -> URL? {
        var comps = URLComponents()
        comps.scheme = "remeet"
        comps.host = "meeting"
        comps.path = "/\(folderID)"
        if let timestamp, timestamp > 0 {
            comps.queryItems = [URLQueryItem(name: "t", value: String(Int(timestamp.rounded())))]
        }
        return comps.url
    }

    public static func parseDeepLink(_ url: URL) -> (folderID: String, timestamp: Double?)? {
        guard url.scheme?.lowercased() == "remeet",
              url.host?.lowercased() == "meeting" else { return nil }
        let folderID = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !folderID.isEmpty else { return nil }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let t = comps?.queryItems?.first(where: { $0.name == "t" })?.value.flatMap(Double.init)
        return (folderID, t)
    }
}

/// Parses natural-language action item due dates (relative to the meeting date) into Apple Reminders `DateComponents`.
public enum ReminderDueDateParser {
    private static let weekdayMap: [String: Int] = [
        "sun": 1, "sunday": 1,
        "mon": 2, "monday": 2,
        "tue": 3, "tues": 3, "tuesday": 3,
        "wed": 4, "weds": 4, "wednesday": 4,
        "thu": 5, "thur": 5, "thurs": 5, "thursday": 5,
        "fri": 6, "friday": 6,
        "sat": 7, "saturday": 7,
    ]

    public static func parse(_ due: String?, relativeTo referenceDate: Date, calendar: Calendar = .current) -> DateComponents? {
        guard var raw = due?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }

        // Strip common leading prepositions ("by Fri", "before Nov 28", "due tomorrow", "on Monday").
        raw = raw.replacingOccurrences(
            of: #"^(by|before|due|on|until|end of)\s+"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        let lower = raw.lowercased()
        let vagueTerms: Set<String> = ["asap", "soon", "tbd", "later", "eventually", "ongoing", "none", "n/a", "-"]
        if vagueTerms.contains(lower) { return nil }

        let refDay = calendar.startOfDay(for: referenceDate)

        if lower == "today" || lower == "eod" || lower == "end of day" || lower == "tonight" {
            return dayComponents(refDay, calendar: calendar)
        }
        if lower == "tomorrow" || lower == "tmr" || lower == "tmrw" {
            return calendar.date(byAdding: .day, value: 1, to: refDay).map { dayComponents($0, calendar: calendar) }
        }
        if lower == "next week" || lower == "end of week" || lower == "eow" {
            let daysToAdd = lower == "next week" ? 7 : max(1, (6 - calendar.component(.weekday, from: refDay) + 7) % 7)
            return calendar.date(byAdding: .day, value: daysToAdd, to: refDay).map { dayComponents($0, calendar: calendar) }
        }

        // "in N days" / "in N weeks"
        if let match = lower.range(of: #"^in\s+(\d+)\s+(day|days|week|weeks)$"#, options: .regularExpression) {
            let sub = String(lower[match])
            let parts = sub.split(whereSeparator: \.isWhitespace)
            if parts.count == 3, let n = Int(parts[1]) {
                let mult = parts[2].hasPrefix("week") ? 7 : 1
                return calendar.date(byAdding: .day, value: n * mult, to: refDay).map { dayComponents($0, calendar: calendar) }
            }
        }

        // Weekday names ("Fri", "Friday", "this Friday", "next Monday")
        let isNextWeekPrefix = lower.hasPrefix("next ")
        let weekdayToken = lower
            .replacingOccurrences(of: #"^(this|next)\s+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        if let targetWeekday = weekdayMap[weekdayToken] {
            let currentWeekday = calendar.component(.weekday, from: refDay)
            var delta = (targetWeekday - currentWeekday + 7) % 7
            if delta == 0 {
                delta = 7
            } else if isNextWeekPrefix && currentWeekday != 1 && (targetWeekday == 1 || targetWeekday > currentWeekday) {
                delta += 7
            }
            return calendar.date(byAdding: .day, value: delta, to: refDay).map { dayComponents($0, calendar: calendar) }
        }

        // ISO YYYY-MM-DD
        if let isoDate = parseWithFormats(raw, formats: ["yyyy-MM-dd"], calendar: calendar) {
            return dayComponents(isoDate, calendar: calendar)
        }

        // Month/Day with or without year ("Nov 28", "November 28", "Nov 28, 2026", "11/28", "11/28/2026")
        if let explicitYearDate = parseWithFormats(raw, formats: ["MMM d, yyyy", "MMM d yyyy", "MMMM d, yyyy", "MMMM d yyyy", "MM/dd/yyyy", "M/d/yyyy", "M/d/yy"], calendar: calendar) {
            return dayComponents(explicitYearDate, calendar: calendar)
        }

        if let monthDay = parseWithFormats(raw, formats: ["MMM d", "MMMM d", "M/d", "MM/dd"], calendar: calendar) {
            var comps = calendar.dateComponents([.month, .day], from: monthDay)
            let refYear = calendar.component(.year, from: refDay)
            comps.year = refYear
            if let candidate = calendar.date(from: comps) {
                // If that month/day already passed more than 30 days ago relative to referenceDate, roll to next year.
                if candidate < refDay.addingTimeInterval(-30 * 86_400) {
                    comps.year = refYear + 1
                }
                return comps
            }
        }

        return nil
    }

    private static func dayComponents(_ date: Date, calendar: Calendar) -> DateComponents {
        calendar.dateComponents([.year, .month, .day], from: date)
    }

    private static func parseWithFormats(_ text: String, formats: [String], calendar: Calendar) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        for fmt in formats {
            formatter.dateFormat = fmt
            if let d = formatter.date(from: text) {
                return d
            }
        }
        return nil
    }
}
