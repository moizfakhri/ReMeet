import AVFoundation
import ReMeetKit

/// Captures the current system default input device with AVAudioEngine.
///
/// ReMeet never selects a device itself: forcing AirPods (or any headset) to become the
/// input would switch them into call mode. On a device or configuration change the
/// session tears this down and calls `start()` again, which picks up the new default.
///
/// Capture only: the tap sits on `inputNode` and the main mixer is muted so mic audio
/// cannot route to the speakers (no monitoring / feedback), even if a future graph
/// change reconnects input to the mixer.
final class MicCapture {
    struct StartInfo {
        var device: AudioDeviceInfo?
        var sampleRate: Double
        var channels: UInt32
    }

    /// Called on the main queue when the engine reports a configuration change.
    var onConfigurationChange: (() -> Void)?

    private let queue: ChunkQueue
    private var engine: AVAudioEngine?
    private var configObserver: NSObjectProtocol?

    init(queue: ChunkQueue) {
        self.queue = queue
    }

    func start() throws -> StartInfo {
        stop()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "ReMeet", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No usable input device (format \(format))"])
        }
        guard format.commonFormat == .pcmFormatFloat32 else {
            throw NSError(domain: "ReMeet", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Unexpected mic sample format \(format)"])
        }

        // Silence any path from the engine to the default output (clicks of opening the
        // device still happen; audible mic monitoring must not).
        engine.mainMixerNode.outputVolume = 0

        let raw = queue.raw
        let interleaved = format.isInterleaved
        let channels = format.channelCount
        let rate = format.sampleRate
        input.installTap(onBus: 0, bufferSize: 4_800, format: format) { buffer, time in
            let hostTime = time.isHostTimeValid ? time.hostTime : mach_absolute_time()
            RMChunkQueuePush(raw, buffer.audioBufferList, interleaved, channels,
                             buffer.frameLength, hostTime, rate)
        }

        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.onConfigurationChange?()
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
            configObserver = nil
            throw error
        }
        self.engine = engine

        let device = CoreAudioUtil.defaultInputDevice().map(CoreAudioUtil.deviceInfo)
        return StartInfo(device: device, sampleRate: rate, channels: channels)
    }

    func stop() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }
}
