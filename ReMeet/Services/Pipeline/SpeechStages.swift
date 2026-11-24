import AVFoundation
import CoreML
import FluidAudio
import Foundation
import ReMeetKit

/// One speaker turn. `words` are times from the start of `samples`. Empty means the engine
/// did not return a time for each word.
struct LocalSpeech: Sendable {
    var text: String
    var words: [TranscriptWord]
}

/// Speech to text for one speaker turn.
protocol Transcriber: Sendable {
    var engineName: String { get }
    func load() async throws
    func transcribe(_ samples: [Float]) async throws -> LocalSpeech
    func unload() async
}

/// Parakeet TDT 0.6B v2 (English) through FluidAudio, on the Neural Engine.
actor ParakeetTranscriber: Transcriber {
    nonisolated let engineName = "Parakeet TDT 0.6B v2"
    private let directory: URL
    private var manager: AsrManager?

    init(directory: URL) {
        self.directory = directory
    }

    func load() async throws {
        guard manager == nil else { return }
        let models = try await AsrModels.load(from: directory, version: .v2)
        let manager = AsrManager()
        try await manager.loadModels(models)
        self.manager = manager
    }

    func transcribe(_ samples: [Float]) async throws -> LocalSpeech {
        guard let manager else { throw StageWaiting(reason: "Speech model not loaded") }
        // Parakeet needs at least ~1 s of input; pad short turns with silence.
        var input = samples
        if input.count < 16_000 { input += [Float](repeating: 0, count: 16_000 - input.count) }
        var state = TdtDecoderState.make()
        let result = try await manager.transcribe(input, decoderState: &state)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let built = buildWordTimings(from: result.tokenTimings ?? [])
        let pieces = WordLayout.tokens(text)
        let words: [TranscriptWord]
        if built.count == pieces.count {
            words = zip(pieces, built).map { token, time in
                TranscriptWord(text: token, start: time.startTime, end: time.endTime)
            }
        } else {
            words = []
        }
        return LocalSpeech(text: text, words: words)
    }

    func unload() async {
        await manager?.cleanup()
        manager = nil
    }
}

/// Reads stretches of a 16 kHz mono track (mic-16k.m4a / system-16k.m4a) straight from
/// disk, so a long meeting is never loaded into memory whole.
final class TrackReader {
    private let file: AVAudioFile
    private let buffer: AVAudioPCMBuffer
    let rate: Double

    init(_ url: URL) throws {
        file = try AVAudioFile(forReading: url)
        rate = file.processingFormat.sampleRate
        buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(rate * 100))!
    }

    /// Mono samples for [start, end) seconds (at most 100 s, which turns never exceed).
    func samples(from start: Double, to end: Double) throws -> [Float] {
        let first = AVAudioFramePosition(max(0, start) * rate)
        guard first < file.length else { return [] }
        let count = min(AVAudioFrameCount(max(0, end - start) * rate), buffer.frameCapacity,
                        AVAudioFrameCount(file.length - first))
        file.framePosition = first
        try file.read(into: buffer, frameCount: count)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }
}

enum TrackAudio {

    static func duration(_ url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.fileFormat.sampleRate
    }

}

/// Diarize stage: who spoke when. Mic energy is the user. The diarizer runs only on the
/// system track and only to split other people. `audio.m4a` is never opened.
struct DiarizeRunner: StageRunner {
    let models: @Sendable () async -> (ready: Bool, directory: URL)
    let speakerLabels: @Sendable () -> Bool

