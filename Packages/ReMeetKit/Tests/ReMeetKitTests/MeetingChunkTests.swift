import Foundation
import Testing
@testable import ReMeetKit

struct MeetingChunkTests {
  @Test func turnSummaryAndNotes() {
    let meta = MeetingMeta(title: "Sync", startTime: Date())
    let transcript = Transcript(engine: "x", segments: [
      TranscriptSegment(start: 1, end: 2, speaker: "speaker_1", text: "We ship Friday", source: .system),
    ])
    let summary = MeetingSummary(
      title: "t",
      summary: [SummaryPoint(text: "Ship on Friday", t: 1)],
      actionItems: [ActionItem(owner: "Alex", task: "Email QA", due: nil, done: false, t: 2)]
    )
    let notes = [MeetingNote(t: 3, text: "Check staging", kind: .note)]
    let chunks = MeetingChunkBuilder.build(
      meetingID: "2026-01-01_1200_sync",
      meta: meta,
      transcript: transcript,
      summary: summary,
      notes: notes,
      speakers: SpeakerNames(names: ["speaker_1": "Priya"])
    )
    #expect(chunks.contains { $0.kind == .turn && $0.text.contains("Priya") && $0.text.contains("Friday") })
    #expect(chunks.contains { $0.kind == .summary && $0.text.contains("Ship on Friday") })
    #expect(chunks.contains { $0.kind == .summary && $0.text.contains("Action:") })
    #expect(chunks.contains { $0.kind == .note && $0.text == "Check staging" })
  }

  @Test func tokenEstimate() {
    let transcript = Transcript(engine: "x", segments: [
      TranscriptSegment(start: 0, end: 1, speaker: "you", text: String(repeating: "word ", count: 200), source: .mic),
    ])
    let tokens = MeetingChunkBuilder.estimatedTokens(transcript: transcript, summary: nil, notes: [])
    #expect(tokens > 100)
  }

    @Test func parsesAnswerJSON() throws {
        let json = """
        {"answer":"We ship Friday.","sources":[{"meetingId":"m1","start":1.0,"label":"Priya"}]}
        """
        let parsed = try MeetingChatPrompt.parseAnswer(json)
        #expect(parsed.answer.contains("Friday"))
        #expect(parsed.sources.count == 1)
        #expect(parsed.sources[0].meetingID == "m1")
    }

    @Test func parsesAnswerWithoutSources() throws {
        let json = #"{"answer":"Nothing on that topic."}"#
        let parsed = try MeetingChatPrompt.parseAnswer(json)
        #expect(parsed.sources.isEmpty)
    }

    @Test func historyIsInThePromptAndFollowUpsSearchThePriorQuestion() {
        let history = [
            MeetingChatTurn(role: .user, text: "What did we decide?", sources: []),
            MeetingChatTurn(role: .assistant, text: "Ship Friday.", sources: [
                MeetingChatSource(meetingID: "m1", start: 1, label: "Priya"),
            ]),
        ]
        let prompt = MeetingChatPrompt.user(
            question: "Who owns it?",
            passages: [.init(meetingID: "m1", title: "Sync", start: 1, end: 2, speaker: "Priya", kind: .turn, text: "Priya: Ship Friday")],
            recorderName: "Alex",
            history: history
        )
        #expect(prompt.contains("What did we decide?"))
        #expect(prompt.contains("Ship Friday."))
        #expect(prompt.contains("Who owns it?"))
        #expect(prompt.contains("Alex"))
        let queries = MeetingChatThread.retrievalQueries(question: "Who owns it?", history: history)
        #expect(queries == ["Who owns it?", "What did we decide?"])
        #expect(MeetingChatThread.shouldExpandRetrieval(hitCount: 1))
        #expect(!MeetingChatThread.shouldExpandRetrieval(hitCount: 4))
    }

    @Test func threadRoundTripKeepsTheLatestTurns() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chat-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var thread = MeetingChatThread()
        for index in 0..<6 {
            thread = thread.appending(
                question: "Question \(index)",
                answer: MeetingChatAnswer(answer: "Answer \(index)", sources: [])
            )
        }
        #expect(thread.turns.count == MeetingChatThread.promptLimit)
        #expect(thread.turns.first?.text == "Question 2")
        try thread.save(to: url)
        let loaded = MeetingChatThread.load(from: url)
        #expect(loaded == thread)
        #expect(MeetingChatThread.load(from: url.deletingLastPathComponent().appendingPathComponent("missing.json")).turns.isEmpty)
    }
}