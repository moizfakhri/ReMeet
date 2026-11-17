import Foundation

/// The models ReMeet downloads, all into `~/Library/Application Support/ReMeet/Models`.
public enum ModelID: String, CaseIterable, Codable, Sendable, Identifiable {
    /// pyannote community-1 segmentation + WeSpeaker embeddings, Core ML (FluidAudio).
    case diarizer
    /// Parakeet TDT 0.6B v2, English, Core ML (FluidAudio). The "Fast" engine.
    case parakeet
    /// Cohere Transcribe 03-2026 (2B), 8-bit MLX on the GPU. The "Accurate" engine.
    /// Raw value differs from the old Core ML build's ("cohere"), so a manifest entry left
    /// by that build never marks this one ready. The Core ML export ran its encoder on the
    /// CPU on this M4 (~24 s per 35 s window); MLX does a 1-hour meeting in ~3 minutes.
    case cohere = "cohereMLX"
    /// Built-in summary model, MLX 4-bit.
    case summaryLLM

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .diarizer: "Speaker labels"
        case .parakeet: "Speech to text (Fast)"
        case .cohere: "Speech to text (Accurate)"
        case .summaryLLM: "Built-in summary model"
        }
    }

    public var detail: String {
        switch self {
        case .diarizer: "pyannote community-1, finds who spoke when"
        case .parakeet: "NVIDIA Parakeet TDT 0.6B v2, English"
        case .cohere: "Cohere Transcribe 03-2026 (2B), 8-bit MLX"
        case .summaryLLM: "Qwen3 4B Instruct 2507, 4-bit MLX"
        }
    }

    /// Rough download size shown before downloading (bytes).
    public var approximateBytes: Int64 {
        switch self {
        case .diarizer: 130_000_000
        case .parakeet: 650_000_000
        case .cohere: 2_420_000_000
        case .summaryLLM: 2_280_000_000
        }
    }

    /// Hugging Face repository for models ReMeet downloads itself (the FluidAudio ones are
    /// fetched by FluidAudio into the same folder).
    public var huggingFaceRepo: String? {
        switch self {
        case .summaryLLM: "mlx-community/Qwen3-4B-Instruct-2507-4bit"
        // Public 8-bit MLX conversion of the Apache-2.0 model (the CohereLabs original is
        // gated). 4-bit was measured too: same WER on the test call, 12 s faster per hour.
        case .cohere: "beshkenadze/cohere-transcribe-03-2026-mlx-8bit"
        default: nil
        }
    }

    /// Only these files of the repository are downloaded. The Cohere repo also holds
    /// conversion notes (key_map.json, conversion_summary.json) the model does not read.
    public func includes(_ path: String) -> Bool {
        switch self {
        case .cohere: path.hasSuffix(".safetensors") || path.hasSuffix(".model") || path.hasSuffix("config.json")
            || path == "special_tokens_map.json"
        default: true
        }
    }

    /// Folders older builds downloaded that nothing uses any more (deleted at launch).
    public static let retiredFolders = ["cohere-transcribe-03-2026-coreml", "cohere-transcribe-neural-engine"]
}

/// One file in a Hugging Face repository listing.
public struct RemoteFile: Codable, Equatable, Sendable {
    public var path: String
    public var size: Int64

    public init(path: String, size: Int64) {
        self.path = path
        self.size = size
    }
}

/// Which files still need fetching, so an interrupted download resumes instead of restarting.
public struct DownloadPlan: Equatable, Sendable {
    public var toFetch: [RemoteFile]
    public var totalBytes: Int64
    public var alreadyBytes: Int64

    /// `localSize` returns the size of a file already on disk (nil if missing). A file
    /// counts as done only when its size matches exactly.
    public static func make(remote: [RemoteFile], localSize: (String) -> Int64?) -> DownloadPlan {
        var fetch: [RemoteFile] = []
        var have: Int64 = 0
        for file in remote {
            if localSize(file.path) == file.size { have += file.size } else { fetch.append(file) }
        }
        return DownloadPlan(toFetch: fetch, totalBytes: remote.reduce(0) { $0 + $1.size }, alreadyBytes: have)
    }

    public func fraction(fetchedBytes: Int64) -> Double {
        guard totalBytes > 0 else { return 1 }
        return min(1, Double(alreadyBytes + fetchedBytes) / Double(totalBytes))
    }

    /// Parses `GET https://huggingface.co/api/models/<repo>/tree/main?recursive=true`,
    /// keeping files only (not directories) and skipping repository metadata.
    public static func parseTree(_ data: Data) throws -> [RemoteFile] {
        struct Entry: Decodable {
            var type: String
            var path: String
            var size: Int64?
        }
        return try JSONDecoder().decode([Entry].self, from: data)
            .filter { $0.type == "file" && !$0.path.hasPrefix(".") && $0.path != "README.md" }
            .map { RemoteFile(path: $0.path, size: $0.size ?? 0) }
    }
}

extension Int64 {
    /// "2.3 GB", "130 MB".
    public var byteString: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}

/// Settings > Transcription > Engine. Fast stays the default local draft.
/// Sonnet is not a choice: it runs after the draft on its own. The `sonnet` raw value
/// still resolves, so an older setting keeps Parakeet as the draft.
public enum TranscriptionEngine: String, CaseIterable, Sendable, Identifiable {
    /// Cohere Transcribe 03-2026 on MLX: fewest word errors, ~3 minutes per hour of audio.
    case accurate
    /// Parakeet TDT 0.6B v2: fast (~25 s per hour of audio). Default.
    case fast
    /// Parakeet on this Mac for a draft, then one Claude Sonnet 5.5 text pass. For hard meetings only.
    case sonnet

    public var id: String { rawValue }
    public static let `default` = TranscriptionEngine.fast
    /// Engines the user can pick. Sonnet is not one of them.
    public static let selectable: [TranscriptionEngine] = [.fast, .accurate]

    /// A meeting or setting saved while this option was called Haiku still selects Sonnet.
    public static func resolve(_ raw: String?) -> TranscriptionEngine? {
        switch raw {
        case "sonnet", "haiku": .sonnet
        default: raw.flatMap(Self.init(rawValue:))
        }
    }

    /// The on-device speech model. Sonnet still needs Parakeet for the draft and the speaker timeline.
    public var model: ModelID? {
        switch self {
        case .accurate: .cohere
        case .fast, .sonnet: .parakeet
        }
    }

    /// Models that can serve this engine, preferred first.
    public var models: [ModelID] { model.map { [$0] } ?? [] }

    public var label: String {
        switch self {
        case .accurate: "Accurate (Cohere Transcribe)"
        case .fast: "Fast (Parakeet)"
        case .sonnet: "Sonnet 5.5 (hard meetings)"
        }
    }

    public var shortLabel: String {
        switch self {
        case .accurate: "Cohere"
        case .fast: "Parakeet"
        case .sonnet: "Sonnet"
        }
    }
}
