import Foundation

/// Float32 blobs stored on chunk rows, and cosine similarity for hybrid retrieval.
/// Native endianness: the index is a local cache and is never copied between machines.
public enum ChunkEmbedding {
    public static func encode(_ vector: [Float]) -> Data {
        var vector = vector
        return Data(bytes: &vector, count: vector.count * MemoryLayout<Float>.size)
    }

    public static func decode(_ data: Data) -> [Float]? {
        let width = MemoryLayout<Float>.size
        guard data.count >= width, data.count.isMultiple(of: width) else { return nil }
        return data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return nil }
            let buffer = base.assumingMemoryBound(to: Float.self)
            return Array(UnsafeBufferPointer(start: buffer, count: data.count / width))
        }
    }

    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        SpeakerMemory.cosine(a, b)
    }
}

/// Cosine candidates, then FTS rerank on that set. Higher cosine is better. Lower FTS rank is better.
public enum ChunkHybridRank {
    public struct Candidate: Equatable, Sendable {
        public var id: String
        public var meetingID: String
        public var cosine: Float
        public var ftsRank: Double?

        public init(id: String, meetingID: String, cosine: Float, ftsRank: Double?) {
            self.id = id
            self.meetingID = meetingID
            self.cosine = cosine
            self.ftsRank = ftsRank
        }
    }

    /// Summary and notes are slightly closer so a decision line can beat a nearby turn.
    public static func boostedCosine(_ score: Float, kind: MeetingChunk.Kind) -> Float {
        switch kind {
        case .summary: score * 1.12
        case .note: score * 1.06
        case .turn: score
        }
    }

    /// Lexical matches inside the cosine set first, then cosine-only hits. Caps chunks per meeting.
    public static func order(_ candidates: [Candidate], limit: Int, maxPerMeeting: Int) -> [String] {
        let lexical = candidates.filter { $0.ftsRank != nil }.sorted { lhs, rhs in
            let left = lhs.ftsRank ?? 0
            let right = rhs.ftsRank ?? 0
            if left != right { return left < right }
            return lhs.cosine > rhs.cosine
        }
        let semantic = candidates.filter { $0.ftsRank == nil }.sorted { $0.cosine > $1.cosine }
        var perMeeting: [String: Int] = [:]
        var out: [String] = []
        for candidate in lexical + semantic {
            let count = perMeeting[candidate.meetingID, default: 0]
            guard count < maxPerMeeting else { continue }
            perMeeting[candidate.meetingID] = count + 1
            out.append(candidate.id)
            if out.count >= limit { break }
        }
        return out
    }
}
