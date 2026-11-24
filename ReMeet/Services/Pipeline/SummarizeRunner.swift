import Foundation
import ReMeetKit

/// Summarize stage: transcript + notes -> summary.json and summary.md. Long meetings that
/// do not fit the backend's context are summarized in ~15-minute parts, then merged.
struct SummarizeRunner: StageRunner {
    /// Picks the backend for a meeting (Regenerate's choice, else Settings). Nil = not ready.
    let summarizer: @Sendable (SummaryBackendKind?) async throws -> Summarizer?
    let customInstructions: @Sendable () -> String
    /// Production asks Sonnet first and keeps this backend's summary if that call fails.
    var useSonnet = true
    var recorderName: @Sendable () -> String = { "" }

    func run(_ folder: MeetingFolder, progress: @escaping @Sendable (Double) -> Void) async throws {
        let meta = try folder.readMeta()
        guard let transcript = try folder.read(Transcript.self, .transcript) else { throw RunnerError.missing("transcript.json") }
        let notes = NotesFile(url: folder.file(.notes)).load()
        let speakers = ((try? folder.read(SpeakerNames.self, .speakers)) ?? nil) ?? SpeakerNames()
        let started = Date()

        var summary: MeetingSummary
        var backendName = "none"
        var modelName: String?
        var sonnetSummaryNote: String?
        if PipelineStop.isRequested(folder.id) { throw CancellationError() }
        if transcript.segments.isEmpty {
            // Nothing was said: no model needed, and Sonnet is not asked to invent one.
            summary = MeetingSummary(title: meta.title, summary: [SummaryPoint(text: "No speech was detected in this recording.")])
            SummaryParser.enforceNotes(&summary, notes: notes)
        } else {
            let folderCtx = CollectionsFile(for: folder).context(for: meta)
            let peopleStore = PeopleFile.load(PeopleFile.url(beside: folder.url.deletingLastPathComponent()))
            let peopleCtx = PeopleDirectory.summaryContext(for: speakers, calendarAttendees: meta.calendarAttendees, store: peopleStore)
            let combinedContext = [folderCtx, peopleCtx]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            let input = SummaryPrompt.Input(title: meta.title, date: meta.startTime, duration: meta.effectiveDuration,
                                            lines: SummaryPrompt.lines(from: transcript, speakers: speakers),
                                            notes: notes, customInstructions: customInstructions(),
                                            folderContext: combinedContext,
                                            recorderName: recorderName())
            var sonnetSummary: MeetingSummary?
            if useSonnet {
                if ClaudeSonnet.isAvailable {
                    do {
                        sonnetSummary = try await ClaudeSonnet.summarize(input)
                        if PipelineStop.isRequested(folder.id) { throw CancellationError() }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        sonnetSummaryNote = error.localizedDescription
                    }
                } else {
                    sonnetSummaryNote = HaikuBridgeError.notConfigured.errorDescription
                }
            }
            if let sonnetSummary {
                summary = sonnetSummary
                backendName = "Claude Sonnet 5.5"
                modelName = HaikuBridge.model
                SummaryTimeLinker.link(&summary, lines: input.lines)
            } else {
                guard let backend = try await summarizer(meta.processing.requestedSummaryBackend) else {
                    if let sonnetSummaryNote {
                        _ = try? folder.updateMeta { $0.processing.sonnetSummaryNote = sonnetSummaryNote }
                    }
                    throw StageWaiting(reason: "Waiting for the summary model to finish downloading.")
                }
                // Await unload on this task (not a fire-and-forget Task): clearing MLX while
                // generation is still draining Metal command buffers kills the process.
                defer { await backend.unload() }
                backendName = backend.kind.displayName
                modelName = await backend.modelName()
                if PipelineStop.isRequested(folder.id) { throw CancellationError() }
                summary = try await summarize(input, with: backend, fallbackTitle: meta.title, meetingID: folder.id, progress: progress)
                SummaryTimeLinker.link(&summary, lines: input.lines)
            }
        }
        if PipelineStop.isRequested(folder.id) { throw CancellationError() }

        try folder.write(summary, .summary)
        let updated = try folder.updateMeta {
            if !$0.titleIsUserSet, summary.title != MeetingMeta.defaultTitle, !summary.title.isEmpty { $0.title = summary.title }
            $0.processing.summaryBackend = backendName
            $0.processing.summaryModel = modelName
            $0.processing.summarySeconds = (Date().timeIntervalSince(started) * 10).rounded() / 10
            $0.processing.requestedSummaryBackend = nil
            if useSonnet { $0.processing.sonnetSummaryNote = sonnetSummaryNote }
            if let sonnetSummaryNote {
                $0.events.append(SessionEvent(time: Date(), offsetSeconds: 0, type: "sonnet_summary", detail: sonnetSummaryNote))
            }
        }
        try folder.writeText(SummaryMarkdown.render(summary, meta: updated, notes: notes), .summaryMarkdown)
        progress(1)
    }

    private func summarize(_ input: SummaryPrompt.Input, with backend: Summarizer, fallbackTitle: String,
                           meetingID: String, progress: @escaping @Sendable (Double) -> Void) async throws -> MeetingSummary {
        let context = await backend.contextTokens()
        // Leave room for the reply (~2k tokens) and the notes/instructions.
        let pieces = TranscriptChunker.chunks(input.lines, maxTokens: max(context - 2_500, 1_500))
        if pieces.count == 1 {
            progress(0.1)
            return try await ask(backend, user: SummaryPrompt.user(input), notes: input.notes, fallbackTitle: fallbackTitle)
        }
        var partials: [String] = []
        for (index, lines) in pieces.enumerated() {
            try Task.checkCancellation()
            if PipelineStop.isRequested(meetingID) { throw CancellationError() }
            var part = input
            part.lines = lines
            part.notes = TranscriptChunker.notesForChunk(input.notes, pieces: pieces, index: index)
            let reply = try await backend.complete(system: SummaryPrompt.system,
                                                   user: SummaryPrompt.user(part, part: (index + 1, pieces.count)))
            partials.append((try? SummaryParser.extractJSON(reply)) ?? reply)
            progress(Double(index + 1) / Double(pieces.count + 1))
        }
        return try await ask(backend, user: SummaryPrompt.merge(partials: partials, input: input),
                             notes: input.notes, fallbackTitle: fallbackTitle)
    }

    /// One request, retried once with a firmer instruction if the reply is not usable JSON.
    private func ask(_ backend: Summarizer, user: String, notes: [MeetingNote], fallbackTitle: String) async throws -> MeetingSummary {
        let reply = try await backend.complete(system: SummaryPrompt.system, user: user)
        do {
            return try SummaryParser.parse(reply, notes: notes, fallbackTitle: fallbackTitle)
        } catch {
            try Task.checkCancellation()
            let retry = try await backend.complete(system: SummaryPrompt.system,
                                                   user: user + "\n\nYour previous answer was not valid JSON. Reply with the JSON object only.")
            return try SummaryParser.parse(retry, notes: notes, fallbackTitle: fallbackTitle)
        }
    }
}
