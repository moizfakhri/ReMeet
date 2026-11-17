import Foundation

// Value types written by the Phase 0 capture core (RecordingSession, TrackWriter,
// CoreAudioUtil). They live here so meta.json has one definition shared by the
// recorder, the pipeline and the tests. Field names are unchanged from Phase 0.

public struct AudioDeviceInfo: Codable, Equatable, Sendable {
    public var id: UInt32
    public var uid: String
    public var name: String
    public var nominalSampleRate: Double

    public init(id: UInt32, uid: String, name: String, nominalSampleRate: Double) {
        self.id = id
        self.uid = uid
        self.name = name
        self.nominalSampleRate = nominalSampleRate
    }
}

public struct SessionEvent: Codable, Equatable, Sendable {
    public var time: Date
    /// Seconds since the first sample of both files.
    public var offsetSeconds: Double
    public var type: String
    public var detail: String

    public init(time: Date, offsetSeconds: Double, type: String, detail: String) {
        self.time = time
        self.offsetSeconds = offsetSeconds
        self.type = type
        self.detail = detail
    }
}

public struct TrackGap: Codable, Equatable, Sendable {
    public var atSeconds: Double
    public var durationSeconds: Double

    public init(atSeconds: Double, durationSeconds: Double) {
        self.atSeconds = atSeconds
        self.durationSeconds = durationSeconds
    }
}

public struct TrackStats: Codable, Equatable, Sendable {
    public var fileName: String
    public var fileFormat = "WAV, 48000 Hz, mono, 16-bit PCM"
    public var framesWritten: Int64 = 0
    public var durationSeconds: Double = 0
    public var sourceSampleRates: [Double] = []
    public var silenceInsertedSeconds: Double = 0
    public var driftTrimmedSeconds: Double = 0
    public var droppedChunks: UInt64 = 0
    /// Gaps of 0.25 s or more that were filled with silence (device switches, tap rebuilds).
    public var gaps: [TrackGap] = []

    public init(fileName: String) {
        self.fileName = fileName
    }
}
