import AVFoundation
import CoreAudio
import Foundation
import Observation
import ReMeetKit

/// Live mic and call levels + pre-meeting Sound Check without saving any meeting:
/// feeds two lock-free queues that are drained and discarded, follows live AirPods /
/// input-device switches while active, verifies System Audio permission via an external
/// chime process, and optionally records a 3-second temporary voice loopback check.
@MainActor
@Observable
final class LevelProbe: NSObject, AVAudioPlayerDelegate {
    enum ChimeState: Equatable {
        case idle
        case playing
        case verified
        case blocked
    }

    enum VoiceCheckState: Equatable {
        case idle
        case recording(secondsLeft: Int)
        case playing
        case failed(String)
    }

    private(set) var micLevel: Float = 0
    private(set) var systemLevel: Float = 0
    private(set) var isRunning = false
    private(set) var micError: String?
    private(set) var systemError: String?
    /// True once the call track delivered real (non-silent) audio, i.e. System Audio permission works.
    private(set) var heardSystemAudio = false
    /// True once the active microphone delivered speech-level signal (`> -48 dBFS`).
    private(set) var heardMicSpeech = false
    private(set) var peakMicDB: Float = -60

    private(set) var inputDevice: AudioDeviceInfo?
    private(set) var outputDevice: AudioDeviceInfo?
    private(set) var isBluetoothInput = false
    private(set) var isInputMuted = false

    private(set) var chimeState: ChimeState = .idle
    private(set) var voiceCheckState: VoiceCheckState = .idle

    @ObservationIgnored private let micQueue = ChunkQueue()
    @ObservationIgnored private let systemQueue = ChunkQueue()
    @ObservationIgnored private lazy var mic = MicCapture(queue: micQueue)
    @ObservationIgnored private lazy var system = SystemAudioCapture(queue: systemQueue)
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var deviceMonitor: DefaultDeviceMonitor?
    @ObservationIgnored private var restartWork: DispatchWorkItem?
    @ObservationIgnored private var chimeTask: Task<Void, Never>?
    @ObservationIgnored private var chimeProcess: Process?
    @ObservationIgnored private var voiceTask: Task<Void, Never>?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var tempVoiceURL: URL?

    @ObservationIgnored private var capturingVoiceSamples = false
    @ObservationIgnored private var capturedVoiceSamples: [Float] = []
    @ObservationIgnored private var capturedSampleRate: Double = 48_000
    @ObservationIgnored private var tickCounter = 0

