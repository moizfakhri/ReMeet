import AVFoundation
import AppKit
import ReMeetKit

/// Developer aid: `ReMeet --selftest <name>` exercises real UI code with synthesized input,
/// prints PASS/FAIL lines and exits with the failure count. Never runs in normal use.
@MainActor
enum SelfTest {
    static var requested: String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--selftest"), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    private static var failures = 0

    static func run(_ name: String, model: AppModel) {
        setvbuf(stdout, nil, _IONBF, 0)
        Task { @MainActor in
            switch name {
            case "bubble": await bubble(model: model)
            case "bubbledemo": await bubbleDemo(model: model)
            case "callend": await callEndTest(model: model)
            case "copyforai": await copyForAITest()
            case "reminders": await remindersTest(model: model)
            case "folders": await foldersTest()
            case "window": await windowChrome(model: model)
            case "compress": await compress()
            case "player": await playerTest()
            case "models": await modelsTest(model: model)
            case "download": await downloadOne(model: model)
            case "speech": await speechTest(model: model)
            case "backends": await backendsTest()
            case "search": await searchTest()
            case "processmonitor": await processMonitorTest()
            case "holdmic": await holdMic()
            case "tapfilter": await tapFilterTest()
            case "dataset": makeDataset()
            case "compose": composeLong()
            case "process": await processFolder(model: model)
            case "bughunt": await BugHuntTests.run(model: model)
            default: check(false, "unknown self-test \(name)")
            }
            print(failures == 0 ? "SELFTEST OK" : "SELFTEST FAILED: \(failures)")
            exit(Int32(failures))
        }
    }

    static func check(_ condition: Bool, _ label: String) {
        print("\(condition ? "PASS" : "FAIL")  \(label)")
        if !condition { failures += 1 }
    }

    static func pause(_ seconds: Double = 0.4) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    // MARK: - Bubble

    private static func bubble(model: AppModel) async {
        let bubble = model.bubble
        var notes: [MeetingNote] = []
        var clock = 42.0
        bubble.timestamp = { clock }
        bubble.isRecordingActive = { true }
        bubble.isHiddenBySetting = { false }
        bubble.onNote = { notes.append($0) }

        bubble.recordingStarted()
        await pause()
        guard let panel = bubble.panelForTesting else { return check(false, "panel created") }
        check(panel.isVisible, "pill visible when recording starts")
        check(panel.level == .floating, "panel level floating")
        check(panel.collectionBehavior.contains(.canJoinAllSpaces)
              && panel.collectionBehavior.contains(.fullScreenAuxiliary), "joins all Spaces and full-screen apps")
        check(panel.styleMask.contains(.nonactivatingPanel), "non-activating")
        check(!NSApp.isActive, "ReMeet did not activate")
        check(panel.frame.size == BubbleController.collapsedSize, "collapsed size \(panel.frame.size)")
        check(panel.sharingType != .none, "pill stays visible to screen capture")
        bubble.hidePill()
        await pause()
        check(!panel.isVisible, "hide pill hides the window")
        bubble.showPill()
        await pause()
        check(panel.isVisible, "show pill brings it back")
        bubble.noteScreenShare(true)
        await pause()
        check(!panel.isVisible, "screen sharing hides the pill")
        bubble.showPill()
        await pause()
        check(panel.isVisible, "show pill during a share brings it back")
        bubble.noteScreenShare(false)
        await pause()
        check(panel.isVisible, "pill stays up when sharing stops")

        // Hover opens the field after a rest long enough to click Hide. A draft survives the pointer leaving.
        bubble.pointerHover(true)
        await pause(0.4)
        check(!bubble.state.expanded, "a short hover does not open the note field")
        await pause(BubbleController.hoverOpenDelay)
        check(bubble.state.expanded && panel.isKeyWindow && panel.frame.size == BubbleController.expandedSize,
              "a resting hover opens and focuses the note field")
        bubble.state.draft = "keep"
        bubble.pointerHover(false)
        await pause(0.7)
        check(bubble.state.expanded && bubble.state.draft == "keep", "mouse leave keeps a draft")
        bubble.state.draft = ""
        bubble.pointerHover(false)
        // 0.45 s leave delay, then the window shrinks once the 0.3 s morph has finished.
        // Polled (up to 2 s) rather than one fixed wait: on a busy Mac the morph's
        // completion can land a little later, which made this check flaky.
        for _ in 0..<20 where bubble.state.expanded || panel.frame.size != BubbleController.collapsedSize {
            await pause(0.1)
        }
        check(!bubble.state.expanded && panel.frame.size == BubbleController.collapsedSize,
              "mouse leave closes an empty note")

        // 1. Typed note + Return. Time is when the field opened, not when Return was pressed.
        bubble.openNoteField()
        await pause()
        check(panel.isKeyWindow, "panel is key while the field is open")
        check(panel.frame.size == BubbleController.expandedSize, "expanded size")
        clock = 50
        type("Ask Tom about refunds", into: panel)
        key(36, "\r", into: panel)
        await pause()
        check(notes.count == 1 && notes.last?.kind == .note && notes.last?.text == "Ask Tom about refunds",
              "Return saves a note: \(notes.last.map { "\($0.kind) '\($0.text)'" } ?? "none")")
        check(notes.last?.t == 42, "note time is when the field opened (42), got \(notes.last?.t ?? -1)")
        check(!bubble.state.expanded && panel.frame.size == BubbleController.collapsedSize, "collapses after save")

        // 2. Command-Return = action item.
        clock = 60
        bubble.openNoteField()
        await pause()
        type("Send the deck", into: panel)
        key(36, "\r", modifiers: .command, into: panel)
        await pause()
        check(notes.count == 2 && notes.last?.kind == .action && notes.last?.t == 60, "Cmd-Return saves an action item")

        // 3. Empty Return = bookmark.
        clock = 70
        bubble.openNoteField()
        await pause()
        key(36, "\r", into: panel)
        await pause()
        check(notes.count == 3 && notes.last?.kind == .bookmark && notes.last?.t == 70, "empty Return saves a bookmark")

        // 4. Escape cancels.
        bubble.openNoteField()
        await pause()
        type("never mind", into: panel)
        key(53, "\u{1b}", into: panel)
        await pause()
        check(notes.count == 3, "Escape saves nothing")
        check(!bubble.state.expanded, "Escape collapses")

        // 5. Stop hides it.
        bubble.recordingStopped()
        await pause()
        check(!panel.isVisible, "hidden when recording stops")
    }

    // MARK: - Window resize

