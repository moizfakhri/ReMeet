import Foundation

public enum MeetingChatScope: String, Sendable, CaseIterable, Identifiable {
    case thisMeeting
    case thisFolder
    case allRecordings

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .thisMeeting: "This meeting"
        case .thisFolder: "This folder"
        case .allRecordings: "All recordings"
        }
    }
}

public struct MeetingChatSource: Codable, Sendable, Equatable, Identifiable {
    public var meetingID: String
    public var start: Double
    public var label: String

    public var id: String { "\(meetingID)-\(start)-\(label)" }

    public init(meetingID: String, start: Double, label: String) {
        self.meetingID = meetingID
        self.start = start
        self.label = label
    }
}

public struct MeetingChatAnswer: Codable, Sendable, Equatable {
    public var answer: String
    public var sources: [MeetingChatSource]

    public init(answer: String, sources: [MeetingChatSource]) {
        self.answer = answer
        self.sources = sources
    }
}

/// Where Chat answers are generated. Sonnet is the default. MLX stays on this Mac.
public enum MeetingChatAnswerBackend: String, Sendable, CaseIterable, Identifiable {
    case sonnet
    case mlx

    public var id: String { rawValue }
    public static let `default` = MeetingChatAnswerBackend.sonnet

    public var label: String {
        switch self {
        case .sonnet: "Sonnet"
        case .mlx: "On this Mac"
        }
    }
}

/// Prompt bodies for meeting Q&A. Sonnet and the on-device model share this JSON shape.
public enum MeetingChatPrompt {
    public static let system = """
    You answer questions using only the meeting excerpts provided. \
    Earlier conversation, when present, is context for follow-up questions. \
    Answer the latest question only from the excerpts. \
    Write concise prose in complete sentences. If the excerpts do not contain enough evidence, \
    say you could not find it in these meetings and do not guess. \
    Reply with JSON only, no markdown fences: \
    {"answer":"...","sources":[{"meetingId":"...","start":0.0,"label":"short speaker or section name"}]}. \
    Every factual claim must have a matching source when evidence exists. meetingId and start must come from the excerpts. \
    Use the recorder's name spelling when it appears in the excerpts. sources may be an empty array when nothing matched.
    """

    public struct Passage: Sendable {
        public var meetingID: String
        public var title: String
        public var start: Double
        public var end: Double
        public var speaker: String
        public var kind: MeetingChunk.Kind
        public var text: String

        public init(meetingID: String, title: String, start: Double, end: Double, speaker: String,
                    kind: MeetingChunk.Kind, text: String) {
            self.meetingID = meetingID
            self.title = title
            self.start = start
            self.end = end
            self.speaker = speaker
            self.kind = kind
            self.text = text
        }
    }

    private struct WirePassage: Encodable {
        var meetingId: String
        var title: String
        var start: Double
        var end: Double
        var speaker: String
        var kind: String
        var text: String
    }

    public static func user(question: String, passages: [Passage], recorderName: String,
                            history: [MeetingChatTurn] = []) -> String {
        var lines: [String] = []
        if !recorderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("The person who recorded these meetings is \(recorderName).")
            lines.append("")
        }
        let prior = history.suffix(MeetingChatThread.promptLimit)
        if !prior.isEmpty {
            lines.append("Earlier in this conversation:")
            for turn in prior {
                let who = turn.role == .user ? "User" : "Assistant"
                lines.append("\(who): \(turn.text)")
            }
            lines.append("")
        }
        lines.append("Question: \(question)")
        lines.append("")
        lines.append("Excerpts (JSON array):")
        let wire = passages.map {
            WirePassage(meetingId: $0.meetingID, title: $0.title, start: $0.start, end: $0.end,
                        speaker: $0.speaker, kind: $0.kind.rawValue, text: $0.text)
        }
        let data = (try? JSONEncoder().encode(wire)) ?? Data("[]".utf8)
        lines.append(String(decoding: data, as: UTF8.self))
        return lines.joined(separator: "\n")
    }

    public static func parseAnswer(_ text: String) throws -> MeetingChatAnswer {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let data: Data
        if trimmed.hasPrefix("{") {
            guard let raw = trimmed.data(using: .utf8) else { throw MeetingChatError.badReply }
            data = raw
        } else if let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}") {
            data = Data(trimmed[start...end].utf8)
        } else {
            throw MeetingChatError.badReply
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        struct Wire: Decodable {
            var answer: String
            var sources: [WireSource]?
        }
        struct WireSource: Decodable {
            var meetingId: String
            var start: Double
            var label: String
        }
        let wire = try decoder.decode(Wire.self, from: data)
        let answer = wire.answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { throw MeetingChatError.badReply }
        let sources = (wire.sources ?? []).compactMap { source -> MeetingChatSource? in
            let id = source.meetingId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { return nil }
            return MeetingChatSource(meetingID: id, start: source.start, label: source.label)
        }
        return MeetingChatAnswer(answer: answer, sources: sources)
    }
}

public enum MeetingChatError: LocalizedError, Equatable {
    case notConfigured
    case badReply
    case server(String)
    case indexUnavailable
    case modelMissing

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Chat needs the claude command at ~/.local/bin/claude. ReMeet does not use an API key."
        case .badReply:
            "The model replied, but not in the expected JSON shape."
        case .server(let message):
            "The model didn't finish: \(message)"
        case .indexUnavailable:
            "The search index is still building. Try again in a moment."
        case .modelMissing:
            "Chat on this Mac needs the built-in summary model. Download it in Settings, or switch Chat answers back to Sonnet."
        }
    }
}