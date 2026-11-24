import AppKit
import ReMeetKit
import SwiftUI

/// Developer aid: `ReMeet --snapshots <dir>` renders the main views (real code, sample state)
/// into an offscreen window in light and dark, writes PNGs and quits. Lets the build be
/// checked visually without driving the menu bar. Never runs in normal use.
@MainActor
enum SnapshotRenderer {
    static var requestedDirectory: URL? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--snapshots"), index + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[index + 1], isDirectory: true)
    }

    struct Shot {
        var name: String
        var size: CGSize
        var prepare: () -> Void = {}
        var view: () -> AnyView
    }

    /// Filled in per phase with the screens that exist.
    static func shots(model: AppModel) -> [Shot] {
        [
            Shot(name: "menubar-idle", size: CGSize(width: 320, height: 460),
                 prepare: {
                     SampleData.install(model: model, select: -1)
                     model.recorder.debugSetPreview(recording: false)
                 }) {
                AnyView(MenuBarView().environment(model).tint(Theme.accentFill))
            },
            Shot(name: "menubar-recording", size: CGSize(width: 360, height: 520),
                 prepare: { model.recorder.debugSetPreview(recording: true) }) {
                AnyView(MenuBarView().environment(model).tint(Theme.accentFill))
            },
            Shot(name: "bubble-pill", size: BubbleController.collapsedSize,
                 prepare: {
                     model.recorder.debugSetPreview(recording: true)
                     model.bubble.state.expanded = false
                 }) {
                AnyView(BubbleView(controller: model.bubble, state: model.bubble.state).environment(model))
            },
            Shot(name: "bubble-note", size: BubbleController.expandedSize,
                 prepare: {
                     model.recorder.debugSetPreview(recording: true)
                     model.bubble.state.expanded = true
                     model.bubble.state.openedAt = 1300
                     model.bubble.state.draft = "Ask Tom about the refund API"
                 }) {
                AnyView(BubbleView(controller: model.bubble, state: model.bubble.state).environment(model))
            },
            Shot(name: "transcript", size: CGSize(width: 380, height: 560),
                 prepare: { SampleData.install(model: model, select: 0) }) {
                let folder = MeetingFolder.scan(root: SampleData.root).first { $0.name.contains("weekly") }!
                return AnyView(TranscriptInspector(document: MeetingDocument(folder: folder), player: PlayerModel())
                    .environment(model).tint(Theme.accentFill))
            },
            Shot(name: "welcome", size: CGSize(width: 600, height: 520)) {
                AnyView(FirstLaunchView().environment(model).tint(Theme.accentFill))
            },
            Shot(name: "settings", size: CGSize(width: 760, height: 540)) {
                AnyView(SettingsRoot().environment(model).tint(Theme.accentFill))
            },
            Shot(name: "settings-transcription", size: CGSize(width: 760, height: 640)) {
                AnyView(SettingsRoot(initialPane: .transcription).environment(model).tint(Theme.accentFill))
            },
            Shot(name: "meeting-summary", size: CGSize(width: 1040, height: 760),
                 prepare: {
                     model.recorder.debugSetPreview(recording: false)
                     SampleData.install(model: model, select: 0)
                     model.requestedTab = .meetings
                 }) {
                AnyView(MeetingWindowRoot().environment(model).tint(Theme.accentFill))
            },
            Shot(name: "schedule-prep", size: CGSize(width: 1040, height: 720),
                 prepare: {
                     SampleData.install(model: model, select: -1)
                     model.requestedTab = .schedule
                     model.selectedCalendarEventID = "sample-sync-next"
                 }) {
                AnyView(MeetingWindowRoot().environment(model).tint(Theme.accentFill))
            },
            Shot(name: "people-detail", size: CGSize(width: 1040, height: 720),
                 prepare: {
                     SampleData.install(model: model, select: -1)
                     model.requestedTab = .people
                     model.selectedPersonID = model.hub.people.first?.id
                 }) {
                AnyView(MeetingWindowRoot().environment(model).tint(Theme.accentFill))
            },
            Shot(name: "moments-gallery", size: CGSize(width: 1040, height: 680),
                 prepare: {
                     SampleData.install(model: model, select: -1)
                     model.requestedTab = .moments
                 }) {
                AnyView(MeetingWindowRoot().environment(model).tint(Theme.accentFill))
            },
            Shot(name: "settings-calendar", size: CGSize(width: 760, height: 540),
                 prepare: { SampleData.install(model: model, select: 0) }) {
                AnyView(SettingsRoot(initialPane: .calendar).environment(model).tint(Theme.accentFill))
            },
            Shot(name: "sound-check", size: CGSize(width: 470, height: 340)) {
                let probe = LevelProbe()
                probe.debugSetPreview()
                return AnyView(SoundCheckSheet(probe: probe).environment(model).tint(Theme.accentFill))
            },
            Shot(name: "menubar-audio-warning", size: CGSize(width: 340, height: 470),
                 prepare: {
                     let issue = AudioHealthIssue(
                         kind: .micDeviceMismatch,
                         pillLabel: "Wrong mic?",
                         title: "Zoom is using AirPods Pro",
                         detail: "ReMeet is recording MacBook Pro Microphone. Switch to AirPods Pro so your voice comes through clearly.",
                         action: .followMeetingMic
                     )
                     model.recorder.debugSetPreview(recording: true, issue: issue)
                 }) {
                AnyView(MenuBarView().environment(model).tint(Theme.accentFill))
            },
            Shot(name: "meeting-failed", size: CGSize(width: 1000, height: 660),
                 prepare: {
                     SampleData.install(model: model, select: 1)
                     model.requestedTab = .meetings
                 }) {
                AnyView(MeetingWindowRoot().environment(model).tint(Theme.accentFill))
            },
            Shot(name: "meeting-narrow-inspector", size: CGSize(width: 880, height: 680),
                 prepare: {
                     SampleData.install(model: model, select: 0)
                     model.requestedTab = .meetings
                 }) {
                AnyView(MeetingWindowRoot(initialShowTranscript: true).environment(model).tint(Theme.accentFill))
            },
            Shot(name: "commitments-radar", size: CGSize(width: 880, height: 640),
                 prepare: {
                     SampleData.install(model: model, select: 0)
                     model.requestedTab = .schedule
                 }) {
                AnyView(MeetingWindowRoot(initialScheduleSelection: .commitmentsRadar).environment(model).tint(Theme.accentFill))
            },
        ]
    }

    static func run(into directory: URL, model: AppModel) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        model.library.reloadNow()
        for shot in shots(model: model) {
            for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                shot.prepare()
                let url = directory.appendingPathComponent("\(shot.name)-\(suffix).png")
                render(shot, appearance: NSAppearance(named: appearance)!, to: url)
            }
        }
        model.recorder.debugSetPreview(recording: false)
        print("snapshots written to \(directory.path)")
        NSApp.terminate(nil)
    }

    private static func render(_ shot: Shot, appearance: NSAppearance, to url: URL) {
        let hosting = NSHostingView(rootView: shot.view()
            .frame(width: shot.size.width, height: shot.size.height, alignment: .top)
            .background(Theme.bg))
        hosting.frame = CGRect(origin: .zero, size: shot.size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
    }
}
