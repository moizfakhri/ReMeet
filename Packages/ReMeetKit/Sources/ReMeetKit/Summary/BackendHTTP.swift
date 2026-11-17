import Foundation

/// Request bodies and reply parsing for the HTTP summarizers. Pure, so they are unit-tested.
public enum OpenAICompatible {
    /// POST <server>/v1/chat/completions (LM Studio).
    public static func body(model: String?, system: String, user: String, maxTokens: Int = 2_048) -> Data {
        var object: [String: Any] = [
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
            "temperature": 0.2,
            "max_tokens": maxTokens,
            "stream": false,
        ]
        if let model, !model.isEmpty { object["model"] = model }
        return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    public static func text(from data: Data) throws -> String {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw BackendError.badReply("not JSON") }
        if let error = root["error"] {
            let message = (error as? [String: Any])?["message"] as? String ?? "\(error)"
            throw BackendError.server(message)
        }
        guard let choices = root["choices"] as? [[String: Any]], let first = choices.first,
              let message = first["message"] as? [String: Any], let content = message["content"] as? String else {
            throw BackendError.badReply("no choices[0].message.content")
        }
        return content
    }

    /// GET <server>/api/v0/models (LM Studio): the loaded model's id and context length.
    public static func loadedModel(from data: Data) -> (id: String, context: Int)? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["data"] as? [[String: Any]] else { return nil }
        let loaded = models.first { ($0["state"] as? String) == "loaded" && ($0["type"] as? String) != "embeddings" }
        guard let loaded, let id = loaded["id"] as? String else { return nil }
        let context = loaded["loaded_context_length"] as? Int ?? loaded["max_context_length"] as? Int ?? 8_192
        return (id, context)
    }

    /// A loaded LM Studio embeddings model, if the local server has one.
    public static func loadedEmbeddingModel(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["data"] as? [[String: Any]] else { return nil }
        let loaded = models.first { ($0["state"] as? String) == "loaded" && ($0["type"] as? String) == "embeddings" }
        guard let id = loaded?["id"] as? String, !id.isEmpty else { return nil }
        return id
    }

    /// POST <server>/v1/embeddings (LM Studio, OpenAI-compatible).
    public static func embeddingsBody(model: String, input: [String]) -> Data {
        var object: [String: Any] = ["input": input]
        if !model.isEmpty { object["model"] = model }
        return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// Embeddings in request order. JSON numbers arrive as NSNumber, not Swift Double.
    public static func embeddings(from data: Data) throws -> [[Float]] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BackendError.badReply("not JSON")
        }
        if let error = root["error"] {
            let message = (error as? [String: Any])?["message"] as? String ?? "\(error)"
            throw BackendError.server(message)
        }
        guard let rows = root["data"] as? [[String: Any]], !rows.isEmpty else {
            throw BackendError.badReply("no embeddings")
        }
        var ordered: [(Int, [Float])] = []
        ordered.reserveCapacity(rows.count)
        for (fallback, item) in rows.enumerated() {
            guard let raw = item["embedding"] as? [Any], !raw.isEmpty else {
                throw BackendError.badReply("bad embedding")
            }
            let vector = raw.compactMap { ($0 as? NSNumber)?.floatValue }
            guard vector.count == raw.count else { throw BackendError.badReply("bad embedding") }
            let index = item["index"] as? Int ?? fallback
            ordered.append((index, vector))
        }
        return ordered.sorted { $0.0 < $1.0 }.map(\.1)
    }
}


public enum BackendError: LocalizedError, Equatable {
    case badReply(String)
    case server(String)
    case notConfigured(String)
    case unreachable(String)

    public var errorDescription: String? {
        switch self {
        case .badReply(let d): "The summary service sent an unexpected reply (\(d))."
        case .server(let m): "The summary service reported an error: \(m)"
        case .notConfigured(let m): m
        case .unreachable(let m): m
        }
    }
}
