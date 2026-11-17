import Foundation
import ReMeetKit

/// Retrieves passages and asks Sonnet for a cited answer.
enum MeetingChatService {
    struct Context: Sendable {
        var meetingID: String
        var collectionID: String?
        var title: String
        var transcript: Transcript?
        var summary: MeetingSummary?
        var notes: [MeetingNote]
        var speakers: SpeakerNames
        var chunkIndex: ChunkIndex?
        var recorderName: String

        @MainActor
        init(document: MeetingDocument, chunkIndex: ChunkIndex?, recorderName: String) {
            meetingID = document.folder.id
            collectionID = document.meta.collectionID
            title = document.meta.title
            transcript = document.transcript
            summary = document.summary
            notes = document.notes
            speakers = document.speakers
            self.chunkIndex = chunkIndex
            self.recorderName = recorderName
        }
    }

    static func answer(question: String, scope: MeetingChatScope, context: Context,
                       history: [MeetingChatTurn] = [],
                       embedQuery: (@Sendable (String) async -> [Float]?)? = nil,
                       answerWith: @escaping @Sendable (String, [MeetingChatPrompt.Passage], [MeetingChatTurn], String) async throws -> MeetingChatAnswer) async -> Result<MeetingChatAnswer, Error> {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .success(MeetingChatAnswer(answer: "", sources: []))
        }
        if scope == .thisFolder, context.collectionID == nil {
            return .success(MeetingChatAnswer(
                answer: "This meeting is not in a folder. Move it into a folder to search that group, or switch to All recordings.",
                sources: []
            ))
        }
        do {
            let passages: [MeetingChatPrompt.Passage]
            let tokens = MeetingChunkBuilder.estimatedTokens(
                transcript: context.transcript,
                summary: context.summary,
                notes: context.notes
            )
            let longMeeting = tokens > MeetingChunkBuilder.fullContextTokenLimit
            let mustRetrieve = scope == .allRecordings || scope == .thisFolder
                || (scope == .thisMeeting && longMeeting)
            if mustRetrieve {
                guard let index = context.chunkIndex else {
                    return .failure(MeetingChatError.indexUnavailable)
                }
                let collectionID: String? = scope == .thisFolder ? context.collectionID : nil
                let meetingFilter: Set<String>? = scope == .thisMeeting ? [context.meetingID] : nil
                let queries = MeetingChatThread.retrievalQueries(question: trimmed, history: history)
                let queryVector = await embedQuery?(queries.first ?? trimmed)
                let hits = try await Task.detached(priority: .userInitiated) {
                    var found: [ChunkIndex.RetrievedChunk] = []
                    var seen = Set<String>()
                    for (offset, query) in queries.enumerated() {
                        let batch = try index.retrieve(
                            query,
                            meetingIDs: meetingFilter,
                            collectionID: collectionID,
                            queryEmbedding: offset == 0 ? queryVector : nil
                        )
                        for hit in batch where seen.insert(hit.chunk.id).inserted {
                            found.append(hit)
                        }
                        if !MeetingChatThread.shouldExpandRetrieval(hitCount: found.count) { break }
                    }
                    return Array(found.prefix(16))
                }.value
                guard !hits.isEmpty else {
                    return .success(MeetingChatAnswer(
                        answer: "I could not find anything in your recordings that matches that question.",
                        sources: []
                    ))
                }
                passages = hits.map {
                    MeetingChatPrompt.Passage(
                        meetingID: $0.chunk.meetingID,
                        title: $0.meetingTitle,
                        start: $0.chunk.start,
                        end: $0.chunk.end,
                        speaker: $0.chunk.speaker,
                        kind: $0.chunk.kind,
                        text: $0.chunk.text
                    )
                }
            } else {
                passages = fullMeetingPassages(context: context)
            }
            guard !passages.isEmpty else {
                return .success(MeetingChatAnswer(
                    answer: "There is no transcript, summary, or notes to search in this scope yet.",
                    sources: []
                ))
            }
            let reply = try await answerWith(trimmed, passages, history, context.recorderName)
            return .success(reply)
        } catch {
            return .failure(error)
        }
    }

    private static func fullMeetingPassages(context: Context) -> [MeetingChatPrompt.Passage] {
        var passages: [MeetingChatPrompt.Passage] = []
        if let summary = context.summary {
            for point in summary.summary {
                let text = point.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                passages.append(.init(
                    meetingID: context.meetingID, title: context.title, start: point.t ?? 0, end: point.t ?? 0,
                    speaker: "", kind: .summary, text: text
                ))
            }
        }
        if let transcript = context.transcript {
            for segment in transcript.segments {
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let speaker = context.speakers.displayName(for: segment.speaker)
                passages.append(.init(
                    meetingID: context.meetingID, title: context.title, start: segment.start, end: segment.end,
                    speaker: speaker, kind: .turn, text: "\(speaker): \(text)"
                ))
            }
        }
        for note in context.notes {
            let text = note.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            passages.append(.init(
                meetingID: context.meetingID, title: context.title, start: note.t, end: note.t,
                speaker: "", kind: .note, text: text
            ))
        }
        return passages
    }
}