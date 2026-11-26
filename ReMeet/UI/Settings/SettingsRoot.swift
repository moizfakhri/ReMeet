import AVFoundation
import AppKit
import KeyboardShortcuts
import ReMeetKit
import ServiceManagement
import SwiftUI
import UserNotifications

/// Settings laid out like System Settings on macOS 26: glass sidebar of sections, grouped
/// rows on the right.
struct SettingsRoot: View {
    enum Pane: String, CaseIterable, Identifiable {
        case general = "General"
        case recording = "Recording"
        case calendar = "Calendar"
        case reminders = "Reminders"
        case transcription = "Transcription"
        case summaries = "Summaries"
        case permissions = "Permissions"

        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .recording: "record.circle"
            case .calendar: "calendar"
            case .reminders: "checklist"
            case .transcription: "text.quote"
            case .summaries: "sparkles.rectangle.stack"
            case .permissions: "lock.shield"
            }
        }
    }

    @Environment(AppModel.self) private var model
    @State private var pane: Pane?

    init(initialPane: Pane = .general) {
        _pane = State(initialValue: initialPane)
    }

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases) { item in
                let isSelected = pane == item
                HStack(spacing: 8) {
                    Image(systemName: item.symbol)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(isSelected ? Theme.accent : Theme.fg2)
                        .frame(width: 18)
                    Text(item.rawValue)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Theme.accent : Theme.fg)
                }
                .sidebarRow(selected: isSelected) {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { pane = item }
                }
            }
            .navigationSplitViewColumnWidth(190)
        } detail: {
            Group {
                switch pane ?? .general {
                case .general: GeneralPane()
                case .recording: RecordingPane()
                case .calendar: CalendarPane()
                case .reminders: RemindersPane()
                case .transcription: TranscriptionPane()
                case .summaries: SummariesPane()
                case .permissions: PermissionsPane()
                }
            }
            .formStyle(.grouped)
            .navigationTitle((pane ?? .general).rawValue)
        }
        .frame(minWidth: 680, idealWidth: 760, maxWidth: .infinity,
               minHeight: 460, idealHeight: 540, maxHeight: .infinity)
        .background { WindowChrome(minSize: CGSize(width: 680, height: 460)) }
        .background { FollowPointerScreen() }
        .onAppear {
            DockPresence.show("settings")
            if let requested = model.requestedSettingsPane {
                pane = requested
                model.requestedSettingsPane = nil
            }
        }
        .onChange(of: model.requestedSettingsPane) { _, requested in
            if let requested {
                pane = requested
                model.requestedSettingsPane = nil
            }
        }
        .onDisappear { DockPresence.hide("settings") }
    }
}

// MARK: - General

