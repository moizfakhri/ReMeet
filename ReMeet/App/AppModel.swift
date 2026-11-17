import AppKit
import CoreAudio
import CoreServices
import KeyboardShortcuts
import Observation
import ReMeetKit
import SwiftUI
import UniformTypeIdentifiers

extension KeyboardShortcuts.Name {
    static let toggleRecording = Self("toggleRecording", default: .init(.r, modifiers: [.option, .command]))
    static let addNote = Self("addNote", default: .init(.n, modifiers: [.option, .command]))

    /// The shortcut as the user set it ("⌥⌘R"), or "" if they removed it (audit L1).
    var hint: String { KeyboardShortcuts.getShortcut(for: self)?.description ?? "" }
}

/// UserDefaults keys shared by Settings and the services.
enum SettingsKey {
    static let appearance = "appearance"
    static let showBubble = "showNoteBubble"
    static let storageFolder = "storageFolder"
    static let keepAudioDays = "keepAudioDays"          // 0 = forever
    static let hasCompletedFirstLaunch = "hasCompletedFirstLaunch"
    static let recordingScope = "recordingScope"
    static let askWhenMeetingStarts = "askWhenMeetingStarts"
    static let stopWhenCallEnds = "stopWhenCallEnds"
    static let remindBeforeCalendarMeetings = "remindBeforeCalendarMeetings"
    static let speakerLabels = "speakerLabels"
    static let transcriptionEngine = "transcriptionEngine"
    static let userName = "userName"
    static let summaryBackend = "summaryBackend"
    static let lmStudioURL = "lmStudioURL"
    static let lmStudioModel = "lmStudioModel"
    static let customInstructions = "customInstructions"
    static let notifyWhenReady = "notifyWhenReady"
    static let chatAnswerBackend = "chatAnswerBackend"
}

