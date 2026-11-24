import Foundation

/// A cross-meeting commitment / action item, classified into what YOU promised vs what OTHERS promised.
public struct CommitmentItem: Equatable, Sendable, Identifiable {
    public enum Direction: Equatable, Sendable {
        case mine
        case theirs(String)
        case unassigned
    }

    public enum Relevance: Int, Comparable, Equatable, Sendable {
        case mine = 0
        case relatedToMe = 1
        case others = 2

        public static func < (lhs: Relevance, rhs: Relevance) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    public var meetingFolder: MeetingFolder
    public var meetingTitle: String
    public var meetingDate: Date
    public var actionItem: ActionItem
    public var direction: Direction
    public var relevance: Relevance
    public var ageDays: Int

    public var id: String { "\(meetingFolder.id)::\(actionItem.id)" }

    public var ownerLabel: String {
        switch direction {
        case .mine: "You"
        case .theirs(let name): name
        case .unassigned: "Unassigned"
        }
    }

    public init(meetingFolder: MeetingFolder,
                meetingTitle: String,
                meetingDate: Date,
                actionItem: ActionItem,
                direction: Direction,
                relevance: Relevance = .others,
                ageDays: Int) {
        self.meetingFolder = meetingFolder
        self.meetingTitle = meetingTitle
        self.meetingDate = meetingDate
        self.actionItem = actionItem
        self.direction = direction
        self.relevance = relevance
        self.ageDays = ageDays
    }
}

public enum CommitmentsRadar {
    public static func classifyOwner(_ owner: String?, recorderName: String) -> CommitmentItem.Direction {
        guard let raw = owner?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return .unassigned
        }
        let myName = recorderName.trimmingCharacters(in: .whitespacesAndNewlines)
        func isMe(_ candidate: String) -> Bool {
            let lower = candidate.lowercased()
            if lower == "you" || lower == "me" || lower == "myself" { return true }
            return !myName.isEmpty && SpeakerMemory.namesMatch(candidate, myName)
        }
        if isMe(raw) { return .mine }

        // Handle joint owners ("Alex and Priya", "You / Sam", "Alex, Elena").
        let parts = raw
            .replacingOccurrences(of: " and ", with: ",", options: .caseInsensitive)
            .split { $0 == "," || $0 == "/" || $0 == "&" }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if parts.contains(where: isMe) { return .mine }

        return .theirs(raw)
    }

    public static func classifyRelevance(_ item: ActionItem,
                                         recorderName: String,
                                         otherParticipantCount: Int) -> CommitmentItem.Relevance {
        if classifyOwner(item.owner, recorderName: recorderName) == .mine {
            return .mine
        }
        if let explicit = item.relatesToMe {
            return explicit ? .relatedToMe : .others
        }
        if taskReferencesUser(item.task, recorderName: recorderName) {
            return .relatedToMe
        }
        if otherParticipantCount == 1 {
            return .relatedToMe
        }
        return .others
    }

    public static func partition(_ items: [ActionItem],
                                 recorderName: String,
                                 otherParticipantCount: Int) -> (mine: [ActionItem], related: [ActionItem], others: [ActionItem]) {
        var mine: [ActionItem] = []
        var related: [ActionItem] = []
        var others: [ActionItem] = []
        for item in items where !item.dismissed {
            switch classifyRelevance(item, recorderName: recorderName, otherParticipantCount: otherParticipantCount) {
            case .mine: mine.append(item)
            case .relatedToMe: related.append(item)
            case .others: others.append(item)
            }
        }
        return (mine, related, others)
    }

