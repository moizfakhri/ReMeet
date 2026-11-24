import Foundation
import Testing
@testable import ReMeetKit

@Suite struct PolishFeaturesTests {
    @Test func scheduleFiltersOutClassesAndPhysicalBlocksWithoutCallLinks() {
        let now = Date()
        let lecture = CalendarMeeting(
            id: "class-1",
            title: "PHYS 101 Introductory Seminar",
            start: now.addingTimeInterval(60),
            end: now.addingTimeInterval(3660),
            attendees: [
                CalendarAttendee(name: "Prof. Carter", email: "carter@example.edu"),
                CalendarAttendee(name: "Alex Morgan", email: "alex@example.edu"),
            ],
            linkText: "Main Hall 210",
            notes: "Bring printed handout to seminar.",
            sourceKind: .icsFeed
        )
        let zoomMeeting = CalendarMeeting(
            id: "zoom-1",
            title: "Weekly Platform Sync",
            start: now.addingTimeInterval(90),
            end: now.addingTimeInterval(2700),
            attendees: [CalendarAttendee(name: "Dr. Carter")],
            linkText: "https://example.zoom.us/j/987654321",
            sourceKind: .appleCalendar
        )
        let teamsMeeting = CalendarMeeting(
            id: "teams-1",
            title: "Core Systems Review",
            start: now.addingTimeInterval(120),
            end: now.addingTimeInterval(2700),
            linkText: "Join Microsoft Teams Meeting",
            sourceKind: .appleCalendar
        )
        let discordCall = CalendarMeeting(
            id: "discord-1",
            title: "Study Group Check-in",
            start: now.addingTimeInterval(180),
            end: now.addingTimeInterval(1980),
            notes: "Hop onto https://discord.gg/project-team",
            sourceKind: .icsFeed
        )
        let slackHuddle = CalendarMeeting(
            id: "slack-1",
            title: "Quick backend debug",
            start: now.addingTimeInterval(240),
            end: now.addingTimeInterval(1200),
            linkText: "https://app.slack.com/huddle/T123/C456",
            sourceKind: .icsFeed
        )

        #expect(MeetingReminder.hasOnlineMeetingPlatform(lecture) == false)
        #expect(MeetingReminder.hasOnlineMeetingPlatform(zoomMeeting) == true)
        #expect(MeetingReminder.hasOnlineMeetingPlatform(teamsMeeting) == true)
        #expect(MeetingReminder.hasOnlineMeetingPlatform(discordCall) == true)
        #expect(MeetingReminder.hasOnlineMeetingPlatform(slackHuddle) == true)

        // nextOnlineMeeting ignores the class even though it has attendees and starts sooner.
        let picked = MeetingReminder.nextOnlineMeeting([lecture, teamsMeeting, zoomMeeting], now: now, reminded: [])
        #expect(picked?.event.id == "zoom-1")
    }

