import Foundation

/// Builds the summarizer requests. Every backend gets the same text and the same JSON shape.
public enum SummaryPrompt {
    public struct Input: Sendable {
        public var title: String
        public var date: Date
        public var duration: Double
        public var lines: [TranscriptLine]
        public var notes: [MeetingNote]
        public var customInstructions: String
        /// What the user wrote about the folder this meeting is in (the lab, the project,
        /// who is who). Background for the model, not something to summarize.
        public var folderContext: String
        /// The recording person's name, spelled the way they want it written.
        public var recorderName: String

        public init(title: String, date: Date, duration: Double, lines: [TranscriptLine],
                    notes: [MeetingNote], customInstructions: String = "", folderContext: String = "",
                    recorderName: String = "") {
            self.title = title
            self.date = date
            self.duration = duration
            self.lines = lines
            self.notes = notes
            self.customInstructions = customInstructions
            self.folderContext = folderContext
            self.recorderName = recorderName
        }
    }

    /// One transcript turn as the model sees it: `[12:34] Priya: text`.
    public struct TranscriptLine: Equatable, Sendable {
        public var t: Double
        public var speaker: String
        public var text: String

        public init(t: Double, speaker: String, text: String) {
            self.t = t
            self.speaker = speaker
            self.text = text
        }

        public var rendered: String { "[\(TimeFormat.clock(t))] \(speaker): \(text)" }
    }

    public static func lines(from transcript: Transcript, speakers: SpeakerNames) -> [TranscriptLine] {
        transcript.segments.map { TranscriptLine(t: $0.start, speaker: speakers.displayName(for: $0.speaker), text: $0.text) }
    }

    public static let schemaDescription = """
    {
      "title": "short meeting title, 3 to 7 words",
      "summary": [{"text": "one sentence", "t": "mm:ss where it was discussed"}],
      "decisions": [{"text": "decision", "t": "mm:ss"}],
      "action_items": [{"owner": "name or null", "task": "what to do", "due": "when, or null", "t": "mm:ss", "relates_to_me": true}],
      "open_questions": [{"text": "question left open", "t": "mm:ss"}],
      "your_notes": [{"t": "mm:ss of the note", "note": "the note exactly as written", "context": "what was said around it, one or two sentences"}]
    }
    """

    public static let system = """
    You write concise, factual meeting notes from a transcript. Use only what the transcript says; never invent names, numbers or dates. Write plain English, no filler, no praise, no speculation. Answer with one JSON object and nothing else.
    """

    public static func user(_ input: Input, part: (index: Int, count: Int)? = nil) -> String {
        var out: [String] = []
        out.append("Meeting: \(input.title)")
        out.append("Date: \(input.date.formatted(date: .complete, time: .shortened)), length \(TimeFormat.duration(input.duration))")
        let people = Array(Set(input.lines.map(\.speaker))).sorted()
        let recorder = input.recorderName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !recorder.isEmpty {
            out.append("The person who recorded this is named \(recorder). Spell that name exactly \"\(recorder)\". \"You\" is \(recorder).")
        }
        if !people.isEmpty { out.append("Speakers: \(people.joined(separator: ", ")). \"You\" is the person who recorded this.") }
        let background = input.folderContext.trimmingCharacters(in: .whitespacesAndNewlines)
        if !background.isEmpty {
            out.append("Background from the person who recorded this (use it to understand names, projects and terms; do not summarize it): \(background)")
        }
        if let part {
            out.append("This is part \(part.index) of \(part.count) of the meeting; summarize only this part.")
        }
        out.append("")
        if !input.notes.isEmpty {
            out.append("The person who recorded this took these notes during the meeting. They are the most important points. Every one must appear in \"your_notes\" with its context, and every note marked ACTION must also be an action item.")
            for note in input.notes {
                let kind = note.kind == .action ? "ACTION" : note.kind == .bookmark ? "BOOKMARK" : "NOTE"
                let text = note.kind == .bookmark && note.text.isEmpty ? "(bookmarked this moment)" : note.text
                out.append("- [\(TimeFormat.clock(note.t))] \(kind): \(text)")
            }
            out.append("")
        }
        out.append("Transcript:")
        out.append(contentsOf: input.lines.map(\.rendered))
        out.append("")
        out.append("Return JSON in exactly this shape:")
        out.append(schemaDescription)
        out.append("Rules: 3 to 6 summary sentences, most important first. Leave a list empty if there is nothing for it. Use the transcript's [mm:ss] times for \"t\". An action item's owner is the person who agreed to do it. Set \"relates_to_me\": true on an action item only when the owner is the person who recorded this OR the task directly delivers something to, unblocks, or depends on them; false otherwise.")
        let custom = input.customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { out.append("Also: \(custom)") }
        return out.joined(separator: "\n")
    }

