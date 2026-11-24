import Foundation

/// A person ReMeet has heard before. The embedding is the diarizer's voice vector
/// (WeSpeaker, 256 numbers), kept next to the meetings folder in `voiceprints.json`.
public struct KnownVoice: Codable, Equatable, Sendable, Identifiable {
    public struct Contribution: Codable, Equatable, Sendable {
        public var key: String
        public var embedding: [Float]
        public var seconds: Double

        public init(key: String, embedding: [Float], seconds: Double) {
            self.key = key
            self.embedding = embedding
            self.seconds = seconds
        }
    }

    public var id: String
    public var name: String
    public var embedding: [Float]
    public var seconds: Double
    public var updated: Date
    public var contributions: [Contribution]?

    public init(id: String = UUID().uuidString,
                name: String,
                embedding: [Float],
                seconds: Double,
                updated: Date,
                contributions: [Contribution]? = nil) {
        self.id = id
        self.name = name
        self.embedding = embedding
        self.seconds = seconds
        self.updated = updated
        self.contributions = contributions
    }
}

/// A voiceprint the user can accept for one speaker. Accepting it is a separate step.
public struct VoiceSuggestion: Equatable, Sendable {
    public var speaker: String
    public var name: String
    public var score: Float
    /// True when this known voice also matches an attendee on the meeting's calendar invite.
    public var onInvite: Bool

    public init(speaker: String, name: String, score: Float, onInvite: Bool = false) {
        self.speaker = speaker
        self.name = name
        self.score = score
        self.onInvite = onInvite
    }
}

/// Names learned from meetings the user has labeled, matched to new diarization embeddings.
public struct SpeakerMemory: Codable, Equatable, Sendable {
    public var voices: [KnownVoice]

    /// Cosine similarity on L2-normalized embeddings. Same-speaker WeSpeaker scores on
    /// meeting audio usually sit above this; a lower bar mislabels people.
    public static let matchThreshold: Float = 0.62
    /// Lower threshold permitted ONLY when a saved voice is confirmed on this meeting's calendar invite.
    public static let inviteMatchThreshold: Float = 0.52
    /// The best match has to lead the runner-up by this much, so two close voices are left unnamed.
    public static let matchMargin: Float = 0.07
    public static let inviteMatchMargin: Float = 0.04
    public static let inviteRankBonus: Float = 0.05
    public static let maxVoices = 80

    public init(voices: [KnownVoice] = []) {
        self.voices = voices
    }

    public static func isPlaceholder(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        let lower = trimmed.lowercased()
        if lower == "you" || lower == "call" { return true }
        if lower.hasPrefix("speaker ") { return Int(lower.dropFirst("speaker ".count)) != nil }
        return false
    }