private struct GeneralPane: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.appearance) private var appearance = AppearanceSetting.system.rawValue
    @AppStorage(SettingsKey.showBubble) private var showBubble = true
    @AppStorage(SettingsKey.autoHideBubbleOnShare) private var autoHideBubbleOnShare = true
    @AppStorage(SettingsKey.keepAudioDays) private var keepAudioDays = 0
    @AppStorage(SettingsKey.storageFolder) private var storageFolder = ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Open ReMeet when you log in", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.orange)
                }
            }
            Section("Shortcuts") {
                KeyboardShortcuts.Recorder("Start or stop recording", name: .toggleRecording)
                KeyboardShortcuts.Recorder("Add a note", name: .addNote)
                KeyboardShortcuts.Recorder("Mark a moment", name: .markMoment)
                KeyboardShortcuts.Recorder("Hide or show recording pill", name: .toggleBubble)
            }
            Section("Note bubble") {
                Toggle("Show the recording pill while recording", isOn: $showBubble.onSet { _ in model.bubbleSettingChanged() })
                Text("When off, the pill never appears on screen—ideal if you share your screen often. You still see the red timer in the menu bar, and \(KeyboardShortcuts.Name.addNote.hint.isEmpty ? "Add a note" : KeyboardShortcuts.Name.addNote.hint) opens a note box only while you type.")
                    .font(.caption).foregroundStyle(Theme.fg2)
                Toggle("Auto-hide pill when screen sharing is detected", isOn: $autoHideBubbleOnShare)
                    .disabled(!showBubble)
                Text("Hides the pill automatically when Zoom, Teams, or macOS screen sharing/recording starts. Press \(KeyboardShortcuts.Name.toggleBubble.hint.isEmpty ? "the shortcut above" : KeyboardShortcuts.Name.toggleBubble.hint) anytime to hide or bring it back.")
                    .font(.caption).foregroundStyle(Theme.fg2)
            }
            Section("Storage") {
                LabeledContent("Meetings folder") {
                    HStack {
                        Text(model.meetingsRoot.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .foregroundStyle(Theme.fg2)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…", action: chooseFolder)
                            .disabled(model.recorder.isRecording)
                    }
                }
                Picker("Keep audio", selection: $keepAudioDays.onSet { _ in model.cleanOldAudio() }) {
                    Text("Forever").tag(0)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("1 year").tag(365)
                }
                Text("Transcripts, notes and summaries are always kept. Only the audio files of older meetings are removed.")
                    .font(.caption).foregroundStyle(Theme.fg2)
            }
            Section("Appearance") {
                Picker("Theme", selection: $appearance) {
                    ForEach(AppearanceSetting.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .onChange(of: appearance) { _, value in AppearanceSetting(rawValue: value)?.apply() }
            }
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Could not change this: \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use This Folder"
        panel.message = "ReMeet keeps a \u{201C}meetings\u{201D} folder inside the folder you choose. Existing meetings are not moved."
        if panel.runModal() == .OK, let url = panel.url {
            storageFolder = url.path
            model.storageFolderChanged()
        }
    }
}

// MARK: - Recording

private struct RecordingPane: View {
    @AppStorage(SettingsKey.recordingScope) private var scope = RecordingScope.allApps.rawValue
    @AppStorage(SettingsKey.askWhenMeetingStarts) private var askWhenMeetingStarts = true
    @AppStorage(SettingsKey.stopWhenCallEnds) private var stopWhenCallEnds = true
    @AppStorage(SettingsKey.remindBeforeCalendarMeetings) private var remindBeforeCalendar = true
    @State private var calendarDenied = CalendarWatcher.accessDenied
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                Picker("Record call audio from", selection: $scope) {
                    ForEach(RecordingScope.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Text(RecordingScope(rawValue: scope)?.detail ?? "")
                    .font(.caption).foregroundStyle(Theme.fg2)
            }
            Section {
                Toggle("Ask to record when a meeting app starts using the mic", isOn: $askWhenMeetingStarts)
                Text("Zoom, Teams, FaceTime, Slack, Webex, or a browser tab (Google Meet). Teams asks as soon as its pre-join screen turns the mic on. ReMeet never starts recording on its own.")
                    .font(.caption).foregroundStyle(Theme.fg2)
                Toggle("Remind me a minute before calendar meetings", isOn: $remindBeforeCalendar.onSet { on in
                    guard on else { return model.calendarRemindersChanged() }
                    Task {
                        let granted = await model.calendar.requestAccess()
                        calendarDenied = !granted
                        if !granted { remindBeforeCalendar = false }
                        model.calendarRemindersChanged()
                    }
                })
                Text(calendarDenied
                     ? "ReMeet isn't allowed to read your calendar. Turn it on in System Settings > Privacy & Security > Calendars, then switch this on again."
                     : "Uses the calendars in the Calendar app on this Mac, so add your Google or Outlook account there (System Settings > Internet Accounts). Meetings with other people or a call link; the recording is named after the event.")
                    .font(.caption).foregroundStyle(Theme.fg2)
                if calendarDenied {
                    Button("Open Calendar privacy settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                    }
                }
            }
            Section {
                Toggle("Stop recording when the call ends", isOn: $stopWhenCallEnds)
                Text("When the meeting app lets go of the mic for 30 seconds, the pill counts down from 10 seconds with a Keep recording button, then stops.")
                    .font(.caption).foregroundStyle(Theme.fg2)
            }
            Section("Audio Guardian & AirPods") {
                Text("ReMeet automatically follows your active call microphone—including mid-call switches to AirPods or headsets selected inside Zoom, Meet, or Teams—and warns you right away if either your mic or call audio is muted or silent.")
                    .font(.callout).foregroundStyle(Theme.fg2)
            }
        }
    }
}

// MARK: - Calendar & ICS Automation

private struct CalendarPane: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.remindBeforeCalendarMeetings) private var remindBeforeCalendar = true
    @State private var addingFeed = false
    @State private var accessGranted = CalendarWatcher.hasAccess
    @State private var accessDenied = CalendarWatcher.accessDenied

    var body: some View {
        Form {
            Section("Apple Calendar & Internet Accounts") {
                LabeledContent("Calendar access") {
                    if accessGranted {
                        Label("Connected", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Theme.accent)
                            .font(.callout.weight(.medium))
                    } else if accessDenied {
                        Button("Open Privacy Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                        }
                    } else {
                        Button("Connect Apple Calendar") {
                            Task {
                                let ok = await model.calendar.requestAccess()
                                accessGranted = ok
                                accessDenied = CalendarWatcher.accessDenied
                                if ok { model.calendar.start() }
                            }
                        }
                    }
                }
                Toggle("Remind me 1 minute before scheduled meetings", isOn: $remindBeforeCalendar.onSet { _ in
                    model.calendarRemindersChanged()
                })
                Text("Reads all calendars added in macOS Calendar (including iCloud, Google, and Exchange accounts in System Settings > Internet Accounts) to populate the Schedule tab, create People profiles, and boost voice recognition.")
                    .font(.caption)
                    .foregroundStyle(Theme.fg2)

                if accessGranted, !model.calendar.availableCalendars.isEmpty {
                    ForEach(model.calendar.availableCalendars) { cal in
                        Toggle(
                            "\(cal.title) (\(cal.accountTitle))",
                            isOn: Binding(
                                get: { model.calendar.isCalendarEnabled(cal.id) },
                                set: { model.calendar.setCalendarEnabled(cal.id, enabled: $0) }
                            )
                        )
                    }
                }
            }

            Section("Google Calendar & iCal (.ics) Feeds") {
                if model.calendar.icsFeeds.isEmpty {
                    Text("No subscribed .ics URLs yet. Paste a Google Calendar \u{201C}Secret address in iCal format\u{201D} to sync your Google Calendar directly in the background without adding it to macOS Calendar.")
                        .font(.caption)
                        .foregroundStyle(Theme.fg2)
                } else {
                    ForEach(model.calendar.icsFeeds) { feed in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Toggle("", isOn: Binding(
                                get: { feed.isEnabled },
                                set: { model.calendar.toggleICSFeed(feed.id, enabled: $0) }
                            ))
                            .labelsHidden()

                            VStack(alignment: .leading, spacing: 2) {
                                Text(feed.name.isEmpty ? "Subscribed Calendar" : feed.name)
                                    .font(.system(size: 13, weight: .medium))
                                if let err = feed.lastError {
                                    Text(err)
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                } else if let synced = feed.lastSyncedAt {
                                    Text("\(feed.lastEventCount) events · synced \(synced.formatted(date: .omitted, time: .shortened))")
                                        .font(.caption)
                                        .foregroundStyle(Theme.fg2)
                                } else {
                                    Text(feed.urlString)
                                        .font(.caption)
                                        .foregroundStyle(Theme.fg3)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                            Spacer()
                            Button(role: .destructive) {
                                model.calendar.removeICSFeed(feed.id)
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(Theme.fg2)
                            }
                            .buttonStyle(.borderless)
                            .help("Remove this .ics subscription")
                        }
                    }
                }

                HStack(spacing: 10) {
                    Button("Add Google / iCal .ics URL…") { addingFeed = true }
                    if !model.calendar.icsFeeds.isEmpty || accessGranted {
                        Button(model.calendar.isSyncingICS ? "Syncing…" : "Sync Now") {
                            model.calendar.syncICSFeedsNow()
                        }
                        .disabled(model.calendar.isSyncingICS)
                    }
                }
            }
        }
        .onAppear {
            accessGranted = CalendarWatcher.hasAccess
            accessDenied = CalendarWatcher.accessDenied
        }
        .sheet(isPresented: $addingFeed) {
            AddICSFeedSheet { name, url in
                _ = model.calendar.addICSFeed(name: name, urlString: url)
                model.calendarRemindersChanged()
            }
        }
    }
}

// MARK: - Reminders

private struct RemindersPane: View {
    private static let systemDefaultChoice = "__system__"
    private static let folderDefaultChoice = "__default__"
    private static let folderOffChoice = "__off__"

    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.remindersAutoSync) private var autoSync = true
    @AppStorage(SettingsKey.remindersIncludeWaitingOnOthers) private var includeWaiting = false
    @AppStorage(SettingsKey.remindersMirrorFolders) private var mirrorFolders = true
    @AppStorage(SettingsKey.defaultRemindersListID) private var defaultListID = ""
    @AppStorage(SettingsKey.defaultRemindersListName) private var defaultListName = ""
    @State private var accessGranted = RemindersSyncService.hasAccess
    @State private var accessDenied = RemindersSyncService.accessDenied
    @State private var syncStatus: String?
    @State private var isSyncingNow = false

    private var hasWorkList: Bool {
        model.reminders.listNamed("Work") != nil
    }

    var body: some View {
        Form {
            Section("Apple Reminders") {
                LabeledContent("Reminders access") {
                    if accessGranted {
                        Label("Connected", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Theme.accent)
                            .font(.callout.weight(.medium))
                    } else if accessDenied {
                        Button("Open Privacy Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")!)
                        }
                    } else {
                        Button("Connect Apple Reminders") {
                            Task {
                                let ok = await model.reminders.requestAccess()
                                accessGranted = ok
                                accessDenied = RemindersSyncService.accessDenied
                                if ok { model.reminders.start() }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accentFill)
                    }
                }

                if !accessGranted {
                    Text("Click \u{201C}Connect Apple Reminders\u{201D} to trigger the macOS permission prompt. macOS only lists ReMeet in System Settings \u{2192} Privacy & Security \u{2192} Reminders after you request access here once.")
                        .font(.caption)
                        .foregroundStyle(Theme.fg2)
                }

                if let err = model.reminders.lastError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if accessGranted {
                    Picker("Default Reminders list", selection: Binding(
                        get: { defaultListID.isEmpty ? Self.systemDefaultChoice : defaultListID },
                        set: { next in
                            if next == Self.systemDefaultChoice {
                                defaultListID = ""
                                defaultListName = ""
                            } else {
                                defaultListID = next
                                defaultListName = model.reminders.list(forID: next)?.title ?? ""
                            }
                        }
                    )) {
                        Text("System default").tag(Self.systemDefaultChoice)
                        ForEach(model.reminders.availableLists) { list in
                            Text(list.accountTitle.isEmpty ? list.title : "\(list.title) (\(list.accountTitle))").tag(list.id)
                        }
                    }

                    if !hasWorkList {
                        Button("Create \u{201C}Work\u{201D} List & Set as Default") {
                            if let created = model.reminders.createList(named: "Work") {
                                defaultListID = created.id
                                defaultListName = created.title
                            }
                        }
                    }
                }

                Toggle("Automatically sync new \u{201C}For you\u{201D} action items", isOn: $autoSync)
                Toggle("Also add \u{201C}Waiting on others\u{201D} as follow-up reminders", isOn: $includeWaiting)
                Text("Synced items include due dates and a deep link back to the exact moment in the meeting. Checking off a reminder on your Mac, iPhone, or Apple Watch updates ReMeet automatically.")
                    .font(.caption)
                    .foregroundStyle(Theme.fg2)
            }

            if accessGranted && !model.library.collections.isEmpty {
                Section("Folder Routing") {
                    Toggle("Mirror ReMeet folders as Apple Reminders lists", isOn: $mirrorFolders)
                    ForEach(model.library.collections) { folder in
                        HStack(spacing: 8) {
                            Picker(folder.name, selection: Binding(
                                get: {
                                    if folder.remindersDisabled { return Self.folderOffChoice }
                                    if let lid = folder.remindersListID, !lid.isEmpty { return lid }
                                    return Self.folderDefaultChoice
                                },
                                set: { next in
                                    if next == Self.folderOffChoice {
                                        model.library.updateCollection(folder.id, remindersListID: .some(nil), remindersListName: .some(nil), remindersDisabled: true)
                                    } else if next == Self.folderDefaultChoice {
                                        model.library.updateCollection(folder.id, remindersListID: .some(nil), remindersListName: .some(nil), remindersDisabled: false)
                                    } else {
                                        let name = model.reminders.list(forID: next)?.title
                                        model.library.updateCollection(folder.id, remindersListID: .some(next), remindersListName: .some(name), remindersDisabled: false)
                                    }
                                }
                            )) {
                                Text(mirrorFolders
                                     ? "Auto (\u{201C}\(folder.name)\u{201D})"
                                     : "Default (\(defaultListName.isEmpty ? "Reminders" : defaultListName))")
                                    .tag(Self.folderDefaultChoice)
                                ForEach(model.reminders.availableLists) { list in
                                    Text(list.title).tag(list.id)
                                }
                                Text("Don't auto-sync").tag(Self.folderOffChoice)
                            }
                            Button("Sync") {
                                isSyncingNow = true
                                Task {
                                    let count = await model.syncCollectionReminders(folder)
                                    isSyncingNow = false
                                    syncStatus = "Synced \(count) open item\(count == 1 ? "" : "s") from \u{201C}\(folder.name)\u{201D}."
                                }
                            }
                            .controlSize(.small)
                            .disabled(isSyncingNow || folder.remindersDisabled)
                        }
                    }
                    Button("Create & Link Folder Lists Now") {
                        let lists = model.syncFolderReminderLists()
                        syncStatus = "Linked \(lists.count) folder list\(lists.count == 1 ? "" : "s") in Apple Reminders."
                    }
                    Text("Each ReMeet folder automatically creates/links its own matching list. In Apple Reminders' sidebar, you can drag those lists into a \u{201C}Work\u{201D} group once \u{2014} ReMeet tracks each list by ID and keeps syncing into your group.")
                        .font(.caption)
                        .foregroundStyle(Theme.fg2)
                }
            }

            if accessGranted {
                Section("Sync") {
                    HStack(spacing: 10) {
                        Button(isSyncingNow ? "Syncing…" : "Sync Open Items Now") {
                            isSyncingNow = true
                            Task {
                                let count = await model.syncOpenCommitmentsToReminders()
                                model.pullRemindersChanges()
                                isSyncingNow = false
                                syncStatus = count == 0
                                    ? "Up to date."
                                    : "Synced \(count) open action item\(count == 1 ? "" : "s")."
                            }
                        }
                        .disabled(isSyncingNow)

                        Button("Open Reminders") {
                            model.reminders.openRemindersApp()
                        }
                    }
                    if let syncStatus {
                        Text(syncStatus)
                            .font(.caption)
                            .foregroundStyle(Theme.accent)
                    }
                    if let err = model.reminders.lastError {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .onAppear {
            accessGranted = RemindersSyncService.hasAccess
            accessDenied = RemindersSyncService.accessDenied
            if accessGranted {
                model.reminders.refreshLists()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessGranted = RemindersSyncService.hasAccess
            accessDenied = RemindersSyncService.accessDenied
            if accessGranted {
                model.reminders.start()
            }
        }
    }
}

// MARK: - Transcription

private struct TranscriptionPane: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.speakerLabels) private var speakerLabels = true
    @AppStorage(SettingsKey.transcriptionEngine) private var engine = TranscriptionEngine.default.rawValue
    @AppStorage(SettingsKey.userName) private var userName = ""

    var body: some View {
        Form {
            Section {
                Picker("Engine", selection: Binding(
                    get: {
                        let resolved = TranscriptionEngine.resolve(engine) ?? .fast
                        let shown = resolved == .sonnet ? TranscriptionEngine.fast : resolved
                        return TranscriptionEngine.selectable.contains(shown) ? shown.rawValue : TranscriptionEngine.fast.rawValue
                    },
                    set: { engine = $0 }
                ).onSet { value in
                    if let chosen = TranscriptionEngine.resolve(value), let id = chosen.model,
                       !model.models.isReady(id) {
                        model.models.download(id)
                    }
                }) {
                    ForEach(TranscriptionEngine.selectable) { Text($0.label).tag($0.rawValue) }
                }
                Text(engineCaption)
                    .font(.caption).foregroundStyle(Theme.fg2)
                TextField("Your name", text: $userName, prompt: Text(AppModel.recorderName))
                Text("Sonnet spells your name this way. Leave it blank to use your Mac account name, \(AppModel.recorderName). Parakeet and Cohere only hear the audio, so they cannot be given a spelling.")
                    .font(.caption).foregroundStyle(Theme.fg2)
                Toggle("Label speakers", isOn: $speakerLabels)
                Text("Your mic is always \u{201C}You\u{201D}. Other voices on the call become Speaker 1, Speaker 2, from the call audio only. Naming one voice does not rename the others. After the meeting, each other voice has a short clip and a name field. A voice ReMeet has heard before is offered as a suggestion.")
                    .font(.caption).foregroundStyle(Theme.fg2)
            }
            Section("Sonnet 5.5") {
                Text("After the on-device draft, one claude command sends the transcript text to Claude Sonnet 5.5 to fix words and punctuation, then another asks for the summary. No audio is attached. This runs on every meeting. You do not pick Sonnet. If the claude command is missing or the call fails, the on-device transcript and summary stay, and the meeting says what failed. ReMeet stores no API key.")
                    .font(.caption).foregroundStyle(Theme.fg2)
                if ClaudeSonnet.isAvailable {
                    Text("The claude command is installed. If its login has expired, the meeting keeps the on-device result and shows that failure.")
                        .font(.caption).foregroundStyle(Theme.fg2)
                } else {
                    Text("The claude command was not found at ~/.local/bin/claude. Meetings will keep the on-device transcript and summary until it is installed and you are signed in.")
                        .font(.caption).foregroundStyle(Theme.fg2)
                }
            }
            Section("Models") {
                ModelRow(id: .diarizer, allowDelete: true)
                ModelRow(id: .cohere, allowDelete: true)
                ModelRow(id: .parakeet, allowDelete: true)
            }
        }
    }

    private var engineCaption: String {
        let resolved = TranscriptionEngine.resolve(engine) ?? .fast
        switch resolved == .sonnet ? TranscriptionEngine.fast : resolved {
        case .accurate:
            return "Cohere Transcribe writes the draft on this Mac: fewest word errors, about 3 minutes per hour of audio, using up to 3 GB while it runs. Sonnet then cleans the text."
        case .fast, .sonnet:
            return "Parakeet writes the draft on this Mac: about half a minute per hour of audio. Sonnet then cleans the text."
        }
    }
}

// MARK: - Summaries

private struct SummariesPane: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.summaryBackend) private var backend = SummaryBackendKind.builtIn.rawValue
    @AppStorage(SettingsKey.lmStudioURL) private var lmStudioURL = "http://localhost:1234"
    @AppStorage(SettingsKey.lmStudioModel) private var lmStudioModel = ""
    @AppStorage(SettingsKey.customInstructions) private var customInstructions = ""
    @AppStorage(SettingsKey.notifyWhenReady) private var notifyWhenReady = true
    @AppStorage(SettingsKey.chatAnswerBackend) private var chatAnswerBackend = MeetingChatAnswerBackend.default.rawValue

    var body: some View {
        Form {
            Section {
                Picker("Summarize with", selection: $backend) {
                    Text("On this Mac").tag(SummaryBackendKind.builtIn.rawValue)
                    Text("LM Studio").tag(SummaryBackendKind.lmStudio.rawValue)
                }
                .pickerStyle(.segmented)
                Text("Sonnet writes the summary after the transcript is cleaned. If that call fails, this choice writes it instead. You can also regenerate one meeting from the meeting window.")
                    .font(.caption).foregroundStyle(Theme.fg2)
                Toggle("Notify when ready", isOn: $notifyWhenReady)
            }
            switch SummaryBackendKind(rawValue: backend) ?? .builtIn {
            case .builtIn:
                Section("Built-in model") {
                    ModelRow(id: .summaryLLM, allowDelete: true)
                }
            case .lmStudio:
                Section("LM Studio") {
                    TextField("Server", text: $lmStudioURL)
                    TextField("Model (blank = the loaded model)", text: $lmStudioModel)
                    Text("Start LM Studio's local server (Developer tab) and load a model. Nothing leaves this Mac.")
                        .font(.caption).foregroundStyle(Theme.fg2)
                }
            }
            Section("Chat") {
                Picker("Answer with", selection: $chatAnswerBackend) {
                    Text("Sonnet").tag(MeetingChatAnswerBackend.sonnet.rawValue)
                    Text("On this Mac").tag(MeetingChatAnswerBackend.mlx.rawValue)
                }
                .pickerStyle(.segmented)
                Text("Sonnet is the default. On this Mac uses the built-in summary model and stays offline. Both reply with the same citation JSON. Retrieval stays on this Mac either way.")
                    .font(.caption).foregroundStyle(Theme.fg2)
            }
            Section("Custom instructions") {
                TextEditor(text: $customInstructions)
                    .font(.body)
                    .frame(minHeight: 70)
                Text("Added to every summary request, e.g. \u{201C}Name an owner for every action item.\u{201D}")
                    .font(.caption).foregroundStyle(Theme.fg2)
            }
        }
    }
}

