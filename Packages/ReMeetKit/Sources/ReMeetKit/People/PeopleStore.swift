import Foundation

/// Persistent profile for a person you meet with, stored in `people.json` beside `meetings/`.
public struct PersonProfile: Codable, Equatable, Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var aliases: [String]
    public var email: String?
    public var role: String?
    public var organization: String?
    /// Relationship / background context about this person. Fed into meeting summaries when they speak.
    public var notes: String
    public var hueIndex: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String = UUID().uuidString,
                name: String,
                aliases: [String] = [],
                email: String? = nil,
                role: String? = nil,
                organization: String? = nil,
                notes: String = "",
                hueIndex: Int? = nil,
                createdAt: Date = Date(),
                updatedAt: Date = Date()) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.id = id
        self.name = trimmed
        self.aliases = aliases.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let cleanEmail = email?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.email = (cleanEmail?.isEmpty == false) ? cleanEmail : nil
        let cleanRole = role?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.role = (cleanRole?.isEmpty == false) ? cleanRole : nil
        let cleanOrg = organization?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.organization = (cleanOrg?.isEmpty == false) ? cleanOrg : nil
        self.notes = notes
        self.hueIndex = hueIndex ?? Self.stableHueIndex(for: trimmed)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var initials: String {
        Self.initials(for: name)
    }

    public var subtitle: String? {
        let parts = [role, organization].compactMap { $0 }.filter { !$0.isEmpty }
        if !parts.isEmpty { return parts.joined(separator: " · ") }
        return email
    }

    public func matchesName(_ candidate: String) -> Bool {
        let target = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, !SpeakerMemory.isPlaceholder(target) else { return false }
        if SpeakerMemory.namesMatch(name, target) { return true }
        return aliases.contains { SpeakerMemory.namesMatch($0, target) }
    }

    public func matchesAttendee(_ attendee: CalendarAttendee) -> Bool {
        if let myEmail = email?.lowercased(), let theirEmail = attendee.email?.lowercased(),
           !myEmail.isEmpty, myEmail == theirEmail {
            return true
        }
        return matchesName(attendee.name)
    }

    public static func initials(for name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let words = cleaned
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return "?" }
        if words.count == 1 {
            return String(words[0].prefix(2)).uppercased()
        }
        let first = words.first?.first.map(String.init) ?? ""
        let last = words.last?.first.map(String.init) ?? ""
        return (first + last).uppercased()
    }

    public static func stableHueIndex(for name: String) -> Int {
        var hash: UInt64 = 5381
        for byte in name.lowercased().utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        return Int(hash % UInt64(PersonAvatarPalette.hues.count))
    }
}

/// Accessible OKLCH avatar colors (8 distinct hues) that harmonize with the Fern palette.
public enum PersonAvatarPalette {
    public static let hues: [Double] = [150, 205, 255, 300, 25, 55, 115, 180]

    public static func colors(index: Int, isDark: Bool) -> (background: RGBA, foreground: RGBA) {
        let hue = hues[abs(index) % hues.count]
        if isDark {
            return (
                background: OKLCH(0.28, 0.065, hue).srgb,
                foreground: OKLCH(0.86, 0.095, hue).srgb
            )
        } else {
            return (
                background: OKLCH(0.92, 0.045, hue).srgb,
                foreground: OKLCH(0.34, 0.095, hue).srgb
            )
        }
    }
}

/// Manages `people.json` beside `meetings/`, `collections.json`, and `voiceprints.json`.
public struct PeopleStore: Codable, Equatable, Sendable {
    public var profiles: [PersonProfile]

    public init(profiles: [PersonProfile] = []) {
        self.profiles = profiles
    }

    public func find(named name: String, email: String? = nil) -> PersonProfile? {
        if let email = email?.lowercased(), !email.isEmpty,
           let byEmail = profiles.first(where: { $0.email?.lowercased() == email }) {
            return byEmail
        }
        return profiles.first { $0.matchesName(name) }
    }

