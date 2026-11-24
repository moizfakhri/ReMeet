import Foundation

/// Who spoke, taken from the mic track and the system track. The mixed playback file
/// is not an input: echo in that mix is not speech the models should hear.
public enum SpeakerTurnPlan {
    public struct Result: Equatable, Sendable {
        public var mic: [SpeechSegment]
        public var system: [SpeechSegment]
        public var embeddings: [String: [Float]]
    }

    /// Mic energy is the user. System speech is other people. Diarizer labels only split
    /// the system track. A system label is never `you`, and two raw system speakers stay two.
    public static func assemble(
        micEnergy: [(start: Double, end: Double)],
        systemEnergy: [(start: Double, end: Double)],
        systemDiarized: [SpeechSegment],
        systemEmbeddings: [String: [Float]],
        labelSpeakers: Bool
    ) -> Result {
        let mic = micEnergy
            .filter { $0.end > $0.start }
            .map { SpeechSegment(start: $0.start, end: $0.end, speaker: SpeakerNames.youID) }
            .sorted { $0.start < $1.start }

        if !labelSpeakers {
            let regions = systemEnergy.isEmpty ? spans(systemDiarized) : systemEnergy
            let system = regions.filter { $0.end > $0.start }.map {
                SpeechSegment(start: $0.start, end: $0.end, speaker: SpeakerNames.callID)
            }.sorted { $0.start < $1.start }
            return Result(mic: mic, system: system, embeddings: [:])
        }

        if systemDiarized.isEmpty {
            let system = systemEnergy.filter { $0.end > $0.start }.map {
                SpeechSegment(start: $0.start, end: $0.end, speaker: "energy")
            }
            let normalized = SpeakerNormalizer.normalize(system, embeddings: [:])
            return Result(mic: mic, system: normalized.segments, embeddings: [:])
        }

        let relabeled = systemDiarized.filter { $0.end > $0.start }.map { segment in
            SpeechSegment(start: segment.start, end: segment.end, speaker: systemRawID(segment.speaker))
        }
        var carried: [String: [Float]] = [:]
        for (raw, vector) in systemEmbeddings where !vector.isEmpty {
            carried[systemRawID(raw)] = vector
        }
        let normalized = SpeakerNormalizer.normalize(relabeled, embeddings: carried)
        let system = normalized.segments.map { segment -> SpeechSegment in
            guard segment.speaker == SpeakerNames.youID else { return segment }
            return SpeechSegment(start: segment.start, end: segment.end, speaker: "speaker_other")
        }
        let embeddings = normalized.embeddings.filter { $0.key != SpeakerNames.youID }
        return Result(mic: mic, system: system, embeddings: embeddings)
    }

    /// A diarizer id that collides with the user is still someone on the call, not the user.
    public static func systemRawID(_ speaker: String) -> String {
        let trimmed = speaker.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower == SpeakerNames.youID || lower == "you" || trimmed == SpeakerNames.callID || lower == "call" {
            return "system:" + trimmed
        }
        return trimmed
    }

    private static func spans(_ segments: [SpeechSegment]) -> [(start: Double, end: Double)] {
        segments.map { (start: $0.start, end: $0.end) }
    }
}

/// A few seconds of one non-user voice, on the system track's clock (the same clock as playback).
public enum SpeakerClip {
    public static func excerpt(speaker: String, segments: [TranscriptSegment], maxDuration: Double = 8) -> (start: Double, end: Double)? {
        guard speaker != SpeakerNames.youID else { return nil }
        let own = segments.filter { $0.speaker == speaker && $0.source == .system && $0.end > $0.start }
        guard let best = own.max(by: { ($0.end - $0.start) < ($1.end - $1.start) }) else { return nil }
        let length = min(max(maxDuration, 0.5), best.end - best.start)
        return (best.start, best.start + length)
    }
}

/// The name Sonnet should spell for the person who recorded the meeting.
/// A saved setting wins. Otherwise the first word of the Mac account name is used ("Alex Morgan" → "Alex").
public enum RecorderName {
    public static func given(stored: String?, systemFullName: String) -> String {
        let saved = stored?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !saved.isEmpty { return saved }
        let full = systemFullName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !full.isEmpty else { return "" }
        return full.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? full
    }
}

