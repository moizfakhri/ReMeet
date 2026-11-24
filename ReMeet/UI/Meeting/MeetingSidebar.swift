import AppKit
import ReMeetKit
import SwiftUI

struct MeetingSidebar: View {
    @Environment(AppModel.self) private var model
    @Binding var activeTab: WorkspaceTab
    @Binding var selection: SidebarSelection?
    @Binding var scheduleSelection: ScheduleSelection?
    @Binding var selectedPersonID: String?
    @Binding var momentCategory: MomentFilterOption
    @Binding var selectedMomentID: String?
    let search: String
    let onOpenMeetingAt: (MeetingFolder, Double?) -> Void
    @State private var renaming: MeetingItem?
    @State private var renameText = ""
    @State private var deleting: MeetingItem?
    /// Open folder dropdowns, comma-separated ids ("*" = all, for snapshots). Remembered.
    @AppStorage("sidebarExpandedFolders") private var expandedFolders = ""
    /// Folder IDs whose one-time setup prompt was dismissed.
    @AppStorage("dismissedFolderHints") private var dismissedFolderHints = ""
    /// Folder or date group ids whose "Show more" is on.
    @State private var showingAll: Set<String> = []
    /// The row a drag is hovering over, drawn highlighted.
    @State private var dropTarget: String?
    @State private var folderEditor: FolderEditor?
    @State private var deletingFolder: MeetingCollection?
    @State private var hoveredFolderID: String?

