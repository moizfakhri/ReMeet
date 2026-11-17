import Foundation
import Testing
@testable import ReMeetKit

struct DownloadPlanTests {
    @Test func parsesTreeKeepingFilesOnly() throws {
        let json = """
        [{"type":"file","oid":"a","size":1570,"path":".gitattributes"},
         {"type":"file","oid":"b","size":900,"path":"README.md"},
         {"type":"file","oid":"c","size":2000000000,"path":"model.safetensors"},
         {"type":"directory","oid":"d","size":0,"path":"sub"},
         {"type":"file","oid":"e","size":7000,"path":"sub/tokenizer.json"},
         {"type":"file","oid":"f","path":"config.json"}]
        """
        let files = try DownloadPlan.parseTree(Data(json.utf8))
        #expect(files.map(\.path) == ["model.safetensors", "sub/tokenizer.json", "config.json"])
        #expect(files.last?.size == 0)
    }

    @Test func resumesSkippingCompleteFiles() {
        let remote = [RemoteFile(path: "a", size: 100), RemoteFile(path: "b", size: 300), RemoteFile(path: "c", size: 600)]
        let local: [String: Int64] = ["a": 100, "b": 120]  // b is partial, c missing
        let plan = DownloadPlan.make(remote: remote) { local[$0] }
        #expect(plan.toFetch.map(\.path) == ["b", "c"])
        #expect(plan.totalBytes == 1000 && plan.alreadyBytes == 100)
        #expect(plan.fraction(fetchedBytes: 0) == 0.1)
        #expect(plan.fraction(fetchedBytes: 450) == 0.55)
        #expect(plan.fraction(fetchedBytes: 5000) == 1)
        let done = DownloadPlan.make(remote: remote) { name in remote.first { $0.path == name }?.size }
        #expect(done.toFetch.isEmpty && done.fraction(fetchedBytes: 0) == 1)
    }

    @Test func catalog() {
        #expect(ModelID.cohere.huggingFaceRepo == "beshkenadze/cohere-transcribe-03-2026-mlx-8bit")
        // The old Core ML build's manifest entry ("cohere") must not mark the MLX model ready.
        #expect(ModelID.cohere.rawValue == "cohereMLX")
        #expect(ModelID.cohere.includes("model.safetensors") && ModelID.cohere.includes("tokenizer.model"))
        #expect(ModelID.cohere.includes("config.json") && ModelID.cohere.includes("preprocessor_config.json"))
        #expect(!ModelID.cohere.includes("key_map.json") && !ModelID.cohere.includes("conversion_summary.json"))
        #expect(TranscriptionEngine.default == .fast && TranscriptionEngine.accurate.model == .cohere)
        #expect(TranscriptionEngine.accurate.models == [.cohere])
        #expect(ModelID.summaryLLM.huggingFaceRepo == "mlx-community/Qwen3-4B-Instruct-2507-4bit")
        #expect(Int64(2_280_000_000).byteString.contains("GB"))
    }
}