    /// Creates or enriches a profile when a speaker is named or a calendar attendee is seen.
    @discardableResult
    public mutating func upsert(name: String,
                                email: String? = nil,
                                role: String? = nil,
                                organization: String? = nil,
                                notes: String? = nil,
                                now: Date = Date()) -> PersonProfile? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !SpeakerMemory.isPlaceholder(trimmed) else { return nil }

        let cleanEmail = email?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = profiles.firstIndex(where: {
            if let e = cleanEmail?.lowercased(), !e.isEmpty, $0.email?.lowercased() == e { return true }
            return $0.name.compare(trimmed, options: .caseInsensitive) == .orderedSame
                || $0.aliases.contains(where: { $0.compare(trimmed, options: .caseInsensitive) == .orderedSame })
        }) {
            var existing = profiles[index]
            // Upgrade single-word name ("Priya") to full name ("Priya Patel") if matched by alias/email, keeping alias.
            if !existing.name.contains(" "), trimmed.contains(" "),
               SpeakerMemory.namesMatch(existing.name, trimmed) {
                if !existing.aliases.contains(where: { $0.caseInsensitiveCompare(existing.name) == .orderedSame }) {
                    existing.aliases.append(existing.name)
                }
                existing.name = trimmed
            }
            if existing.email == nil, let cleanEmail, !cleanEmail.isEmpty { existing.email = cleanEmail }
            if let role, !role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                existing.role = role.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let organization, !organization.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if existing.organization == nil || notes != nil {
                    existing.organization = organization.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            if let notes { existing.notes = notes }
            existing.updatedAt = now
            profiles[index] = existing
            return existing
        }

        // Also check first-name match if email gives a fuller name for an existing single-name profile.
        if let index = profiles.firstIndex(where: { SpeakerMemory.namesMatch($0.name, trimmed) }),
           profiles.filter({ SpeakerMemory.namesMatch($0.name, trimmed) }).count == 1 {
            var existing = profiles[index]
            if !existing.name.contains(" "), trimmed.contains(" ") {
                if !existing.aliases.contains(where: { $0.caseInsensitiveCompare(existing.name) == .orderedSame }) {
                    existing.aliases.append(existing.name)
                }
                existing.name = trimmed
            } else if existing.name.caseInsensitiveCompare(trimmed) != .orderedSame,
                      !existing.aliases.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                existing.aliases.append(trimmed)
            }
            if existing.email == nil, let cleanEmail, !cleanEmail.isEmpty { existing.email = cleanEmail }
            if existing.organization == nil, let organization, !organization.isEmpty { existing.organization = organization }
            if let role, !role.isEmpty { existing.role = role }
            if let notes { existing.notes = notes }
            existing.updatedAt = now
            profiles[index] = existing
            return existing
        }

