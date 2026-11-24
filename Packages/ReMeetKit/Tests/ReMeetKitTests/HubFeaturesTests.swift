import Foundation
import Testing
@testable import ReMeetKit

@Suite struct CalendarAndICSTests {
    @Test func parsesUnfoldedGoogleICSWithMeetLinkAttendeesAndRecurrence() {
        let ics = """
        BEGIN:VCALENDAR\r
        VERSION:2.0\r
        X-WR-CALNAME:alex@acme.io\r
        X-WR-TIMEZONE:UTC\r
        BEGIN:VEVENT\r
        UID:weekly-sync-123@google.com\r
        DTSTART:20261123T150000Z\r
        DTEND:20261123T153000Z\r
        RRULE:FREQ=WEEKLY;COUNT=3;BYDAY=MO,WE\r
        EXDATE:20261125T150000Z\r
        SUMMARY:Weekly Product\r
          Sync\r
        X-GOOGLE-CONFERENCE:https://meet.google.com/xyz-abcd-efg\r
        DESCRIPTION:Review Q4 launch\\n-::~:~::~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~::~:~::-\\nJoin Meet\r
        ORGANIZER;CN="Priya Patel":mailto:priya.patel@stripe.com\r
        ATTENDEE;CUTYPE=INDIVIDUAL;PARTSTAT=ACCEPTED;CN="Priya Patel":mailto:priya.patel@stripe.com\r
        ATTENDEE;CUTYPE=INDIVIDUAL;PARTSTAT=ACCEPTED:mailto:tom.chen@acme.io\r
        ATTENDEE;CUTYPE=INDIVIDUAL;PARTSTAT=ACCEPTED:mailto:alex@acme.io\r
        ATTENDEE;CUTYPE=ROOM;CN="Conf Room B":mailto:room_b@resource.calendar.google.com\r
        END:VEVENT\r
        BEGIN:VEVENT\r
        UID:cancelled-event@google.com\r
        STATUS:CANCELLED\r
        DTSTART:20261124T180000Z\r
        DTEND:20261124T183000Z\r
        SUMMARY:Cancelled Call\r
        END:VEVENT\r
        END:VCALENDAR
        """

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = cal.date(from: DateComponents(year: 2026, month: 11, day: 20))!
        let end = cal.date(from: DateComponents(year: 2026, month: 12, day: 10))!

        let parsed = ICalendarParser.parse(ics, windowStart: start, windowEnd: end, defaultTimeZone: TimeZone(secondsFromGMT: 0)!)
        #expect(parsed.calendarName == "alex@acme.io")
        // COUNT=3 on MO,WE starting Mon Nov 23 -> Mon Nov 23, Wed Nov 25 (excluded via EXDATE!), Mon Nov 30 => 2 active events.
        #expect(parsed.events.count == 2)
        let first = parsed.events[0]
        #expect(first.title == "Weekly Product Sync")
        #expect(first.callService == "Google Meet")
        #expect(first.joinURL?.absoluteString == "https://meet.google.com/xyz-abcd-efg")
        #expect(first.notes == "Review Q4 launch")
        // Self (`alex@acme.io`) and room resource are excluded; Priya and Tom remain with humanized names & orgs!
        #expect(first.attendees.map(\.name) == ["Priya Patel", "Tom Chen"])
        #expect(first.attendees.first?.inferredOrganization == "Stripe")
    }

    @Test func deduplicatesSameEventFromAppleCalendarAndICSFeed() {
        let start = Date(timeIntervalSince1970: 1_795_000_000)
        let end = start.addingTimeInterval(1800)
        let ek = CalendarMeeting(id: "abc@1", uid: "shared-uid", title: "1:1 with Priya",
                                 start: start, end: end,
                                 attendees: [CalendarAttendee(name: "Priya Patel", email: "priya@acme.io")],
                                 sourceKind: .appleCalendar)
        let ics = CalendarMeeting(id: "abc@2", uid: "shared-uid", title: "1:1 with Priya",
                                  start: start, end: end,
                                  attendees: [CalendarAttendee(name: "Priya")],
                                  sourceKind: .icsFeed)
        let merged = MeetingReminder.deduplicate([ics, ek])
        #expect(merged.count == 1)
        #expect(merged[0].sourceKind == .appleCalendar)
        #expect(merged[0].attendees.first?.email == "priya@acme.io")
    }

