import Foundation

/// One visual "Key Moment" tile card for a meeting: high-level takeaway + verbatim quote + playable audio window.
public struct KeyMoment: Codable, Equatable, Sendable, Identifiable, Hashable {
    public enum Kind: String, Codable, Sendable, CaseIterable, Hashable {
        case pinned
        case decision
        case commitment
        case takeaway
        case question

        public var label: String {
            switch self {
            case .pinned: "Pinned"
            case .decision: "Decision"
            case .commitment: "Commitment"
            case .takeaway: "Key Point"
            case .question: "Open Question"
            }
        }

        public var symbol: String {
            switch self {
            case .pinned: "pin.fill"
            case .decision: "checkmark.seal.fill"
            case .commitment: "arrow.right.circle.fill"
            case .takeaway: "sparkles"
            case .question: "questionmark.circle.fill"
            }
        }
    }

    public var id: String
    public var kind: Kind
    public var title: String
    public var quote: String
    public var speakerID: String?
    public var speakerName: String?
    public var startTime: Double
    public var endTime: Double
    public var isStarred: Bool
    public var ownerBadge: String?

    public var clipDuration: Double { max(1, endTime - startTime) }

    public init(id: String,
                kind: Kind,
                title: String,
                quote: String = "",
                speakerID: String? = nil,
                speakerName: String? = nil,
                startTime: Double,
                endTime: Double,
                isStarred: Bool = false,
                ownerBadge: String? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.quote = quote
        self.speakerID = speakerID
        self.speakerName = speakerName
        self.startTime = max(0, startTime)
        self.endTime = max(self.startTime + 2, endTime)
        self.isStarred = isStarred
        self.ownerBadge = ownerBadge
    }

    /// Clean Markdown quote card for pasting into Slack, Notion, docs, or PRs.
    public func markdownCard(meetingTitle: String, meetingDate: Date) -> String {
        var lines: [String] = []
        lines.append("**\(kind.label): \(title)**")
        if !quote.isEmpty {
            let attribution = speakerName.map { " — *\($0)*" } ?? ""
            lines.append("> \u{201C}\(quote)\u{201D}\(attribution) (`\(TimeFormat.clock(startTime))`)")
        } else {
            lines.append("*From \(meetingTitle) at `\(TimeFormat.clock(startTime))`*")
        }
        lines.append("*Source: \(meetingTitle) · \(meetingDate.formatted(date: .abbreviated, time: .omitted))*")
        return lines.joined(separator: "\n")
    }
}

/// User-created moments and tile customizations saved in `<meeting>/moments.json`.
public struct SavedMoments: Codable, Equatable, Sendable {
    public struct CustomMoment: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var kind: KeyMoment.Kind
        public var title: String
        public var startTime: Double
        public var endTime: Double?

        public init(id: String = UUID().uuidString,
                    kind: KeyMoment.Kind = .pinned,
                    title: String,
                    startTime: Double,
                    endTime: Double? = nil) {
            self.id = id
            self.kind = kind
            self.title = title
            self.startTime = max(0, startTime)
            self.endTime = endTime
        }
    }

    public var custom: [CustomMoment]
    public var starredIDs: Set<String>
    public var hiddenIDs: Set<String>
    public var renamedTitles: [String: String]

    public init(custom: [CustomMoment] = [],
                starredIDs: Set<String> = [],
                hiddenIDs: Set<String> = [],
                renamedTitles: [String: String] = [:]) {
        self.custom = custom
        self.starredIDs = starredIDs
        self.hiddenIDs = hiddenIDs
        self.renamedTitles = renamedTitles
    }
}

public struct MomentsFile: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public func load() -> SavedMoments {
        guard FileManager.default.fileExists(atPath: url.path),
              let loaded = try? JSONCoding.read(SavedMoments.self, from: url) else {
            return SavedMoments()
        }
        return loaded
    }

    public func save(_ moments: SavedMoments) throws {
        try JSONCoding.write(moments, to: url)
    }
}

/// Cross-meeting moment entry for the global Moments tab.
public struct GlobalMomentItem: Equatable, Sendable, Identifiable {
    public var folder: MeetingFolder
    public var meetingTitle: String
    public var meetingDate: Date
    public var collectionID: String?
    public var hasAudio: Bool
    public var moment: KeyMoment

    public var id: String { "\(folder.id)::\(moment.id)" }