    /// Opens the meeting window and checks it can grow and shrink. The split view used
    /// to pin contentMinSize to the current size, so the window only grew.
    private static func windowChrome(model: AppModel) async {
        let key = SettingsKey.hasCompletedFirstLaunch
        let previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(true, forKey: key)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        NSApp.windows.filter { $0.title.contains("Welcome") }.forEach { $0.close() }

        var meeting: NSWindow?
        for _ in 0..<24 {
            model.openMeetings()
            meeting = NSApp.windows.first { $0.title == "ReMeet" }
            if meeting != nil { break }
            await pause(0.25)
        }
        guard let meeting else {
            check(false, "meeting window opened. windows: \(NSApp.windows.map(\.title))")
            return
        }
        await pause(0.8)
        let min = meeting.contentMinSize
        check(meeting.styleMask.contains(.resizable), "meeting window is resizable")
        check(min.width > 400 && min.width <= 780, "meeting min width \(min.width) is a floor, not the current size \(meeting.frame.width)")
        check(min.height > 300 && min.height <= 600, "meeting min height \(min.height) is a floor, not the current size \(meeting.frame.height)")
        let bigger = NSRect(x: meeting.frame.minX, y: meeting.frame.minY - 100,
                            width: meeting.frame.width + 180, height: meeting.frame.height + 100)
        meeting.setFrame(bigger, display: true, animate: false)
        await pause(0.35)
        check(meeting.frame.width > bigger.width - 24, "meeting window grew to \(Int(meeting.frame.width)) (asked \(Int(bigger.width)))")
        let smaller = NSRect(x: bigger.minX, y: bigger.minY + 40, width: 820, height: 560)
        meeting.setFrame(smaller, display: true, animate: false)
        await pause(0.35)
        check(meeting.frame.width < bigger.width - 60,
              "meeting window shrank to \(Int(meeting.frame.width)) from \(Int(bigger.width)) (min \(Int(meeting.contentMinSize.width)))")
        check(meeting.frame.height < bigger.height - 40,
              "meeting window height shrank to \(Int(meeting.frame.height)) from \(Int(bigger.height))")

        model.openSettings()
        var settings: NSWindow?
        for _ in 0..<16 {
            settings = NSApp.windows.first {
                $0 !== meeting && ($0.title.localizedCaseInsensitiveContains("settings") || $0.title == "General")
            }
            if settings != nil { break }
            await pause(0.25)
        }
        guard let settings else {
            check(false, "settings window opened. windows: \(NSApp.windows.map(\.title))")
            return
        }
        await pause(0.4)
        let settingsBefore = settings.frame
        let settingsBigger = NSRect(x: settingsBefore.minX, y: settingsBefore.minY - 80,
                                    width: settingsBefore.width + 120, height: settingsBefore.height + 80)
        settings.setFrame(settingsBigger, display: true, animate: false)
        await pause(0.3)
        check(settings.frame.width > settingsBefore.width + 40,
              "settings window grew to \(Int(settings.frame.width)) from \(Int(settingsBefore.width))")
        settings.setFrame(settingsBefore, display: true, animate: false)
        await pause(0.3)
        check(abs(settings.frame.width - settingsBefore.width) < 30,
              "settings window shrank back to \(Int(settings.frame.width))")
    }

    /// Not a check: cycles pill -> note field -> pill so the animation can be screen-recorded.
    private static func bubbleDemo(model: AppModel) async {
        let bubble = model.bubble
        bubble.timestamp = { 42 }
        bubble.isRecordingActive = { true }
        bubble.isHiddenBySetting = { false }
        bubble.onNote = { _ in }
        bubble.recordingStarted()
        if let panel = bubble.panelForTesting {
            let primary = NSScreen.screens.first?.frame ?? .zero
            print("DEMO panel \(panel.frame) on screen \(panel.screen?.frame ?? .zero), primary \(primary)")
        }
        await pause(1.5)
        for _ in 0..<3 {
            bubble.openNoteField()
            await pause(1.5)
            bubble.cancel()
            await pause(1.5)
        }
        bubble.recordingStopped()
    }

    // MARK: - Stop when the call ends

    /// Records for real (run with `-storageFolder <tmp> -callEndGraceSeconds 1
    /// -callEndCountdownSeconds 2`) and feeds the mic-user list the process monitor would
    /// report, since a test cannot make Zoom take and release the mic.
    private static func callEndTest(model: AppModel) async {
        let zoom: Set<String> = ["us.zoom.xos"]
        let bubble = model.bubble
        func record() async -> Bool {
            model.meetingAppsUsingMic(zoom)
            model.startRecording(for: MeetingApp.match("us.zoom.xos"))
            for _ in 0..<50 where !model.recorder.isRecording { await pause(0.1) }
            return model.recorder.isRecording
        }
        func stopAndWait() async {
            if model.recorder.isRecording { model.recorder.stop() }
            for _ in 0..<100 where model.recorder.state != .idle { await pause(0.1) }
        }

        guard await record() else { return check(false, "recording started") }
        // 1. Zoom lets go, then takes the mic back during the countdown: nothing stops.
        model.meetingAppsUsingMic([])
        await pause(0.6)
        check(bubble.state.callEndCountdown == nil, "no countdown before the grace period")
        await pause(0.9)
        check(bubble.state.callEndCountdown != nil && bubble.isVisible, "countdown shows in the pill after the grace period")
        model.meetingAppsUsingMic(zoom)
        await pause(0.2)
        check(bubble.state.callEndCountdown == nil, "Zoom taking the mic back cancels the countdown")
        await pause(2.5)
        check(model.recorder.isRecording, "still recording after the cancelled countdown")

        // 2. Keep recording: no automatic stop for the rest of this recording.
        model.meetingAppsUsingMic([])
        await pause(1.5)
        check(bubble.state.callEndCountdown != nil, "countdown shows again")
        model.keepRecordingAfterCallEnd()
        await pause(3)
        check(model.recorder.isRecording && bubble.state.callEndCountdown == nil, "Keep recording keeps it running")
        await stopAndWait()

        // 3. Zoom does not come back: the recording stops by itself and is kept.
        guard await record() else { return check(false, "second recording started") }
        model.meetingAppsUsingMic([])
        await pause(4.5)
        check(!model.recorder.isRecording, "recording stops after grace + countdown")
        check(bubble.state.callEndCountdown == nil, "countdown cleared after the stop")
        await stopAndWait()

        // 4. Setting off: never stops on its own.
        UserDefaults.standard.set(false, forKey: SettingsKey.stopWhenCallEnds)
        defer { UserDefaults.standard.removeObject(forKey: SettingsKey.stopWhenCallEnds) }
        guard await record() else { return check(false, "third recording started") }
        model.meetingAppsUsingMic([])
        await pause(4.5)
        check(model.recorder.isRecording && bubble.state.callEndCountdown == nil, "setting off: keeps recording")
        await stopAndWait()
    }

    // MARK: - Calendar reminders