    func run(_ folder: MeetingFolder, progress: @escaping @Sendable (Double) -> Void) async throws {
        let tracks = MeetingFolder.modelTracks.filter(folder.exists)
        // No separate tracks left but a transcript exists (Keep audio removed them): finding
        // "no speech" here would replace the real transcript with an empty one. Keep it instead.
        // The mixed playback file is not a substitute.
        if tracks.isEmpty, folder.exists(.transcript) {
            throw RunnerError.audioRemoved
        }
        let labels = speakerLabels()
        let diarizeSystem = labels && folder.exists(.system16k)
        let modelRoot: URL?
        if diarizeSystem {
            let (ready, root) = await models()
            guard ready else { throw StageWaiting(reason: "Waiting for the speaker model to finish downloading.") }
            modelRoot = root
        } else {
            modelRoot = nil
        }
        let previousDiarization = (try? folder.read(Diarization.self, .diarization)) ?? nil
        let previousNames = (try? folder.read(SpeakerNames.self, .speakers)) ?? nil
        let micEnergy = folder.exists(.mic16k) ? try energySegments(folder.file(.mic16k)) : []
        let systemEnergy = folder.exists(.system16k) ? try energySegments(folder.file(.system16k)) : []
        var systemSpeech = TrackSpeech(segments: [], embeddings: [:])
        if let modelRoot {
            let diarizerModels = try await OfflineDiarizerModels.load(from: modelRoot)
            let expected = (try? folder.readMeta())?.expectedCallSpeakers
            var config = OfflineDiarizerConfig.default
            config.postProcessing.exclusiveSegments = true
            if let expected, (1...12).contains(expected) {
                config = config.withSpeakers(exactly: expected)
            }
            let manager = OfflineDiarizerManager(config: config)
            manager.initialize(models: diarizerModels)
            systemSpeech = try await Self.diarize(folder.file(.system16k), manager: manager, progress: progress)
        }
        let expected = (try? folder.readMeta())?.expectedCallSpeakers
        let plan = SpeakerTurnPlan.assemble(
            micEnergy: micEnergy,
            systemEnergy: systemEnergy,
            systemDiarized: systemSpeech.segments,
            systemEmbeddings: systemSpeech.embeddings,
            labelSpeakers: labels)
        // Names are not written here. A voiceprint is a suggestion the user accepts per voice.
        let engine: String
        if labels {
            engine = expected.map { "mic energy; pyannote community-1 on the call track (FluidAudio offline VBx, \($0) call speakers)" }
                ?? "mic energy; pyannote community-1 on the call track (FluidAudio offline VBx)"
        } else {
            engine = "energy on each track; speaker labels off"
        }
        try folder.write(Diarization(mic: plan.mic, system: plan.system, engine: engine, embeddings: plan.embeddings), .diarization)
        let carried = SpeakerNameCarry.names(previous: previousNames ?? SpeakerNames(),
                                             previousEmbeddings: previousDiarization?.embeddings ?? [:],
                                             nextEmbeddings: plan.embeddings)
        try folder.write(carried, .speakers)
        _ = try folder.updateMeta {
            var label = labels ? "mic energy, pyannote community-1 on the call" : "energy, speaker labels off"
            if let expected, labels { label += ", \(expected) call speakers" }
            $0.processing.diarization = label
        }
        progress(1)
    }

    /// One track, plus a voice embedding per raw diarizer id (WeSpeaker, via FluidAudio).
    private static func diarize(_ url: URL, manager: OfflineDiarizerManager,
                                progress: @escaping @Sendable (Double) -> Void) async throws -> TrackSpeech {
        if url.lastPathComponent == MeetingFolder.File.audio.rawValue {
            throw RunnerError.mixedAudio
        }
        let result: DiarizationResult
        do {
            result = try await manager.process(url) { done, total in progress(Double(done) / Double(max(total, 1))) }
        } catch OfflineDiarizationError.noSpeechDetected {
            // The diarizer misses short recordings and short utterances (10 s windows). If the
            // track has sound, find it by loudness instead so the words are not dropped; a
            // truly silent track (e.g. no call audio) stays empty (audit C1).
            progress(1)
            return TrackSpeech(segments: try energySegments(url).map { SpeechSegment(start: $0.start, end: $0.end, speaker: "energy") },
                               embeddings: [:])
        }
        let segments = result.segments.map {
            SpeechSegment(start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds), speaker: $0.speakerId)
        }
        return TrackSpeech(segments: segments, embeddings: Self.embeddings(from: result))
    }

    private static func embeddings(from result: DiarizationResult) -> [String: [Float]] {
        if let database = result.speakerDatabase?.filter({ !$0.value.isEmpty }), !database.isEmpty {
            return database
        }
        var sums: [String: [Float]] = [:]
        var counts: [String: Int] = [:]
        for segment in result.segments where !segment.embedding.isEmpty {
            let id = segment.speakerId
            if var sum = sums[id], sum.count == segment.embedding.count {
                for index in sum.indices { sum[index] += segment.embedding[index] }
                sums[id] = sum
            } else if sums[id] == nil {
                sums[id] = segment.embedding
            }
            counts[id, default: 0] += 1
        }
        var mean: [String: [Float]] = [:]
        for (id, sum) in sums {
            let count = Float(max(counts[id] ?? 1, 1))
            mean[id] = sum.map { $0 / count }
        }
        return mean
    }
}

