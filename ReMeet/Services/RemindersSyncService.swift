import AppKit
import EventKit
import Foundation
import Observation
import ReMeetKit

/// Two-way Apple Reminders integration via native macOS EventKit (`EKEventStore`).
/// Zero polling: listens to `.EKEventStoreChanged` for completions, list moves, and deletions
/// across Mac, iPhone, iPad, and Apple Watch via iCloud.
@MainActor
@Observable
final class RemindersSyncService {
    private(set) var availableLists: [ReminderListInfo] = []
    private(set) var isSyncing = false
    private(set) var lastSyncedAt: Date?
    private(set) var lastError: String?

    @ObservationIgnored var onExternalChange: (() -> Void)?
    @ObservationIgnored private let store = EKEventStore()
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var lastLocalWriteAt: Date = .distantPast

    static var hasAccess: Bool { EKEventStore.authorizationStatus(for: .reminder) == .fullAccess }
    static var notDetermined: Bool { EKEventStore.authorizationStatus(for: .reminder) == .notDetermined }
    static var accessDenied: Bool {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        return status == .denied || status == .restricted || status == .writeOnly
    }

    func requestAccess() async -> Bool {
        if Self.hasAccess {
            start()
            return true
        }
        NSApp.activate(ignoringOtherApps: true)
        do {
            let granted = try await store.requestFullAccessToReminders()
            lastError = nil
            if granted {
                start()
            }
            return granted
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func start() {
        stop()
        guard Self.hasAccess else { return }
        refreshLists()
        observer = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: store,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Suppress immediate echo from ReMeet's own EventKit saves.
                guard Date().timeIntervalSince(self.lastLocalWriteAt) > 0.5 else { return }
                self.debounceTask?.cancel()
                self.debounceTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(450))
                    guard !Task.isCancelled, let self else { return }
                    self.refreshLists()
                    self.onExternalChange?()
                }
            }
        }
    }

    func stop() {
        debounceTask?.cancel()
        debounceTask = nil
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        availableLists = []
    }

    func refreshLists() {
        guard Self.hasAccess else {
            availableLists = []
            return
        }
        let defaultID = store.defaultCalendarForNewReminders()?.calendarIdentifier
        let lists = store.calendars(for: .reminder)
            .filter(\.allowsContentModifications)
            .map { cal in
                ReminderListInfo(
                    id: cal.calendarIdentifier,
                    title: cal.title,
                    accountTitle: cal.source.title,
                    isDefault: cal.calendarIdentifier == defaultID
                )
            }
            .sorted { a, b in
                if a.isDefault != b.isDefault { return a.isDefault }
                if a.accountTitle != b.accountTitle { return a.accountTitle < b.accountTitle }
                return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            }
        availableLists = lists

        // First-time smart default: if a "Work" list already exists and no default was saved yet, select it.
        if UserDefaults.standard.string(forKey: SettingsKey.defaultRemindersListID) == nil,
           let research = lists.first(where: { $0.title.caseInsensitiveCompare("Work") == .orderedSame }) {
            UserDefaults.standard.set(research.id, forKey: SettingsKey.defaultRemindersListID)
            UserDefaults.standard.set(research.title, forKey: SettingsKey.defaultRemindersListName)
        }
    }

    func defaultListID() -> String? {
        store.defaultCalendarForNewReminders()?.calendarIdentifier ?? availableLists.first?.id
    }

    func list(forID id: String?) -> ReminderListInfo? {
        guard let id, !id.isEmpty else { return nil }
        return availableLists.first { $0.id == id }
    }

    func listNamed(_ name: String) -> ReminderListInfo? {
        availableLists.first { $0.title.caseInsensitiveCompare(name) == .orderedSame }
    }

    @discardableResult
    func createList(named title: String) -> ReminderListInfo? {
        guard Self.hasAccess else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let existing = listNamed(trimmed) { return existing }

        let cal = EKCalendar(for: .reminder, eventStore: store)
        cal.title = trimmed
        let preferredSource = store.defaultCalendarForNewReminders()?.source
            ?? store.sources.first(where: { $0.sourceType == .calDAV })
            ?? store.sources.first(where: { $0.sourceType == .local })
            ?? store.sources.first
        guard let preferredSource else {
            lastError = "No Apple Reminders account is available to host a new list."
            return nil
        }
        cal.source = preferredSource
        do {
            lastLocalWriteAt = Date()
            try store.saveCalendar(cal, commit: true)
            lastError = nil
            refreshLists()
            return availableLists.first { $0.id == cal.calendarIdentifier }
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Fetches live reminders directly from `remindd` after resetting EventKit's in-memory cache.
    private func fetchAllReminders() async -> [EKReminder] {
        guard Self.hasAccess else { return [] }
        store.reset()
        let predicate = store.predicateForReminders(in: nil)
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { fetched in
                continuation.resume(returning: fetched ?? [])
            }
        }
    }

    func prefetchReminderIndex() async -> [String: EKReminder] {
        let all = await fetchAllReminders()
        var map: [String: EKReminder] = [:]
        for rem in all {
            map[rem.calendarItemIdentifier] = rem
            if let ext = rem.calendarItemExternalIdentifier, !ext.isEmpty {
                map[ext] = rem
            }
        }
        return map
    }

    private func findReminder(matching id: String, in index: [String: EKReminder]? = nil) async -> EKReminder? {
        if let index, let hit = index[id] { return hit }
        let freshIndex = await prefetchReminderIndex()
        if let hit = freshIndex[id] { return hit }
        return store.calendarItem(withIdentifier: id) as? EKReminder
    }

    /// Creates or updates a single `EKReminder` for an action item. Never creates duplicates for linked items.
    func upsertReminder(item: ActionItem,
                        folder: MeetingFolder,
                        meta: MeetingMeta,
                        collection: MeetingCollection?,
                        targetListID: String?,
                        recorderName: String,
                        otherParticipantCount: Int,
                        prefetchedIndex: [String: EKReminder]? = nil) async -> (reminderID: String, listID: String, listName: String)? {
        guard Self.hasAccess else { return nil }
        let targetCalendar = resolveCalendar(preferredID: targetListID)
        guard let targetCalendar else {
            lastError = "No writable Apple Reminders list found."
            return nil
        }

        let reminder: EKReminder
        if let rid = item.reminderID,
           let existing = await findReminder(matching: rid, in: prefetchedIndex) {
            reminder = existing
        } else {
            reminder = EKReminder(eventStore: store)
        }

        let relevance = CommitmentsRadar.classifyRelevance(
            item,
            recorderName: recorderName,
            otherParticipantCount: otherParticipantCount
        )
        reminder.title = ReminderRouting.formatTitle(item: item, relevance: relevance)
        reminder.notes = ReminderRouting.formatNotes(
            meetingTitle: meta.title,
            meetingDate: meta.startTime,
            folderName: collection?.name,
            owner: item.owner,
            timestamp: item.t
        )
        reminder.url = ReminderRouting.deepLinkURL(folderID: folder.id, timestamp: item.t)
        reminder.dueDateComponents = ReminderDueDateParser.parse(item.due, relativeTo: meta.startTime)
        if reminder.isCompleted != item.done {
            reminder.isCompleted = item.done
            reminder.completionDate = item.done ? (reminder.completionDate ?? Date()) : nil
        }
        reminder.calendar = targetCalendar

        do {
            lastLocalWriteAt = Date()
            try store.save(reminder, commit: true)
            lastError = nil
            lastSyncedAt = Date()
            return (reminder.calendarItemIdentifier, targetCalendar.calendarIdentifier, targetCalendar.title)
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func syncCompletion(reminderID: String, done: Bool) async {
        guard Self.hasAccess,
              let rem = await findReminder(matching: reminderID) else { return }
        guard rem.isCompleted != done else { return }
        rem.isCompleted = done
        rem.completionDate = done ? Date() : nil
        do {
            lastLocalWriteAt = Date()
            try store.save(rem, commit: true)
            lastError = nil
            lastSyncedAt = Date()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func removeReminder(reminderID: String) async {
        guard Self.hasAccess,
              let rem = await findReminder(matching: reminderID) else { return }
        do {
            lastLocalWriteAt = Date()
            try store.remove(rem, commit: true)
            lastError = nil
            lastSyncedAt = Date()
        } catch {
            lastError = error.localizedDescription
        }
    }

    struct ReminderSnapshotState: Sendable {
        var exists: Bool
        var currentID: String
        var done: Bool
        var listID: String
        var listName: String
    }

    /// Pulls completion status, list moves, and external deletions from Apple Reminders back into `summary.json`.
    func pullChanges(folders: [MeetingFolder]) async -> [MeetingFolder] {
        guard Self.hasAccess else { return [] }
        isSyncing = true
        defer { isSyncing = false }

        let allReminders = await fetchAllReminders()
        var byID: [String: EKReminder] = [:]
        for rem in allReminders {
            byID[rem.calendarItemIdentifier] = rem
            if let ext = rem.calendarItemExternalIdentifier, !ext.isEmpty {
                byID[ext] = rem
            }
        }

        var stateByID: [String: ReminderSnapshotState] = [:]
        for (key, rem) in byID {
            stateByID[key] = ReminderSnapshotState(
                exists: true,
                currentID: rem.calendarItemIdentifier,
                done: rem.isCompleted,
                listID: rem.calendar.calendarIdentifier,
                listName: rem.calendar.title
            )
        }

        let states = stateByID
        let updatedFolders = await Task.detached(priority: .utility) { () -> [MeetingFolder] in
            var mutated: [MeetingFolder] = []
            for folder in folders {
                guard var summary = (try? folder.read(MeetingSummary.self, .summary)) ?? nil else { continue }
                var changed = false
                for idx in summary.actionItems.indices {
                    guard let rid = summary.actionItems[idx].reminderID else { continue }
                    guard let state = states[rid] else {
                        summary.actionItems[idx].reminderID = nil
                        summary.actionItems[idx].reminderListID = nil
                        summary.actionItems[idx].reminderListName = nil
                        summary.actionItems[idx].reminderListPinned = false
                        changed = true
                        continue
                    }
                    if summary.actionItems[idx].reminderID != state.currentID {
                        summary.actionItems[idx].reminderID = state.currentID
                        changed = true
                    }
                    if summary.actionItems[idx].done != state.done {
                        summary.actionItems[idx].done = state.done
                        changed = true
                    }
                    if summary.actionItems[idx].reminderListID != state.listID
                        || summary.actionItems[idx].reminderListName != state.listName {
                        summary.actionItems[idx].reminderListID = state.listID
                        summary.actionItems[idx].reminderListName = state.listName
                        // External move in Apple Reminders pins this item to its chosen list.
                        summary.actionItems[idx].reminderListPinned = true
                        changed = true
                    }
                }
                if changed {
                    try? folder.write(summary, .summary)
                    folder.rewriteMarkdown()
                    mutated.append(folder)
                }
            }
            return mutated
        }.value

        lastSyncedAt = Date()
        return updatedFolders
    }

    func openRemindersApp() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.reminders") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private func resolveCalendar(preferredID: String?) -> EKCalendar? {
        let writable = store.calendars(for: .reminder).filter(\.allowsContentModifications)
        if let preferredID, !preferredID.isEmpty,
           let match = writable.first(where: { $0.calendarIdentifier == preferredID }) {
            return match
        }
        if let def = store.defaultCalendarForNewReminders(), def.allowsContentModifications {
            return def
        }
        return writable.first
    }
}
