import Foundation
import Testing
@testable import ReMeetKit

struct ChunkHybridTests {
    @Test func ftsReranksTheCosineSetThenKeepsSemanticHits() {
        let candidates = [
            ChunkHybridRank.Candidate(id: "refunds", meetingID: "m1", cosine: 0.95, ftsRank: nil),
            ChunkHybridRank.Candidate(id: "workshop", meetingID: "m2", cosine: 0.4, ftsRank: -1.2),
            ChunkHybridRank.Candidate(id: "weak", meetingID: "m2", cosine: 0.7, ftsRank: -0.2),
            ChunkHybridRank.Candidate(id: "extra", meetingID: "m2", cosine: 0.99, ftsRank: -3),
        ]
        let ordered = ChunkHybridRank.order(candidates, limit: 3, maxPerMeeting: 2)
        #expect(ordered == ["extra", "workshop", "refunds"])
        #expect(ChunkHybridRank.boostedCosine(0.5, kind: .summary) > 0.55)
        #expect(ChunkHybridRank.boostedCosine(0.5, kind: .turn) == 0.5)
    }

    @Test func embeddingBlobRoundTrip() {
        let vector: [Float] = [0.25, -1, 0.5]
        let decoded = ChunkEmbedding.decode(ChunkEmbedding.encode(vector))
        #expect(decoded == vector)
        #expect(ChunkEmbedding.decode(Data()) == nil)
        #expect(ChunkEmbedding.cosine([1, 0], [1, 0]) > 0.99)
        #expect(abs(ChunkEmbedding.cosine([1, 0], [0, 1])) < 0.001)
    }
}
