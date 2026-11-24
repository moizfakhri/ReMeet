import Foundation
import ReMeetKit

/// Sample meetings for snapshots and self-tests, written to a temporary folder (never to
/// ~/ReMeet). Content mirrors the design mockups.
@MainActor
enum SampleData {
    static let baseRoot = FileManager.default.temporaryDirectory.appendingPathComponent("remeet-sample", isDirectory: true)
    static let root = baseRoot.appendingPathComponent("meetings", isDirectory: true)

    static func install(model: AppModel, select index: Int) {
        if !FileManager.default.fileExists(atPath: root.path) { write() }
        writeSamplePeopleAndCalendar(model: model)
        model.library.root = root
        model.hub.configure(root: root)
        model.library.reloadNow()
        if model.library.collections.isEmpty, let first = model.library.items.first {
            let product = model.library.createCollection(named: "Product team")
            model.library.createCollection(named: "Projects")
            if let product {
                model.library.updateCollection(product.id, context: "Weekly product sync for the payments app. Priya runs releases, Tom owns the refund API.")
                model.library.move(first.folder, to: product.id)
            }
            model.library.reloadNow()
        }
        model.hub.reloadAll(items: model.library.items, calendarEvents: model.calendar.events, recorderName: AppModel.recorderName)
        RunLoop.main.run(until: Date().addingTimeInterval(0.18))
        let folders = model.library.items.map(\.folder)
        if index >= 0, index < folders.count { model.selectedMeeting = folders[index] }
    }