    public init(folder: MeetingFolder,
                meetingTitle: String,
                meetingDate: Date,
                collectionID: String?,
                hasAudio: Bool,
                moment: KeyMoment) {
        self.folder = folder
        self.meetingTitle = meetingTitle
        self.meetingDate = meetingDate
        self.collectionID = collectionID
        self.hasAudio = hasAudio
        self.moment = moment
    }
}

public enum KeyMomentsBuilder {
    /// Synthesizes high-signal Key Moment tiles from custom moments, live notes/bookmarks,
    /// summary decisions/commitments/points, and transcript quotes.
    public static func build(meta: MeetingMeta,
                             summary: MeetingSummary?,
                             transcript: Transcript?,
                             notes: [MeetingNote],
                             speakers: SpeakerNames,
                             saved: SavedMoments = SavedMoments()) -> [KeyMoment] {
        let segments = transcript?.segments ?? []
        let meetingDuration = max(meta.effectiveDuration, segments.last?.end ?? 0)
        var rawMoments: [KeyMoment] = []

        func resolveContext(around targetTime: Double?, matchingText: String) -> (start: Double, end: Double, quote: String, speakerID: String?, speakerName: String?) {
            if !segments.isEmpty {
                let bestIndex: Int?
                if let t = targetTime {
                    // Find segment containing `t` or nearest within 15s.
                    if let containing = segments.indices.first(where: { segments[$0].start - 1.5 <= t && t <= segments[$0].end + 1.5 }) {
                        bestIndex = containing
                    } else {
                        let nearest = segments.indices.min {
                            abs(segments[$0].start - t) < abs(segments[$1].start - t)
                        }
                        if let nearest, abs(segments[nearest].start - t) <= 20 {
                            bestIndex = nearest
                        } else {
                            bestIndex = nil
                        }
                    }
                } else if !matchingText.isEmpty {
                    bestIndex = segments.indices
                        .map { ($0, SummaryParser.wordOverlap(segments[$0].text, matchingText)) }
                        .filter { $0.1 >= 0.25 }
                        .max { $0.1 < $1.1 }?
                        .0
                } else {
                    bestIndex = nil
                }

                if let idx = bestIndex {
                    let primary = segments[idx]
                    let clipStart = primary.start
                    var clipEnd = primary.end
                    var quoteText = primary.text.trimmingCharacters(in: .whitespacesAndNewlines)

                    // Include immediate follow-up turn if the primary turn is brief (< 5s), capturing Q&A context.
                    if clipEnd - clipStart < 5.5, idx + 1 < segments.count,
                       segments[idx + 1].start - primary.end <= 3.0 {
                        clipEnd = min(primary.start + 16, segments[idx + 1].end)
                        if quoteText.count < 70 {
                            let nextText = segments[idx + 1].text.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !nextText.isEmpty {
                                quoteText += " — " + nextText
                            }
                        }
                    }
                    clipEnd = min(max(clipStart + 4, clipEnd), clipStart + 18)
                    if meetingDuration > 0 { clipEnd = min(clipEnd, meetingDuration) }
                    return (
                        start: max(0, clipStart),
                        end: max(clipStart + 2, clipEnd),
                        quote: truncateQuote(quoteText),
                        speakerID: primary.speaker,
                        speakerName: speakers.displayName(for: primary.speaker)
                    )
                }
            }

            let fallbackStart = max(0, (targetTime ?? 0) - 2)
            let fallbackEnd = meetingDuration > 0 ? min(meetingDuration, fallbackStart + 10) : (fallbackStart + 10)
            return (fallbackStart, max(fallbackStart + 2, fallbackEnd), "", nil, nil)
        }

        // 1. User's custom saved moments (`moments.json`).
        for item in saved.custom {
            let id = "custom:\(item.id)"
            guard !saved.hiddenIDs.contains(id) else { continue }
            let ctx = resolveContext(around: item.startTime, matchingText: item.title)
            let headline = saved.renamedTitles[id] ?? item.title
            rawMoments.append(KeyMoment(
                id: id,
                kind: item.kind,
                title: headline.isEmpty ? "Pinned moment" : headline,
                quote: ctx.quote,
                speakerID: ctx.speakerID,
                speakerName: ctx.speakerName,
                startTime: item.startTime,
                endTime: item.endTime ?? ctx.end,
                isStarred: true
            ))
        }

        // 2. Live notes & bookmarks (`notes.json`).
        for note in notes {
            let id = "note:\(note.id.uuidString)"
            guard !saved.hiddenIDs.contains(id) else { continue }
            let noteSummaryCtx = summary?.yourNotes.first { abs($0.t - note.t) < 2.0 }?.context ?? ""
            let ctx = resolveContext(around: note.t, matchingText: note.text)
            let defaultTitle: String
            if !note.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                defaultTitle = note.text.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if !noteSummaryCtx.isEmpty {
                defaultTitle = firstSentence(of: noteSummaryCtx, maxChars: 76)
            } else if !ctx.quote.isEmpty {
                defaultTitle = firstSentence(of: ctx.quote, maxChars: 72)
            } else {
                defaultTitle = "Marked moment at \(TimeFormat.clock(note.t))"
            }
            let quote = !ctx.quote.isEmpty ? ctx.quote : noteSummaryCtx
            rawMoments.append(KeyMoment(
                id: id,
                kind: note.kind == .action ? .commitment : .pinned,
                title: saved.renamedTitles[id] ?? defaultTitle,
                quote: quote,
                speakerID: ctx.speakerID,
                speakerName: ctx.speakerName,
                startTime: ctx.start,
                endTime: ctx.end,
                isStarred: true,
                ownerBadge: note.kind == .action ? "You" : nil
            ))
        }

        // Helper to avoid crowding two auto moments on the exact same 10-second exchange.
        func overlapsExisting(_ t: Double, window: Double = 10) -> Bool {
            rawMoments.contains { abs($0.startTime - t) < window }
        }

        // 3. Summary Decisions (`✓ Decision`) — never suppressed by a nearby user note.
        if let summary {
            for dec in summary.decisions {
                let ctx = resolveContext(around: dec.t, matchingText: dec.text)
                guard dec.t != nil || !ctx.quote.isEmpty else { continue }
                let id = "decision:\(Int(ctx.start)):\( String(dec.text.prefix(24)).lowercased() )"
                let duplicateDecision = rawMoments.contains { $0.kind == .decision && abs($0.startTime - ctx.start) < 5 }
                guard !saved.hiddenIDs.contains(id), !duplicateDecision else { continue }
                rawMoments.append(KeyMoment(
                    id: id,
                    kind: .decision,
                    title: saved.renamedTitles[id] ?? dec.text,
                    quote: ctx.quote,
                    speakerID: ctx.speakerID,
                    speakerName: ctx.speakerName,
                    startTime: ctx.start,
                    endTime: ctx.end,
                    isStarred: saved.starredIDs.contains(id)
                ))
            }

            // 4. Summary Action Items with timestamps or matched quotes (`→ Commitment`).
            for act in summary.actionItems {
                let ctx = resolveContext(around: act.t, matchingText: act.task)
                guard act.t != nil || !ctx.quote.isEmpty else { continue }
                let id = "action:\(Int(ctx.start)):\(String(act.task.prefix(24)).lowercased())"
                guard !saved.hiddenIDs.contains(id), !overlapsExisting(ctx.start, window: 9) else { continue }
                let badge = [act.owner, act.due].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                rawMoments.append(KeyMoment(
                    id: id,
                    kind: .commitment,
                    title: saved.renamedTitles[id] ?? act.task,
                    quote: ctx.quote,
                    speakerID: ctx.speakerID,
                    speakerName: ctx.speakerName,
                    startTime: ctx.start,
                    endTime: ctx.end,
                    isStarred: saved.starredIDs.contains(id),
                    ownerBadge: badge.isEmpty ? nil : badge
                ))
            }

            // 5. High-level Summary Takeaways (`★ Key Point`).
            for point in summary.summary {
                let ctx = resolveContext(around: point.t, matchingText: point.text)
                let id = "takeaway:\(Int(ctx.start)):\(String(point.text.prefix(24)).lowercased())"
                guard !saved.hiddenIDs.contains(id) else { continue }
                if point.t != nil, overlapsExisting(ctx.start, window: 10) { continue }
                rawMoments.append(KeyMoment(
                    id: id,
                    kind: .takeaway,
                    title: saved.renamedTitles[id] ?? point.text,
                    quote: ctx.quote,
                    speakerID: ctx.speakerID,
                    speakerName: ctx.speakerName,
                    startTime: ctx.start,
                    endTime: ctx.end,
                    isStarred: saved.starredIDs.contains(id)
                ))
            }

            // 6. Open Questions (`? Open Question`).
            for q in summary.openQuestions.prefix(2) {
                let ctx = resolveContext(around: q.t, matchingText: q.text)
                guard q.t != nil || !ctx.quote.isEmpty else { continue }
                let id = "question:\(Int(ctx.start)):\(String(q.text.prefix(24)).lowercased())"
                guard !saved.hiddenIDs.contains(id), !overlapsExisting(ctx.start, window: 10) else { continue }
                rawMoments.append(KeyMoment(
                    id: id,
                    kind: .question,
                    title: saved.renamedTitles[id] ?? q.text,
                    quote: ctx.quote,
                    speakerID: ctx.speakerID,
                    speakerName: ctx.speakerName,
                    startTime: ctx.start,
                    endTime: ctx.end,
                    isStarred: saved.starredIDs.contains(id)
                ))
            }
        } else if !segments.isEmpty {
            // Transcript-only fallback before summary finishes: surface clear decision/commitment/metric turns.
            let cues: [(KeyMoment.Kind, [String])] = [
                (.decision, ["agreed", "decided", "let's go with", "we'll ship", "move the deadline"]),
                (.commitment, ["i'll ", "i will ", "can you ", "by friday", "by wednesday", "take a look"]),
                (.question, ["?"]),
            ]
            for seg in segments where seg.text.count >= 28 {
                if rawMoments.count >= 6 { break }
                if overlapsExisting(seg.start, window: 15) { continue }
                let lower = seg.text.lowercased()
                guard let matchedKind = cues.first(where: { $0.1.contains(where: lower.contains) })?.0 else { continue }
                let id = "transcript:\(Int(seg.start))"
                guard !saved.hiddenIDs.contains(id) else { continue }
                rawMoments.append(KeyMoment(
                    id: id,
                    kind: matchedKind,
                    title: saved.renamedTitles[id] ?? firstSentence(of: seg.text, maxChars: 72),
                    quote: truncateQuote(seg.text),
                    speakerID: seg.speaker,
                    speakerName: speakers.displayName(for: seg.speaker),
                    startTime: seg.start,
                    endTime: min(seg.start + 14, max(seg.start + 4, seg.end)),
                    isStarred: saved.starredIDs.contains(id)
                ))
            }
        }

        // Apply explicit star overrides and cap unstarred auto moments so the deck stays scannable.
        var starred = rawMoments.filter(\.isStarred)
        for i in starred.indices where saved.starredIDs.contains(starred[i].id) {
            starred[i].isStarred = true
        }
        let auto = rawMoments.filter { !$0.isStarred }
        let combined = (starred + Array(auto.prefix(max(2, 8 - starred.count))))
            .sorted { $0.startTime < $1.startTime }
        return combined
    }

