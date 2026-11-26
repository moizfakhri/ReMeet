import Foundation
import Testing
@testable import ReMeetKit

@Suite struct PeopleDeduplicationTests {
    @Test func parsesTeamsLastFirstAllCapsHonorificsAndSuffixes() {
        let p1 = PersonName.parse("Patel, Priya R")
        #expect(p1.canonicalDisplayName == "Priya R Patel")
        #expect(p1.first == "Priya")
        #expect(p1.last == "Patel")

        let p2 = PersonName.parse("THOMPSON, MORGAN")
        #expect(p2.canonicalDisplayName == "Morgan Thompson")

        let p3 = PersonName.parse("Dr. Patel")
        #expect(p3.isHonorificLastName == true)
        #expect(p3.honorific == "Dr.")
        #expect(p3.last == "Patel")
        #expect(p3.canonicalDisplayName == "Dr. Patel")

        let p4 = PersonName.parse("Maya Lin (External)")
        #expect(p4.canonicalDisplayName == "Maya Lin")

        let p5 = PersonName.parse("John Smith, Jr.")
        #expect(p5.canonicalDisplayName == "John Smith")
    }

    @Test func matchesHonorificFirstNamesAndPrefixesAcrossFormats() {
        #expect(SpeakerMemory.namesMatch("Dr. Patel", "Patel, Priya R"))
        #expect(SpeakerMemory.namesMatch("Elena", "Chen, Elena"))
        #expect(SpeakerMemory.namesMatch("Jordan", "Kim, Jordan R"))
        #expect(SpeakerMemory.namesMatch("Marco", "Reyes, Marco Antonio G"))
        #expect(SpeakerMemory.namesMatch("Morgan Thompson", "THOMPSON, MORGAN"))

        #expect(SpeakerMemory.namesPrefixMatch("Alex", "Alvarez, Alexander J"))
        #expect(!SpeakerMemory.namesMatch("Tom Chen", "Chen, Elena"))
    }

    @Test func consolidatesExistingDuplicatesAndRefusesAmbiguousMerges() {
        var store = PeopleStore(profiles: [
            PersonProfile(name: "Patel, Priya R", email: "priya.patel@example.edu", organization: "Example"),
            PersonProfile(name: "Dr. Patel", notes: "Team Lead"),
            PersonProfile(name: "Chen, Elena", email: "elena.chen@example.edu"),
            PersonProfile(name: "Elena"),
            PersonProfile(name: "Alvarez, Alexander J", email: "alex.alvarez@example.edu"),
            PersonProfile(name: "Alex"),
            // Ambiguous two Jordans: "Jordan" must NOT auto-merge into either!
            PersonProfile(name: "Kim, Jordan R", email: "jordan.kim@example.edu"),
            PersonProfile(name: "Brooks, Jordan E", email: "jordan.brooks@example.edu"),
            PersonProfile(name: "Jordan"),
        ])

        let changed = store.consolidateDuplicates()
        #expect(changed == true)

        let priya = store.profiles.first { $0.email == "priya.patel@example.edu" }
        #expect(priya?.name == "Dr. Priya R Patel")
        #expect(priya?.notes == "Team Lead")
        #expect(priya?.aliases.contains("Dr. Patel") == true)

        let elena = store.profiles.filter { $0.email == "elena.chen@example.edu" }
        #expect(elena.count == 1)
        #expect(elena[0].name == "Elena Chen")
        #expect(elena[0].aliases.contains("Elena") == true)

        let alex = store.profiles.filter { $0.email == "alex.alvarez@example.edu" }
        #expect(alex.count == 1)
        #expect(alex[0].name == "Alexander J Alvarez")
        #expect(alex[0].aliases.contains("Alex") == true)

        // Ambiguous "Jordan" remains separate until user chooses, and surfaces as possible duplicate.
        let standaloneJordan = store.profiles.first { $0.name == "Jordan" }
        #expect(standaloneJordan != nil)
        if let id = standaloneJordan?.id {
            #expect(store.possibleDuplicates(for: id).count == 2)
        }
    }

