import Foundation

/// Word error rate (substitutions + deletions + insertions) / reference words, after
/// lowercasing and dropping punctuation. Used by the speech self-test.
public enum WordErrorRate {
    public static func normalize(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    public static func compute(reference: String, hypothesis: String) -> Double {
        let r = normalize(reference), h = normalize(hypothesis)
        guard !r.isEmpty else { return h.isEmpty ? 0 : 1 }
        var previous = Array(0...h.count)
        for i in 1...r.count {
            var current = [i] + [Int](repeating: 0, count: h.count)
            for j in stride(from: 1, through: h.count, by: 1) {
                current[j] = r[i - 1] == h[j - 1] ? previous[j - 1]
                    : 1 + min(previous[j - 1], previous[j], current[j - 1])
            }
            previous = current
        }
        return Double(previous[h.count]) / Double(r.count)
    }
}
