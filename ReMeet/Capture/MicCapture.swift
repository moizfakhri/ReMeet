import AudioToolbox
import AVFoundation
import CoreAudio
import ReMeetKit

/// Captures the active microphone with AVAudioEngine.
///
/// ReMeet never forces an idle Bluetooth headset into call mode on its own: by default it
/// opens macOS's system default input. However, when a meeting app (Zoom, Meet, Teams) is
/// ALREADY actively capturing from another input device (e.g. AirPods selected inside Zoom's
/// mic menu while macOS Default Input stayed on MacBook Mic), `preferredDeviceID` lets ReMeet
/// bind to that already-active input device so the user's voice is never missed.
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

    func start(preferredDeviceID: AudioDeviceID? = nil) throws -> StartInfo {
        if let preferredDeviceID,
           preferredDeviceID != CoreAudioUtil.defaultInputDevice(),
           let info = try? startEngine(bindingTo: preferredDeviceID) {
            return info
        }
        return try startEngine(bindingTo: nil)
    }

    private func startEngine(bindingTo explicitDeviceID: AudioDeviceID?) throws -> StartInfo {
        stop()
        let engine = AVAudioEngine()
        let input = engine.inputNode

        if var deviceID = explicitDeviceID, let audioUnit = input.audioUnit {
            let status = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &deviceID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            if status != noErr {
                throw CoreAudioError(operation: "Bind input AudioUnit to call mic", status: status)
            }
        }

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "ReMeet", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No usable input device (format \(format))"])
        }
        guard format.commonFormat == .pcmFormatFloat32 else {
            throw NSError(domain: "ReMeet", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Unexpected mic sample format \(format)"])
        }

        // Silence any path from the engine to the default output so audible mic monitoring cannot occur.
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

        let resolvedID = explicitDeviceID ?? CoreAudioUtil.defaultInputDevice()
        var device = resolvedID.map(CoreAudioUtil.deviceInfo)
        if device != nil, rate > 0 {
            device?.nominalSampleRate = rate
        }
        return StartInfo(device: device, sampleRate: rate, channels: channels)
    }

    var isRunning: Bool {
        engine?.isRunning == true
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
