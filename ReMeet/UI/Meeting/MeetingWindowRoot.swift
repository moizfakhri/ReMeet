import AppKit
import ReMeetKit
import SwiftUI

enum SidebarSelection: Hashable {
    case live
    case meeting(MeetingFolder)
}

/// The main ReMeet window: 4-tab sidebar (Meetings, Schedule, People, Moments),
/// main detail column, optional transcript inspector (⌘T), and floating player capsule.
/// While open, ReMeet shows a Dock icon.
struct MeetingWindowRoot: View {
    @Environment(AppModel.self) private var model
    @State private var activeTab: WorkspaceTab = .meetings
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var autoCollapsedSidebar = false
    @State private var selection: SidebarSelection?
    @State private var scheduleSelection: ScheduleSelection?
    @State private var selectedPersonID: String?
    @State private var momentCategory: MomentFilterOption = .all
    @State private var selectedMomentID: String?
    @State private var search = ""
    @State private var showTranscript: Bool
    @State private var transcriptWidth: CGFloat = 340
    @State private var dragStartTranscriptWidth: CGFloat?
    @State private var hoveringDivider = false
    @State private var document: MeetingDocument?
    @State private var player = PlayerModel()
    @State private var loadFailed: MeetingFolder?
    /// Last few meetings, so clicking back and forth does not blank the detail.
    @State private var cache: [String: MeetingDocument] = [:]
    @State private var cacheOrder: [String] = []
    @State private var loadTask: Task<Void, Never>?
    @State private var loadingFolder: MeetingFolder?

    init(initialShowTranscript: Bool = false, initialScheduleSelection: ScheduleSelection? = nil) {
        _showTranscript = State(initialValue: initialShowTranscript)
        _scheduleSelection = State(initialValue: initialScheduleSelection)
    }

    private var transcriptPresented: Bool {
        activeTab == .meetings && showTranscript
    }