    /// Feeds made-up calendar events (the real calendar is never read or changed) and checks
    /// the reminder fires a minute before, names the recording, and that a call joined from
    /// a lobby is matched to its event. Records for real: run with `-storageFolder <tmp>
    /// -hasCompletedFirstLaunch YES -askWhenMeetingStarts YES`.
    private static func remindersTest(model: AppModel) async {
        let now = Date()
        var events = [
            CalendarMeeting(id: "sync", title: "Weekly sync with Priya", start: now.addingTimeInterval(62),
                            end: now.addingTimeInterval(1862), attendeeNames: ["Priya"],
                            linkText: "https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc"),
            CalendarMeeting(id: "focus", title: "Focus time", start: now.addingTimeInterval(61), end: now.addingTimeInterval(3600)),
        ]
        model.calendar.source = { events }
        UserDefaults.standard.set(true, forKey: SettingsKey.remindBeforeCalendarMeetings)
        defer { UserDefaults.standard.removeObject(forKey: SettingsKey.remindBeforeCalendarMeetings) }
        model.calendarRemindersChanged()

        await pause(1)
        check(!model.prompt.isVisible, "no reminder earlier than a minute before")
        await pause(2)
        check(model.prompt.isVisible && model.prompt.event?.id == "sync", "reminder a minute before the meeting (\(model.prompt.event?.title ?? "none"))")
        check(model.prompt.event?.id != "focus", "a block with nobody else and no call link is skipped")

        // Record from the reminder: the recording is named after the event.
        model.startRecording(for: nil, event: model.prompt.event)
        for _ in 0..<50 where !model.recorder.isRecording { await pause(0.1) }
        check(model.recorder.isRecording && model.recorder.title == "Weekly sync with Priya", "recording named after the event (\(model.recorder.title))")
        check(!model.prompt.isVisible, "reminder closes when recording starts")
        model.recorder.stop()
        for _ in 0..<100 where model.recorder.state != .idle { await pause(0.1) }

        // A Teams call joined 3 minutes after a calendar meeting started is named after it.
        events = [CalendarMeeting(id: "review", title: "Design review", start: now.addingTimeInterval(-180),
                                  end: now.addingTimeInterval(1800), attendeeNames: ["Sam", "Lee"])]
        model.calendar.reload()
        model.meetingAppsUsingMic([])
        model.meetingAppsUsingMic(["com.microsoft.teams2"])
        await pause(0.3)
        check(model.prompt.isVisible && model.prompt.app?.name == "Teams" && model.prompt.event?.title == "Design review",
              "mic prompt for Teams names the calendar meeting (\(model.prompt.event?.title ?? "none"))")
        model.prompt.hide()

        // Setting off: no reminders at all.
        UserDefaults.standard.set(false, forKey: SettingsKey.remindBeforeCalendarMeetings)
        events = [CalendarMeeting(id: "late", title: "Late", start: Date().addingTimeInterval(61), end: Date().addingTimeInterval(900),
                                  attendeeNames: ["Priya"])]
        model.calendarRemindersChanged()
        await pause(2.5)
        check(!model.prompt.isVisible, "setting off: no reminder")
    }

    // MARK: - Folders

    /// Folders with context, end to end on a temporary storage folder: create, move, filter
    /// counts, the context in the summary request and in Copy for AI, delete keeps meetings.
    private static func foldersTest() async {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent("remeet-folders-\(UUID())")
        defer { try? FileManager.default.removeItem(at: storage) }
        let meetings = storage.appendingPathComponent("meetings")
        try? FileManager.default.createDirectory(at: meetings, withIntermediateDirectories: true)
        var folders: [MeetingFolder] = []
        for title in ["Team sync", "1:1"] {
            let folder = MeetingFolder.makeNew(in: meetings, start: Date(), title: title)
            try? FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
            try? folder.writeMeta(MeetingMeta(title: title, status: .transcribed, startTime: Date()))
            try? folder.write(Transcript(engine: "x", segments: [
                TranscriptSegment(start: 2, end: 6, speaker: "speaker_1", text: "Loop closure works on the new map.", source: .system)]), .transcript)
            folders.append(folder)
        }
        let library = MeetingLibrary(root: meetings)
        library.reloadNow()
        guard let lab = library.createCollection(named: "  Projects ") else { return check(false, "folder created") }
        library.updateCollection(lab.id, context: "Priya leads releases; we focus on payments.")
        check(library.collections.map(\.name) == ["Projects"], "folder saved with a trimmed name")
        library.move(folders[0], to: lab.id)
        check((try? folders[0].readMeta().collectionID) == lab.id, "move writes the folder into meta.json")
        check(library.items.filter { $0.meta.collectionID == lab.id }.count == 1, "folder holds one meeting")
        check(MeetingLibrary(root: meetings).collections.first?.context == "Priya leads releases; we focus on payments.", "folders survive a reload")

        // The summary request carries the folder's context; the other meeting's does not.
        final class Capture: Summarizer, @unchecked Sendable {
            var prompts: [String] = []
            let kind = SummaryBackendKind.builtIn
            func modelName() async -> String { "capture" }
            func contextTokens() async -> Int { 32_000 }
            func complete(system: String, user: String) async throws -> String {
                prompts.append(user)
                return #"{"title":"Sync","summary":[{"text":"Loop closure works.","t":"0:02"}],"decisions":[],"action_items":[],"open_questions":[],"your_notes":[]}"#
            }
            func unload() async {}
        }
        let capture = Capture()
        for folder in folders {
            try? await SummarizeRunner(summarizer: { _ in capture }, customInstructions: { "" }, useSonnet: false).run(folder) { _ in }
        }
        check(capture.prompts.count == 2 && capture.prompts[0].contains("Priya leads releases; we focus on payments."), "folder context in that meeting's summary request")
        check(capture.prompts.count == 2 && !capture.prompts[1].contains("Priya leads releases"), "no context for a meeting outside the folder")

        let saved = NSPasteboard.general.string(forType: .string)
        await AIClipboard.copy(folders[0])
        let copied = NSPasteboard.general.string(forType: .string) ?? ""
        NSPasteboard.general.clearContents()
        if let saved { NSPasteboard.general.setString(saved, forType: .string) }
        check(copied.contains("- Folder: Projects") && copied.contains("Priya leads releases; we focus on payments."), "Copy for AI includes the folder and its context")

        library.deleteCollection(lab.id)
        check(library.collections.isEmpty && (try? folders[0].readMeta().collectionID) == nil
              && FileManager.default.fileExists(atPath: folders[0].url.path), "deleting the folder keeps its meetings")
    }

    // MARK: - Copy for AI

