import AVFoundation
import Observation
import ReMeetKit

/// Plays one meeting: audio.m4a once compressed, otherwise mic.wav + system.wav mixed live
/// through a composition (so a meeting can be played before the pipeline gets to it).
@MainActor
@Observable
final class PlayerModel {
    static let speeds: [Float] = [1, 1.5, 2]

    private(set) var folder: MeetingFolder?
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var isAvailable = false
    /// Set only after a load finds nothing to play. Stays false while the next item
    /// opens, so the capsule does not dim for a beat on every meeting change.
    private(set) var audioMissing = false
    var speed: Float = 1 {
        didSet { if isPlaying { player.rate = speed } }
    }

    @ObservationIgnored nonisolated(unsafe) private let player = AVPlayer()
    @ObservationIgnored nonisolated(unsafe) private var timeObserver: Any?
    @ObservationIgnored nonisolated(unsafe) private var endObserver: NSObjectProtocol?

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    init() {
        player.automaticallyWaitsToMinimizeStalling = false
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = time.seconds.isFinite ? time.seconds : 0
                self.isPlaying = self.player.rate != 0
            }
        }
    }

    /// Loads the meeting's audio; keeps position when called again for the same meeting.
    func load(_ folder: MeetingFolder, knownDuration: Double) {
        guard folder != self.folder || !isAvailable else { return }
        pause()
        self.folder = folder
        currentTime = 0
        duration = knownDuration
        audioMissing = false
        isAvailable = false
        player.replaceCurrentItem(with: nil)
        Task { [weak self] in
            let item = await Self.makeItem(folder)
            guard let self, self.folder == folder else { return }
            self.install(item)
        }
    }

    private func install(_ item: AVPlayerItem?) {
        isAvailable = item != nil
        audioMissing = item == nil
        player.replaceCurrentItem(with: item)
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                             object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isPlaying = false }
        }
        if let item {
            Task { [weak self] in
                if let seconds = try? await item.asset.load(.duration).seconds, seconds.isFinite, seconds > 0 {
                    self?.duration = seconds
                }
            }
        }
    }

    /// Forget the current item (the files are about to change, e.g. after compression).
    func reloadAudio() {
        guard let folder else { return }
        let position = currentTime
        isAvailable = false
        load(folder, knownDuration: duration)
        seek(to: position)
    }

    /// Self-tests play silently.
    func setMuted(_ muted: Bool) { player.isMuted = muted }

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard isAvailable else { return }
        if duration > 0, currentTime >= duration - 0.1 { seek(to: 0) }
        player.rate = speed
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func seek(to seconds: Double) {
        let clamped = min(max(0, seconds), max(duration, 0))
        currentTime = clamped
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func skip(_ delta: Double) {
        seek(to: currentTime + delta)
    }

    /// Seek and start playing (transcript time click, summary "jump to").
    func play(from seconds: Double) {
        seek(to: seconds)
        play()
    }

    private static func makeItem(_ folder: MeetingFolder) async -> AVPlayerItem? {
        if folder.exists(.audio) { return AVPlayerItem(url: folder.file(.audio)) }
        let tracks = [MeetingFolder.File.micWAV, .systemWAV].filter(folder.exists)
        guard !tracks.isEmpty else { return nil }
        if tracks.count == 1 { return AVPlayerItem(url: folder.file(tracks[0])) }
        // Both WAVs start at the same host time, so laying them at zero keeps them aligned.
        let composition = AVMutableComposition()
        for file in tracks {
            let asset = AVURLAsset(url: folder.file(file))
            guard let source = try? await asset.loadTracks(withMediaType: .audio).first,
                  let length = try? await asset.load(.duration),
                  let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            try? track.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: source, at: .zero)
        }
        return AVPlayerItem(asset: composition)
    }
}
