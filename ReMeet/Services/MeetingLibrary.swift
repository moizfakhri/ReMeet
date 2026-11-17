import AVFoundation
import Foundation
import Observation
import ReMeetKit

/// One row in the sidebar or the menu bar's recent list.
struct MeetingItem: Identifiable, Equatable {
    var folder: MeetingFolder
    var meta: MeetingMeta
    var id: String { folder.id }
}

/// The meetings on disk. meta.json in each folder is the source of truth; this is a cache
/// that reloads whenever the recorder or the pipeline changes something.
@MainActor
@Observable
final class MeetingLibrary {
    private(set) var items: [MeetingItem] = []
    /// The user's folders (collections.json next to the meetings folder).
    private(set) var collections: [MeetingCollection] = []
    var root: URL {
        didSet { loadCollections() }
    }

    init(root: URL = MeetingFolder.defaultRoot) {
        self.root = root
        loadCollections()
    }

    // MARK: - Folders

    private var collectionsFile: CollectionsFile {
        CollectionsFile(url: root.deletingLastPathComponent().appendingPathComponent("collections.json"))
    }

    func loadCollections() {
        collections = collectionsFile.load()
    }

    @discardableResult
    func createCollection(named name: String) -> MeetingCollection? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let collection = MeetingCollection(name: trimmed)
        saveCollections(collections + [collection])
        return collection
    }

    func updateCollection(_ id: String, name: String? = nil, context: String? = nil) {
        var list = collections
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            list[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let context { list[index].context = context }
        saveCollections(list)
    }

    /// Removes the folder; its meetings stay, just without a folder.
    func deleteCollection(_ id: String) {
        for item in items where item.meta.collectionID == id { move(item.folder, to: nil) }
        saveCollections(collections.filter { $0.id != id })
    }

    func move(_ folder: MeetingFolder, to collectionID: String?) {
        _ = try? folder.updateMeta { $0.collectionID = collectionID }
        refresh(folder)
        onEdited?(folder)
    }

    /// Drag a folder to a new place in the list.
    func moveCollection(_ id: String, before target: String) {
        saveCollections(SidebarList.reordered(collections, moving: id, before: target))
    }

    func collection(_ id: String?) -> MeetingCollection? {
        id.flatMap { id in collections.first { $0.id == id } }
    }

    private func saveCollections(_ list: [MeetingCollection]) {
        try? FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? collectionsFile.save(list)
        collections = list
    }

    @ObservationIgnored private var generation = 0
    /// Completions of reloads not applied yet. A newer reload supersedes an older scan but
    /// must still run its completion (launch queues pending meetings in one); they all run
    /// once the newest scan is in.
    @ObservationIgnored private var pendingCompletions: [() -> Void] = []

    /// Rescans the meetings folder on a background thread and applies the result on main
    /// (a stale scan never overwrites a newer one). `then` runs after the update.
    func reload(then: (() -> Void)? = nil) {
        generation += 1
        let mine = generation
        let root = root
        if let then { pendingCompletions.append(then) }
        Task {
            let scanned = await Task.detached(priority: .userInitiated) { Self.scan(root) }.value
            guard mine == self.generation else { return }
            if scanned != self.items { self.items = scanned }
            let completions = self.pendingCompletions
            self.pendingCompletions = []
            completions.forEach { $0() }
        }
    }

    /// Synchronous rescan, for snapshots, self-tests and one-off recovery.
    func reloadNow() {
        generation += 1
        items = Self.scan(root)
        let completions = pendingCompletions
        pendingCompletions = []
        completions.forEach { $0() }
    }

    nonisolated private static func scan(_ root: URL) -> [MeetingItem] {
        MeetingFolder.scan(root: root).compactMap { folder in
            guard let meta = try? folder.readMeta() else { return nil }
            return MeetingItem(folder: folder, meta: meta)
        }
        .sorted { $0.meta.startTime > $1.meta.startTime }
    }

    func item(for folder: MeetingFolder) -> MeetingItem? {
        items.first { $0.folder == folder }
    }

    /// Re-reads one meeting's meta.json (after a pipeline step) without rescanning everything.
    func refresh(_ folder: MeetingFolder) {
        // One small meta.json: cheap enough to read here (<1 ms).
        guard let meta = try? folder.readMeta() else {
            reload()
            return
        }
        if let index = items.firstIndex(where: { $0.folder == folder }) {
            items[index].meta = meta
        } else {
            reload()
        }
    }

    /// Called after a user edit (rename, notes) so search stays current.
    var onEdited: ((MeetingFolder) -> Void)?
    /// Called after a meeting is moved to the Trash so queues, badges and search stay clean.
    var onTrashed: ((MeetingFolder) -> Void)?

    func rename(_ folder: MeetingFolder, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        _ = try? folder.updateMeta {
            $0.title = trimmed
            $0.titleIsUserSet = true
        }
        refresh(folder)
        onEdited?(folder)
        Task.detached(priority: .utility) { folder.rewriteMarkdown() }
    }

    /// Moves the folder to the Trash (recoverable), never deletes outright.
    func moveToTrash(_ folder: MeetingFolder) throws {
        try FileManager.default.trashItem(at: folder.url, resultingItemURL: nil)
        items.removeAll { $0.folder == folder }
        onTrashed?(folder)
    }

    /// Meetings whose meta.json still says "recording" but that are not the live recording:
    /// ReMeet quit or crashed mid-call. Repairs the WAV headers and marks them recorded so the
    /// pipeline picks them up. Returns the folders it fixed.
    @discardableResult
    func recoverInterruptedRecordings(except live: MeetingFolder?) -> [MeetingFolder] {
        var fixed: [MeetingFolder] = []
        for folder in MeetingFolder.scan(root: root) where folder != live {
            guard var meta = try? folder.readMeta(), meta.status == .recording else { continue }
            var durations: [Double] = []
            for file in [MeetingFolder.File.micWAV, .systemWAV] where folder.exists(file) {
                _ = try? WAVRepair.repair(folder.file(file))
                if let audio = try? AVAudioFile(forReading: folder.file(file)) {
                    durations.append(Double(audio.length) / audio.fileFormat.sampleRate)
                }
            }
            meta.durationSeconds = durations.max() ?? 0
            meta.endTime = meta.startTime.addingTimeInterval(meta.durationSeconds ?? 0)
            meta.status = .recorded
            meta.events.append(SessionEvent(time: Date(), offsetSeconds: meta.durationSeconds ?? 0,
                                            type: "recovered_after_interruption",
                                            detail: "ReMeet stopped before the recording was finalized; WAV headers repaired"))
            if (try? folder.writeMeta(meta)) != nil { fixed.append(folder) }
        }
        if !fixed.isEmpty { reloadNow() }
        return fixed
    }
}