    private static func truncateQuote(_ text: String, maxChars: Int = 145) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.count > maxChars else { return collapsed }
        let prefix = collapsed.prefix(maxChars)
        if let space = prefix.lastIndex(of: " ") {
            return String(prefix[..<space]) + "…"
        }
        return String(prefix) + "…"
    }

    private static func firstSentence(of text: String, maxChars: Int) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if let end = collapsed.firstIndex(where: { $0 == "." || $0 == "!" || $0 == "?" }) {
            let sentence = String(collapsed[...end])
            if sentence.count <= maxChars { return sentence }
        }
        return truncateQuote(collapsed, maxChars: maxChars)
    }
}

// MARK: - Conversation Pulse & Highlight Reel Plan

/// Visual speaker balance and timeline slices for the Conversation Pulse strip in Meeting Detail.
public struct ConversationPulse: Equatable, Sendable {
    public struct SpeakerShare: Equatable, Sendable, Identifiable {
        public var speakerID: String
        public var name: String
        public var seconds: Double
        public var fraction: Double
        public var words: Int
        public var turns: Int
        public var isYou: Bool
        public var hueIndex: Int

        public var id: String { speakerID }
    }

    public struct TimelineSlice: Equatable, Sendable, Identifiable {
        public var startFraction: Double
        public var endFraction: Double
        public var speakerID: String
        public var isYou: Bool
        public var hueIndex: Int