    var body: some View {
        // Selection is drawn as the Fern "mark" (soft accent tint, accent title, readable meta
        // line) instead of the system highlight, whose white text on the dark-mode green was
        // 2.2:1. Arrow keys still move the selection.
        // Stack the tab switcher, List, and footer in a VStack rather than `.safeAreaInset`
        // so scrolled rows clip cleanly at the Divider and never bleed through Liquid Glass.
        VStack(spacing: 0) {
            tabSwitcher
            Theme.line.frame(height: 1)

            switch activeTab {
            case .meetings:
                meetingsList
            case .schedule:
                ScheduleSidebarContent(selection: $scheduleSelection, search: search)
            case .people:
                PeopleSidebarContent(selectedPersonID: $selectedPersonID, search: search)
            case .moments:
                MomentsSidebarContent(
                    selectedCategory: $momentCategory,
                    selectedMomentID: $selectedMomentID,
                    search: search,
                    onOpenInMeeting: { folder, time in onOpenMeetingAt(folder, time) }
                )
            }

            Theme.line.frame(height: 1)
            HStack(spacing: 12) {
                Button {
                    model.importMeetingAudioChosen()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 12))
                        Text("Import")
                    }
                    .foregroundStyle(Theme.fg2)
                    .hitTarget(6)
                }
                .buttonStyle(.plain)
                .help("Import an existing audio recording to transcribe and summarize")
                Spacer()
                Button {
                    model.openSettings()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 12))
                        Text("Settings")
                    }
                    .foregroundStyle(Theme.fg2)
                    .hitTarget(6)
                }
                .buttonStyle(.plain)
                .help("Settings (⌘,)")
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
        // A meeting opened from elsewhere (menu bar, notification) shows inside its folder.
        .onChange(of: selection) { _, next in
            guard case .meeting(let folder) = next,
                  let id = model.library.item(for: folder)?.meta.collectionID else { return }
            setExpanded(id, true)
        }
        .task(id: search) {
            // Debounced: a search runs 150 ms after the last keystroke.
            try? await Task.sleep(for: .milliseconds(search.isEmpty ? 0 : 150))
            guard !Task.isCancelled else { return }
            await model.runSearch(search)
        }
        .alert("Rename meeting", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $renameText)
            Button("Rename") {
                if let renaming { model.library.rename(renaming.folder, to: renameText) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .alert("Could not import", isPresented: Binding(
            get: { model.importNotice != nil },
            set: { if !$0 { model.importNotice = nil } }
        )) {
            Button("OK", role: .cancel) { model.importNotice = nil }
        } message: {
            Text(model.importNotice ?? "")
        }
        .onChange(of: model.sidebarRequest) { _, request in
            guard let request else { return }
            model.sidebarRequest = nil
            switch request {
            case .rename(let folder):
                if let item = model.library.item(for: folder) {
                    renameText = item.meta.title
                    renaming = item
                }
            case .trash(let folder):
                deleting = model.library.item(for: folder)
            case .newFolder:
                folderEditor = FolderEditor(collection: nil)
            }
        }
        .sheet(item: $folderEditor) { editor in
            FolderEditorSheet(editor: editor) { name, context, exportPath in
                if let id = editor.collection?.id {
                    model.library.updateCollection(id, name: name, context: context, exportDirectoryPath: .some(exportPath))
                } else if let created = model.library.createCollection(named: name, context: context,
                                                                       exportDirectoryPath: exportPath) {
                    if let meeting = editor.moving { model.library.move(meeting, to: created.id) }
                    setExpanded(created.id, true)
                }
            }
        }
        .confirmationDialog("Delete this folder?",
                            isPresented: Binding(get: { deletingFolder != nil }, set: { if !$0 { deletingFolder = nil } }),
                            presenting: deletingFolder) { folder in
            Button("Delete Folder", role: .destructive) {
                model.library.deleteCollection(folder.id)
                deletingFolder = nil
            }
        } message: { folder in
            Text("\u{201C}\(folder.name)\u{201D} and its context are removed. Its recordings stay, back in the main list.")
        }
        .confirmationDialog("Move this meeting to the Trash?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { item in
            Button("Move to Trash", role: .destructive) {
                let wasSelected = selection == .meeting(item.folder)
                if (try? model.library.moveToTrash(item.folder)) != nil, wasSelected {
                    selection = model.library.items.first.map { .meeting($0.folder) }
                }
                deleting = nil
            }
        } message: { item in
            Text("\u{201C}\(item.meta.title)\u{201D}, its audio, transcript and summary go to the Trash. You can put them back from there.")
        }
    }

    // MARK: - Top Tab Switcher & Meetings List

    private var tabSwitcher: some View {
        HStack(spacing: 4) {
            ForEach(WorkspaceTab.allCases) { tab in
                let isSelected = activeTab == tab
                Button {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { activeTab = tab }
                } label: {
                    Image(systemName: tab.symbol)
                        .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Theme.accent : Theme.fg2)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(isSelected ? Theme.mark : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.rawValue)
                .help(tooltip(for: tab))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func tooltip(for tab: WorkspaceTab) -> String {
        switch tab {
        case .meetings: "Meetings (⌘1)"
        case .schedule: "Schedule & Commitments (⌘2)"
        case .people: "People & Voiceprints (⌘3)"
        case .moments: "Key Moments (⌘4)"
        }
    }

    private var meetingsList: some View {
        List {
            if search.isEmpty, !model.recorder.isRecording, let upcoming = model.calendar.upNext(withinHours: 2) {
                Section {
                    Button {
                        scheduleSelection = .event(upcoming.id)
                        activeTab = .schedule
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "calendar.badge.clock")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Up next · \(upcoming.start.formatted(date: .omitted, time: .shortened))")
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(Theme.accent)
                                Text(upcoming.title)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Theme.fg)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            Text("Prep")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Theme.surface, in: Capsule())
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Theme.mark.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.accent.opacity(0.22)))
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 4, leading: 10, bottom: 2, trailing: 10))
                    .listRowBackground(Color.clear)
                }
            }
            folderSection
            if model.recorder.isRecording {
                LiveRow()
                    .padding(.vertical, 5)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { select(.live) }
                    .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
            }
            ForEach(groups, id: \.0) { group, items in
                let list = shown(items, limit: SidebarList.groupLimit, id: group.rawValue)
                Section {
                    ForEach(list.rows) { item in
                        meetingRow(item, isTodayGroup: group == .today)
                            .dropDestination(for: String.self) { drops, _ in
                                drop(drops, intoFolder: nil)
                            } isTargeted: { dropTarget = $0 ? item.id : (dropTarget == item.id ? nil : dropTarget) }
                    }
                    showMoreRow(id: group.rawValue, hidden: list.hidden, total: items.count, limit: SidebarList.groupLimit)
                } header: {
                    Text(group.rawValue)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.fg3)
                        .textCase(nil)
                }
            }
            if groups.isEmpty, search.isEmpty, hasFiledMeetings {
                Text("Drag a recording here to take it out of its folder.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.fg2)
                    .sidebarRow(selected: dropTarget == "unfiled") {}
                    .dropDestination(for: String.self) { drops, _ in
                        drop(drops, intoFolder: nil)
                    } isTargeted: { dropTarget = $0 ? "unfiled" : (dropTarget == "unfiled" ? nil : dropTarget) }
            }
        }
        .listStyle(.sidebar)
        .transaction { $0.disablesAnimations = true }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.downArrow) { move(1) }
        .onKeyPress(.upArrow) { move(-1) }
        .overlay {
            if !search.isEmpty && groups.isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
    }

    private var hasFiledMeetings: Bool {
        let known = Set(model.library.collections.map(\.id))
        guard !known.isEmpty else { return false }
        return model.library.items.contains { item in
            !(model.recorder.isRecording && model.recorder.folder == item.folder)
                && item.meta.collectionID.map(known.contains) == true
        }
    }

    private var groups: [(MeetingGroup, [MeetingItem])] {
        var items = model.library.items.filter { item in
            !(model.recorder.isRecording && model.recorder.folder == item.folder)
        }
        if !search.isEmpty, let hits = model.searchHits {
            // Search looks everywhere, folders included.
            let ids = Set(hits.map(\.id))
            items = items.filter { ids.contains($0.id) }
        } else {
            // A recording in a folder lives under that folder's dropdown, not here too.
            let known = Set(model.library.collections.map(\.id))
            items = items.filter { item in item.meta.collectionID.map { !known.contains($0) } ?? true }
        }
        return MeetingGroup.grouped(items, date: { $0.meta.startTime }, now: Date())
    }

    /// Selection changes are not animated. An implicit animation here stretches the
    /// detail column while the next meeting loads, which is the jump between rows.
    private func select(_ next: SidebarSelection) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { selection = next }
    }

    /// Arrow keys: next / previous meeting in the order shown.
    private func move(_ delta: Int) -> KeyPress.Result {
        var order: [SidebarSelection] = model.recorder.isRecording ? [.live] : []
        if search.isEmpty {
            for folder in model.library.collections where isExpanded(folder.id) {
                let rows = shown(meetings(in: folder), limit: SidebarList.folderLimit, id: folder.id).rows
                order += rows.map { .meeting($0.folder) }
            }
        }
        for (group, items) in groups {
            order += shown(items, limit: SidebarList.groupLimit, id: group.rawValue).rows.map { .meeting($0.folder) }
        }
        guard !order.isEmpty else { return .ignored }
        let index = selection.flatMap { order.firstIndex(of: $0) } ?? (delta > 0 ? -1 : order.count)
        select(order[min(max(index + delta, 0), order.count - 1)])
        return .handled
    }

    private var snippets: [String: String] {
        guard !search.isEmpty, let hits = model.searchHits else { return [:] }
        return Dictionary(hits.map { ($0.id, $0.snippet) }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: - Rows

    private func meetingRow(_ item: MeetingItem, indent: CGFloat = 0, isTodayGroup: Bool = false) -> some View {
        let isSelected = selection == .meeting(item.folder)
        return MeetingRow(item: item, isProcessing: model.queue.isWorking(on: item.folder),
                          snippet: snippets[item.id], isSelected: isSelected,
                          omitDateIfToday: isTodayGroup)
            .padding(.leading, indent)
            .sidebarRow(selected: isSelected || dropTarget == item.id) { select(.meeting(item.folder)) }
            .animation(nil, value: isSelected)
            .contextMenu { contextMenu(item) }
            .draggable(SidebarDrag.meeting(item.folder.url.path).payload) {
                Text(item.meta.title)
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Theme.mark, in: RoundedRectangle(cornerRadius: 8))
            }
    }

    private func shown(_ items: [MeetingItem], limit: Int, id: String) -> (rows: [MeetingItem], hidden: Int) {
        SidebarList.visible(items, limit: limit, showAll: showingAll.contains(id)) { selection == .meeting($0.folder) }
    }

    /// "Show 4 more" / "Show less", when a list is longer than its limit.
    @ViewBuilder private func showMoreRow(id: String, hidden: Int, total: Int, limit: Int, indent: CGFloat = 0) -> some View {
        if hidden > 0 || (showingAll.contains(id) && total > limit) {
            Button {
                if showingAll.contains(id) { showingAll.remove(id) } else { showingAll.insert(id) }
            } label: {
                Text(hidden > 0 ? "Show \(hidden) more" : "Show less")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.accent)
                    .padding(.vertical, 3)
                    .padding(.leading, 10 + indent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
        }
    }

    /// Handles a drop: recordings go into `folder` (nil = out of any folder). Folder drags
    /// only count on another folder, handled in `folderRow`.
    private func drop(_ payloads: [String], intoFolder folder: String?) -> Bool {
        var handled = false
        for payload in payloads {
            guard case .meeting(let path) = SidebarDrag(payload: payload),
                  let item = model.library.items.first(where: { $0.folder.url.path == path }) else { continue }
            if item.meta.collectionID != folder { model.library.move(item.folder, to: folder) }
            handled = true
        }
        if handled, let folder { setExpanded(folder, true) }
        return handled
    }

    // MARK: - Folders

    private func isExpanded(_ id: String) -> Bool {
        expandedFolders == "*" || expandedFolders.split(separator: ",").contains(Substring(id))
    }

    private func setExpanded(_ id: String, _ open: Bool) {
        var ids = expandedFolders.split(separator: ",").map(String.init).filter { $0 != "*" }
        ids.removeAll { $0 == id }
        if open { ids.append(id) }
        expandedFolders = ids.joined(separator: ",")
    }

    private var meetingsByCollection: [String: [MeetingItem]] {
        let liveFolder = model.recorder.isRecording ? model.recorder.folder : nil
        var map: [String: [MeetingItem]] = [:]
        for item in model.library.items where item.folder != liveFolder {
            if let cid = item.meta.collectionID {
                map[cid, default: []].append(item)
            }
        }
        return map
    }

    private func meetings(in folder: MeetingCollection) -> [MeetingItem] {
        meetingsByCollection[folder.id] ?? []
    }

    private func isFolderHintDismissed(_ id: String) -> Bool {
        dismissedFolderHints.split(separator: ",").contains(Substring(id))
    }

    private func dismissFolderHint(_ id: String) {
        var ids = dismissedFolderHints.split(separator: ",").map(String.init)
        if !ids.contains(id) { ids.append(id) }
        dismissedFolderHints = ids.joined(separator: ",")
    }

    private func shouldShowSetupHint(for folder: MeetingCollection) -> Bool {
        folder.context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (folder.exportDirectoryPath ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isFolderHintDismissed(folder.id)
    }

    @ViewBuilder private var folderSection: some View {
        // While searching, results are a flat list across folders.
        if search.isEmpty {
            let byFolder = meetingsByCollection
            Section {
                ForEach(model.library.collections) { folder in
                    let items = byFolder[folder.id] ?? []
                    folderRow(folder, count: items.count)
                    if isExpanded(folder.id) {
                        if shouldShowSetupHint(for: folder) {
                            FolderContextCard(
                                folder: folder,
                                edit: {
                                    dismissFolderHint(folder.id)
                                    folderEditor = FolderEditor(collection: folder)
                                },
                                dismiss: { dismissFolderHint(folder.id) }
                            )
                            .listRowInsets(EdgeInsets(top: 2, leading: 32, bottom: 4, trailing: 10))
                            .listRowBackground(Color.clear)
                        }
                        let list = shown(items, limit: SidebarList.folderLimit, id: folder.id)
                        ForEach(list.rows) { item in
                            meetingRow(item, indent: 20)
                                .dropDestination(for: String.self) { drops, _ in
                                    drop(drops, intoFolder: folder.id)
                                } isTargeted: { dropTarget = $0 ? item.id : (dropTarget == item.id ? nil : dropTarget) }
                        }
                        showMoreRow(id: folder.id, hidden: list.hidden, total: items.count, limit: SidebarList.folderLimit, indent: 20)
                    }
                }
            } header: {
                HStack(spacing: 6) {
                    Text("Folders")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.fg3)
                        .textCase(nil)
                    Spacer()
                    Button {
                        folderEditor = FolderEditor(collection: nil)
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.fg2)
                            .frame(width: 20, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("New Folder (⇧⌘N)")
                    .accessibilityLabel("New Folder")
                }
            }
        }
    }

    /// A folder: click to open or close its dropdown, drop recordings on it, drag it to reorder.
    private func folderRow(_ folder: MeetingCollection, count: Int) -> some View {
        let open = isExpanded(folder.id)
        let target = dropTarget == "folder-\(folder.id)"
        return HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.fg2)
                .rotationEffect(.degrees(open ? 90 : 0))
                .frame(width: 12)
            Image(systemName: open ? "folder.fill" : "folder")
                .foregroundStyle(target ? Theme.accent : Theme.fg2)
                .frame(width: 18)
            Text(folder.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(target ? Theme.accent : Theme.fg)
                .lineLimit(1)
            Spacer(minLength: 4)
            if hoveredFolderID == folder.id {
                Button {
                    folderEditor = FolderEditor(collection: folder)
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.fg2)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Edit folder context & AI export")
            }
            if let exportPath = folder.exportDirectoryPath {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.accent)
                    .help("Auto-exporting .md files to \(exportPath.replacingOccurrences(of: NSHomeDirectory(), with: "~"))")
            }
            Text("\(count)")
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(Theme.fg2)
        }
        .sidebarRow(selected: target) { setExpanded(folder.id, !open) }
        .onHover { hoveredFolderID = $0 ? folder.id : (hoveredFolderID == folder.id ? nil : hoveredFolderID) }
        .accessibilityValue(open ? "Expanded" : "Collapsed")
        .contextMenu {
            Button("Edit Folder & AI Export…") { folderEditor = FolderEditor(collection: folder) }
            if let exportPath = folder.exportDirectoryPath {
                Button("Export All Meetings Now") {
                    model.syncCollectionExports(folder)
                }
                Button("Open Export Folder in Finder") {
                    let expanded = (exportPath as NSString).expandingTildeInPath
                    let url = URL(fileURLWithPath: expanded, isDirectory: true)
                    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(url)
                }
            }
            Divider()
            Button("Delete Folder…", role: .destructive) { deletingFolder = folder }
        }
        .draggable(SidebarDrag.collection(folder.id).payload) {
            Label(folder.name, systemImage: "folder")
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Theme.mark, in: RoundedRectangle(cornerRadius: 8))
        }
        .dropDestination(for: String.self) { drops, _ in
            var handled = drop(drops, intoFolder: folder.id)
            for payload in drops {
                if case .collection(let moving) = SidebarDrag(payload: payload) {
                    model.library.moveCollection(moving, before: folder.id)
                    handled = true
                }
            }
            return handled
        } isTargeted: { over in
            let id = "folder-\(folder.id)"
            dropTarget = over ? id : (dropTarget == id ? nil : dropTarget)
        }
    }

    @ViewBuilder private func contextMenu(_ item: MeetingItem) -> some View {
        Button("Rename…") {
            renameText = item.meta.title
            renaming = item
        }
        Menu("Move to Folder") {
            Button("No Folder") { model.library.move(item.folder, to: nil) }
                .disabled(item.meta.collectionID == nil)
            if !model.library.collections.isEmpty { Divider() }
            ForEach(model.library.collections) { folder in
                Button(folder.name) { model.library.move(item.folder, to: folder.id) }
                    .disabled(item.meta.collectionID == folder.id)
            }
            Divider()
            Button("New Folder…") { folderEditor = FolderEditor(collection: nil, moving: item.folder) }
        }
        Button("Copy for AI") {
            Task { await AIClipboard.copy(item.folder) }
        }
        Button("Export Markdown…") {
            model.exportMarkdownOneOff(item.folder)
        }
        if let exported = item.meta.exportedMarkdownPath, !exported.isEmpty {
            Button("Reveal Exported .md") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: exported)])
            }
        }
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([item.folder.url])
        }
        Button("Reprocess") {
            model.reprocess(item.folder)
        }
        .disabled(item.meta.status == .recording)
        Divider()
        Button("Delete…", role: .destructive) { deleting = item }
            .disabled(item.meta.status == .recording)
    }
}

