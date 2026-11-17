import Foundation

/// "Copy for AI": one meeting as plain Markdown to paste into any AI chat as context.
/// Built for reading by a model: a short header (what, when, who), your own notes, the
/// summary when there is one, then the whole transcript one line per turn with the time
/// and the speaker's name. No tables or styling a model has to see past.
public enum AIContextMarkdown {
    public static func render(meta: MeetingMeta, transcript: Transcript?, notes: [MeetingNote],
                              summary: MeetingSummary?, speakers: SpeakerNames, collection: MeetingCollection? = nil,
                              timeZone: TimeZone = .current) -> String {
        var lines = ["# Meeting: \(meta.title)", ""]

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEEE, MMM d, yyyy 'at' h:mm a"
        var facts = ["Date: \(formatter.string(from: meta.startTime))"]
        let duration = meta.effectiveDuration
        if duration > 0 { facts.append("Length: \(TimeFormat.duration(duration))") }
        if let bundle = meta.sourceApp, let app = MeetingApp.known.first(where: { $0.bundleID == bundle }) {
            facts.append("Call app: \(app.name)")
        }
        let turns = turns(transcript, speakers: speakers)
        let names = orderedUnique(turns.map(\.speaker))
        if !names.isEmpty {
            facts.append("Speakers: " + names.map { $0 == "You" ? "You (the person who recorded this)" : $0 }
                .joined(separator: ", "))
        }
        if let collection { facts.append("Folder: \(collection.name)") }
        lines += facts.map { "- \($0)" }

        let background = collection?.context.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !background.isEmpty {
            lines += ["", "## Context (written by me about this group of meetings)", background]
        }

        let sortedNotes = notes.sorted { $0.t < $1.t }
        if !sortedNotes.isEmpty {
            lines += ["", "## My notes during the meeting"]
            for note in sortedNotes {
                let text = note.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let label = switch note.kind {
                case .bookmark: text.isEmpty ? "Bookmarked this moment" : "Bookmark: \(text)"
                case .action: "Action item: \(text)"
                case .note: text
                }
                lines.append("- [\(TimeFormat.clock(note.t))] \(label)")
            }
        }

        if let summary {
            lines += ["", "## Summary (generated on this Mac; the transcript below is the source)"]
            lines += summary.summary.map { "- \($0.text)" }
            if !summary.decisions.isEmpty {
                lines += ["", "Decisions:"] + summary.decisions.map { "- \($0.text)" }
            }
            if !summary.actionItems.isEmpty {
                lines += ["", "Action items:"]
                for item in summary.actionItems {
                    var line = "- " + (item.done ? "[done] " : "") + item.task
                    if let owner = item.owner, !owner.isEmpty { line += " (owner: \(owner))" }
                    if let due = item.due, !due.isEmpty { line += " (due: \(due))" }
                    lines.append(line)
                }
            }
            if !summary.openQuestions.isEmpty {
                lines += ["", "Open questions:"] + summary.openQuestions.map { "- \($0.text)" }
            }
        }

        lines += ["", "## Transcript"]
        if turns.isEmpty {
            lines.append("(No transcript yet.)")
        } else {
            lines += turns.map { "[\(TimeFormat.clock($0.start))] \($0.speaker): \($0.text)" }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Consecutive segments from the same speaker merged into one line.
    static func turns(_ transcript: Transcript?, speakers: SpeakerNames) -> [(start: Double, speaker: String, text: String)] {
        var result: [(start: Double, speaker: String, text: String)] = []
        for segment in transcript.map({ Stitcher.stitch($0.segments) }) ?? [] {
            let name = speakers.displayName(for: segment.speaker)
            if let last = result.last, last.speaker == name {
                result[result.count - 1].text += " " + segment.text
            } else {
                result.append((segment.start, name, segment.text))
            }
        }
        return result
    }

    private static func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
