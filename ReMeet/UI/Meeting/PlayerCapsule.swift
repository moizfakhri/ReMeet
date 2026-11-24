import ReMeetKit
import SwiftUI

/// Floating audio player capsule: play/pause, ±15 s, scrubber with note ticks, speed.
/// When audio is no longer on disk, displays a clean compact status pill instead of
/// overlapping text on top of disabled playback controls.
struct PlayerCapsule: View {
    let player: PlayerModel
    let notes: [MeetingNote]
    @State private var scrubbing: Double?

    private var audioUnavailable: Bool {
        !player.isAvailable && player.folder.map { !Self.hasAudio($0) } == true
    }

    var body: some View {
        Group {
            if audioUnavailable {
                HStack(spacing: 8) {
                    Image(systemName: "waveform.slash")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.fg3)
                    Text("Audio unavailable")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.fg2)
                        .lineLimit(1)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .help("Audio file was removed by Keep audio setting or never recorded")
            } else {
                HStack(spacing: 8) {
                    Button { player.skip(-15) } label: {
                        Image(systemName: "gobackward.15")
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .help("Back 15 seconds")
                    .accessibilityLabel("Back 15 seconds")

                    Button { player.togglePlay() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(Theme.accentFill, in: Circle())
                    }
                    .help(player.isPlaying ? "Pause" : "Play")
                    .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

                    Button { player.skip(15) } label: {
                        Image(systemName: "goforward.15")
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .help("Forward 15 seconds")
                    .accessibilityLabel("Forward 15 seconds")

                    Text(TimeFormat.clock(scrubbing ?? player.currentTime))
                        .font(Fonts.monoSmall)
                        .foregroundStyle(Theme.fg2)
                        .frame(minWidth: 36, alignment: .trailing)

                    Scrubber(value: scrubbing ?? player.currentTime, duration: player.duration, ticks: notes.map(\.t)) { value, ended in
                        if ended {
                            player.seek(to: value)
                            scrubbing = nil
                        } else {
                            scrubbing = value
                        }
                    }
                    .frame(minWidth: 60, maxWidth: .infinity)
                    .frame(height: 22)

                    Text(TimeFormat.clock(player.duration))
                        .font(Fonts.monoSmall)
                        .foregroundStyle(Theme.fg2)
                        .frame(minWidth: 36, alignment: .leading)

                    Button {
                        let speeds = PlayerModel.speeds
                        let index = speeds.firstIndex(of: player.speed) ?? 0
                        player.speed = speeds[(index + 1) % speeds.count]
                    } label: {
                        Text(speedLabel)
                            .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Theme.fg2)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Theme.mark, in: Capsule())
                    }
                    .help("Playback speed")
                    .accessibilityLabel("Playback speed \(speedLabel)")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.fg)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: 560)
                .disabled(!player.isAvailable)
                .opacity(player.audioMissing ? 0.6 : 1)
                .animation(nil, value: player.audioMissing)
            }
        }
        .background(Theme.bg.opacity(0.94), in: Capsule())
        .glassEffect(.regular, in: Capsule())
        .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 5)
    }

    private static func hasAudio(_ folder: MeetingFolder) -> Bool {
        AudioRetention.audioFiles.contains(where: folder.exists)
    }

    private var speedLabel: String {
        player.speed == 1 ? "1×" : player.speed == 1.5 ? "1.5×" : "2×"
    }
}

/// Track with a fill, a knob and small accent ticks where notes were taken.
private struct Scrubber: View {
    let value: Double
    let duration: Double
    let ticks: [Double]
    let onChange: (Double, Bool) -> Void

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let fraction = duration > 0 ? min(max(value / duration, 0), 1) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.line).frame(height: 4)
                Capsule().fill(Theme.accent).frame(width: width * fraction, height: 4)
                ForEach(Array(ticks.enumerated()), id: \.offset) { _, t in
                    if duration > 0 {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Theme.accent.opacity(0.8))
                            .frame(width: 2, height: 10)
                            .offset(x: width * min(t / duration, 1) - 1)
                    }
                }
                Circle()
                    .fill(Theme.fg)
                    .frame(width: 11, height: 11)
                    .offset(x: width * fraction - 5.5)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { onChange(seconds(at: $0.location.x, width: width), false) }
                .onEnded { onChange(seconds(at: $0.location.x, width: width), true) })
        }
    }

    private func seconds(at x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return Double(min(max(x / width, 0), 1)) * duration
    }
}
