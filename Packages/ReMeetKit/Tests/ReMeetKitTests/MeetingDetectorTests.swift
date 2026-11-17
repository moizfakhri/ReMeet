import Foundation
import Testing
@testable import ReMeetKit

struct MeetingDetectorTests {
    @Test func matchesHelpers() {
        #expect(MeetingApp.match("us.zoom.xos")?.name == "Zoom")
        #expect(MeetingApp.match("com.google.Chrome.helper")?.name == "Google Chrome")
        #expect(MeetingApp.match("com.apple.WebKit.GPU")?.name == "Safari")
        #expect(MeetingApp.match("com.microsoft.teams2")?.meetingTitle == "Teams call")
        #expect(MeetingApp.match("com.google.Chrome")?.meetingTitle == "Browser call")
        #expect(MeetingApp.match("com.apple.VoiceMemos") == nil)
        #expect(MeetingApp.match("com.moizfakhri.ReMeet") == nil)
    }

    @Test func promptsOnceWhenAMeetingAppStartsUsingTheMic() {
        var d = MeetingDetector()
        let t0 = Date(timeIntervalSince1970: 0)
        #expect(d.update(inputProcesses: ["com.apple.VoiceMemos"], isRecording: false, now: t0) == nil)
        #expect(d.update(inputProcesses: ["us.zoom.xos"], isRecording: false, now: t0)?.name == "Zoom")
        // Still in the call: no second prompt.
        #expect(d.update(inputProcesses: ["us.zoom.xos"], isRecording: false, now: t0 + 30) == nil)
        // Mic released and taken again within 10 minutes: no prompt.
        _ = d.update(inputProcesses: [], isRecording: false, now: t0 + 60)
        #expect(d.update(inputProcesses: ["us.zoom.xos"], isRecording: false, now: t0 + 120) == nil)
        // After the cooldown: asks again.
        _ = d.update(inputProcesses: [], isRecording: false, now: t0 + 700)
        #expect(d.update(inputProcesses: ["us.zoom.xos"], isRecording: false, now: t0 + 701)?.name == "Zoom")
    }

    @Test func neverPromptsWhileRecording() {
        var d = MeetingDetector()
        #expect(d.update(inputProcesses: ["com.microsoft.teams2"], isRecording: true) == nil)
        // The app was already active when recording ended: no prompt for that same session.
        #expect(d.update(inputProcesses: ["com.microsoft.teams2"], isRecording: false) == nil)
        #expect(d.isActive(MeetingApp.match("com.microsoft.teams2")!))
    }
}
