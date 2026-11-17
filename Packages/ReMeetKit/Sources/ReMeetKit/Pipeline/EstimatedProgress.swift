import Foundation

/// A progress bar for a stage whose real progress arrives in big steps (one long speaker
/// turn can take a minute on Cohere). It moves with time against an estimate of how long the
/// stage should take, never goes backwards, never shows more than 99% before the stage
/// really ends, and never shows less than the real fraction done.
public struct EstimatedProgress: Sendable {
    /// Expected stage length in seconds.
    public var expected: TimeInterval
    /// Shown ceiling until the stage reports completion.
    public static let ceiling = 0.99
    private var shown = 0.0

    public init(expected: TimeInterval) {
        self.expected = max(expected, 1)
    }

    /// Eased: ~90% at the expected time, then creeping toward 99% if it runs long.
    public static func curve(elapsed: TimeInterval, expected: TimeInterval) -> Double {
        let k = 2.4   // 0.99 * (1 - e^-2.4) ≈ 0.90
        return ceiling * (1 - exp(-k * max(elapsed, 0) / max(expected, 1)))
    }

    /// The value to show now. `actual` is the real fraction done (0...1) if known.
    public mutating func value(elapsed: TimeInterval, actual: Double) -> Double {
        let estimate = Self.curve(elapsed: elapsed, expected: expected)
        shown = min(Self.ceiling, max(shown, estimate, min(actual, Self.ceiling)))
        return shown
    }

    /// Expected seconds for `audioSeconds` of speech at `secondsPerAudioSecond`, plus a fixed
    /// model-load cost.
    public static func expectedSeconds(audioSeconds: Double, secondsPerAudioSecond: Double, loadSeconds: Double) -> TimeInterval {
        loadSeconds + max(audioSeconds, 0) * max(secondsPerAudioSecond, 0)
    }

    /// Blends a newly measured rate into the stored one, so the estimate follows this Mac.
    public static func learn(stored: Double?, measured: Double) -> Double {
        guard measured.isFinite, measured > 0 else { return stored ?? measured }
        guard let stored, stored > 0 else { return measured }
        return stored * 0.6 + measured * 0.4
    }
}
