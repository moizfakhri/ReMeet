import Foundation
import Testing
@testable import ReMeetKit

struct CallEndWatcherTests {
    let t0 = Date(timeIntervalSince1970: 0)

    @Test func endsAfterGraceAndCancelsWhenTheAppReturns() {
        var w = CallEndWatcher(grace: 30)
        w.begin(app: "us.zoom.xos", inputProcesses: ["us.zoom.xos"])
        #expect(w.update(inputProcesses: [], now: t0) == .released)
        #expect(!w.callEnded(now: t0 + 29))
        // Zoom takes the mic back (rejoin, device switch): the pending stop is cancelled.
        #expect(w.update(inputProcesses: ["us.zoom.xos"], now: t0 + 20) == .returned)
        #expect(!w.callEnded(now: t0 + 60))
        #expect(w.update(inputProcesses: [], now: t0 + 100) == .released)
        #expect(w.callEnded(now: t0 + 130))
    }

    @Test func otherAppsDoNotCount() {
        var w = CallEndWatcher(grace: 30)
        w.begin(app: "us.zoom.xos", inputProcesses: ["us.zoom.xos", "com.apple.VoiceMemos"])
        // Voice Memos letting go is not the call ending.
        #expect(w.update(inputProcesses: ["us.zoom.xos"], now: t0) == .none)
        // Zoom letting go while Chrome holds the mic still ends the Zoom call.
        #expect(w.update(inputProcesses: ["com.google.Chrome.helper"], now: t0) == .released)
        #expect(w.app == "us.zoom.xos")
    }

    @Test func manualRecordingAdoptsTheFirstMeetingApp() {
        var w = CallEndWatcher(grace: 30)
        w.begin(app: nil, inputProcesses: [])
        #expect(w.app == nil)
        #expect(w.update(inputProcesses: ["com.apple.VoiceMemos"], now: t0) == .none)
        #expect(w.app == nil)
        #expect(w.update(inputProcesses: ["com.microsoft.teams2"], now: t0 + 5) == .none)
        #expect(w.app == "com.microsoft.teams2")
        #expect(w.update(inputProcesses: [], now: t0 + 10) == .released)
        #expect(w.callEnded(now: t0 + 40))
    }

    @Test func anAppNeverSeenOnTheMicCannotEndTheCall() {
        var w = CallEndWatcher(grace: 30)
        w.begin(app: "us.zoom.xos", inputProcesses: [])
        #expect(w.update(inputProcesses: ["com.apple.VoiceMemos"], now: t0) == .none)
        #expect(!w.callEnded(now: t0 + 100))
    }

    @Test func keepRecordingStopsWatching() {
        var w = CallEndWatcher(grace: 30)
        w.begin(app: "us.zoom.xos", inputProcesses: ["us.zoom.xos"])
        _ = w.update(inputProcesses: [], now: t0)
        w.dismiss()
        #expect(!w.callEnded(now: t0 + 100))
        #expect(w.update(inputProcesses: ["us.zoom.xos"], now: t0 + 110) == .none)
        #expect(w.update(inputProcesses: [], now: t0 + 120) == .none)
        // A new recording watches again.
        w.end()
        w.begin(app: "us.zoom.xos", inputProcesses: ["us.zoom.xos"])
        #expect(w.update(inputProcesses: [], now: t0 + 200) == .released)
    }
}
