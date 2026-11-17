import Foundation

/// Which summarizer wrote (or should write) a summary.
public enum SummaryBackendKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case builtIn
    case lmStudio

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .builtIn: "Built-in model"
        case .lmStudio: "LM Studio"
        }
    }

    public var menuTitle: String {
        switch self {
        case .builtIn: "With the built-in model (on this Mac)"
        case .lmStudio: "With LM Studio (on this Mac)"
        }
    }
}

/// summary.md and the "Copy summary" clipboard text.
public enum SummaryMarkdown {
    public static func render(_ s: MeetingSummary, meta: MeetingMeta, notes: [MeetingNote],
                              timeZone: TimeZone = .current) -> String {
        var lines: [String] = []
        lines.append("# \(meta.title)")
        var style = Date.FormatStyle(date: .abbreviated, time: .shortened)
        style.timeZone = timeZone
        lines.append("\(meta.startTime.formatted(style)) · \(TimeFormat.duration(meta.effectiveDuration))")

        func section(_ title: String, _ body: [String]) {
            guard !body.isEmpty else { return }
            lines.append("")
            lines.append("## \(title)")
            lines.append(contentsOf: body)
        }
        func stamp(_ t: Double?) -> String { t.map { " (\(TimeFormat.clock($0)))" } ?? "" }

        section("Summary", s.summary.map { "- \($0.text)\(stamp($0.t))" })
        section("Action items", s.actionItems.map { item in
            let who = [item.owner, item.due].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
            return "- [\(item.done ? "x" : " ")] \(item.task)\(who.isEmpty ? "" : " — \(who)")"
        })
        let noteLines: [String] = notes.map { note in
            let context = s.yourNotes.first { abs($0.t - note.t) < 1.5 }?.context
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let label = note.kind == .action ? " (action)" : ""
            let suffix = (context?.isEmpty == false) ? ": \(context!)" : ""
            return "- **\(TimeFormat.clock(note.t))** \(note.displayText)\(label)\(suffix)"
        }
        section("Your notes", noteLines)
        section("Decisions", s.decisions.map { "- \($0.text)\(stamp($0.t))" })
        section("Open questions", s.openQuestions.map { "- \($0.text)\(stamp($0.t))" })
        return lines.joined(separator: "\n") + "\n"
    }
}
