import Foundation

// MARK: - Transcript (transcript.json)

/// Which recorded track a segment came from. The mic track is always "You".
public enum TrackSource: String, Codable, Sendable {
    case mic
    case system
}

/// One spoken word and when it was said, on the same timeline as playback.
public struct TranscriptWord: Codable, Equatable, Sendable {
    public var text: String
    public var start: Double
    public var end: Double

    public init(text: String, start: Double, end: Double) {
        self.text = text
        self.start = start
        self.end = end
    }
}

public struct TranscriptSegment: Codable, Equatable, Sendable, Identifiable {
    public var start: Double
    public var end: Double
    /// Stable id: "you" for the mic track, "speaker_1", "speaker_2" ... for the call track.
    public var speaker: String
    public var text: String
    public var source: TrackSource
    /// Real word times from the transcriber. Empty means the turn only has a start and end.
    public var words: [TranscriptWord]

    public var id: String { "\(source.rawValue)-\(speaker)-\(start)" }

    public init(start: Double, end: Double, speaker: String, text: String, source: TrackSource, words: [TranscriptWord] = []) {
        self.start = start
        self.end = end
        self.speaker = speaker
        self.text = text
        self.source = source
        self.words = words
    }

    private enum CodingKeys: String, CodingKey { case start, end, speaker, text, source, words }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        start = try c.decode(Double.self, forKey: .start)
        end = try c.decode(Double.self, forKey: .end)
        speaker = try c.decode(String.self, forKey: .speaker)
        text = try c.decode(String.self, forKey: .text)
        source = try c.decode(TrackSource.self, forKey: .source)
        words = try c.decodeIfPresent([TranscriptWord].self, forKey: .words) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(start, forKey: .start)
        try c.encode(end, forKey: .end)
        try c.encode(speaker, forKey: .speaker)
        try c.encode(text, forKey: .text)
        try c.encode(source, forKey: .source)
        if !words.isEmpty { try c.encode(words, forKey: .words) }
    }
}

public struct Transcript: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var engine: String
    public var segments: [TranscriptSegment]

    public init(engine: String, segments: [TranscriptSegment]) {
        self.engine = engine
        self.segments = segments
    }

    /// Words in the spoken transcript. Notes are not included.
    public var wordCount: Int {
        segments.reduce(0) { $0 + Self.words(in: $1.text) }
    }

    public static func words(in text: String) -> Int {
        text.split { $0.isWhitespace }.count
    }
}

/// speakers.json: display names chosen by the user, keyed by speaker id.
public struct SpeakerNames: Codable, Equatable, Sendable {
    public var names: [String: String]

    public init(names: [String: String] = [:]) {
        self.names = names
    }

    public static let youID = "you"
    /// Everyone on the call, when speaker labels are off.
    public static let callID = "call"

    /// The display name of one speaker id. Every other id is left as it was.
    /// A system speaker cannot be named "You": that label is the mic.
    public func renaming(_ id: String, to name: String) -> SpeakerNames {
        var copy = self
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if id != Self.youID {
            let lower = trimmed.lowercased()
            if lower == "you" || lower == Self.youID { return self }
        }
        if trimmed.isEmpty {
            copy.names.removeValue(forKey: id)
        } else {
            copy.names[id] = trimmed
        }
        return copy
    }

    /// "You", the user's chosen name, or "Speaker N" from the id.
    public func displayName(for id: String) -> String {
        if let name = names[id], !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
        if id == Self.youID { return "You" }
        if id == Self.callID { return "Call" }
        if id.hasPrefix("speaker_"), let n = Int(id.dropFirst("speaker_".count)) { return "Speaker \(n)" }
        return id
    }
}

// MARK: - Summary (summary.json)

public struct SummaryPoint: Codable, Equatable, Sendable, Identifiable {
    public var text: String
    /// Where in the meeting this comes from (seconds), for "jump to 12:34".
    public var t: Double?
    public var id: String { "\(t.map { String($0) } ?? "-"):\(text)" }

    public init(text: String, t: Double? = nil) {
        self.text = text
        self.t = t
    }
}

