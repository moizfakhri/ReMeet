import Foundation
import Observation
import ReMeetKit

/// Coordinates off-main indexing of People, Key Moments, Commitments, and Calendar linkage
/// across the meeting library so tabs render instantaneously with 0% idle CPU.
@MainActor
@Observable
final class HubCoordinator {
    private(set) var people: [PersonSummary] = []
    private(set) var moments: [GlobalMomentItem] = []
    private(set) var commitments: [CommitmentItem] = []
    private(set) var snapshotsByID: [String: MeetingSnapshot] = [:]

    @ObservationIgnored var onMeetingMutated: ((MeetingFolder) -> Void)?
    @ObservationIgnored private var meetingsRoot: URL = MeetingFolder.defaultRoot
    @ObservationIgnored private var calendarEvents: [CalendarMeeting] = []
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    func configure(root: URL) {
        if meetingsRoot != root {
            meetingsRoot = root
            snapshotsByID = [:]
        }
    }

    var peopleFileURL: URL { PeopleFile.url(beside: meetingsRoot) }
    var voiceprintsURL: URL { meetingsRoot.deletingLastPathComponent().appendingPathComponent("voiceprints.json") }

    /// Full scan on launch or storage folder switch, off the main thread.
    func reloadAll(items: [MeetingItem], calendarEvents: [CalendarMeeting], recorderName: String) {
        self.calendarEvents = calendarEvents
        generation += 1
        let myGen = generation
        let peopleURL = peopleFileURL
        let voiceURL = voiceprintsURL
        let folders = items.filter { $0.meta.status != .recording }.map(\.folder)

        refreshTask?.cancel()
        refreshTask = Task {
            let computed = await Task.detached(priority: .utility) { () -> (
                snaps: [String: MeetingSnapshot],
                people: [PersonSummary],
                moments: [GlobalMomentItem],
                commitments: [CommitmentItem],
                linkedFolders: [MeetingFolder]
            ) in
                var linked: [MeetingFolder] = []
                var snaps: [String: MeetingSnapshot] = [:]
                for folder in folders {
                    // Retroactively link unlinked meetings to matching calendar invites (non-destructively).
                    if let meta = try? folder.readMeta(),
                       meta.calendarEventID == nil,
                       meta.calendarAttendees.isEmpty,
                       let matched = MeetingReminder.matchingEvent(startTime: meta.startTime, title: meta.title, in: calendarEvents) {
                        _ = try? folder.updateMeta {
                            $0.calendarEventID = matched.id
                            $0.calendarAttendees = matched.attendees
                            $0.calendarJoinURL = matched.joinURL?.absoluteString
                            $0.calendarName = matched.calendarName
                        }
                        linked.append(folder)
                    }
                    if let snap = MeetingSnapshot.read(folder) {
                        snaps[folder.id] = snap
                    }
                }
                let orderedSnaps = snaps.values.sorted { $0.meta.startTime > $1.meta.startTime }
                var store = PeopleFile.load(peopleURL)
                let seeded = store.ingestCalendarEvents(calendarEvents, recorderName: recorderName)
                if seeded { try? PeopleFile.save(store, to: peopleURL) }
                let memory = SpeakerMemoryFile.load(voiceURL)
                let peopleList = PeopleDirectory.build(
                    store: store,
                    memory: memory,
                    snapshots: orderedSnaps,
                    calendarEvents: calendarEvents,
                    recorderName: recorderName
                )
                let globalMoments = Self.flattenMoments(from: orderedSnaps)
                let radar = CommitmentsRadar.build(from: orderedSnaps, recorderName: recorderName)
                return (snaps, peopleList, globalMoments, radar, linked)
            }.value

            guard !Task.isCancelled, myGen == self.generation else { return }
            self.snapshotsByID = computed.snaps
            self.people = computed.people
            self.moments = computed.moments
            self.commitments = computed.commitments
            for folder in computed.linkedFolders {
                self.onMeetingMutated?(folder)
            }
        }
    }

    /// Incremental refresh when a single meeting finishes a stage, is renamed, or has notes/speakers edited.
    func refreshMeeting(_ folder: MeetingFolder, recorderName: String) {
        let peopleURL = peopleFileURL
        let voiceURL = voiceprintsURL
        let calEvents = calendarEvents
        let existing = snapshotsByID

        Task {
            let updatedSnap = await Task.detached(priority: .utility) { MeetingSnapshot.read(folder) }.value
            var nextMap = existing
            if let updatedSnap, updatedSnap.meta.status != .recording {
                nextMap[folder.id] = updatedSnap
            } else {
                nextMap.removeValue(forKey: folder.id)
            }
            self.snapshotsByID = nextMap
            await self.recomputeDerived(snapshotsMap: nextMap, calendarEvents: calEvents,
                                        peopleURL: peopleURL, voiceURL: voiceURL, recorderName: recorderName)
        }
    }

