import Foundation

/// One searchable passage from a meeting: a transcript turn, summary bullet, or note.
public struct MeetingChunk: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        case turn
        case summary
        case note
    }

    public var id: String
    public var meetingID: String
    public var start: Double
    public var end: Double
    public var speaker: String
    public var kind: Kind
    public var text: String

    public init(id: String, meetingID: String, start: Double, end: Double, speaker: String,
                kind: Kind, text: String) {
        self.id = id
        self.meetingID = meetingID
        self.start = start
        self.end = end
        self.speaker = speaker
        self.kind = kind
        self.text = text
    }

    /// Short label for citations (speaker or kind).
    public func citationLabel(title: String) -> String {
        switch kind {
        case .turn:
            let trimmed = speaker.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? title : trimmed
        case .summary: return "Summary"
        case .note: return "Note"
        }
    }
}

/// Builds retrieval chunks at speaker-turn boundaries plus summary and notes.
public enum MeetingChunkBuilder {
    public static func build(meetingID: String, meta: MeetingMeta, transcript: Transcript?,
                             summary: MeetingSummary?, notes: [MeetingNote], speakers: SpeakerNames) -> [MeetingChunk] {
        var chunks: [MeetingChunk] = []
        if let transcript {
            for segment in transcript.segments {
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let speaker = speakers.displayName(for: segment.speaker)
                let id = "\(meetingID)-turn-\(segment.source.rawValue)-\(segment.speaker)-\(segment.start)"
                chunks.append(MeetingChunk(id: id, meetingID: meetingID, start: segment.start, end: segment.end,
                                           speaker: speaker, kind: .turn, text: "\(speaker): \(text)"))
            }
        }
        if let summary {
            for point in summary.summary {
                let text = point.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let start = point.t ?? 0
                chunks.append(MeetingChunk(id: "\(meetingID)-summary-\(start)-\(text.hashValue)", meetingID: meetingID,
                                           start: start, end: start, speaker: "", kind: .summary, text: text))
            }
            for point in summary.decisions {
                let text = point.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let start = point.t ?? 0
                chunks.append(MeetingChunk(id: "\(meetingID)-decision-\(start)-\(text.hashValue)", meetingID: meetingID,
                                           start: start, end: start, speaker: "", kind: .summary, text: "Decision: \(text)"))
            }
            for item in summary.actionItems {
                let task = item.task.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !task.isEmpty else { continue }
                let start = item.t ?? 0
                let owner = item.owner?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let text = owner.isEmpty ? task : "\(owner): \(task)"
                chunks.append(MeetingChunk(id: "\(meetingID)-action-\(start)-\(text.hashValue)", meetingID: meetingID,
                                           start: start, end: start, speaker: owner, kind: .summary, text: "Action: \(text)"))
            }
            for point in summary.openQuestions {
                let text = point.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let start = point.t ?? 0
                chunks.append(MeetingChunk(id: "\(meetingID)-question-\(start)-\(text.hashValue)", meetingID: meetingID,
                                           start: start, end: start, speaker: "", kind: .summary, text: "Open question: \(text)"))
            }
        }
        for note in notes {
            let text = note.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let body: String
            switch note.kind {
            case .bookmark:
                body = text.isEmpty ? "Bookmarked this moment" : "Bookmark: \(text)"
            case .action:
                body = "Action item: \(text)"
            case .note:
                guard !text.isEmpty else { continue }
                body = text
            }
            chunks.append(MeetingChunk(id: "\(meetingID)-note-\(note.t)-\(note.kind.rawValue)", meetingID: meetingID,
                                       start: note.t, end: note.t, speaker: "", kind: .note, text: body))
        }
        _ = meta
        return chunks
    }

    /// Rough token estimate for fitting a whole meeting into a prompt.
    public static func estimatedTokens(transcript: Transcript?, summary: MeetingSummary?, notes: [MeetingNote]) -> Int {
        var chars = 0
        if let transcript {
            chars += transcript.segments.reduce(0) { $0 + $1.text.count + 32 }
        }
        if let summary {
            chars += summary.summary.reduce(0) { $0 + $1.text.count }
            chars += summary.decisions.reduce(0) { $0 + $1.text.count }
            chars += summary.actionItems.reduce(0) { $0 + ($1.task.count + ($1.owner?.count ?? 0)) }
            chars += summary.openQuestions.reduce(0) { $0 + $1.text.count }
        }
        chars += notes.reduce(0) { $0 + $1.text.count + 16 }
        return max(1, chars / 4)
    }

    public static let fullContextTokenLimit = 12_000
}