import Foundation

/// One text call through the Claude CLI already on this Mac: `claude -p --model claude-sonnet-5-5`.
/// The whole Parakeet draft goes in as text. No audio block. ReMeet does not read or store an API key.
/// `--bare` stays off; that mode ignores the Claude login.
public enum HaikuBridge {
    public static let model = "claude-sonnet-5-5"
    /// ForgetMeNot blocks these so a subscription call cannot edit files or browse.
    public static let disallowedTools = "Bash,Read,Write,Edit,Glob,Grep,WebSearch,WebFetch,Task,NotebookEdit"

    /// The prompt is the entire transcript on stdin (`--input-format text`), not an argument,
    /// so a long meeting is not cut off by the command-line limit. `--no-session-persistence`
    /// keeps that transcript out of Claude's saved sessions.
    public static func textArguments(system: String) -> [String] {
        ["-p",
         "--input-format", "text",
         "--output-format", "json",
         "--no-session-persistence",
         "--system-prompt", system,
         "--model", model,
         "--max-turns", "1",
         "--disallowed-tools", disallowedTools]
    }

    /// `claude --output-format json`: the text is `result`. `is_error` is a failure even
    /// when the process exits 0.
    public static func text(fromCLIJSON data: Data) throws -> String {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HaikuBridgeError.badReply
        }
        if (root["is_error"] as? Bool) == true {
            let detail = root["result"] as? String ?? "the claude command failed"
            throw HaikuBridgeError.server(redact(detail))
        }
        guard let text = root["result"] as? String else { throw HaikuBridgeError.badReply }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw HaikuBridgeError.badReply }
        return trimmed
    }

    /// Drops anything that looks like a credential before an error is shown or logged.
    public static func redact(_ text: String) -> String {
        var cleaned = text
        let patterns = ["sk-[A-Za-z0-9_\\-]+", "sk-ant-[A-Za-z0-9_\\-]+", "eyJ[A-Za-z0-9_\\-]+\\.[A-Za-z0-9_\\-]+"]
        for pattern in patterns {
            cleaned = cleaned.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression)
        }
        if cleaned.count > 240 { cleaned = String(cleaned.prefix(240)) }
        return cleaned
    }
}

public enum HaikuBridgeError: LocalizedError, Equatable {
    case notConfigured
    case badReply
    case server(String)
    case unreachable

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Sonnet didn't run. The claude command was not found at ~/.local/bin/claude. The local result was kept. ReMeet does not use an API key."
        case .badReply:
            "Sonnet replied, but not in the expected shape. The local result was kept."
        case .server(let message):
            "Sonnet didn't finish: \(message) The local result was kept."
        case .unreachable:
            "The claude command did not finish. The local result was kept."
        }
    }
}

/// One text pass over the whole draft. Sonnet rewrites bad words, broken sentences, and punctuation.
public enum HaikuCorrection {
    public static let system = """
    You are correcting a meeting transcript. A local speech model wrote every line, \
    and accents made it mishear words. You have the entire transcript. Rewrite incorrect \
    words, incoherent sentences, and punctuation. Keep each line's meaning and index. \
    The speaker on each line is fixed. Lines marked You are the person who recorded the meeting; \
    do not give those words to anyone else. Do not merge Speaker 1, Speaker 2, or any other \
    speakers into one label. Do not summarize, do not merge lines, do not drop lines, \
    and do not add people or lines that were not spoken. \
    Reply with JSON only, no markdown: \
    {"segments":[{"i":0,"text":"corrected line"}]}
    """

    /// The entire transcript, one JSON object, sent as the user message.
    /// `context` is the recorder's name and the speaker ids the user has confirmed. It is text, not audio.
    public static func userPrompt(_ lines: [(index: Int, id: String, speaker: String, text: String)], context: String = "") -> String {
        let items: [[String: Any]] = lines.map { ["i": $0.index, "id": $0.id, "speaker": $0.speaker, "text": $0.text] }
        let data = (try? JSONSerialization.data(withJSONObject: ["segments": items], options: [.sortedKeys])) ?? Data()
        let draft = String(decoding: data, as: UTF8.self)
        let note = context.trimmingCharacters(in: .whitespacesAndNewlines)
        if note.isEmpty { return "Entire transcript:\n\(draft)" }
        return "\(note)\n\nEntire transcript:\n\(draft)"
    }

    /// Applies corrected lines onto the originals. A missing index keeps the local text.
    /// An empty `segments` array means nothing needed a rewrite. Throws if the reply is not that JSON,
    /// or if it lists lines and none of them apply.
    public static func apply(reply: String, originals: [String]) throws -> [String] {
        let json = jsonObject(in: reply)
        guard let root = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              let segments = root["segments"] as? [[String: Any]] else {
            throw HaikuBridgeError.badReply
        }
        var corrected = originals
        var applied = 0
        for item in segments {
            guard let index = intValue(item["i"]), originals.indices.contains(index),
                  let line = item["text"] as? String else { continue }
            let trimmed = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !trimmed.isEmpty else { continue }
            corrected[index] = trimmed
            applied += 1
        }
        if segments.isEmpty { return corrected }
        guard applied > 0 else { throw HaikuBridgeError.badReply }
        return corrected
    }

    private static func jsonObject(in reply: String) -> String {
        var text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start <= end {
            text = String(text[start...end])
        }
        return text
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }
}