    @Test func webcalNormalizedToHTTPS() {
        let sub = ICSFeedSubscription(urlString: "  webcal://calendar.google.com/calendar/ical/test/basic.ics ")
        #expect(sub.urlString == "https://calendar.google.com/calendar/ical/test/basic.ics")
    }
}

@Suite struct PeopleAndVoiceBoostTests {
    @Test func calendarInviteBoostsConfirmedAttendeeWithoutFalsePositives() {
        var memory = SpeakerMemory()
        memory.remember(name: "Priya", embedding: [1, 0, 0, 0], seconds: 120)
        memory.remember(name: "Other Person", embedding: [0, 1, 0, 0], seconds: 120)

        // Cosine ~0.56 with Priya: below the 0.62 unassisted bar, above the 0.52 invite-verified bar.
        let slightlyNoisyPriya: [Float] = [0.56, 0.10, 0.822, 0]
        let withoutInvite = memory.suggestions(for: ["speaker_1": slightlyNoisyPriya], existing: SpeakerNames())
        #expect(withoutInvite.isEmpty)

        let withInvite = memory.suggestions(for: ["speaker_1": slightlyNoisyPriya],
                                            existing: SpeakerNames(),
                                            attendeeNames: ["Priya Patel", "Tom Chen"])
        #expect(withInvite.count == 1)
        #expect(withInvite[0].name == "Priya")
        #expect(withInvite[0].onInvite == true)

        // Completely different voice (cosine ~0.10) is still rejected even when on the invite!
        let unrelatedVoice: [Float] = [0.10, 0.0, 0.995, 0]
        let rejected = memory.suggestions(for: ["speaker_1": unrelatedVoice],
                                          existing: SpeakerNames(),
                                          attendeeNames: ["Priya Patel"])
        #expect(rejected.isEmpty)
    }

    @Test func unassignedInviteesExcludesRecorderAndAlreadyNamedSpeakers() {
        let attendees = [
            CalendarAttendee(name: "Alex", email: "alex@acme.io"),
            CalendarAttendee(name: "Priya Patel", email: "priya@acme.io"),
            CalendarAttendee(name: "Tom Chen", email: "tom@acme.io"),
            CalendarAttendee(name: "Declined Guest", status: .declined),
        ]
        let existing = SpeakerNames(names: ["speaker_1": "Priya"])
        let remaining = CalendarSpeakerHints.unassignedInvitees(attendees: attendees,
                                                                existing: existing,
                                                                recorderName: "Alex")
        #expect(remaining == ["Tom Chen"])
    }

    @Test func peopleStoreUpsertUpgradesSingleNameAndMergesProfiles() {
        var store = PeopleStore()
        _ = store.upsert(name: "Priya", notes: "Runs releases")
        _ = store.upsert(name: "Priya Patel", email: "priya@acme.io", organization: "Acme")
        #expect(store.profiles.count == 1)
        #expect(store.profiles[0].name == "Priya Patel")
        #expect(store.profiles[0].aliases.contains("Priya"))
        #expect(store.profiles[0].notes == "Runs releases")
        #expect(store.profiles[0].organization == "Acme")

        let dupe = store.upsert(name: "P. Patel", role: "VP Product")!
        let merged = store.merge(sourceID: dupe.id, into: store.profiles[0].id)
        #expect(merged?.target.role == "VP Product")
        #expect(store.profiles.count == 1)
    }
}

@Suite struct MomentsPulseAndPrepTests {
    @Test func buildsKeyMomentsPulseWalkInBriefAndFollowUp() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("remeet-hub-test-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let meetingsRoot = tempRoot.appendingPathComponent("meetings", isDirectory: true)
        try FileManager.default.createDirectory(at: meetingsRoot, withIntermediateDirectories: true)

        let pastDate = Date().addingTimeInterval(-3 * 86_400)
        let folder = MeetingFolder.makeNew(in: meetingsRoot, start: pastDate, title: "Weekly product sync")
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)

