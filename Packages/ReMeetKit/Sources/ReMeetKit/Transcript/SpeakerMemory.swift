import Foundation

/// A person ReMeet has heard before. The embedding is the diarizer's voice vector
/// (WeSpeaker, 256 numbers), kept next to the meetings folder in `voiceprints.json`.
public struct KnownVoice: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var embedding: [Float]
    public var seconds: Double
    public var updated: Date

    public init(id: String = UUID().uuidString, name: String, embedding: [Float], seconds: Double, updated: Date) {
        self.id = id
        self.name = name
        self.embedding = embedding
        self.seconds = seconds
        self.updated = updated
    }
}

/// A voiceprint the user can accept for one speaker. Accepting it is a separate step.
public struct VoiceSuggestion: Equatable, Sendable {
    public var speaker: String
    public var name: String
    public var score: Float

    public init(speaker: String, name: String, score: Float) {
        self.speaker = speaker
        self.name = name
        self.score = score
    }
}

/// Names learned from meetings the user has labeled, matched to new diarization embeddings.
public struct SpeakerMemory: Codable, Equatable, Sendable {
    public var voices: [KnownVoice]

    /// Cosine similarity on L2-normalized embeddings. Same-speaker WeSpeaker scores on
    /// meeting audio usually sit above this; a lower bar mislabels people.
    public static let matchThreshold: Float = 0.62
    /// The best match has to lead the runner-up by this much, so two close voices are left unnamed.
    public static let matchMargin: Float = 0.07
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
    public func suggestions(for embeddings: [String: [Float]], existing: SpeakerNames) -> [VoiceSuggestion] {
        struct Candidate {
            var speaker: String
            var voice: Int
            var score: Float
        }
        var candidates: [Candidate] = []
        for (speaker, vector) in embeddings where speaker != SpeakerNames.youID {
            if let name = existing.names[speaker], !Self.isPlaceholder(name) { continue }
            var scored: [(Int, Float)] = []
            for (index, voice) in voices.enumerated() {
                scored.append((index, Self.cosine(vector, voice.embedding)))
            }
            guard let best = scored.max(by: { $0.1 < $1.1 }), best.1 >= Self.matchThreshold else { continue }
            let second = scored.filter { $0.0 != best.0 }.map(\.1).max() ?? 0
            guard best.1 - second >= Self.matchMargin else { continue }
            candidates.append(Candidate(speaker: speaker, voice: best.0, score: best.1))
        }
        candidates.sort { left, right in
            if left.score != right.score { return left.score > right.score }
            return left.speaker < right.speaker
        }
        var offered: [VoiceSuggestion] = []
        var usedSpeakers: Set<String> = []
        var usedVoices: Set<Int> = []
        for candidate in candidates where !usedSpeakers.contains(candidate.speaker) && !usedVoices.contains(candidate.voice) {
            usedSpeakers.insert(candidate.speaker)
            usedVoices.insert(candidate.voice)
            offered.append(VoiceSuggestion(speaker: candidate.speaker, name: voices[candidate.voice].name, score: candidate.score))
        }
        return offered
    }

    /// Fills in display names for speaker ids that do not already have one. One saved voice
    /// is used at most once in a meeting. The pipeline does not call this; the meeting asks first.
    public func applying(to existing: SpeakerNames, embeddings: [String: [Float]]) -> SpeakerNames {
        var names = existing
        for suggestion in suggestions(for: embeddings, existing: existing) {
            names.names[suggestion.speaker] = suggestion.name
        }
        return names
    }

    /// Stores or blends a voice the user just named. Placeholder names are ignored.
    public mutating func remember(name: String, embedding: [Float], seconds: Double, at date: Date = Date()) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !Self.isPlaceholder(trimmed), !embedding.isEmpty else { return }
        let weight = Double(max(seconds, 1))
        if let index = voices.firstIndex(where: { $0.name.compare(trimmed, options: .caseInsensitive) == .orderedSame }) {
            var voice = voices[index]
            if voice.embedding.count == embedding.count {
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
        voices.append(KnownVoice(name: trimmed, embedding: embedding, seconds: weight, updated: date))
        if voices.count > Self.maxVoices {
            voices.sort { $0.updated > $1.updated }
            voices.removeLast(voices.count - Self.maxVoices)
        }
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