public struct ActionItem: Codable, Equatable, Sendable, Identifiable {
    public var owner: String?
    public var task: String
    public var due: String?
    public var done: Bool
    public var t: Double?
    public var relatesToMe: Bool?
    public var dismissed: Bool
    public var reminderID: String?
    public var reminderListID: String?
    public var reminderListName: String?
    public var reminderListPinned: Bool
    public var id: String { "\(owner ?? "-"):\(due ?? "-"):\(t.map { String($0) } ?? "-"):\(task)" }

    public init(owner: String? = nil,
                task: String,
                due: String? = nil,
                done: Bool = false,
                t: Double? = nil,
                relatesToMe: Bool? = nil,
                dismissed: Bool = false,
                reminderID: String? = nil,
                reminderListID: String? = nil,
                reminderListName: String? = nil,
                reminderListPinned: Bool = false) {
        self.owner = owner
        self.task = task
        self.due = due
        self.done = done
        self.t = t
        self.relatesToMe = relatesToMe
        self.dismissed = dismissed
        self.reminderID = reminderID
        self.reminderListID = reminderListID
        self.reminderListName = reminderListName
        self.reminderListPinned = reminderListPinned
    }

    enum CodingKeys: String, CodingKey {
        case owner, task, due, done, t
        case relatesToMe = "relates_to_me"
        case dismissed
        case reminderID = "reminder_id"
        case reminderListID = "reminder_list_id"
        case reminderListName = "reminder_list_name"
        case reminderListPinned = "reminder_list_pinned"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        owner = try c.decodeIfPresent(String.self, forKey: .owner)
        task = try c.decode(String.self, forKey: .task)
        due = try c.decodeIfPresent(String.self, forKey: .due)
        done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
        t = try c.decodeIfPresent(Double.self, forKey: .t)
        relatesToMe = try c.decodeIfPresent(Bool.self, forKey: .relatesToMe)
        dismissed = try c.decodeIfPresent(Bool.self, forKey: .dismissed) ?? false
        reminderID = try c.decodeIfPresent(String.self, forKey: .reminderID)
        reminderListID = try c.decodeIfPresent(String.self, forKey: .reminderListID)
        reminderListName = try c.decodeIfPresent(String.self, forKey: .reminderListName)
        reminderListPinned = try c.decodeIfPresent(Bool.self, forKey: .reminderListPinned) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(owner, forKey: .owner)
        try c.encode(task, forKey: .task)
        try c.encodeIfPresent(due, forKey: .due)
        try c.encode(done, forKey: .done)
        try c.encodeIfPresent(t, forKey: .t)
        try c.encodeIfPresent(relatesToMe, forKey: .relatesToMe)
        if dismissed { try c.encode(true, forKey: .dismissed) }
        try c.encodeIfPresent(reminderID, forKey: .reminderID)
        try c.encodeIfPresent(reminderListID, forKey: .reminderListID)
        try c.encodeIfPresent(reminderListName, forKey: .reminderListName)
        if reminderListPinned { try c.encode(true, forKey: .reminderListPinned) }
    }
}

public struct NoteContext: Codable, Equatable, Sendable, Identifiable {
    public var t: Double
    public var note: String
    /// What was being said around the note, written by the summarizer.
    public var context: String
    public var id: String { "\(t)-\(note)" }

    public init(t: Double, note: String, context: String) {
        self.t = t
        self.note = note
        self.context = context
    }
}

/// The summary schema from the build spec. Keys are snake_case on disk.
public struct MeetingSummary: Codable, Equatable, Sendable {
    public var title: String
    public var summary: [SummaryPoint]
    public var decisions: [SummaryPoint]
    public var actionItems: [ActionItem]
    public var openQuestions: [SummaryPoint]
    public var yourNotes: [NoteContext]

    public init(title: String, summary: [SummaryPoint] = [], decisions: [SummaryPoint] = [],
                actionItems: [ActionItem] = [], openQuestions: [SummaryPoint] = [], yourNotes: [NoteContext] = []) {
        self.title = title
        self.summary = summary
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
        self.yourNotes = yourNotes
    }

    enum CodingKeys: String, CodingKey {
        case title, summary, decisions
        case actionItems = "action_items"
        case openQuestions = "open_questions"
        case yourNotes = "your_notes"
    }
}
