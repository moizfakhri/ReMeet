import Foundation

/// Where a meeting is in its life. Each value is the last step that finished, so the
/// pipeline can resume from meta.json alone after a quit or crash.
public enum MeetingStatus: String, Codable, Sendable, CaseIterable {
    case recording
    case recorded
    case compressed
    case diarized
    case transcribed
    case summarized
    case failed
}

/// The processing steps after recording, in order.
public enum PipelineStage: String, Codable, Sendable, CaseIterable, Comparable {
    case compress
    case diarize
    case transcribe
    case summarize

    public var displayName: String {
        switch self {
        case .compress: "Compressing audio"
        case .diarize: "Finding speakers"
        case .transcribe: "Transcribing"
        case .summarize: "Writing summary"
        }
    }

    /// The status a meeting has once this stage has finished.
    public var completedStatus: MeetingStatus {
        switch self {
        case .compress: .compressed
        case .diarize: .diarized
        case .transcribe: .transcribed
        case .summarize: .summarized
        }
    }

    public static func < (lhs: PipelineStage, rhs: PipelineStage) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

public struct MeetingFailure: Codable, Equatable, Sendable {
    public var stage: PipelineStage
    public var message: String
    public var time: Date
    /// The user dismissed it from the menu bar: it no longer raises the warning icon
    /// (the meeting still shows its failure and Retry).
    public var dismissed: Bool

    public init(stage: PipelineStage, message: String, time: Date = Date(), dismissed: Bool = false) {
        self.stage = stage
        self.message = message
        self.time = time
        self.dismissed = dismissed
    }

    private enum CodingKeys: String, CodingKey { case stage, message, time, dismissed }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stage = try c.decode(PipelineStage.self, forKey: .stage)
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
        time = try c.decodeIfPresent(Date.self, forKey: .time) ?? Date()
        dismissed = try c.decodeIfPresent(Bool.self, forKey: .dismissed) ?? false
    }
}

/// What produced the transcript and summary, shown under the summary and used by Regenerate.
public struct ProcessingInfo: Codable, Equatable, Sendable {
    public var transcriptionEngine: String?
    public var diarization: String?
    public var summaryBackend: String?
    public var summaryModel: String?
    public var summarySeconds: Double?
    /// Set by Regenerate to use a specific backend once; cleared after the summary is written.
    public var requestedSummaryBackend: SummaryBackendKind?
    /// Per-meeting transcription override (`TranscriptionEngine` raw value). Nil uses Settings.
    public var requestedTranscriptionEngine: String?
    /// Wall-clock seconds per finished stage, keyed by PipelineStage raw value.
    public var stageSeconds: [String: Double] = [:]
    /// Why automatic Sonnet transcript cleanup did not replace the local draft. Nil when it ran, or when there was nothing to clean.
    public var sonnetTranscriptNote: String?
    /// Why automatic Sonnet did not write the summary. Nil when Sonnet wrote it, or when the summary was skipped.
    public var sonnetSummaryNote: String?

    public init() {}
}

/// meta.json. Decoding is lenient so Phase 0 recordings (no schema version, no status)
/// open as ordinary finished recordings.
public struct MeetingMeta: Codable, Equatable, Sendable {
    public struct Devices: Codable, Equatable, Sendable {
        public var initialInput: AudioDeviceInfo?
        public var initialOutput: AudioDeviceInfo?
        public var finalInput: AudioDeviceInfo?
        public var finalOutput: AudioDeviceInfo?

        public init(initialInput: AudioDeviceInfo? = nil, initialOutput: AudioDeviceInfo? = nil) {
            self.initialInput = initialInput
            self.initialOutput = initialOutput
        }
    }

    public static let currentSchemaVersion = 1
    public static let defaultTitle = "Untitled meeting"

    public var schemaVersion = MeetingMeta.currentSchemaVersion
    public var app = "ReMeet"
    public var title: String
    /// True once the user (or the summary) named it; auto titles may be replaced by the summary.
    public var titleIsUserSet = false
    public var status: MeetingStatus
    public var failure: MeetingFailure?
    public var startTime: Date
    public var endTime: Date?
    public var durationSeconds: Double?
    /// Meeting app that had the mic when recording started (bundle identifier), if known.
    public var sourceApp: String?
    /// The user folder this meeting is in (`MeetingCollection.id`), nil = none.
    public var collectionID: String?
    /// Last auto-exported AI Markdown file path, so renames and folder moves update in place
    /// instead of leaving stale duplicates behind.
    public var exportedMarkdownPath: String?
    /// Voices to find on the call audio, not counting you. Nil lets the diarizer decide.
    public var expectedCallSpeakers: Int?
    /// Linked calendar event identifier (when recorded from or matched to Apple/Google Calendar).
    public var calendarEventID: String?
    /// Participants from the linked calendar event, used to seed People profiles and boost speaker matching.
    public var calendarAttendees: [CalendarAttendee] = []
    /// Video call join URL from the linked calendar event, if any.
    public var calendarJoinURL: String?
    /// Name of the calendar this meeting came from (e.g. "Work (Google)").
    public var calendarName: String?
    public var startHostTime: UInt64?
    public var clock: String?
    public var devices: Devices
    public var mic: TrackStats?
    public var system: TrackStats?
    public var events: [SessionEvent] = []
    public var processing = ProcessingInfo()

