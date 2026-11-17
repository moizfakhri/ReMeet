import AVFoundation
import ReMeetKit

/// Compress stage: mic.wav + system.wav (48 kHz) become
/// - mic-16k.m4a, system-16k.m4a: lossless ALAC at 16 kHz, what diarization and
///   transcription read (the models run at 16 kHz anyway, so nothing is lost for them);
/// - audio.m4a: AAC mono 16 kHz mix of both, for playback.
/// The WAVs are deleted only after all three outputs reopen with the expected duration.
enum AudioCompressor {
    static let rate: Double = 16_000
    private static let chunkFrames: AVAudioFrameCount = 48_000

    enum CompressError: LocalizedError {
        case verifyFailed(String)
        case converter

        var errorDescription: String? {
            switch self {
            case .verifyFailed(let detail): "The compressed audio did not check out (\(detail)); the WAV files were kept."
            case .converter: "Could not set up the audio converter."
            }
        }
    }

    static func compress(_ folder: MeetingFolder, progress: @Sendable (Double) -> Void) throws {
        // Resumed after the WAVs were already removed: nothing left to do.
        if !folder.exists(.micWAV), !folder.exists(.systemWAV) { return }

        let mic = try openIfPresent(folder.file(.micWAV))
        let system = try openIfPresent(folder.file(.systemWAV))
        guard mic != nil || system != nil else {
            // Nothing was captured (e.g. ⌥⌘R pressed twice). Not a failure: the later stages
            // see no tracks and the meeting completes as "No speech was detected" (audit M5).
            try? FileManager.default.removeItem(at: folder.file(.micWAV))
            try? FileManager.default.removeItem(at: folder.file(.systemWAV))
            progress(1)
            return
        }
        let totalFrames = max(mic?.length ?? 0, system?.length ?? 0)
        let sourceRate = mic?.processingFormat.sampleRate ?? system!.processingFormat.sampleRate
        let expectedSeconds = Double(totalFrames) / sourceRate

        let partial = { (file: MeetingFolder.File) in
            folder.url.appendingPathComponent(file.rawValue + ".partial.m4a")
        }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let alac: [String: Any] = [AVFormatIDKey: kAudioFormatAppleLossless, AVSampleRateKey: rate,
                                   AVNumberOfChannelsKey: 1, AVEncoderBitDepthHintKey: 16]
        let aac: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate,
                                  AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000]

        do {
            var micOut = mic != nil ? try AVAudioFile(forWriting: partial(.mic16k), settings: alac,
                                                      commonFormat: .pcmFormatFloat32, interleaved: false) : nil
            var systemOut = system != nil ? try AVAudioFile(forWriting: partial(.system16k), settings: alac,
                                                            commonFormat: .pcmFormatFloat32, interleaved: false) : nil
            var mixOut: AVAudioFile? = try AVAudioFile(forWriting: partial(.audio), settings: aac,
                                                       commonFormat: .pcmFormatFloat32, interleaved: false)

            let micReader = try mic.map { try Downsampler(file: $0, to: format) }
            let systemReader = try system.map { try Downsampler(file: $0, to: format) }
            let mixBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames)!
            var read: AVAudioFramePosition = 0

            while true {
                try Task.checkCancellation()
                let a = try micReader?.next(chunkFrames)
                let b = try systemReader?.next(chunkFrames)
                let count = max(a?.frameLength ?? 0, b?.frameLength ?? 0)
                if count == 0 { break }
                if let a, a.frameLength > 0 { try micOut?.write(from: a) }
                if let b, b.frameLength > 0 { try systemOut?.write(from: b) }

                mixBuffer.frameLength = count
                let out = UnsafeMutableBufferPointer(start: mixBuffer.floatChannelData![0], count: Int(count))
                let empty = UnsafeBufferPointer<Float>(start: nil, count: 0)
                let pa = a.map { UnsafeBufferPointer(start: $0.floatChannelData![0], count: Int($0.frameLength)) } ?? empty
                let pb = b.map { UnsafeBufferPointer(start: $0.floatChannelData![0], count: Int($0.frameLength)) } ?? empty
                AudioMix.mix(pa, pb, into: out)
                try mixOut?.write(from: mixBuffer)

                read += AVAudioFramePosition(Double(count) * sourceRate / rate)
                progress(min(Double(read) / Double(max(totalFrames, 1)), 1) * 0.95)
            }
            // Releasing the files finalizes them.
            micOut = nil
            systemOut = nil
            mixOut = nil
        } catch {
            for file in [MeetingFolder.File.mic16k, .system16k, .audio] { try? FileManager.default.removeItem(at: partial(file)) }
            throw error
        }

        // Verify every output before anything is deleted.
        var produced: [MeetingFolder.File] = [.audio]
        if mic != nil { produced.append(.mic16k) }
        if system != nil { produced.append(.system16k) }
        for file in produced {
            let url = partial(file)
            let check = try AVAudioFile(forReading: url)
            let seconds = Double(check.length) / check.fileFormat.sampleRate
            let source = file == .mic16k ? Double(mic!.length) / sourceRate
                : file == .system16k ? Double(system!.length) / sourceRate : expectedSeconds
            guard abs(seconds - source) < 0.25 else {
                throw CompressError.verifyFailed("\(file.rawValue) is \(String(format: "%.2f", seconds)) s, expected \(String(format: "%.2f", source)) s")
            }
        }
        for file in produced {
            let destination = folder.file(file)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: partial(file), to: destination)
        }
        try? FileManager.default.removeItem(at: folder.file(.micWAV))
        try? FileManager.default.removeItem(at: folder.file(.systemWAV))
        progress(1)
    }

    private static func openIfPresent(_ url: URL) throws -> AVAudioFile? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let file = try AVAudioFile(forReading: url)
        return file.length > 0 ? file : nil
    }
}

/// Reads a file in chunks and resamples to the target format, flushing at the end.
final class Downsampler {
    private let file: AVAudioFile
    private let converter: AVAudioConverter
    private let input: AVAudioPCMBuffer
    private var output: AVAudioPCMBuffer
    private let format: AVAudioFormat
    private var finished = false

    init(file: AVAudioFile, to format: AVAudioFormat) throws {
        self.file = file
        self.format = format
        guard let converter = AVAudioConverter(from: file.processingFormat, to: format) else {
            throw AudioCompressor.CompressError.converter
        }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        self.converter = converter
        input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48_000)!
        output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
    }

    /// Up to `frames` output frames; an empty buffer once the file is done.
    func next(_ frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        if output.frameCapacity < frames {
            output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        }
        output.frameLength = 0
        guard !finished else { return output }
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { [self] needed, inputStatus in
            if file.framePosition >= file.length {
                inputStatus.pointee = .endOfStream
                return nil
            }
            do {
                try file.read(into: input, frameCount: min(needed, input.frameCapacity))
            } catch {
                inputStatus.pointee = .endOfStream
                return nil
            }
            inputStatus.pointee = input.frameLength > 0 ? .haveData : .endOfStream
            return input
        }
        if status == .error { throw error ?? AudioCompressor.CompressError.converter }
        if status == .endOfStream { finished = true }
        return output
    }
}
