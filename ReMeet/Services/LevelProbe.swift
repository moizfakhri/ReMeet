import AVFoundation
import Foundation
import Observation

/// Live mic and call levels without recording anything: the Phase 0 capture classes feed
/// two queues that are drained and thrown away. Used by first launch and Settings to show
/// that both permissions work. Starting it is what makes macOS ask for them.
@MainActor
@Observable
final class LevelProbe {
    private(set) var micLevel: Float = 0
    private(set) var systemLevel: Float = 0
    private(set) var isRunning = false
    private(set) var micError: String?
    private(set) var systemError: String?
    /// True once the call track delivered real (non-silent) audio, i.e. the permission works.
    private(set) var heardSystemAudio = false

    @ObservationIgnored private let micQueue = ChunkQueue()
    @ObservationIgnored private let systemQueue = ChunkQueue()
    @ObservationIgnored private lazy var mic = MicCapture(queue: micQueue)
    @ObservationIgnored private lazy var system = SystemAudioCapture(queue: systemQueue)
    @ObservationIgnored private var timer: Timer?

    func start() {
        guard !isRunning else { return }
        isRunning = true
        micError = nil
        systemError = nil
        do { _ = try mic.start() } catch { micError = error.localizedDescription }
        do { _ = try system.start() } catch { systemError = "\(error)" }
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.drain() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        mic.stop()
        system.stop()
        isRunning = false
        micLevel = 0
        systemLevel = 0
    }

    private func drain() {
        var micPeak: Float = 0
        var systemPeak: Float = 0
        micQueue.drain { chunk in micPeak = max(micPeak, Self.peak(chunk)) }
        systemQueue.drain { chunk in systemPeak = max(systemPeak, Self.peak(chunk)) }
        if systemPeak > 0.0005 { heardSystemAudio = true }
        micLevel = max(Self.meter(micPeak), micLevel * 0.8)
        systemLevel = max(Self.meter(systemPeak), systemLevel * 0.8)
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
