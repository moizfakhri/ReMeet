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
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let email = email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !email.isEmpty,
           let byEmail = profiles.first(where: { $0.email?.lowercased() == email }) {
            return byEmail
        }
        guard !trimmed.isEmpty, !SpeakerMemory.isPlaceholder(trimmed) else { return nil }
        let canon = PersonName.parse(trimmed).canonicalDisplayName
        if let exact = profiles.first(where: {
            $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
                || $0.name.caseInsensitiveCompare(canon) == .orderedSame
                || $0.aliases.contains(where: {
                    $0.caseInsensitiveCompare(trimmed) == .orderedSame
                        || $0.caseInsensitiveCompare(canon) == .orderedSame
                })
        }) {
            return exact
        }
        let nameMatches = profiles.filter { $0.matchesName(trimmed) }
        if nameMatches.count == 1 { return nameMatches[0] }
        if nameMatches.count > 1 { return nameMatches.first }
        let prefixMatches = profiles.filter {
            SpeakerMemory.namesPrefixMatch($0.name, trimmed)
                || $0.aliases.contains { SpeakerMemory.namesPrefixMatch($0, trimmed) }
        }
        return prefixMatches.count == 1 ? prefixMatches[0] : nil
    }

    private static func appendAlias(_ candidate: String, to aliases: inout [String], excluding displayName: String) {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !SpeakerMemory.isPlaceholder(trimmed) else { return }
        guard trimmed.caseInsensitiveCompare(displayName) != .orderedSame else { return }
        if !aliases.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            aliases.append(trimmed)
        }
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
        let parsed = PersonName.parse(trimmed)
        let canonical = parsed.canonicalDisplayName.isEmpty ? trimmed : parsed.canonicalDisplayName

        let cleanEmail = email?.trimmingCharacters(in: .whitespacesAndNewlines)

        let matchedIndex: Int? = {
            if let e = cleanEmail?.lowercased(), !e.isEmpty,
               let idx = profiles.firstIndex(where: { $0.email?.lowercased() == e }) {
                return idx
            }
            if let idx = profiles.firstIndex(where: {
                $0.name.compare(trimmed, options: .caseInsensitive) == .orderedSame
                    || $0.name.compare(canonical, options: .caseInsensitive) == .orderedSame
                    || $0.aliases.contains(where: {
                        $0.compare(trimmed, options: .caseInsensitive) == .orderedSame
                            || $0.compare(canonical, options: .caseInsensitive) == .orderedSame
                    })
            }) {
                return idx
            }
            let nameIndices = profiles.indices.filter { profiles[$0].matchesName(trimmed) }
            if nameIndices.count == 1 { return nameIndices[0] }
            let prefixIndices = profiles.indices.filter { idx in
                SpeakerMemory.namesPrefixMatch(profiles[idx].name, trimmed)
                    || profiles[idx].aliases.contains { SpeakerMemory.namesPrefixMatch($0, trimmed) }
            }
            if prefixIndices.count == 1 { return prefixIndices[0] }
            return nil
        }()

        if let index = matchedIndex {
            var existing = profiles[index]
            let oldName = existing.name
            let mergedName = PersonName.preferredMergedDisplayName(existing: oldName, incoming: canonical)
            existing.name = mergedName
            existing.aliases.removeAll { $0.caseInsensitiveCompare(mergedName) == .orderedSame }
            Self.appendAlias(oldName, to: &existing.aliases, excluding: mergedName)
            Self.appendAlias(trimmed, to: &existing.aliases, excluding: mergedName)
            Self.appendAlias(canonical, to: &existing.aliases, excluding: mergedName)

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

        var initialAliases: [String] = []
        Self.appendAlias(trimmed, to: &initialAliases, excluding: canonical)
        let created = PersonProfile(name: canonical, aliases: initialAliases, email: cleanEmail, role: role,
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
        let oldTargetName = target.name
        let mergedName = PersonName.preferredMergedDisplayName(existing: oldTargetName, incoming: source.name)
        target.name = mergedName
        target.aliases.removeAll { $0.caseInsensitiveCompare(mergedName) == .orderedSame }
        Self.appendAlias(oldTargetName, to: &target.aliases, excluding: mergedName)
        for candidate in [source.name] + source.aliases {
            Self.appendAlias(candidate, to: &target.aliases, excluding: mergedName)
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

    /// Consolidates duplicate profiles created by `"Last, First"` calendar attendees vs manual speaker names
    /// (e.g. `"Dr. Patel"` + `"Patel, Priya R"` -> `"Dr. Priya R Patel"`).
    @discardableResult
    public mutating func consolidateDuplicates(now: Date = Date()) -> Bool {
        let before = profiles

        // 1. Normalize any raw "Last, First" or ALL-CAPS display names already stored in people.json.
        for idx in profiles.indices {
            let raw = profiles[idx].name.trimmingCharacters(in: .whitespacesAndNewlines)
            let canonical = PersonName.parse(raw).canonicalDisplayName
            if !canonical.isEmpty, canonical != raw {
                profiles[idx].name = canonical
                profiles[idx].aliases.removeAll { $0.caseInsensitiveCompare(canonical) == .orderedSame }
                Self.appendAlias(raw, to: &profiles[idx].aliases, excluding: canonical)
                profiles[idx].updatedAt = now
            }
        }

        // 2. Iteratively merge unambiguous duplicates until fixed point.
        var didMerge = true
        while didMerge {
            didMerge = false
            outer: for i in profiles.indices {
                for j in profiles.indices where j > i {
                    let a = profiles[i]
                    let b = profiles[j]
                    if shouldAutoMerge(a, b) {
                        let (sourceID, targetID) = preferredMergeDirection(a, b)
                        _ = merge(sourceID: sourceID, into: targetID, now: now)
                        didMerge = true
                        break outer
                    }
                }
            }
        }

        return profiles != before
    }

    /// Ambiguous possible duplicates for a profile (e.g. `"David"` when multiple `"David ..."` profiles exist),
    /// surfaced as a 1-click merge suggestion in the People detail view.
    public func possibleDuplicates(for profileID: String) -> [PersonProfile] {
        guard let target = profiles.first(where: { $0.id == profileID }) else { return [] }
        return profiles.filter { other in
            guard other.id != target.id else { return false }
            return target.matchesName(other.name)
                || other.matchesName(target.name)
                || SpeakerMemory.namesPrefixMatch(target.name, other.name)
        }
    }

    private func shouldAutoMerge(_ a: PersonProfile, _ b: PersonProfile) -> Bool {
        if let ea = a.email?.lowercased(), !ea.isEmpty,
           let eb = b.email?.lowercased(), !eb.isEmpty, ea == eb {
            return true
        }
        let pa = PersonName.parse(a.name)
        let pb = PersonName.parse(b.name)
        let aFull = !pa.first.isEmpty && !pa.last.isEmpty
        let bFull = !pb.first.isEmpty && !pb.last.isEmpty

        if aFull && bFull {
            let af = PersonName.normalizedToken(pa.first)
            let al = PersonName.normalizedToken(pa.last)
            let bf = PersonName.normalizedToken(pb.first)
            let bl = PersonName.normalizedToken(pb.last)
            return af == bf && al == bl
        }

        // One short/honorific profile and one fuller profile: auto-merge ONLY if globally unambiguous.
        if aFull != bFull {
            let short = aFull ? b : a
            let full = aFull ? a : b
            let fullerProfiles = profiles.filter {
                let p = PersonName.parse($0.name)
                return !p.first.isEmpty && !p.last.isEmpty
            }
            let exactShortMatches = fullerProfiles.filter { $0.matchesName(short.name) || short.matchesName($0.name) }
            if exactShortMatches.count == 1, exactShortMatches[0].id == full.id {
                return true
            }
            if exactShortMatches.isEmpty {
                let prefixMatches = fullerProfiles.filter {
                    SpeakerMemory.namesPrefixMatch($0.name, short.name)
                        || $0.aliases.contains { SpeakerMemory.namesPrefixMatch($0, short.name) }
                }
                if prefixMatches.count == 1, prefixMatches[0].id == full.id {
                    return true
                }
            }
            return false
        }

        return a.name.caseInsensitiveCompare(b.name) == .orderedSame
            || a.aliases.contains(where: { $0.caseInsensitiveCompare(b.name) == .orderedSame })
            || b.aliases.contains(where: { $0.caseInsensitiveCompare(a.name) == .orderedSame })
    }

    private func preferredMergeDirection(_ a: PersonProfile, _ b: PersonProfile) -> (sourceID: String, targetID: String) {
        let pa = PersonName.parse(a.name)
        let pb = PersonName.parse(b.name)
        let aScore = ((!pa.first.isEmpty && !pa.last.isEmpty) ? 4 : 0) + (a.email != nil ? 2 : 0) + (a.notes.isEmpty ? 0 : 1)
        let bScore = ((!pb.first.isEmpty && !pb.last.isEmpty) ? 4 : 0) + (b.email != nil ? 2 : 0) + (b.notes.isEmpty ? 0 : 1)
        if bScore > aScore { return (a.id, b.id) }
        return (b.id, a.id)
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
        for (id, name) in speakers.names where id != SpeakerNames.youID {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !SpeakerMemory.isPlaceholder(trimmed),
               !names.contains(where: { SpeakerMemory.namesMatch($0, trimmed) }) {
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
            if !myName.isEmpty, SpeakerMemory.namesMatch(voice.name, myName) { continue }
            _ = working.upsert(name: voice.name, now: voice.updated)
        }
        for snap in snapshots {
            for att in snap.meta.calendarAttendees where att.status != .declined {
                if !myName.isEmpty, SpeakerMemory.namesMatch(att.name, myName) { continue }
                _ = working.upsert(name: att.name, email: att.email, organization: att.inferredOrganization, now: snap.meta.startTime)
            }
            for (speakerID, speakerName) in snap.speakers.names where speakerID != SpeakerNames.youID {
                if !myName.isEmpty, SpeakerMemory.namesMatch(speakerName, myName) { continue }
                _ = working.upsert(name: speakerName, now: snap.meta.startTime)
            }
        }
        _ = working.ingestCalendarEvents(calendarEvents, recorderName: myName, now: now)
        _ = working.consolidateDuplicates(now: now)

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
                    (id != SpeakerNames.youID && profile.matchesName(name)) ? id : nil
                }
                let onRecordedInvite = snap.meta.calendarAttendees.contains {
                    $0.status != .declined && profile.matchesAttendee($0)
                }
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
                                          recorderName: String = "",
                                          store: PeopleStore? = nil) -> [String] {
        let myName = recorderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let assigned = existing.names.values.filter { !SpeakerMemory.isPlaceholder($0) }
        var out: [String] = []
        for att in attendees where att.status != .declined {
            let raw = att.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty, !SpeakerMemory.isPlaceholder(raw) else { continue }
            let resolved = store?.find(named: raw, email: att.email)?.name
                ?? PersonName.parse(raw).canonicalDisplayName
            let candidate = resolved.isEmpty ? raw : resolved
            guard !SpeakerMemory.isPlaceholder(candidate) else { continue }
            if !myName.isEmpty, SpeakerMemory.namesMatch(candidate, myName) { continue }
            if assigned.contains(where: { SpeakerMemory.namesMatch($0, candidate) || SpeakerMemory.namesPrefixMatch($0, candidate) }) {
                continue
            }
            if !out.contains(where: { SpeakerMemory.namesMatch($0, candidate) }) {
                out.append(candidate)
            }
        }
        return out
    }
}