private struct LiveRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Theme.recording).frame(width: 7, height: 7)
            Text(model.recorder.title)
                .font(.system(size: 12.5, weight: .semibold))
                .lineLimit(1)
            Spacer()
            Text(TimeFormat.clock(model.recorder.elapsed))
                .font(Fonts.monoSmall)
                .foregroundStyle(Theme.fg2)
        }
        .padding(.vertical, 3)
        .listRowBackground(RoundedRectangle(cornerRadius: 8).fill(Theme.recording.opacity(0.10)).padding(.horizontal, 6))
    }
}

struct MeetingRow: View {
    let item: MeetingItem
    var isProcessing = false
    var snippet: String?
    var isSelected = false
    var omitDateIfToday = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.meta.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isSelected ? Theme.accent : Theme.fg)
                .lineLimit(1)
            // Compact date/time and length so nothing truncates in a 240 pt sidebar.
            HStack(spacing: 5) {
                Text(timeText)
                if item.meta.effectiveDuration > 0 {
                    Text("·").foregroundStyle(Theme.fg3)
                    Text(TimeFormat.duration(item.meta.effectiveDuration))
                }
            }
            .lineLimit(1)
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.fg2)
            if item.meta.status != .summarized {
                HStack(spacing: 5) {
                    if isProcessing { ProgressView().controlSize(.mini) }
                    MeetingStatusText(meta: item.meta)
                }
                .lineLimit(1)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.fg2)
            }
            if let snippet, !snippet.isEmpty {
                Text(snippet)
                    .font(.system(size: 11.5))
                    // fg3 on the selected mark misses AA (~4.0); fg2 stays readable on mark and surface.
                    .foregroundStyle(isSelected ? Theme.fg2 : Theme.fg3)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    private static let timeOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    private static let thisYearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d, h:mm a"
        return f
    }()

    private static let otherYearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d, yyyy"
        return f
    }()

    /// Compact, non-truncating timestamp: "11:00 AM" under Today, "Nov 18, 11:00 AM" this year.
    private var timeText: String {
        let date = item.meta.startTime
        let calendar = Calendar.current
        if omitDateIfToday, calendar.isDateInToday(date) {
            return Self.timeOnlyFormatter.string(from: date)
        }
        let thisYear = calendar.isDate(date, equalTo: Date(), toGranularity: .year)
        return (thisYear ? Self.thisYearFormatter : Self.otherYearFormatter).string(from: date)
    }
}