/// Speech found on one track, and the diarizer's embedding for each raw speaker id.
private struct TrackSpeech: Sendable {
    var segments: [SpeechSegment]
    var embeddings: [String: [Float]]
}

/// Loud stretches of a 16 kHz track, read in 60 s chunks (never the whole track at once).
private func energySegments(_ url: URL) throws -> [(start: Double, end: Double)] {
    let reader = try TrackReader(url)
    let length = try TrackAudio.duration(url)
    var result: [(start: Double, end: Double)] = []
    var offset = 0.0
    while offset < length {
        let chunk = try reader.samples(from: offset, to: min(length, offset + 60))
        if chunk.isEmpty { break }
        for segment in EnergySegmenter.segments(chunk, rate: reader.rate) {
            let shifted = (start: segment.start + offset, end: segment.end + offset)
            if let last = result.last, shifted.start - last.end <= 0.8 {
                result[result.count - 1].end = shifted.end
            } else {
                result.append(shifted)
            }
        }
        offset += 60
    }
    return result
}

/// Combines per-track progress into one 0...1 value.
final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var parts: [Double]
    private let report: @Sendable (Double) -> Void

    init(count: Int, report: @escaping @Sendable (Double) -> Void) {
        parts = Array(repeating: 0, count: max(count, 1))
        self.report = report
    }

    func update(_ index: Int, _ value: Double) {
        let total = lock.withLock { () -> Double in
            parts[index] = value
            return parts.reduce(0, +) / Double(parts.count)
        }
        report(total)
    }
}