/// Root object: wires the recorder, the library and (later phases) the pipeline together.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let recorder = RecorderService()
    let library: MeetingLibrary
    let queue = ProcessingQueue()
    let models = ModelManager()
    @ObservationIgnored private(set) lazy var notifier = Notifier()
    @ObservationIgnored private let processMonitor = AudioProcessMonitor()
    @ObservationIgnored private var detector = MeetingDetector()
    @ObservationIgnored private(set) var prompt = MeetingPromptController()
    /// The meeting app currently using the mic, if any (becomes the recording's sourceApp).
    @ObservationIgnored private(set) var activeMeetingApp: MeetingApp?
    /// Search results for the sidebar: meeting id -> snippet, best first; nil when not searching.
    private(set) var searchHits: [(id: String, snippet: String)]?
    @ObservationIgnored private var indexTask: Task<Void, Never>?
    @ObservationIgnored private(set) lazy var searchIndex: SearchIndex? = try? SearchIndex(
        url: meetingsRoot.deletingLastPathComponent().appendingPathComponent("index.sqlite"))
    @ObservationIgnored private(set) lazy var chunkIndex: ChunkIndex? = try? ChunkIndex(
        url: meetingsRoot.deletingLastPathComponent().appendingPathComponent("chunks.sqlite"))
    @ObservationIgnored private var chunkIndexTask: Task<Void, Never>?
    /// Meetings whose summary arrived and that have not been opened yet (menu bar dot).
    private(set) var unseenReady: Set<MeetingFolder> = []
    @ObservationIgnored private(set) lazy var bubble = BubbleController(recorder: recorder)
    /// Transcript time to scroll to (summary "jump to", note click); the inspector consumes it.
    var transcriptJump: Double?
    /// Set with chat citations when switching meetings; the meeting window seeks playback once loaded.
    var pendingCitationPlay: Double?
    /// Menu bar asks the sidebar to rename / trash a meeting or create a folder.
    var sidebarRequest: SidebarRequest?
    /// Menu bar "Find in Transcript": the inspector opens its find field and clears this.
    var transcriptFindPending = false
    /// Toolbar or ⌘L: scroll the open meeting to Chat and focus the question field.
    var chatFocusPending = false
    /// The meeting the meeting window should show next (menu bar "recent" click, notification).
    var selectedMeeting: MeetingFolder?

    @ObservationIgnored private var openWindowAction: OpenWindowAction?
    @ObservationIgnored private var openSettingsAction: OpenSettingsAction?
    /// A Dock click arrived before the menu bar registered `openWindow`.
    @ObservationIgnored private var openMeetingsWhenReady = false
    @ObservationIgnored private var wordingCleanup = 0
    /// Shown when an imported file could not be read.
    var importNotice: String?

    var meetingsRoot: URL {
        if let path = UserDefaults.standard.string(forKey: SettingsKey.storageFolder), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("meetings", isDirectory: true)
        }
        return MeetingFolder.defaultRoot
    }

    private init() {
        UserDefaults.standard.register(defaults: [
            SettingsKey.showBubble: true,
            SettingsKey.speakerLabels: true,
            SettingsKey.notifyWhenReady: true,
            SettingsKey.askWhenMeetingStarts: true,
            SettingsKey.stopWhenCallEnds: true,
            SettingsKey.remindBeforeCalendarMeetings: true,
            SettingsKey.summaryBackend: SummaryBackendKind.builtIn.rawValue,
            SettingsKey.transcriptionEngine: TranscriptionEngine.default.rawValue,
            SettingsKey.chatAnswerBackend: MeetingChatAnswerBackend.default.rawValue,
        ])
        library = MeetingLibrary(root: MeetingFolder.defaultRoot)
        library.root = meetingsRoot
        recorder.meetingsRoot = meetingsRoot
        recorder.onFinished = { [weak self] folder in
            self?.callEndFinished()
            self?.bubble.recordingStopped()
            self?.library.reload()
            self?.recordingFinished(folder)
            self?.presentDeferredReminderIfRelevant()
        }
        // Save a half-typed bubble note before the session closes (audit C3).
        recorder.onWillStop = { [weak self] in self?.bubble.recordingStopped() }
        recorder.onDiscarded = { [weak self] in
            self?.callEndFinished()
            self?.bubble.recordingStopped()
            self?.queue.resume()
            self?.library.reload()
            self?.presentDeferredReminderIfRelevant()
        }
        recorder.onStarted = { [weak self] _ in
            self?.queue.pause()
            self?.library.reload()
            self?.bubble.recordingStarted()
            if !CommandLine.arguments.contains("--selftest") {
                self?.bubble.startShareWatch()
            }
            self?.callEndStarted()
        }
    }

    func launch() {
        library.onEdited = { [weak self] folder in self?.reindex(folder) }
        library.onTrashed = { [weak self] folder in self?.meetingTrashed(folder) }
        queue.onChange = { [weak self] folder in
            self?.library.refresh(folder)
            self?.reindex(folder)
        }
        models.onReady = { [weak self] id in
            self?.queue.retryWaiting()
        }
        installSpeechStages()
        queue.runners[.summarize] = summarizeRunner()
        queue.onFinished = { [weak self] folder, meta in
            self?.unseenReady.insert(folder)
            self?.cleanOldAudio()
            self?.notifier.summaryReady(folder, meta: meta)
        }
        queue.onFailed = { [weak self] folder, failure in self?.notifier.failed(folder, failure: failure) }
        queue.onTranscribed = { [weak self] folder, meta in self?.notifier.transcriptReady(folder, meta: meta) }
        notifier.onOpen = { [weak self] folder in self?.openMeetings(selecting: folder) }
        notifier.isRecording = { [weak self] in self?.recorder.isRecording ?? false }
        try? FileManager.default.createDirectory(at: meetingsRoot, withIntermediateDirectories: true)
        Perf.mark("launch.begin")
        library.recoverInterruptedRecordings(except: nil)
        library.reload { [weak self] in
            guard let self else { return }
            Perf.mark("library.loaded")
            self.queue.enqueuePending(in: self.library)
        }
        syncSearchIndex()
        cleanOldAudio()
        KeyboardShortcuts.onKeyUp(for: .toggleRecording) { [weak self] in
            self?.toggleRecording()
        }
        startMeetingDetection()
        Perf.mark("launch.end")
        if Perf.recordNow { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.toggleRecording() } }
        if let i = CommandLine.arguments.firstIndex(of: "--perf-stop-after"), i + 1 < CommandLine.arguments.count,
           let seconds = Double(CommandLine.arguments[i + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { self.recorder.stop() }
        }
        KeyboardShortcuts.onKeyUp(for: .addNote) { [weak self] in
            self?.addNoteShortcut()
        }
        (AppearanceSetting(rawValue: UserDefaults.standard.string(forKey: SettingsKey.appearance) ?? "") ?? .system).apply()
        models.removeRetiredModels()
        // Accurate chosen before its model existed (or the old Core ML Cohere was in use):
        // fetch the MLX model now instead of leaving meetings waiting.
        if UserDefaults.standard.bool(forKey: SettingsKey.hasCompletedFirstLaunch) {
            models.downloadMissing(transcriptionEngine.models)
        }
    }

    // MARK: - Windows

    /// Captured from a view that always exists (the menu bar label), so shortcuts and
    /// notifications can open windows too.
    func register(openWindow: OpenWindowAction, openSettings: OpenSettingsAction) {
        let first = openWindowAction == nil
        openWindowAction = openWindow
        openSettingsAction = openSettings
        if openMeetingsWhenReady {
            openMeetingsWhenReady = false
            openMeetings()
        }
        if first {
            Perf.mark("menubar.ready")
            if Perf.openWindow {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    Perf.mark("window.open.request")
                    self.openMeetings()
                    // Second open after closing, to compare first vs repeat cost.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        NSApp.windows.first { $0.identifier?.rawValue.contains(WindowID.meetings) == true }?.close()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            Perf.mark("window.reopen.request")
                            self.openMeetings()
                        }
                    }
                }
            }
        }
    }

    func openMeetings(selecting folder: MeetingFolder? = nil) {
        if let folder { selectedMeeting = folder }
        DockPresence.show("meetings")
        DockPresence.makeRegularNow()
        guard let openWindowAction else {
            openMeetingsWhenReady = true
            NSApp.activate()
            return
        }
        openMeetingsWhenReady = false
        openWindowAction(id: WindowID.meetings)
        if let window = Self.meetingsWindow() {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate()
    }

    /// The meetings window, when SwiftUI has created it. Other panels (the recording bar,
    /// the menu) do not count.
    static func meetingsWindow() -> NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.contains(WindowID.meetings) == true }
    }

    /// One wording pass after the user stops naming. A newer save replaces an older wait.
    func scheduleSpeakerWording(_ document: MeetingDocument) async -> WordingResult {
        wordingCleanup += 1
        let token = wordingCleanup
        try? await Task.sleep(for: .seconds(1.5))
        guard token == wordingCleanup else { return WordingResult(message: nil, wrote: false, skipped: true) }
        return await cleanWithSonnet(document)
    }

    /// Asks for a recording, then transcribes it like a meeting ReMeet captured.
    func importMeetingAudioChosen() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .mp3, .wav, .mpeg4Audio, .aiff]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a recording. ReMeet transcribes it and writes a summary."
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                AppModel.shared.importMeetingAudio(from: url)
            }
        }
    }

    /// Copies an existing recording in as a meeting and runs diarize, transcribe, and summary.
    func importMeetingAudio(from url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        let title = url.deletingPathExtension().lastPathComponent
        let folder = MeetingFolder.makeNew(in: library.root, start: Date(), title: title.isEmpty ? "Imported meeting" : title)
        Task {
            do {
                let seconds = try AudioImport.convert(url, into: folder)
                if access { url.stopAccessingSecurityScopedResource() }
                await MainActor.run {
                    self.finishImport(folder, title: title, seconds: seconds, filename: url.lastPathComponent)
                }
            } catch {
                if access { url.stopAccessingSecurityScopedResource() }
                try? FileManager.default.removeItem(at: folder.url)
                let message = error.localizedDescription
                await MainActor.run { self.importNotice = message }
            }
        }
    }

    private func finishImport(_ folder: MeetingFolder, title: String, seconds: Double, filename: String) {
        var meta = MeetingMeta(title: title.isEmpty ? MeetingMeta.defaultTitle : title, status: .compressed, startTime: Date())
        meta.endTime = Date()
        meta.durationSeconds = seconds
        meta.events.append(SessionEvent(time: Date(), offsetSeconds: 0, type: "imported", detail: filename))
        do {
            try folder.writeMeta(meta)
        } catch {
            importNotice = error.localizedDescription
            return
        }
        library.reloadNow()
        openMeetings(selecting: folder)
        queue.enqueue(folder)
    }

    @ObservationIgnored private lazy var builtInSummarizer = BuiltInSummarizer(directory: models.directory(.summaryLLM))
    @ObservationIgnored private let chunkEmbedder = ChunkEmbeddingBackend()

    /// Drain the shared pipeline and any in-flight built-in MLX generation before quit.
    /// Self-tests build a private ProcessingQueue but still use this summarizer instance.
    func drainInferenceForTermination() async {
        await queue.prepareToTerminate()
        await builtInSummarizer.waitUntilIdle()
    }

    /// Summarize stage bound to Settings (also used by self-tests).
    func summarizeRunner() -> SummarizeRunner {
        SummarizeRunner(
            summarizer: { @MainActor [weak self] requested in
                guard let self else { return nil }
                return try self.makeSummarizer(requested ?? self.summaryBackend)
            },
            customInstructions: { UserDefaults.standard.string(forKey: SettingsKey.customInstructions) ?? "" },
            recorderName: { Self.recorderName })
    }

    func makeSummarizer(_ kind: SummaryBackendKind) throws -> Summarizer? {
        let defaults = UserDefaults.standard
        switch kind {
        case .builtIn:
            return models.isReady(.summaryLLM) ? builtInSummarizer : nil
        case .lmStudio:
            let text = defaults.string(forKey: SettingsKey.lmStudioURL) ?? "http://localhost:1234"
            guard let url = URL(string: text.isEmpty ? "http://localhost:1234" : text) else {
                throw BackendError.notConfigured("The LM Studio address in Settings > Summaries is not valid.")
            }
            return LMStudioSummarizer(server: url, model: defaults.string(forKey: SettingsKey.lmStudioModel) ?? "")
        }
    }

    /// Notes edited in the meeting window: keep search in step (MeetingDocument updates Markdown).
    func notesEdited(_ document: MeetingDocument) {
        reindex(document.folder)
    }

    private func meetingTrashed(_ folder: MeetingFolder) {
        unseenReady.remove(folder)
        if selectedMeeting == folder { selectedMeeting = nil }
        queue.remove(folder)
        removeFromSearchIndex(folder)
        removeFromChunkIndex(folder)
    }

    /// True when notes.json is newer than summary.json (offer to regenerate).
    func notesChangedSinceSummary(_ document: MeetingDocument) -> Bool {
        func modified(_ file: MeetingFolder.File) -> Date? {
            (try? FileManager.default.attributesOfItem(atPath: document.folder.file(file).path))?[.modificationDate] as? Date
        }
        guard let notes = modified(.notes), let summary = modified(.summary) else { return false }
        return notes > summary
    }

    /// Failed meetings the user has not dismissed (menu bar warning + popover rows).
    var failedMeetings: [MeetingItem] {
        library.items.filter { $0.meta.hasActiveFailure }
    }

    func retryFailed(_ folder: MeetingFolder) {
        queue.retry(folder)
    }

    /// Hides a failure from the menu bar (the meeting keeps its Retry button).
    func dismissFailure(_ folder: MeetingFolder) {
        _ = try? folder.updateMeta { $0.failure?.dismissed = true }
        library.refresh(folder)
    }

    /// Settings > Note bubble changed: apply to a running recording right away (audit M7).
    func bubbleSettingChanged() {
        guard recorder.isRecording else { return }
        if UserDefaults.standard.bool(forKey: SettingsKey.showBubble) { bubble.recordingStarted() } else { bubble.recordingStopped() }
    }

    func markSeen(_ folder: MeetingFolder) {
        unseenReady.remove(folder)
    }

    @ObservationIgnored private lazy var cohere = CohereMLXTranscriber(directory: models.directory(.cohere))
    @ObservationIgnored private lazy var parakeet = ParakeetTranscriber(directory: models.directory(.parakeet))

    private func installSpeechStages() {
        for (stage, runner) in speechRunners() { queue.runners[stage] = runner }
    }

    /// Diarize and transcribe stages bound to this app's models (also used by self-tests).
    func speechRunners() -> [PipelineStage: StageRunner] {
        var runners: [PipelineStage: StageRunner] = [:]
        runners[.diarize] = DiarizeRunner(
            models: { @MainActor [weak self] in
                guard let self else { return (false, ModelManager.defaultRoot) }
                return (self.models.isReady(.diarizer), self.models.root)
            },
            speakerLabels: { UserDefaults.standard.bool(forKey: SettingsKey.speakerLabels) })
        runners[.transcribe] = TranscribeRunner(
            route: { @MainActor [weak self] folder in
                guard let self else { return nil }
                switch self.transcriptionEngine(for: folder) {
                case .accurate:
                    guard self.models.isReady(.cohere) else { return nil }
                    return .local(self.cohere)
                case .fast, .sonnet:
                    guard self.models.isReady(.parakeet) else { return nil }
                    return .local(self.parakeet)
                }
            },
            releaseModels: { @MainActor [weak self] in
                await self?.parakeet.unload()
                await self?.cohere.unload()
            },
            recorderName: { Self.recorderName })
        return runners
    }

    /// A meeting can pin an engine. Otherwise Settings wins, and that default stays Fast.
    func transcriptionEngine(for folder: MeetingFolder) -> TranscriptionEngine {
        if let raw = (try? folder.readMeta())?.processing.requestedTranscriptionEngine,
           let engine = TranscriptionEngine.resolve(raw) {
            return engine
        }
        return transcriptionEngine
    }

    /// Shown once, the first time the menu bar item appears.
    func showFirstLaunchIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: SettingsKey.hasCompletedFirstLaunch) else { return }
        openWindowAction?(id: WindowID.welcome)
        NSApp.activate()
    }

    /// Models the default pipeline needs: speaker labels if on, Parakeet, and the built-in
    /// summary model only when summaries run on it.
    var requiredModels: [ModelID] {
        // The diarizer is needed even with speaker labels off: it finds where there is speech.
        var ids: [ModelID] = [.diarizer]
        if let model = transcriptionEngine.model { ids.append(model) }
        if summaryBackend == .builtIn { ids.append(.summaryLLM) }
        return ids
    }

    var transcriptionEngine: TranscriptionEngine {
        TranscriptionEngine.resolve(UserDefaults.standard.string(forKey: SettingsKey.transcriptionEngine)) ?? .default
    }

    /// The installed model that serves the chosen engine (the faster Cohere build first).
    var transcriptionModel: ModelID? {
        transcriptionEngine.models.first { models.isReady($0) }
    }

    var summaryBackend: SummaryBackendKind {
        SummaryBackendKind(rawValue: UserDefaults.standard.string(forKey: SettingsKey.summaryBackend) ?? "") ?? .builtIn
    }

    var chatAnswerBackend: MeetingChatAnswerBackend {
        MeetingChatAnswerBackend(rawValue: UserDefaults.standard.string(forKey: SettingsKey.chatAnswerBackend) ?? "") ?? .default
    }

    var lmStudioServerURL: URL? {
        let text = UserDefaults.standard.string(forKey: SettingsKey.lmStudioURL) ?? "http://localhost:1234"
        guard let url = URL(string: text), !text.isEmpty else { return nil }
        return url
    }

    func focusChat() {
        openMeetings()
        chatFocusPending = true
    }

    /// Query vector for hybrid retrieval. Nil means embeddings are unavailable and Chat stays on FTS.
    func embedChatQuery(_ text: String) async -> [Float]? {
        await chunkEmbedder.embedOne(text, modelsRoot: models.root, server: lmStudioServerURL)
    }

    func answerChat(question: String, passages: [MeetingChatPrompt.Passage], history: [MeetingChatTurn],
                    recorderName: String) async throws -> MeetingChatAnswer {
        switch chatAnswerBackend {
        case .sonnet:
            return try await ClaudeSonnet.askMeeting(question: question, passages: passages,
                                                     recorderName: recorderName, history: history)
        case .mlx:
            guard models.isReady(.summaryLLM) else { throw MeetingChatError.modelMissing }
            let prompt = MeetingChatPrompt.user(question: question, passages: passages,
                                                recorderName: recorderName, history: history)
            let reply = try await builtInSummarizer.complete(system: MeetingChatPrompt.system, user: prompt)
            do {
                return try MeetingChatPrompt.parseAnswer(reply)
            } catch {
                throw MeetingChatError.badReply
            }
        }
    }

    /// Settings > Storage changed: new recordings go to the new folder; the list follows.
    func storageFolderChanged() {
        try? FileManager.default.createDirectory(at: meetingsRoot, withIntermediateDirectories: true)
        unseenReady.removeAll()
        selectedMeeting = nil
        searchHits = nil
        queue.resetForStorageChange()
        recorder.meetingsRoot = meetingsRoot
        library.root = meetingsRoot
        library.reload { [weak self] in
            guard let self else { return }
            self.queue.enqueuePending(in: self.library)
        }
        searchIndex = try? SearchIndex(url: meetingsRoot.deletingLastPathComponent().appendingPathComponent("index.sqlite"))
        chunkIndex = try? ChunkIndex(url: meetingsRoot.deletingLastPathComponent().appendingPathComponent("chunks.sqlite"))
        syncSearchIndex()
    }

    func openSettings() {
        openSettingsAction?()
        NSApp.activate()
    }

    var menuBarStatus: MenuBarStatus {
        if recorder.isRecording { return .recording(elapsed: recorder.elapsed) }
        if let activity = queue.current { return .processing(progress: activity.progress) }
        if recorder.errorMessage != nil || recorder.warning != nil || !failedMeetings.isEmpty {
            return .problem
        }
        if !unseenReady.isEmpty { return .ready }
        return .idle
    }

    // MARK: - Recording

    /// ⌥⌘R and the menu bar button: stop, or start with the meeting app that has the mic.
    func toggleRecording() {
        if recorder.isRecording {
            recorder.stop()
        } else {
            let app = prompt.app ?? activeMeetingApp
            startRecording(for: app, event: prompt.event ?? (app != nil ? calendar.eventForCall() : nil))
        }
    }

    /// `event`: the calendar meeting this recording is for; it names the recording.
    func startRecording(for app: MeetingApp?, event: CalendarMeeting? = nil) {
        prompt.hide()
        if let event {
            if deferredReminder?.id == event.id { deferredReminder = nil }
            calendar.markReminded(event.id)
        }
        let scope = RecordingScope(rawValue: UserDefaults.standard.string(forKey: SettingsKey.recordingScope) ?? "") ?? .allApps
        recorder.meetingProcessFilter = scope == .meetingApps ? { Self.meetingProcessObjects() } : nil
        lastMeetingProcesses = scope == .meetingApps ? Self.meetingProcessObjects() : []
        callEndApp = app?.bundleID
        let eventTitle = event.map(\.title).flatMap { $0.isEmpty ? nil : $0 }
        recorder.start(title: eventTitle ?? app?.meetingTitle, titleIsFinal: eventTitle != nil, sourceApp: app?.bundleID)
    }

    // MARK: - Calendar reminders

    let calendar = CalendarWatcher()
    @ObservationIgnored private var deferredReminder: CalendarMeeting?
    @ObservationIgnored private var dismissedEvents: Set<String> = []

    /// Settings > Recording toggle, or launch with it on: watch the calendar if allowed.
    func calendarRemindersChanged() {
        guard UserDefaults.standard.bool(forKey: SettingsKey.remindBeforeCalendarMeetings) else {
            deferredReminder = nil
            calendar.stop()
            return
        }
        // On by default: the first launch with it on asks for Calendar
        // access once; macOS remembers the answer, and a "no" just leaves reminders off.
        if !CalendarWatcher.hasAccess, calendar.source == nil {
            guard CalendarWatcher.notDetermined else { return calendar.stop() }
            Task {
                if await calendar.requestAccess() { calendarRemindersChanged() }
            }
            return
        }
        calendar.onReminder = { [weak self] event in
            guard let self, !self.dismissedEvents.contains(event.id) else { return }
            if self.recorder.isRecording || self.recorder.isBusy {
                self.deferredReminder = event
                return
            }
            self.prompt.remind(event)
        }
        calendar.start()
    }

    private func presentDeferredReminderIfRelevant() {
        guard let event = deferredReminder else { return }
        deferredReminder = nil
        guard UserDefaults.standard.bool(forKey: SettingsKey.remindBeforeCalendarMeetings),
              !dismissedEvents.contains(event.id),
              !recorder.isRecording else { return }
        let now = Date()
        guard now < event.end, now.timeIntervalSince(event.start) <= MeetingReminder.joinWindow else { return }
        prompt.remind(event)
    }

    /// "Record this meeting?": watches which apps use the mic (Core Audio listeners, no
    /// polling) and asks when a meeting app starts. Never starts recording by itself.
    private func startMeetingDetection() {
        prompt.onRecord = { [weak self] app, event in self?.startRecording(for: app, event: event) }
        prompt.onDismiss = { [weak self] _, event in
            guard let self, let event else { return }
            self.dismissedEvents.insert(event.id)
            self.calendar.markReminded(event.id)
        }
        calendarRemindersChanged()
        processMonitor.onInputChange = { [weak self] inputs in
            MainActor.assumeIsolated { self?.meetingAppsUsingMic(inputs) }
        }
        processMonitor.onProcessListChange = { [weak self] in
            MainActor.assumeIsolated { self?.audioProcessesChanged() }
        }
        processMonitor.start()
    }

    func meetingAppsUsingMic(_ inputs: Set<String>) {
        micInputs = inputs
        activeMeetingApp = inputs.compactMap(MeetingApp.match).first
        if recorder.isRecording { callEndInputsChanged(inputs) }
        let ask = detector.update(inputProcesses: inputs, isRecording: recorder.isRecording)
        if let app = prompt.app, !detector.isActive(app) { prompt.hide() }
        guard let ask, UserDefaults.standard.bool(forKey: SettingsKey.askWhenMeetingStarts) else { return }
        // Joined from a lobby a few minutes before or after a calendar meeting: name it.
        let matchedEvent = prompt.event ?? calendar.eventForCall()
        if let matchedEvent, dismissedEvents.contains(matchedEvent.id) { return }
        prompt.show(ask, event: matchedEvent)
    }

    private func audioProcessesChanged() {
        guard recorder.isRecording, recorder.meetingProcessFilter != nil else { return }
        let now = Self.meetingProcessObjects()
        if now != lastMeetingProcesses {
            lastMeetingProcesses = now
            recorder.meetingProcessesChanged()
        }
    }

    @ObservationIgnored private var lastMeetingProcesses: [AudioObjectID] = []

    // MARK: - Stop when the call ends

    /// Bundle IDs of the processes using the mic, as last reported by the process monitor.
    @ObservationIgnored private var micInputs: Set<String> = []
    /// The meeting app the next recording is started for (prompt or the app holding the mic).
    @ObservationIgnored private var callEndApp: String?
    @ObservationIgnored private var callEnd = CallEndWatcher()
    @ObservationIgnored private var callEndTask: Task<Void, Never>?

    /// Grace before the countdown, and the countdown. Overridable for the self-test
    /// (`-callEndGraceSeconds 1`); not in Settings.
    private static var callEndGrace: Double {
        let value = UserDefaults.standard.double(forKey: "callEndGraceSeconds")
        return value > 0 ? value : 30
    }
    private static var callEndCountdown: Int {
        let value = UserDefaults.standard.integer(forKey: "callEndCountdownSeconds")
        return value > 0 ? value : 10
    }

    private func callEndStarted() {
        callEnd = CallEndWatcher(grace: Self.callEndGrace)
        callEnd.begin(app: callEndApp, inputProcesses: micInputs)
        if let adopted = callEnd.app {
            recorder.adoptSourceApp(adopted)
        }
        callEndApp = nil
    }

    private func callEndFinished() {
        callEndTask?.cancel()
        callEndTask = nil
        callEnd.end()
        bubble.callEndCountdown(nil)
    }

    private func callEndInputsChanged(_ inputs: Set<String>) {
        let change = callEnd.update(inputProcesses: inputs)
        if let adopted = callEnd.app {
            recorder.adoptSourceApp(adopted)
        }
        switch change {
        case .released:
            guard UserDefaults.standard.bool(forKey: SettingsKey.stopWhenCallEnds) else { return }
            callEndTask?.cancel()
            callEndTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.callEndGrace))
                guard !Task.isCancelled, let self, self.callEnd.callEnded() else { return }
                await self.runCallEndCountdown()
            }
        case .returned:
            callEndTask?.cancel()
            callEndTask = nil
            bubble.callEndCountdown(nil)
        case .none:
            break
        }
    }

    /// "Call ended, stopping in N s" in the pill, then stop, unless Keep recording or the app
    /// takes the mic back first.
    private func runCallEndCountdown() async {
        for remaining in stride(from: Self.callEndCountdown, to: 0, by: -1) {
            guard !Task.isCancelled, recorder.isRecording else { return }
            bubble.callEndCountdown(remaining)
            try? await Task.sleep(for: .seconds(1))
        }
        guard !Task.isCancelled, recorder.isRecording, callEnd.callEnded() else { return }
        bubble.callEndCountdown(nil)
        recorder.stop()
    }

    /// The pill's Keep recording button: no automatic stop for the rest of this recording.
    func keepRecordingAfterCallEnd() {
        callEndTask?.cancel()
        callEndTask = nil
        callEnd.dismiss()
        bubble.callEndCountdown(nil)
    }

    /// Audio process objects of known meeting apps and browsers ("meeting apps only").
    nonisolated static func meetingProcessObjects() -> [AudioObjectID] {
        AudioProcessMonitor.processes().filter { MeetingApp.match($0.bundleID) != nil }.map(\.object).sorted()
    }

    // MARK: - Meeting actions

    /// Sidebar search: titles, notes, transcripts and summaries (FTS5), off the main thread.
    func runSearch(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let index = searchIndex else {
            searchHits = nil
            return
        }
        let hits = await Task.detached(priority: .userInitiated) { (try? index.search(trimmed)) ?? [] }.value
        guard !Task.isCancelled else { return }
        searchHits = hits.map { ($0.id, $0.snippet) }
    }

    /// Settings > Keep audio (default Forever): removes audio of finished meetings older
    /// than the chosen period, in the background.
    func cleanOldAudio() {
        let days = UserDefaults.standard.integer(forKey: SettingsKey.keepAudioDays)
        guard days > 0 else { return }
        let root = meetingsRoot
        Task.detached(priority: .utility) {
            let changed = AudioRetention.clean(root: root, keepDays: days)
            await MainActor.run { for folder in changed { self.library.refresh(folder) } }
        }
    }

    /// Re-checks the whole index against the folders (launch, storage folder change).
    func syncSearchIndex() {
        guard let index = searchIndex else { return }
        let root = meetingsRoot
        indexTask?.cancel()
        indexTask = Task.detached(priority: .utility) { try? index.sync(root: root) }
        syncChunkIndex()
    }

    /// One meeting changed (pipeline step, rename, notes): update just that entry.
    func reindex(_ folder: MeetingFolder) {
        if let index = searchIndex {
            Task.detached(priority: .utility) { try? index.index(folder) }
        }
        reindexChunks(folder)
    }

    func removeFromSearchIndex(_ folder: MeetingFolder) {
        searchHits?.removeAll { $0.id == folder.id }
        guard let index = searchIndex else { return }
        let id = folder.id
        Task.detached(priority: .utility) { try? index.remove(id: id) }
        removeFromChunkIndex(folder)
    }

    func syncChunkIndex() {
        guard let index = chunkIndex else { return }
        let root = meetingsRoot
        let modelsRoot = models.root
        let server = lmStudioServerURL
        let embedder = chunkEmbedder
        chunkIndexTask?.cancel()
        chunkIndexTask = Task.detached(priority: .utility) {
            let session = await embedder.session(modelsRoot: modelsRoot, server: server)
            try? await index.sync(root: root, embeddingModel: session?.modelID, embed: session?.embed)
        }
    }

    func reindexChunks(_ folder: MeetingFolder) {
        guard let index = chunkIndex else { return }
        let modelsRoot = models.root
        let server = lmStudioServerURL
        let embedder = chunkEmbedder
        Task.detached(priority: .utility) {
            let session = await embedder.session(modelsRoot: modelsRoot, server: server)
            try? await index.refresh(folder, embeddingModel: session?.modelID, embed: session?.embed)
        }
    }

    func removeFromChunkIndex(_ folder: MeetingFolder) {
        guard let index = chunkIndex else { return }
        let id = folder.id
        Task.detached(priority: .utility) { try? index.remove(id: id) }
    }

    /// Chat source pill: open the meeting, scroll the transcript, and queue playback seek.
    func openCitation(meetingID: String, start: Double, switchingFrom currentMeetingID: String?) {
        guard let item = library.items.first(where: { $0.id == meetingID }) else { return }
        transcriptJump = start
        pendingCitationPlay = start
        guard currentMeetingID != meetingID else { return }
        selectedMeeting = item.folder
        openMeetings(selecting: item.folder)
    }

    /// Called by the meeting window after the cited meeting is on screen.
    func consumePendingCitationPlay() -> Double? {
        let value = pendingCitationPlay
        pendingCitationPlay = nil
        return value
    }

    /// Context menu Reprocess: everything after compression runs again (compression too if
    /// the WAVs are still there and it never finished).
    func reprocess(_ folder: MeetingFolder) {
        queue.reprocess(folder, from: Self.reprocessStart(folder))
    }

    /// Where Reprocess starts. Without any audio (Keep audio removed it) only the summary can
    /// be redone: rerunning speech found nothing and replaced the transcript with an empty one.
    nonisolated static func reprocessStart(_ folder: MeetingFolder) -> PipelineStage {
        if folder.exists(.mic16k) || folder.exists(.system16k) { return .diarize }
        if folder.exists(.micWAV) || folder.exists(.systemWAV) { return .compress }
        return folder.exists(.transcript) ? .summarize : .compress
    }

    /// Saves how many call voices to find, and re-runs speakers when the audio is still here.
    func applyCallSpeakers(_ document: MeetingDocument, count: Int?) {
        document.setExpectedCallSpeakers(count)
        library.refresh(document.folder)
        guard document.meta.status != .recording else { return }
        let start = Self.reprocessStart(document.folder)
        guard start < .transcribe else { return }
        queue.reprocess(document.folder, from: start)
    }

    /// Pins this meeting's transcription engine. Nil follows Settings. Re-runs the transcript
    /// when diarization is already done and the audio has not been removed.
    func applyTranscriptionEngine(_ document: MeetingDocument, engine: TranscriptionEngine?) {
        document.setTranscriptionEngine(engine)
        library.refresh(document.folder)
        guard document.meta.status != .recording else { return }
        let earliest = Self.reprocessStart(document.folder)
        guard earliest < .summarize else { return }
        let from: PipelineStage = document.folder.exists(.diarization) ? .transcribe : earliest
        queue.reprocess(document.folder, from: from)
    }

    /// The name Sonnet should spell. A Settings value wins; otherwise the Mac account's given name.
    nonisolated static var recorderName: String {
        RecorderName.given(stored: UserDefaults.standard.string(forKey: SettingsKey.userName),
                           systemFullName: NSFullUserName())
    }

    struct WordingResult: Sendable {
        var message: String?
        var wrote: Bool
        /// A newer save replaced this one. The caller should leave its notice alone.
        var skipped = false
    }

    /// Sends the current transcript text to Sonnet 5.5 with the names the user has confirmed.
    /// The audio is not read again. The on-device draft stays if the call fails.
    /// When the transcript is actually rewritten, the summary is rewritten from it too.
    func cleanWithSonnet(_ document: MeetingDocument) async -> WordingResult {
        do {
            let wrote = try await ClaudeSonnet.reviseMeeting(document.folder, recorderName: Self.recorderName)
            await document.reload()
            library.refresh(document.folder)
            reindex(document.folder)
            if wrote { refreshSummary(document.folder) }
            return WordingResult(message: nil, wrote: wrote)
        } catch {
            if error is CancellationError {
                return WordingResult(message: "Stopped. The transcript was not changed.", wrote: false)
            }
            let message = error.localizedDescription
            _ = try? document.folder.updateMeta { $0.processing.sonnetTranscriptNote = message }
            await document.reload()
            library.refresh(document.folder)
            return WordingResult(message: message, wrote: false)
        }
    }

    /// Rewrites the summary from the transcript that is already on disk. Does not re-split speakers
    /// or reread the audio. Skipped when this meeting is already being transcribed, because that run
    /// writes the summary when it finishes.
    func refreshSummary(_ folder: MeetingFolder) {
        guard folder.exists(.transcript) else { return }
        if let current = queue.current, current.folder == folder, current.stage != .summarize { return }
        queue.reprocess(folder, from: .summarize)
    }

    /// Finds the call voices again without changing how many were requested.
    /// A saved name stays only when the new voice still matches that person.
    func findSpeakersAgain(_ document: MeetingDocument) {
        library.refresh(document.folder)
        guard document.meta.status != .recording else { return }
        let start = Self.reprocessStart(document.folder)
        guard start < .transcribe else { return }
        queue.reprocess(document.folder, from: start)
    }

    /// Ends the wording pass. The on-device draft is left as it is.
    func stopWording() {
        ClaudeSonnet.stop(.wording)
    }

    func regenerateSummary(_ folder: MeetingFolder, backend: SummaryBackendKind) {
        queue.reprocess(folder, from: .summarize) { $0.processing.requestedSummaryBackend = backend }
    }

    // MARK: - Hooks filled in by later phases

    func addNoteShortcut() {
        bubble.openNoteField()
    }

    func recordingFinished(_ folder: MeetingFolder) {
        queue.resume()
        queue.enqueue(folder)
    }
}

