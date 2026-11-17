import Foundation
import GRDB

/// FTS5 index of per-meeting chunks for RAG retrieval, with an optional embedding blob per chunk.
/// Lives beside `index.sqlite` as `chunks.sqlite`. Same sync cadence as the meeting-level search index.
/// Embeddings are filled when a local model is available and left null otherwise, so search falls back to FTS.
public final class ChunkIndex: @unchecked Sendable {
    public struct RetrievedChunk: Sendable, Equatable {
        public var chunk: MeetingChunk
        public var rank: Double
        public var meetingTitle: String
    }

    public struct MeetingRef: Sendable {
        public var id: String
        public var collectionID: String?
        public var title: String
    }

    private struct StoredMeta {
        var fingerprint: String
        var collectionID: String?
        var title: String
        var embeddingModel: String?
    }

    private struct PriorChunk {
        var text: String
        var embedding: Data?
    }

    private let db: DatabaseQueue

    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        db = try DatabaseQueue(path: url.path)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE meeting_chunk_meta (
                    id TEXT PRIMARY KEY,
                    path TEXT NOT NULL,
                    fingerprint TEXT NOT NULL,
                    collection_id TEXT,
                    title TEXT NOT NULL
                );
                CREATE TABLE chunk (
                    id TEXT PRIMARY KEY,
                    meeting_id TEXT NOT NULL,
                    start REAL NOT NULL,
                    end REAL NOT NULL,
                    speaker TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    text TEXT NOT NULL
                );
                CREATE INDEX chunk_meeting ON chunk(meeting_id);
                CREATE VIRTUAL TABLE chunk_fts USING fts5(
                    text,
                    meeting_id UNINDEXED,
                    chunk_id UNINDEXED,
                    tokenize = 'porter unicode61 remove_diacritics 2'
                );
                """)
        }
        migrator.registerMigration("v2") { db in
            try db.execute(sql: "ALTER TABLE chunk ADD COLUMN embedding BLOB")
            try db.execute(sql: "ALTER TABLE meeting_chunk_meta ADD COLUMN embedding_model TEXT")
        }
        try migrator.migrate(db)
    }

    /// `embed` returns one vector per text, or nil when the local model is unavailable.
    /// A nil result keeps any embeddings whose text did not change.
    public func sync(root: URL, embeddingModel: String? = nil,
                     embed: (@Sendable ([String]) async -> [[Float]]?)? = nil) async throws {
        let folders = MeetingFolder.scan(root: root)
        var seen = Set<String>()
        for folder in folders {
            seen.insert(folder.id)
            try await refresh(folder, embeddingModel: embeddingModel, embed: embed)
        }
        let known = try storedMetas()
        let gone = Set(known.keys).subtracting(seen)
        if !gone.isEmpty { try delete(ids: gone) }
    }

    private func delete(ids: Set<String>) throws {
        try db.write { db in
            for id in ids {
                try db.execute(sql: "DELETE FROM meeting_chunk_meta WHERE id = ?", arguments: [id])
                try db.execute(sql: "DELETE FROM chunk WHERE meeting_id = ?", arguments: [id])
                try db.execute(sql: "DELETE FROM chunk_fts WHERE meeting_id = ?", arguments: [id])
            }
        }
    }

    /// Reindexes chunk text when notes, transcript, summary, or speakers change.
    /// A folder-only change updates `collection_id` without rebuilding chunks or embeddings.
    public func refresh(_ folder: MeetingFolder, embeddingModel: String? = nil,
                        embed: (@Sendable ([String]) async -> [[Float]]?)? = nil) async throws {
        guard let meta = try? folder.readMeta() else { return }
        let content = Self.contentFingerprint(folder)
        let stored = try storedMetas()[folder.id]
        let contentChanged = stored?.fingerprint != content
        let embedStale = embeddingModel != nil && stored?.embeddingModel != embeddingModel
        let membershipChanged = stored?.collectionID != meta.collectionID || stored?.title != meta.title
        if stored == nil || contentChanged || embedStale {
            let chunks = MeetingChunkBuilder.build(meetingID: folder.id, meta: meta,
                                                   transcript: try? folder.read(Transcript.self, .transcript),
                                                   summary: try? folder.read(MeetingSummary.self, .summary),
                                                   notes: NotesFile(url: folder.file(.notes)).load(),
                                                   speakers: ((try? folder.read(SpeakerNames.self, .speakers)) ?? nil) ?? SpeakerNames())
            var fresh: [String: [Float]]?
            if let embed, embeddingModel != nil,
               let vectors = await embed(chunks.map(\.text)),
               vectors.count == chunks.count,
               !vectors.isEmpty,
               vectors.allSatisfy({ !$0.isEmpty }) {
                var map: [String: [Float]] = [:]
                for (chunk, vector) in zip(chunks, vectors) { map[chunk.id] = vector }
                fresh = map
            }
            if fresh == nil, embedStale, !contentChanged, stored != nil {
                if membershipChanged {
                    try updateMembership(id: folder.id, collectionID: meta.collectionID, title: meta.title)
                }
                return
            }
            try index(folder, fingerprint: content, embeddings: fresh,
                      embeddingModel: fresh == nil ? nil : embeddingModel)
        } else if membershipChanged {
            try updateMembership(id: folder.id, collectionID: meta.collectionID, title: meta.title)
        }
    }

    /// `embeddings == nil` keeps stored vectors whose text is unchanged. A dictionary replaces them.
    public func index(_ folder: MeetingFolder, fingerprint: String? = nil,
                      embeddings: [String: [Float]]? = nil, embeddingModel: String? = nil) throws {
        guard let meta = try? folder.readMeta() else { return }
        let notes = NotesFile(url: folder.file(.notes)).load()
        let transcript = try? folder.read(Transcript.self, .transcript)
        let summary = try? folder.read(MeetingSummary.self, .summary)
        let speakers = ((try? folder.read(SpeakerNames.self, .speakers)) ?? nil) ?? SpeakerNames()
        let chunks = MeetingChunkBuilder.build(meetingID: folder.id, meta: meta, transcript: transcript,
                                               summary: summary, notes: notes, speakers: speakers)
        let print = fingerprint ?? Self.contentFingerprint(folder)
        try db.write { db in
            let prior = try Self.priorChunks(db: db, meetingID: folder.id)
            let priorModel = try String.fetchOne(db, sql: "SELECT embedding_model FROM meeting_chunk_meta WHERE id = ?",
                                                  arguments: [folder.id])
            try db.execute(sql: "DELETE FROM chunk WHERE meeting_id = ?", arguments: [folder.id])
            try db.execute(sql: "DELETE FROM chunk_fts WHERE meeting_id = ?", arguments: [folder.id])
            var blobs: [String: Data] = [:]
            for chunk in chunks {
                let blob: Data?
                if let embeddings {
                    blob = embeddings[chunk.id].map(ChunkEmbedding.encode)
                } else if let kept = prior[chunk.id], kept.text == chunk.text {
                    blob = kept.embedding
                } else {
                    blob = nil
                }
                if let blob, !blob.isEmpty { blobs[chunk.id] = blob }
                try db.execute(sql: """
                    INSERT INTO chunk (id, meeting_id, start, end, speaker, kind, text, embedding)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [chunk.id, chunk.meetingID, chunk.start, chunk.end, chunk.speaker,
                                     chunk.kind.rawValue, chunk.text, blobs[chunk.id]])
                try db.execute(sql: "INSERT INTO chunk_fts (text, meeting_id, chunk_id) VALUES (?, ?, ?)",
                               arguments: [chunk.text, chunk.meetingID, chunk.id])
            }
            let complete = !chunks.isEmpty && chunks.allSatisfy { blobs[$0.id] != nil }
            let model: String? = if embeddings != nil, complete {
                embeddingModel
            } else if embeddings == nil, complete {
                priorModel
            } else {
                nil
            }
            try db.execute(sql: """
                INSERT OR REPLACE INTO meeting_chunk_meta (id, path, fingerprint, collection_id, title, embedding_model)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [folder.id, folder.url.path, print, meta.collectionID, meta.title, model])
        }
    }

    /// Folder membership or title changed. Chunk text and embeddings stay.
    public func updateMembership(id: String, collectionID: String?, title: String) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE meeting_chunk_meta SET collection_id = ?, title = ? WHERE id = ?",
                           arguments: [collectionID, title, id])
        }
    }

    public func remove(id: String) throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM meeting_chunk_meta WHERE id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM chunk WHERE meeting_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM chunk_fts WHERE meeting_id = ?", arguments: [id])
        }
    }

    /// BM25 search, or cosine top-K reranked by FTS when `queryEmbedding` is present.
    /// Missing embeddings, or a query the embedder could not encode, use FTS only.
    public func retrieve(_ query: String,
                         limit: Int = 16,
                         maxPerMeeting: Int = 4,
                         meetingIDs: Set<String>? = nil,
                         collectionID: String? = nil,
                         queryEmbedding: [Float]? = nil,
                         cosinePool: Int = 48) throws -> [RetrievedChunk] {
        if let queryEmbedding, !queryEmbedding.isEmpty,
           let hybrid = try hybridRetrieve(query, limit: limit, maxPerMeeting: maxPerMeeting,
                                           meetingIDs: meetingIDs, collectionID: collectionID,
                                           queryEmbedding: queryEmbedding, cosinePool: cosinePool) {
            return hybrid
        }
        return try ftsRetrieve(query, limit: limit, maxPerMeeting: maxPerMeeting,
                               meetingIDs: meetingIDs, collectionID: collectionID)
    }

    public func meetingTitle(for id: String) throws -> String? {
        try db.read { db in
            try String.fetchOne(db, sql: "SELECT title FROM meeting_chunk_meta WHERE id = ?", arguments: [id])
        }
    }

    public func collectionID(for meetingID: String) throws -> String? {
        try db.read { db in
            try String.fetchOne(db, sql: "SELECT collection_id FROM meeting_chunk_meta WHERE id = ?", arguments: [meetingID])
        }
    }

    public func embedding(for chunkID: String) throws -> [Float]? {
        try db.read { db in
            guard let blob = try Data.fetchOne(db, sql: "SELECT embedding FROM chunk WHERE id = ?", arguments: [chunkID]) else {
                return nil
            }
            return ChunkEmbedding.decode(blob)
        }
    }

    /// Modification times of every file the meeting search index reads, including meta.json.
    public static func fingerprint(_ folder: MeetingFolder) -> String {
        stamp(SearchIndexFingerprint.files, folder)
    }

    /// Chunk text inputs only. Folder membership lives in meta.json and is applied on its own.
    public static func contentFingerprint(_ folder: MeetingFolder) -> String {
        stamp([.notes, .transcript, .summary, .speakers], folder)
    }

    private static func stamp(_ files: [MeetingFolder.File], _ folder: MeetingFolder) -> String {
        files.map { file in
            let date = (try? FileManager.default.attributesOfItem(atPath: folder.file(file).path)[.modificationDate]) as? Date
            return date.map { String(Int($0.timeIntervalSince1970 * 1000)) } ?? "-"
        }.joined(separator: ",")
    }

    private func storedMetas() throws -> [String: StoredMeta] {
        try db.read { db in
            var result: [String: StoredMeta] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT id, fingerprint, collection_id, title, embedding_model FROM meeting_chunk_meta
                """) {
                let id: String = row["id"]
                let collection: String? = row["collection_id"]
                let model: String? = row["embedding_model"]
                result[id] = StoredMeta(fingerprint: row["fingerprint"], collectionID: collection,
                                        title: row["title"], embeddingModel: model)
            }
            return result
        }
    }

    private static func priorChunks(db: Database, meetingID: String) throws -> [String: PriorChunk] {
        var result: [String: PriorChunk] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT id, text, embedding FROM chunk WHERE meeting_id = ?",
                                    arguments: [meetingID]) {
            let id: String = row["id"]
            let text: String = row["text"]
            let blob: Data? = row["embedding"]
            result[id] = PriorChunk(text: text, embedding: blob)
        }
        return result
    }

    private func ftsRetrieve(_ query: String, limit: Int, maxPerMeeting: Int,
                             meetingIDs: Set<String>?, collectionID: String?) throws -> [RetrievedChunk] {
        guard let fts = SearchText.ftsQuery(query) else { return [] }
        let pool = min(max(limit * 4, 40), 120)
        let rows: [(MeetingChunk, Double, String)] = try db.read { db in
            let (sql, args) = Self.matchSQL(fts: fts, pool: pool, meetingIDs: meetingIDs, collectionID: collectionID,
                                            chunkIDs: nil)
            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)).compactMap { row in
                guard let kind = MeetingChunk.Kind(rawValue: row["kind"]) else { return nil }
                let chunk = MeetingChunk(id: row["id"], meetingID: row["meeting_id"], start: row["start"],
                                         end: row["end"], speaker: row["speaker"], kind: kind, text: row["text"])
                let rank = (row["rank"] as Double?) ?? 0
                let title: String = row["title"]
                return (chunk, Self.boostedRank(rank, kind: kind), title)
            }
        }
        return Self.capped(rows.sorted { $0.1 < $1.1 }, limit: limit, maxPerMeeting: maxPerMeeting)
    }

    /// Nil when nothing in scope has a usable embedding, so the caller can use FTS alone.
    private func hybridRetrieve(_ query: String, limit: Int, maxPerMeeting: Int,
                                meetingIDs: Set<String>?, collectionID: String?,
                                queryEmbedding: [Float], cosinePool: Int) throws -> [RetrievedChunk]? {
        let rows = try loadEmbedded(meetingIDs: meetingIDs, collectionID: collectionID, width: queryEmbedding.count)
        guard !rows.isEmpty else { return nil }
        let scored = rows.map { row -> (MeetingChunk, String, Float) in
            let score = ChunkHybridRank.boostedCosine(
                ChunkEmbedding.cosine(queryEmbedding, row.embedding), kind: row.chunk.kind)
            return (row.chunk, row.title, score)
        }.sorted { $0.2 > $1.2 }
        let top = Array(scored.prefix(max(cosinePool, 1)))
        let ranks = try ftsRanks(query: query, ids: top.map(\.0.id))
        let candidates = top.map { chunk, _, score in
            ChunkHybridRank.Candidate(
                id: chunk.id, meetingID: chunk.meetingID, cosine: score,
                ftsRank: ranks[chunk.id].map { Self.boostedRank($0, kind: chunk.kind) })
        }
        let ordered = ChunkHybridRank.order(candidates, limit: limit, maxPerMeeting: maxPerMeeting)
        let byID = Dictionary(uniqueKeysWithValues: top.map { ($0.0.id, $0) })
        return ordered.compactMap { id in
            guard let (chunk, title, score) = byID[id] else { return nil }
            return RetrievedChunk(chunk: chunk, rank: Double(score), meetingTitle: title)
        }
    }

    private struct EmbeddedRow {
        var chunk: MeetingChunk
        var title: String
        var embedding: [Float]
    }

    private func loadEmbedded(meetingIDs: Set<String>?, collectionID: String?, width: Int) throws -> [EmbeddedRow] {
        try db.read { db in
            var sql = """
                SELECT c.id, c.meeting_id, c.start, c.end, c.speaker, c.kind, c.text, c.embedding, m.title
                FROM chunk c
                JOIN meeting_chunk_meta m ON m.id = c.meeting_id
                WHERE c.embedding IS NOT NULL
                """
            var args: [DatabaseValueConvertible] = []
            if let meetingIDs, !meetingIDs.isEmpty {
                sql += " AND c.meeting_id IN (\(meetingIDs.map { _ in "?" }.joined(separator: ",")))"
                args += Array(meetingIDs)
            }
            if let collectionID {
                sql += " AND m.collection_id = ?"
                args.append(collectionID)
            }
            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)).compactMap { row in
                guard let kind = MeetingChunk.Kind(rawValue: row["kind"]),
                      let blob: Data = row["embedding"],
                      let vector = ChunkEmbedding.decode(blob),
                      vector.count == width else { return nil }
                let chunk = MeetingChunk(id: row["id"], meetingID: row["meeting_id"], start: row["start"],
                                         end: row["end"], speaker: row["speaker"], kind: kind, text: row["text"])
                let title: String = row["title"]
                return EmbeddedRow(chunk: chunk, title: title, embedding: vector)
            }
        }
    }

    private func ftsRanks(query: String, ids: [String]) throws -> [String: Double] {
        guard let fts = SearchText.ftsQuery(query), !ids.isEmpty else { return [:] }
        return try db.read { db in
            let placeholders = ids.map { _ in "?" }.joined(separator: ",")
            var args: [DatabaseValueConvertible] = [fts]
            args += ids
            let rows = try Row.fetchAll(db, sql: """
                SELECT chunk_id, bm25(chunk_fts) AS rank
                FROM chunk_fts
                WHERE chunk_fts MATCH ? AND chunk_id IN (\(placeholders))
                """, arguments: StatementArguments(args))
            var ranks: [String: Double] = [:]
            for row in rows {
                let id: String = row["chunk_id"]
                ranks[id] = (row["rank"] as Double?) ?? 0
            }
            return ranks
        }
    }

    private static func matchSQL(fts: String, pool: Int, meetingIDs: Set<String>?, collectionID: String?,
                                 chunkIDs: [String]?) -> (String, [DatabaseValueConvertible]) {
        var sql = """
            SELECT c.id, c.meeting_id, c.start, c.end, c.speaker, c.kind, c.text,
                   bm25(chunk_fts) AS rank, m.title
            FROM chunk_fts
            JOIN chunk c ON c.id = chunk_fts.chunk_id
            JOIN meeting_chunk_meta m ON m.id = c.meeting_id
            WHERE chunk_fts MATCH ?
            """
        var args: [DatabaseValueConvertible] = [fts]
        if let meetingIDs, !meetingIDs.isEmpty {
            sql += " AND c.meeting_id IN (\(meetingIDs.map { _ in "?" }.joined(separator: ",")))"
            args += Array(meetingIDs)
        }
        if let collectionID {
            sql += " AND m.collection_id = ?"
            args.append(collectionID)
        }
        if let chunkIDs, !chunkIDs.isEmpty {
            sql += " AND c.id IN (\(chunkIDs.map { _ in "?" }.joined(separator: ",")))"
            args += chunkIDs
        }
        sql += " ORDER BY rank LIMIT ?"
        args.append(pool)
        return (sql, args)
    }

    private static func capped(_ rows: [(MeetingChunk, Double, String)], limit: Int, maxPerMeeting: Int) -> [RetrievedChunk] {
        var perMeeting: [String: Int] = [:]
        var out: [RetrievedChunk] = []
        for (chunk, rank, title) in rows {
            let count = perMeeting[chunk.meetingID, default: 0]
            guard count < maxPerMeeting else { continue }
            perMeeting[chunk.meetingID] = count + 1
            out.append(RetrievedChunk(chunk: chunk, rank: rank, meetingTitle: title))
            if out.count >= limit { break }
        }
        return out
    }

    private static func boostedRank(_ rank: Double, kind: MeetingChunk.Kind) -> Double {
        switch kind {
        case .summary: rank * 0.85
        case .note: rank * 0.9
        case .turn: rank
        }
    }
}

/// Shared fingerprint inputs for meeting and chunk indexes.
public enum SearchIndexFingerprint {
    public static let files: [MeetingFolder.File] = [.meta, .notes, .transcript, .summary, .speakers]
}