/// New folder (optionally for a meeting being moved) or editing one.
struct FolderEditor: Identifiable {
    let id = UUID()
    var collection: MeetingCollection?
    var moving: MeetingFolder?
}

private struct FolderEditorSheet: View {
    let editor: FolderEditor
    let save: (String, String, String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var context = ""
    @State private var exportDirectoryPath = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(editor.collection == nil ? "New Folder" : "Edit Folder")
                .font(.headline)
            TextField("Name, e.g. Projects", text: $name)
                .textFieldStyle(.roundedBorder)
            VStack(alignment: .leading, spacing: 4) {
                Text("Context").font(.subheadline.weight(.semibold))
                TextEditor(text: $context)
                    .font(.body)
                    .frame(minHeight: 96)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
                Text("Who is who, the project, terms and acronyms. Added to the summaries of meetings in this folder and to Copy for AI.")
                    .font(.caption).foregroundStyle(Theme.fg2)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("AI Export Folder (.md)").font(.subheadline.weight(.semibold))
                HStack(spacing: 8) {
                    Text(displayExportPath)
                        .font(.callout)
                        .foregroundStyle(exportDirectoryPath.isEmpty ? Theme.fg3 : Theme.fg)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line))
                    Button("Choose…", action: chooseExportDirectory)
                    if !exportDirectoryPath.isEmpty {
                        Button("Clear") { exportDirectoryPath = "" }
                    }
                }
                Text("Finished meetings in this folder automatically save a Markdown file here (summary, action items, notes, and full transcript) so Claude or other AI agents can read them directly.")
                    .font(.caption).foregroundStyle(Theme.fg2)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(editor.collection == nil ? "Create" : "Save") {
                    let trimmed = exportDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
                    save(name, context, trimmed.isEmpty ? nil : trimmed)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .tint(Theme.accentFill)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            name = editor.collection?.name ?? ""
            context = editor.collection?.context ?? ""
            exportDirectoryPath = editor.collection?.exportDirectoryPath ?? ""
        }
    }

    private var displayExportPath: String {
        guard !exportDirectoryPath.isEmpty else { return "Not set (optional)" }
        return exportDirectoryPath.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private func chooseExportDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose a local folder where ReMeet will save .md files for meetings in this folder."
        if !exportDirectoryPath.isEmpty {
            let url = URL(fileURLWithPath: (exportDirectoryPath as NSString).expandingTildeInPath, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) { panel.directoryURL = url }
        }
        if panel.runModal() == .OK, let url = panel.url {
            exportDirectoryPath = url.path
        }
    }
}

/// One-time setup prompt shown only for brand-new empty folders with no context or AI export folder yet.
private struct FolderContextCard: View {
    let folder: MeetingCollection
    let edit: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: edit) {
                Text("Add context or AI export…")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.fg2)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Add background context or an AI Markdown export folder for \u{201C}\(folder.name)\u{201D}")

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Theme.fg3)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Theme.surface.opacity(0.65), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line.opacity(0.7)))
    }
}