    override init() {
        super.init()
        refreshDeviceSnapshot()
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        micError = nil
        systemError = nil
        heardMicSpeech = false
        peakMicDB = -60
        tickCounter = 0

        mic.onConfigurationChange = { [weak self] in
            MainActor.assumeIsolated { self?.scheduleDeviceRestart(delay: 0.35) }
        }
        startMicStream()
        do {
            let info = try system.start()
            outputDevice = info.outputDevice ?? CoreAudioUtil.defaultOutputDevice().map(CoreAudioUtil.deviceInfo)
        } catch {
            systemError = "\(error)"
        }

        let monitor = DefaultDeviceMonitor()
        monitor.onChange = { [weak self] kind in
            MainActor.assumeIsolated {
                guard let self, self.isRunning else { return }
                switch kind {
                case .input:
                    let bt = CoreAudioUtil.defaultInputDevice().map(CoreAudioUtil.isBluetooth) ?? false
                    self.scheduleDeviceRestart(delay: bt ? 0.45 : 0.3)
                case .output:
                    self.outputDevice = CoreAudioUtil.defaultOutputDevice().map(CoreAudioUtil.deviceInfo)
                    try? _ = self.system.rebuild()
                }
            }
        }
        deviceMonitor = monitor

        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.drain() }
        }
    }

    func stop() {
        restartWork?.cancel()
        restartWork = nil
        chimeTask?.cancel()
        chimeTask = nil
        if let p = chimeProcess, p.isRunning { p.terminate() }
        chimeProcess = nil
        voiceTask?.cancel()
        voiceTask = nil
        stopPlaybackAndCleanTemp()

        deviceMonitor = nil
        timer?.invalidate()
        timer = nil
        mic.onConfigurationChange = nil
        mic.stop()
        system.stop()
        isRunning = false
        capturingVoiceSamples = false
        capturedVoiceSamples.removeAll(keepingCapacity: false)
        micLevel = 0
        systemLevel = 0
        if chimeState == .playing { chimeState = .idle }
        voiceCheckState = .idle
        refreshDeviceSnapshot()
    }

    /// Plays a gentle system chime in a separate child process (`/usr/bin/afplay`) so it passes
    /// through `SystemAudioCapture`'s process tap and proves end-to-end call audio permission.
    func runCallAudioTest() {
        if !isRunning { start() }
        chimeTask?.cancel()
        if let p = chimeProcess, p.isRunning { p.terminate() }
        heardSystemAudio = false
        chimeState = .playing

        chimeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let chimeURL = Self.resolveChimeURL()
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            proc.arguments = ["-v", "0.45", chimeURL.path]
            do {
                try proc.run()
                self.chimeProcess = proc
            } catch {
                self.chimeState = .blocked
                return
            }

            for _ in 0..<28 {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled else { return }
                if self.heardSystemAudio {
                    self.chimeState = .verified
                    return
                }
            }
            self.chimeState = self.heardSystemAudio ? .verified : .blocked
        }
    }

    /// Records 3 seconds from the active microphone (e.g. AirPods or MacBook Mic) and plays it
    /// right back so the user can hear their actual call clarity before joining a meeting.
    func runVoiceLoopbackTest(seconds: Int = 3) {
        if case .recording = voiceCheckState { return }
        if case .playing = voiceCheckState {
            stopPlaybackAndCleanTemp()
            voiceCheckState = .idle
            return
        }
        if !isRunning { start() }
        guard micError == nil else {
            voiceCheckState = .failed("Microphone unavailable")
            return
        }

        voiceTask?.cancel()
        stopPlaybackAndCleanTemp()
        capturedVoiceSamples.removeAll(keepingCapacity: true)
        capturedVoiceSamples.reserveCapacity(Int(capturedSampleRate) * seconds)
        capturingVoiceSamples = true
        voiceCheckState = .recording(secondsLeft: seconds)

        voiceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for remaining in stride(from: seconds, to: 0, by: -1) {
                self.voiceCheckState = .recording(secondsLeft: remaining)
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
            }
            self.capturingVoiceSamples = false
            let samples = self.capturedVoiceSamples
            self.capturedVoiceSamples.removeAll(keepingCapacity: false)

            guard samples.count > 2_400 else {
                self.voiceCheckState = .failed("No audio received from mic")
                return
            }
            do {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("remeet-soundcheck-\(UUID().uuidString).wav")
                try Self.writeMonoWAV(samples: samples, sampleRate: self.capturedSampleRate, to: url)
                self.tempVoiceURL = url
                let audioPlayer = try AVAudioPlayer(contentsOf: url)
                audioPlayer.delegate = self
                audioPlayer.volume = 1.0
                audioPlayer.prepareToPlay()
                audioPlayer.play()
                self.player = audioPlayer
                self.voiceCheckState = .playing
            } catch {
                self.voiceCheckState = .failed(error.localizedDescription)
            }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.stopPlaybackAndCleanTemp()
            self.voiceCheckState = .idle
        }
    }

    /// Deterministic preview state for UI snapshot tests without opening hardware audio.
    func debugSetPreview() {
        isRunning = true
        inputDevice = AudioDeviceInfo(id: 72, uid: "airpods-pro", name: "AirPods Pro", nominalSampleRate: 24_000)
        outputDevice = AudioDeviceInfo(id: 73, uid: "airpods-pro-out", name: "AirPods Pro", nominalSampleRate: 24_000)
        isBluetoothInput = true
        isInputMuted = false
        micLevel = 0.72
        systemLevel = 0.58
        heardMicSpeech = true
        heardSystemAudio = true
        peakMicDB = -14.2
        chimeState = .verified
        voiceCheckState = .idle
    }

    // MARK: - Private

    private func refreshDeviceSnapshot() {
        let preferred = CoreAudioUtil.activeMeetingAppInputDevice()?.device
        let fallback = CoreAudioUtil.defaultInputDevice().map(CoreAudioUtil.deviceInfo)
        inputDevice = preferred ?? fallback
        outputDevice = CoreAudioUtil.defaultOutputDevice().map(CoreAudioUtil.deviceInfo)
        if let id = inputDevice?.id {
            isBluetoothInput = CoreAudioUtil.isBluetooth(id)
            isInputMuted = CoreAudioUtil.isInputMuted(id)
        } else {
            isBluetoothInput = false
            isInputMuted = false
        }
    }

    private func startMicStream() {
        do {
            let preferredID = CoreAudioUtil.activeMeetingAppInputDevice()?.device.id
            let info = try mic.start(preferredDeviceID: preferredID)
            micError = nil
            capturedSampleRate = info.sampleRate > 0 ? info.sampleRate : 48_000
            inputDevice = info.device ?? CoreAudioUtil.defaultInputDevice().map(CoreAudioUtil.deviceInfo)
            if let id = inputDevice?.id {
                isBluetoothInput = CoreAudioUtil.isBluetooth(id)
                isInputMuted = CoreAudioUtil.isInputMuted(id)
            }
        } catch {
            micError = error.localizedDescription
            refreshDeviceSnapshot()
        }
    }

    private func scheduleDeviceRestart(delay: TimeInterval) {
        restartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning else { return }
            self.heardMicSpeech = false
            self.peakMicDB = -60
            self.startMicStream()
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func drain() {
        var micPeak: Float = 0
        var systemPeak: Float = 0
        micQueue.drain { chunk in
            micPeak = max(micPeak, Self.peak(chunk))
            if capturingVoiceSamples, let ptr = chunk.samples, chunk.frameCount > 0 {
                if chunk.sampleRate > 0 { capturedSampleRate = chunk.sampleRate }
                capturedVoiceSamples.append(contentsOf: UnsafeBufferPointer(start: ptr, count: Int(chunk.frameCount)))
            }
        }
        systemQueue.drain { chunk in
            systemPeak = max(systemPeak, Self.peak(chunk))
        }

        if systemPeak > 0.0005 {
            heardSystemAudio = true
            if chimeState == .playing { chimeState = .verified }
        }
        if micPeak > 0.004 {
            heardMicSpeech = true
        }
        if micPeak > 0.0001 {
            let db = max(-60, min(0, 20 * log10(micPeak)))
            peakMicDB = max(peakMicDB * 0.985, db)
        }
        micLevel = max(Self.meter(micPeak), micLevel * 0.8)
        systemLevel = max(Self.meter(systemPeak), systemLevel * 0.8)

        tickCounter += 1
        if tickCounter % 20 == 0, let id = inputDevice?.id {
            isInputMuted = CoreAudioUtil.isInputMuted(id)
            isBluetoothInput = CoreAudioUtil.isBluetooth(id)
        }
    }

    private func stopPlaybackAndCleanTemp() {
        player?.stop()
        player = nil
        if let url = tempVoiceURL {
            try? FileManager.default.removeItem(at: url)
            tempVoiceURL = nil
        }
    }

    private static func resolveChimeURL() -> URL {
        let glass = URL(fileURLWithPath: "/System/Library/Sounds/Glass.aiff")
        if FileManager.default.fileExists(atPath: glass.path) { return glass }
        let tink = URL(fileURLWithPath: "/System/Library/Sounds/Tink.aiff")
        if FileManager.default.fileExists(atPath: tink.path) { return tink }

        // Fallback synthetic 2-tone chime WAV if macOS system sound files are absent.
        let fallback = FileManager.default.temporaryDirectory.appendingPathComponent("remeet-chime.wav")
        if !FileManager.default.fileExists(atPath: fallback.path) {
            let rate = 48_000.0
            let frames = Int(rate * 0.35)
            let samples = (0..<frames).map { i -> Float in
                let t = Double(i) / rate
                let freq = t < 0.16 ? 659.25 : 880.0
                let env = sin(.pi * min(1.0, t / 0.35))
                return Float(sin(2 * .pi * freq * t) * env * 0.25)
            }
            try? writeMonoWAV(samples: samples, sampleRate: rate, to: fallback)
        }
        return fallback
    }

    private static func writeMonoWAV(samples: [Float], sampleRate: Double, to url: URL) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw NSError(domain: "ReMeet", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not allocate audio buffer"])
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { ptr in
            if let base = ptr.baseAddress {
                buffer.floatChannelData![0].update(from: base, count: samples.count)
            }
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }

    private nonisolated static func peak(_ chunk: RMChunk) -> Float {
        guard let samples = chunk.samples else { return 0 }
        var peak: Float = 0
        for i in 0..<Int(chunk.frameCount) { peak = max(peak, abs(samples[i])) }
        return peak
    }

    private static func meter(_ peak: Float) -> Float {
        guard peak > 0 else { return 0 }
        return min(max((20 * log10(peak) + 60) / 60, 0), 1)
    }
}
