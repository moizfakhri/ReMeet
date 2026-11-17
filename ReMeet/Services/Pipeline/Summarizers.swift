import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import ReMeetKit
import Tokenizers

/// Writes the summary JSON for a prompt. Backends: built-in MLX model, LM Studio.
protocol Summarizer: Sendable {
    var kind: SummaryBackendKind { get }
    /// Model name shown under the summary.
    func modelName() async -> String
    /// Tokens the backend can take in one request (prompt + reply).
    func contextTokens() async -> Int
    func complete(system: String, user: String) async throws -> String
    func unload() async
}

extension Summarizer {
    func unload() async {}
}

// MARK: - Built-in (MLX)

/// Qwen3 4B Instruct 2507 (4-bit MLX) on this Mac. Loaded for one meeting, then released
/// together with MLX's buffer cache so it never sits in memory next to the speech models.
///
/// Metal teardown is fail-soft: `unload` never clears weights/cache while a generation is
/// still on the GPU. Doing that raced `Memory.clearCache()` / process exit with
/// `mlx-swift-lm`'s generation thread and aborted the whole app (SIGSEGV in
/// `CommandEncoder::register_output_array`, IPS 2026-11-02-235833).
actor BuiltInSummarizer: Summarizer {
    nonisolated let kind = SummaryBackendKind.builtIn
    private let directory: URL
    private var container: ModelContainer?
    /// Actor-reentrant count: `complete` can be suspended in `respond` while `unload` runs.
    private var activeGenerations = 0
    private var unloadWaiters: [CheckedContinuation<Void, Never>] = []

    init(directory: URL) {
        self.directory = directory
    }

    func modelName() -> String { "Qwen3 4B Instruct 2507 (4-bit)" }

    /// The model handles 256K tokens; this keeps the KV cache to roughly 3.5 GB on a 16 GB Mac.
    func contextTokens() -> Int { 24_000 }

    func complete(system: String, user: String) async throws -> String {
        activeGenerations += 1
        defer { endGeneration() }
        if container == nil {
            // Keep MLX's reusable-buffer cache small; the weights themselves are ~2.3 GB.
            Memory.cacheLimit = 256 * 1024 * 1024
            container = try await LLMModelFactory.shared.loadContainer(from: directory, using: TransformersTokenizerLoader())
        }
        guard let container else { throw BackendError.notConfigured("The built-in model could not be loaded.") }
        // Peak for a 1-hour transcript (~10k tokens) is ~4.4 GB: 2.2 GB weights + ~2.2 GB of
        // transient prefill buffers. Smaller prefill steps and an 8-bit KV cache were measured
        // and did not lower it (docs/performance.md), so defaults are kept.
        let session = ChatSession(container, instructions: system,
                                  generateParameters: GenerateParameters(maxTokens: 2_048, temperature: 0.2, topP: 0.9))
        let reply = try await session.respond(to: user)
        // Settle any pipelined async_eval before the caller (or unload) may drop buffers.
        Stream.defaultStream.synchronize()
        return reply
    }

    /// True while `complete` holds the GPU (including across actor suspension in `respond`).
    var isGenerating: Bool { activeGenerations > 0 }

    /// Wait until every in-flight `complete` has finished and Metal has settled. Used on
    /// quit so NSApplication does not tear down the Metal device under mlx-swift-lm
    /// (self-tests use a private ProcessingQueue, so the shared queue can look idle).
    func waitUntilIdle() async {
        while activeGenerations > 0 {
            await withCheckedContinuation { unloadWaiters.append($0) }
        }
        Stream.defaultStream.synchronize()
    }

    func unload() async {
        await waitUntilIdle()
        container = nil
        Memory.clearCache()
    }

    private func endGeneration() {
        activeGenerations = max(0, activeGenerations - 1)
        guard activeGenerations == 0 else { return }
        let waiters = unloadWaiters
        unloadWaiters = []
        for waiter in waiters { waiter.resume() }
    }
}

/// Adapts swift-transformers' tokenizer to mlx-swift-lm's protocol (what the MLXHuggingFace
/// macro would generate, written out so the app needs no macro package).
struct TransformersTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TokenizerBridge(try await Tokenizers.AutoTokenizer.from(modelFolder: directory))
    }
}

private struct TokenizerBridge: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) {
        self.upstream = upstream
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}

// MARK: - LM Studio

/// LM Studio's OpenAI-compatible local server. Uses the model loaded in LM Studio unless a
/// model id is set in Settings.
struct LMStudioSummarizer: Summarizer {
    let kind = SummaryBackendKind.lmStudio
    let server: URL
    let model: String
    var session: URLSession = .shared

    func modelName() async -> String {
        if !model.isEmpty { return model }
        return await loaded()?.id ?? "loaded model"
    }

    func contextTokens() async -> Int { await loaded()?.context ?? 8_192 }

    func complete(system: String, user: String) async throws -> String {
        var request = URLRequest(url: server.appendingPathComponent("v1/chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 900
        request.httpBody = OpenAICompatible.body(model: model, system: system, user: user)
        let data: Data
        do {
            (data, _) = try await session.data(for: request)
        } catch {
            throw BackendError.unreachable("LM Studio is not reachable at \(server.absoluteString). Open LM Studio, load a model and start its local server.")
        }
        return try OpenAICompatible.text(from: data)
    }

    private func loaded() async -> (id: String, context: Int)? {
        guard let (data, _) = try? await session.data(from: server.appendingPathComponent("api/v0/models")) else { return nil }
        return OpenAICompatible.loadedModel(from: data)
    }
}