    public init(title: String = MeetingMeta.defaultTitle, status: MeetingStatus = .recording,
                startTime: Date, startHostTime: UInt64? = nil, devices: Devices = .init()) {
        self.title = title
        self.status = status
        self.startTime = startTime
        self.startHostTime = startHostTime
        self.devices = devices
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, app, title, titleIsUserSet, status, failure, startTime, endTime, durationSeconds
        case sourceApp, collectionID, exportedMarkdownPath, expectedCallSpeakers
        case calendarEventID, calendarAttendees, calendarJoinURL, calendarName
        case startHostTime, clock, devices, mic, system, events, processing
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        app = try c.decodeIfPresent(String.self, forKey: .app) ?? "ReMeet"
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? Self.defaultTitle
        titleIsUserSet = try c.decodeIfPresent(Bool.self, forKey: .titleIsUserSet) ?? false
        startTime = try c.decode(Date.self, forKey: .startTime)
        endTime = try c.decodeIfPresent(Date.self, forKey: .endTime)
        durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds)
        failure = try c.decodeIfPresent(MeetingFailure.self, forKey: .failure)
        // Phase 0 files have no status: a finished one (endTime set) is simply "recorded".
        status = try c.decodeIfPresent(MeetingStatus.self, forKey: .status)
            ?? (endTime != nil ? .recorded : .recording)
        sourceApp = try c.decodeIfPresent(String.self, forKey: .sourceApp)
        collectionID = try c.decodeIfPresent(String.self, forKey: .collectionID)
        exportedMarkdownPath = try c.decodeIfPresent(String.self, forKey: .exportedMarkdownPath)
        let speakers = try c.decodeIfPresent(Int.self, forKey: .expectedCallSpeakers)
        expectedCallSpeakers = speakers.flatMap { (1...8).contains($0) ? $0 : nil }
        calendarEventID = try c.decodeIfPresent(String.self, forKey: .calendarEventID)
        calendarAttendees = try c.decodeIfPresent([CalendarAttendee].self, forKey: .calendarAttendees) ?? []
        calendarJoinURL = try c.decodeIfPresent(String.self, forKey: .calendarJoinURL)
        calendarName = try c.decodeIfPresent(String.self, forKey: .calendarName)
        startHostTime = try c.decodeIfPresent(UInt64.self, forKey: .startHostTime)
        clock = try c.decodeIfPresent(String.self, forKey: .clock)
        devices = try c.decodeIfPresent(Devices.self, forKey: .devices) ?? .init()
        mic = try c.decodeIfPresent(TrackStats.self, forKey: .mic)
        system = try c.decodeIfPresent(TrackStats.self, forKey: .system)
        events = try c.decodeIfPresent([SessionEvent].self, forKey: .events) ?? []
        processing = try c.decodeIfPresent(ProcessingInfo.self, forKey: .processing) ?? ProcessingInfo()
    }

    // MARK: - Pipeline bookkeeping

    /// The next stage to run, or nil when there is nothing to do (still recording, or done).
    /// A failed meeting resumes at the stage that failed.
    public var nextStage: PipelineStage? {
        switch status {
        case .recording, .summarized: nil
        case .recorded: .compress
        case .compressed: .diarize
        case .diarized: .transcribe
        case .transcribed: .summarize
        case .failed: failure?.stage ?? .compress
        }
    }

    /// Stages already finished, for the processing view's checkmarks.
    public var completedStages: [PipelineStage] {
        let done: PipelineStage?
        switch status {
        case .recording, .recorded: done = nil
        case .compressed: done = .compress
        case .diarized: done = .diarize
        case .transcribed: done = .transcribe
        case .summarized: done = .summarize
        case .failed:
            guard let stage = failure?.stage,
                  let index = PipelineStage.allCases.firstIndex(of: stage), index > 0 else { return [] }
            done = PipelineStage.allCases[index - 1]
        }
        guard let done, let last = PipelineStage.allCases.firstIndex(of: done) else { return [] }
        return Array(PipelineStage.allCases[...last])
    }

    /// A failure the user has not dismissed: shows the menu bar warning.
    public var hasActiveFailure: Bool {
        status == .failed && failure?.dismissed != true
    }

    public var isProcessingPending: Bool {
        status != .recording && status != .summarized && status != .failed
    }

    public mutating func markCompleted(_ stage: PipelineStage, seconds: Double? = nil) {
        status = stage.completedStatus
        failure = nil
        if let seconds { processing.stageSeconds[stage.rawValue] = (seconds * 10).rounded() / 10 }
    }

    public mutating func markFailed(_ stage: PipelineStage, message: String, at date: Date = Date()) {
        status = .failed
        failure = MeetingFailure(stage: stage, message: message, time: date)
    }

    /// Rewinds so that `stage` runs again (Reprocess, Regenerate). Never moves forward.
    public mutating func rewind(to stage: PipelineStage) {
        guard status != .recording, let index = PipelineStage.allCases.firstIndex(of: stage) else { return }
        // `index` stages come before `stage`; only rewind if at least that many are done.
        guard index <= completedStages.count else { return }
        status = index == 0 ? .recorded : PipelineStage.allCases[index - 1].completedStatus
        failure = nil
    }

    /// Duration if known, else derived from the track stats or the clock.
    public var effectiveDuration: Double {
        if let durationSeconds { return durationSeconds }
        if let d = mic?.durationSeconds ?? system?.durationSeconds, d > 0 { return d }
        if let endTime { return endTime.timeIntervalSince(startTime) }
        return 0
    }
}

/// Which finished state the files still support after Stop.
/// Stop does not delete a transcript or summary that was fully written.
public enum MeetingRecovery {
    public static func restoredStatus(hasSummary: Bool, hasTranscript: Bool, hasDiarization: Bool, hasModelAudio: Bool) -> MeetingStatus? {
        if hasSummary, hasTranscript { return .summarized }
        if hasTranscript { return .transcribed }
        if hasDiarization { return .diarized }
        if hasModelAudio { return .compressed }
        return nil
    }
}
