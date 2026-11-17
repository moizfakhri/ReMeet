import Foundation
import MLX
import MLXAudioSTT

/// Cohere Transcribe 03-2026 (2B) on the GPU through MLX (mlx-audio-swift). The Core ML
/// export's INT8 encoder falls back to the CPU on this M4 (~24 s per 35 s window, see
/// `--selftest coherebench`); MLX runs the quantized weights on the GPU instead.
actor CohereMLXTranscriber: Transcriber {
    nonisolated let engineName: String
    private let directory: URL
    private var model: CohereTranscribeModel?

    init(directory: URL, engineName: String = "Cohere Transcribe 03-2026 (MLX)") {
        self.directory = directory
        self.engineName = engineName
    }

    func load() async throws {
        guard model == nil else { return }
        // Small reusable-buffer cache, as for the summary model; the weights stay resident
        // only for the transcribe stage.
        Memory.cacheLimit = 256 * 1024 * 1024
        model = try CohereTranscribeModel.fromDirectory(directory)
    }

    func transcribe(_ samples: [Float]) async throws -> LocalSpeech {
        guard let model else { throw StageWaiting(reason: "Speech model not loaded") }
        let output = model.generate(audio: MLXArray(samples),
                                    generationParameters: STTGenerateParameters(language: "en"))
        // Settle the GPU before the next turn or an unload drops buffers.
        Stream.defaultStream.synchronize()
        // Cohere's decoder does not return a time for each word. The turn's start and end are enough.
        return LocalSpeech(text: output.text.trimmingCharacters(in: .whitespacesAndNewlines), words: [])
    }

    func unload() async {
        Stream.defaultStream.synchronize()
        model = nil
        Memory.clearCache()
    }
}
