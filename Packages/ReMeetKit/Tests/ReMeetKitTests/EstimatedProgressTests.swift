import Testing
@testable import ReMeetKit

struct EstimatedProgressTests {
    @Test func movesWithTimeAndStopsAt99() {
        var p = EstimatedProgress(expected: 100)
        let early = p.value(elapsed: 5, actual: 0)
        let mid = p.value(elapsed: 50, actual: 0)
        let atExpected = p.value(elapsed: 100, actual: 0)
        let late = p.value(elapsed: 1_000, actual: 0)
        #expect(early > 0.05 && early < 0.2)
        #expect(mid > early && atExpected > 0.85 && atExpected < 0.92)
        #expect(late <= EstimatedProgress.ceiling && late > atExpected)
    }

    @Test func neverBackwardsAndNeverBelowReal() {
        var p = EstimatedProgress(expected: 100)
        #expect(p.value(elapsed: 10, actual: 0.6) == 0.6)      // real progress ahead of the estimate
        #expect(p.value(elapsed: 11, actual: 0.6) == 0.6)      // estimate below: hold, never drop
        #expect(p.value(elapsed: 12, actual: 1.0) == EstimatedProgress.ceiling)  // 100% only on completion
    }

    @Test func expectedTimeAndLearning() {
        #expect(EstimatedProgress.expectedSeconds(audioSeconds: 3_600, secondsPerAudioSecond: 0.05, loadSeconds: 4) == 184)
        #expect(EstimatedProgress.learn(stored: nil, measured: 0.05) == 0.05)
        #expect(abs(EstimatedProgress.learn(stored: 0.05, measured: 0.10) - 0.07) < 1e-9)
        #expect(EstimatedProgress.learn(stored: 0.05, measured: .infinity) == 0.05)
    }
}
