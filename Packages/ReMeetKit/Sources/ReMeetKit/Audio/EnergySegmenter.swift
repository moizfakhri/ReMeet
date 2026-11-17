import Foundation

/// Finds stretches with sound by loudness. Used when the diarizer reports no speech on a
/// track that clearly has sound (it works on 10 s windows and misses short recordings and
/// short utterances), so those words still reach transcription (audit C1).
public enum EnergySegmenter {
    public struct Options: Sendable {
        public var frameSeconds = 0.03
        /// Frames louder than this (dBFS RMS) count as sound.
        public var thresholdDB: Float = -45
        public var mergeGap = 0.8
        public var minDuration = 0.3

        public init() {}
    }

    public static func segments(_ samples: [Float], rate: Double, options: Options = Options()) -> [(start: Double, end: Double)] {
        let frame = max(1, Int(options.frameSeconds * rate))
        let threshold = pow(10, options.thresholdDB / 20)
        var regions: [(Double, Double)] = []
        var openStart: Double?
        var index = 0
        while index < samples.count {
            let end = min(samples.count, index + frame)
            var sum: Float = 0
            for i in index..<end { sum += samples[i] * samples[i] }
            let rms = (sum / Float(end - index)).squareRoot()
            let t = Double(index) / rate
            if rms >= threshold {
                if openStart == nil { openStart = t }
            } else if let start = openStart {
                regions.append((start, t))
                openStart = nil
            }
            index = end
        }
        if let start = openStart { regions.append((start, Double(samples.count) / rate)) }

        var merged: [(Double, Double)] = []
        for region in regions {
            if let last = merged.last, region.0 - last.1 <= options.mergeGap {
                merged[merged.count - 1].1 = region.1
            } else {
                merged.append(region)
            }
        }
        return merged.filter { $0.1 - $0.0 >= options.minDuration }.map { (start: $0.0, end: $0.1) }
    }

    /// Loudest RMS (dBFS) over 30 ms frames, for "does this track have any sound at all".
    public static func peakRMSdB(_ samples: [Float], rate: Double) -> Float {
        let frame = max(1, Int(0.03 * rate))
        var best: Float = 0
        var index = 0
        while index < samples.count {
            let end = min(samples.count, index + frame)
            var sum: Float = 0
            for i in index..<end { sum += samples[i] * samples[i] }
            best = max(best, (sum / Float(end - index)).squareRoot())
            index = end
        }
        return best > 0 ? 20 * log10(best) : -160
    }
}

/// Cuts long speech into pieces a fixed-window recognizer can take whole. Cohere's decoder
/// (the ungated v2 export) emits at most ~99 tokens per call, which dense speech can exceed
/// beyond ~20 s, so turns are cut at the quietest 30 ms frame between `minSeconds` and
/// `maxSeconds` from the previous cut, where a word boundary is most likely.
public enum SpeechSplitter {
    public static func cuts(_ samples: [Float], rate: Double, minSeconds: Double = 6, maxSeconds: Double = 15) -> [Range<Int>] {
        let maxLen = Int(maxSeconds * rate), minLen = Int(minSeconds * rate)
        guard samples.count > maxLen else { return [0..<samples.count] }
        let frame = max(1, Int(0.03 * rate))
        var pieces: [Range<Int>] = []
        var start = 0
        while samples.count - start > maxLen {
            var bestCut = start + maxLen
            var bestEnergy = Float.greatestFiniteMagnitude
            var i = start + minLen
            while i + frame <= start + maxLen {
                var sum: Float = 0
                for k in i..<(i + frame) { sum += samples[k] * samples[k] }
                if sum < bestEnergy {
                    bestEnergy = sum
                    bestCut = i + frame / 2
                }
                i += frame
            }
            pieces.append(start..<bestCut)
            start = bestCut
        }
        pieces.append(start..<samples.count)
        return pieces
    }
}