    private var minWindowWidth: CGFloat {
        if !transcriptPresented { return 760 }
        return columnVisibility == .detailOnly ? 680 : 840
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            MeetingSidebar(
                activeTab: $activeTab,
                selection: selectionBinding,
                scheduleSelection: $scheduleSelection,
                selectedPersonID: $selectedPersonID,
                momentCategory: $momentCategory,
                selectedMomentID: $selectedMomentID,
                search: search,
                onOpenMeetingAt: openMeetingAt
            )
            .navigationSplitViewColumnWidth(min: 204, ideal: 244, max: 320)
        } detail: {
            GeometryReader { geo in
                let totalWidth = max(1, geo.size.width)
                if transcriptPresented {
                    let minDetail = min(320, totalWidth * 0.52)
                    let maxTranscript = max(220, min(480, totalWidth - minDetail))
                    let clampedTranscript = min(max(transcriptWidth, 240), maxTranscript)
                    let detailWidth = max(200, totalWidth - clampedTranscript - 1)

                    HStack(spacing: 0) {
                        detail
                            .frame(width: detailWidth, height: geo.size.height)
                            .clipped()
                            .animation(nil, value: document?.folder)
                            .animation(nil, value: activeTab)

                        Rectangle()
                            .fill(Theme.line)
                            .frame(width: 1, height: geo.size.height)
                            .overlay {
                                Color.clear
                                    .frame(width: 9, height: geo.size.height)
                                    .contentShape(Rectangle())
                                    .onHover { inside in
                                        if inside && !hoveringDivider {
                                            hoveringDivider = true
                                            NSCursor.resizeLeftRight.push()
                                        } else if !inside && hoveringDivider {
                                            hoveringDivider = false
                                            NSCursor.pop()
                                        }
                                    }
                                    .onDisappear {
                                        if hoveringDivider {
                                            hoveringDivider = false
                                            NSCursor.pop()
                                        }
                                    }
                                    .gesture(
                                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                                            .onChanged { value in
                                                if dragStartTranscriptWidth == nil {
                                                    dragStartTranscriptWidth = clampedTranscript
                                                }
                                                let base = dragStartTranscriptWidth ?? clampedTranscript
                                                transcriptWidth = min(max(base - value.translation.width, 240), maxTranscript)
                                            }
                                            .onEnded { _ in
                                                dragStartTranscriptWidth = nil
                                            }
                                    )
                            }
                            .zIndex(2)

                        TranscriptInspector(document: document, player: player)
                            .frame(width: clampedTranscript, height: geo.size.height)
                            .clipped()
                    }
                } else {
                    detail
                        .frame(width: totalWidth, height: geo.size.height)
                        .clipped()
                        .animation(nil, value: document?.folder)
                        .animation(nil, value: activeTab)
                }
            }
            .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        .searchable(text: $search, placement: .sidebar, prompt: searchPrompt)
        .toolbar { toolbar }
        .focusedSceneValue(\.meetingFocus, MeetingFocus(document: activeTab == .meetings ? document : nil,
                                                        showTranscript: $showTranscript))
        .frame(minWidth: minWindowWidth, idealWidth: 1060, maxWidth: .infinity,
               minHeight: 500, idealHeight: 680, maxHeight: .infinity)
        .background { WindowChrome(minSize: CGSize(width: minWindowWidth, height: 500)) }
        .onAppear {
            Perf.mark("window.appear")
            DockPresence.show("meetings")
            if !model.library.hasLoaded {
                model.library.reload()
            }
            DispatchQueue.main.async { Perf.mark("window.firstRunloopAfterAppear") }
            applyRequestedSelection()
            applyRequestedTabAndTargets()
            if selection == nil, model.recorder.isRecording { selection = .live }
            if selection == nil, let first = model.library.items.first { selection = .meeting(first.folder) }
            if case .meeting(let folder) = selection { adopt(folder) }
            ensureSecondarySelections()
        }
        .onDisappear {
            loadTask?.cancel()
            loadTask = nil
            player.pause()
            DockPresence.hide("meetings")
        }
        .onChange(of: model.selectedMeeting) { applyRequestedSelection() }
        .onChange(of: model.requestedTab) { applyRequestedTabAndTargets() }
        .onChange(of: model.selectedPersonID) { applyRequestedTabAndTargets() }
        .onChange(of: model.selectedCalendarEventID) { applyRequestedTabAndTargets() }
        .onChange(of: showTranscript) { _, open in
            if open {
                if let win = AppModel.meetingsWindow(), win.frame.width < 920, columnVisibility != .detailOnly {
                    autoCollapsedSidebar = true
                    columnVisibility = .detailOnly
                }
            } else if autoCollapsedSidebar {
                autoCollapsedSidebar = false
                if columnVisibility == .detailOnly { columnVisibility = .all }
            }
        }
        .onChange(of: activeTab) { _, next in
            if next != .meetings {
                player.pause()
                if autoCollapsedSidebar {
                    autoCollapsedSidebar = false
                    if columnVisibility == .detailOnly { columnVisibility = .all }
                }
            }
            ensureSecondarySelections()
        }
        .onChange(of: model.hub.people) { _, _ in ensureSecondarySelections() }
        .onChange(of: model.calendar.events) { _, _ in ensureSecondarySelections() }
        .onChange(of: selection) { _, next in
            if case .meeting(let folder) = next { adopt(folder) }
        }
        .onChange(of: model.library.items) { previous, items in
            let prevByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0.meta) })
            let nextByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.meta) })
            for id in Array(cache.keys) where id != document?.folder.id {
                if nextByID[id] == nil || prevByID[id] != nextByID[id] {
                    cache.removeValue(forKey: id)
                    cacheOrder.removeAll { $0 == id }
                }
            }
            if selection == nil, let first = items.first {
                selection = .meeting(first.folder)
                adopt(first.folder)
                return
            }
            guard case .meeting(let folder) = selection else { return }
            guard let after = nextByID[folder.id] else {
                cache.removeValue(forKey: folder.id)
                cacheOrder.removeAll { $0 == folder.id }
                document = nil
                if model.recorder.isRecording, model.recorder.folder == folder {
                    selection = .live
                } else {
                    selection = items.first.map { .meeting($0.folder) }
                    if case .meeting(let next) = selection { adopt(next) }
                }
                return
            }
            let before = prevByID[folder.id]
            if before != after || document?.meta != after { refreshDocument() }
        }
    }

    private var searchPrompt: String {
        switch activeTab {
        case .meetings: "Search meetings"
        case .schedule: "Search schedule"
        case .people: "Search people"
        case .moments: "Search moments"
        }
    }

    @ViewBuilder private var detail: some View {
        switch activeTab {
        case .meetings:
            meetingsDetail
        case .schedule:
            scheduleDetail
        case .people:
            peopleDetail
        case .moments:
            MomentsGalleryView(
                category: momentCategory,
                selectedMomentID: selectedMomentID,
                search: search,
                onOpenInMeeting: { folder, time in openMeetingAt(folder, time) }
            )
        }
    }

    @ViewBuilder private var meetingsDetail: some View {
        switch selection {
        case .live:
            LiveRecordingView()
        case .meeting(let folder):
            if loadFailed == folder {
                EmptyStateView(title: "This meeting could not be opened",
                               message: "Its meta.json is missing or unreadable.")
            } else if let document, document.folder == folder {
                MeetingDetailView(document: document, player: player, showTranscript: $showTranscript)
            } else {
                LoadingMeetingPlaceholder(item: model.library.item(for: folder))
            }
        case nil:
            if model.library.items.isEmpty {
                EmptyStateView(title: "No meetings yet",
                               message: "Press ⌥⌘R in any app to start recording. ReMeet records your mic and the call, then transcribes and summarizes it on this Mac.")
            } else {
                EmptyStateView(title: "Select a meeting", message: "")
            }
        }
    }

    @ViewBuilder private var scheduleDetail: some View {
        switch scheduleSelection {
        case .commitmentsRadar:
            CommitmentsRadarDetailView { folder, time in openMeetingAt(folder, time) }
        case .event(let id):
            if let event = model.calendar.events.first(where: { $0.id == id }) {
                CalendarEventDetailView(event: event) { folder, time in openMeetingAt(folder, time) }
            } else {
                CommitmentsRadarDetailView { folder, time in openMeetingAt(folder, time) }
            }
        case nil:
            if let next = model.calendar.upcomingMeetings().first {
                CalendarEventDetailView(event: next) { folder, time in openMeetingAt(folder, time) }
            } else {
                CommitmentsRadarDetailView { folder, time in openMeetingAt(folder, time) }
            }
        }
    }

    @ViewBuilder private var peopleDetail: some View {
        let resolved = selectedPersonID.flatMap { id in model.hub.people.first { $0.id == id } }
            ?? model.hub.people.first
        if let person = resolved {
            PersonDetailView(person: person) { folder, time in
                openMeetingAt(folder, time)
            }
        } else {
            EmptyStateView(
                title: "People you meet with",
                message: "Name any speaker once in a recording — or connect your Apple/Google Calendar — and ReMeet builds a profile with their voiceprint, shared commitments, and every conversation."
            )
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if activeTab == .meetings {
                CopyForAIButton(document: document)

                Button {
                    if let document { model.exportMarkdownOneOff(document.folder) }
                } label: {
                    Label("Export Markdown", systemImage: "arrow.down.doc")
                }
                .help("Save this meeting as an AI-ready Markdown file (⇧⌘E)")
                .disabled(document == nil)

                Button {
                    if let document { SummaryClipboard.copy(document) }
                } label: {
                    Label("Copy summary", systemImage: "doc.on.doc")
                }
                .help("Copy summary as Markdown (⌥⇧⌘C)")
                .disabled(document?.summary == nil)

                RegenerateMenu(document: document)

                Button {
                    if let urls = document?.originalAudioURLs, !urls.isEmpty {
                        NSWorkspace.shared.activateFileViewerSelecting(urls)
                    }
                } label: {
                    Label("Reveal audio", systemImage: "waveform")
                }
                .help("Show the original recording in Finder")
                .disabled(document?.originalAudioURLs.isEmpty != false)

                Button {
                    model.chatFocusPending = true
                } label: {
                    Label("Chat", systemImage: "bubble.left")
                }
                .help("Focus chat (⌘L)")
                .disabled(document == nil)

                Toggle(isOn: $showTranscript) {
                    Label("Transcript", systemImage: "text.quote")
                }
                .help("Show transcript (⌘T)")
            } else if activeTab == .schedule {
                Button {
                    model.calendar.syncICSFeedsNow()
                } label: {
                    Label("Sync Calendar", systemImage: "arrow.clockwise")
                }
                .help("Sync Apple Calendar and subscribed Google/iCal .ics feeds")
            }
        }
    }

    private var selectionBinding: Binding<SidebarSelection?> {
        Binding(
            get: { selection },
            set: { next in
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    selection = next
                    if case .meeting(let folder) = next { adopt(folder) }
                }
            }
        )
    }

    private func openMeetingAt(_ folder: MeetingFolder, _ timestamp: Double?) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            activeTab = .meetings
            selection = .meeting(folder)
            if let timestamp {
                model.transcriptJump = timestamp
                model.pendingCitationPlay = timestamp
                showTranscript = true
            }
            adopt(folder)
        }
    }

    private func applyRequestedTabAndTargets() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if let tab = model.requestedTab {
                activeTab = tab
                model.requestedTab = nil
            }
            if let pid = model.selectedPersonID {
                selectedPersonID = pid
                model.selectedPersonID = nil
            }
            if let eid = model.selectedCalendarEventID {
                scheduleSelection = .event(eid)
                model.selectedCalendarEventID = nil
            }
            ensureSecondarySelections()
        }
    }

    private func ensureSecondarySelections() {
        if selectedPersonID == nil || !model.hub.people.contains(where: { $0.id == selectedPersonID }) {
            selectedPersonID = model.hub.people.first?.id
        }
        if scheduleSelection == nil {
            if let next = model.calendar.upcomingMeetings().first {
                scheduleSelection = .event(next.id)
            } else if let recent = model.calendar.events.last(where: { MeetingReminder.hasOnlineMeetingPlatform($0) }) {
                scheduleSelection = .event(recent.id)
            } else {
                scheduleSelection = .commitmentsRadar
            }
        }
    }

    private func applyRequestedSelection() {
        guard let folder = model.selectedMeeting else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            activeTab = .meetings
            if model.recorder.isRecording, model.recorder.folder == folder {
                selection = .live
            } else {
                selection = .meeting(folder)
                adopt(folder)
            }
            model.selectedMeeting = nil
        }
    }

    private func adopt(_ folder: MeetingFolder) {
        model.markSeen(folder)
        let currentMeta = model.library.item(for: folder)?.meta
        guard document?.folder != folder else {
            loadTask?.cancel()
            loadTask = nil
            loadingFolder = nil
            if player.folder != folder {
                player.load(folder, knownDuration: document?.meta.effectiveDuration ?? 0)
            }
            if let currentMeta, document?.meta != currentMeta {
                refreshDocument()
            }
            if let cite = model.consumePendingCitationPlay() {
                player.play(from: max(0, cite - 1))
            }
            return
        }
        if let hit = cache[folder.id], currentMeta == nil || hit.meta == currentMeta {
            loadTask?.cancel()
            loadTask = nil
            loadingFolder = nil
            installLoadedDocument(hit)
            return
        }
        guard loadingFolder != folder else { return }
        loadTask?.cancel()
        loadingFolder = folder
        loadFailed = nil
        player.load(folder, knownDuration: currentMeta?.effectiveDuration ?? 0)
        loadTask = Task {
            let loaded = await MeetingDocument.load(folder)
            guard !Task.isCancelled, loadingFolder == folder else { return }
            loadingFolder = nil
            guard let loaded else {
                loadFailed = folder
                return
            }
            installLoadedDocument(loaded)
        }
    }

    private func installLoadedDocument(_ loaded: MeetingDocument) {
        loadFailed = nil
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            document = loaded
        }
        let id = loaded.folder.id
        cache[id] = loaded
        cacheOrder.removeAll { $0 == id }
        cacheOrder.append(id)
        while cacheOrder.count > 12 {
            cache.removeValue(forKey: cacheOrder.removeFirst())
        }
        player.load(loaded.folder, knownDuration: loaded.meta.effectiveDuration)
        if let cite = model.consumePendingCitationPlay() {
            player.play(from: max(0, cite - 1))
        }
        Perf.mark("document.shown")
    }

    private func refreshDocument() {
        guard case .meeting(let folder) = selection else { return }
        guard let document, document.folder == folder else {
            adopt(folder)
            return
        }
        let hadAudio = document.folder.exists(.audio)
        let before = document.meta.status
        Task {
            await document.reload()
            guard selection == .meeting(folder) else { return }
            if document.meta.status != before, hadAudio != document.folder.exists(.audio) || before == .recorded {
                player.reloadAudio()
            }
        }
    }
}

