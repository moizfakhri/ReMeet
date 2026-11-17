import AppKit
import ReMeetKit
import SwiftUI

enum SidebarSelection: Hashable {
    case live
    case meeting(MeetingFolder)
}

/// The meeting window: glass sidebar, one document column, transcript inspector (⌘T),
/// player capsule. While it is open ReMeet shows a Dock icon.
struct MeetingWindowRoot: View {
    @Environment(AppModel.self) private var model
    @State private var selection: SidebarSelection?
    @State private var search = ""
    @State private var showTranscript = false
    @State private var document: MeetingDocument?
    @State private var player = PlayerModel()
    @State private var loadFailed: MeetingFolder?
    /// Last few meetings, so clicking back and forth does not blank the detail.
    @State private var cache: [String: MeetingDocument] = [:]
    @State private var cacheOrder: [String] = []

    var body: some View {
        // Transcript is a fixed-width trailing panel, not `.inspector`. Nested
        // NavigationSplitView + inspectorColumnWidth invalidated split constraints
        // mid-pass and aborted with SIGABRT when clicking around (3 IPS 2026-11-02).
        NavigationSplitView {
            MeetingSidebar(selection: selectionBinding, search: search)
                .navigationSplitViewColumnWidth(min: 188, ideal: 240, max: 320)
        } detail: {
            HStack(spacing: 0) {
                // One stable column. A zero-size placeholder used to change the split
                // view's minimum, so the window jumped or refused to shrink.
                detail
                    .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                    // Folder changes are a cut, not a resize interpolation.
                    .animation(nil, value: document?.folder)
                if showTranscript {
                    Divider()
                    TranscriptInspector(document: document, player: player)
                        .frame(minWidth: 240, idealWidth: 360, maxWidth: 480)
                        .transition(.move(edge: .trailing))
                }
            }
            .animation(.snappy(duration: 0.18), value: showTranscript)
        }
        .navigationSplitViewStyle(.balanced)
        .searchable(text: $search, placement: .sidebar, prompt: "Search")
        .toolbar { toolbar }
        .focusedSceneValue(\.meetingFocus, MeetingFocus(document: document, showTranscript: $showTranscript))
        .frame(minWidth: 760, idealWidth: 1040, maxWidth: .infinity,
               minHeight: 500, idealHeight: 680, maxHeight: .infinity)
        .background { WindowChrome(minSize: CGSize(width: 760, height: 500)) }
        .onAppear {
            Perf.mark("window.appear")
            DockPresence.show("meetings")
            model.library.reload()
            DispatchQueue.main.async { Perf.mark("window.firstRunloopAfterAppear") }
            applyRequestedSelection()
            if selection == nil, model.recorder.isRecording { selection = .live }
            if selection == nil, let first = model.library.items.first { selection = .meeting(first.folder) }
            if case .meeting(let folder) = selection { adopt(folder) }
        }
        .onDisappear {
            player.pause()
            DockPresence.hide("meetings")
        }
        .onChange(of: model.selectedMeeting) { applyRequestedSelection() }
        .onChange(of: selection) { _, next in
            if case .meeting(let folder) = next { adopt(folder) }
        }
        .onChange(of: model.library.items) { previous, items in
            let prevByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0.meta) })
            let nextByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.meta) })
            // Evict cached documents that changed or disappeared in the background, so clicking
            // back to them loads fresh JSON without relayouting the meeting currently on screen.
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
            // A pipeline tick on some other meeting must not reload and relayout this one.
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

    @ViewBuilder private var detail: some View {
        switch selection {
        case .live:
            LiveRecordingView()
        case .meeting(let folder):
            if loadFailed == folder {
                EmptyStateView(title: "This meeting could not be opened",
                               message: "Its meta.json is missing or unreadable.")
            } else if let document, document.folder == folder {
                MeetingDetailView(document: document, player: player, showTranscript: $showTranscript)
                    .id(folder)
            } else {
                // Same min frame as a document, so a miss does not collapse the column.
                Theme.surface
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            CopyForAIButton(document: document)

            Button {
                if let document { SummaryClipboard.copy(document) }
            } label: {
                Label("Copy summary", systemImage: "doc.on.doc")
            }
            .help("Copy summary as Markdown (⌥⇧⌘C)")
            .disabled(document?.summary == nil)

            RegenerateMenu(document: document)

            Button {
                if let urls = document?.folder.originalAudioURLs(), !urls.isEmpty {
                    NSWorkspace.shared.activateFileViewerSelecting(urls)
                }
            } label: {
                Label("Reveal audio", systemImage: "waveform")
            }
            .help("Show the original recording in Finder")
            .disabled(document?.folder.originalAudioURLs().isEmpty != false)

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
        }
    }

    /// Selection and the document change in one unanimated transaction. The sidebar
    /// writes this binding; setting `selection` alone would paint the new row against
    /// the previous meeting for a frame, then animate the column as the load landed.
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

    private func applyRequestedSelection() {
        guard let folder = model.selectedMeeting else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if model.recorder.isRecording, model.recorder.folder == folder {
                selection = .live
            } else {
                selection = .meeting(folder)
                adopt(folder)
            }
            model.selectedMeeting = nil
        }
    }

    /// Puts `folder` on screen before the next paint. Meeting JSON is small, so the
    /// read stays on this turn instead of hopping to a detached task (that hop was
    /// the flash of the previous meeting and the split-view jump).
    private func adopt(_ folder: MeetingFolder) {
        model.markSeen(folder)
        let currentMeta = model.library.item(for: folder)?.meta
        guard document?.folder != folder else {
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
        let cached: MeetingDocument?
        if let hit = cache[folder.id], currentMeta == nil || hit.meta == currentMeta {
            cached = hit
        } else {
            cached = nil
        }
        let loaded = cached ?? MeetingDocument(folder: folder)
        guard let loaded else {
            loadFailed = folder
            return
        }
        loadFailed = nil
        document = loaded
        let id = loaded.folder.id
        cache[id] = loaded
        cacheOrder.removeAll { $0 == id }
        cacheOrder.append(id)
        while cacheOrder.count > 8 {
            cache.removeValue(forKey: cacheOrder.removeFirst())
        }
        player.load(folder, knownDuration: loaded.meta.effectiveDuration)
        if let cite = model.consumePendingCitationPlay() {
            player.play(from: max(0, cite - 1))
        }
        Perf.mark("document.shown")
    }

    /// The library changed (pipeline progress, rename): re-read the open meeting.
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
                    .frame(maxWidth: 360)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surface)
    }
}

/// Copy for AI in the toolbar. Says "Copied" for a moment, so a click visibly did something.
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
