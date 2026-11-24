import AppKit
import EventKit
import Foundation
import Observation
import ReMeetKit

/// Source calendar metadata from macOS Calendar (iCloud, Google, Exchange, subscribed).
struct AppleCalendarInfo: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var accountTitle: String
}

/// Syncs meetings from BOTH macOS EventKit (Apple Calendar, iCloud, Google/Outlook Internet Accounts)
/// AND subscribed Google/iCal `.ics` feeds (`calendar-feeds.json`).
/// Fires pre-meeting reminders (1 minute before start), exposes the full multi-week schedule to the UI,
/// and notifies `onEventsUpdated` so People profiles and recorded meetings link automatically.
@MainActor
@Observable
final class CalendarWatcher {
    @ObservationIgnored var onReminder: ((CalendarMeeting) -> Void)?
    @ObservationIgnored var onEventsUpdated: (([CalendarMeeting]) -> Void)?

    private(set) var events: [CalendarMeeting] = []
    private(set) var availableCalendars: [AppleCalendarInfo] = []
    private(set) var icsFeeds: [ICSFeedSubscription] = []
    private(set) var isSyncingICS = false
    private(set) var lastSyncedAt: Date?

    @ObservationIgnored private let store = EKEventStore()
    @ObservationIgnored private var reminded: Set<String> = []
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var icsTimer: Task<Void, Never>?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var cachedICSEvents: [String: [CalendarMeeting]] = [:]

    var storageRoot: URL = MeetingFolder.defaultRoot {
        didSet {
            if storageRoot != oldValue {
                loadFeedsAndCache()
            }
        }
    }

    /// Self-tests and snapshots set this to feed synthetic events without touching the real calendar.
    @ObservationIgnored var source: (() -> [CalendarMeeting])?

    private static let disabledCalendarsKey = "disabledAppleCalendarIDs"
    static let lookbackSeconds: TimeInterval = 14 * 86_400
    static let lookaheadSeconds: TimeInterval = 30 * 86_400

