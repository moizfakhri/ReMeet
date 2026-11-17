import Foundation

/// Turns a model's reply into a MeetingSummary. Lenient about shape (models drift), strict
/// about the spec's promises: every note is covered and every action note is an action item.
public enum SummaryParser {
    public enum ParseError: LocalizedError, Equatable {
        case noJSON
        case invalid(String)

        public var errorDescription: String? {
            switch self {
            case .noJSON: "The summary model did not return JSON."
            case .invalid(let detail): "The summary model returned JSON in an unexpected shape (\(detail))."
            }
        }
    }

    public static func parse(_ reply: String, notes: [MeetingNote], fallbackTitle: String) throws -> MeetingSummary {
        let data = Data(try extractJSON(reply).utf8)
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ParseError.invalid("not valid JSON")
        }
        guard let root = object as? [String: Any] else { throw ParseError.invalid("not an object") }

        var summary = MeetingSummary(
            title: string(root["title"]).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackTitle,
            summary: Array(points(root["summary"]).prefix(6)),
            decisions: points(root["decisions"]),
            actionItems: actions(root["action_items"] ?? root["actionItems"]),
            openQuestions: points(root["open_questions"] ?? root["openQuestions"]),
            yourNotes: noteContexts(root["your_notes"] ?? root["yourNotes"]))
        enforceNotes(&summary, notes: notes)
        return summary
    }

    /// The JSON object inside a reply: strips ``` fences, <think> blocks and chatter.
    public static func extractJSON(_ reply: String) throws -> String {
        var text = reply
        if let end = text.range(of: "</think>") { text = String(text[end.upperBound...]) }
        guard let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close else {
            throw ParseError.noJSON
        }
        return String(text[open...close])
    }

    /// "12:34", "[1:02:03]", 754, "754" -> seconds.
    public static func time(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        guard var s = value as? String else { return nil }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        if s.isEmpty || s.lowercased() == "null" { return nil }
        return TimeFormat.parseClock(s)
    }

    // MARK: - Shapes

    private static func string(_ value: Any?) -> String? {
        guard let s = value as? String else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.lowercased() == "null" || trimmed.lowercased() == "none" ? nil : trimmed
    }

    private static func points(_ value: Any?) -> [SummaryPoint] {
        guard let list = value as? [Any] else { return [] }
        return list.compactMap { item in
            if let s = string(item) { return SummaryPoint(text: s) }
            guard let dict = item as? [String: Any],
                  let text = string(dict["text"] ?? dict["point"] ?? dict["question"] ?? dict["decision"]) else { return nil }
            return SummaryPoint(text: text, t: time(dict["t"] ?? dict["time"]))
        }
    }

    private static func actions(_ value: Any?) -> [ActionItem] {
        guard let list = value as? [Any] else { return [] }
        return list.compactMap { item in
            if let s = string(item) { return ActionItem(task: s) }
            guard let dict = item as? [String: Any], let task = string(dict["task"] ?? dict["text"]) else { return nil }
            return ActionItem(owner: string(dict["owner"]), task: task, due: string(dict["due"]),
                              done: (dict["done"] as? Bool) ?? false, t: time(dict["t"] ?? dict["time"]))
        }
    }

    private static func noteContexts(_ value: Any?) -> [NoteContext] {
        guard let list = value as? [Any] else { return [] }
        return list.compactMap { item in
            guard let dict = item as? [String: Any], let t = time(dict["t"] ?? dict["time"]) else { return nil }
            return NoteContext(t: t, note: string(dict["note"]) ?? "", context: string(dict["context"]) ?? "")
        }
    }

    // MARK: - Spec guarantees

    /// Adds anything the model left out: one `your_notes` entry per note (matched by time,
    /// then text) and one action item per action-kind note.
    public static func enforceNotes(_ summary: inout MeetingSummary, notes: [MeetingNote]) {
        var contexts: [NoteContext] = []
        var unused = summary.yourNotes
        for note in notes.sorted(by: { $0.t < $1.t }) {
            let match = unused.firstIndex { abs($0.t - note.t) < 3 }
                ?? unused.firstIndex { !note.text.isEmpty && $0.note.localizedCaseInsensitiveContains(note.text) }
            var entry = NoteContext(t: note.t, note: note.displayText, context: "")
            if let match {
                entry.context = echoesPrompt(unused[match].context) ? "" : unused[match].context
                unused.remove(at: match)
            }
            contexts.append(entry)
        }
        summary.yourNotes = contexts

        for note in notes where note.kind == .action && !note.text.isEmpty {
            let covered = summary.actionItems.contains { item in
                item.task.localizedCaseInsensitiveContains(note.text)
                    || note.text.localizedCaseInsensitiveContains(item.task)
                    || (item.t.map { abs($0 - note.t) < 60 } ?? false) && wordOverlap(item.task, note.text) >= 0.5
            }
            if !covered { summary.actionItems.append(ActionItem(owner: "You", task: note.text, t: note.t)) }
        }
    }

    /// Small models sometimes copy the prompt's instructions into a note's context (seen on a
    /// real 19 s meeting: "The person who recorded this took these notes..."). Such a line says
    /// nothing about the meeting, so it is dropped.
    static func echoesPrompt(_ context: String) -> Bool {
        let lowered = context.lowercased()
        let phrases = ["person who recorded this", "took these notes", "must appear in", "your_notes",
                       "marked action", "return json", "the transcript's", "most important points"]
        return phrases.contains { lowered.contains($0) }
    }

    static func wordOverlap(_ a: String, _ b: String) -> Double {
        func words(_ s: String) -> Set<String> {
            Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 })
        }
        let wa = words(a), wb = words(b)
        guard !wb.isEmpty else { return 0 }
        return Double(wa.intersection(wb).count) / Double(wb.count)
    }
}

/// Gives "jump to" times to summary points the model left without one, by finding the
/// transcript line that shares the most words with the point.
public enum SummaryTimeLinker {
    public static func link(_ summary: inout MeetingSummary, lines: [SummaryPrompt.TranscriptLine], minOverlap: Double = 0.3) {
        func best(_ text: String) -> Double? {
            var top: (Double, Double)?
            for line in lines {
                let score = SummaryParser.wordOverlap(line.text, text)
                if score >= minOverlap, score > (top?.0 ?? 0) { top = (score, line.t) }
            }
            return top?.1
        }
        for i in summary.summary.indices where summary.summary[i].t == nil { summary.summary[i].t = best(summary.summary[i].text) }
        for i in summary.decisions.indices where summary.decisions[i].t == nil { summary.decisions[i].t = best(summary.decisions[i].text) }
        for i in summary.openQuestions.indices where summary.openQuestions[i].t == nil { summary.openQuestions[i].t = best(summary.openQuestions[i].text) }
        for i in summary.actionItems.indices where summary.actionItems[i].t == nil { summary.actionItems[i].t = best(summary.actionItems[i].task) }
    }
}