// MARK: - Permissions

private struct PermissionsPane: View {
    @Environment(AppModel.self) private var model
    @State private var probe = LevelProbe()
    @State private var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var notifications: UNAuthorizationStatus = .notDetermined
    @State private var remindersGranted = RemindersSyncService.hasAccess
    @State private var remindersDenied = RemindersSyncService.accessDenied
    @State private var remindersNotDetermined = RemindersSyncService.notDetermined

    var body: some View {
        Form {
            Section {
                LabeledContent("Microphone") {
                    HStack {
                        Text(micText).foregroundStyle(Theme.fg2)
                        Button("Open System Settings") { open("Privacy_Microphone") }
                    }
                }
                LabeledContent("System audio") {
                    HStack {
                        Text(probe.heardSystemAudio ? "Verified" : probe.chimeState == .blocked ? "Blocked" : probe.isRunning ? "Click Test Call Audio below" : "Not checked")
                            .foregroundStyle(probe.chimeState == .blocked ? .orange : Theme.fg2)
                        Button("Open System Settings") { open("Privacy_AudioCapture") }
                    }
                }
                LabeledContent("Notifications") {
                    HStack {
                        Text(notificationText).foregroundStyle(Theme.fg2)
                        Button("Open System Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                        }
                    }
                }
                LabeledContent("Apple Reminders") {
                    HStack {
                        Text(remindersGranted ? "Allowed" : (remindersDenied ? "Off" : "Not asked yet"))
                            .foregroundStyle(Theme.fg2)
                        if remindersNotDetermined {
                            Button("Request Access") {
                                Task {
                                    _ = await model.reminders.requestAccess()
                                    refreshPermissionStates()
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.accentFill)
                        }
                        Button("Open System Settings") { open("Privacy_Reminders") }
                    }
                }
            }
            Section("Pre-Meeting Sound Check") {
                SoundCheckCard(probe: probe, compact: false)
            }
            DiagnosticsSection()
        }
        .onAppear {
            refreshPermissionStates()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissionStates()
        }
        .onChange(of: model.recorder.isRecording) { _, recording in
            if recording { probe.stop() }
        }
        .onDisappear { probe.stop() }
    }

    private func refreshPermissionStates() {
        micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        remindersGranted = RemindersSyncService.hasAccess
        remindersDenied = RemindersSyncService.accessDenied
        remindersNotDetermined = RemindersSyncService.notDetermined
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status = settings.authorizationStatus
            DispatchQueue.main.async { notifications = status }
        }
    }

    private var micText: String {
        switch micStatus {
        case .authorized: "Allowed"
        case .denied, .restricted: "Off"
        default: "Not asked yet"
        }
    }

    private var notificationText: String {
        switch notifications {
        case .authorized, .provisional: "Allowed"
        case .denied: "Off"
        default: "Not asked yet"
        }
    }

    private func open(_ anchor: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
    }
}

/// Diagnostics: versions, devices, models and the capture event log (the Phase 0 log of
/// device switches, tap rebuilds, gaps and dropped chunks) of the live or latest recording.
struct DiagnosticsSection: View {
    @Environment(AppModel.self) private var model
    @State private var copied = false