    public static func namesMatch(_ a: String, _ b: String) -> Bool {
        let na = a.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let nb = b.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !na.isEmpty, !nb.isEmpty else { return false }
        if na == nb { return true }
        // Match first-name voiceprint ("Priya") against full calendar name ("Priya Patel") when unambiguous.
        let aParts = na.split(whereSeparator: \.isWhitespace).map(String.init)
        let bParts = nb.split(whereSeparator: \.isWhitespace).map(String.init)
        if aParts.count == 1, let first = bParts.first, first == na, na.count >= 3 { return true }
        if bParts.count == 1, let first = aParts.first, first == nb, nb.count >= 3 { return true }
        return false
    }

    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var left = Float(0)
        var right = Float(0)
        for index in a.indices {
            dot += a[index] * b[index]
            left += a[index] * a[index]
            right += b[index] * b[index]
        }
        let denom = (left * right).squareRoot()
        guard denom > 0 else { return 0 }
        return dot / denom
    }

    public static func mean(_ vectors: [[Float]]) -> [Float]? {
        let usable = vectors.filter { !$0.isEmpty }
        guard let width = usable.first?.count else { return nil }
        let same = usable.filter { $0.count == width }
        guard !same.isEmpty else { return nil }
        var sum = [Float](repeating: 0, count: width)
        for vector in same {
            for index in sum.indices { sum[index] += vector[index] }
        }
        let count = Float(same.count)
        return sum.map { $0 / count }
    }

    /// Names worth offering for this meeting. Nothing is written. One saved voice is
    /// suggested for at most one speaker, and a speaker who already has a name is skipped.
    /// When `attendeeNames` are known from the calendar invite, saved voices who are actually
    /// invited receive a calibrated prior boost while keeping strict anti-mislabeling margins.
    public func suggestions(for embeddings: [String: [Float]],
                            existing: SpeakerNames,
                            attendeeNames: [String] = []) -> [VoiceSuggestion] {
        struct Candidate {
            var speaker: String
            var voice: Int
            var rawScore: Float
            var rankScore: Float
            var onInvite: Bool
        }
        let cleanInvitees = attendeeNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !Self.isPlaceholder($0) }

        func isInvited(_ voiceName: String) -> Bool {
            guard !cleanInvitees.isEmpty else { return false }
            let matches = cleanInvitees.filter { Self.namesMatch(voiceName, $0) }
            return matches.count == 1 || cleanInvitees.contains { $0.caseInsensitiveCompare(voiceName) == .orderedSame }
        }

        let invitedVoiceIndices = Set(voices.indices.filter { isInvited(voices[$0].name) })

        var candidates: [Candidate] = []
        for (speaker, vector) in embeddings where speaker != SpeakerNames.youID {
            if let name = existing.names[speaker], !Self.isPlaceholder(name) { continue }
            var scored: [(index: Int, raw: Float, effective: Float, invited: Bool)] = []
            for (index, voice) in voices.enumerated() {
                let raw = Self.cosine(vector, voice.embedding)
                let invited = invitedVoiceIndices.contains(index)
                let effective = raw + (invited ? Self.inviteRankBonus : 0)
                scored.append((index, raw, effective, invited))
            }
            guard let best = scored.max(by: { $0.effective < $1.effective }) else { continue }
            let threshold = best.invited ? Self.inviteMatchThreshold : Self.matchThreshold
            let margin = best.invited ? Self.inviteMatchMargin : Self.matchMargin
            guard best.raw >= threshold else { continue }
            let secondRaw = scored.filter { $0.index != best.index }.map(\.raw).max() ?? 0
            let secondEffective = scored.filter { $0.index != best.index }.map(\.effective).max() ?? 0
            guard (best.raw - secondRaw >= margin) || (best.invited && best.effective - secondEffective >= Self.matchMargin) else {
                continue
            }
            candidates.append(Candidate(speaker: speaker, voice: best.index,
                                        rawScore: best.raw, rankScore: best.effective, onInvite: best.invited))
        }
        candidates.sort { left, right in
            if left.rankScore != right.rankScore { return left.rankScore > right.rankScore }
            return left.speaker < right.speaker
        }
        var offered: [VoiceSuggestion] = []
        var usedSpeakers: Set<String> = []
        var usedVoices: Set<Int> = []
        for candidate in candidates where !usedSpeakers.contains(candidate.speaker) && !usedVoices.contains(candidate.voice) {
            usedSpeakers.insert(candidate.speaker)
            usedVoices.insert(candidate.voice)
            // Prefer the richer full name from the invite ("Priya Patel") if the voiceprint only stored "Priya",
            // or keep the user's saved voiceprint name when explicit.
            let savedName = voices[candidate.voice].name
            offered.append(VoiceSuggestion(speaker: candidate.speaker,
                                           name: savedName,
                                           score: candidate.rawScore,
                                           onInvite: candidate.onInvite))
        }
        return offered
    }

    /// Fills in display names for speaker ids that do not already have one. One saved voice
    /// is used at most once in a meeting. The pipeline does not call this; the meeting asks first.
    public func applying(to existing: SpeakerNames, embeddings: [String: [Float]],
                         attendeeNames: [String] = []) -> SpeakerNames {
        var names = existing
        for suggestion in suggestions(for: embeddings, existing: existing, attendeeNames: attendeeNames) {
            names.names[suggestion.speaker] = suggestion.name
        }
        return names
    }

    /// Top candidate matches (`>= 0.42` cosine similarity) ranked by calendar-invite boost,
    /// used in quick-pick speaker assignment menus when automatic matching stayed uncertain.
    public func rankedMatches(for embedding: [Float],
                              attendeeNames: [String] = [],
                              limit: Int = 3) -> [VoiceSuggestion] {
        guard !embedding.isEmpty else { return [] }
        let cleanInvitees = attendeeNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !Self.isPlaceholder($0) }
        func isInvited(_ voiceName: String) -> Bool {
            cleanInvitees.contains { Self.namesMatch(voiceName, $0) }
        }
        return voices.compactMap { voice -> (suggestion: VoiceSuggestion, rankScore: Float)? in
            let raw = Self.cosine(embedding, voice.embedding)
            guard raw >= 0.42 else { return nil }
            let invited = isInvited(voice.name)
            let rank = raw + (invited ? Self.inviteRankBonus : 0)
            return (VoiceSuggestion(speaker: "", name: voice.name, score: raw, onInvite: invited), rank)
        }
        .sorted { $0.rankScore > $1.rankScore }
        .prefix(limit)
        .map(\.suggestion)
    }

    /// Renames a saved voiceprint (merging embeddings if another voiceprint already has the target name).
    public mutating func renameVoice(from oldName: String, to newName: String, at date: Date = Date()) {
        let trimmedNew = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !Self.isPlaceholder(trimmedNew) else { return }
        guard let sourceIdx = voices.firstIndex(where: { $0.name.compare(oldName, options: .caseInsensitive) == .orderedSame }) else {
            return
        }
        let source = voices.remove(at: sourceIdx)
        if let list = source.contributions, !list.isEmpty {
            for c in list {
                remember(name: trimmedNew, embedding: c.embedding, seconds: c.seconds, sourceKey: c.key, at: date)
            }
        } else {
            remember(name: trimmedNew, embedding: source.embedding, seconds: source.seconds, at: date)
        }
    }

    /// Removes a person's saved voiceprint.
    public mutating func forgetVoice(named name: String) {
        voices.removeAll { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }
    }

    /// Removes a specific meeting+speaker contribution (`"<meetingID>::<speakerID>"`), recomputing
    /// the remaining centroid so mislabeling a speaker never contaminates another person's voiceprint.
    public mutating func unlearn(sourceKey: String) {
        for index in voices.indices.reversed() {
            guard var list = voices[index].contributions else { continue }
            let before = list.count
            list.removeAll { $0.key == sourceKey }
            guard list.count != before else { continue }
            if list.isEmpty {
                voices.remove(at: index)
            } else if let recomputed = Self.weightedCentroid(of: list) {
                voices[index].embedding = recomputed.embedding
                voices[index].seconds = recomputed.seconds
                voices[index].contributions = list
            }
        }
    }

    /// Stores or blends a voice the user just named. Placeholder names are ignored.
    /// Passing `sourceKey` (e.g. `"<meetingID>::<speakerID>"`) atomically unlearns any previous
    /// assignment for that speaker turn so corrections never corrupt another person's voiceprint.
    public mutating func remember(name: String,
                                  embedding: [Float],
                                  seconds: Double,
                                  sourceKey: String? = nil,
                                  at date: Date = Date()) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !Self.isPlaceholder(trimmed), !embedding.isEmpty else { return }
        if let sourceKey {
            unlearn(sourceKey: sourceKey)
        }
        let weight = Double(max(seconds, 1))
        if let index = voices.firstIndex(where: { $0.name.compare(trimmed, options: .caseInsensitive) == .orderedSame }) {
            var voice = voices[index]
            if let sourceKey {
                var list = voice.contributions ?? [
                    KnownVoice.Contribution(key: "legacy", embedding: voice.embedding, seconds: max(voice.seconds, 1))
                ]
                list.removeAll { $0.key == sourceKey }
                list.append(KnownVoice.Contribution(key: sourceKey, embedding: embedding, seconds: weight))
                if list.count > 12 {
                    list.removeFirst(list.count - 12)
                }
                if let recomputed = Self.weightedCentroid(of: list) {
                    voice.embedding = recomputed.embedding
                    voice.seconds = recomputed.seconds
                } else {
                    voice.embedding = embedding
                    voice.seconds = weight
                }
                voice.contributions = list
            } else if voice.embedding.count == embedding.count {
                let oldWeight = max(voice.seconds, 1)
                let total = oldWeight + weight
                voice.embedding = zip(voice.embedding, embedding).map { left, right in
                    Float((Double(left) * oldWeight + Double(right) * weight) / total)
                }
                voice.seconds = min(oldWeight + weight, 60 * 60)
            } else {
                voice.embedding = embedding
                voice.seconds = weight
            }
            voice.name = trimmed
            voice.updated = date
            voices[index] = voice
            return
        }
        let initialContributions = sourceKey.map { [KnownVoice.Contribution(key: $0, embedding: embedding, seconds: weight)] }
        voices.append(KnownVoice(name: trimmed, embedding: embedding, seconds: weight, updated: date, contributions: initialContributions))
        if voices.count > Self.maxVoices {
            voices.sort { $0.updated > $1.updated }
            voices.removeLast(voices.count - Self.maxVoices)
        }
    }

    private static func weightedCentroid(of contributions: [KnownVoice.Contribution]) -> (embedding: [Float], seconds: Double)? {
        guard let targetDim = contributions.last?.embedding.count, targetDim > 0 else { return nil }
        let compatible = contributions.filter { $0.embedding.count == targetDim }
        guard !compatible.isEmpty else { return nil }
        var sum = [Double](repeating: 0, count: targetDim)
        var totalSeconds = 0.0
        for item in compatible {
            let w = max(item.seconds, 1)
            for idx in sum.indices {
                sum[idx] += Double(item.embedding[idx]) * w
            }
            totalSeconds += w
        }
        guard totalSeconds > 0 else { return nil }
        let vector = sum.map { Float($0 / totalSeconds) }
        return (vector, min(totalSeconds, 60 * 60))
    }
}

/// `voiceprints.json` beside `meetings/` and `collections.json`.
public enum SpeakerMemoryFile {
    public static func url(beside meeting: MeetingFolder) -> URL {
        meeting.url.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("voiceprints.json")
    }

    public static func load(_ url: URL) -> SpeakerMemory {
        (try? JSONCoding.read(SpeakerMemory.self, from: url)) ?? SpeakerMemory()
    }

    public static func save(_ memory: SpeakerMemory, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONCoding.write(memory, to: url)
    }
}
