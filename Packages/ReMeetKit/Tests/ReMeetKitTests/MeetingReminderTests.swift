import Foundation
import Testing
@testable import ReMeetKit

struct MeetingReminderTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func event(_ id: String, inMinutes: Double, attendees: [String] = ["Priya"], link: String = "",
               allDay: Bool = false, declined: Bool = false) -> CalendarMeeting {
        let start = now.addingTimeInterval(inMinutes * 60)
        return CalendarMeeting(id: id, title: id, start: start, end: start.addingTimeInterval(1800), isAllDay: allDay,
                               attendeeNames: attendees, declined: declined, linkText: link)
    }

    @Test func recognizesCallLinks() {
        #expect(MeetingReminder.callService(in: "Join: https://teams.microsoft.com/l/meetup-join/19%3ameeting_x") == "Teams")
        #expect(MeetingReminder.callService(in: "https://us02web.zoom.us/j/8123456789?pwd=abc") == "Zoom")
        #expect(MeetingReminder.callService(in: "meet.google.com/abc-defg-hij") == "Google Meet")
        #expect(MeetingReminder.callService(in: "Room 4B, bring snacks") == nil)
    }

    @Test func whatCountsAsAMeeting() {
        #expect(MeetingReminder.isMeeting(event("1:1", inMinutes: 10)))
        #expect(MeetingReminder.isMeeting(event("solo zoom", inMinutes: 10, attendees: [], link: "zoom.us/j/1")))
        #expect(!MeetingReminder.isMeeting(event("focus", inMinutes: 10, attendees: [])))
        #expect(!MeetingReminder.isMeeting(event("holiday", inMinutes: 10, allDay: true)))
        #expect(!MeetingReminder.isMeeting(event("declined", inMinutes: 10, declined: true)))
    }

    @Test func nextReminderIsAMinuteBeforeTheEarliestMeeting() {
        let events = [event("later", inMinutes: 90), event("soon", inMinutes: 30), event("focus", inMinutes: 5, attendees: [])]
        let next = MeetingReminder.next(events, now: now, reminded: [])
        #expect(next?.event.id == "soon")
        #expect(next?.fireAt == now.addingTimeInterval(29 * 60))
        // Already reminded: move on to the next one.
        #expect(MeetingReminder.next(events, now: now, reminded: ["soon"])?.event.id == "later")
    }

    @Test func meetingStartingNowFiresImmediatelyAndPastOnesDoNot() {
        let starting = event("starting", inMinutes: 0.5)
        #expect(MeetingReminder.next([starting], now: now, reminded: [])?.fireAt == now)
        // Began 30 s ago (Mac was asleep): still reminded, right away.
        #expect(MeetingReminder.next([event("just began", inMinutes: -0.5)], now: now, reminded: [])?.fireAt == now)
        #expect(MeetingReminder.next([event("long gone", inMinutes: -10)], now: now, reminded: []) == nil)
    }

    @Test func callIsMatchedToItsCalendarEvent() {
        let events = [event("standup", inMinutes: -12), event("review", inMinutes: 45), event("early", inMinutes: 4)]
        // Joined 4 minutes early: the event about to start, not the one 12 minutes in.
        #expect(MeetingReminder.event(forCallAt: now, in: events)?.id == "early")
        #expect(MeetingReminder.event(forCallAt: now, in: [event("standup", inMinutes: -12)])?.id == "standup")
        #expect(MeetingReminder.event(forCallAt: now, in: [event("old", inMinutes: -20), event("review", inMinutes: 45)]) == nil)
    }
}