    var body: some View {
        Section("Diagnostics") {
            LabeledContent("ReMeet", value: version)
            LabeledContent("macOS", value: ProcessInfo.processInfo.operatingSystemVersionString)
            LabeledContent("Input", value: model.recorder.inputDevice.map { "\($0.name), \(Int($0.nominalSampleRate)) Hz" } ?? "None")
            LabeledContent("Output", value: model.recorder.outputDevice.map { "\($0.name), \(Int($0.nominalSampleRate)) Hz" } ?? "None")
            ForEach(ModelID.allCases) { id in
                LabeledContent(id.displayName, value: Self.describe(model.models.state(id)))
            }
            if let (title, meta) = latest {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Capture log: \(title)").font(.callout.weight(.semibold))
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(events(meta).enumerated()), id: \.offset) { _, line in
                                Text(line).font(Fonts.monoSmall).foregroundStyle(Theme.fg2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .frame(maxHeight: 160)
                }
            }
            HStack {
                Button(copied ? "Copied" : "Copy diagnostics") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report, forType: .string)
                    copied = true
                }
                Button("Reveal meetings folder") { NSWorkspace.shared.activateFileViewerSelecting([model.meetingsRoot]) }
                Button("Reveal models folder") { NSWorkspace.shared.activateFileViewerSelecting([model.models.root]) }
            }
        }
    }

    static func describe(_ state: ModelManager.State) -> String {
        switch state {
        case .missing: "Not downloaded"
        case .downloading(let p): "Downloading, \(Int(p * 100))%"
        case .ready: "Ready"
        case .failed(let message): "Failed: \(message)"
        }
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    /// The live recording's events, else the newest meeting's meta.json events.
    private var latest: (String, MeetingMeta)? {
        if model.recorder.isRecording {
            var meta = MeetingMeta(title: model.recorder.title, startTime: model.recorder.startDate ?? Date())
            meta.events = model.recorder.recentEvents
            return ("\(model.recorder.title) (recording)", meta)
        }
        guard let item = model.library.items.first else { return nil }
        return (item.meta.title, item.meta)
    }

    private func events(_ meta: MeetingMeta) -> [String] {
        var lines = meta.events.map { "\(TimeFormat.timer($0.offsetSeconds))  \($0.type): \($0.detail)" }
        for (name, stats) in [("mic", meta.mic), ("call", meta.system)] {
            guard let stats else { continue }
            lines.append("\(name): \(String(format: "%.1f", stats.durationSeconds)) s, rates \(stats.sourceSampleRates.map { Int($0) }), "
                + "silence \(String(format: "%.2f", stats.silenceInsertedSeconds)) s, trimmed \(String(format: "%.2f", stats.driftTrimmedSeconds)) s, "
                + "dropped \(stats.droppedChunks), gaps \(stats.gaps.count)")
        }
        if let failure = meta.failure { lines.append("failed at \(failure.stage.rawValue): \(failure.message)") }
        return lines
    }

    private var report: String {
        var lines = ["ReMeet \(version)", "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
                     "Input: \(model.recorder.inputDevice?.name ?? "none")", "Output: \(model.recorder.outputDevice?.name ?? "none")"]
        lines += ModelID.allCases.map { "\($0.displayName): \(Self.describe(model.models.state($0)))" }
        if let (title, meta) = latest {
            lines.append("Latest: \(title), status \(meta.status.rawValue)")
            lines += events(meta)
        }
        return lines.joined(separator: "\n")
    }
}

enum RecordingScope: String, CaseIterable, Identifiable {
    case allApps
    case meetingApps

    var id: String { rawValue }
    var label: String {
        switch self {
        case .allApps: "All apps"
        case .meetingApps: "Meeting apps only"
        }
    }

    var detail: String {
        switch self {
        case .allApps: "Everything your Mac plays while recording, except ReMeet itself. Simplest and never misses the call."
        case .meetingApps: "Only audio from Zoom, Teams, FaceTime, Slack, Webex and browsers. Music and other apps are left out."
        }
    }
}

extension Binding {
    /// Runs `action` after the value is set from the UI.
    func onSet(_ action: @escaping (Value) -> Void) -> Binding<Value> {
        Binding(get: { wrappedValue }, set: { wrappedValue = $0; action($0) })
    }
}