/// Names handed to Sonnet with the transcript text. The on-device speech model never sees this:
/// it only receives audio from the mic track and the call track.
public enum NameGlossary {
    public static func context(recorderName: String,
                               speakers: SpeakerNames,
                               segments: [TranscriptSegment],
                               attendeeNames: [String] = []) -> String {
        var lines: [String] = []
        let name = recorderName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            lines.append("The person who recorded this meeting is named \(name). Spell that name exactly \"\(name)\" wherever it is spoken, including inside someone else's sentence. A speech draft often mishears it. Lines whose speaker id is \(SpeakerNames.youID) are \(name).")
        }
        let invitees = attendeeNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !SpeakerMemory.isPlaceholder($0) }
        if !invitees.isEmpty {
            lines.append("Calendar invitees for this meeting (use these exact name spellings when spoken): \(invitees.joined(separator: ", ")).")
        }
        var seen: [String] = []
        for segment in segments where !seen.contains(segment.speaker) {
            seen.append(segment.speaker)
        }
        if !seen.isEmpty {
            lines.append("Each speaker id below is one voice. Do not merge ids, and do not move a line from one id to another.")
            for id in seen {
                let label = id == SpeakerNames.youID && !name.isEmpty ? name : speakers.displayName(for: id)
                lines.append("- \(id): \(label)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// Combines two voices the user has decided are the same person. The mic user is never folded into someone else.
public enum SpeakerMerge {
    public static func transcript(_ transcript: Transcript, from source: String, into target: String) -> Transcript {
        guard canMerge(source, into: target) else { return transcript }
        var copy = transcript
        copy.segments = transcript.segments.map { segment in
            guard segment.speaker == source else { return segment }
            var next = segment
            next.speaker = target
            return next
        }
        return copy
    }

    public static func diarization(_ diarization: Diarization, from source: String, into target: String) -> Diarization {
        guard canMerge(source, into: target) else { return diarization }
        var copy = diarization
        copy.mic = diarization.mic.map { moved($0, from: source, into: target) }
        copy.system = diarization.system.map { moved($0, from: source, into: target) }
        if copy.embeddings[target] == nil, let moved = copy.embeddings[source] {
            copy.embeddings[target] = moved
        }
        copy.embeddings.removeValue(forKey: source)
        return copy
    }

    /// Keeps the target's name. If the target is still unnamed, it takes the source's name. The source id is dropped.
    public static func names(_ names: SpeakerNames, from source: String, into target: String) -> SpeakerNames {
        guard canMerge(source, into: target) else { return names }
        var copy = names
        let targetName = copy.names[target] ?? ""
        if target != SpeakerNames.youID,
           SpeakerMemory.isPlaceholder(targetName),
           let sourceName = copy.names[source], !SpeakerMemory.isPlaceholder(sourceName) {
            copy.names[target] = sourceName
        }
        copy.names.removeValue(forKey: source)
        return copy
    }

    public static func canMerge(_ source: String, into target: String) -> Bool {
        source != target && source != SpeakerNames.youID && !source.isEmpty && !target.isEmpty
    }

    private static func moved(_ segment: SpeechSegment, from source: String, into target: String) -> SpeechSegment {
        guard segment.speaker == source else { return segment }
        return SpeechSegment(start: segment.start, end: segment.end, speaker: target)
    }
}

/// After the call is split again, a confirmed name follows the voice, not the old id.
/// `speaker_1` can be a different person on the next run. A name with no matching voice is dropped.
public enum SpeakerNameCarry {
    public static func names(previous: SpeakerNames, previousEmbeddings: [String: [Float]],
                             nextEmbeddings: [String: [Float]], threshold: Float = SpeakerMemory.matchThreshold) -> SpeakerNames {
        var result = SpeakerNames()
        if let you = previous.names[SpeakerNames.youID], !SpeakerMemory.isPlaceholder(you) {
            result.names[SpeakerNames.youID] = you
        }
        struct Link {
            var previousID: String
            var nextID: String
            var score: Float
        }
        var links: [Link] = []
        for (oldID, oldVector) in previousEmbeddings {
            let oldName = previous.names[oldID] ?? ""
            guard oldID != SpeakerNames.youID, !SpeakerMemory.isPlaceholder(oldName), !oldVector.isEmpty else { continue }
            for (newID, newVector) in nextEmbeddings where newID != SpeakerNames.youID && !newVector.isEmpty {
                let score = SpeakerMemory.cosine(oldVector, newVector)
                guard score >= threshold else { continue }
                links.append(Link(previousID: oldID, nextID: newID, score: score))
            }
        }
        links.sort { $0.score > $1.score }
        var usedOld: Set<String> = []
        var usedNew: Set<String> = []
        for link in links where !usedOld.contains(link.previousID) && !usedNew.contains(link.nextID) {
            usedOld.insert(link.previousID)
            usedNew.insert(link.nextID)
            result.names[link.nextID] = previous.names[link.previousID]
        }
        return result
    }
}

/// Two voices in this meeting that sound like one person. Nothing is merged until the user says so.
public enum SpeakerLikeness {
    public struct Pair: Equatable, Sendable {
        public var source: String
        public var target: String
        public var score: Float

        public init(source: String, target: String, score: Float) {
            self.source = source
            self.target = target
            self.score = score
        }
    }

    /// Each speaker is in at most one pair. `source` is the later voice; merging it into `target` keeps the earlier row.
    public static func pairs(_ embeddings: [String: [Float]], order: [String],
                             threshold: Float = SpeakerMemory.matchThreshold) -> [Pair] {
        let ids = order.filter { $0 != SpeakerNames.youID && embeddings[$0]?.isEmpty == false }
        var scored: [(source: String, target: String, score: Float)] = []
        for left in ids.indices {
            for right in ids.indices where right > left {
                let earlier = ids[left]
                let later = ids[right]
                guard let leftVector = embeddings[earlier], let rightVector = embeddings[later] else { continue }
                let score = SpeakerMemory.cosine(leftVector, rightVector)
                guard score >= threshold else { continue }
                scored.append((later, earlier, score))
            }
        }
        scored.sort { $0.score > $1.score }
        var used: Set<String> = []
        var pairs: [Pair] = []
        for item in scored where !used.contains(item.source) && !used.contains(item.target) {
            used.insert(item.source)
            used.insert(item.target)
            pairs.append(Pair(source: item.source, target: item.target, score: item.score))
        }
        return pairs
    }
}

/// Sonnet may change words. It may not move a line onto another person or drop a line.
public enum TranscriptSpeakers {
    public static func preserved(original: [TranscriptSegment], corrected: [TranscriptSegment]) -> Bool {
        guard original.count == corrected.count else { return false }
        return zip(original, corrected).allSatisfy { left, right in
            left.speaker == right.speaker && left.source == right.source
                && left.start == right.start && left.end == right.end
        }
    }
}
