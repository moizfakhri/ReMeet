import Foundation

/// Exports a meeting as a self-contained AI-context Markdown file (`.md`) with YAML frontmatter,
/// folder context, user notes, summary, action items, open questions, and the full transcript.
/// Designed so users can point AI agents (Claude Code, Cursor, etc.) directly at a folder of
/// meeting files instead of copy-pasting each meeting into new chat sessions.
public enum MeetingExporter {
    /// Human- and agent-sortable filename: `2026-11-21_14-30_weekly-mv-team-meeting.md`.
    public static func filename(meta: MeetingMeta, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: meta.startTime)
        let stamp = String(format: "%04d-%02d-%02d_%02d-%02d",
                           c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
        return "\(stamp)_\(MeetingFolder.slug(meta.title)).md"
    }

    /// Full Markdown document: clean YAML frontmatter followed by `AIContextMarkdown` content
    /// (with standard Markdown checkboxes for action items).
    public static func render(meta: MeetingMeta, meetingID: String, transcript: Transcript?,
                              notes: [MeetingNote], summary: MeetingSummary?,
                              speakers: SpeakerNames, collection: MeetingCollection? = nil,
                              timeZone: TimeZone = .current) -> String {
        let iso = ISO8601DateFormatter()
        iso.timeZone = timeZone
        iso.formatOptions = [.withInternetDateTime]

        let turns = AIContextMarkdown.turns(transcript, speakers: speakers)
        var seenSpeakers = Set<String>()
        let speakerList = turns.map(\.speaker).filter { seenSpeakers.insert($0).inserted }

        var frontmatter = [
            "---",
            "meeting_id: \(yamlScalar(meetingID))",
            "title: \(yamlScalar(meta.title))",
            "date: \(iso.string(from: meta.startTime))",
        ]
        let duration = meta.effectiveDuration
        if duration > 0 {
            frontmatter.append("duration: \(yamlScalar(TimeFormat.duration(duration)))")
        }
        if let collection {
            frontmatter.append("folder: \(yamlScalar(collection.name))")
        }
        if let bundle = meta.sourceApp, let app = MeetingApp.known.first(where: { $0.bundleID == bundle }) {
            frontmatter.append("call_app: \(yamlScalar(app.name))")
        }
        frontmatter.append("status: \(meta.status.rawValue)")
        if !speakerList.isEmpty {
            frontmatter.append("speakers:")
            for name in speakerList {
                frontmatter.append("  - \(yamlScalar(name))")
            }
        }
        frontmatter.append("---")

        let body = renderBody(meta: meta, transcript: transcript, notes: notes, summary: summary,
                              speakers: speakers, collection: collection, timeZone: timeZone)
        return frontmatter.joined(separator: "\n") + "\n\n" + body
    }

