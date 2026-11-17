import Foundation

/// Owns an RMChunkQueue. `raw` is captured by value in real-time callbacks so they never
/// touch Swift reference counting; keep the ChunkQueue alive for as long as any producer runs.
final class ChunkQueue {
    let raw: OpaquePointer

    init() {
        raw = RMChunkQueueCreate()
    }

    deinit {
        RMChunkQueueDestroy(raw)
    }

    var droppedChunks: UInt64 { RMChunkQueueDroppedChunks(raw) }

    /// Consumer side: hands each queued chunk to `body`, then releases its slot.
    func drain(_ body: (RMChunk) -> Void) {
        var chunk = RMChunk()
        while RMChunkQueuePeek(raw, &chunk) {
            body(chunk)
            RMChunkQueuePop(raw)
        }
    }
}