        let created = PersonProfile(name: trimmed, email: cleanEmail, role: role,
                                    organization: organization, notes: notes ?? "",
                                    createdAt: now, updatedAt: now)
        profiles.append(created)
        return created
    }

    public mutating func update(_ id: String,
                                name: String,
                                email: String?,
                                role: String?,
                                organization: String?,
                                notes: String,
                                now: Date = Date()) -> (oldName: String, updated: PersonProfile)? {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !SpeakerMemory.isPlaceholder(trimmed) else { return nil }
        let oldName = profiles[index].name
        if oldName.caseInsensitiveCompare(trimmed) != .orderedSame,
           !profiles[index].aliases.contains(where: { $0.caseInsensitiveCompare(oldName) == .orderedSame }) {
            profiles[index].aliases.append(oldName)
        }
        profiles[index].name = trimmed
        let cleanEmail = email?.trimmingCharacters(in: .whitespacesAndNewlines)
        profiles[index].email = (cleanEmail?.isEmpty == false) ? cleanEmail : nil
        let cleanRole = role?.trimmingCharacters(in: .whitespacesAndNewlines)
        profiles[index].role = (cleanRole?.isEmpty == false) ? cleanRole : nil
        let cleanOrg = organization?.trimmingCharacters(in: .whitespacesAndNewlines)
        profiles[index].organization = (cleanOrg?.isEmpty == false) ? cleanOrg : nil
        profiles[index].notes = notes
        profiles[index].updatedAt = now
        return (oldName, profiles[index])
    }

    public mutating func merge(sourceID: String, into targetID: String, now: Date = Date()) -> (sourceName: String, target: PersonProfile)? {
        guard sourceID != targetID,
              let sIdx = profiles.firstIndex(where: { $0.id == sourceID }),
              let tIdx = profiles.firstIndex(where: { $0.id == targetID }) else { return nil }
        let source = profiles[sIdx]
        var target = profiles[tIdx]
        for candidate in [source.name] + source.aliases {
            if candidate.caseInsensitiveCompare(target.name) != .orderedSame,
               !target.aliases.contains(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) {
                target.aliases.append(candidate)
            }
        }
        if target.email == nil { target.email = source.email }
        if target.role == nil { target.role = source.role }
        if target.organization == nil { target.organization = source.organization }
        if !source.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            target.notes = target.notes.isEmpty ? source.notes : (target.notes + "\n\n" + source.notes)
        }
        target.updatedAt = now
        profiles[tIdx] = target
        profiles.remove(at: sIdx)
        return (source.name, target)
    }

    public mutating func remove(_ id: String) -> PersonProfile? {
        guard let idx = profiles.firstIndex(where: { $0.id == id }) else { return nil }
        return profiles.remove(at: idx)
    }

    /// Automatically seeds/enriches People profiles from non-declined calendar attendees of real online meetings.
    @discardableResult
    public mutating func ingestCalendarEvents(_ events: [CalendarMeeting], recorderName: String = "", now: Date = Date()) -> Bool {
        let before = profiles
        let myName = recorderName.trimmingCharacters(in: .whitespacesAndNewlines)
        for event in events where MeetingReminder.hasOnlineMeetingPlatform(event) && event.attendees.count <= 15 {
            for attendee in event.attendees where attendee.status != .declined {
                if !myName.isEmpty, attendee.name.caseInsensitiveCompare(myName) == .orderedSame { continue }
                _ = upsert(name: attendee.name,
                           email: attendee.email,
                           organization: attendee.inferredOrganization,
                           now: now)
            }
        }
        return profiles != before
    }
}

public enum PeopleFile {
    public static func url(beside meetingsRoot: URL) -> URL {
        meetingsRoot.deletingLastPathComponent().appendingPathComponent("people.json")
    }

    public static func load(_ url: URL) -> PeopleStore {
        (try? JSONCoding.read(PeopleStore.self, from: url)) ?? PeopleStore()
    }

    public static func save(_ store: PeopleStore, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONCoding.write(store, to: url)
    }
}

// MARK: - Lightweight Meeting Snapshot & Directory Aggregation

/// Compact, off-main-decoded summary of one meeting folder used to build People, Prep Briefs,
/// Commitments, and Global Moments without keeping 150 full transcripts in memory.
public struct MeetingSnapshot: Equatable, Sendable, Identifiable {
    public var folder: MeetingFolder
    public var meta: MeetingMeta
    public var speakers: SpeakerNames
    public var summary: MeetingSummary?
    public var notes: [MeetingNote]
    /// Display-resolved non-user speaker names in this meeting (`speakers.json` + calendar fallback).
    public var participantNames: [String]
    /// Total spoken seconds per speaker ID (including `"you"`).
    public var talkSecondsBySpeaker: [String: Double]
    /// Representative quote per speaker ID for quick preview cards.
    public var sampleQuoteBySpeaker: [String: String]
    /// Key moments precomputed for this meeting.
    public var moments: [KeyMoment]

    public var id: String { folder.id }