    func removeMeeting(_ folder: MeetingFolder, recorderName: String) {
        snapshotsByID.removeValue(forKey: folder.id)
        let nextMap = snapshotsByID
        let peopleURL = peopleFileURL
        let voiceURL = voiceprintsURL
        let calEvents = calendarEvents
        Task {
            await self.recomputeDerived(snapshotsMap: nextMap, calendarEvents: calEvents,
                                        peopleURL: peopleURL, voiceURL: voiceURL, recorderName: recorderName)
        }
    }

    func updateCalendarEvents(_ events: [CalendarMeeting], items: [MeetingItem], recorderName: String) {
        calendarEvents = events
        // If we haven't indexed snapshots yet or new events can link to existing meetings, run full lightweight pass.
        reloadAll(items: items, calendarEvents: events, recorderName: recorderName)
    }

    private func recomputeDerived(snapshotsMap: [String: MeetingSnapshot],
                                  calendarEvents: [CalendarMeeting],
                                  peopleURL: URL,
                                  voiceURL: URL,
                                  recorderName: String) async {
        let result = await Task.detached(priority: .utility) { () -> ([PersonSummary], [GlobalMomentItem], [CommitmentItem]) in
            let orderedSnaps = snapshotsMap.values.sorted { $0.meta.startTime > $1.meta.startTime }
            let store = PeopleFile.load(peopleURL)
            let memory = SpeakerMemoryFile.load(voiceURL)
            let peopleList = PeopleDirectory.build(
                store: store,
                memory: memory,
                snapshots: orderedSnaps,
                calendarEvents: calendarEvents,
                recorderName: recorderName
            )
            let globalMoments = Self.flattenMoments(from: orderedSnaps)
            let radar = CommitmentsRadar.build(from: orderedSnaps, recorderName: recorderName)
            return (peopleList, globalMoments, radar)
        }.value

        self.people = result.0
        self.moments = result.1
        self.commitments = result.2
    }

    nonisolated private static func flattenMoments(from snapshots: [MeetingSnapshot]) -> [GlobalMomentItem] {
        var out: [GlobalMomentItem] = []
        for snap in snapshots {
            let hasAudio = snap.folder.exists(.audio)
            for moment in snap.moments {
                out.append(GlobalMomentItem(
                    folder: snap.folder,
                    meetingTitle: snap.meta.title,
                    meetingDate: snap.meta.startTime,
                    collectionID: snap.meta.collectionID,
                    hasAudio: hasAudio,
                    moment: moment
                ))
            }
        }
        return out
    }

    // MARK: - Prep Briefs

    func prepBrief(for event: CalendarMeeting, recorderName: String) -> MeetingPrepBrief {
        let orderedSnaps = snapshotsByID.values.sorted { $0.meta.startTime > $1.meta.startTime }
        return MeetingPrepBrief.build(
            for: event,
            snapshots: orderedSnaps,
            people: people,
            recorderName: recorderName
        )
    }

    // MARK: - People Management

    @discardableResult
    func createPerson(name: String, email: String?, role: String?, organization: String?, notes: String,
                      recorderName: String) -> PersonProfile? {
        var store = PeopleFile.load(peopleFileURL)
        guard let created = store.upsert(name: name, email: email, role: role, organization: organization, notes: notes) else {
            return nil
        }
        try? PeopleFile.save(store, to: peopleFileURL)
        Task {
            await recomputeDerived(snapshotsMap: snapshotsByID, calendarEvents: calendarEvents,
                                   peopleURL: peopleFileURL, voiceURL: voiceprintsURL, recorderName: recorderName)
        }
        return created
    }

