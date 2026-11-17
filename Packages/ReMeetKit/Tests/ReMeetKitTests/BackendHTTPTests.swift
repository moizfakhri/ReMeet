import Foundation
import Testing
@testable import ReMeetKit

struct BackendHTTPTests {
    @Test func openAIBodyAndReply() throws {
        let body = try JSONSerialization.jsonObject(with: OpenAICompatible.body(model: "qwen", system: "S", user: "U")) as! [String: Any]
        #expect(body["model"] as? String == "qwen")
        #expect((body["messages"] as! [[String: String]]).map { $0["role"]! } == ["system", "user"])
        let noModel = try JSONSerialization.jsonObject(with: OpenAICompatible.body(model: "", system: "S", user: "U")) as! [String: Any]
        #expect(noModel["model"] == nil)

        let reply = #"{"choices":[{"index":0,"message":{"role":"assistant","content":"{\"title\":\"x\"}"}}]}"#
        #expect(try OpenAICompatible.text(from: Data(reply.utf8)) == #"{"title":"x"}"#)
        #expect(throws: BackendError.server("Model not loaded")) {
            try OpenAICompatible.text(from: Data(#"{"error":{"message":"Model not loaded"}}"#.utf8))
        }
    }

    @Test func lmStudioLoadedModel() {
        let json = #"{"data":[{"id":"nomic-embed","type":"embeddings","state":"loaded"},{"id":"qwen3-8b","type":"llm","state":"loaded","loaded_context_length":32768},{"id":"other","type":"llm","state":"not-loaded"}]}"#
        let loaded = OpenAICompatible.loadedModel(from: Data(json.utf8))
        #expect(loaded?.id == "qwen3-8b" && loaded?.context == 32768)
        #expect(OpenAICompatible.loadedModel(from: Data(#"{"data":[]}"#.utf8)) == nil)
        #expect(OpenAICompatible.loadedEmbeddingModel(from: Data(json.utf8)) == "nomic-embed")
    }

    @Test func embeddingsRoundTripOrder() throws {
        let body = try JSONSerialization.jsonObject(with: OpenAICompatible.embeddingsBody(model: "nomic", input: ["a", "b"])) as! [String: Any]
        #expect(body["model"] as? String == "nomic")
        #expect(body["input"] as? [String] == ["a", "b"])
        let reply = #"{"data":[{"index":1,"embedding":[0,1]},{"index":0,"embedding":[1,0]}]}"#
        let vectors = try OpenAICompatible.embeddings(from: Data(reply.utf8))
        #expect(vectors.count == 2)
        #expect(vectors[0] == [1, 0])
        #expect(vectors[1] == [0, 1])
        #expect(throws: BackendError.server("no model")) {
            try OpenAICompatible.embeddings(from: Data(#"{"error":{"message":"no model"}}"#.utf8))
        }
    }
}