    public init(folder: MeetingFolder,
                meta: MeetingMeta,
                speakers: SpeakerNames = SpeakerNames(),
                summary: MeetingSummary? = nil,
                notes: [MeetingNote] = [],
                participantNames: [String] = [],
                talkSecondsBySpeaker: [String: Double] = [:],
                sampleQuoteBySpeaker: [String: String] = [:],
                moments: [KeyMoment] = []) {
        self.folder = folder
        self.meta = meta
        self.speakers = speakers
        self.summary = summary
        self.notes = notes
        self.participantNames = participantNames
        self.talkSecondsBySpeaker = talkSecondsBySpeaker
        self.sampleQuoteBySpeaker = sampleQuoteBySpeaker
        self.moments = moments
    }

    public static func read(_ folder: MeetingFolder) -> MeetingSnapshot? {
        guard let meta = try? folder.readMeta() else { return nil }
        let speakers = ((try? folder.read(SpeakerNames.self, .speakers)) ?? nil) ?? SpeakerNames()
        let summary = (try? folder.read(MeetingSummary.self, .summary)) ?? nil
        let notes = NotesFile(url: folder.file(.notes)).load()
        let transcript = (try? folder.read(Transcript.self, .transcript)) ?? nil
        let savedMoments = MomentsFile(url: folder.file(.moments)).load()

        var talkSeconds: [String: Double] = [:]
        var sampleQuotes: [String: String] = [:]
        if let segments = transcript?.segments {
            for seg in segments {
                let dur = max(0, seg.end - seg.start)
                talkSeconds[seg.speaker, default: 0] += dur
                let trimmed = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.count >= 24, (sampleQuotes[seg.speaker]?.count ?? 0) < min(trimmed.count, 140) {
                    sampleQuotes[seg.speaker] = String(trimmed.prefix(160))
                }
            }
        }

        var names: [String] = []
        for (_, name) in speakers.names {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !SpeakerMemory.isPlaceholder(trimmed),
               !names.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                names.append(trimmed)
            }
        }
        for att in meta.calendarAttendees where att.status != .declined {
            if !SpeakerMemory.isPlaceholder(att.name),
               !names.contains(where: { SpeakerMemory.namesMatch($0, att.name) }) {
                names.append(att.name)
            }
        }

        let builtMoments = KeyMomentsBuilder.build(
            meta: meta,
            summary: summary,
            transcript: transcript,
            notes: notes,
            speakers: speakers,
            saved: savedMoments
        )

        return MeetingSnapshot(
            folder: folder,
            meta: meta,
            speakers: speakers,
            summary: summary,
            notes: notes,
            participantNames: names,
            talkSecondsBySpeaker: talkSeconds,
            sampleQuoteBySpeaker: sampleQuotes,
            moments: builtMoments
        )
    }
}

/// One recorded conversation involving a specific person.
public struct PersonConversation: Equatable, Sendable, Identifiable {
    public var folder: MeetingFolder
    public var title: String
    public var date: Date
    public var durationSeconds: Double
    public var personTalkSeconds: Double
    public var sampleQuote: String?
    public var decisions: [SummaryPoint]
    public var summaryHighlights: [SummaryPoint]

    public var id: String { folder.id }

    public init(folder: MeetingFolder, title: String, date: Date, durationSeconds: Double,
                personTalkSeconds: Double, sampleQuote: String?, decisions: [SummaryPoint],
                summaryHighlights: [SummaryPoint]) {
        self.folder = folder
        self.title = title
        self.date = date
        self.durationSeconds = durationSeconds
        self.personTalkSeconds = personTalkSeconds
        self.sampleQuote = sampleQuote
        self.decisions = decisions
        self.summaryHighlights = summaryHighlights
    }
}

/// Complete, UI-ready view of one person combining `people.json`, `voiceprints.json`, meetings, and calendar.
public struct PersonSummary: Equatable, Sendable, Identifiable {
    public var profile: PersonProfile
    public var hasVoiceprint: Bool
    public var voiceSampleSeconds: Double
    public var conversations: [PersonConversation]
    public var totalTalkSeconds: Double
    public var lastMetDate: Date?
    public var upcomingMeetings: [CalendarMeeting]
    public var theirOpenCommitments: [CommitmentItem]
    public var yourOpenCommitments: [CommitmentItem]

