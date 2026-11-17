import Accelerate
import AVFoundation
import ReMeetKit

/// Writes one mono 48 kHz WAV whose sample 0 is the session's start host time.
///
/// Every chunk carries the host time of its first sample. The writer compares that with
/// how many frames it has written so far: if the source fell behind (device switch, tap
/// rebuild, dropped chunk) it pads with silence; if the source ran ahead (clock drift)
/// it trims. Both files therefore stay on the same host-time timeline.
///
/// Not thread safe: use only from the session's writer queue.
final class TrackWriter {
    static let outputRate: Double = 48_000
    /// Mismatch tolerated before correcting, in output frames (50 ms).
    private static let alignTolerance: Int64 = 2_400
    private static let reportedGapFrames: Int64 = 12_000

    private let startHostTime: UInt64
    private let outputFormat: AVAudioFormat
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var converterInputRate: Double = 0
    private var inputBuffer: AVAudioPCMBuffer?
    private let outputBuffer: AVAudioPCMBuffer
    private let silenceBuffer: AVAudioPCMBuffer
    private(set) var stats: TrackStats

    init(url: URL, startHostTime: UInt64) throws {
        self.startHostTime = startHostTime
        outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.outputRate,
                                     channels: 1, interleaved: false)!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.outputRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        file = try AVAudioFile(forWriting: url, settings: settings,
                               commonFormat: .pcmFormatFloat32, interleaved: false)
        // Worst case: an 8 kHz source chunk of 4096 frames becomes 24576 frames at 48 kHz.
        outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 32_768)!
        silenceBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4_800)!
        silenceBuffer.frameLength = silenceBuffer.frameCapacity
        memset(silenceBuffer.floatChannelData![0], 0, Int(silenceBuffer.frameCapacity) * MemoryLayout<Float>.size)
        stats = TrackStats(fileName: url.lastPathComponent)
    }

    /// Appends one chunk and returns its peak absolute sample value (for the level meter).
    @discardableResult
    func append(_ chunk: RMChunk) -> Float {
        guard file != nil, var samples = chunk.samples, chunk.frameCount > 0 else { return 0 }
        var frames = Int(chunk.frameCount)
        var hostTime = chunk.hostTime
        let rate = chunk.sampleRate

        if hostTime < startHostTime {
            let skip = Int((AVAudioTime.seconds(forHostTime: startHostTime - hostTime) * rate).rounded(.up))
            guard skip < frames else { return 0 }
            samples += skip
            frames -= skip
            hostTime = startHostTime
        }

        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(frames))

        if !stats.sourceSampleRates.contains(rate) { stats.sourceSampleRates.append(rate) }
        if rate != converterInputRate { configureConverter(inputRate: rate) }

        let expected = Int64((AVAudioTime.seconds(forHostTime: hostTime - startHostTime) * Self.outputRate).rounded())
        let offset = expected - stats.framesWritten
        var trimFrames = 0
        if offset > Self.alignTolerance {
            converter?.reset()
            writeSilence(frames: offset)
            stats.silenceInsertedSeconds += Double(offset) / Self.outputRate
            if offset >= Self.reportedGapFrames {
                stats.gaps.append(TrackGap(atSeconds: Double(expected - offset) / Self.outputRate,
                                           durationSeconds: Double(offset) / Self.outputRate))
            }
        } else if offset < -Self.alignTolerance {
            trimFrames = Int(-offset)
        }

        guard let converted = resample(samples, frames: frames) else { return peak }
        if trimFrames > 0 {
            let trimmed = min(trimFrames, Int(converted.frameLength))
            let data = converted.floatChannelData![0]
            let remaining = Int(converted.frameLength) - trimmed
            if remaining > 0 { memmove(data, data + trimmed, remaining * MemoryLayout<Float>.size) }
            converted.frameLength = AVAudioFrameCount(remaining)
            stats.driftTrimmedSeconds += Double(trimmed) / Self.outputRate
        }
        write(converted)
        return peak
    }

    func finish(droppedChunks: UInt64) -> TrackStats {
        file = nil  // AVAudioFile finalizes the WAV header when released.
        stats.droppedChunks = droppedChunks
        stats.durationSeconds = Double(stats.framesWritten) / Self.outputRate
        return stats
    }

    // MARK: - Private

    private func configureConverter(inputRate: Double) {
        converterInputRate = inputRate
        guard inputRate != Self.outputRate,
              let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputRate,
                                              channels: 1, interleaved: false) else {
            converter = nil
            inputBuffer = nil
            return
        }
        converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        converter?.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 4_096)
    }

    /// Returns the chunk at 48 kHz in `outputBuffer` (or nil if conversion failed).
    private func resample(_ samples: UnsafePointer<Float>, frames: Int) -> AVAudioPCMBuffer? {
        guard let converter, let inputBuffer else {
            let count = min(frames, Int(outputBuffer.frameCapacity))
            memcpy(outputBuffer.floatChannelData![0], samples, count * MemoryLayout<Float>.size)
            outputBuffer.frameLength = AVAudioFrameCount(count)
            return outputBuffer
        }
        let count = min(frames, Int(inputBuffer.frameCapacity))
        memcpy(inputBuffer.floatChannelData![0], samples, count * MemoryLayout<Float>.size)
        inputBuffer.frameLength = AVAudioFrameCount(count)

        outputBuffer.frameLength = 0
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return inputBuffer
        }
        if status == .error {
            NSLog("ReMeet: resample failed for %@: %@", stats.fileName, error?.localizedDescription ?? "unknown")
            return nil
        }
        return outputBuffer
    }

    private func writeSilence(frames: Int64) {
        var remaining = frames
        while remaining > 0 {
            let count = AVAudioFrameCount(min(remaining, Int64(silenceBuffer.frameCapacity)))
            silenceBuffer.frameLength = count
            write(silenceBuffer)
            remaining -= Int64(count)
        }
        silenceBuffer.frameLength = silenceBuffer.frameCapacity
    }

    private func write(_ buffer: AVAudioPCMBuffer) {
        guard let file, buffer.frameLength > 0 else { return }
        do {
            try file.write(from: buffer)
            stats.framesWritten += Int64(buffer.frameLength)
        } catch {
            writeFailures += 1
            lastWriteError = error.localizedDescription
            NSLog("ReMeet: write failed for %@: %@", stats.fileName, error.localizedDescription)
        }
    }

    /// Failed writes so far (disk full, volume gone). Read on the writer queue.
    private(set) var writeFailures = 0
    private(set) var lastWriteError: String?
}