    private static func taskReferencesUser(_ task: String, recorderName: String) -> Bool {
        let lower = task.lowercased()
        let trimmedName = recorderName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.count >= 2, containsWholeWord(trimmedName.lowercased(), in: lower) {
            return true
        }
        let firstName = trimmedName.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        if firstName.count >= 3, containsWholeWord(firstName.lowercased(), in: lower) {
            return true
        }
        let phrases = [
            "send you", "share with you", "email you", "follow up with you",
            "get back to you", "review your", "approve your", "unblock you",
            "to you", "for you", "with you",
        ]
        if phrases.contains(where: { containsPhrase($0, in: lower) }) {
            return true
        }
        return containsWholeWord("your", in: lower)
    }

    private static func containsWholeWord(_ word: String, in text: String) -> Bool {
        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: word) + "\\b"
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func containsPhrase(_ phrase: String, in text: String) -> Bool {
        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: phrase) + "\\b"
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    public static func build(from snapshots: [MeetingSnapshot],
                             recorderName: String = "",
                             now: Date = Date()) -> [CommitmentItem] {
        let cal = Calendar.current
        var items: [CommitmentItem] = []
        for snap in snapshots {
            guard let summary = snap.summary else { continue }
            let days = max(0, cal.dateComponents([.day], from: snap.meta.startTime, to: now).day ?? 0)
            let otherCount = max(
                snap.participantNames.count,
                snap.talkSecondsBySpeaker.keys.filter { $0 != SpeakerNames.youID }.count
            )
            for action in summary.actionItems where !action.dismissed {
                let dir = classifyOwner(action.owner, recorderName: recorderName)
                let rel = classifyRelevance(action, recorderName: recorderName, otherParticipantCount: otherCount)
                items.append(CommitmentItem(
                    meetingFolder: snap.folder,
                    meetingTitle: snap.meta.title,
                    meetingDate: snap.meta.startTime,
                    actionItem: action,
                    direction: dir,
                    relevance: rel,
                    ageDays: days
                ))
            }
        }
        items.sort { a, b in
            if a.actionItem.done != b.actionItem.done { return !a.actionItem.done }
            if a.relevance != b.relevance { return a.relevance < b.relevance }
            return a.meetingDate > b.meetingDate
        }
        return items
    }
}

// MARK: - Walk-In Pre-Meeting Prep Brief (Signature Feature)

/// Automatic pre-meeting briefing assembled locally for any upcoming or current CalendarMeeting.
/// Cross-references the calendar invite's recurring title and attendees against past meetings & People.
public struct MeetingPrepBrief: Equatable, Sendable {
    public struct PriorMeetingRecap: Equatable, Sendable, Identifiable {
        public var folder: MeetingFolder
        public var title: String
        public var date: Date
        public var takeaways: [SummaryPoint]
        public var decisions: [SummaryPoint]
        public var openQuestions: [SummaryPoint]

        public var id: String { folder.id }
    }

    public var event: CalendarMeeting
    public var matchedPeople: [PersonSummary]
    public var lastSeriesMeeting: PriorMeetingRecap?
    public var recentRelatedMeetings: [PriorMeetingRecap]
    /// Unchecked promises YOU made in prior meetings with these attendees / series.
    public var yourOpenPromises: [CommitmentItem]
    /// Unchecked promises THESE ATTENDEES made in prior meetings.
    public var theirOpenPromises: [CommitmentItem]
    /// Unresolved open questions from the last meeting in this series / group.
    public var carryoverQuestions: [SummaryPoint]

    public var hasPriorHistory: Bool {
        lastSeriesMeeting != nil || !yourOpenPromises.isEmpty || !theirOpenPromises.isEmpty || matchedPeople.contains { $0.meetingsCount > 0 || !$0.profile.notes.isEmpty }
    }