    @Test func commitmentsRadarPrioritizesUserAndRelatedTasksOverUnrelatedOthers() throws {
        let mine = ActionItem(owner: "You", task: "Push updated database migration", due: "Fri")
        let joint = ActionItem(owner: "Alex and Priya", task: "Finalize Q4 release checklist")
        let waitingOnForMe = ActionItem(owner: "Priya", task: "Send benchmark CSV to you before Friday")
        let explicitlyRelated = ActionItem(owner: "Elena", task: "Approve pull request", relatesToMe: true)
        let explicitlyUnrelated = ActionItem(owner: "David", task: "Ping Alex? Actually internal only", relatesToMe: false)
        let unrelatedGroupTask = ActionItem(owner: "Sam", task: "Rebuild staging search index")
        let dismissedMine = ActionItem(owner: "You", task: "Old dismissed task", dismissed: true)

        let partition = CommitmentsRadar.partition(
            [unrelatedGroupTask, waitingOnForMe, explicitlyUnrelated, joint, dismissedMine, explicitlyRelated, mine],
            recorderName: "Alex",
            otherParticipantCount: 4
        )
        #expect(partition.mine.map(\.task) == [
            "Finalize Q4 release checklist",
            "Push updated database migration",
        ])
        #expect(partition.related.map(\.task) == [
            "Send benchmark CSV to you before Friday",
            "Approve pull request",
        ])
        #expect(partition.others.map(\.task) == [
            "Rebuild staging search index",
            "Ping Alex? Actually internal only",
        ])

        // 1:1 call automatically elevates the single partner's tasks to relatedToMe when relatesToMe is nil.
        let oneOnOneRel = CommitmentsRadar.classifyRelevance(
            unrelatedGroupTask,
            recorderName: "Alex",
            otherParticipantCount: 1
        )
        #expect(oneOnOneRel == .relatedToMe)

        // End-to-end radar build sorts pending items by Relevance (.mine -> .relatedToMe -> .others) and omits dismissed.
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("remeet-polish-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let pastDate = Date().addingTimeInterval(-3600)
        let folder = MeetingFolder.makeNew(in: tempRoot, start: pastDate, title: "Team Sync")
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)

        var meta = MeetingMeta(title: "Team Sync", status: .summarized, startTime: pastDate)
        meta.durationSeconds = 1800
        try folder.writeMeta(meta)
        try folder.write(
            MeetingSummary(
                title: "Team Sync",
                actionItems: [unrelatedGroupTask, waitingOnForMe, mine, dismissedMine]
            ),
            .summary
        )
        try folder.write(
            Transcript(engine: "test", segments: [
                TranscriptSegment(start: 0, end: 10, speaker: SpeakerNames.youID, text: "Hello", source: .mic),
                TranscriptSegment(start: 10, end: 30, speaker: "speaker_1", text: "Hi", source: .system),
                TranscriptSegment(start: 30, end: 50, speaker: "speaker_2", text: "Hey", source: .system),
            ]),
            .transcript
        )
        let snap = try #require(MeetingSnapshot.read(folder))
        let radar = CommitmentsRadar.build(from: [snap], recorderName: "Alex", now: Date())
        #expect(radar.count == 3)
        #expect(radar.map(\.relevance) == [.mine, .relatedToMe, .others])
    }

    @Test func speakerMemoryUnlearnsPreviousContributionWhenReassigningMistake() {
        var memory = SpeakerMemory()
        let samVec: [Float] = [1, 0, 0, 0]
        let elenaVec: [Float] = [0, 1, 0, 0]

        // Meeting 0: Sam validly learned from speaker_1.
        memory.remember(name: "Sam", embedding: samVec, seconds: 120, sourceKey: "m0::speaker_1")
        // Meeting 1: speaker_2 was initially mislabeled as "Sam" with Elena's voice embedding.
        memory.remember(name: "Sam", embedding: elenaVec, seconds: 120, sourceKey: "m1::speaker_2")

        // Before fix, Sam's centroid was pulled 50/50 toward Elena's vector!
        let polluted = memory.voices.first { $0.name == "Sam" }!
        #expect(SpeakerMemory.cosine(polluted.embedding, samVec) < 0.8)

        // User corrects m1::speaker_2 from "Sam" to "Elena".
        memory.remember(name: "Elena", embedding: elenaVec, seconds: 120, sourceKey: "m1::speaker_2")

        let repairedSam = memory.voices.first { $0.name == "Sam" }!
        let learnedElena = memory.voices.first { $0.name == "Elena" }!
        #expect(SpeakerMemory.cosine(repairedSam.embedding, samVec) > 0.99)
        #expect(SpeakerMemory.cosine(learnedElena.embedding, elenaVec) > 0.99)

        // Verify unlearn removes an orphan voice completely when its only contribution is cleared.
        memory.unlearn(sourceKey: "m1::speaker_2")
        #expect(memory.voices.contains { $0.name == "Elena" } == false)
        #expect(memory.voices.contains { $0.name == "Sam" } == true)
    }

    @Test func speakerMemoryRankedMatchesPrioritizesBestFitAndMarksInvitees() throws {
        var memory = SpeakerMemory()
        memory.remember(name: "Priya Patel", embedding: [0.95, 0.31, 0, 0], seconds: 90, sourceKey: "m1::speaker_1")
        memory.remember(name: "Tom Chen", embedding: [0.55, 0.835, 0, 0], seconds: 90, sourceKey: "m1::speaker_2")
        memory.remember(name: "Unrelated Voice", embedding: [0.10, 0.995, 0, 0], seconds: 90, sourceKey: "m1::speaker_3")

        let query: [Float] = [1, 0, 0, 0]
        let ranked = memory.rankedMatches(for: query, attendeeNames: ["Priya Patel"], limit: 5)
        try #require(ranked.count == 2)
        #expect(ranked[0].name == "Priya Patel")
        #expect(ranked[0].onInvite == true)
        #expect(ranked[0].score > ranked[1].score)
        #expect(ranked[1].name == "Tom Chen")
        #expect(ranked[1].onInvite == false)
    }
}
