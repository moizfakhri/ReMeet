import Foundation

/// Text that goes into the search index for one meeting, and the FTS5 query syntax.
public enum SearchText {
    /// FTS5 MATCH expression: every word must match, each as a prefix ("refu" finds
    /// "refunds"). User input is quoted, so FTS operators and punctuation are inert.
    public static func ftsQuery(_ input: String) -> String? {
        let words = input.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }
        return words.map { "\"\($0)\"*" }.joined(separator: " AND ")
    }

    public struct Document: Equatable, Sendable {
        public var title: String
        public var notes: String
        public var transcript: String
        public var summary: String
    }

    public static func document(meta: MeetingMeta, notes: [MeetingNote], transcript: Transcript?,
                                summary: MeetingSummary?, speakers: SpeakerNames) -> Document {
        let transcriptText = transcript?.segments
            .map { "\(speakers.displayName(for: $0.speaker)): \($0.text)" }
            .joined(separator: "\n") ?? ""
        var summaryParts: [String] = []
        if let summary {
            summaryParts += summary.summary.map(\.text)
            summaryParts += summary.decisions.map(\.text)
            summaryParts += summary.actionItems.map { [$0.owner, $0.task].compactMap { $0 }.joined(separator: ": ") }
            summaryParts += summary.openQuestions.map(\.text)
            summaryParts += summary.yourNotes.map(\.context)
        }
        return Document(title: meta.title,
                        notes: notes.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n"),
                        transcript: transcriptText,
                        summary: summaryParts.joined(separator: "\n"))
    }
}