    public static func build(for event: CalendarMeeting,
                             snapshots: [MeetingSnapshot],
                             people: [PersonSummary],
                             recorderName: String = "",
                             now: Date = Date()) -> MeetingPrepBrief {
        let matchedPeople = event.attendees
            .filter { $0.status != .declined }
            .compactMap { att in
                people.first { $0.profile.matchesAttendee(att) }
            }

        let targetSeries = event.seriesKey
        let attendeeProfiles = matchedPeople.map(\.profile)

        func snapshotMatchesInvite(_ snap: MeetingSnapshot) -> (sameSeries: Bool, sharedPeople: Int) {
            let sameSeries = !targetSeries.isEmpty
                && targetSeries != "untitled event"
                && targetSeries != "meeting"
                && MeetingReminder.seriesKey(for: snap.meta.title) == targetSeries
            var shared = 0
            for profile in attendeeProfiles {
                let inSpeakers = snap.speakers.names.values.contains { profile.matchesName($0) }
                let inCalendar = snap.meta.calendarAttendees.contains { profile.matchesAttendee($0) }
                if inSpeakers || inCalendar { shared += 1 }
            }
            return (sameSeries, shared)
        }

        var seriesHits: [MeetingSnapshot] = []
        var attendeeHits: [MeetingSnapshot] = []
        for snap in snapshots where snap.meta.status == .summarized && snap.meta.startTime < event.end {
            let match = snapshotMatchesInvite(snap)
            if match.sameSeries {
                seriesHits.append(snap)
            } else if match.sharedPeople > 0 {
                attendeeHits.append(snap)
            }
        }
        seriesHits.sort { $0.meta.startTime > $1.meta.startTime }
        attendeeHits.sort { $0.meta.startTime > $1.meta.startTime }

        func makeRecap(_ snap: MeetingSnapshot) -> PriorMeetingRecap {
            PriorMeetingRecap(
                folder: snap.folder,
                title: snap.meta.title,
                date: snap.meta.startTime,
                takeaways: Array((snap.summary?.summary ?? []).prefix(3)),
                decisions: snap.summary?.decisions ?? [],
                openQuestions: snap.summary?.openQuestions ?? []
            )
        }

        let primaryPrior = seriesHits.first ?? (attendeeProfiles.count == 1 ? attendeeHits.first : nil)
        let relatedSnaps = Array((seriesHits + attendeeHits).prefix(4))
        let relatedFolderIDs = Set(relatedSnaps.map(\.id))

        let allCommitments = CommitmentsRadar.build(from: snapshots, recorderName: recorderName, now: now)
        let yourOpen = allCommitments.filter { item in
            !item.actionItem.done && item.direction == .mine && relatedFolderIDs.contains(item.meetingFolder.id)
        }
        let theirOpen = allCommitments.filter { item in
            guard !item.actionItem.done else { return false }
            if case .theirs(let owner) = item.direction {
                if attendeeProfiles.contains(where: { $0.matchesName(owner) }) { return true }
                if event.attendeeNames.contains(where: { SpeakerMemory.namesMatch($0, owner) }) { return true }
            }
            return false
        }.sorted { a, b in
            if a.relevance != b.relevance { return a.relevance < b.relevance }
            return a.meetingDate > b.meetingDate
        }

        return MeetingPrepBrief(
            event: event,
            matchedPeople: matchedPeople,
            lastSeriesMeeting: primaryPrior.map(makeRecap),
            recentRelatedMeetings: relatedSnaps.map(makeRecap),
            yourOpenPromises: Array(yourOpen.prefix(6)),
            theirOpenPromises: Array(theirOpen.prefix(6)),
            carryoverQuestions: Array((primaryPrior?.summary?.openQuestions ?? []).prefix(4))
        )
    }

