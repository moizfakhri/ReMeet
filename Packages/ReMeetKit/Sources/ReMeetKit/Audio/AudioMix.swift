import Foundation

/// Mixes the mic and call tracks into the mono playback file (audio.m4a).
public enum AudioMix {
    /// Sums two equally long chunks. Peaks above `ceiling` are compressed with a smooth
    /// tanh knee instead of hard clipping, so loud overlaps stay listenable.
    public static func mix(_ a: UnsafeBufferPointer<Float>, _ b: UnsafeBufferPointer<Float>,
                           into out: UnsafeMutableBufferPointer<Float>, ceiling: Float = 0.9) {
        let n = min(a.count, b.count, out.count)
        let headroom = 1 - ceiling
        for i in 0..<n {
            out[i] = limit(a[i] + b[i], ceiling: ceiling, headroom: headroom)
        }
        // A shorter input counts as silence for the rest of the chunk.
        if a.count > n || b.count > n {
            for i in n..<min(out.count, max(a.count, b.count)) {
                let v = i < a.count ? a[i] : b[i]
                out[i] = limit(v, ceiling: ceiling, headroom: headroom)
            }
        }
    }

    public static func mix(_ a: [Float], _ b: [Float], ceiling: Float = 0.9) -> [Float] {
        var out = [Float](repeating: 0, count: max(a.count, b.count))
        a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                out.withUnsafeMutableBufferPointer { po in mix(pa, pb, into: po, ceiling: ceiling) }
            }
        }
        return out
    }

    @inline(__always)
    static func limit(_ x: Float, ceiling: Float, headroom: Float) -> Float {
        let m = abs(x)
        guard m > ceiling else { return x }
        let over = (m - ceiling) / headroom
        return (x < 0 ? -1 : 1) * (ceiling + headroom * tanh(over))
    }
}