private struct LoadingMeetingPlaceholder: View {
    let item: MeetingItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let item {
                Text(item.meta.title)
                    .font(Fonts.title)
                    .foregroundStyle(Theme.fg)
                HStack(spacing: 6) {
                    Text(item.meta.startTime.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                    Text("·")
                    Text(item.meta.startTime.formatted(date: .omitted, time: .shortened))
                    if item.meta.effectiveDuration > 0 {
                        Text("·")
                        Text(TimeFormat.duration(item.meta.effectiveDuration))
                    }
                }
                .font(.system(size: 13))
                .foregroundStyle(Theme.fg2)
            }
            Spacer()
        }
        .frame(maxWidth: 620, alignment: .leading)
        .padding(.horizontal, 40)
        .padding(.top, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.surface)
    }
}

struct EmptyStateView: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.fg3)
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.fg)
            if !message.isEmpty {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(Theme.fg2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surface)
    }
}

private struct CopyForAIButton: View {
    let document: MeetingDocument?
    @State private var copied = false

    var body: some View {
        Button {
            guard let document else { return }
            AIClipboard.copy(document)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            Label(copied ? "Copied" : "Copy for AI", systemImage: copied ? "checkmark" : "doc.on.clipboard")
                .contentTransition(.symbolEffect(.replace))
        }
        .help("Copy the transcript, your notes and the summary as Markdown for an AI chat (⇧⌘C)")
        .disabled(document == nil)
    }
}