    @Test func pulseCombinesDuplicateSpeakerIDsSharingSameName() {
        let transcript = Transcript(engine: "test", segments: [
            TranscriptSegment(start: 0, end: 10, speaker: "speaker_1", text: "Hello team", source: .system),
            TranscriptSegment(start: 10, end: 25, speaker: "speaker_2", text: "Let's check SQL logs", source: .system),
            TranscriptSegment(start: 25, end: 35, speaker: "you", text: "Sounds good", source: .mic),
        ])
        let speakers = SpeakerNames(names: [
            "speaker_1": "Dr. Nguyen",
            "speaker_2": "Dr. Nguyen",
        ])
        let pulse = ConversationPulse.compute(transcript: transcript, speakers: speakers, metaDuration: 35)
        #expect(pulse.shares.count == 2)
        let nguyen = pulse.shares.first { $0.name == "Dr. Nguyen" }
        #expect(nguyen?.seconds == 25)
        #expect(nguyen?.turns == 2)
    }
}

@Suite struct RemindersRoutingAndDueDateTests {
    @Test func parsesNaturalLanguageDueDatesRelativeToMeeting() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        // Wednesday, Nov 25, 2026
        let ref = cal.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 14, minute: 0))!

        let today = ReminderDueDateParser.parse("EOD", relativeTo: ref, calendar: cal)
        #expect(today?.year == 2026 && today?.month == 11 && today?.day == 25)

        let tomorrow = ReminderDueDateParser.parse("by tomorrow", relativeTo: ref, calendar: cal)
        #expect(tomorrow?.month == 11 && tomorrow?.day == 26)

        let fri = ReminderDueDateParser.parse("Fri", relativeTo: ref, calendar: cal)
        #expect(fri?.month == 11 && fri?.day == 27)

        let nextMon = ReminderDueDateParser.parse("next Monday", relativeTo: ref, calendar: cal)
        #expect(nextMon?.month == 11 && nextMon?.day == 30)

        let explicit = ReminderDueDateParser.parse("by Dec 4", relativeTo: ref, calendar: cal)
        #expect(explicit?.month == 12 && explicit?.day == 4)

        let iso = ReminderDueDateParser.parse("2026-12-10", relativeTo: ref, calendar: cal)
        #expect(iso?.year == 2026 && iso?.month == 12 && iso?.day == 10)

        #expect(ReminderDueDateParser.parse("ASAP", relativeTo: ref, calendar: cal) == nil)
    }

    @Test func resolvesRoutingHierarchyAndDeepLinks() throws {
        let workFolder = MeetingCollection(name: "Core Projects", remindersListID: "list-work", remindersListName: "Work")
        let mutedFolder = MeetingCollection(name: "Personal", remindersDisabled: true)

        #expect(ReminderRouting.resolveListID(
            itemListID: "list-custom",
            meetingListID: "list-meeting",
            folder: workFolder,
            globalDefaultListID: "list-global",
            fallbackListID: "list-sys"
        ) == "list-custom")

        #expect(ReminderRouting.resolveListID(
            itemListID: nil,
            meetingListID: "list-meeting",
            folder: workFolder,
            globalDefaultListID: "list-global",
            fallbackListID: "list-sys"
        ) == "list-meeting")

        #expect(ReminderRouting.resolveListID(
            itemListID: nil,
            meetingListID: nil,
            folder: workFolder,
            globalDefaultListID: "list-global",
            fallbackListID: "list-sys"
        ) == "list-work")

        #expect(ReminderRouting.resolveListID(
            itemListID: nil,
            meetingListID: nil,
            folder: mutedFolder,
            globalDefaultListID: "list-global",
            fallbackListID: "list-sys"
        ) == "list-global")

        let item = ActionItem(owner: "You", task: "Run script")
        let meta = MeetingMeta(title: "Sync", startTime: Date())
        #expect(ReminderRouting.shouldAutoSync(item: item, relevance: .mine, meetingMeta: meta, folder: workFolder, globalAutoSync: true, includeWaitingOnOthers: false) == true)
        #expect(ReminderRouting.shouldAutoSync(item: item, relevance: .mine, meetingMeta: meta, folder: mutedFolder, globalAutoSync: true, includeWaitingOnOthers: false) == false)

        let url = try #require(ReminderRouting.deepLinkURL(folderID: "2026-11-25_1400_sync", timestamp: 125.4))
        let parsed = try #require(ReminderRouting.parseDeepLink(url))
        #expect(parsed.folderID == "2026-11-25_1400_sync")
        #expect(parsed.timestamp == 125)

        // Backwards compatibility: legacy ActionItem JSON without reminder fields still decodes cleanly.
        let legacyJSON = #"{"owner":"You","task":"Email draft","done":false}"#
        let decoded = try JSONDecoder().decode(ActionItem.self, from: Data(legacyJSON.utf8))
        #expect(decoded.task == "Email draft")
        #expect(decoded.reminderID == nil)
        #expect(decoded.reminderListPinned == false)

        // Pinned vs unpinned item routing: pinned keeps its custom list; unpinned follows folder list.
        let pinnedItem = ActionItem(owner: "You", task: "Pinned task", reminderID: "r1", reminderListID: "list-general", reminderListName: "Reminders", reminderListPinned: true)
        let encoded = try JSONEncoder().encode(pinnedItem)
        let redecoded = try JSONDecoder().decode(ActionItem.self, from: encoded)
        #expect(redecoded.reminderListPinned == true)
        #expect(ReminderRouting.resolveListID(
            itemListID: redecoded.reminderListPinned ? redecoded.reminderListID : nil,
            meetingListID: nil,
            folder: workFolder,
            globalDefaultListID: "list-global",
            fallbackListID: "list-sys"
        ) == "list-general")
        #expect(ReminderRouting.resolveListID(
            itemListID: decoded.reminderListPinned ? decoded.reminderListID : nil,
            meetingListID: nil,
            folder: workFolder,
            globalDefaultListID: "list-global",
            fallbackListID: "list-sys"
        ) == "list-work")

        // Mirrored folder resolution respects overrides and disabled folders.
        let unlinkedFolder = MeetingCollection(name: "Mobile App")
        #expect(ReminderRouting.resolveListLabel(meetingMeta: nil, folder: unlinkedFolder, globalDefaultListName: "Work", mirrorFolders: true) == "Mobile App")
        #expect(ReminderRouting.resolveListLabel(meetingMeta: nil, folder: unlinkedFolder, globalDefaultListName: "Work", mirrorFolders: false) == "Work")
        #expect(ReminderRouting.resolveListLabel(meetingMeta: nil, folder: mutedFolder, globalDefaultListName: "Work", mirrorFolders: true) == "Auto-sync off")

        #expect(ReminderRouting.mirroredFolderListName(itemListID: nil, meetingListID: nil, folder: unlinkedFolder, mirrorFolders: true) == "Mobile App")
        #expect(ReminderRouting.mirroredFolderListName(itemListID: nil, meetingListID: "override", folder: unlinkedFolder, mirrorFolders: true) == nil)
        #expect(ReminderRouting.mirroredFolderListName(itemListID: nil, meetingListID: nil, folder: mutedFolder, mirrorFolders: true) == nil)
        #expect(ReminderRouting.mirroredFolderListName(itemListID: nil, meetingListID: nil, folder: nil, mirrorFolders: true) == nil)
    }
}

