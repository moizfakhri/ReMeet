import AVFoundation
import Foundation
import ReMeetKit

/// Turns one existing recording into the call track and the playback file.
/// There is no separate mic track: the whole file is what diarization and transcription read.
enum AudioImport {
    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// Writes `system-16k.m4a` and `audio.m4a`. Returns the duration in seconds.
    static func convert(_ source: URL, into folder: MeetingFolder) throws -> Double {
        let input: AVAudioFile
        do {
            input = try AVAudioFile(forReading: source)
        } catch {
            throw Failure(message: "ReMeet could not open that audio file.")
        }
        guard input.length > 0 else { throw Failure(message: "That audio file is empty.") }
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: input.processingFormat, to: format) else {
            throw Failure(message: "ReMeet could not read that audio file.")
        }
        let alac: [String: Any] = [AVFormatIDKey: kAudioFormatAppleLossless, AVSampleRateKey: 16_000,
                                   AVNumberOfChannelsKey: 1, AVEncoderBitDepthHintKey: 16]
        let aac: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000,
                                  AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000]
        let system = try AVAudioFile(forWriting: folder.file(.system16k), settings: alac,
                                     commonFormat: .pcmFormatFloat32, interleaved: false)
        let playback = try AVAudioFile(forWriting: folder.file(.audio), settings: aac,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
        let inCapacity = AVAudioFrameCount(max(input.processingFormat.sampleRate, 16_000))
        let inBuffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: inCapacity)!
        let outBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: inCapacity * 2)!
        while input.framePosition < input.length {
            let frames = min(inCapacity, AVAudioFrameCount(input.length - input.framePosition))
            try input.read(into: inBuffer, frameCount: frames)
            guard inBuffer.frameLength > 0 else { break }
            var supplied = false
            var convertError: NSError?
            let status = converter.convert(to: outBuffer, error: &convertError) { _, outStatus in
                if supplied {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                outStatus.pointee = .haveData
                return inBuffer
            }
            if let convertError { throw convertError }
            if status == .error { throw Failure(message: "ReMeet could not convert that audio file.") }
            if outBuffer.frameLength > 0 {
                try system.write(from: outBuffer)
                try playback.write(from: outBuffer)
            }
        }
        let seconds = Double(system.length) / 16_000
        guard seconds > 0.2 else {
            try? FileManager.default.removeItem(at: folder.url)
            throw Failure(message: "That audio file is too short to transcribe.")
        }
        return seconds
    }
}
