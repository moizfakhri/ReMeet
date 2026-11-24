import Foundation
import ReMeetKit

/// One text correction through `claude -p --model claude-sonnet-5-5`.
/// Parakeet has already drafted the transcript. The whole draft is the prompt. No audio is attached.
/// No key is read or stored.
/// Claude processes ReMeet started. Stop terminates one kind without touching the other.
private final class ClaudeJobs: @unchecked Sendable {
    struct Entry {
        var process: Process
        var kind: ClaudeSonnet.Kind
        var cancelled = false
    }

    let lock = NSLock()
    var jobs: [UUID: Entry] = [:]

    func track(_ process: Process, kind: ClaudeSonnet.Kind) -> UUID {
        let id = UUID()
        lock.lock()
        jobs[id] = Entry(process: process, kind: kind)
        lock.unlock()
        return id
    }

    /// Removes the job and reports whether Stop or task cancellation asked it to end.
    func take(_ id: UUID) -> Bool {
        lock.lock()
        let cancelled = jobs[id]?.cancelled ?? false
        jobs.removeValue(forKey: id)
        lock.unlock()
        return cancelled
    }

    func cancel(_ id: UUID) {
        lock.lock()
        jobs[id]?.cancelled = true
        let process = jobs[id]?.process
        lock.unlock()
        if process?.isRunning == true { process?.terminate() }
    }

    func isRunning(_ kind: ClaudeSonnet.Kind) -> Bool {
        lock.lock()
        let running = jobs.values.contains { $0.kind == kind && $0.process.isRunning }
        lock.unlock()
        return running
    }

    @discardableResult
    func stop(_ kind: ClaudeSonnet.Kind) -> Bool {
        lock.lock()
        let matched = jobs.filter { $0.value.kind == kind }.map(\.key)
        for id in matched { jobs[id]?.cancelled = true }
        let processes = matched.compactMap { jobs[$0]?.process }
        lock.unlock()
        for process in processes where process.isRunning { process.terminate() }
        return !matched.isEmpty
    }
}

private let claudeJobs = ClaudeJobs()

/// One in-flight wording pass per app. A later pass wins if both finish.
private actor WordingRevision {
    static let shared = WordingRevision()
    private var ticket = 0
    func issue() -> Int { ticket += 1; return ticket }
    func isCurrent(_ token: Int) -> Bool { token == ticket }
}

enum ClaudeSonnet {
    enum Kind: Sendable { case pipeline, wording, chat }

    static var isAvailable: Bool { executable() != nil }

    static func isRunning(_ kind: Kind) -> Bool { claudeJobs.isRunning(kind) }

    /// Ends that kind of claude call. The on-device model is not touched.
    static func stop(_ kind: Kind) { claudeJobs.stop(kind) }

    static func executable() -> URL? {
        let local = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude")
        if FileManager.default.isExecutableFile(atPath: local.path) { return local }
        return nil
    }

    static func correct(_ segments: [TranscriptSegment], speakers: SpeakerNames, context: String = "", kind: Kind = .pipeline) async throws -> [TranscriptSegment] {
        guard let executable = executable() else { throw HaikuBridgeError.notConfigured }
        let lines = segments.enumerated().map { index, segment in
            (index: index, id: segment.speaker, speaker: speakers.displayName(for: segment.speaker), text: segment.text)
        }
        let hasWords = lines.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard hasWords else { return segments }
        let prompt = HaikuCorrection.userPrompt(lines, context: context)
        let reply = try await run(executable, system: HaikuCorrection.system, prompt: prompt, kind: kind)
        let texts = try HaikuCorrection.apply(reply: reply, originals: segments.map(\.text))
        var corrected = segments
        for index in texts.indices where texts[index] != corrected[index].text {
            corrected[index].text = texts[index]
        }
        return corrected
    }

    /// Rewrites the words of an existing transcript with the current names. Does not read audio.
    /// A newer save or merge supersedes this call. The write copies wording onto the transcript
    /// as it is at that moment, so a merge that landed during the call is not undone.
    /// True when this call wrote the transcript. A newer save wins and this call leaves the file alone.
    @discardableResult
    static func reviseMeeting(_ folder: MeetingFolder, recorderName: String) async throws -> Bool {
        guard let transcript = try folder.read(Transcript.self, .transcript) else {
            throw RunnerError.missing("transcript.json")
        }
        let speakers = ((try? folder.read(SpeakerNames.self, .speakers)) ?? nil) ?? SpeakerNames()
        let hasWords = transcript.segments.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard hasWords else { return false }
        let ticket = await WordingRevision.shared.issue()
        let attendees = ((try? folder.readMeta().calendarAttendees) ?? []).filter { $0.status != .declined }.map(\.name)
        let context = NameGlossary.context(recorderName: recorderName, speakers: speakers,
                                           segments: transcript.segments, attendeeNames: attendees)
        let corrected = try await correct(transcript.segments, speakers: speakers, context: context, kind: .wording)
        guard await WordingRevision.shared.isCurrent(ticket) else { return false }
        guard TranscriptSpeakers.preserved(original: transcript.segments, corrected: corrected) else {
            throw HaikuBridgeError.badReply
        }
        let current = (try folder.read(Transcript.self, .transcript)) ?? transcript
        guard current.segments.count == corrected.count else { throw HaikuBridgeError.badReply }
        var written = current
        for index in written.segments.indices {
            let fresh = written.segments[index]
            let sent = transcript.segments[index]
            guard fresh.source == sent.source, fresh.start == sent.start, fresh.end == sent.end else {
                throw HaikuBridgeError.badReply
            }
            written.segments[index].text = corrected[index].text
        }
        let base = written.engine.replacingOccurrences(of: ", then Claude Sonnet 5.5", with: "")
        written.engine = base.contains("Sonnet") ? base : "\(base), then Claude Sonnet 5.5"
        try folder.write(written, .transcript)
        let named = ((try? folder.read(SpeakerNames.self, .speakers)) ?? nil) ?? speakers
        let meta = try folder.updateMeta {
            $0.processing.transcriptionEngine = written.engine
            $0.processing.sonnetTranscriptNote = nil
        }
        let notes = NotesFile(url: folder.file(.notes)).load()
        try folder.writeText(TranscriptMarkdown.render(written, notes: notes, speakers: named, title: meta.title), .transcriptMarkdown)
        return true
    }