    /// Clean Markdown dossier for copying into notes or an AI assistant before joining the call.
    public func markdown() -> String {
        var lines: [String] = []
        lines.append("# Walk-In Brief: \(event.title)")
        lines.append("- When: \(event.start.formatted(date: .abbreviated, time: .shortened)) – \(event.end.formatted(date: .omitted, time: .shortened))")
        if !event.attendeeNames.isEmpty {
            lines.append("- Attendees: \(event.attendeeNames.joined(separator: ", "))")
        }
        if let service = event.callService {
            lines.append("- Call: \(service)")
        }
        lines.append("")

        let peopleWithContext = matchedPeople.filter { !$0.profile.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.profile.subtitle != nil }
        if !peopleWithContext.isEmpty {
            lines.append("## Who's in the room")
            for person in peopleWithContext {
                var header = "- **\(person.profile.name)**"
                if let sub = person.profile.subtitle { header += " (\(sub))" }
                if person.meetingsCount > 0 { header += " · \(person.meetingsCount) past meeting\(person.meetingsCount == 1 ? "" : "s")" }
                lines.append(header)
                let note = person.profile.notes.trimmingCharacters(in: .whitespacesAndNewlines)
                if !note.isEmpty { lines.append("  \(note)") }
            }
            lines.append("")
        }

        if !yourOpenPromises.isEmpty {
            lines.append("## What you promised (still open)")
            for item in yourOpenPromises {
                let due = item.actionItem.due.map { " (due \($0))" } ?? ""
                lines.append("- [ ] \(item.actionItem.task)\(due) — *\(item.meetingTitle)*")
            }
            lines.append("")
        }

        if !theirOpenPromises.isEmpty {
            lines.append("## Waiting on them")
            for item in theirOpenPromises {
                let due = item.actionItem.due.map { " (due \($0))" } ?? ""
                lines.append("- [ ] **\(item.ownerLabel)**: \(item.actionItem.task)\(due) — *\(item.meetingTitle)*")
            }
            lines.append("")
        }

        if let last = lastSeriesMeeting {
            lines.append("## Last time (\(last.title) · \(last.date.formatted(date: .abbreviated, time: .omitted)))")
            for pt in last.takeaways { lines.append("- \(pt.text)") }
            for dec in last.decisions { lines.append("- **Decision:** \(dec.text)") }
            lines.append("")
        }

        if !carryoverQuestions.isEmpty {
            lines.append("## Open questions from last time")
            for q in carryoverQuestions { lines.append("- \(q.text)") }
            lines.append("")
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Instant Follow-Up Message Composer (Slack / Email)

public enum FollowUpComposer {
    public static func compose(title: String,
                               date: Date,
                               participants: [String],
                               summary: MeetingSummary,
                               recorderName: String = "") -> String {
        var lines: [String] = []
        let firstNames = participants
            .filter { !SpeakerMemory.isPlaceholder($0) }
            .map { $0.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? $0 }
        if !firstNames.isEmpty {
            lines.append("Hi \(firstNames.joined(separator: ", ")),")
            lines.append("")
            lines.append("Quick recap from **\(title)** (\(date.formatted(.dateTime.month(.abbreviated).day()))):")
        } else {
            lines.append("Recap from **\(title)** (\(date.formatted(.dateTime.month(.abbreviated).day()))):")
        }
        lines.append("")

        if !summary.decisions.isEmpty {
            lines.append("**Decisions**")
            for d in summary.decisions { lines.append("- \(d.text)") }
            lines.append("")
        } else if !summary.summary.isEmpty {
            lines.append("**Key takeaways**")
            for s in summary.summary.prefix(3) { lines.append("- \(s.text)") }
            lines.append("")
        }

        let openActions = summary.actionItems.filter { !$0.done }
        if !openActions.isEmpty {
            lines.append("**Next steps**")
            for item in openActions {
                let owner = item.owner.map { raw -> String in
                    if raw.caseInsensitiveCompare("You") == .orderedSame {
                        return recorderName.isEmpty ? "Me" : recorderName
                    }
                    return raw
                } ?? "Team"
                let due = item.due.map { " *(by \($0))*" } ?? ""
                lines.append("- **\(owner):** \(item.task)\(due)")
            }
            lines.append("")
        }

        if !summary.openQuestions.isEmpty {
            lines.append("**Open questions**")
            for q in summary.openQuestions { lines.append("- \(q.text)") }
            lines.append("")
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