    func updatePerson(id: String, name: String, email: String?, role: String?, organization: String?, notes: String,
                      recorderName: String) {
        var store = PeopleFile.load(peopleFileURL)
        let result: (oldName: String, updated: PersonProfile)?
        if let updated = store.update(id, name: name, email: email, role: role, organization: organization, notes: notes) {
            result = updated
        } else if let created = store.upsert(name: name, email: email, role: role, organization: organization, notes: notes) {
            result = (name, created)
        } else {
            return
        }
        try? PeopleFile.save(store, to: peopleFileURL)

        // If the person's display name changed, keep their voiceprint and meeting speaker labels in step!
        if let result, result.oldName.caseInsensitiveCompare(result.updated.name) != .orderedSame {
            propagatePersonRename(from: result.oldName, to: result.updated.name, recorderName: recorderName)
        } else {
            Task {
                await recomputeDerived(snapshotsMap: snapshotsByID, calendarEvents: calendarEvents,
                                       peopleURL: peopleFileURL, voiceURL: voiceprintsURL, recorderName: recorderName)
            }
        }
    }

    func mergePeople(sourceID: String, into targetID: String, recorderName: String) {
        var store = PeopleFile.load(peopleFileURL)
        // Materialize implicit profiles if needed first so merge always succeeds.
        for summary in people where summary.id == sourceID || summary.id == targetID {
            if !store.profiles.contains(where: { $0.id == summary.id }) {
                store.profiles.append(summary.profile)
            }
        }
        guard let merged = store.merge(sourceID: sourceID, into: targetID) else { return }
        try? PeopleFile.save(store, to: peopleFileURL)
        propagatePersonRename(from: merged.sourceName, to: merged.target.name, recorderName: recorderName)
    }

    func deletePerson(_ person: PersonSummary, removeVoiceprint: Bool = true, recorderName: String) {
        var store = PeopleFile.load(peopleFileURL)
        store.profiles.removeAll { $0.id == person.id || $0.matchesName(person.profile.name) }
        try? PeopleFile.save(store, to: peopleFileURL)
        if removeVoiceprint {
            var memory = SpeakerMemoryFile.load(voiceprintsURL)
            memory.forgetVoice(named: person.profile.name)
            try? SpeakerMemoryFile.save(memory, to: voiceprintsURL)
        }
        Task {
            await recomputeDerived(snapshotsMap: snapshotsByID, calendarEvents: calendarEvents,
                                   peopleURL: peopleFileURL, voiceURL: voiceprintsURL, recorderName: recorderName)
        }
    }

    func forgetVoiceprint(for person: PersonSummary, recorderName: String) {
        var memory = SpeakerMemoryFile.load(voiceprintsURL)
        memory.forgetVoice(named: person.profile.name)
        for alias in person.profile.aliases { memory.forgetVoice(named: alias) }
        try? SpeakerMemoryFile.save(memory, to: voiceprintsURL)
        Task {
            await recomputeDerived(snapshotsMap: snapshotsByID, calendarEvents: calendarEvents,
                                   peopleURL: peopleFileURL, voiceURL: voiceprintsURL, recorderName: recorderName)
        }
    }

    private func propagatePersonRename(from oldName: String, to newName: String, recorderName: String) {
        let voiceURL = voiceprintsURL
        let folders = Array(snapshotsByID.values.map(\.folder))
        Task {
            let touched = await Task.detached(priority: .utility) { () -> [MeetingFolder] in
                var memory = SpeakerMemoryFile.load(voiceURL)
                memory.renameVoice(from: oldName, to: newName)
                try? SpeakerMemoryFile.save(memory, to: voiceURL)

                var changed: [MeetingFolder] = []
                for folder in folders {
                    guard var speakers = (try? folder.read(SpeakerNames.self, .speakers)) ?? nil else { continue }
                    var didChange = false
                    for (id, label) in speakers.names where label.caseInsensitiveCompare(oldName) == .orderedSame {
                        speakers.names[id] = newName
                        didChange = true
                    }
                    guard didChange else { continue }
                    try? folder.write(speakers, .speakers)
                    if var summary = (try? folder.read(MeetingSummary.self, .summary)) ?? nil {
                        for idx in summary.actionItems.indices where summary.actionItems[idx].owner?.caseInsensitiveCompare(oldName) == .orderedSame {
                            summary.actionItems[idx].owner = newName
                        }
                        try? folder.write(summary, .summary)
                    }
                    folder.rewriteMarkdown()
                    changed.append(folder)
                }
                return changed
            }.value

            for folder in touched {
                if let snap = MeetingSnapshot.read(folder) {
                    self.snapshotsByID[folder.id] = snap
                }
                self.onMeetingMutated?(folder)
            }
            await self.recomputeDerived(snapshotsMap: self.snapshotsByID, calendarEvents: self.calendarEvents,
                                        peopleURL: self.peopleFileURL, voiceURL: self.voiceprintsURL,
                                        recorderName: recorderName)
        }
    }
}