    private static func writeSamplePeopleAndCalendar(model: AppModel) {
        let peopleURL = PeopleFile.url(beside: root)
        var store = PeopleStore()
        _ = store.upsert(name: "Priya Patel", email: "priya@acme.io", role: "Product Lead",
                         organization: "Acme", notes: "Runs mobile & payments releases. Prefers crisp decision summaries before partner updates.")
        _ = store.upsert(name: "Tom Chen", email: "tom@acme.io", role: "Staff Backend Engineer",
                         organization: "Acme", notes: "Owns the refund API and payment webhook reliability.")
        try? PeopleFile.save(store, to: peopleURL)

        let voiceURL = root.deletingLastPathComponent().appendingPathComponent("voiceprints.json")
        var memory = SpeakerMemory()
        memory.remember(name: "Priya Patel", embedding: [1, 0, 0, 0], seconds: 420)
        try? SpeakerMemoryFile.save(memory, to: voiceURL)

        let soon = Date().addingTimeInterval(22 * 60)
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: soon) ?? soon.addingTimeInterval(86_400)
        let sampleEvents = [
            CalendarMeeting(
                id: "sample-class-lecture",
                title: "PHYS 101 Introductory Seminar",
                start: soon.addingTimeInterval(5 * 60),
                end: soon.addingTimeInterval(65 * 60),
                attendees: [
                    CalendarAttendee(name: "Prof. Carter", status: .accepted),
                    CalendarAttendee(name: "Priya Patel", status: .accepted),
                ],
                linkText: "Main Hall 210",
                notes: "Bring printed handout",
                calendarName: "Classes",
                sourceKind: .icsFeed
            ),
            CalendarMeeting(
                id: "sample-sync-next",
                title: "Weekly product sync",
                start: soon,
                end: soon.addingTimeInterval(30 * 60),
                attendees: [
                    CalendarAttendee(name: "Priya Patel", email: "priya@acme.io", isOrganizer: true, status: .accepted),
                    CalendarAttendee(name: "Tom Chen", email: "tom@acme.io", status: .accepted),
                ],
                linkText: "https://meet.google.com/abc-defg-hij",
                notes: "Agenda: 1) Confirm 3.2 partner note went out, 2) Demo admin refund endpoint, 3) Review annual-plan FAQ.",
                calendarName: "Work (Google)",
                sourceKind: .appleCalendar
            ),
            CalendarMeeting(
                id: "sample-design-tomorrow",
                title: "Onboarding Q4 metrics review",
                start: tomorrow,
                end: tomorrow.addingTimeInterval(45 * 60),
                attendees: [
                    CalendarAttendee(name: "Priya Patel", email: "priya@acme.io", status: .accepted),
                ],
                linkText: "https://zoom.us/j/9123456789",
                calendarName: "Product (.ics)",
                sourceKind: .icsFeed
            ),
        ]
        model.calendar.source = { sampleEvents }
        model.calendar.reload()
    }

    static func write() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let today = Calendar.current.date(bySettingHour: 11, minute: 0, second: 0, of: Date())!

        let sync = MeetingFolder.makeNew(in: root, start: today, title: "Weekly product sync")
        try? FileManager.default.createDirectory(at: sync.url, withIntermediateDirectories: true)
        var meta = MeetingMeta(title: "Weekly product sync", status: .summarized, startTime: today)
        meta.durationSeconds = 48 * 60 + 3
        meta.sourceApp = "com.google.Chrome"
        meta.processing.summaryBackend = "Built-in model"
        meta.processing.summarySeconds = 52
        try? sync.writeMeta(meta)
        try? NotesFile(url: sync.file(.notes)).save([
            MeetingNote(t: 760, text: "Ask Tom about refund API", kind: .note),
            MeetingNote(t: 1265, text: "", kind: .bookmark),
        ])
        try? sync.write(MeetingSummary(
            title: "Weekly product sync",
            summary: [SummaryPoint(text: "Release 3.2 moves from 10 Nov to 17 Nov to fit the payments fix.", t: 718),
                      SummaryPoint(text: "The onboarding test lifted day-7 retention from 31% to 36%, so it ships to everyone.", t: 1450),
                      SummaryPoint(text: "Support tickets are up 20% since the pricing change, mostly about annual plans.", t: 1905)],
            decisions: [SummaryPoint(text: "Onboarding variant B becomes the default.", t: 1490)],
            actionItems: [ActionItem(owner: "Priya", task: "Send the new release date to you for partner review", due: "Wed", t: 740),
                          ActionItem(owner: "You", task: "Write an FAQ entry on annual plan refunds", due: "Fri"),
                          ActionItem(owner: "David", task: "Clean up staging database fixtures", due: "Thu"),
                          ActionItem(owner: "Tom", task: "Check test coverage of the payments fix", done: true)],
            openQuestions: [],
            yourNotes: [NoteContext(t: 760, note: "Ask Tom about refund API",
                                    context: "Tom said the refund endpoint exists but isn't in the admin panel yet; he'll look at it this week.")]),
            .summary)
        try? sync.write(Transcript(engine: "Parakeet TDT 0.6B v2", segments: [
            TranscriptSegment(start: 718, end: 731, speaker: "speaker_1", text: "The payments fix needs another week of testing. I'd rather move 3.2 than ship it half done.", source: .system),
            TranscriptSegment(start: 734, end: 738, speaker: "you", text: "Agreed. Can we tell partners by Wednesday?", source: .mic),
            TranscriptSegment(start: 740, end: 743, speaker: "speaker_1", text: "Yes, I'll send the new date.", source: .system),
            TranscriptSegment(start: 761, end: 769, speaker: "speaker_2", text: "On refunds, the endpoint exists, it's just not in the admin panel yet.", source: .system),
            TranscriptSegment(start: 775, end: 778, speaker: "you", text: "Could you take a look this week?", source: .mic),
            TranscriptSegment(start: 782, end: 786, speaker: "speaker_2", text: "Sure, and I'll check the coverage too.", source: .system),
        ]), .transcript)
        try? sync.write(SpeakerNames(names: ["speaker_1": "Priya"]), .speakers)

        let debrief = MeetingFolder.makeNew(in: root, start: today.addingTimeInterval(-3600), title: "Hiring loop debrief")
        try? FileManager.default.createDirectory(at: debrief.url, withIntermediateDirectories: true)
        var failed = MeetingMeta(title: "Hiring loop debrief", status: .diarized, startTime: today.addingTimeInterval(-3600))
        failed.durationSeconds = 31 * 60
        failed.markFailed(.transcribe, message: "The speech model is not downloaded yet.")
        try? debrief.writeMeta(failed)

        let older = MeetingFolder.makeNew(in: root, start: today.addingTimeInterval(-3 * 86_400), title: "Design review: onboarding")
        try? FileManager.default.createDirectory(at: older.url, withIntermediateDirectories: true)
        var done = MeetingMeta(title: "Design review: onboarding", status: .summarized, startTime: today.addingTimeInterval(-3 * 86_400))
        done.durationSeconds = 55 * 60
        try? older.writeMeta(done)
    }
}
