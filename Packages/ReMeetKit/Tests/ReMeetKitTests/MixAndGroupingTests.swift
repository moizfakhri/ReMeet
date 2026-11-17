import Foundation
import Testing
@testable import ReMeetKit

struct AudioMixTests {
    @Test func quietSignalsAddExactly() {
        let out = AudioMix.mix([0.1, -0.2, 0.3], [0.2, 0.1, 0])
        #expect(zip(out, [0.3, -0.1, 0.3]).allSatisfy { abs($0 - Float($1)) < 1e-6 })
    }

    @Test func loudOverlapNeverClips() {
        let out = AudioMix.mix([0.9, -0.95, 1.0, 0.5], [0.9, -0.95, 1.0, 0.45])
        #expect(out.allSatisfy { abs($0) <= 1.0 })  // never beyond full scale
        #expect(out[0] > 0.9 && out[1] < -0.9)  // still loud, just limited
        #expect(abs(out[3] - 0.95) < 0.05)       // just over the ceiling: barely touched
        // Monotonic: a louder input is never quieter after limiting.
        let ramp = AudioMix.mix((0..<200).map { Float($0) / 100 }, [Float](repeating: 0, count: 200))
        #expect(zip(ramp, ramp.dropFirst()).allSatisfy { $0 <= $1 })
    }

    @Test func unequalLengthsPadWithSilence() {
        let out = AudioMix.mix([0.1, 0.1, 0.1], [0.2])
        #expect(out.count == 3)
        #expect(abs(out[0] - 0.3) < 1e-6 && abs(out[2] - 0.1) < 1e-6)
    }
}

struct MeetingGroupingTests {
    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }

    @Test func groups() {
        let cal = calendar
        // Monday 2 Nov 2026, 09:00 New York.
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 9))!
        func at(_ day: Int, _ hour: Int, month: Int = 11) -> Date {
            cal.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
        }
        #expect(MeetingGroup.group(for: at(2, 0), now: now, calendar: cal) == .today)
        #expect(MeetingGroup.group(for: at(1, 23), now: now, calendar: cal) == .yesterday)
        #expect(MeetingGroup.group(for: at(1, 0), now: now, calendar: cal) == .yesterday)
        #expect(MeetingGroup.group(for: at(29, 15, month: 10), now: now, calendar: cal) == .thisWeek)
        #expect(MeetingGroup.group(for: at(26, 10, month: 10), now: now, calendar: cal) == .thisWeek)
        #expect(MeetingGroup.group(for: at(25, 10, month: 10), now: now, calendar: cal) == .earlier)

        let dates = [at(2, 8), at(1, 10), at(30, 9, month: 10), at(1, 9, month: 9)]
        let grouped = MeetingGroup.grouped(dates, date: { $0 }, now: now, calendar: cal)
        #expect(grouped.map(\.0) == [.today, .yesterday, .thisWeek, .earlier])
        #expect(MeetingGroup.grouped([at(2, 8)], date: { $0 }, now: now, calendar: cal).count == 1)
    }
}

struct EnergySegmenterTests {
    func tone(_ seconds: Double, amp: Float, rate: Double = 16_000) -> [Float] {
        (0..<Int(seconds * rate)).map { amp * Float(sin(2 * Double.pi * 300 * Double($0) / rate)) }
    }
    func silence(_ seconds: Double, rate: Double = 16_000) -> [Float] { [Float](repeating: 0, count: Int(seconds * rate)) }

    @Test func findsSoundAndMergesShortGaps() {
        let audio = silence(1) + tone(2, amp: 0.2) + silence(0.5) + tone(1, amp: 0.2) + silence(3) + tone(0.1, amp: 0.2) + silence(1)
        let segs = EnergySegmenter.segments(audio, rate: 16_000)
        #expect(segs.count == 1)                                   // 0.5 s gap merged, 0.1 s blip dropped
        #expect(abs(segs[0].start - 1.0) < 0.05 && abs(segs[0].end - 4.5) < 0.05)
    }

    @Test func silenceAndQuietNoiseGiveNothing() {
        #expect(EnergySegmenter.segments(silence(5), rate: 16_000).isEmpty)
        #expect(EnergySegmenter.segments(tone(5, amp: 0.001), rate: 16_000).isEmpty)  // about -63 dBFS
        #expect(EnergySegmenter.peakRMSdB(silence(1), rate: 16_000) == -160)
        #expect(EnergySegmenter.peakRMSdB(tone(1, amp: 0.2), rate: 16_000) > -20)
    }
}

struct SpeechSplitterTests {
    @Test func shortAudioIsOnePiece() {
        #expect(SpeechSplitter.cuts([Float](repeating: 0.1, count: 16_000 * 10), rate: 16_000) == [0..<160_000])
    }

    @Test func cutsAtTheQuietestPointWithinBounds() {
        // 40 s of "speech" with quiet gaps at 9 s and 21 s and 33 s.
        var audio = [Float](repeating: 0.2, count: 16_000 * 40)
        for gap in [9.0, 21.0, 33.0] {
            let at = Int(gap * 16_000)
            for k in at..<(at + 4_000) { audio[k] = 0 }
        }
        let pieces = SpeechSplitter.cuts(audio, rate: 16_000)
        #expect(pieces.first?.lowerBound == 0 && pieces.last?.upperBound == audio.count)
        #expect(zip(pieces, pieces.dropFirst()).allSatisfy { $0.upperBound == $1.lowerBound })   // contiguous, nothing lost
        #expect(pieces.allSatisfy { $0.count <= 15 * 16_000 })
        let cutSeconds = pieces.dropLast().map { Double($0.upperBound) / 16_000 }
        #expect(cutSeconds.count == 3)
        for (cut, gap) in zip(cutSeconds, [9.0, 21.0, 33.0]) { #expect(cut >= gap && cut <= gap + 0.25, "cut \(cut) gap \(gap)") }
    }
}
