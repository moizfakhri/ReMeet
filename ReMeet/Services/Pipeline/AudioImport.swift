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

    /// Resolves the audio file's original creation date:
    /// 1. Embedded container creation date (e.g. Voice Memos / QuickTime `.m4a` metadata),
    ///    which survives AirDrop and cloud copies.
    /// 2. Filesystem creation date (or content modification date if earlier, e.g. copied files
    ///    whose APFS birth time was reset on transfer).
    /// 3. Current date as a last resort.
    static func creationDate(of source: URL) async -> Date {
        let asset = AVURLAsset(url: source)
        if let item = try? await asset.load(.creationDate),
           let embedded = try? await item.load(.dateValue),
           isReasonable(embedded) {
            return embedded
        }
        let values = try? source.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        let created = values?.creationDate.flatMap { isReasonable($0) ? $0 : nil }
        let modified = values?.contentModificationDate.flatMap { isReasonable($0) ? $0 : nil }
        if let created, let modified {
            return min(created, modified)
        }
        return created ?? modified ?? Date()
    }

    private static func isReasonable(_ date: Date) -> Bool {
        // Guard against bogus epoch-0 / 1904 QuickTime placeholder dates or far-future clocks.
        let earliest = Date(timeIntervalSince1970: 946_684_800) // 2000-01-01
        let latest = Date().addingTimeInterval(24 * 3600)
        return date >= earliest && date <= latest
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