    /// `--selftest copyforai <meeting folder>`: both copy paths put the same Markdown on the
    /// clipboard (the clipboard is restored afterwards).
    private static func copyForAITest() async {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "copyforai"), i + 1 < args.count else { return check(false, "usage: copyforai <folder>") }
        let folder = MeetingFolder(url: URL(fileURLWithPath: args[i + 1], isDirectory: true))
        let saved = NSPasteboard.general.string(forType: .string)
        defer {
            NSPasteboard.general.clearContents()
            if let saved { NSPasteboard.general.setString(saved, forType: .string) }
        }
        guard let document = MeetingDocument(folder: folder) else { return check(false, "meeting loads") }
        AIClipboard.copy(document)
        let fromWindow = NSPasteboard.general.string(forType: .string) ?? ""
        await AIClipboard.copy(folder)
        let fromSidebar = NSPasteboard.general.string(forType: .string) ?? ""
        let lines = fromWindow.split(separator: "\n")
        check(fromWindow.hasPrefix("# Meeting: ") && fromWindow.contains("## Transcript"), "Markdown with a transcript section")
        check(fromWindow == fromSidebar, "window and sidebar copies match")
        print("  \(lines.count) lines, \(fromWindow.count) characters; first lines:")
        lines.prefix(12).forEach { print("    \($0.prefix(110))") }
    }

    // MARK: - Compression + queue

    static func makeTestMeeting(seconds mic: Double, _ system: Double, root: URL) throws -> MeetingFolder {
        let folder = MeetingFolder.makeNew(in: root, start: Date(), title: "Self test")
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        try writeTone(folder.file(.micWAV), seconds: mic, hz: 440)
        try writeTone(folder.file(.systemWAV), seconds: system, hz: 660)
        var meta = MeetingMeta(title: "Self test", status: .recorded, startTime: Date())
        meta.durationSeconds = max(mic, system)
        try folder.writeMeta(meta)
        return folder
    }

    /// Same format as TrackWriter: 48 kHz mono 16-bit PCM WAV.
    static func writeTone(_ url: URL, seconds: Double, hz: Double) throws {
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000.0,
                                       AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                                       AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(seconds * 48_000)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)!
        buffer.frameLength = frames
        let data = buffer.floatChannelData![0]
        for i in 0..<Int(frames) { data[i] = Float(0.5 * sin(2 * .pi * hz * Double(i) / 48_000)) }
        try file.write(from: buffer)
    }

    static func duration(_ url: URL) -> Double {
        guard let f = try? AVAudioFile(forReading: url) else { return -1 }
        return Double(f.length) / f.fileFormat.sampleRate
    }

    private static func compress() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("remeet-selftest-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        guard let folder = try? makeTestMeeting(seconds: 10, 9.5, root: root) else { return check(false, "make test meeting") }

        let queue = ProcessingQueue()
        queue.enqueue(folder)
        check(queue.current?.stage == .compress || queue.pending.isEmpty, "queue picked it up")
        var waited = 0.0
        while (try? folder.readMeta().status) == .recorded, waited < 30 { await pause(0.2); waited += 0.2 }
        let meta = try? folder.readMeta()
        check(meta?.status == .compressed, "status recorded -> compressed (got \(meta?.status.rawValue ?? "nil"))")
        check(meta?.processing.stageSeconds["compress"] != nil, "stage time recorded")
        for file in [MeetingFolder.File.audio, .mic16k, .system16k] {
            check(folder.exists(file), "\(file.rawValue) exists")
        }
        check(abs(duration(folder.file(.mic16k)) - 10) < 0.05, "mic-16k is 10 s (\(duration(folder.file(.mic16k))))")
        check(abs(duration(folder.file(.system16k)) - 9.5) < 0.05, "system-16k is 9.5 s (\(duration(folder.file(.system16k))))")
        check(abs(duration(folder.file(.audio)) - 10) < 0.25, "audio.m4a is ~10 s (\(duration(folder.file(.audio))))")
        if let f = try? AVAudioFile(forReading: folder.file(.audio)) {
            check(f.fileFormat.sampleRate == 16_000 && f.fileFormat.channelCount == 1, "audio.m4a is 16 kHz mono")
            check(f.fileFormat.settings[AVFormatIDKey] as? UInt32 == kAudioFormatMPEG4AAC, "audio.m4a is AAC")
        }
        if let f = try? AVAudioFile(forReading: folder.file(.mic16k)) {
            check(f.fileFormat.settings[AVFormatIDKey] as? UInt32 == kAudioFormatAppleLossless, "per-track files are ALAC")
        }
        check(!folder.exists(.micWAV) && !folder.exists(.systemWAV), "WAVs deleted after verification")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: folder.url.path))?.filter { $0.contains("partial") } ?? []
        check(leftovers.isEmpty, "no partial files left")

        // Mix contains both tones: measure 440 and 660 Hz energy with a Goertzel filter.
        if let f = try? AVAudioFile(forReading: folder.file(.audio)),
           let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: 16_000) {
            f.framePosition = 16_000
            try? f.read(into: buf, frameCount: 16_000)
            let samples = Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
            let e440 = goertzel(samples, hz: 440), e660 = goertzel(samples, hz: 660), e1000 = goertzel(samples, hz: 1000)
            check(e440 > 50 * e1000 && e660 > 50 * e1000, "mix has both tracks (440: \(Int(e440)), 660: \(Int(e660)), 1000: \(Int(e1000)))")
        }

        // Resume after the WAVs are gone is a no-op.
        do {
            try AudioCompressor.compress(folder) { _ in }
            check(true, "re-running compress after success is a no-op")
        } catch {
            check(false, "re-run threw \(error)")
        }

        // Failure keeps the audio: a meeting with an unreadable WAV fails at compress and keeps it.
        guard let bad = try? makeTestMeeting(seconds: 1, 1, root: root) else { return }
        try? Data("not audio".utf8).write(to: bad.file(.systemWAV))
        queue.enqueue(bad)
        waited = 0
        while (try? bad.readMeta().status) == .recorded, waited < 15 { await pause(0.2); waited += 0.2 }
        let badMeta = try? bad.readMeta()
        check(badMeta?.status == .failed && badMeta?.failure?.stage == .compress, "bad WAV fails at compress stage")
        check(bad.exists(.micWAV) && bad.exists(.systemWAV), "failure never deletes audio")
        check(badMeta?.nextStage == .compress, "retry resumes at compress")
    }

    private static func playerTest() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("remeet-selftest-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        guard let folder = try? makeTestMeeting(seconds: 10, 9.5, root: root) else { return check(false, "make test meeting") }
        let player = PlayerModel()
        player.setMuted(true)

        player.load(folder, knownDuration: 10)
        var waited = 0.0
        while !player.isAvailable, waited < 5 { await pause(0.1); waited += 0.1 }
        check(player.isAvailable, "plays the WAVs before compression (composition)")
        await pause(0.5)
        check(abs(player.duration - 10) < 0.1, "duration 10 s (\(player.duration))")
        player.play()
        await pause(1.2)
        check(player.isPlaying && player.currentTime > 0.6, "time advances while playing (\(player.currentTime))")
        player.speed = 2
        let before = player.currentTime
        await pause(1.0)
        check(player.currentTime - before > 1.5, "2x speed (advanced \(player.currentTime - before) s in 1 s)")
        player.pause()

        try? AudioCompressor.compress(folder) { _ in }
        player.reloadAudio()
        waited = 0
        while !player.isAvailable, waited < 5 { await pause(0.1); waited += 0.1 }
        check(player.isAvailable && folder.exists(.audio), "reloads onto audio.m4a after compression")
        player.seek(to: 7)
        player.speed = 1
        player.play()
        await pause(0.8)
        check(player.currentTime > 7.3 && player.currentTime < 9, "seek then play from 7 s (\(player.currentTime))")
        player.skip(-15)
        check(player.currentTime == 0, "skip back clamps at 0")
        player.skip(15)
        check(abs(player.currentTime - player.duration) < 0.3, "skip forward clamps at the end")
        player.pause()
    }

    /// `--selftest download <model-id>`: downloads one model through ModelManager.
    private static func downloadOne(model: AppModel) async {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "download"), i + 1 < args.count, let id = ModelID(rawValue: args[i + 1]) else {
            return check(false, "usage: --selftest download <\(ModelID.allCases.map(\.rawValue).joined(separator: "|"))>")
        }
        let manager = model.models
        let started = Date()
        manager.download(id)
        var last = -1
        while true {
            await pause(2)
            switch manager.state(id) {
            case .downloading(let p):
                if Int(p * 10) != last { last = Int(p * 10); print("  \(id.rawValue) \(last * 10)%") }
                continue
            default: break
            }
            break
        }
        check(manager.isReady(id), "\(id.displayName): \(manager.state(id)), \(manager.sizeOnDisk(id).byteString) in \(Int(Date().timeIntervalSince(started))) s")
    }

    private static func modelsTest(model: AppModel) async {
        let manager = model.models
        // Cancel-and-resume on the big one first.
        if !manager.isReady(.summaryLLM) {
            manager.download(.summaryLLM)
            while true {
                await pause(0.5)
                if case .downloading(let p) = manager.state(.summaryLLM), p > 0.03 { break }
                if case .failed(let m) = manager.state(.summaryLLM) { return check(false, "summary model download failed: \(m)") }
            }
            manager.cancel(.summaryLLM)
            await pause(2)
            check(manager.state(.summaryLLM) == .missing, "cancel leaves the model missing (not ready)")
        }
        let ids: [ModelID] = [.diarizer, .parakeet, .summaryLLM]
        manager.downloadMissing(ids)
        var lastPrinted: [ModelID: Int] = [:]
        let started = Date()
        while ids.contains(where: { if case .downloading = manager.state($0) { true } else { false } }),
              Date().timeIntervalSince(started) < 3600 {
            await pause(2)
            for id in ids {
                if case .downloading(let p) = manager.state(id) {
                    let decile = Int(p * 10)
                    if decile != lastPrinted[id] { print("  \(id.rawValue) \(decile * 10)%"); lastPrinted[id] = decile }
                }
            }
        }
        for id in ids {
            let state = manager.state(id)
            check(state == .ready, "\(id.displayName) ready (\(state)) in \(manager.directory(id).lastPathComponent), \(manager.sizeOnDisk(id).byteString)")
        }
        print("  download time \(Int(Date().timeIntervalSince(started))) s")
        // A fresh manager sees them as ready from the manifest.
        let fresh = ModelManager()
        check(ids.allSatisfy { fresh.isReady($0) }, "ready state survives a relaunch (manifest)")
    }

    // MARK: - Speech (diarize + transcribe on synthetic multi-voice audio)

    struct Utterance {
        var track: TrackSource
        var start: Double
        var file: URL
        var text: String
    }

    /// `--selftest speech <dir>`: <dir>/manifest.txt has `track|start|file|text` lines.
    private static func speechTest(model: AppModel) async {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "speech"), i + 1 < args.count else { return check(false, "usage: --selftest speech <dir>") }
        let dir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        guard let manifest = try? String(contentsOf: dir.appendingPathComponent("manifest.txt"), encoding: .utf8) else {
            return check(false, "manifest.txt")
        }
        let utterances: [Utterance] = manifest.split(separator: "\n").compactMap { line in
            let p = line.split(separator: "|", maxSplits: 3).map(String.init)
            guard p.count == 4, let start = Double(p[1]) else { return nil }
            return Utterance(track: p[0] == "mic" ? .mic : .system, start: start, file: dir.appendingPathComponent(p[2]), text: p[3])
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("remeet-speech-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = MeetingFolder.makeNew(in: root, start: Date(), title: "Speech test")
        do {
            try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
            let end = try compose(utterances, into: folder)
            var meta = MeetingMeta(title: "Speech test", status: .recorded, startTime: Date())
            meta.durationSeconds = end
            try folder.writeMeta(meta)
            try NotesFile(url: folder.file(.notes)).save([
                MeetingNote(t: 26, text: "Refund endpoint not in admin panel", kind: .note),
                MeetingNote(t: 18, text: "Email partners the new date", kind: .action),
            ])
        } catch {
            return check(false, "compose audio: \(error)")
        }

        let summarize = args.contains("--summarize")
        let queue = ProcessingQueue()
        for (stage, runner) in model.speechRunners() {
            if var transcribe = runner as? TranscribeRunner {
                transcribe.useSonnet = false
                queue.runners[stage] = transcribe
            } else {
                queue.runners[stage] = runner
            }
        }
        if summarize {
            var summary = model.summarizeRunner()
            summary.useSonnet = false
            queue.runners[.summarize] = summary
        }
        let target: MeetingStatus = summarize ? .summarized : .transcribed
        let started = Date()
        queue.enqueue(folder)
        while Date().timeIntervalSince(started) < 600 {
            await pause(0.5)
            let status = (try? folder.readMeta().status) ?? .failed
            if status == target || status == .failed || !queue.waiting.isEmpty { break }
        }
        let meta = try? folder.readMeta()
        check(meta?.status == target, "status -> \(target.rawValue) (\(meta?.status.rawValue ?? "?") \(meta?.failure?.message ?? "") \(queue.waiting.values.first ?? ""))")
        print("  stage seconds: \(meta?.processing.stageSeconds ?? [:]), wall \(Int(Date().timeIntervalSince(started))) s")
        guard let diarization = try? folder.read(Diarization.self, .diarization),
              let transcript = try? folder.read(Transcript.self, .transcript) else { return check(false, "diarization.json + transcript.json written") }
        let speakers = Set(diarization.system.map(\.speaker))
        check(speakers.count == 2, "call track has 2 speakers (found \(speakers.sorted()))")
        check(!diarization.mic.isEmpty && diarization.mic.allSatisfy { $0.speaker == "you" }, "mic track is all You")

        // Each utterance -> the transcript segment overlapping it most.
        var byVoice: [String: Set<String>] = [:]
        let voiceOf = Dictionary(uniqueKeysWithValues: manifest.split(separator: "\n").compactMap { line -> (String, String)? in
            let p = line.split(separator: "|").map(String.init)
            return p.count >= 3 ? (p[2], p[0]) : nil
        })
        _ = voiceOf
        let script = (try? String(contentsOf: dir.appendingPathComponent("script.txt"), encoding: .utf8)) ?? ""
        let voices = script.split(separator: "\n").map { $0.split(separator: "|").map(String.init) }
        for (index, u) in utterances.enumerated() {
            let duration = Self.duration(u.file)
            let best = transcript.segments.max { a, b in
                overlap(a, u.start, u.start + duration) < overlap(b, u.start, u.start + duration)
            }
            let voice = index < voices.count && voices[index].count > 2 ? voices[index][2] : "?"
            if let best { byVoice[voice, default: []].insert(best.speaker) }
            print("  u\(index + 1) \(voice) -> \(best?.speaker ?? "none")")
        }
        check(byVoice.values.allSatisfy { $0.count == 1 }, "each voice maps to exactly one speaker label \(byVoice)")
        let labels = byVoice.values.compactMap(\.first)
        check(Set(labels).count == byVoice.count, "different voices get different labels")
        check(byVoice["Samantha"] == ["you"], "the mic voice is You")

        let reference = utterances.sorted { $0.start < $1.start }.map(\.text).joined(separator: " ")
        let hypothesis = transcript.segments.map(\.text).joined(separator: " ")
        let wer = WordErrorRate.compute(reference: reference, hypothesis: hypothesis)
        print(String(format: "  WER %.1f%%", wer * 100))
        check(wer < 0.10, String(format: "word error rate under 10%% (%.1f%%)", wer * 100))
        check(folder.exists(.transcriptMarkdown), "transcript.md written")
        if summarize {
            guard let summary = try? folder.read(MeetingSummary.self, .summary) else { return check(false, "summary.json written") }
            check((1...6).contains(summary.summary.count), "1-6 summary points (\(summary.summary.count))")
            check(summary.yourNotes.count == 2 && summary.yourNotes.allSatisfy { !$0.context.isEmpty },
                  "both notes covered with context")
            check(summary.actionItems.contains { $0.task.localizedCaseInsensitiveContains("partner") },
                  "action note became an action item")
            check(summary.summary.contains { $0.t != nil }, "summary points carry times")
            check(meta?.title != "Speech test" || summary.title == "Speech test", "meeting title taken from the summary (\(meta?.title ?? ""))")
            check(meta?.processing.summaryBackend == "Built-in model", "backend recorded (\(meta?.processing.summaryBackend ?? "nil"), \(meta?.processing.summaryModel ?? ""))")
            check(folder.exists(.summaryMarkdown), "summary.md written")
            print("---- summary.md ----")
            print((try? String(contentsOf: folder.file(.summaryMarkdown), encoding: .utf8)) ?? "")
        }
        print("---- transcript.md ----")
        print((try? String(contentsOf: folder.file(.transcriptMarkdown), encoding: .utf8)) ?? "")
    }

    private static func overlap(_ s: TranscriptSegment, _ a: Double, _ b: Double) -> Double {
        max(0, min(s.end, b) - max(s.start, a))
    }

    /// Writes mic.wav and system.wav (48 kHz mono 16-bit, like the recorder) with each
    /// utterance at its start time. Returns the length in seconds.
    private static func compose(_ utterances: [Utterance], into folder: MeetingFolder) throws -> Double {
        let rate = 48_000.0
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        var tracks: [TrackSource: [Float]] = [.mic: [], .system: []]
        for u in utterances {
            let file = try AVAudioFile(forReading: u.file)
            let reader = try Downsampler(file: file, to: format)
            var samples: [Float] = []
            while true {
                let chunk = try reader.next(48_000)
                if chunk.frameLength == 0 { break }
                samples += UnsafeBufferPointer(start: chunk.floatChannelData![0], count: Int(chunk.frameLength))
            }
            let offset = Int(u.start * rate)
            var track = tracks[u.track]!
            if track.count < offset + samples.count { track += [Float](repeating: 0, count: offset + samples.count - track.count) }
            for (k, v) in samples.enumerated() { track[offset + k] += v * 0.8 }
            tracks[u.track] = track
        }
        let length = max(tracks[.mic]!.count, tracks[.system]!.count) + Int(rate)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
                                       AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        for (source, file) in [(TrackSource.mic, MeetingFolder.File.micWAV), (.system, .systemWAV)] {
            var track = tracks[source]!
            track += [Float](repeating: 0, count: length - track.count)
            let out = try AVAudioFile(forWriting: folder.file(file), settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(length))!
            buffer.frameLength = AVAudioFrameCount(length)
            track.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: length) }
            try out.write(from: buffer)
        }
        return Double(length) / rate
    }

    // MARK: - LM Studio client against a mocked network

    private static func backendsTest() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("remeet-backends-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockHTTP.self]
        let session = URLSession(configuration: config)
        let summaryJSON = #"{"title":"Release planning","summary":[{"text":"Release moves a week.","t":"0:05"}],"decisions":[],"action_items":[{"owner":"Priya","task":"Email partners","due":"Wed","t":"0:12"}],"open_questions":[],"your_notes":[{"t":"0:08","note":"Check refunds","context":"Refund endpoint exists."}]}"#

        func meeting() throws -> MeetingFolder {
            let folder = MeetingFolder.makeNew(in: root, start: Date(), title: "Backend test")
            try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
            try folder.writeMeta(MeetingMeta(title: "Backend test", status: .transcribed, startTime: Date()))
            try folder.write(Transcript(engine: "x", segments: [
                TranscriptSegment(start: 5, end: 9, speaker: "speaker_1", text: "We move the release a week.", source: .system),
                TranscriptSegment(start: 12, end: 14, speaker: "you", text: "Priya, can you email partners?", source: .mic)]), .transcript)
            try NotesFile(url: folder.file(.notes)).save([MeetingNote(t: 8, text: "Check refunds", kind: .note)])
            return folder
        }

        // LM Studio
        MockHTTP.requests = []
        MockHTTP.handler = { request in
            if request.url!.path.hasSuffix("/api/v0/models") {
                return (200, #"{"data":[{"id":"qwen3-8b","type":"llm","state":"loaded","loaded_context_length":32768}]}"#)
            }
            let reply: [String: Any] = ["choices": [["message": ["role": "assistant", "content": summaryJSON]]]]
            return (200, String(decoding: try! JSONSerialization.data(withJSONObject: reply), as: UTF8.self))
        }
        do {
            let folder = try meeting()
            let lm = LMStudioSummarizer(server: URL(string: "http://localhost:1234")!, model: "", session: session)
            try await SummarizeRunner(summarizer: { _ in lm }, customInstructions: { "Be brief." }, useSonnet: false).run(folder) { _ in }
            let post = MockHTTP.requests.first { $0.url!.path == "/v1/chat/completions" }
            check(post?.httpMethod == "POST", "LM Studio: POST /v1/chat/completions")
            let body = post.flatMap { MockHTTP.body($0) }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let user = ((body?["messages"] as? [[String: Any]])?.last?["content"] as? String) ?? ""
            check(user.contains("[0:08] NOTE: Check refunds") && user.contains("Also: Be brief."), "LM Studio: prompt has notes and custom instructions")
            let summary = try folder.read(MeetingSummary.self, .summary)
            check(summary?.actionItems.first?.owner == "Priya", "LM Studio: summary parsed")
            let meta = try folder.readMeta()
            check(meta.processing.summaryBackend == "LM Studio" && meta.processing.summaryModel == "qwen3-8b",
                  "LM Studio: backend + loaded model recorded (\(meta.processing.summaryModel ?? "nil"))")
            check(meta.title == "Release planning", "LM Studio: title from summary")
        } catch {
            check(false, "LM Studio run threw \(error)")
        }

        // Errors surface as readable messages.
        MockHTTP.handler = { request in
            if request.url!.path.hasSuffix("/api/v0/models") { return (200, #"{"data":[]}"#) }
            return (400, #"{"error":{"message":"No models loaded. Please load a model first."}}"#)
        }
        do {
            let folder = try meeting()
            let lm = LMStudioSummarizer(server: URL(string: "http://localhost:1234")!, model: "", session: session)
            try await SummarizeRunner(summarizer: { _ in lm }, customInstructions: { "" }, useSonnet: false).run(folder) { _ in }
            check(false, "server error should fail")
        } catch {
            check(error.localizedDescription.contains("No models loaded"), "server error -> readable error: \(error.localizedDescription)")
        }
    }

    // MARK: - Search

    private static func searchTest() async {
        try? FileManager.default.removeItem(at: SampleData.root)
        SampleData.write()
        let dbURL = FileManager.default.temporaryDirectory.appendingPathComponent("remeet-index-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }
        guard let index = try? SearchIndex(url: dbURL) else { return check(false, "open index") }
        do {
            let started = Date()
            try index.sync(root: SampleData.root)
            print(String(format: "  initial sync %.0f ms", Date().timeIntervalSince(started) * 1000))
            func ids(_ q: String) -> [String] { ((try? index.search(q)) ?? []).map(\.id) }
            let weekly = MeetingFolder.scan(root: SampleData.root).first { $0.name.contains("weekly") }!
            check(ids("refund endpoint") == [weekly.id], "transcript words find the meeting")
            check(ids("refu") == [weekly.id], "prefix search")
            check(ids("Priya") == [weekly.id], "speaker names and action owners are searchable")
            check(ids("Ask Tom") == [weekly.id], "your notes are searchable")
            check(ids("variant default") == [weekly.id], "summary decisions are searchable")
            check(ids("hiring").count == 1, "titles are searchable")
            check(ids("zebra").isEmpty, "no false hits")
            check(ids("\"OR NEAR(").isEmpty, "FTS syntax in the query is harmless")
            let hit = try index.search("admin panel").first
            check(hit?.snippet.contains("admin panel") == true, "snippet shows the match (\(hit?.snippet ?? ""))")

            // Rename -> only that meeting is re-indexed on the next sync.
            try await Task.sleep(for: .milliseconds(20))
            try weekly.updateMeta { $0.title = "Quarterly roadmap" }
            try index.sync(root: SampleData.root)
            check(ids("quarterly") == [weekly.id], "rename picked up by incremental sync")
            // Deleted folder disappears from results.
            try FileManager.default.removeItem(at: weekly.url)
            try index.sync(root: SampleData.root)
            check(ids("refund").isEmpty, "deleted meeting removed from the index")
        } catch {
            check(false, "search threw \(error)")
        }
        try? FileManager.default.removeItem(at: SampleData.root)
    }

    // MARK: - Process monitor (meeting detection)

    /// Child process: uses the mic for 4 s, then exits.
    private static func holdMic() async {
        let queue = ChunkQueue()
        let mic = MicCapture(queue: queue)
        do { _ = try mic.start() } catch { return check(false, "mic start \(error)") }
        await pause(4)
        mic.stop()
    }

    private static func processMonitorTest() async {
        let monitor = AudioProcessMonitor()
        var events: [(Date, Set<String>)] = []
        monitor.onInputChange = { events.append((Date(), $0)) }
        monitor.start()
        await pause(0.5)
        let baseline = events.last?.1 ?? []
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--selftest", "holdmic"]
        let started = Date()
        try? child.run()
        await pause(6)
        let me = "com.moizfakhri.ReMeet"
        let on = events.first { $0.0 > started && $0.1.contains(me) && !baseline.contains(me) }
        let off = events.last { $0.0 > (on?.0 ?? started) && !$0.1.contains(me) }
        check(on != nil, "child process using the mic was reported (after \(on.map { String(format: "%.2f s", $0.0.timeIntervalSince(started)) } ?? "-"))")
        check(off != nil, "release of the mic was reported")
        check(events.count < 12, "event-driven: \(events.count) callbacks in 6.5 s, no polling")
        monitor.stop()
    }

    // MARK: - Meeting-apps-only tap

    private static func tapFilterTest() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("remeet-tap-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let toneA = root.appendingPathComponent("a.wav"), toneB = root.appendingPathComponent("b.wav")
        try? writeTone(toneA, seconds: 4, hz: 440)
        try? writeTone(toneB, seconds: 4, hz: 1000)

        func record(filterToA: Bool) async -> (Double, Double)? {
            let players = [toneA, toneB].map { url -> Process in
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
                p.arguments = ["-v", "0.05", url.path]
                try? p.run()
                return p
            }
            defer { players.forEach { $0.terminate() } }
            await pause(0.5)
            let pidA = players[0].processIdentifier
            let folder = MeetingFolder.makeNew(in: root, start: Date(), title: filterToA ? "filtered" : "all")
            guard let session = try? RecordingSession(folder: folder, startDate: Date(), title: "t", sourceApp: nil,
                                                      input: nil, output: nil) else { return nil }
            if filterToA {
                session.setProcessFilter { AudioProcessMonitor.processes().filter { $0.pid == pidA }.map(\.object) }
            }
            do { try session.start() } catch { return nil }
            await pause(2)
            await withCheckedContinuation { c in session.stop(input: nil, output: nil) { c.resume() } }
            print("  events: " + session.meta.events.map { "\($0.type): \($0.detail)" }.joined(separator: " | "))
            guard let file = try? AVAudioFile(forReading: folder.file(.systemWAV)),
                  let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return nil }
            try? file.read(into: buf)
            let x = Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
            return (goertzel(x, hz: 440, rate: 48_000), goertzel(x, hz: 1000, rate: 48_000))
        }

        guard let all = await record(filterToA: false), let filtered = await record(filterToA: true) else {
            return check(false, "recordings")
        }
        print(String(format: "  all apps: 440 Hz %.3g, 1000 Hz %.3g | filtered: 440 Hz %.3g, 1000 Hz %.3g", all.0, all.1, filtered.0, filtered.1))
        check(all.0 > 1 && all.1 > 1, "all apps hears both players (system audio permission works)")
        check(filtered.0 > 1, "filtered tap hears the included app")
        check(filtered.1 < filtered.0 / 1000, "filtered tap does not hear the other app")
    }

    // MARK: - Performance dataset

    /// `--selftest dataset <root> <count>`: <count> finished meetings with 1-hour-sized
    /// transcripts (600 turns), summaries and notes, spread over the last 120 days.
    private static func makeDataset() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "dataset"), i + 2 < args.count, let count = Int(args[i + 2]) else {
            return check(false, "usage: --selftest dataset <root> <count>")
        }
        let root = URL(fileURLWithPath: args[i + 1], isDirectory: true).appendingPathComponent("meetings")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let words = "release payments refund partners onboarding retention variant coverage budget roadmap hiring design review customer pricing annual plan support ticket launch migration".split(separator: " ")
        var rng = SystemRandomNumberGenerator()
        for n in 0..<count {
            let start = Date().addingTimeInterval(-Double(n) * 0.8 * 86_400 - 3600)
            let folder = MeetingFolder.makeNew(in: root, start: start, title: "Meeting \(n + 1)")
            try? FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
            var meta = MeetingMeta(title: "Meeting \(n + 1) about \(words[n % words.count])", status: .summarized, startTime: start)
            meta.durationSeconds = 3600
            meta.endTime = start.addingTimeInterval(3600)
            meta.processing.summaryBackend = "Built-in model"
            try? folder.writeMeta(meta)
            let segments = (0..<600).map { k -> TranscriptSegment in
                let text = (0..<16).map { _ in String(words.randomElement(using: &rng)!) }.joined(separator: " ")
                let speaker = k % 3 == 0 ? "you" : "speaker_\(k % 3)"
                return TranscriptSegment(start: Double(k) * 6, end: Double(k) * 6 + 5, speaker: speaker, text: text,
                                         source: speaker == "you" ? .mic : .system)
            }
            try? folder.write(Transcript(engine: "Parakeet TDT 0.6B v2", segments: segments), .transcript)
            try? folder.write(MeetingSummary(title: meta.title,
                                             summary: (0..<5).map { SummaryPoint(text: "Point \($0) about \(words[$0])", t: Double($0) * 600) },
                                             decisions: [SummaryPoint(text: "Decision", t: 1200)],
                                             actionItems: [ActionItem(owner: "Priya", task: "Follow up", due: "Fri", t: 1300)],
                                             yourNotes: [NoteContext(t: 900, note: "Check pricing", context: "Discussed annual plans.")]), .summary)
            try? NotesFile(url: folder.file(.notes)).save([MeetingNote(t: 900, text: "Check pricing", kind: .note)])
        }
        print("dataset: \(count) meetings in \(root.path)")
    }

    // MARK: - Long meeting (Phase 4)

    /// `--selftest compose <utterance-dir> <out-root> <repeats>`: loops the manifest's
    /// 62 s script `repeats` times into one meeting (streamed to disk), with notes.
    private static func composeLong() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "compose"), i + 3 < args.count, let repeats = Int(args[i + 3]) else {
            return check(false, "usage: --selftest compose <dir> <out-root> <repeats>")
        }
        let dir = URL(fileURLWithPath: args[i + 1]), root = URL(fileURLWithPath: args[i + 2])
        guard let manifest = try? String(contentsOf: dir.appendingPathComponent("manifest.txt"), encoding: .utf8) else { return }
        let utterances: [Utterance] = manifest.split(separator: "\n").compactMap { line in
            let p = line.split(separator: "|", maxSplits: 3).map(String.init)
            guard p.count == 4, let start = Double(p[1]) else { return nil }
            return Utterance(track: p[0] == "mic" ? .mic : .system, start: start, file: dir.appendingPathComponent(p[2]), text: p[3])
        }
        let folder = MeetingFolder.makeNew(in: root, start: Date(), title: "Long meeting")
        do {
            try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
            let cycleRoot = root.appendingPathComponent("cycle-\(UUID())")
            defer { try? FileManager.default.removeItem(at: cycleRoot) }
            let cycle = MeetingFolder.makeNew(in: cycleRoot, start: Date(), title: "cycle")
            try FileManager.default.createDirectory(at: cycle.url, withIntermediateDirectories: true)
            let cycleSeconds = try compose(utterances, into: cycle)
            for file in [MeetingFolder.File.micWAV, .systemWAV] {
                let source = try AVAudioFile(forReading: cycle.file(file))
                let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: AVAudioFrameCount(source.length))!
                try source.read(into: buffer)
                let out = try AVAudioFile(forWriting: folder.file(file), settings: source.fileFormat.settings,
                                          commonFormat: .pcmFormatFloat32, interleaved: false)
                for _ in 0..<repeats { try out.write(from: buffer) }
            }
            var meta = MeetingMeta(title: "Long meeting", status: .recorded, startTime: Date())
            meta.durationSeconds = cycleSeconds * Double(repeats)
            try folder.writeMeta(meta)
            var notes: [MeetingNote] = []
            for k in 0..<6 {
                let even = k % 2 == 0
                let text = even ? "Email partners the new date" : "Check refund endpoint"
                let kind: MeetingNote.Kind = even ? .action : .note
                notes.append(MeetingNote(t: Double(k) * 600 + 18, text: text, kind: kind))
            }
            try NotesFile(url: folder.file(.notes)).save(notes)
            print("composed \(folder.url.path) \(Int(cycleSeconds * Double(repeats))) s")
        } catch {
            check(false, "compose \(error)")
        }
    }

    /// `--selftest process <folder>`: runs every stage on the folder and reports wall time
    /// and peak memory footprint per stage.
    private static func processFolder(model: AppModel) async {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "process"), i + 1 < args.count else { return check(false, "usage: --selftest process <folder>") }
        let folder = MeetingFolder(url: URL(fileURLWithPath: args[i + 1], isDirectory: true))
        if let f = args.firstIndex(of: "--from"), f + 1 < args.count, let stage = PipelineStage(rawValue: args[f + 1]) {
            _ = try? folder.updateMeta { $0.rewind(to: stage) }
        }
        let queue = ProcessingQueue()
        for (stage, runner) in model.speechRunners() { queue.runners[stage] = runner }
        queue.runners[.summarize] = model.summarizeRunner()
        var target = MeetingStatus.summarized
        if let f = args.firstIndex(of: "--stop-after"), f + 1 < args.count, let stage = PipelineStage(rawValue: args[f + 1]) {
            target = stage.completedStatus
            for later in PipelineStage.allCases where later > stage { queue.runners[later] = nil }
        }
        var peak: [String: UInt64] = [:]
        let started = Date()
        queue.enqueue(folder)
        while Date().timeIntervalSince(started) < 3600 {
            await pause(1)
            let stage = queue.current?.stage.rawValue ?? "idle"
            if let p = queue.current?.progress { print(String(format: "  progress %@ %.0f%% at %.0f s", stage, p * 100, Date().timeIntervalSince(started))) }
            peak[stage] = max(peak[stage] ?? 0, footprint())
            let status = (try? folder.readMeta().status) ?? .failed
            if status == target || status == .failed || !queue.waiting.isEmpty { break }
        }
        await pause(5)
        print(String(format: "  footprint 5 s after processing: %.0f MB", Double(footprint()) / 1_048_576))
        let meta = try? folder.readMeta()
        check(meta?.status == target, "1-hour meeting processed (\(meta?.status.rawValue ?? "?") \(meta?.failure?.message ?? ""))")
        print("  wall \(Int(Date().timeIntervalSince(started))) s, stage seconds \(meta?.processing.stageSeconds ?? [:])")
        for (stage, bytes) in peak.sorted(by: { $0.key < $1.key }) {
            print(String(format: "  peak footprint during %@: %.0f MB", stage, Double(bytes) / 1_048_576))
        }
        if let t = try? folder.read(Transcript.self, .transcript), let s = try? folder.read(MeetingSummary.self, .summary) {
            print("  transcript segments \(t.segments.count), words \(t.segments.reduce(0) { $0 + $1.text.split(separator: " ").count })")
            print("  summary points \(s.summary.count), action items \(s.actionItems.count), notes covered \(s.yourNotes.count)")
            let speakers = Set(t.segments.map(\.speaker))
            check(speakers.count == 3, "3 speakers over the hour (\(speakers.sorted()))")
        }
    }

    /// phys_footprint of this process (what Activity Monitor calls Memory).
    nonisolated static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    private static func goertzel(_ x: [Float], hz: Double, rate: Double = 16_000) -> Double {
        let k = 2 * cos(2 * .pi * hz / rate)
        var s1 = 0.0, s2 = 0.0
        for v in x { let s = Double(v) + k * s1 - s2; s2 = s1; s1 = s }
        return s1 * s1 + s2 * s2 - k * s1 * s2
    }

    private static func type(_ text: String, into window: NSWindow) {
        for character in text {
            let s = String(character)
            key(0, s, into: window)
        }
    }

    private static func key(_ code: UInt16, _ chars: String, modifiers: NSEvent.ModifierFlags = [], into window: NSWindow) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                                               timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil,
                                               characters: chars, charactersIgnoringModifiers: chars,
                                               isARepeat: false, keyCode: code) else { continue }
            window.sendEvent(event)
        }
    }
}

/// Answers URLSession requests in self-tests without touching the network.
final class MockHTTP: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (URLRequest) -> (Int, String) = { _ in (404, "") }
    nonisolated(unsafe) static var requests: [URLRequest] = []

    static func body(_ request: URLRequest) -> Data? {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        let (status, text) = Self.handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