    static var hasAccess: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }
    static var notDetermined: Bool { EKEventStore.authorizationStatus(for: .event) == .notDetermined }
    static var accessDenied: Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        return status == .denied || status == .restricted || status == .writeOnly
    }

    init() {
        loadFeedsAndCache()
    }

    // MARK: - Permissions & Lifecycle

    /// Asks for Calendar access (once; macOS remembers the answer). Returns whether granted.
    func requestAccess() async -> Bool {
        if Self.hasAccess { return true }
        return (try? await store.requestFullAccessToEvents()) ?? false
    }

    func start() {
        stopTimersAndObservers()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload(syncICS: false) }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload(syncICS: true) }
        })
        reload(syncICS: true)
        startPeriodicICSSync()
    }

    func stop() {
        stopTimersAndObservers()
        events = []
    }

    private func stopTimersAndObservers() {
        timer?.cancel()
        timer = nil
        icsTimer?.cancel()
        icsTimer = nil
        reloadTask?.cancel()
        reloadTask = nil
        observers.forEach {
            NotificationCenter.default.removeObserver($0)
            NSWorkspace.shared.notificationCenter.removeObserver($0)
        }
        observers = []
    }

    // MARK: - Calendar Filtering & ICS Feed Subscriptions

    var disabledCalendarIDs: Set<String> {
        get {
            let list = UserDefaults.standard.stringArray(forKey: Self.disabledCalendarsKey) ?? []
            return Set(list)
        }
        set {
            UserDefaults.standard.set(Array(newValue).sorted(), forKey: Self.disabledCalendarsKey)
            reload(syncICS: false)
        }
    }

    func isCalendarEnabled(_ id: String) -> Bool {
        !disabledCalendarIDs.contains(id)
    }

    func setCalendarEnabled(_ id: String, enabled: Bool) {
        var disabled = disabledCalendarIDs
        if enabled { disabled.remove(id) } else { disabled.insert(id) }
        disabledCalendarIDs = disabled
    }

    private var feedsFile: ICSFeedsFile {
        ICSFeedsFile(url: ICSFeedsFile.url(beside: storageRoot))
    }

    private var icsCacheURL: URL {
        storageRoot.deletingLastPathComponent().appendingPathComponent("calendar-ics-cache.json")
    }

    private func loadFeedsAndCache() {
        icsFeeds = feedsFile.load()
        cachedICSEvents = (try? JSONCoding.read([String: [CalendarMeeting]].self, from: icsCacheURL)) ?? [:]
    }

    private func saveFeeds() {
        try? feedsFile.save(icsFeeds)
    }

    private func saveICSCache() {
        try? JSONCoding.write(cachedICSEvents, to: icsCacheURL)
    }

    @discardableResult
    func addICSFeed(name: String = "", urlString: String) -> Bool {
        let normalized = ICSFeedSubscription.normalizeURLString(urlString)
        guard let url = URL(string: normalized),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            return false
        }
        if icsFeeds.contains(where: { $0.urlString.caseInsensitiveCompare(normalized) == .orderedSame }) {
            syncICSFeedsNow()
            return true
        }
        let sub = ICSFeedSubscription(name: name, urlString: normalized)
        icsFeeds.append(sub)
        saveFeeds()
        syncICSFeedsNow()
        return true
    }

    func removeICSFeed(_ id: String) {
        icsFeeds.removeAll { $0.id == id }
        cachedICSEvents.removeValue(forKey: id)
        saveFeeds()
        saveICSCache()
        reload(syncICS: false)
    }

    func toggleICSFeed(_ id: String, enabled: Bool) {
        guard let idx = icsFeeds.firstIndex(where: { $0.id == id }) else { return }
        icsFeeds[idx].isEnabled = enabled
        saveFeeds()
        if enabled { syncICSFeedsNow() } else { reload(syncICS: false) }
    }

    func syncICSFeedsNow() {
        reload(syncICS: true)
    }

    private func startPeriodicICSSync() {
        icsTimer?.cancel()
        guard source == nil else { return }
        icsTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15 * 60))
                guard !Task.isCancelled, let self else { return }
                if self.icsFeeds.contains(where: \.isEnabled) {
                    self.reload(syncICS: true)
                }
            }
        }
    }

    // MARK: - Queries & Matching

    /// The calendar meeting a call detected now belongs to, if any.
    func eventForCall(at date: Date = Date()) -> CalendarMeeting? {
        MeetingReminder.event(forCallAt: date, in: events)
    }

    /// Upcoming online meetings from `now` onward (recognized video/call platforms only).
    func upcomingMeetings(from now: Date = Date(), limit: Int = 20) -> [CalendarMeeting] {
        Array(
            events
                .filter { MeetingReminder.hasOnlineMeetingPlatform($0) && $0.end > now }
                .sorted { $0.start < $1.start }
                .prefix(limit)
        )
    }

    /// The next online meeting starting within `withinHours` (or currently in progress), for Menu Bar / Sidebar quick access.
    func upNext(at now: Date = Date(), withinHours: Double = 8) -> CalendarMeeting? {
        events
            .filter { MeetingReminder.hasOnlineMeetingPlatform($0) && $0.end > now && $0.start.timeIntervalSince(now) <= withinHours * 3600 }
            .min { $0.start < $1.start }
    }

    /// The user is already recording (or chose Record from the mic prompt): no reminder for it.
    func markReminded(_ id: String) {
        reminded.insert(id)
        schedule()
    }

    // MARK: - Loading & Merging

    func reload(syncICS: Bool = false) {
        reloadTask?.cancel()
        if let source {
            let synthetic = source()
            events = synthetic
            schedule()
            onEventsUpdated?(synthetic)
            return
        }

        let hasEK = Self.hasAccess
        let store = self.store
        let disabled = self.disabledCalendarIDs
        let enabledFeeds = self.icsFeeds.filter(\.isEnabled)
        let shouldFetchNetworkICS = syncICS && !enabledFeeds.isEmpty
        if shouldFetchNetworkICS { isSyncingICS = true }

        let existingCache = self.cachedICSEvents

        reloadTask = Task { [weak self] in
            let now = Date()
            let windowStart = now.addingTimeInterval(-Self.lookbackSeconds)
            let windowEnd = now.addingTimeInterval(Self.lookaheadSeconds)

            // 1. Read EventKit off the main thread.
            let ekResult: (calendars: [AppleCalendarInfo], events: [CalendarMeeting]) = await Task.detached(priority: .utility) {
                guard hasEK else { return ([], []) }
                let allCals = store.calendars(for: .event)
                let infos = allCals.map {
                    AppleCalendarInfo(id: $0.calendarIdentifier, title: $0.title, accountTitle: $0.source.title)
                }.sorted {
                    if $0.accountTitle != $1.accountTitle { return $0.accountTitle < $1.accountTitle }
                    return $0.title < $1.title
                }
                let activeCals = allCals.filter { !disabled.contains($0.calendarIdentifier) }
                guard !activeCals.isEmpty else { return (infos, []) }
                let predicate = store.predicateForEvents(withStart: windowStart, end: windowEnd, calendars: activeCals)
                let mapped = store.events(matching: predicate).map(Self.meeting)
                return (infos, mapped)
            }.value

            guard !Task.isCancelled, let self else { return }
            self.availableCalendars = ekResult.calendars

            // 2. Combine with cached ICS events immediately so UI never waits on network.
            let cachedFlat = enabledFeeds.flatMap { existingCache[$0.id] ?? [] }
            let initialMerged = MeetingReminder.deduplicate(ekResult.events + cachedFlat)
            if initialMerged != self.events {
                self.events = initialMerged
            }
            self.lastSyncedAt = Date()
            self.schedule()
            self.onEventsUpdated?(initialMerged)

            // 3. Refresh remote Google/iCal `.ics` feeds in background when requested.
            guard shouldFetchNetworkICS else {
                self.isSyncingICS = false
                return
            }

            var updatedFeeds = self.icsFeeds
            var updatedCache = self.cachedICSEvents
            for feed in enabledFeeds {
                guard !Task.isCancelled else { break }
                guard let url = feed.resolvedURL else {
                    if let idx = updatedFeeds.firstIndex(where: { $0.id == feed.id }) {
                        updatedFeeds[idx].lastError = "Invalid URL"
                    }
                    continue
                }
                do {
                    var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
                    req.setValue("ReMeet/1.0", forHTTPHeaderField: "User-Agent")
                    let (data, response) = try await URLSession.shared.data(for: req)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        throw URLError(.badServerResponse)
                    }
                    let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
                    let fallback = feed.name.isEmpty ? "Calendar (.ics)" : feed.name
                    let parsed = await Task.detached(priority: .utility) {
                        ICalendarParser.parse(text, windowStart: windowStart, windowEnd: windowEnd,
                                              fallbackCalendarName: fallback)
                    }.value
                    updatedCache[feed.id] = parsed.events
                    if let idx = updatedFeeds.firstIndex(where: { $0.id == feed.id }) {
                        if updatedFeeds[idx].name.isEmpty, let calName = parsed.calendarName, !calName.isEmpty {
                            updatedFeeds[idx].name = calName
                        }
                        updatedFeeds[idx].lastSyncedAt = Date()
                        updatedFeeds[idx].lastEventCount = parsed.events.count
                        updatedFeeds[idx].lastError = nil
                    }
                } catch {
                    if let idx = updatedFeeds.firstIndex(where: { $0.id == feed.id }) {
                        updatedFeeds[idx].lastError = error.localizedDescription
                    }
                }
            }

            guard !Task.isCancelled else { return }
            self.icsFeeds = updatedFeeds
            self.cachedICSEvents = updatedCache
            self.isSyncingICS = false
            self.lastSyncedAt = Date()
            self.saveFeeds()
            self.saveICSCache()

            let finalICS = updatedFeeds.filter(\.isEnabled).flatMap { updatedCache[$0.id] ?? [] }
            let finalMerged = MeetingReminder.deduplicate(ekResult.events + finalICS)
            if finalMerged != self.events {
                self.events = finalMerged
            }
            self.schedule()
            self.onEventsUpdated?(finalMerged)
        }
    }

    private func schedule() {
        timer?.cancel()
        guard UserDefaults.standard.bool(forKey: SettingsKey.remindBeforeCalendarMeetings) else { return }
        let now = Date()
        let refresh = now.addingTimeInterval(6 * 3600)
        let next = MeetingReminder.nextOnlineMeeting(events, now: now, reminded: reminded)
        let fireAt = min(next?.fireAt ?? refresh, refresh)
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, fireAt.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self else { return }
            if let next, fireAt == next.fireAt {
                self.reminded.insert(next.event.id)
                self.onReminder?(next.event)
                self.schedule()
            } else {
                self.reload(syncICS: true)
            }
        }
    }

    private nonisolated static func meeting(_ event: EKEvent) -> CalendarMeeting {
        let others = (event.attendees ?? []).filter { !$0.isCurrentUser }
        let me = event.attendees?.first { $0.isCurrentUser }
        let link = [event.url?.absoluteString, event.location, event.notes].compactMap { $0 }.joined(separator: "\n")
        let structuredAttendees: [CalendarAttendee] = others.compactMap { participant in
            let rawURL = participant.url.absoluteString
            let email = rawURL.lowercased().hasPrefix("mailto:") ? String(rawURL.dropFirst("mailto:".count)) : nil
            let status: CalendarAttendee.Status = switch participant.participantStatus {
            case .accepted: .accepted
            case .tentative: .tentative
            case .declined: .declined
            default: .pending
            }
            let att = CalendarAttendee(
                name: participant.name ?? "",
                email: email,
                isOrganizer: participant.participantRole == .chair,
                status: status
            )
            return att.name.isEmpty ? nil : att
        }
        let calTitle = event.calendar.map { cal in
            cal.source.title.isEmpty ? cal.title : "\(cal.title) (\(cal.source.title))"
        }
        let externalUID = event.calendarItemExternalIdentifier ?? event.eventIdentifier
        return CalendarMeeting(
            id: (externalUID ?? UUID().uuidString) + "@\(event.startDate.timeIntervalSince1970)",
            uid: externalUID,
            title: (event.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            start: event.startDate,
            end: event.endDate,
            isAllDay: event.isAllDay,
            attendees: structuredAttendees,
            declined: me?.participantStatus == .declined,
            linkText: link,
            notes: (event.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            calendarName: calTitle,
            sourceKind: .appleCalendar,
            organizerName: event.organizer?.name
        )
    }
}