    public var id: String { profile.id }
    public var meetingsCount: Int { conversations.count }
    public var nextMeeting: CalendarMeeting? { upcomingMeetings.first }
    public var openCommitmentsCount: Int { theirOpenCommitments.count + yourOpenCommitments.count }
}

public enum PeopleDirectory {
    /// Builds the unified People directory from explicit profiles, saved voiceprints, recorded meetings, and calendar events.
    public static func build(store: PeopleStore,
                             memory: SpeakerMemory,
                             snapshots: [MeetingSnapshot],
                             calendarEvents: [CalendarMeeting],
                             recorderName: String = "",
                             now: Date = Date()) -> [PersonSummary] {
        var working = store
        let myName = recorderName.trimmingCharacters(in: .whitespacesAndNewlines)

        // Ensure every voiceprint in SpeakerMemory and every named speaker in meetings appears as a Person!
        for voice in memory.voices {
            if !myName.isEmpty, voice.name.caseInsensitiveCompare(myName) == .orderedSame { continue }
            _ = working.upsert(name: voice.name, now: voice.updated)
        }
        for snap in snapshots {
            for att in snap.meta.calendarAttendees where att.status != .declined {
                if !myName.isEmpty, att.name.caseInsensitiveCompare(myName) == .orderedSame { continue }
                _ = working.upsert(name: att.name, email: att.email, organization: att.inferredOrganization, now: snap.meta.startTime)
            }
            for (_, speakerName) in snap.speakers.names {
                if !myName.isEmpty, speakerName.caseInsensitiveCompare(myName) == .orderedSame { continue }
                _ = working.upsert(name: speakerName, now: snap.meta.startTime)
            }
        }
        _ = working.ingestCalendarEvents(calendarEvents, recorderName: myName, now: now)

        let allCommitments = CommitmentsRadar.build(from: snapshots, recorderName: myName, now: now)

        var summaries: [PersonSummary] = []
        for profile in working.profiles {
            let matchingVoices = memory.voices.filter { profile.matchesName($0.name) }
            let hasVoice = !matchingVoices.isEmpty
            let voiceSeconds = matchingVoices.reduce(0) { $0 + $1.seconds }

            var convs: [PersonConversation] = []
            var totalTalk = 0.0

            for snap in snapshots where snap.meta.status != .recording {
                let matchingSpeakerIDs = snap.speakers.names.compactMap { id, name in
                    profile.matchesName(name) ? id : nil
                }
                let onRecordedInvite = snap.meta.calendarAttendees.contains { profile.matchesAttendee($0) }
                let mentionedAsOwner = snap.summary?.actionItems.contains { item in
                    guard let owner = item.owner else { return false }
                    return profile.matchesName(owner)
                } ?? false

                guard !matchingSpeakerIDs.isEmpty || onRecordedInvite || mentionedAsOwner else { continue }

                let personSeconds = matchingSpeakerIDs.reduce(0.0) { $0 + (snap.talkSecondsBySpeaker[$1] ?? 0) }
                totalTalk += personSeconds
                let quote = matchingSpeakerIDs.compactMap { snap.sampleQuoteBySpeaker[$0] }.first
                convs.append(PersonConversation(
                    folder: snap.folder,
                    title: snap.meta.title,
                    date: snap.meta.startTime,
                    durationSeconds: snap.meta.effectiveDuration,
                    personTalkSeconds: personSeconds,
                    sampleQuote: quote,
                    decisions: snap.summary?.decisions ?? [],
                    summaryHighlights: Array((snap.summary?.summary ?? []).prefix(2))
                ))
            }
            convs.sort { $0.date > $1.date }

            let upcoming = calendarEvents
                .filter { MeetingReminder.hasOnlineMeetingPlatform($0) && $0.end >= now && $0.attendees.contains(where: { profile.matchesAttendee($0) }) }
                .sorted { $0.start < $1.start }

            let theirOpen = allCommitments.filter { item in
                guard !item.actionItem.done else { return false }
                if case .theirs(let owner) = item.direction {
                    return profile.matchesName(owner)
                }
                return false
            }

            let personMeetingIDs = Set(convs.map(\.id))
            let yourOpen = allCommitments.filter { item in
                guard !item.actionItem.done, item.direction == .mine else { return false }
                return personMeetingIDs.contains(item.meetingFolder.id)
            }

            summaries.append(PersonSummary(
                profile: profile,
                hasVoiceprint: hasVoice,
                voiceSampleSeconds: voiceSeconds,
                conversations: convs,
                totalTalkSeconds: totalTalk,
                lastMetDate: convs.first?.date,
                upcomingMeetings: upcoming,
                theirOpenCommitments: theirOpen,
                yourOpenCommitments: yourOpen
            ))
        }

        // Default ordering: people you've recorded most recently first, then upcoming today/soon, then alphabetical.
        summaries.sort { a, b in
            if let la = a.lastMetDate, let lb = b.lastMetDate, la != lb { return la > lb }
            if a.lastMetDate != nil && b.lastMetDate == nil { return true }
            if a.lastMetDate == nil && b.lastMetDate != nil { return false }
            if let na = a.nextMeeting?.start, let nb = b.nextMeeting?.start, na != nb { return na < nb }
            if a.nextMeeting != nil && b.nextMeeting == nil { return true }
            if a.nextMeeting == nil && b.nextMeeting != nil { return false }
            return a.profile.name.localizedCaseInsensitiveCompare(b.profile.name) == .orderedAscending
        }
        return summaries
    }

