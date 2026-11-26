import Foundation
import Observation
import ReMeetKit

/// Everything the meeting detail view shows, read from one folder. Edits write straight
/// back to the folder's JSON files. Derived metadata and speaker summaries are precomputed
/// off the main thread when loaded so SwiftUI body passes never hit FileManager or scan
/// full transcripts/embeddings on every render.
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

    struct ClipRange: Equatable, Sendable {
        var start: Double
        var end: Double
    }

    // Precomputed derived state (updated on load / mutation, never computed inside SwiftUI body).
    private(set) var wordCount: Int = 0
    private(set) var originalAudioURLs: [URL] = []
    private(set) var hasSystemTrack: Bool = false
    private(set) var reprocessStart: PipelineStage = .compress
    private(set) var notesChangedSinceSummary: Bool = false
    private(set) var callSpeakers: [String] = []
    private(set) var speakerClips: [String: ClipRange] = [:]
    private(set) var speakerAlike: [String: SpeakerLikeness.Pair] = [:]
    private(set) var savedMoments = SavedMoments()
    private(set) var moments: [KeyMoment] = []
    private(set) var pulse: ConversationPulse = .empty

    /// Everything read from disk for one meeting. Built off the main thread.
    struct Contents: Sendable {
        var meta: MeetingMeta
        var notes: [MeetingNote]
        var summary: MeetingSummary?
        var transcript: Transcript?
        var speakers: SpeakerNames
        var diarization: Diarization?
        var savedMoments: SavedMoments = SavedMoments()
        var error: String?
        var wordCount: Int = 0
        var originalAudioURLs: [URL] = []
        var hasSystemTrack: Bool = false
        var reprocessStart: PipelineStage = .compress
        var notesChangedSinceSummary: Bool = false
        var callSpeakers: [String] = []
        var speakerClips: [String: ClipRange] = [:]
        var speakerAlike: [String: SpeakerLikeness.Pair] = [:]
        var moments: [KeyMoment] = []
        var pulse: ConversationPulse = .empty

        static func read(_ folder: MeetingFolder) -> Contents? {
            guard let meta = try? folder.readMeta() else { return nil }
            var contents = Contents(
                meta: meta,
                notes: NotesFile(url: folder.file(.notes)).load(),
                speakers: SpeakerNames(),
                savedMoments: MomentsFile(url: folder.file(.moments)).load()
            )
            do {
                contents.summary = try folder.read(MeetingSummary.self, .summary)
                contents.transcript = try folder.read(Transcript.self, .transcript)
                contents.speakers = try folder.read(SpeakerNames.self, .speakers) ?? SpeakerNames()
                contents.diarization = try folder.read(Diarization.self, .diarization)
            } catch {
                contents.error = "Could not read this meeting's files: \(error.localizedDescription)"
            }
            contents.computeDerived(folder: folder)
            return contents
        }

        mutating func computeDerived(folder: MeetingFolder) {
            wordCount = transcript?.wordCount ?? 0
            originalAudioURLs = folder.originalAudioURLs()
            hasSystemTrack = folder.exists(.system16k)
            reprocessStart = AppModel.reprocessStart(folder)
            let notesDate = (try? FileManager.default.attributesOfItem(atPath: folder.file(.notes).path))?[.modificationDate] as? Date
            let summaryDate = (try? FileManager.default.attributesOfItem(atPath: folder.file(.summary).path))?[.modificationDate] as? Date
            notesChangedSinceSummary = if let notesDate, let summaryDate { notesDate > summaryDate } else { false }
            let segments = transcript?.segments ?? []
            var seen: [String] = []
            for segment in segments where segment.source == .system && segment.speaker != SpeakerNames.youID {
                if !seen.contains(segment.speaker) { seen.append(segment.speaker) }
            }
            callSpeakers = seen
            var clips: [String: ClipRange] = [:]
            for id in seen {
                if let clip = SpeakerClip.excerpt(speaker: id, segments: segments) {
                    clips[id] = ClipRange(start: clip.start, end: clip.end)
                }
            }
            speakerClips = clips
            let pairs = SpeakerLikeness.pairs(diarization?.embeddings ?? [:], order: seen)
            speakerAlike = Dictionary(uniqueKeysWithValues: pairs.map { ($0.source, $0) })
            moments = KeyMomentsBuilder.build(meta: meta, summary: summary, transcript: transcript,
                                              notes: notes, speakers: speakers, saved: savedMoments)
            pulse = ConversationPulse.compute(transcript: transcript, speakers: speakers,
                                              metaDuration: meta.effectiveDuration)
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
        wordCount = contents.wordCount
        originalAudioURLs = contents.originalAudioURLs
        hasSystemTrack = contents.hasSystemTrack
        reprocessStart = contents.reprocessStart
        notesChangedSinceSummary = contents.notesChangedSinceSummary
        callSpeakers = contents.callSpeakers
        speakerClips = contents.speakerClips
        speakerAlike = contents.speakerAlike
        savedMoments = contents.savedMoments
        moments = contents.moments
        pulse = contents.pulse
    }

    private func recomputeMomentsAndPulse() {
        moments = KeyMomentsBuilder.build(meta: meta, summary: summary, transcript: transcript,
                                          notes: notes, speakers: speakers, saved: savedMoments)
        pulse = ConversationPulse.compute(transcript: transcript, speakers: speakers,
                                          metaDuration: meta.effectiveDuration)
    }

    private func recomputeSpeakersDerived() {
        let segments = transcript?.segments ?? []
        var seen: [String] = []
        for segment in segments where segment.source == .system && segment.speaker != SpeakerNames.youID {
            if !seen.contains(segment.speaker) { seen.append(segment.speaker) }
        }
        callSpeakers = seen
        var clips: [String: ClipRange] = [:]
        for id in seen {
            if let clip = SpeakerClip.excerpt(speaker: id, segments: segments) {
                clips[id] = ClipRange(start: clip.start, end: clip.end)
            }
        }
        speakerClips = clips
        let pairs = SpeakerLikeness.pairs(diarization?.embeddings ?? [:], order: seen)
        speakerAlike = Dictionary(uniqueKeysWithValues: pairs.map { ($0.source, $0) })
        recomputeMomentsAndPulse()
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

    func setStartTime(_ newStartTime: Date) {
        guard meta.status != .recording, abs(newStartTime.timeIntervalSince(meta.startTime)) >= 1 else { return }
        let duration = max(0, meta.effectiveDuration)
        if let updated = try? folder.updateMeta({
            $0.startTime = newStartTime
            if $0.endTime != nil || duration > 0 {
                $0.endTime = newStartTime.addingTimeInterval(duration)
            }
        }) {
            meta = updated
            writeSummaryMarkdown()
        }
    }

    @discardableResult
    func setActionItem(_ item: ActionItem, done: Bool) -> String? {
        guard var summary, let index = summary.actionItems.firstIndex(where: { $0.id == item.id }) else { return item.reminderID }
        summary.actionItems[index].done = done
        let rid = summary.actionItems[index].reminderID
        self.summary = summary
        try? folder.write(summary, .summary)
        writeSummaryMarkdown()
        return rid
    }

    func updateActionItem(_ item: ActionItem,
                          owner: String?? = nil,
                          relatesToMe: Bool?? = nil,
                          dismissed: Bool? = nil) {
        guard var summary, let index = summary.actionItems.firstIndex(where: { $0.id == item.id }) else { return }
        if let owner { summary.actionItems[index].owner = owner }
        if let relatesToMe { summary.actionItems[index].relatesToMe = relatesToMe }
        if let dismissed { summary.actionItems[index].dismissed = dismissed }
        self.summary = summary
        try? folder.write(summary, .summary)
        writeSummaryMarkdown()
    }

    func updateActionItemReminder(_ item: ActionItem,
                                  reminderID: String?,
                                  listID: String?,
                                  listName: String?,
                                  pinned: Bool? = nil) {
        guard var summary, let index = summary.actionItems.firstIndex(where: { $0.id == item.id }) else { return }
        summary.actionItems[index].reminderID = reminderID
        summary.actionItems[index].reminderListID = listID
        summary.actionItems[index].reminderListName = listName
        if reminderID == nil {
            summary.actionItems[index].reminderListPinned = false
        } else if let pinned {
            summary.actionItems[index].reminderListPinned = pinned
        }
        self.summary = summary
        try? folder.write(summary, .summary)
    }

    func setRemindersList(id: String?, name: String?) {
        if let updated = try? folder.updateMeta({
            $0.remindersListID = id
            $0.remindersListName = name
        }) {
            meta = updated
        }
    }

    /// Renames one voice in this meeting. Other speaker ids are not touched.
    /// Clearing or resetting to a placeholder also unlearns this meeting speaker's voiceprint contribution.
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
        recomputeMomentsAndPulse()
        if SpeakerMemory.isPlaceholder(trimmed) {
            unlearnVoice(id)
        } else {
            rememberVoice(id, name: trimmed)
        }
    }

    func clearSpeakerName(_ id: String) {
        renameSpeaker(id, to: "")
    }

    /// Reassigns specific transcript segments (e.g. a misattributed turn) to another speaker ID
    /// without altering global voiceprints.
    func reassignSegments(at indices: IndexSet, toSpeakerID targetID: String) {
        guard var transcript, !indices.isEmpty else { return }
        var changed = false
        for i in indices where transcript.segments.indices.contains(i) {
            if transcript.segments[i].speaker != targetID {
                transcript.segments[i].speaker = targetID
                changed = true
            }
        }
        guard changed else { return }
        self.transcript = transcript
        try? folder.write(transcript, .transcript)
        writeTranscriptMarkdown()
        recomputeSpeakersDerived()
    }

    /// Splits selected transcript segments out into a new `speaker_N` ID when the diarizer
    /// merged two voices together.
    @discardableResult
    func splitSegmentsToNewSpeaker(at indices: IndexSet, named rawName: String) -> String? {
        guard var transcript, !indices.isEmpty else { return nil }
        let allIDs = Set(transcript.segments.map(\.speaker)).union(speakers.names.keys)
        var maxNum = 0
        for id in allIDs where id.hasPrefix("speaker_") {
            if let n = Int(id.dropFirst("speaker_".count)) {
                maxNum = max(maxNum, n)
            }
        }
        let newID = "speaker_\(maxNum + 1)"
        var changed = false
        for i in indices where transcript.segments.indices.contains(i) {
            transcript.segments[i].speaker = newID
            changed = true
        }
        guard changed else { return nil }

        self.transcript = transcript
        try? folder.write(transcript, .transcript)

        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !SpeakerMemory.isPlaceholder(trimmed) {
            speakers = speakers.renaming(newID, to: trimmed)
            try? folder.write(speakers, .speakers)
            upsertPersonProfile(name: trimmed)
        }
        writeTranscriptMarkdown()
        recomputeSpeakersDerived()
        return newID
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
        recomputeSpeakersDerived()
        if let name = speakers.names[target] { rememberVoice(target, name: name) }
    }

    /// How many voices to find on the call, besides you. Nil is automatic.
    func setExpectedCallSpeakers(_ count: Int?) {
        let clamped = count.flatMap { (1...12).contains($0) ? $0 : nil }
        if let updated = try? folder.updateMeta({ $0.expectedCallSpeakers = clamped }) { meta = updated }
    }

    /// Nil uses the Settings default for the next transcription of this meeting.
    func setTranscriptionEngine(_ engine: TranscriptionEngine?) {
        if let updated = try? folder.updateMeta({ $0.processing.requestedTranscriptionEngine = engine?.rawValue }) {
            meta = updated
        }
    }

    private func upsertPersonProfile(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !SpeakerMemory.isPlaceholder(trimmed) else { return }
        let meetingsDir = folder.url.deletingLastPathComponent()
        let peopleURL = PeopleFile.url(beside: meetingsDir)
        var store = PeopleFile.load(peopleURL)
        let nonDeclined = meta.calendarAttendees.filter { $0.status != .declined }
        let matchingAttendee: CalendarAttendee? = nonDeclined.first(where: { SpeakerMemory.namesMatch($0.name, trimmed) })
            ?? {
                let prefixHits = nonDeclined.filter { SpeakerMemory.namesPrefixMatch($0.name, trimmed) }
                return prefixHits.count == 1 ? prefixHits[0] : nil
            }()
        _ = store.upsert(
            name: trimmed,
            email: matchingAttendee?.email,
            organization: matchingAttendee?.inferredOrganization
        )
        try? PeopleFile.save(store, to: peopleURL)
    }

    private func rememberVoice(_ id: String, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !SpeakerMemory.isPlaceholder(trimmed) else { return }

        upsertPersonProfile(name: trimmed)

        guard let diarization = try? folder.read(Diarization.self, .diarization),
              let embedding = diarization.embeddings[id], !embedding.isEmpty else { return }
        let stretches = id == SpeakerNames.youID ? diarization.mic : diarization.system
        let seconds = stretches.filter { $0.speaker == id }.reduce(0) { $0 + $1.duration }
        let url = SpeakerMemoryFile.url(beside: folder)
        var memory = SpeakerMemoryFile.load(url)
        memory.remember(name: trimmed, embedding: embedding, seconds: seconds, sourceKey: "\(folder.id)::\(id)")
        try? SpeakerMemoryFile.save(memory, to: url)
    }

    private func unlearnVoice(_ id: String) {
        let url = SpeakerMemoryFile.url(beside: folder)
        var memory = SpeakerMemoryFile.load(url)
        memory.unlearn(sourceKey: "\(folder.id)::\(id)")
        try? SpeakerMemoryFile.save(memory, to: url)
    }

    func saveNotes(_ notes: [MeetingNote]) {
        let sorted = notes.sorted { $0.t < $1.t }
        self.notes = sorted
        try? NotesFile(url: folder.file(.notes)).save(sorted)
        if summary != nil { notesChangedSinceSummary = true }
        recomputeMomentsAndPulse()
        writeTranscriptMarkdown()
        writeSummaryMarkdown()
    }

    // MARK: - Key Moments & Calendar Linkage

    func addCustomMoment(title: String, kind: KeyMoment.Kind = .pinned, startTime: Double, endTime: Double? = nil) {
        var next = savedMoments
        next.custom.append(SavedMoments.CustomMoment(
            kind: kind,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            startTime: startTime,
            endTime: endTime
        ))
        persistMoments(next)
    }

    func toggleMomentStar(_ id: String) {
        var next = savedMoments
        if next.starredIDs.contains(id) {
            next.starredIDs.remove(id)
        } else {
            next.starredIDs.insert(id)
        }
        persistMoments(next)
    }

    func hideMoment(_ id: String) {
        var next = savedMoments
        if id.hasPrefix("custom:") {
            let rawID = String(id.dropFirst("custom:".count))
            next.custom.removeAll { $0.id == rawID }
        } else {
            next.hiddenIDs.insert(id)
        }
        persistMoments(next)
    }

    func renameMoment(_ id: String, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var next = savedMoments
        next.renamedTitles[id] = trimmed
        persistMoments(next)
    }

    private func persistMoments(_ next: SavedMoments) {
        savedMoments = next
        try? MomentsFile(url: folder.file(.moments)).save(next)
        recomputeMomentsAndPulse()
    }

    func linkCalendarEvent(_ event: CalendarMeeting) {
        if let updated = try? folder.updateMeta({
            $0.calendarEventID = event.id
            $0.calendarAttendees = event.attendees
            $0.calendarJoinURL = event.joinURL?.absoluteString
            $0.calendarName = event.calendarName
        }) {
            meta = updated
        }
    }

    private func writeTranscriptMarkdown() {
        guard let transcript else { return }
        let folder = folder
        let notes = notes
        let speakers = speakers
        let title = meta.title
        Task.detached(priority: .utility) {
            try? folder.writeText(TranscriptMarkdown.render(transcript, notes: notes, speakers: speakers,
                                                            title: title), .transcriptMarkdown)
        }
    }

    private func writeSummaryMarkdown() {
        guard let summary else { return }
        let folder = folder
        let meta = meta
        let notes = notes
        Task.detached(priority: .utility) {
            try? folder.writeText(SummaryMarkdown.render(summary, meta: meta, notes: notes), .summaryMarkdown)
        }
    }
}