        public var id: String { "\(speakerID)-\(startFraction)" }
    }

    public var duration: Double
    public var shares: [SpeakerShare]
    public var slices: [TimelineSlice]
    public var turnSwitches: Int
    public var paceLabel: String

    public static let empty = ConversationPulse(duration: 0, shares: [], slices: [], turnSwitches: 0, paceLabel: "")

    public static func compute(transcript: Transcript?,
                               speakers: SpeakerNames,
                               metaDuration: Double) -> ConversationPulse {
        guard let transcript, !transcript.segments.isEmpty else { return .empty }
        let duration = max(metaDuration, transcript.segments.map(\.end).max() ?? 1, 1)

        var secondsBySpeaker: [String: Double] = [:]
        var wordsBySpeaker: [String: Int] = [:]
        var turnsBySpeaker: [String: Int] = [:]
        var order: [String] = []
        var switches = 0
        var lastSpeaker: String?

        for seg in transcript.segments {
            let dur = max(0.2, seg.end - seg.start)
            if !order.contains(seg.speaker) { order.append(seg.speaker) }
            secondsBySpeaker[seg.speaker, default: 0] += dur
            wordsBySpeaker[seg.speaker, default: 0] += Transcript.words(in: seg.text)
            if lastSpeaker != seg.speaker {
                turnsBySpeaker[seg.speaker, default: 0] += 1
                if lastSpeaker != nil { switches += 1 }
                lastSpeaker = seg.speaker
            }
        }

        let totalSpeech = max(secondsBySpeaker.values.reduce(0, +), 0.1)
        var shares: [SpeakerShare] = order.map { id in
            let name = speakers.displayName(for: id)
            let isYou = id == SpeakerNames.youID
            let secs = secondsBySpeaker[id] ?? 0
            return SpeakerShare(
                speakerID: id,
                name: name,
                seconds: secs,
                fraction: secs / totalSpeech,
                words: wordsBySpeaker[id] ?? 0,
                turns: turnsBySpeaker[id] ?? 0,
                isYou: isYou,
                hueIndex: isYou ? 0 : PersonProfile.stableHueIndex(for: name)
            )
        }
        shares.sort { a, b in
            if a.seconds != b.seconds { return a.seconds > b.seconds }
            return a.isYou && !b.isYou
        }

        let hueBySpeaker = Dictionary(uniqueKeysWithValues: shares.map { ($0.speakerID, $0.hueIndex) })
        var rawSlices: [TimelineSlice] = []
        for seg in transcript.segments {
            let s = min(max(seg.start / duration, 0), 1)
            let e = min(max(seg.end / duration, s + 0.004), 1)
            if let last = rawSlices.last, last.speakerID == seg.speaker, s - last.endFraction <= 0.012 {
                rawSlices[rawSlices.count - 1].endFraction = max(last.endFraction, e)
            } else {
                rawSlices.append(TimelineSlice(
                    startFraction: s,
                    endFraction: e,
                    speakerID: seg.speaker,
                    isYou: seg.speaker == SpeakerNames.youID,
                    hueIndex: hueBySpeaker[seg.speaker] ?? 1
                ))
            }
        }

        let youShare = shares.first(where: \.isYou)?.fraction ?? 0
        let topShare = shares.first?.fraction ?? 0
        let pace: String
        if shares.count <= 1 {
            pace = "Solo voice note"
        } else if topShare >= 0.72 {
            let leader = shares.first?.name ?? "One speaker"
            pace = "Mostly \(leader) (\(Int((topShare * 100).rounded()))%)"
        } else if youShare <= 0.28 {
            pace = "Listener mode · You \(Int((youShare * 100).rounded()))%"
        } else {
            pace = "Balanced dialogue · \(switches + 1) turns"
        }

        return ConversationPulse(
            duration: duration,
            shares: shares,
            slices: rawSlices,
            turnSwitches: switches,
            paceLabel: pace
        )
    }
}

/// Ordered audio excerpt queue for playing a meeting's Key Moments back-to-back as a Highlight Reel.
public struct HighlightReelPlan: Equatable, Sendable {
    public struct Stop: Equatable, Sendable, Identifiable {
        public var momentID: String
        public var title: String
        public var startTime: Double
        public var endTime: Double

        public var id: String { momentID }
        public var duration: Double { max(1, endTime - startTime) }

        public init(momentID: String, title: String, startTime: Double, endTime: Double) {
            self.momentID = momentID
            self.title = title
            self.startTime = startTime
            self.endTime = endTime
        }
    }

    public var stops: [Stop]
    public var totalSeconds: Double { stops.reduce(0) { $0 + $1.duration } }

    public init(stops: [Stop]) {
        self.stops = stops
    }

    public static func build(from moments: [KeyMoment]) -> HighlightReelPlan {
        let stops = moments.map {
            Stop(momentID: $0.id, title: $0.title, startTime: $0.startTime, endTime: $0.endTime)
        }
        return HighlightReelPlan(stops: stops)
    }
}