/// The latest value written from one task and read by another.
final class LatestValue: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0.0
    var value: Double {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// How one meeting gets its local draft. Sonnet cleanup runs after this, on the text.
enum TranscriptionRoute: Sendable {
    case local(Transcriber)

    var engineName: String { transcriber.engineName }

    var transcriber: Transcriber {
        switch self {
        case .local(let transcriber): transcriber
        }
    }
}

/// Transcribe stage: each speaker turn of each track through the Transcriber, stitched into
/// transcript.json and transcript.md.
struct TranscribeRunner: StageRunner {
    let route: @Sendable (MeetingFolder) async -> TranscriptionRoute?
    let releaseModels: @Sendable () async -> Void
    /// Production runs Sonnet after the local draft. Tests that measure the local draft turn it off.
    var useSonnet = true
    /// The recording person's name, for the Sonnet wording pass. Empty in tests.
    var recorderName: @Sendable () -> String = { "" }

    func run(_ folder: MeetingFolder, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let route = await route(folder) else {
            throw StageWaiting(reason: "Waiting for the speech model to finish downloading.")
        }
        let transcriber = route.transcriber
        guard let diarization = try folder.read(Diarization.self, .diarization) else {
            throw RunnerError.missing("diarization.json")
        }
        // Real progress only moves when a speaker turn finishes, and one long turn can take a
        // minute on Cohere, so the bar follows an estimate of the whole stage (model load +
        // seconds of speech x this engine's measured rate) up to 99%, never behind the real
        // fraction, and shows 100% only when the transcript is written.
        let estimate = Self.estimate(folder, diarization: diarization, engine: route.engineName)
        let actual = LatestValue()
        let started = Date()
        let ticker = Task {
            var shown = EstimatedProgress(expected: estimate.expected)
            while !Task.isCancelled {
                progress(shown.value(elapsed: Date().timeIntervalSince(started), actual: actual.value))
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        defer { ticker.cancel() }
        try await transcriber.load()
        // Released as soon as this meeting's turns are done, so the speech model is never in
        // memory together with the summary model. Awaited here, not in a detached Task: the
        // Cohere (MLX) unload clears MLX's buffer cache, which must not race the summary
        // model loading on the GPU right after this stage (same crash family as
        // BuiltInSummarizer's unload notes).
        do {
            try await transcribeTurns(folder, transcriber: transcriber, diarization: diarization,
                                      engineLabel: route.engineName) { actual.value = $0 }
        } catch {
            await transcriber.unload()
            throw error
        }
        await transcriber.unload()
        ticker.cancel()
        progress(1)
        Self.learn(engine: route.engineName, seconds: Date().timeIntervalSince(started), estimate: estimate)
    }

    // MARK: - Time estimate

    struct Estimate {
        var audioSeconds: Double
        var load: Double
        var expected: TimeInterval
    }

    /// Seconds per second of speech and model-load seconds, measured on the M4 (16 GB):
    /// Parakeet ~25 s per hour, Cohere on MLX ~170-230 s per hour. Replaced by this Mac's own
    /// numbers after each run.
    private static func defaults(for engine: String) -> (rate: Double, load: Double) {
        return engine.contains("Cohere") ? (0.055, 4) : (0.008, 2)
    }

    private static func rateKey(_ engine: String) -> String { "transcribeRate.\(engine)" }

    static func estimate(_ folder: MeetingFolder, diarization: Diarization, engine: String) -> Estimate {
        var audio = 0.0
        for (segments, source, file) in Self.trackJobs(diarization) where folder.exists(file) {
            let duration = (try? TrackAudio.duration(folder.file(file))) ?? 0
            audio += TurnBuilder.turns(from: segments, source: source, audioDuration: duration).reduce(0) { $0 + $1.duration }
        }
        let base = defaults(for: engine)
        let stored = UserDefaults.standard.double(forKey: rateKey(engine))
        let rate = stored > 0 ? stored : base.rate
        return Estimate(audioSeconds: audio, load: base.load,
                        expected: EstimatedProgress.expectedSeconds(audioSeconds: audio, secondsPerAudioSecond: rate,
                                                                    loadSeconds: base.load))
    }

    private static func learn(engine: String, seconds: TimeInterval, estimate: Estimate) {
        guard estimate.audioSeconds >= 30 else { return }   // short clips are mostly load time
        let measured = max(seconds - estimate.load, 0) / estimate.audioSeconds
        let stored = UserDefaults.standard.double(forKey: rateKey(engine))
        UserDefaults.standard.set(EstimatedProgress.learn(stored: stored > 0 ? stored : nil, measured: measured),
                                  forKey: rateKey(engine))
    }

    /// Mic and system only, in recording order. The mix is not a job.
    private static func trackJobs(_ diarization: Diarization) -> [(segments: [SpeechSegment], source: TrackSource, file: MeetingFolder.File)] {
        [(diarization.mic, .mic, .mic16k), (diarization.system, .system, .system16k)]
    }

    private func transcribeTurns(_ folder: MeetingFolder, transcriber: Transcriber, diarization: Diarization,
                                 engineLabel: String,
                                 progress: @escaping @Sendable (Double) -> Void) async throws {
        var jobs: [(Turn, MeetingFolder.File)] = []
        for (segments, source, file) in Self.trackJobs(diarization) where folder.exists(file) {
            if file == .audio { throw RunnerError.mixedAudio }
            let duration = (try? TrackAudio.duration(folder.file(file))) ?? 0
            jobs += TurnBuilder.turns(from: segments, source: source, audioDuration: duration).map { ($0, file) }
        }
        let totalSeconds = max(jobs.reduce(0) { $0 + $1.0.duration }, 1)
        var doneSeconds = 0.0
        var segments: [TranscriptSegment] = []
        var readers: [MeetingFolder.File: TrackReader] = [:]
        var failedTurns = 0
        var lastTurnError: String?
        for (turn, file) in jobs {
            try Task.checkCancellation()
            if PipelineStop.isRequested(folder.id) { throw CancellationError() }
            if readers[file] == nil { readers[file] = try TrackReader(folder.file(file)) }
            // One unreadable turn must not fail the meeting forever: skip it and count it, and
            // fail only if most turns fail (audit H4).
            let speech: LocalSpeech
            do {
                let audio = try readers[file]!.samples(from: turn.start, to: turn.end)
                speech = try await transcriber.transcribe(audio)
            } catch is CancellationError {
                throw CancellationError()
            } catch let bridge as HaikuBridgeError {
                throw bridge
            } catch {
                failedTurns += 1
                lastTurnError = error.localizedDescription
                speech = LocalSpeech(text: "", words: [])
            }
            let words = speech.words.map { word in
                TranscriptWord(text: word.text, start: word.start + turn.start, end: word.end + turn.start)
            }
            segments.append(TranscriptSegment(start: turn.start, end: turn.end, speaker: turn.speaker,
                                              text: speech.text, source: turn.source, words: words))
            doneSeconds += turn.duration
            progress(doneSeconds / totalSeconds)
        }
        if failedTurns > 0, failedTurns * 2 > jobs.count {
            throw RunnerError.turns(failed: failedTurns, of: jobs.count, last: lastTurnError ?? "unknown error")
        }
        let speakers = ((try? folder.read(SpeakerNames.self, .speakers)) ?? nil) ?? SpeakerNames()
        var sonnetNote: String?
        var usedSonnet = false
        let hasWords = segments.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if PipelineStop.isRequested(folder.id) { throw CancellationError() }
        if useSonnet, hasWords {
            do {
                let attendees = ((try? folder.readMeta().calendarAttendees) ?? []).filter { $0.status != .declined }.map(\.name)
                let context = NameGlossary.context(recorderName: recorderName(), speakers: speakers,
                                                   segments: segments, attendeeNames: attendees)
                let corrected = try await ClaudeSonnet.correct(segments, speakers: speakers, context: context)
                if PipelineStop.isRequested(folder.id) { throw CancellationError() }
                if TranscriptSpeakers.preserved(original: segments, corrected: corrected) {
                    segments = corrected
                    usedSonnet = true
                } else {
                    sonnetNote = "Sonnet tried to change who spoke. The local transcript was kept."
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                sonnetNote = error.localizedDescription
            }
        }
        if PipelineStop.isRequested(folder.id) { throw CancellationError() }
        let writtenEngine = usedSonnet ? "\(engineLabel), then Claude Sonnet 5.5" : engineLabel
        // Each turn already carries its track time. Stitching sorts those times onto one timeline
        // so they match the mixed playback file, which starts at the same zero.
        let transcript = Transcript(engine: writtenEngine, segments: Stitcher.stitch(segments))
        try folder.write(transcript, .transcript)
        let meta = try folder.updateMeta {
            $0.processing.transcriptionEngine = writtenEngine
            if useSonnet { $0.processing.sonnetTranscriptNote = sonnetNote }
            if let sonnetNote {
                $0.events.append(SessionEvent(time: Date(), offsetSeconds: 0, type: "sonnet_transcript", detail: sonnetNote))
            }
            if failedTurns > 0 {
                $0.events.append(SessionEvent(time: Date(), offsetSeconds: 0, type: "turns_skipped",
                                              detail: "\(failedTurns) of \(jobs.count) turns could not be transcribed: \(lastTurnError ?? "")"))
            }
        }
        let notes = NotesFile(url: folder.file(.notes)).load()
        try folder.writeText(TranscriptMarkdown.render(transcript, notes: notes, speakers: speakers,
                                                       title: meta.title), .transcriptMarkdown)
        progress(1)
    }

    func unload() async {
        await releaseModels()
    }
}

enum RunnerError: LocalizedError {
    case missing(String)
    case turns(failed: Int, of: Int, last: String)
    case audioRemoved
    case mixedAudio
    var errorDescription: String? {
        switch self {
        case .missing(let file): "\(file) is missing; reprocess the meeting."
        case .turns(let failed, let total, let last): "\(failed) of \(total) speaker turns could not be transcribed (\(last))."
        case .audioRemoved: "This meeting's audio was removed by the Keep audio setting, so it can't be transcribed again. The transcript is kept."
        case .mixedAudio: "The mixed recording is for playback only, so it was not sent to the speech model."
        }
    }
}
