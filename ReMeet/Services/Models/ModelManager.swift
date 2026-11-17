import FluidAudio
import Foundation
import Observation
import ReMeetKit

/// Downloads, tracks and deletes the local models, all under
/// `~/Library/Application Support/ReMeet/Models`. A model counts as ready once its download
/// finished and was verified (recorded in manifest.json), so a half-finished download is
/// never mistaken for a usable one.
@MainActor
@Observable
final class ModelManager {
    enum State: Equatable {
        case missing
        case downloading(Double)
        case ready
        case failed(String)

        var isReady: Bool { self == .ready }
    }

    private struct Manifest: Codable {
        var completed: [String: Date] = [:]
    }

    static let defaultRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ReMeet/Models", isDirectory: true)

    let root: URL
    private(set) var states: [ModelID: State] = [:]
    /// Called on main when a model becomes ready (the pipeline retries waiting meetings).
    @ObservationIgnored var onReady: ((ModelID) -> Void)?
    @ObservationIgnored private var tasks: [ModelID: Task<Void, Never>] = [:]

    init(root: URL = ModelManager.defaultRoot) {
        self.root = root
        refresh()
    }

    /// Deletes model folders older builds downloaded that nothing loads any more (the Core ML
    /// Cohere builds, ~2 GB). Off the main thread.
    func removeRetiredModels() {
        let folders = ModelID.retiredFolders.map { root.appendingPathComponent($0, isDirectory: true) }
        Task.detached(priority: .utility) {
            for folder in folders where FileManager.default.fileExists(atPath: folder.path) {
                try? FileManager.default.removeItem(at: folder)
            }
        }
    }

    func state(_ id: ModelID) -> State { states[id] ?? .missing }
    func isReady(_ id: ModelID) -> Bool { state(id).isReady }
    var isDownloadingAny: Bool { states.values.contains { if case .downloading = $0 { true } else { false } } }

    /// Overall progress of everything currently downloading, for the first-launch screen.
    var overallProgress: Double? {
        let active = states.compactMap { id, state -> (ModelID, Double)? in
            if case .downloading(let p) = state { return (id, p) }
            return nil
        }
        guard !active.isEmpty else { return nil }
        let total = active.reduce(0.0) { $0 + Double($1.0.approximateBytes) }
        return active.reduce(0.0) { $0 + Double($1.0.approximateBytes) * $1.1 } / max(total, 1)
    }

    /// Folder a model lives in (what FluidAudio / MLX load from).
    func directory(_ id: ModelID) -> URL {
        switch id {
        case .diarizer: root.appendingPathComponent(Repo.diarizer.folderName, isDirectory: true)
        case .parakeet: root.appendingPathComponent(Repo.parakeetV2.folderName, isDirectory: true)
        case .cohere, .summaryLLM: root.appendingPathComponent(id.huggingFaceRepo!.replacingOccurrences(of: "/", with: "_"), isDirectory: true)
        }
    }

    func refresh() {
        let manifest = readManifest()
        for id in ModelID.allCases {
            if case .downloading = state(id) { continue }
            let present = manifest.completed[id.rawValue] != nil
                && FileManager.default.fileExists(atPath: directory(id).path)
            states[id] = present ? .ready : .missing
        }
    }

    func sizeOnDisk(_ id: ModelID) -> Int64 {
        let url = directory(id)
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// Starts every missing model in `ids` (first launch: the required set).
    func downloadMissing(_ ids: [ModelID]) {
        for id in ids where !isReady(id) { download(id) }
    }

    func download(_ id: ModelID) {
        guard tasks[id] == nil else { return }
        states[id] = .downloading(0)
        let root = root
        let directory = directory(id)
        tasks[id] = Task { [weak self] in
            let progress: @Sendable (Double) -> Void = { value in
                Task { @MainActor in
                    guard let self, case .downloading = self.state(id) else { return }
                    self.states[id] = .downloading(min(max(value, 0), 1))
                }
            }
            do {
                try await Self.fetch(id, root: root, directory: directory, progress: progress)
                guard let self else { return }
                self.markCompleted(id)
                self.states[id] = .ready
                self.onReady?(id)
            } catch is CancellationError {
                self?.states[id] = .missing
            } catch {
                self?.states[id] = .failed(error.localizedDescription)
            }
            self?.tasks[id] = nil
        }
    }

    func cancel(_ id: ModelID) {
        tasks[id]?.cancel()
    }

    func delete(_ id: ModelID) {
        cancel(id)
        try? FileManager.default.removeItem(at: directory(id))
        var manifest = readManifest()
        manifest.completed[id.rawValue] = nil
        writeManifest(manifest)
        states[id] = .missing
    }

    // MARK: - Fetching

    private nonisolated static func fetch(_ id: ModelID, root: URL, directory: URL,
                                          progress: @escaping @Sendable (Double) -> Void) async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        switch id {
        case .diarizer:
            // Downloads into root/<repo folder> and compiles for this Mac; the loaded models
            // are dropped right away (the diarize stage loads them again when needed).
            _ = try await OfflineDiarizerModels.load(from: root) { progress($0.fractionCompleted) }
        case .parakeet:
            _ = try await AsrModels.download(to: directory, version: .v2) { progress($0.fractionCompleted) }
            guard AsrModels.modelsExist(at: directory, version: .v2) else {
                throw ModelError.incomplete(id.displayName)
            }
        case .cohere:
            try await HFDownloader().download(repo: id.huggingFaceRepo!, into: directory, include: id.includes, progress: progress)
            for required in ["config.json", "model.safetensors", "tokenizer.model", "tokenizer_config.json"]
            where !FileManager.default.fileExists(atPath: directory.appendingPathComponent(required).path) {
                throw ModelError.incomplete(id.displayName)
            }
        case .summaryLLM:
            try await HFDownloader().download(repo: id.huggingFaceRepo!, into: directory, progress: progress)
            for required in ["config.json", "tokenizer.json"]
            where !FileManager.default.fileExists(atPath: directory.appendingPathComponent(required).path) {
                throw ModelError.incomplete(id.displayName)
            }
        }
    }

    enum ModelError: LocalizedError {
        case incomplete(String)
        var errorDescription: String? {
            switch self {
            case .incomplete(let name): "\(name) did not download completely. Try again."
            }
        }
    }

    // MARK: - Manifest

    private var manifestURL: URL { root.appendingPathComponent("manifest.json") }

    private func readManifest() -> Manifest {
        (try? JSONCoding.read(Manifest.self, from: manifestURL)) ?? Manifest()
    }

    private func writeManifest(_ manifest: Manifest) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? JSONCoding.write(manifest, to: manifestURL)
    }

    private func markCompleted(_ id: ModelID) {
        var manifest = readManifest()
        manifest.completed[id.rawValue] = Date()
        writeManifest(manifest)
    }
}
