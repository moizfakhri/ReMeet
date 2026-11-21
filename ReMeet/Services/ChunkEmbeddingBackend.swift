import Foundation
import MLX
import MLXEmbedders
import MLXLMCommon
import ReMeetKit

/// Local chunk vectors. LM Studio's embeddings model wins when one is loaded.
/// Otherwise an MLX embedder already on disk is used. Either miss leaves retrieval on FTS.
actor ChunkEmbeddingBackend {
    struct Session: Sendable {
        var modelID: String
        var embed: @Sendable ([String]) async -> [[Float]]?
    }

    private var mlxContainer: EmbedderModelContainer?
    private var mlxDirectory: String?
    private var mlxModelID: String?
    private var idleUnloadTask: Task<Void, Never>?

    /// Short-lived cache for LM Studio probe & MLX folder discovery so bursts of edits
    /// or pipeline ticks do not spam localhost HTTP requests or rescan Models/ every second.
    private var cachedProbe: (server: String?, modelsRoot: String, modelID: String?, lmStudioModel: String?, at: Date)?
    private static let probeTTL: TimeInterval = 30
    private static let idleUnloadSeconds: Double = 30

    private let probeSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 0.5
        config.timeoutIntervalForResource = 0.8
        return URLSession(configuration: config)
    }()

    private let embedSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 180
        return URLSession(configuration: config)
    }()

    /// Releases the loaded MLX embedder and clears MLX's reusable GPU buffer cache so idle
    /// memory stays flat and Metal teardown on quit never races an active model.
    func unload() {
        idleUnloadTask?.cancel()
        idleUnloadTask = nil
        guard mlxContainer != nil else { return }
        Stream.defaultStream.synchronize()
        mlxContainer = nil
        mlxDirectory = nil
        mlxModelID = nil
        Memory.clearCache()
    }

    private func scheduleIdleUnload() {
        idleUnloadTask?.cancel()
        idleUnloadTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.idleUnloadSeconds))
            guard !Task.isCancelled else { return }
            await self?.unload()
        }
    }

    func embedOne(_ text: String, modelsRoot: URL, server: URL?) async -> [Float]? {
        guard let vectors = await embed([text], modelsRoot: modelsRoot, server: server) else { return nil }
        return vectors.first
    }

    /// One embedder for a sync pass. The closure re-enters this actor; it does not block a thread.
    func session(modelsRoot: URL, server: URL?) async -> Session? {
        guard let modelID = await resolvedModelID(modelsRoot: modelsRoot, server: server) else { return nil }
        return Session(modelID: modelID) { [weak self] texts in
            guard let self else { return nil }
            return await self.embed(texts, modelsRoot: modelsRoot, server: server)
        }
    }

    private func resolvedModelID(modelsRoot: URL, server: URL?) async -> String? {
        let now = Date()
        if let cached = cachedProbe,
           cached.server == server?.absoluteString,
           cached.modelsRoot == modelsRoot.path,
           now.timeIntervalSince(cached.at) < Self.probeTTL {
            return cached.modelID
        }
        let lmID = server != nil ? await loadedLMStudioModel(server: server!) : nil
        let resolved: String?
        if let lmID {
            resolved = "lmstudio:\(lmID)"
        } else {
            resolved = await mlxModelID(in: modelsRoot)
        }
        cachedProbe = (server: server?.absoluteString, modelsRoot: modelsRoot.path,
                       modelID: resolved, lmStudioModel: lmID, at: now)
        return resolved
    }

    private func embed(_ texts: [String], modelsRoot: URL, server: URL?) async -> [[Float]]? {
        let trimmed = texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !trimmed.isEmpty, trimmed.contains(where: { !$0.isEmpty }) else { return nil }
        _ = await resolvedModelID(modelsRoot: modelsRoot, server: server)
        if let server, let id = cachedProbe?.lmStudioModel {
            if let result = await lmStudioEmbeddings(texts: trimmed, model: id, server: server) {
                return result
            }
            // LM Studio went away: invalidate cache and fall back to MLX if present.
            cachedProbe = nil
        }
        return await mlxEmbeddings(texts: trimmed, modelsRoot: modelsRoot)
    }

    private func loadedLMStudioModel(server: URL) async -> String? {
        var request = URLRequest(url: server.appendingPathComponent("api/v0/models"))
        request.timeoutInterval = 0.5
        guard let (data, _) = try? await probeSession.data(for: request) else { return nil }
        return OpenAICompatible.loadedEmbeddingModel(from: data)
    }

    private func lmStudioEmbeddings(texts: [String], model: String, server: URL) async -> [[Float]]? {
        var vectors: [[Float]] = []
        let batch = 32
        var start = 0
        while start < texts.count {
            let end = min(start + batch, texts.count)
            var request = URLRequest(url: server.appendingPathComponent("v1/embeddings"))
            request.httpMethod = "POST"
            request.timeoutInterval = 60
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = OpenAICompatible.embeddingsBody(model: model, input: Array(texts[start..<end]))
            guard let (data, _) = try? await embedSession.data(for: request),
                  let part = try? OpenAICompatible.embeddings(from: data),
                  part.count == end - start else { return nil }
            vectors.append(contentsOf: part)
            start = end
        }
        return vectors
    }

    private func mlxModelID(in root: URL) async -> String? {
        guard let folder = Self.discoverMLXModel(in: root) else { return nil }
        return "mlx:\(folder.lastPathComponent)"
    }

    private func mlxEmbeddings(texts: [String], modelsRoot: URL) async -> [[Float]]? {
        guard let folder = Self.discoverMLXModel(in: modelsRoot) else { return nil }
        do {
            let container = try await loadMLX(folder)
            let vectors = await container.perform { context -> [[Float]] in
                var output: [[Float]] = []
                output.reserveCapacity(texts.count)
                for text in texts {
                    let ids = Array(context.tokenizer.encode(text: text, addSpecialTokens: true).prefix(256))
                    guard !ids.isEmpty else { return [] }
                    let input = MLXArray(ids.map { Int32($0) }).reshaped(1, ids.count)
                    let hidden = context.model(input, positionIds: nil, tokenTypeIds: nil, attentionMask: nil)
                    let pooled = context.pooling(hidden, normalize: true, applyLayerNorm: false)
                    pooled.eval()
                    guard pooled.shape.count == 2, pooled.shape[0] == 1 else { return [] }
                    let vector = pooled.asArray(Float.self)
                    guard vector.count == pooled.shape[1], !vector.isEmpty else { return [] }
                    output.append(vector)
                }
                Stream.defaultStream.synchronize()
                return output
            }
            scheduleIdleUnload()
            return vectors
        } catch {
            unload()
            return nil
        }
    }

    private func loadMLX(_ folder: URL) async throws -> EmbedderModelContainer {
        if let mlxContainer, mlxDirectory == folder.path { return mlxContainer }
        let container = try await EmbedderModelFactory.shared.loadContainer(
            from: folder, using: TransformersTokenizerLoader())
        mlxContainer = container
        mlxDirectory = folder.path
        mlxModelID = "mlx:\(folder.lastPathComponent)"
        return container
    }

    /// A folder under Models that is an embedding checkpoint, not speech or the summary LLM.
    private static func discoverMLXModel(in root: URL) -> URL? {
        let skip: Set<String> = [
            "manifest.json",
            "parakeet-tdt-0.6b-v2",
            "speaker-diarization",
            "mlx-community_Qwen3-4B-Instruct-2507-4bit",
            "beshkenadze_cohere-transcribe-03-2026-mlx-8bit",
        ]
        let embedderTypes: Set<String> = [
            "bert", "roberta", "xlm-roberta", "distilbert", "nomic_bert", "qwen3", "lfm2",
            "gemma3", "gemma3_text", "gemma3n",
        ]
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return nil }
        for folder in children {
            let name = folder.lastPathComponent
            if skip.contains(name) { continue }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("config.json")),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["model_type"] as? String,
                  embedderTypes.contains(type) else { continue }
            let looksEmbed = name.localizedCaseInsensitiveContains("embed")
                || FileManager.default.fileExists(atPath: folder.appendingPathComponent("1_Pooling/config.json").path)
                || FileManager.default.fileExists(atPath: folder.appendingPathComponent("modules.json").path)
            if type == "qwen3" || type == "lfm2" || type == "gemma3" || type == "gemma3_text" || type == "gemma3n" {
                guard looksEmbed else { continue }
            }
            return folder
        }
        return nil
    }
}