@Suite struct ScheduleWeekFocusTests {
    @Test func switchesFromThisWeekOnWeekdayToUpcomingWeekOnWeekend() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!

        // Wednesday Nov 25, 2026 at 10:00 AM -> "This Week" (Mon Nov 23 .. Sun Nov 29)
        let wed = cal.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 10))!
        let wedFocus = ScheduleWeekFocus.defaultFocus(now: wed, events: [], calendar: cal)
        #expect(wedFocus.title == "This Week")
        #expect(wedFocus.isCurrentWeek == true)
        #expect(cal.component(.day, from: wedFocus.weekStart) == 23)

        // Saturday Nov 28, 2026 at 11:00 AM with no weekend meetings -> "Upcoming Week" (Mon Nov 30 .. Sun Dec 6)
        let sat = cal.date(from: DateComponents(year: 2026, month: 11, day: 28, hour: 11))!
        let satFocus = ScheduleWeekFocus.defaultFocus(now: sat, events: [], calendar: cal)
        #expect(satFocus.title == "Upcoming Week")
        #expect(satFocus.isUpcomingWeek == true)
        #expect(cal.component(.day, from: satFocus.weekStart) == 30)

        // Saturday WITH a remaining Zoom meeting on Sunday -> stays on "This Week"
        let sunCall = CalendarMeeting(
            id: "sun-call",
            title: "Sunday Prep",
            start: cal.date(from: DateComponents(year: 2026, month: 11, day: 29, hour: 16))!,
            end: cal.date(from: DateComponents(year: 2026, month: 11, day: 29, hour: 17))!,
            linkText: "https://zoom.us/j/123456"
        )
        let satWithCall = ScheduleWeekFocus.defaultFocus(now: sat, events: [sunCall], calendar: cal)
        #expect(satWithCall.title == "This Week")

        // Month grid for Nov 2026 starts on Monday Oct 26 and ends on Sunday Dec 6 (42 days).
        let monthDays = ScheduleWeekFocus.monthGridDays(containing: wed, calendar: cal)
        #expect(monthDays.count % 7 == 0)
        #expect(monthDays.count >= 35)
    }

    @Test func weekFocusPlanLinksUpcomingWeekMeetingsToOpenCommitments() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 10))!
        let pastDate = now.addingTimeInterval(-7 * 86_400)

        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("remeet-week-test-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let meetingsRoot = tempRoot.appendingPathComponent("meetings", isDirectory: true)
        let folder = MeetingFolder.makeNew(in: meetingsRoot, start: pastDate, title: "Weekly Product Sync")
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)

        var meta = MeetingMeta(title: "Weekly Product Sync", status: .summarized, startTime: pastDate)
        meta.calendarAttendees = [CalendarAttendee(name: "Kim, Jordan R", email: "jordan.kim@example.edu")]
        try folder.writeMeta(meta)
        try folder.write(SpeakerNames(names: ["speaker_1": "Jordan"]), .speakers)
        try folder.write(MeetingSummary(
            title: "Weekly Product Sync",
            actionItems: [
                ActionItem(owner: "You", task: "Share updated dataset", due: "Fri", done: false),
                ActionItem(owner: "Jordan R Kim", task: "Push SQL fix", due: "Thu", done: false),
            ]
        ), .summary)

        let snap = try #require(MeetingSnapshot.read(folder))
        let people = PeopleDirectory.build(store: PeopleStore(), memory: SpeakerMemory(), snapshots: [snap], calendarEvents: [], recorderName: "Sam")
        let nextCall = CalendarMeeting(
            id: "product-sync-next",
            title: "Weekly Product Sync",
            start: now.addingTimeInterval(2 * 86_400),
            end: now.addingTimeInterval(2 * 86_400 + 3600),
            attendees: [CalendarAttendee(name: "Kim, Jordan R", email: "jordan.kim@example.edu")],
            linkText: "https://teams.microsoft.com/l/meetup-join/123"
        )
        let win = ScheduleWeekFocus.defaultFocus(now: now, events: [nextCall], calendar: cal)
        let plan = WeekFocusPlan.build(window: win, events: [nextCall], snapshots: [snap], people: people, recorderName: "Sam", now: now)

        #expect(plan.weekEvents.count == 1)
        #expect(plan.actionGroups.count == 1)
        #expect(plan.actionGroups[0].yourItems.map(\.actionItem.task) == ["Share updated dataset"])
        #expect(plan.actionGroups[0].theirItems.map(\.actionItem.task) == ["Push SQL fix"])
    }
}