    /// Final pass when the meeting was summarized in parts.
    public static func merge(partials: [String], input: Input) -> String {
        var out = ["Meeting: \(input.title)"]
        let background = input.folderContext.trimmingCharacters(in: .whitespacesAndNewlines)
        if !background.isEmpty {
            out.append("Background from the person who recorded this (use it to understand names, projects and terms; do not summarize it): \(background)")
        }
        out.append("These are JSON notes for consecutive parts of one meeting. Combine them into one set of notes for the whole meeting: 3 to 6 summary sentences overall, merged and de-duplicated decisions, action items and open questions, and keep every entry of \"your_notes\".")
        out.append("")
        if !input.notes.isEmpty {
            out.append("The person who recorded this took these notes during the meeting. Every one must appear in \"your_notes\" with its context from the parts, and every note marked ACTION must also be an action item:")
            for note in input.notes {
                let kind = note.kind == .action ? "ACTION" : note.kind == .bookmark ? "BOOKMARK" : "NOTE"
                let text = note.kind == .bookmark && note.text.isEmpty ? "(bookmarked this moment)" : note.text
                out.append("- [\(TimeFormat.clock(note.t))] \(kind): \(text)")
            }
            out.append("")
        }
        for (i, p) in partials.enumerated() { out.append("Part \(i + 1):\n\(p)\n") }
        out.append("Return JSON in exactly this shape:")
        out.append(schemaDescription)
        let custom = input.customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { out.append("Also: \(custom)") }
        return out.joined(separator: "\n")
    }

    /// Rough token count (about 4 characters per token for English).
    public static func estimateTokens(_ text: String) -> Int { text.utf8.count / 4 + 1 }
}

public enum TranscriptChunker {
    /// Splits the transcript into pieces that fit `maxTokens` (prompt overhead included),
    /// preferring 15-minute boundaries. Returns one piece when everything fits.
    public static func chunks(_ lines: [SummaryPrompt.TranscriptLine], maxTokens: Int,
                              overheadTokens: Int = 1_500, minutes: Double = 15) -> [[SummaryPrompt.TranscriptLine]] {
        let budget = max(maxTokens - overheadTokens, 500)
        let total = lines.reduce(0) { $0 + SummaryPrompt.estimateTokens($1.rendered) + 1 }
        if total <= budget { return [lines] }
        var pieces: [[SummaryPrompt.TranscriptLine]] = []
        var current: [SummaryPrompt.TranscriptLine] = []
        var tokens = 0
        var pieceStart = lines.first?.t ?? 0
        for line in lines {
            let cost = SummaryPrompt.estimateTokens(line.rendered) + 1
            let overTime = line.t - pieceStart >= minutes * 60
            if !current.isEmpty, tokens + cost > budget || overTime {
                pieces.append(current)
                current = []
                tokens = 0
                pieceStart = line.t
            }
            current.append(line)
            tokens += cost
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    /// Partitions notes across chunks using half-open boundaries `[thisStart, nextStart)`, so notes
    /// taken during the final turn of a chunk (or in a pause before the next chunk) are never dropped.
    public static func notesForChunk(_ notes: [MeetingNote], pieces: [[SummaryPrompt.TranscriptLine]], index: Int) -> [MeetingNote] {
        guard pieces.indices.contains(index) else { return [] }
        let lower = index == 0 ? -Double.infinity : (pieces[index].first?.t ?? -Double.infinity)
        let upper = index == pieces.count - 1 ? Double.infinity : (pieces[index + 1].first?.t ?? Double.infinity)
        return notes.filter { $0.t >= lower && $0.t < upper }
    }
}