    /// Context string summarizing known participants' roles & notes to enrich meeting summarization.
    public static func summaryContext(for speakers: SpeakerNames,
                                      calendarAttendees: [CalendarAttendee],
                                      store: PeopleStore) -> String {
        var matched: [PersonProfile] = []
        func include(_ p: PersonProfile) {
            if !matched.contains(where: { $0.id == p.id }) { matched.append(p) }
        }
        for (_, name) in speakers.names {
            if let p = store.find(named: name) { include(p) }
        }
        for att in calendarAttendees where att.status != .declined {
            if let p = store.find(named: att.name, email: att.email) { include(p) }
        }
        var lines: [String] = []
        for p in matched {
            var details: [String] = []
            if let role = p.role, !role.isEmpty { details.append(role) }
            if let org = p.organization, !org.isEmpty { details.append("at \(org)") }
            let note = p.notes.trimmingCharacters(in: .whitespacesAndNewlines)
            if !note.isEmpty { details.append(note) }
            if !details.isEmpty {
                lines.append("\(p.name): \(details.joined(separator: ", "))")
            }
        }
        return lines.joined(separator: " | ")
    }
}

/// Quick-assign invitee helpers for unnamed speakers in `SpeakerNamingSection`.
public enum CalendarSpeakerHints {
    /// Calendar invitees not yet assigned to any speaker in `existing`, so the user can assign a voice in 1 click.
    public static func unassignedInvitees(attendees: [CalendarAttendee],
                                          existing: SpeakerNames,
                                          recorderName: String = "") -> [String] {
        let myName = recorderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let assigned = existing.names.values.filter { !SpeakerMemory.isPlaceholder($0) }
        var out: [String] = []
        for att in attendees where att.status != .declined {
            let candidate = att.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !candidate.isEmpty, !SpeakerMemory.isPlaceholder(candidate) else { continue }
            if !myName.isEmpty, SpeakerMemory.namesMatch(candidate, myName) { continue }
            if assigned.contains(where: { SpeakerMemory.namesMatch($0, candidate) }) { continue }
            if !out.contains(where: { SpeakerMemory.namesMatch($0, candidate) }) {
                out.append(candidate)
            }
        }
        return out
    }
}