/// ReMeet is a menu bar app (LSUIElement); it shows a Dock icon while a UI window that
/// needs one is open (meetings, Settings). An LSUIElement app switched to `.regular` at
/// runtime gets the generic Dock tile unless `applicationIconImage` is set from the real
/// AppIcon *before* the policy flip — and flipping mid-layout amplifies split-view crashes.
@MainActor
enum DockPresence {
    private static var reasons: Set<String> = []
    private static var didRegisterBundle = false

    /// The grille, from the bundled icns. Notification Center reads that file
    /// (an LSUIElement app's asset-catalog icon is what shows up as the blank tile);
    /// the Dock reads `applicationIconImage`.
    static func appIcon() -> NSImage? {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            return icon
        }
        return NSImage(named: "AppIcon") ?? NSImage(named: NSImage.applicationIconName)
    }

    /// Point the Dock and Launch Services at the real icon before any banner is posted.
    static func installIcon() {
        applyAppIcon()
        guard !didRegisterBundle else { return }
        didRegisterBundle = true
        _ = LSRegisterURL(Bundle.main.bundleURL as CFURL, true)
    }

    /// The Dock click has to show a window now. `show` still waits a turn when a layout pass is open.
    static func makeRegularNow() {
        applyAppIcon()
        guard NSApp.activationPolicy() != .regular else { return }
        NSApp.setActivationPolicy(.regular)
    }

    static func show(_ reason: String) {
        let wasEmpty = reasons.isEmpty
        reasons.insert(reason)
        applyAppIcon()
        guard wasEmpty else { return }
        // Next turn: avoid setActivationPolicy during an in-flight constraint pass.
        DispatchQueue.main.async {
            guard !reasons.isEmpty else { return }
            applyAppIcon()
            NSApp.setActivationPolicy(.regular)
        }
    }

    static func hide(_ reason: String) {
        reasons.remove(reason)
        guard reasons.isEmpty else { return }
        DispatchQueue.main.async {
            guard reasons.isEmpty else { return }
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private static func applyAppIcon() {
        if let icon = appIcon() {
            NSApp.applicationIconImage = icon
        }
    }
}

enum WindowID {
    static let meetings = "meetings"
    static let welcome = "welcome"
}
