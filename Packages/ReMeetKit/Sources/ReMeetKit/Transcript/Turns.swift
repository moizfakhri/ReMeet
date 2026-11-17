import Foundation

/// A stretch of one speaker, as the diarizer reports it (seconds on the meeting timeline).
public struct SpeechSegment: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var speaker: String

    public init(start: Double, end: Double, speaker: String) {
        self.start = start
        self.end = end
        self.speaker = speaker
    }

    public var duration: Double { end - start }
}

/// diarization.json: speech found on each track, speakers already normalized.
public struct Diarization: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var mic: [SpeechSegment]
    public var system: [SpeechSegment]
    public var engine: String
    /// Speaker id (`speaker_1`, `you`) to the diarizer's voice embedding. Missing on older files.
    public var embeddings: [String: [Float]]

    public init(mic: [SpeechSegment], system: [SpeechSegment], engine: String, embeddings: [String: [Float]] = [:]) {
        self.mic = mic
        self.system = system
        self.engine = engine
        self.embeddings = embeddings
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, mic, system, engine, embeddings }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        mic = try c.decodeIfPresent([SpeechSegment].self, forKey: .mic) ?? []
        system = try c.decodeIfPresent([SpeechSegment].self, forKey: .system) ?? []
        engine = try c.decodeIfPresent(String.self, forKey: .engine) ?? ""
        embeddings = try c.decodeIfPresent([String: [Float]].self, forKey: .embeddings) ?? [:]
    }
}

/// A unit sent to the speech-to-text model: one speaker, one track, contiguous.
public struct Turn: Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var speaker: String
    public var source: TrackSource

    public init(start: Double, end: Double, speaker: String, source: TrackSource) {
        self.start = start
        self.end = end
        self.speaker = speaker
        self.source = source
    }

    public var duration: Double { end - start }
}

public enum SpeakerNormalizer {
    /// Maps raw diarizer ids ("S3", "speaker_0", ...) to `speaker_1`, `speaker_2` ... in order of
    /// first appearance, so the first person to talk on the call is Speaker 1.
    public static func normalize(_ segments: [SpeechSegment]) -> [SpeechSegment] {
        normalize(segments, embeddings: [:]).segments
    }

    /// Same mapping, carrying each raw id's embedding onto `speaker_1`, `speaker_2`, ...
    public static func normalize(_ segments: [SpeechSegment], embeddings: [String: [Float]]) -> (segments: [SpeechSegment], embeddings: [String: [Float]]) {
        var mapping: [String: String] = [:]
        let normalized = segments.sorted { $0.start < $1.start }.map { segment in
            let id = mapping[segment.speaker] ?? {
                let next = "speaker_\(mapping.count + 1)"
                mapping[segment.speaker] = next
                return next
            }()
            return SpeechSegment(start: segment.start, end: segment.end, speaker: id)
        }
        var mapped: [String: [Float]] = [:]
        for (raw, id) in mapping {
            if let vector = embeddings[raw], !vector.isEmpty { mapped[id] = vector }
        }
        return (normalized, mapped)
    }
}

public enum TurnBuilder {
    public struct Options: Sendable {
        /// Same-speaker segments closer than this are one turn.
        public var mergeGap: Double = 1.0
        /// Turns shorter than this (after merging) are dropped: coughs, clicks, "mm".
        public var minDuration: Double = 0.35
        /// Audio added on both sides so word edges are not clipped.
        public var padding: Double = 0.2
        /// Long monologues are cut into pieces of at most this length.
        public var maxDuration: Double = 90

        public init() {}
    }

    public static func turns(from segments: [SpeechSegment], source: TrackSource, audioDuration: Double,
                             options: Options = Options()) -> [Turn] {
        let sorted = segments.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        var merged: [SpeechSegment] = []
        for segment in sorted {
            if var last = merged.last, last.speaker == segment.speaker, segment.start - last.end <= options.mergeGap {
                last.end = max(last.end, segment.end)
                merged[merged.count - 1] = last
            } else {
                merged.append(segment)
            }
        }
        var turns: [Turn] = []
        for segment in merged where segment.duration >= options.minDuration {
            var start = segment.start
            while start < segment.end {
                let end = min(segment.end, start + options.maxDuration)
                turns.append(Turn(start: max(0, start - options.padding),
                                  end: min(audioDuration > 0 ? audioDuration : end + options.padding, end + options.padding),
                                  speaker: segment.speaker, source: source))
                start = end
            }
        }
        return turns
    }
}

public enum Stitcher {
    /// One timeline from both tracks: sorted by start, mic first on a tie, empty text dropped,
    /// whitespace tidied. Notes are not mixed in here; they stay in notes.json and are placed
    /// by time when shown or written to transcript.md.
    public static func stitch(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        segments
            .map { segment in
                var s = segment
                s.text = s.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                return s
            }
            .filter { !$0.text.isEmpty }
            .sorted { a, b in
                if a.start != b.start { return a.start < b.start }
                return a.source == .mic && b.source == .system
            }
    }

    /// Items for display: transcript turns with notes placed before the first turn that starts
    /// after them.
    public enum Item: Equatable, Sendable {
        case segment(TranscriptSegment)
        case note(MeetingNote)

        public var time: Double {
            switch self {
            case .segment(let s): s.start
            case .note(let n): n.t
            }
        }
    }

    public static func interleave(_ segments: [TranscriptSegment], notes: [MeetingNote]) -> [Item] {
        var items: [Item] = []
        var pending = notes.sorted { $0.t < $1.t }[...]
        for segment in segments {
            while let note = pending.first, note.t < segment.start {
                items.append(.note(note))
                pending = pending.dropFirst()
            }
            items.append(.segment(segment))
        }
        items.append(contentsOf: pending.map(Item.note))
        return items
    }
}

public enum TranscriptMarkdown {
    public static func render(_ transcript: Transcript, notes: [MeetingNote], speakers: SpeakerNames,
                              title: String) -> String {
        var lines = ["# \(title): transcript", ""]
        var lastSpeaker: String?
        for item in Stitcher.interleave(transcript.segments, notes: notes) {
            switch item {
            case .segment(let s):
                if s.speaker != lastSpeaker {
                    if lastSpeaker != nil { lines.append("") }
                    lines.append("**\(speakers.displayName(for: s.speaker))** \(TimeFormat.clock(s.start))")
                    lastSpeaker = s.speaker
                }
                lines.append(s.text)
            case .note(let n):
                lines.append("")
                let label = n.kind == .bookmark ? "Bookmark" : n.kind == .action ? "Your action item" : "Your note"
                lines.append("> **\(label) \(TimeFormat.clock(n.t))** \(n.text)".trimmingCharacters(in: .whitespaces))
                lines.append("")
                lastSpeaker = nil
            }
        }
        return lines.joined(separator: "\n").replacingOccurrences(of: "\n\n\n", with: "\n\n") + "\n"
    }
}