    /// The same text-only command, asked for the meeting summary. No audio is attached.
    static func summarize(_ input: SummaryPrompt.Input) async throws -> MeetingSummary {
        guard let executable = executable() else { throw HaikuBridgeError.notConfigured }
        let reply = try await run(executable, system: SummaryPrompt.system, prompt: SummaryPrompt.user(input), kind: .pipeline)
        return try SummaryParser.parse(reply, notes: input.notes, fallbackTitle: input.title)
    }

    /// Meeting Q&A over retrieved excerpts only. No audio is attached.
    static func askMeeting(question: String, passages: [MeetingChatPrompt.Passage],
                           recorderName: String, history: [MeetingChatTurn] = []) async throws -> MeetingChatAnswer {
        guard let executable = executable() else { throw MeetingChatError.notConfigured }
        let prompt = MeetingChatPrompt.user(question: question, passages: passages, recorderName: recorderName, history: history)
        let reply = try await run(executable, system: MeetingChatPrompt.system, prompt: prompt, kind: .chat)
        return try MeetingChatPrompt.parseAnswer(reply)
    }

    private static func run(_ executable: URL, system: String, prompt: String, kind: Kind) async throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = HaikuBridge.textArguments(system: system)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var environment = ProcessInfo.processInfo.environment
        let prefix = "\(home)/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = prefix + (environment["PATH"].map { ":\($0)" } ?? "")
        environment.removeValue(forKey: "CLAUDE_CODE_OAUTH_TOKEN")
        environment.removeValue(forKey: "ANTHROPIC_API_KEY")
        process.environment = environment
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("remeet-sonnet", isDirectory: true)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        process.currentDirectoryURL = work
        let outURL = work.appendingPathComponent("out-\(UUID().uuidString).txt")
        let errURL = work.appendingPathComponent("err-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        guard let outHandle = try? FileHandle(forWritingTo: outURL),
              let errHandle = try? FileHandle(forWritingTo: errURL) else {
            throw HaikuBridgeError.unreachable
        }
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = outHandle
        process.standardError = errHandle
        let job = claudeJobs.track(process, kind: kind)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let resumed = ResumeOnce()
                process.terminationHandler = { process in
                    resumed.cancelTimeout()
                    let cancelled = claudeJobs.take(job)
                    try? outHandle.close()
                    try? errHandle.close()
                    let data = (try? Data(contentsOf: outURL)) ?? Data()
                    let errorText = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
                    try? FileManager.default.removeItem(at: outURL)
                    try? FileManager.default.removeItem(at: errURL)
                    if cancelled {
                        resumed.resume(continuation, throwing: CancellationError())
                        return
                    }
                    if process.terminationStatus != 0, data.isEmpty {
                        resumed.resume(continuation, throwing: HaikuBridgeError.server(HaikuBridge.redact(errorText.isEmpty ? "claude exited \(process.terminationStatus)" : errorText)))
                        return
                    }
                    do {
                        resumed.resume(continuation, returning: try HaikuBridge.text(fromCLIJSON: data))
                    } catch {
                        resumed.resume(continuation, throwing: error)
                    }
                }
                do {
                    try process.run()
                } catch {
                    resumed.cancelTimeout()
                    _ = claudeJobs.take(job)
                    resumed.resume(continuation, throwing: HaikuBridgeError.unreachable)
                    return
                }
                let body = Data(prompt.utf8)
                DispatchQueue.global(qos: .userInitiated).async {
                    input.fileHandleForWriting.write(body)
                    try? input.fileHandleForWriting.close()
                }
                resumed.setTimeout(Task {
                    try? await Task.sleep(for: .seconds(240))
                    guard !Task.isCancelled else { return }
                    if process.isRunning { process.terminate() }
                })
            }
        } onCancel: {
            claudeJobs.cancel(job)
        }
    }
}

/// `terminationHandler` and a failed `run()` must not both resume the continuation.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private var timeout: Task<Void, Never>?

    func setTimeout(_ task: Task<Void, Never>) {
        lock.lock()
        if done {
            lock.unlock()
            task.cancel()
            return
        }
        timeout = task
        lock.unlock()
    }

    func cancelTimeout() {
        lock.lock()
        let task = timeout
        timeout = nil
        lock.unlock()
        task?.cancel()
    }

    func resume(_ continuation: CheckedContinuation<String, Error>, returning value: String) {
        lock.lock()
        let first = !done
        done = true
        let task = timeout
        timeout = nil
        lock.unlock()
        task?.cancel()
        if first { continuation.resume(returning: value) }
    }

    func resume(_ continuation: CheckedContinuation<String, Error>, throwing error: Error) {
        lock.lock()
        let first = !done
        done = true
        let task = timeout
        timeout = nil
        lock.unlock()
        task?.cancel()
        if first { continuation.resume(throwing: error) }
    }
}
