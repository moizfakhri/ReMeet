import Foundation
import Observation
import ReMeetKit

/// Everything the meeting detail view shows, read from one folder. Edits write straight
/// back to the folder's JSON files.
@MainActor
@Observable
final class MeetingDocument {
    let folder: MeetingFolder
    private(set) var meta: MeetingMeta
    private(set) var notes: [MeetingNote] = []
    private(set) var summary: MeetingSummary?
    private(set) var transcript: Transcript?
    private(set) var speakers = SpeakerNames()
    private(set) var diarization: Diarization?
    private(set) var loadError: String?

    /// Everything read from disk for one meeting. Built off the main thread.
    struct Contents: Sendable {
        var meta: MeetingMeta
        var notes: [MeetingNote]
        var summary: MeetingSummary?
        var transcript: Transcript?
        var speakers: SpeakerNames
        var diarization: Diarization?
        var error: String?

        static func read(_ folder: MeetingFolder) -> Contents? {
            guard let meta = try? folder.readMeta() else { return nil }
            var contents = Contents(meta: meta, notes: NotesFile(url: folder.file(.notes)).load(), speakers: SpeakerNames())
            do {
                contents.summary = try folder.read(MeetingSummary.self, .summary)
                contents.transcript = try folder.read(Transcript.self, .transcript)
                contents.speakers = try folder.read(SpeakerNames.self, .speakers) ?? SpeakerNames()
                contents.diarization = try folder.read(Diarization.self, .diarization)
            } catch {
                contents.error = "Could not read this meeting's files: \(error.localizedDescription)"
            }
            return contents
        }
    }

    init(folder: MeetingFolder, contents: Contents) {
        self.folder = folder
        meta = contents.meta
        apply(contents)
    }

    /// Reads the meeting's files on a background thread (never blocks the UI).
    static func load(_ folder: MeetingFolder) async -> MeetingDocument? {
        guard let contents = await Task.detached(priority: .userInitiated, operation: { Contents.read(folder) }).value else {
            return nil
        }
        return MeetingDocument(folder: folder, contents: contents)
    }

    /// Synchronous load, for snapshots and self-tests.
    convenience init?(folder: MeetingFolder) {
        guard let contents = Contents.read(folder) else { return nil }
        self.init(folder: folder, contents: contents)
    }

    /// Re-reads the files off the main thread (after a pipeline step or rename).
    func reload() async {
        let folder = folder
        guard let contents = await Task.detached(priority: .userInitiated, operation: { Contents.read(folder) }).value else { return }
        apply(contents)
    }

    private func apply(_ contents: Contents) {
        meta = contents.meta
        notes = contents.notes
        summary = contents.summary
        transcript = contents.transcript
        speakers = contents.speakers
        diarization = contents.diarization
        loadError = contents.error
    }

    func rename(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != meta.title else { return }
        if let updated = try? folder.updateMeta({
            $0.title = trimmed
            $0.titleIsUserSet = true
        }) {
            meta = updated
            writeTranscriptMarkdown()
            writeSummaryMarkdown()
        }
    }

    func setActionItem(_ item: ActionItem, done: Bool) {
        guard var summary, let index = summary.actionItems.firstIndex(of: item) else { return }
        summary.actionItems[index].done = done
        self.summary = summary
        try? folder.write(summary, .summary)
        writeSummaryMarkdown()
    }

    /// Renames one voice in this meeting. Other speaker ids are not touched.
    func renameSpeaker(_ id: String, to name: String) {
        let old = speakers.displayName(for: id)
        let updated = speakers.renaming(id, to: name)
        guard updated != speakers else { return }
        speakers = updated
        try? folder.write(speakers, .speakers)
        let new = speakers.displayName(for: id)
        let trimmed = speakers.names[id] ?? ""
        if var summary, old != new {
            for i in summary.actionItems.indices where summary.actionItems[i].owner == old {
                summary.actionItems[i].owner = new
            }
            self.summary = summary
            try? folder.write(summary, .summary)
            writeSummaryMarkdown()
        }
        writeTranscriptMarkdown()
        rememberVoice(id, name: trimmed)
    }

    /// Makes every turn of `source` belong to `target`. Other voices are left alone.
    /// The mic user is never merged into someone else.
    func mergeSpeakers(from source: String, into target: String) {
        guard SpeakerMerge.canMerge(source, into: target), var transcript else { return }
        let sourceLabel = speakers.displayName(for: source)
        transcript = SpeakerMerge.transcript(transcript, from: source, into: target)
        self.transcript = transcript
        try? folder.write(transcript, .transcript)
        speakers = SpeakerMerge.names(speakers, from: source, into: target)
        try? folder.write(speakers, .speakers)
        if var existing = diarization {
            existing = SpeakerMerge.diarization(existing, from: source, into: target)
            diarization = existing
            try? folder.write(existing, .diarization)
        }
        let targetLabel = speakers.displayName(for: target)
        if var summary, sourceLabel != targetLabel {
            for index in summary.actionItems.indices where summary.actionItems[index].owner == sourceLabel {
                summary.actionItems[index].owner = targetLabel
            }
            self.summary = summary
            try? folder.write(summary, .summary)
            writeSummaryMarkdown()
        }
        writeTranscriptMarkdown()
        if let name = speakers.names[target] { rememberVoice(target, name: name) }
    }

    /// How many voices to find on the call, besides you. Nil is automatic.
    func setExpectedCallSpeakers(_ count: Int?) {
        let clamped = count.flatMap { (1...8).contains($0) ? $0 : nil }
        if let updated = try? folder.updateMeta({ $0.expectedCallSpeakers = clamped }) { meta = updated }
    }

    /// Nil uses the Settings default for the next transcription of this meeting.
    func setTranscriptionEngine(_ engine: TranscriptionEngine?) {
        if let updated = try? folder.updateMeta({ $0.processing.requestedTranscriptionEngine = engine?.rawValue }) {
            meta = updated
        }
    }

    private func rememberVoice(_ id: String, name: String) {
        guard !SpeakerMemory.isPlaceholder(name),
              let diarization = try? folder.read(Diarization.self, .diarization),
              let embedding = diarization.embeddings[id], !embedding.isEmpty else { return }
        let stretches = id == SpeakerNames.youID ? diarization.mic : diarization.system
        let seconds = stretches.filter { $0.speaker == id }.reduce(0) { $0 + $1.duration }
        let url = SpeakerMemoryFile.url(beside: folder)
        var memory = SpeakerMemoryFile.load(url)
        memory.remember(name: name, embedding: embedding, seconds: seconds)
        try? SpeakerMemoryFile.save(memory, to: url)
    }

    func saveNotes(_ notes: [MeetingNote]) {
        let sorted = notes.sorted { $0.t < $1.t }
        self.notes = sorted
        try? NotesFile(url: folder.file(.notes)).save(sorted)
        writeTranscriptMarkdown()
        writeSummaryMarkdown()
    }

    private func writeTranscriptMarkdown() {
        guard let transcript else { return }
        try? folder.writeText(TranscriptMarkdown.render(transcript, notes: notes, speakers: speakers,
                                                        title: meta.title), .transcriptMarkdown)
    }

    private func writeSummaryMarkdown() {
        guard let summary else { return }
        try? folder.writeText(SummaryMarkdown.render(summary, meta: meta, notes: notes), .summaryMarkdown)
    }
}
