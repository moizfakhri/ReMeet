import Foundation
import Testing
@testable import ReMeetKit

struct ChunkIndexTests {
  @Test func retrieveBM25AndFolderScope() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("remeet-chunk-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let folderA = MeetingFolder.makeNew(in: root, start: Date(), title: "Team standup")
    try FileManager.default.createDirectory(at: folderA.url, withIntermediateDirectories: true)
    var metaA = MeetingMeta(title: "Team standup", startTime: Date())
    metaA.collectionID = "lab-a"
    try folderA.writeMeta(metaA)
    let transcriptA = Transcript(engine: "t", segments: [
      TranscriptSegment(start: 10, end: 12, speaker: "speaker_1", text: "Workshop is next Tuesday", source: .system),
    ])
    try folderA.write(transcriptA, .transcript)
    try folderA.write(
      MeetingSummary(title: "Team standup", summary: [SummaryPoint(text: "Workshop confirmed", t: 10)]),
      .summary
    )

    let folderB = MeetingFolder.makeNew(in: root, start: Date().addingTimeInterval(-60), title: "Finance sync")
    try FileManager.default.createDirectory(at: folderB.url, withIntermediateDirectories: true)
    var metaB = MeetingMeta(title: "Finance sync", startTime: Date())
    metaB.collectionID = "finance"
    try folderB.writeMeta(metaB)
    try folderB.write(
      Transcript(engine: "t", segments: [
        TranscriptSegment(start: 5, end: 7, speaker: "you", text: "Refunds are approved", source: .mic),
      ]),
      .transcript
    )

    let dbURL = root.deletingLastPathComponent().appendingPathComponent("chunks-\(UUID().uuidString).sqlite")
    let index = try ChunkIndex(url: dbURL)
    try await index.sync(root: root)

    let all = try index.retrieve("workshop", limit: 10)
    #expect(all.contains { $0.chunk.text.localizedCaseInsensitiveContains("workshop") })

    let scoped = try index.retrieve("workshop", limit: 10, collectionID: "lab-a")
    #expect(scoped.allSatisfy { $0.chunk.meetingID == folderA.id })

    let refunds = try index.retrieve("refunds", limit: 10, collectionID: "lab-a")
    #expect(refunds.isEmpty)
  }

  @Test func folderChangeUpdatesCollectionWithoutDroppingEmbeddings() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("remeet-chunk-folder-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let folder = MeetingFolder.makeNew(in: root, start: Date(), title: "Team standup")
    try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
    var meta = MeetingMeta(title: "Team standup", startTime: Date())
    meta.collectionID = "lab-a"
    try folder.writeMeta(meta)
    try folder.write(
      Transcript(engine: "t", segments: [
        TranscriptSegment(start: 10, end: 12, speaker: "speaker_1", text: "Workshop is next Tuesday", source: .system),
      ]),
      .transcript
    )

    let dbURL = root.deletingLastPathComponent().appendingPathComponent("chunks-\(UUID().uuidString).sqlite")
    let index = try ChunkIndex(url: dbURL)
    try await index.sync(root: root, embeddingModel: "test-embed") { texts in
      texts.map { _ in [1, 0, 0] }
    }
    let hit = try index.retrieve("workshop", limit: 4).first
    let chunkID = try #require(hit?.chunk.id)
    #expect(try index.embedding(for: chunkID) == [1, 0, 0])
    #expect(try index.collectionID(for: folder.id) == "lab-a")

    let metaURL = folder.file(.meta)
    let oldDate = try FileManager.default.attributesOfItem(atPath: metaURL.path)[.modificationDate] as? Date
    var moved = try folder.readMeta()
    moved.collectionID = "finance"
    try folder.writeMeta(moved)
    if let oldDate {
      try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: metaURL.path)
    }

    try await index.sync(root: root)
    #expect(try index.collectionID(for: folder.id) == "finance")
    #expect(try index.embedding(for: chunkID) == [1, 0, 0])
    #expect(try index.retrieve("workshop", collectionID: "lab-a").isEmpty)
    #expect(try index.retrieve("workshop", collectionID: "finance").contains { $0.chunk.id == chunkID })
  }

  @Test func hybridReranksCosineCandidatesWithFTS() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("remeet-chunk-hybrid-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let refunds = MeetingFolder.makeNew(in: root, start: Date(), title: "Finance sync")
    try FileManager.default.createDirectory(at: refunds.url, withIntermediateDirectories: true)
    try refunds.writeMeta(MeetingMeta(title: "Finance sync", startTime: Date()))
    try refunds.write(
      Transcript(engine: "t", segments: [
        TranscriptSegment(start: 5, end: 7, speaker: "you", text: "Refunds are approved", source: .mic),
      ]),
      .transcript
    )

    let workshop = MeetingFolder.makeNew(in: root, start: Date().addingTimeInterval(-60), title: "Team standup")
    try FileManager.default.createDirectory(at: workshop.url, withIntermediateDirectories: true)
    try workshop.writeMeta(MeetingMeta(title: "Team standup", startTime: Date()))
    try workshop.write(
      Transcript(engine: "t", segments: [
        TranscriptSegment(start: 10, end: 12, speaker: "speaker_1", text: "Workshop is next Tuesday", source: .system),
      ]),
      .transcript
    )

    let dbURL = root.deletingLastPathComponent().appendingPathComponent("chunks-\(UUID().uuidString).sqlite")
    let index = try ChunkIndex(url: dbURL)
    try await index.sync(root: root, embeddingModel: "test-embed") { texts in
      texts.map { text in
        text.localizedCaseInsensitiveContains("refund") ? [Float]([1, 0]) : [Float]([0, 1])
      }
    }

    let lexical = try index.retrieve("workshop", limit: 4)
    #expect(lexical.first?.chunk.text.localizedCaseInsensitiveContains("workshop") == true)

    let reranked = try index.retrieve("workshop", limit: 4, queryEmbedding: [1, 0])
    #expect(reranked.first?.chunk.text.localizedCaseInsensitiveContains("workshop") == true)
    #expect(reranked.contains { $0.chunk.text.localizedCaseInsensitiveContains("refund") })

    let semanticOnly = try index.retrieve("workshop", limit: 4, queryEmbedding: [1, 0], cosinePool: 1)
    #expect(semanticOnly.count == 1)
    #expect(semanticOnly[0].chunk.text.localizedCaseInsensitiveContains("refund"))
  }
}