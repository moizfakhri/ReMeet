import Foundation
import GRDB
import ReMeetKit

/// Full-text search over titles, notes, transcripts and summaries: `~/ReMeet/index.sqlite`
/// (GRDB, FTS5). It is only a cache: deleting it is harmless, a rescan rebuilds it.
/// All work runs on GRDB's own queue, never on the main thread.
final class SearchIndex: Sendable {
    struct Hit: Sendable, Equatable {
        var id: String
        var snippet: String
    }

    private let db: DatabaseQueue

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        db = try DatabaseQueue(path: url.path)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE meeting (
                    id TEXT PRIMARY KEY,
                    path TEXT NOT NULL,
                    fingerprint TEXT NOT NULL
                );
                CREATE VIRTUAL TABLE meeting_fts USING fts5(
                    id UNINDEXED, title, notes, transcript, summary,
                    tokenize = 'porter unicode61 remove_diacritics 2'
                );
                """)
        }
        try migrator.migrate(db)
    }

    /// Brings the index in line with the folders on disk: (re)indexes changed meetings,
    /// drops removed ones. Cheap when nothing changed (one stat per file).
    func sync(root: URL) throws {
        let folders = MeetingFolder.scan(root: root)
        let known = try db.read { db in
            try Dictionary(uniqueKeysWithValues: Row.fetchAll(db, sql: "SELECT id, fingerprint FROM meeting")
                .map { ($0["id"] as String, $0["fingerprint"] as String) })
        }
        var seen = Set<String>()
        for folder in folders {
            seen.insert(folder.id)
            let print = Self.fingerprint(folder)
            if known[folder.id] != print { try index(folder, fingerprint: print) }
        }
        let gone = Set(known.keys).subtracting(seen)
        if !gone.isEmpty {
            try db.write { db in
                for id in gone {
                    try db.execute(sql: "DELETE FROM meeting WHERE id = ?", arguments: [id])
                    try db.execute(sql: "DELETE FROM meeting_fts WHERE id = ?", arguments: [id])
                }
            }
        }
    }

    func index(_ folder: MeetingFolder, fingerprint: String? = nil) throws {
        guard let meta = try? folder.readMeta() else { return }
        let doc = SearchText.document(
            meta: meta,
            notes: NotesFile(url: folder.file(.notes)).load(),
            transcript: (try? folder.read(Transcript.self, .transcript)) ?? nil,
            summary: (try? folder.read(MeetingSummary.self, .summary)) ?? nil,
            speakers: ((try? folder.read(SpeakerNames.self, .speakers)) ?? nil) ?? SpeakerNames())
        let print = fingerprint ?? Self.fingerprint(folder)
        try db.write { db in
            try db.execute(sql: "DELETE FROM meeting_fts WHERE id = ?", arguments: [folder.id])
            try db.execute(sql: "INSERT INTO meeting_fts (id, title, notes, transcript, summary) VALUES (?, ?, ?, ?, ?)",
                           arguments: [folder.id, doc.title, doc.notes, doc.transcript, doc.summary])
            try db.execute(sql: "INSERT OR REPLACE INTO meeting (id, path, fingerprint) VALUES (?, ?, ?)",
                           arguments: [folder.id, folder.url.path, print])
        }
    }

    func remove(id: String) throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM meeting WHERE id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM meeting_fts WHERE id = ?", arguments: [id])
        }
    }

    /// Best matches first, with a short snippet around the hit.
    func search(_ text: String, limit: Int = 200) throws -> [Hit] {
        guard let query = SearchText.ftsQuery(text) else { return [] }
        return try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, snippet(meeting_fts, -1, '', '', '…', 10) AS snippet
                FROM meeting_fts WHERE meeting_fts MATCH ? ORDER BY bm25(meeting_fts, 0, 10, 4, 1, 2) LIMIT ?
                """, arguments: [query, limit])
                .map { Hit(id: $0["id"], snippet: $0["snippet"]) }
        }
    }

    /// Modification times of the files that feed the index.
    static func fingerprint(_ folder: MeetingFolder) -> String {
        ChunkIndex.fingerprint(folder)
    }
}
