import Foundation

/// One entry in notes.json. `t` is seconds from the start of the recording to the moment
/// the note field was opened (not when Return was pressed), so a note sits where the
/// conversation was when the user decided to write it.
public struct MeetingNote: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case note
        case bookmark
        case action
    }

    public var id: UUID
    public var t: Double
    public var text: String
    public var kind: Kind

    public init(id: UUID = UUID(), t: Double, text: String, kind: Kind) {
        self.id = id
        self.t = t
        self.text = text
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey { case id, t, text, kind }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        t = try c.decode(Double.self, forKey: .t)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .note
    }

    /// What the bubble shows and the transcript inlines.
    public var displayText: String {
        switch kind {
        case .bookmark: text.isEmpty ? "Bookmark" : text
        case .note, .action: text
        }
    }
}

public enum NoteTiming {
    /// Seconds from recording start to `openedAt`, never negative, rounded to 0.1 s.
    public static func timestamp(openedAt: Date, recordingStart: Date) -> Double {
        (max(0, openedAt.timeIntervalSince(recordingStart)) * 10).rounded() / 10
    }

    /// Turns what was typed and how it was submitted into a note.
    /// Empty Return is a bookmark; Command-Return is an action item (empty is still a bookmark).
    public static func resolve(text raw: String, command: Bool, t: Double) -> MeetingNote {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return MeetingNote(t: t, text: "", kind: .bookmark) }
        return MeetingNote(t: t, text: text, kind: command ? .action : .note)
    }
}

/// Appends to notes.json immediately so nothing typed during a call is lost to a crash.
public struct NotesFile: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() -> [MeetingNote] {
        guard FileManager.default.fileExists(atPath: url.path),
              let notes = try? JSONCoding.read([MeetingNote].self, from: url) else { return [] }
        return notes.sorted { $0.t < $1.t }
    }

    public func append(_ note: MeetingNote) throws {
        var notes = load()
        notes.append(note)
        try save(notes)
    }

    public func save(_ notes: [MeetingNote]) throws {
        try JSONCoding.write(notes.sorted { $0.t < $1.t }, to: url)
    }
}
