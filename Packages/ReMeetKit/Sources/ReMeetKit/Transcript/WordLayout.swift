import Foundation

/// Where each word sits on the playback timeline.
public enum WordLayout {
    public static func tokens(_ text: String) -> [String] {
        text.split { $0.isWhitespace }.map(String.init)
    }

    /// Uses the transcriber's times when there is one per word. Otherwise each word gets an
    /// equal slice of the turn, so a click and the highlight still have a time.
    public static func words(text: String, start: Double, end: Double, timed: [TranscriptWord]) -> [TranscriptWord] {
        let pieces = tokens(text)
        guard !pieces.isEmpty else { return [] }
        if timed.count == pieces.count {
            return zip(pieces, timed).map { token, time in
                TranscriptWord(text: token, start: time.start, end: max(time.start, time.end))
            }
        }
        let span = max(end - start, 0)
        let slice = span / Double(pieces.count)
        return pieces.enumerated().map { index, token in
            let wordStart = start + Double(index) * slice
            let wordEnd = index == pieces.count - 1 ? max(start, end) : wordStart + slice
            return TranscriptWord(text: token, start: wordStart, end: max(wordStart, wordEnd))
        }
    }

    /// The word being spoken. The last word includes its end, so playback resting there stays highlighted.
    public static func activeIndex(at time: Double, words: [TranscriptWord]) -> Int? {
        guard !words.isEmpty else { return nil }
        if let index = words.firstIndex(where: { time >= $0.start && time < $0.end }) { return index }
        if let last = words.indices.last, time >= words[last].start, time <= words[last].end { return last }
        return nil
    }
}

/// A selection in the transcript names one person. Two people's words are not a name.
public enum VoiceClip {
    public static func speaker(_ speakers: [String]) -> String? {
        let unique = Set(speakers)
        guard unique.count == 1 else { return nil }
        return unique.first
    }
}
