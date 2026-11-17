import Foundation

/// One turn in the open meeting's chat. Sources are stored for the UI; the model sees the text.
public struct MeetingChatTurn: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable {
        case user
        case assistant
    }

    public var role: Role
    public var text: String
    public var sources: [MeetingChatSource]

    public init(role: Role, text: String, sources: [MeetingChatSource] = []) {
        self.role = role
        self.text = text
        self.sources = sources
    }
}

/// Chat for the meeting that was open when the question was asked. `chat.json` sits beside
/// the transcript and is not part of the chunk fingerprint.
public struct MeetingChatThread: Codable, Equatable, Sendable {
    /// User and assistant messages kept for the next prompt. Older turns drop off the front.
    public static let promptLimit = 8

    public var schemaVersion: Int
    public var turns: [MeetingChatTurn]

    public init(turns: [MeetingChatTurn] = []) {
        schemaVersion = 1
        self.turns = turns
    }

    public static func fileURL(in folder: MeetingFolder) -> URL {
        folder.url.appendingPathComponent("chat.json")
    }

    public static func load(from url: URL) -> MeetingChatThread {
        guard let thread = try? JSONCoding.read(MeetingChatThread.self, from: url) else {
            return MeetingChatThread()
        }
        return thread
    }

    public func save(to url: URL) throws {
        try JSONCoding.write(self, to: url)
    }

    public func appending(question: String, answer: MeetingChatAnswer) -> MeetingChatThread {
        var copy = self
        copy.turns.append(MeetingChatTurn(role: .user, text: question, sources: []))
        copy.turns.append(MeetingChatTurn(role: .assistant, text: answer.answer, sources: answer.sources))
        if copy.turns.count > Self.promptLimit {
            copy.turns.removeFirst(copy.turns.count - Self.promptLimit)
        }
        return copy
    }

    /// Latest question, then the previous user question when a follow-up needs the earlier topic.
    public static func retrievalQueries(question: String, history: [MeetingChatTurn]) -> [String] {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var queries = [trimmed]
        if let prior = history.last(where: { $0.role == .user })?.text
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !prior.isEmpty, prior.caseInsensitiveCompare(trimmed) != .orderedSame {
            queries.append(prior)
        }
        return queries
    }

    /// A short follow-up ("who owns that?") often misses on its own. Search the prior question too.
    public static func shouldExpandRetrieval(hitCount: Int) -> Bool {
        hitCount < 4
    }
}