        var meta = MeetingMeta(title: "Weekly product sync", status: .summarized, startTime: pastDate)
        meta.durationSeconds = 900
        meta.calendarAttendees = [
            CalendarAttendee(name: "Priya Patel", email: "priya@acme.io"),
            CalendarAttendee(name: "Tom Chen", email: "tom@acme.io"),
        ]
        try folder.writeMeta(meta)
        try NotesFile(url: folder.file(.notes)).save([
            MeetingNote(t: 120, text: "Confirm partner email timeline", kind: .note),
        ])
        try folder.write(SpeakerNames(names: ["speaker_1": "Priya Patel", "speaker_2": "Tom Chen"]), .speakers)
        try folder.write(Transcript(engine: "test", segments: [
            TranscriptSegment(start: 118, end: 128, speaker: "speaker_1",
                              text: "We decided to move release 3.2 to November 17 so payments testing finishes.", source: .system),
            TranscriptSegment(start: 130, end: 136, speaker: "you",
                              text: "Makes sense. I'll write the refund FAQ by Friday.", source: .mic),
            TranscriptSegment(start: 140, end: 148, speaker: "speaker_2",
                              text: "And I'll expose the refund endpoint in the admin panel.", source: .system),
        ]), .transcript)
        let summary = MeetingSummary(
            title: "Weekly product sync",
            summary: [SummaryPoint(text: "Release 3.2 moves to Nov 17.", t: 118)],
            decisions: [SummaryPoint(text: "Ship release 3.2 on Nov 17.", t: 118)],
            actionItems: [
                ActionItem(owner: "You", task: "Write refund FAQ", due: "Fri", done: false, t: 130),
                ActionItem(owner: "Priya Patel", task: "Send partner release update", due: "Wed", done: false, t: 120),
            ],
            openQuestions: [SummaryPoint(text: "Do annual plans auto-prorate?", t: 142)],
            yourNotes: [NoteContext(t: 120, note: "Confirm partner email timeline", context: "Priya will email partners Wednesday.")]
        )
        try folder.write(summary, .summary)

        let snap = try #require(MeetingSnapshot.read(folder))
        #expect(snap.moments.count >= 3)
        #expect(snap.moments.contains { $0.kind == .pinned && $0.speakerName == "Priya Patel" })
        #expect(snap.moments.contains { $0.kind == .decision })

        let transcript = try folder.read(Transcript.self, .transcript)
        let speakers = try folder.read(SpeakerNames.self, .speakers)!
        let pulse = ConversationPulse.compute(transcript: transcript, speakers: speakers, metaDuration: 900)
        #expect(pulse.shares.count == 3)
        #expect(!pulse.slices.isEmpty)

        // Build People & Walk-In Prep Brief for next week's recurring sync!
        let nextEvent = CalendarMeeting(
            id: "next-sync",
            title: "Weekly product sync - Nov 24",
            start: Date().addingTimeInterval(900),
            end: Date().addingTimeInterval(2700),
            attendees: [CalendarAttendee(name: "Priya Patel", email: "priya@acme.io")],
            linkText: "https://meet.google.com/abc-defg-hij"
        )
        let people = PeopleDirectory.build(store: PeopleStore(), memory: SpeakerMemory(),
                                           snapshots: [snap], calendarEvents: [nextEvent], recorderName: "Alex")
        let priya = try #require(people.first { $0.profile.name == "Priya Patel" })
        #expect(priya.meetingsCount == 1)
        #expect(priya.theirOpenCommitments.count == 1)
        #expect(priya.yourOpenCommitments.count == 1)

        let brief = MeetingPrepBrief.build(for: nextEvent, snapshots: [snap], people: people, recorderName: "Alex")
        #expect(brief.lastSeriesMeeting?.title == "Weekly product sync")
        #expect(brief.yourOpenPromises.map(\.actionItem.task) == ["Write refund FAQ"])
        #expect(brief.theirOpenPromises.map(\.actionItem.task) == ["Send partner release update"])
        #expect(brief.carryoverQuestions.count == 1)
        #expect(brief.markdown().contains("Write refund FAQ"))

        let followUp = FollowUpComposer.compose(title: meta.title, date: pastDate,
                                                participants: ["Priya Patel", "Tom Chen"],
                                                summary: summary, recorderName: "Alex")
        #expect(followUp.contains("Hi Priya, Tom,"))
        #expect(followUp.contains("Ship release 3.2 on Nov 17."))
        #expect(followUp.contains("**Alex:** Write refund FAQ"))
    }
}