    /// Same structure as `AIContextMarkdown.render`, using standard `- [ ]` / `- [x]` checkboxes
    /// for action items so both AI agents and Markdown editors (Obsidian, VS Code, GitHub) parse them cleanly.
    private static func renderBody(meta: MeetingMeta, transcript: Transcript?, notes: [MeetingNote],
                                   summary: MeetingSummary?, speakers: SpeakerNames,
                                   collection: MeetingCollection?, timeZone: TimeZone) -> String {
        var lines = ["# \(meta.title)", ""]

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
        let turns = AIContextMarkdown.turns(transcript, speakers: speakers)
        var seen = Set<String>()
        let names = turns.map(\.speaker).filter { seen.insert($0).inserted }
        if !names.isEmpty {
            facts.append("Speakers: " + names.map { $0 == "You" ? "You (the person who recorded this)" : $0 }
                .joined(separator: ", "))
        }
        if let collection { facts.append("Folder: \(collection.name)") }
        lines += facts.map { "- \($0)" }

        let background = collection?.context.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !background.isEmpty {
            lines += ["", "## Folder context", background]
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
            lines += ["", "## Summary"]
            lines += summary.summary.map { "- \($0.text)" }
            if !summary.decisions.isEmpty {
                lines += ["", "### Decisions"] + summary.decisions.map { "- \($0.text)" }
            }
            if !summary.actionItems.isEmpty {
                lines += ["", "### Action items"]
                for item in summary.actionItems {
                    var line = item.done ? "- [x] " : "- [ ] "
                    line += item.task
                    if let owner = item.owner, !owner.isEmpty { line += " (owner: \(owner))" }
                    if let due = item.due, !due.isEmpty { line += " (due: \(due))" }
                    lines.append(line)
                }
            }
            if !summary.openQuestions.isEmpty {
                lines += ["", "### Open questions"] + summary.openQuestions.map { "- \($0.text)" }
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

    /// Synchronizes one meeting's `.md` export with its folder's `exportDirectoryPath`.
    /// - If the meeting belongs to a folder with an `exportDirectoryPath` (and has a transcript or
    ///   summary or notes), writes/updates the `.md` file and removes any previous stale file
    ///   (e.g. after a rename or move to a different folder).
    /// - If the meeting no longer belongs to a folder with an `exportDirectoryPath`, removes the
    ///   previously auto-exported file (if it still exists) and clears `meta.exportedMarkdownPath`.
    /// Returns the written URL, or nil if no export is configured or the meeting isn't ready yet.
    @discardableResult
    public static func sync(_ folder: MeetingFolder, collection: MeetingCollection?,
                            timeZone: TimeZone = .current) throws -> URL? {
        let meta = try folder.readMeta()
        let previousPath = meta.exportedMarkdownPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        let exportDirPath = collection?.exportDirectoryPath?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let exportDirPath, !exportDirPath.isEmpty else {
            // Moved out of an exported folder or folder export disabled: clean up stale file.
            if let previousPath, !previousPath.isEmpty {
                try? FileManager.default.removeItem(atPath: previousPath)
                _ = try? folder.updateMeta { $0.exportedMarkdownPath = nil }
            }
            return nil
        }

        // Don't export an in-progress recording or a completely empty unprocessed meeting.
        guard meta.status != .recording else { return nil }
        let transcript = (try? folder.read(Transcript.self, .transcript)) ?? nil
        let summary = (try? folder.read(MeetingSummary.self, .summary)) ?? nil
        let notes = NotesFile(url: folder.file(.notes)).load()
        guard transcript != nil || summary != nil || !notes.isEmpty else { return nil }

        let speakers = ((try? folder.read(SpeakerNames.self, .speakers)) ?? nil) ?? SpeakerNames()
        let directory = URL(fileURLWithPath: (exportDirPath as NSString).expandingTildeInPath, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let targetURL = resolveTargetURL(in: directory, preferredFilename: filename(meta: meta, timeZone: timeZone),
                                         previousPath: previousPath)
        let markdown = render(meta: meta, meetingID: folder.id, transcript: transcript, notes: notes,
                              summary: summary, speakers: speakers, collection: collection, timeZone: timeZone)
        try Data(markdown.utf8).write(to: targetURL, options: .atomic)

        if let previousPath, !previousPath.isEmpty, previousPath != targetURL.path {
            try? FileManager.default.removeItem(atPath: previousPath)
        }
        if meta.exportedMarkdownPath != targetURL.path {
            _ = try? folder.updateMeta { $0.exportedMarkdownPath = targetURL.path }
        }
        return targetURL
    }

    /// Writes a one-off export to an explicit destination URL chosen by the user (does not alter
    /// `meta.exportedMarkdownPath`).
    @discardableResult
    public static func exportOneOff(_ folder: MeetingFolder, to destinationURL: URL,
                                    collection: MeetingCollection?,
                                    timeZone: TimeZone = .current) throws -> URL {
        let meta = try folder.readMeta()
        let transcript = (try? folder.read(Transcript.self, .transcript)) ?? nil
        let summary = (try? folder.read(MeetingSummary.self, .summary)) ?? nil
        let notes = NotesFile(url: folder.file(.notes)).load()
        let speakers = ((try? folder.read(SpeakerNames.self, .speakers)) ?? nil) ?? SpeakerNames()
        let markdown = render(meta: meta, meetingID: folder.id, transcript: transcript, notes: notes,
                              summary: summary, speakers: speakers, collection: collection, timeZone: timeZone)
        try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(markdown.utf8).write(to: destinationURL, options: .atomic)
        return destinationURL
    }

    /// Removes a previously auto-exported file when a meeting is moved to the Trash.
    public static func removeExportedFile(at path: String?) {
        guard let path, !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return }
        let url = URL(fileURLWithPath: path)
        if (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) == nil {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func resolveTargetURL(in directory: URL, preferredFilename: String,
                                         previousPath: String?) -> URL {
        let baseURL = directory.appendingPathComponent(preferredFilename)
        if !FileManager.default.fileExists(atPath: baseURL.path) || baseURL.path == previousPath {
            return baseURL
        }
        let stem = (preferredFilename as NSString).deletingPathExtension
        let ext = (preferredFilename as NSString).pathExtension
        var suffix = 2
        while true {
            let candidate = directory.appendingPathComponent("\(stem)-\(suffix).\(ext)")
            if !FileManager.default.fileExists(atPath: candidate.path) || candidate.path == previousPath {
                return candidate
            }
            suffix += 1
        }
    }

    private static func yamlScalar(_ value: String) -> String {
        let cleaned = value.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let escaped = cleaned
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
