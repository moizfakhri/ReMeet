import AVFoundation
import ReMeetKit
import SwiftUI

/// One meeting as a document: big title, meta line, then Summary / Action items /
/// Your notes / Decisions / Open questions (empty sections hidden). Solid surface; the
/// player capsule floats over the bottom.
struct MeetingDetailView: View {
    @Environment(AppModel.self) private var model
    let document: MeetingDocument
    let player: PlayerModel
    @Binding var showTranscript: Bool
    @State private var title: String
    @State private var wordingStatus: String?
    @State private var wordingFailed = false
    @State private var editingDate = false
    @State private var draftDate = Date()
    @State private var dateHovered = false
    @State private var copiedFollowUp = false
    @FocusState private var titleFocused: Bool

    init(document: MeetingDocument, player: PlayerModel, showTranscript: Binding<Bool>) {
        self.document = document
        self.player = player
        self._showTranscript = showTranscript
        // Start with the real title. An empty State that fills in onAppear flashes a
        // blank heading on every sidebar click.
        self._title = State(initialValue: document.meta.title)
    }

    var body: some View {
        ScrollViewReader { proxy in
        ResponsiveDocumentScroll(maxWidth: 660, topPadding: 24, bottomPadding: 128) { width in
            VStack(alignment: .leading, spacing: 24) {
                header
                MeetingChatPanel(document: document, player: player, showTranscript: $showTranscript, compact: width < 400)
                    .id(MeetingChatPanel.anchorID)
                if let error = document.loadError {
                    Text(error).foregroundStyle(.orange).font(.callout)
                }
                sonnetNotes
                if let notice = model.queue.notices[document.folder] {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(notice)
                            .font(.callout)
                            .foregroundStyle(Theme.fg)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button("Dismiss") { model.queue.clearNotice(document.folder) }
                            .buttonStyle(.plain)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                    }
                    .padding(12)
                    .background(Theme.bg, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
                }
                if document.meta.status != .summarized || model.queue.isWorking(on: document.folder) {
                    ProcessingStatusView(meta: document.meta,
                                         activity: model.queue.current?.folder == document.folder ? model.queue.current : nil,
                                         waitingReason: model.queue.waiting[document.folder],
                                         stopping: model.queue.stoppingFolder == document.folder) {
                        model.queue.retry(document.folder)
                    } onStop: {
                        model.queue.stop(document.folder)
                    }
                }
                if !document.pulse.shares.isEmpty {
                    ConversationPulseBar(
                        pulse: document.pulse,
                        moments: document.moments,
                        hasAudio: document.folder.exists(.audio),
                        onScrub: jump,
                        onSelectSpeaker: { name in model.openPerson(named: name) }
                    )
                }
                KeyMomentsSection(document: document, player: player, onJumpToTranscript: jump)
                if let summary = document.summary {
                    SummarySections(summary: summary, document: document, onJump: jump)
                }
                if !document.notes.isEmpty || document.meta.status != .recording {
                    NotesSection(document: document, player: player, onJump: jump)
                }
                if let summary = document.summary {
                    PointsSection(title: "Decisions", points: summary.decisions, onJump: jump)
                    PointsSection(title: "Open questions", points: summary.openQuestions, onJump: jump)
                }
                SpeakerNamingSection(document: document, meetingPlayer: player)
            }
        }
        .overlay(alignment: .bottom) {
            // Solid Theme.surface covers the full height of PlayerCapsule (+ 12 pt above it)
            // so scrolled content fades cleanly before reaching the capsule and never refracts
            // or collides through Liquid Glass.
            VStack(spacing: 0) {
                LinearGradient(colors: [Theme.surface.opacity(0), Theme.surface],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 28)
                    .allowsHitTesting(false)
                Theme.surface
                    .frame(height: 76)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) {
                PlayerCapsule(player: player, notes: document.notes)
                    .padding(.bottom, 18)
                    .padding(.horizontal, 12)
            }
        }
        .onAppear {
            title = document.meta.title
            scrollToChatIfNeeded(proxy)
        }
        .onDisappear { if titleFocused { commitTitle() } }
        .onChange(of: document.folder.id) { _, _ in
            if titleFocused { titleFocused = false }
            title = document.meta.title
            wordingStatus = nil
            wordingFailed = false
            editingDate = false
        }
        .onChange(of: document.meta.title) { _, new in if !titleFocused { title = new } }
        .onChange(of: model.chatFocusPending) { _, _ in scrollToChatIfNeeded(proxy) }
        }
    }

    private func scrollToChatIfNeeded(_ proxy: ScrollViewProxy) {
        guard model.chatFocusPending else { return }
        proxy.scrollTo(MeetingChatPanel.anchorID, anchor: .top)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Title", text: $title, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Fonts.title)
                .foregroundStyle(Theme.fg)
                .focused($titleFocused)
                .onSubmit(commitTitle)
                .onChange(of: titleFocused) { _, focused in if !focused { commitTitle() } }

            // Row 1: Pure meeting facts (wraps cleanly without clipping on narrow widths).
            WrappingFlowLayout(spacing: 6, lineSpacing: 4) {
                dateButton
                if document.meta.effectiveDuration > 0 {
                    HStack(spacing: 6) {
                        Text("·").foregroundStyle(Theme.fg3)
                        Text(TimeFormat.duration(document.meta.effectiveDuration))
                    }
                }
                if document.wordCount > 0 {
                    HStack(spacing: 6) {
                        Text("·").foregroundStyle(Theme.fg3)
                        Text("\(document.wordCount.formatted()) words")
                    }
                }
                if let app = MeetingApps.displayName(for: document.meta.sourceApp) {
                    Text(app)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Theme.fg2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Theme.bg, in: Capsule())
                        .overlay(Capsule().stroke(Theme.line))
                        .padding(.leading, 2)
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(Theme.fg2)

            // Row 2: Compact wrapping pill controls for folder, speakers, wording, calendar, and follow-up.
            WrappingFlowLayout(spacing: 7, lineSpacing: 7) {
                folderMenu
                remindersListMenu
                callSpeakerMenu
                engineMenu
                if let eventID = document.meta.calendarEventID {
                    Button {
                        model.openSchedule(selecting: eventID)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "calendar")
                                .font(.system(size: 10.5))
                            Text(document.meta.calendarName ?? "Calendar")
                                .lineLimit(1)
                        }
                        .foregroundStyle(Theme.fg2)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Theme.bg, in: Capsule())
                        .overlay(Capsule().stroke(Theme.line))
                    }
                    .buttonStyle(.plain)
                    .help("Linked to your calendar invite — click to view schedule & attendees")
                }
                if let summary = document.summary {
                    Button {
                        copyFollowUp(summary: summary)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: copiedFollowUp ? "checkmark" : "paperplane")
                                .font(.system(size: 10.5))
                            Text(copiedFollowUp ? "Copied follow-up" : "Follow-up")
                        }
                        .foregroundStyle(copiedFollowUp ? Theme.accent : Theme.fg2)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(copiedFollowUp ? Theme.mark : Theme.bg, in: Capsule())
                        .overlay(Capsule().stroke(copiedFollowUp ? Theme.accent.opacity(0.3) : Theme.line))
                    }
                    .buttonStyle(.plain)
                    .help("Copy a clean Slack / email follow-up message with decisions and owners")
                }
            }
            .font(.system(size: 12))

            if let wordingStatus {
                HStack(spacing: 8) {
                    Text(wordingStatus)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(wordingFailed ? .orange : Theme.accent)
                        .fixedSize(horizontal: false, vertical: true)
                    if wordingStatus.contains("updating") {
                        Button("Stop") { model.stopWording() }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                }
            } else if let written = document.meta.processing.transcriptionEngine,
                      !written.isEmpty,
                      !written.contains("Sonnet") {
                Text("Wording: \(written). Sonnet 5.5 has not cleaned this yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var dateButton: some View {
        let canEdit = document.meta.status != .recording
        let sameYear = Calendar.current.isDate(document.meta.startTime, equalTo: Date(), toGranularity: .year)
        let dateText = sameYear
            ? document.meta.startTime.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
            : document.meta.startTime.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year())
        return Button {
            draftDate = document.meta.startTime
            editingDate = true
        } label: {
            HStack(spacing: 6) {
                Text(dateText)
                Text("·").foregroundStyle(Theme.fg3)
                Text(document.meta.startTime.formatted(date: .omitted, time: .shortened))
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background((dateHovered && canEdit) || editingDate ? Theme.bg : .clear, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke((dateHovered && canEdit) || editingDate ? Theme.line : .clear))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -5)
        .disabled(!canEdit)
        .onHover { dateHovered = $0 }
        .help(canEdit ? "Click to change meeting date and time" : "Recording in progress")
        .popover(isPresented: $editingDate, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Meeting date & time")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.fg)
                DatePicker("Date", selection: $draftDate, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                HStack {
                    Text("Time")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.fg2)
                    Spacer()
                    DatePicker("Time", selection: $draftDate, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                }
                HStack(spacing: 8) {
                    Spacer()
                    Button("Cancel") { editingDate = false }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button("Save") {
                        commitStartTime(draftDate)
                        editingDate = false
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accentFill)
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(14)
            .frame(width: 260)
        }
    }

    private var folderMenu: some View {
        let current = model.library.collection(document.meta.collectionID)
        return Menu {
            Button("No Folder") { model.library.move(document.folder, to: nil) }
                .disabled(current == nil)
            if !model.library.collections.isEmpty { Divider() }
            ForEach(model.library.collections) { folder in
                Button {
                    model.library.move(document.folder, to: folder.id)
                } label: {
                    if folder.exportDirectoryPath != nil {
                        Label(folder.name, systemImage: "arrow.down.doc")
                    } else {
                        Text(folder.name)
                    }
                }
                .disabled(current?.id == folder.id)
            }
            if let exported = document.meta.exportedMarkdownPath, !exported.isEmpty {
                Divider()
                Button("Reveal Exported .md") {
                    let fresh = (try? document.folder.readMeta())?.exportedMarkdownPath ?? exported
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: fresh)])
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: current?.exportDirectoryPath != nil ? "folder.badge.gearshape" : "folder")
                    .font(.system(size: 11))
                Text(current?.name ?? "No folder")
            }
            .foregroundStyle(current != nil ? Theme.accent : Theme.fg2)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(current != nil ? Theme.mark : Theme.bg, in: Capsule())
        .overlay(Capsule().stroke(current != nil ? Theme.accent.opacity(0.25) : Theme.line))
        .help(current?.exportDirectoryPath.map { "In \u{201C}\(current!.name)\u{201D} · auto-exporting .md to \($0)" }
              ?? "Assign this meeting to a folder")
    }

    private var remindersListMenu: some View {
        let resolvedLabel = model.resolvedRemindersListName(meta: document.meta)
        let hasOverride = (document.meta.remindersListID ?? "").isEmpty == false
        return Menu {
            Button {
                model.setMeetingRemindersList(document.folder, listID: nil, listName: nil, document: document)
            } label: {
                if !hasOverride {
                    Label("Use folder / default", systemImage: "checkmark")
                } else {
                    Text("Use folder / default")
                }
            }

            if !model.reminders.availableLists.isEmpty {
                Divider()
                Section("Route this meeting to") {
                    ForEach(model.reminders.availableLists) { list in
                        Button {
                            model.setMeetingRemindersList(document.folder, listID: list.id, listName: list.title, document: document)
                        } label: {
                            if document.meta.remindersListID == list.id {
                                Label(list.title, systemImage: "checkmark")
                            } else {
                                Text(list.title)
                            }
                        }
                    }
                }
            }

            if document.summary != nil {
                Divider()
                Button("Sync open items to Apple Reminders") {
                    model.syncMeetingActionItemsToReminders(document.folder, includeAllOpen: true, document: document)
                }
            }

            if !RemindersSyncService.hasAccess {
                Divider()
                Button("Connect Apple Reminders…") {
                    Task {
                        if await model.reminders.requestAccess() {
                            model.reminders.start()
                        } else {
                            model.openSettings(pane: .reminders)
                        }
                    }
                }
            } else {
                Button("Open Apple Reminders") {
                    model.reminders.openRemindersApp()
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "checklist")
                    .font(.system(size: 10.5))
                Text(resolvedLabel)
                    .lineLimit(1)
            }
            .foregroundStyle(hasOverride ? Theme.accent : Theme.fg2)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(hasOverride ? Theme.mark : Theme.bg, in: Capsule())
        .overlay(Capsule().stroke(hasOverride ? Theme.accent.opacity(0.25) : Theme.line))
        .help("Apple Reminders list for action items in this meeting")
    }

    private var callSpeakerMenu: some View {
        Menu {
            Button("Auto") { model.applyCallSpeakers(document, count: nil) }
            Divider()
            ForEach(1...12, id: \.self) { count in
                Button("\(count)") { model.applyCallSpeakers(document, count: count) }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "person.2")
                    .font(.system(size: 10.5))
                Text(document.meta.expectedCallSpeakers.map { "\($0) call" } ?? "Call speakers")
            }
            .foregroundStyle(Theme.fg2)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Theme.bg, in: Capsule())
        .overlay(Capsule().stroke(Theme.line))
        .help("How many voices to find on the call, besides you. Changing this finds the voices again. A name stays with a person only when the new voice still matches. Renaming someone does not do this.")
    }

    private var engineMenu: some View {
        Menu {
            Button("Redo transcription with Parakeet") { model.applyTranscriptionEngine(document, engine: .fast) }
                .disabled(!canRedoTranscription)
            Button("Redo transcription with Cohere") { model.applyTranscriptionEngine(document, engine: .accurate) }
                .disabled(!canRedoTranscription)
            Divider()
            Button("Clean wording with Sonnet 5.5") {
                Task {
                    wordingStatus = "Sonnet 5.5 is updating the wording…"
                    wordingFailed = false
                    let result = await model.cleanWithSonnet(document)
                    wordingFailed = result.message.map { !$0.hasPrefix("Stopped.") } ?? false
                    if let failure = result.message {
                        wordingStatus = failure
                    } else if result.wrote {
                        wordingStatus = "Wording updated. The summary is being rewritten."
                    } else {
                        wordingStatus = "Wording updated by Claude Sonnet 5.5."
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "waveform.and.magnifyingglass")
                    .font(.system(size: 10.5))
                Text(wordingLabel)
            }
            .foregroundStyle(Theme.fg2)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Theme.bg, in: Capsule())
        .overlay(Capsule().stroke(Theme.line))
        .help(engineHelp)
    }

    private var wordingLabel: String {
        if document.meta.processing.transcriptionEngine?.contains("Sonnet") == true { return "Sonnet 5.5" }
        let draft = meetingEngineLabel
        return draft == "Engine" ? "Draft" : draft
    }

    private var engineHelp: String {
        let written = document.meta.processing.transcriptionEngine
        if let written, written.contains("Sonnet") {
            return "This transcript was cleaned by Claude Sonnet 5.5. \(written)"
        }
        if let written, !written.isEmpty {
            return "\(written). Sonnet 5.5 has not cleaned these words yet. Choose Clean wording with Sonnet 5.5."
        }
        return "Parakeet or Cohere writes the draft from the audio. Sonnet 5.5 then fixes spelling, including your name."
    }

    private var canRedoTranscription: Bool {
        document.meta.status != .recording && document.reprocessStart < .summarize
    }

    private var meetingEngineLabel: String {
        if let raw = document.meta.processing.requestedTranscriptionEngine,
           let engine = TranscriptionEngine.resolve(raw) {
            let shown = engine == .sonnet ? TranscriptionEngine.fast : engine
            return shown.shortLabel
        }
        return "Engine"
    }

    @ViewBuilder private var sonnetNotes: some View {
        let notes = [document.meta.processing.sonnetTranscriptNote, document.meta.processing.sonnetSummaryNote]
            .compactMap { $0 }
        if !notes.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Sonnet")
                    .font(Fonts.section)
                ForEach(notes, id: \.self) { note in
                    Text(note)
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func commitTitle() {
        let before = document.meta.title
        document.rename(title)
        guard document.meta.title != before else { return }
        model.library.refresh(document.folder)
        model.documentEdited(document, reindexSearch: true)
    }

    private func commitStartTime(_ newDate: Date) {
        let before = document.meta.startTime
        document.setStartTime(newDate)
        guard document.meta.startTime != before else { return }
        model.library.refresh(document.folder)
        model.documentEdited(document, reindexSearch: true)
    }

    private func jump(_ t: Double) {
        player.play(from: max(0, t - 1))
        model.transcriptJump = t
        showTranscript = true
    }

    private func copyFollowUp(summary: MeetingSummary) {
        var participants = document.callSpeakers.map { document.speakers.displayName(for: $0) }
        for att in document.meta.calendarAttendees where att.status != .declined {
            if !participants.contains(where: { SpeakerMemory.namesMatch($0, att.name) }) {
                participants.append(att.name)
            }
        }
        let message = FollowUpComposer.compose(
            title: document.meta.title,
            date: document.meta.startTime,
            participants: participants,
            summary: summary,
            recorderName: AppModel.recorderName
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message, forType: .string)
        copiedFollowUp = true
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            copiedFollowUp = false
        }
    }
}

// MARK: - Sections

struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(Fonts.section)
            .foregroundStyle(Theme.fg)
    }
}

/// "↗ 12:34" link shown on hover next to a generated bullet.
struct JumpLink: View {
    let t: Double
    let action: (Double) -> Void
    var visible: Bool

    var body: some View {
        Button { action(t) } label: {
            Text("↗ \(TimeFormat.clock(t))")
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(Theme.accent)
                .hitTarget()
        }
        .buttonStyle(.plain)
        .opacity(visible ? 1 : 0)
        // Hidden until hover: an invisible link must not catch clicks.
        .allowsHitTesting(visible)
        .help("Open the transcript at \(TimeFormat.clock(t))")
    }
}

private struct SummarySections: View {
    @Environment(AppModel.self) private var model
    let summary: MeetingSummary
    let document: MeetingDocument
    let onJump: (Double) -> Void
    @State private var showOthers = false

    private var partitioned: (mine: [ActionItem], related: [ActionItem], others: [ActionItem]) {
        let otherCount = max(
            document.callSpeakers.count,
            document.meta.calendarAttendees.filter { $0.status != .declined }.count
        )
        return CommitmentsRadar.partition(summary.actionItems,
                                          recorderName: AppModel.recorderName,
                                          otherParticipantCount: otherCount)
    }

    var body: some View {
        if !summary.summary.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Summary")
                ForEach(summary.summary) { point in
                    BulletRow(text: point.text, t: point.t, onJump: onJump)
                }
            }
        }
        let tiers = partitioned
        if !tiers.mine.isEmpty || !tiers.related.isEmpty || !tiers.others.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Action items")

                if !tiers.mine.isEmpty {
                    tierHeader("For you", color: Theme.accent)
                    ForEach(tiers.mine) { item in
                        actionRow(item, tier: .mine)
                    }
                }

                if !tiers.related.isEmpty {
                    tierHeader("Waiting on others", color: Theme.fg2)
                        .padding(.top, tiers.mine.isEmpty ? 0 : 2)
                    ForEach(tiers.related) { item in
                        actionRow(item, tier: .relatedToMe)
                    }
                }

                if !tiers.others.isEmpty {
                    let expandByDefault = tiers.mine.isEmpty && tiers.related.isEmpty
                    if expandByDefault {
                        ForEach(tiers.others) { item in
                            actionRow(item, tier: .others)
                        }
                    } else {
                        Button {
                            withAnimation(.snappy(duration: 0.16)) { showOthers.toggle() }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .rotationEffect(.degrees(showOthers ? 90 : 0))
                                Text("Other team items (\(tiers.others.count))")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .foregroundStyle(Theme.fg3)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Show or hide action items owned by others that do not involve you")

                        if showOthers {
                            ForEach(tiers.others) { item in
                                actionRow(item, tier: .others)
                            }
                        }
                    }
                }
            }
        }
    }

    private func tierHeader(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(color)
    }

    private func actionRow(_ item: ActionItem, tier: CommitmentItem.Relevance) -> some View {
        ActionItemRow(
            item: item,
            tier: tier,
            availableReminderLists: model.reminders.availableLists,
            onJump: onJump,
            onToggle: { done in
                let rid = document.setActionItem(item, done: done)
                if let rid {
                    Task { await model.reminders.syncCompletion(reminderID: rid, done: done) }
                }
                model.documentEdited(document)
            },
            onAssignToYou: {
                document.updateActionItem(item, owner: .some("You"), relatesToMe: .some(true))
                model.documentEdited(document)
            },
            onSetRelated: { related in
                document.updateActionItem(item, relatesToMe: .some(related))
                model.documentEdited(document)
            },
            onDismiss: {
                document.updateActionItem(item, dismissed: true)
                model.documentEdited(document)
            },
            onSendToReminders: { listID in
                model.sendActionItemToReminders(item, in: document.folder, listID: listID, document: document)
            },
            onUnlinkReminder: { deleteInReminders in
                model.unlinkActionItemFromReminders(item, in: document.folder, deleteInReminders: deleteInReminders, document: document)
            }
        )
    }
}

struct BulletRow: View {
    let text: String
    let t: Double?
    let onJump: (Double) -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle().fill(Theme.fg3).frame(width: 4, height: 4).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 4 }
            Text(text)
                .font(.system(size: 14.5))
                .foregroundStyle(Theme.fg2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let t { JumpLink(t: t, action: onJump, visible: hovering) }
        }
        .onHover { hovering = $0 }
    }
}

private struct ActionItemRow: View {
    let item: ActionItem
    let tier: CommitmentItem.Relevance
    let availableReminderLists: [ReminderListInfo]
    let onJump: (Double) -> Void
    let onToggle: (Bool) -> Void
    let onAssignToYou: () -> Void
    let onSetRelated: (Bool) -> Void
    let onDismiss: () -> Void
    let onSendToReminders: (String?) -> Void
    let onUnlinkReminder: (Bool) -> Void
    @State private var hovering = false

    var body: some View {
        let meta = [item.owner, item.due].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Toggle("", isOn: Binding(get: { item.done }, set: onToggle))
                .toggleStyle(.checkbox)
                .labelsHidden()
            Text(item.task)
                .font(.system(size: 14.5))
                .foregroundStyle(item.done ? Theme.fg3 : Theme.fg)
                .strikethrough(item.done, color: Theme.fg3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let t = item.t { JumpLink(t: t, action: onJump, visible: hovering) }
            if let rid = item.reminderID, !rid.isEmpty {
                let listLabel = item.reminderListName ?? "Reminders"
                Menu {
                    if !availableReminderLists.isEmpty {
                        Section("Move to list") {
                            ForEach(availableReminderLists) { list in
                                Button {
                                    onSendToReminders(list.id)
                                } label: {
                                    if list.id == item.reminderListID {
                                        Label(list.title, systemImage: "checkmark")
                                    } else {
                                        Text(list.title)
                                    }
                                }
                            }
                        }
                    }
                    Divider()
                    Button("Unlink from ReMeet") { onUnlinkReminder(false) }
                    Button("Delete from Apple Reminders", role: .destructive) { onUnlinkReminder(true) }
                } label: {
                    HStack(spacing: 3.5) {
                        Image(systemName: "checklist")
                            .font(.system(size: 9.5, weight: .semibold))
                        Text(listLabel)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 7.5)
                    .padding(.vertical, 2)
                    .background(Theme.mark, in: Capsule())
                    .overlay(Capsule().stroke(Theme.accent.opacity(0.25)))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Synced to Apple Reminders list \u{201C}\(listLabel)\u{201D}")
            }
            if !meta.isEmpty {
                Text(meta)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(tier == .mine ? Theme.accent : Theme.fg2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(tier == .mine ? Theme.mark : Theme.bg, in: Capsule())
                    .overlay(Capsule().stroke(tier == .mine ? Theme.accent.opacity(0.25) : Theme.line))
            }
            Menu {
                if item.reminderID == nil {
                    Button("Send to Apple Reminders") { onSendToReminders(nil) }
                    if !availableReminderLists.isEmpty {
                        Menu("Send to Reminders list") {
                            ForEach(availableReminderLists) { list in
                                Button(list.title) { onSendToReminders(list.id) }
                            }
                        }
                    }
                    Divider()
                } else if !availableReminderLists.isEmpty {
                    Menu("Move to Reminders list") {
                        ForEach(availableReminderLists) { list in
                            Button(list.title) { onSendToReminders(list.id) }
                        }
                    }
                    Button("Unlink from Apple Reminders") { onUnlinkReminder(false) }
                    Divider()
                }
                if tier != .mine {
                    Button("Assign to You", action: onAssignToYou)
                }
                if tier == .others {
                    Button("Mark as waiting on them (for you)") { onSetRelated(true) }
                } else if tier == .relatedToMe {
                    Button("Move to other team items") { onSetRelated(false) }
                }
                Divider()
                Button("Dismiss action item", role: .destructive, action: onDismiss)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.fg3)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
        }
        .onHover { hovering = $0 }
    }
}

/// Isolates `player.currentTime` observation so playback ticks (10 Hz) only re-render this
/// tiny button instead of invalidating the entire `NotesSection` on every frame.
private struct AddNoteAtPlayheadButton: View {
    let player: PlayerModel
    let onAdd: (Double) -> Void

    var body: some View {
        Button {
            onAdd((player.currentTime * 10).rounded() / 10)
        } label: {
            Label("Add at \(TimeFormat.clock(player.currentTime))", systemImage: "plus")
                .font(.system(size: 12))
                .hitTarget()
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.accent)
        .help("Add a note at the player's position")
    }
}

/// Your notes: accent left edge, full-strength text; editable. With a summary, each note
/// gets the summarizer's context line underneath.
private struct NotesSection: View {
    @Environment(AppModel.self) private var model
    let document: MeetingDocument
    let player: PlayerModel
    let onJump: (Double) -> Void
    @State private var editing: UUID?
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(title: "Your notes")
                Spacer()
                AddNoteAtPlayheadButton(player: player) { timestamp in
                    let note = MeetingNote(t: timestamp, text: "", kind: .note)
                    save(document.notes + [note])
                    draft = ""
                    editing = note.id
                }
            }
            if document.summary != nil, document.notesChangedSinceSummary {
                HStack(spacing: 10) {
                    Text("Your notes changed since the summary was written.")
                        .font(.callout).foregroundStyle(Theme.fg2)
                    Spacer()
                    Button("Regenerate summary") {
                        model.regenerateSummary(document.folder, backend: model.summaryBackend)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.accentFill)
                }
                .padding(10)
                .background(Theme.mark, in: RoundedRectangle(cornerRadius: 10))
            }
            ForEach(document.notes) { note in
                row(note)
            }
        }
    }

    private func row(_ note: MeetingNote) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Button { onJump(note.t) } label: {
                Text(TimeFormat.clock(note.t))
                    .font(Fonts.monoSmall)
                    .foregroundStyle(Theme.accent)
                    .hitTarget()
            }
            .buttonStyle(.plain)
            .help("Play from here")
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if editing == note.id {
                        TextField("Note", text: $draft, onCommit: { commit(note) })
                            .textFieldStyle(.plain)
                            .font(.system(size: 14.5, weight: .medium))
                            .onExitCommand { editing = nil }
                    } else {
                        Text(note.displayText)
                            .font(.system(size: 14.5, weight: .medium))
                            .foregroundStyle(note.kind == .bookmark ? Theme.fg2 : Theme.fg)
                            .textSelection(.enabled)
                            .onTapGesture(count: 2) {
                                draft = note.text
                                editing = note.id
                            }
                    }
                    if note.kind == .action { NoteKindBadge(text: "Action") }
                    Spacer(minLength: 4)
                    Menu {
                        Button("Edit") {
                            draft = note.text
                            editing = note.id
                        }
                        Picker("Kind", selection: Binding(get: { note.kind }, set: { change(note, kind: $0) })) {
                            Text("Note").tag(MeetingNote.Kind.note)
                            Text("Action item").tag(MeetingNote.Kind.action)
                            Text("Bookmark").tag(MeetingNote.Kind.bookmark)
                        }
                        Divider()
                        Button("Delete", role: .destructive) {
                            save(document.notes.filter { $0.id != note.id })
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .foregroundStyle(Theme.fg3)
                }
                if let context = context(for: note) {
                    Text(context)
                        .font(.system(size: 13.5))
                        .foregroundStyle(Theme.fg2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.leading, 12)
        .overlay(alignment: .leading) {
            Capsule().fill(Theme.accent).frame(width: 3)
        }
    }

    private func commit(_ note: MeetingNote) {
        var notes = document.notes
        if let i = notes.firstIndex(where: { $0.id == note.id }) {
            notes[i].text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            if notes[i].text.isEmpty, notes[i].kind != .bookmark { notes[i].kind = .bookmark }
        }
        editing = nil
        save(notes)
    }

    private func change(_ note: MeetingNote, kind: MeetingNote.Kind) {
        var notes = document.notes
        if let i = notes.firstIndex(where: { $0.id == note.id }) { notes[i].kind = kind }
        save(notes)
    }

    private func save(_ notes: [MeetingNote]) {
        document.saveNotes(notes)
        model.notesEdited(document)
    }

    private func context(for note: MeetingNote) -> String? {
        guard let text = document.summary?.yourNotes.first(where: { abs($0.t - note.t) < 1.5 })?.context,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}

private struct PointsSection: View {
    let title: String
    let points: [SummaryPoint]
    let onJump: (Double) -> Void

    var body: some View {
        if !points.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: title)
                ForEach(points) { BulletRow(text: $0.text, t: $0.t, onJump: onJump) }
            }
        }
    }
}

// MARK: - Who else spoke

/// One row per non-user voice: a short clip from the call track, an inline name field,
/// and at most one voiceprint suggestion.
private struct SpeakerNamingSection: View {
    @Environment(AppModel.self) private var model
    let document: MeetingDocument
    let meetingPlayer: PlayerModel
    @State private var drafts: [String: String] = [:]
    @State private var memory = SpeakerMemory()
    @State private var suggestions: [String: VoiceSuggestion] = [:]
    @State private var preview = SpeakerClipPlayer()
    @State private var savedID: String?
    @State private var notice: String?
    @State private var noticeIsError = false
    @State private var cleaning = false
    @State private var cleanGeneration = 0
    @State private var dismissedSuggestions: Set<String> = []

    @State private var expanded = false

    private var unnamedCount: Int {
        document.callSpeakers.filter { id in
            SpeakerMemory.isPlaceholder(document.speakers.names[id] ?? "")
        }.count
    }

    var body: some View {
        let ids = document.callSpeakers
        if !ids.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Button {
                        withAnimation(.snappy(duration: 0.18)) { expanded.toggle() }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Theme.fg3)
                                .rotationEffect(.degrees(expanded ? 90 : 0))
                                .frame(width: 12)
                            SectionHeader(title: "Speakers")
                            Text(ids.map { document.speakers.displayName(for: $0) }.joined(separator: ", "))
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.fg2)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Play a clip and pick or type a name, or click any speaker name in the transcript")

                    Spacer(minLength: 8)

                    if expanded, document.hasSystemTrack, ids.count < 12 {
                        Button {
                            model.applyCallSpeakers(document, count: min(12, ids.count + 1))
                        } label: {
                            Label("Find more", systemImage: "person.badge.plus")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Theme.fg2)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2.5)
                                .background(Theme.surface, in: Capsule())
                                .overlay(Capsule().stroke(Theme.line))
                        }
                        .buttonStyle(.plain)
                        .help("Missed someone on the call? Re-run speaker detection looking for \(ids.count + 1) voices")
                    } else if !expanded, unnamedCount > 0 {
                        Text("\(unnamedCount) unnamed")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Theme.mark, in: Capsule())
                    }
                }

                if expanded {
                    if let notice {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(notice)
                                .font(.caption)
                                .foregroundStyle(noticeIsError ? .orange : Theme.accent)
                                .fixedSize(horizontal: false, vertical: true)
                            if cleaning {
                                Button("Stop", action: stopCleaning)
                                    .buttonStyle(.plain)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                    }
                    ForEach(ids, id: \.self) { id in
                        row(id, people: ids, alike: document.speakerAlike[id])
                    }
                }
            }
            .padding(14)
            .background(Theme.bg.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
            .task(id: document.folder.id) {
                preview.pause()
                savedID = nil
                notice = nil
                expanded = false
                dismissedSuggestions = []
                await load(ids)
            }
            .onChange(of: document.speakers) { _, _ in
                for id in ids where drafts[id] == nil {
                    drafts[id] = document.speakers.names[id] ?? ""
                }
                recomputeSuggestions()
            }
            .onDisappear { preview.pause() }
        }
    }

    private func row(_ id: String, people: [String], alike: SpeakerLikeness.Pair?) -> some View {
        let clip = document.speakerClips[id]
        let canPlay = clip != nil && document.hasSystemTrack
        let playing = preview.playingID == id
        let sameName = duplicate(of: id, among: people)
        let currentDraft = (drafts[id] ?? document.speakers.names[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let savedName = (document.speakers.names[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let dirty = currentDraft != savedName
        let isUnnamed = SpeakerMemory.isPlaceholder(savedName)
        let peopleStore = PeopleStore(profiles: model.hub.people.map(\.profile))
        let inviteHints = isUnnamed
            ? CalendarSpeakerHints.unassignedInvitees(attendees: document.meta.calendarAttendees,
                                                      existing: document.speakers,
                                                      recorderName: AppModel.recorderName,
                                                      store: peopleStore)
            : []
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    toggleClip(id)
                } label: {
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canPlay && !playing)
                .help(playing ? "Pause this clip" : (canPlay ? "Play a short clip of this voice from the call audio" : "The call audio for this clip is no longer on disk"))
                if !isUnnamed {
                    PersonAvatarView(name: savedName, size: 20)
                }
                TextField(document.speakers.displayName(for: id), text: binding(id))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.fg)
                    .frame(maxWidth: 180)
                    .onSubmit { commit(id, name: drafts[id] ?? "") }
                if dirty {
                    Button("Save") { commit(id, name: drafts[id] ?? "") }
                        .buttonStyle(.plain)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                } else if savedID == id && !cleaning {
                    Text("Saved")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                } else if !isUnnamed {
                    Button {
                        model.openPerson(named: savedName)
                    } label: {
                        Image(systemName: "person.text.rectangle")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.fg3)
                            .hitTarget(4)
                    }
                    .buttonStyle(.plain)
                    .help("Open \(savedName) in People")
                }
                Spacer(minLength: 4)
                if let suggestion = suggestions[id],
                   !dismissedSuggestions.contains("\(id)::\(suggestion.name)") {
                    HStack(spacing: 4) {
                        Button {
                            commit(id, name: suggestion.name)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: suggestion.onInvite ? "calendar.badge.checkmark" : "waveform")
                                    .font(.system(size: 10))
                                Text(suggestion.onInvite
                                     ? "\(suggestion.name) · On invite"
                                     : "Sounds like \(suggestion.name)")
                                    .lineLimit(1)
                            }
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.accent)
                        }
                        .buttonStyle(.plain)
                        .help("Use this saved voiceprint for this speaker")

                        Button {
                            dismissedSuggestions.insert("\(id)::\(suggestion.name)")
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Theme.fg3)
                        }
                        .buttonStyle(.plain)
                        .help("Dismiss suggestion")
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Theme.mark, in: Capsule())
                }
                quickPickMenu(id, isUnnamed: isUnnamed, inviteHints: inviteHints)
                mergeMenu(id, people: people)
            }
            if isUnnamed, !inviteHints.isEmpty {
                WrappingFlowLayout(spacing: 6, lineSpacing: 5) {
                    Image(systemName: "calendar")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.fg3)
                        .padding(.top, 3)
                        .help("Invited on calendar — click to assign")
                    ForEach(inviteHints.prefix(5), id: \.self) { invitee in
                        Button {
                            commit(id, name: invitee)
                        } label: {
                            Text(invitee)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Theme.fg)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Theme.surface, in: Capsule())
                                .overlay(Capsule().stroke(Theme.line))
                        }
                        .buttonStyle(.plain)
                        .help("Assign \(invitee) and save their voiceprint for future calls")
                    }
                }
                .padding(.leading, 30)
            }
            if let sameName {
                Button("Merge with the other \(sameName)") { merge(id, intoFirstNamed: sameName, among: people) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            } else if let alike {
                likenessButton(id, pair: alike)
            }
        }
        .padding(10)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(savedID == id ? Theme.accent : Theme.line, lineWidth: savedID == id ? 1.5 : 1))
    }

    private func likenessButton(_ id: String, pair: SpeakerLikeness.Pair) -> some View {
        let stored = document.speakers.names[pair.target] ?? ""
        let title = SpeakerMemory.isPlaceholder(stored) ? "These sound alike. Merge" : "Sounds like \(stored). Merge"
        return Button(title) { merge(id, into: pair.target) }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.accent)
            .help("These two rows sound like the same person. Nothing merges until you click.")
    }

    private func quickPickMenu(_ id: String, isUnnamed: Bool, inviteHints: [String]) -> some View {
        let assignedLower = Set(document.speakers.names.values.map { $0.lowercased() })
        let candidates = model.hub.people.filter { person in
            let lower = person.profile.name.lowercased()
            return !assignedLower.contains(lower)
                && !inviteHints.contains { SpeakerMemory.namesMatch($0, person.profile.name) }
        }
        return Menu {
            if !inviteHints.isEmpty {
                Section("Calendar invite") {
                    ForEach(inviteHints, id: \.self) { invitee in
                        Button(invitee) { commit(id, name: invitee) }
                    }
                }
            }
            if let emb = document.diarization?.embeddings[id], !emb.isEmpty {
                let attendees = document.meta.calendarAttendees.filter { $0.status != .declined }.map(\.name)
                let ranked = memory.rankedMatches(for: emb, attendeeNames: attendees, limit: 3)
                if !ranked.isEmpty {
                    Section("Voice matches") {
                        ForEach(ranked, id: \.name) { match in
                            Button("\(match.name) (\(Int((match.score * 100).rounded()))%)") {
                                commit(id, name: match.name)
                            }
                        }
                    }
                }
            }
            if !candidates.isEmpty {
                Section("People") {
                    ForEach(candidates.prefix(20)) { person in
                        Button(person.profile.name) { commit(id, name: person.profile.name) }
                    }
                }
            }
            if !isUnnamed {
                Divider()
                Button("Clear name & unlearn voice", role: .destructive) {
                    drafts[id] = ""
                    document.clearSpeakerName(id)
                    memory = SpeakerMemoryFile.load(SpeakerMemoryFile.url(beside: document.folder))
                    recomputeSuggestions()
                    notice = "Cleared name."
                    noticeIsError = false
                    model.library.refresh(document.folder)
                    model.documentEdited(document, reindexSearch: true)
                }
            }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.fg2)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Pick from calendar invitees or People, or clear name")
    }

    private func mergeMenu(_ id: String, people: [String]) -> some View {
        Menu("Merge") {
            Button("You (\(AppModel.recorderName))") { merge(id, into: SpeakerNames.youID) }
            Divider()
            ForEach(people.filter { $0 != id }, id: \.self) { other in
                Button(document.speakers.displayName(for: other)) { merge(id, into: other) }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("This voice is the same person as the one you pick. The other rows stay as they are.")
    }

    private func binding(_ id: String) -> Binding<String> {
        Binding(
            get: { drafts[id] ?? document.speakers.names[id] ?? "" },
            set: { drafts[id] = $0 }
        )
    }

    private func load(_ ids: [String]) async {
        let url = SpeakerMemoryFile.url(beside: document.folder)
        let loaded = await Task.detached(priority: .utility) { SpeakerMemoryFile.load(url) }.value
        guard !Task.isCancelled else { return }
        memory = loaded
        var next: [String: String] = [:]
        for id in ids { next[id] = document.speakers.names[id] ?? "" }
        drafts = next
        recomputeSuggestions()
    }

    private func recomputeSuggestions() {
        let embeddings = document.diarization?.embeddings ?? [:]
        guard !embeddings.isEmpty, !memory.voices.isEmpty else {
            suggestions = [:]
            return
        }
        let inviteNames = document.meta.calendarAttendees.filter { $0.status != .declined }.map(\.name)
        let offered = memory.suggestions(for: embeddings, existing: document.speakers, attendeeNames: inviteNames)
        suggestions = Dictionary(uniqueKeysWithValues: offered.map { ($0.speaker, $0) })
    }

    private func toggleClip(_ id: String) {
        if preview.playingID == id {
            preview.pause()
            return
        }
        guard let clip = document.speakerClips[id], document.hasSystemTrack else { return }
        meetingPlayer.pause()
        preview.play(id: id, url: document.folder.file(.system16k), start: clip.start, end: clip.end)
    }

    private func duplicate(of id: String, among people: [String]) -> String? {
        let name = (drafts[id] ?? document.speakers.names[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !SpeakerMemory.isPlaceholder(name) else { return nil }
        let matches = people.filter { other in
            other != id && (document.speakers.names[other] ?? "").compare(name, options: .caseInsensitive) == .orderedSame
        }
        return matches.isEmpty ? nil : name
    }

    private func merge(_ id: String, intoFirstNamed name: String, among people: [String]) {
        guard let target = people.first(where: { other in
            other != id && (document.speakers.names[other] ?? "").compare(name, options: .caseInsensitive) == .orderedSame
        }) else { return }
        merge(id, into: target)
    }

    private func merge(_ id: String, into target: String) {
        document.mergeSpeakers(from: id, into: target)
        drafts[id] = nil
        savedID = target
        notice = "Merged into \(document.speakers.displayName(for: target))."
        noticeIsError = false
        recomputeSuggestions()
        model.library.refresh(document.folder)
        model.documentEdited(document, reindexSearch: true)
        scheduleClean()
    }

    private func commit(_ id: String, name: String) {
        drafts[id] = name
        document.renameSpeaker(id, to: name)
        memory = SpeakerMemoryFile.load(SpeakerMemoryFile.url(beside: document.folder))
        recomputeSuggestions()
        savedID = id
        notice = "Saved \(document.speakers.displayName(for: id))."
        noticeIsError = false
        model.library.refresh(document.folder)
        model.documentEdited(document, reindexSearch: true)
        scheduleClean()
    }

    private func stopCleaning() {
        cleanGeneration += 1
        cleaning = false
        notice = "Stopped. The transcript was not changed."
        noticeIsError = false
        model.stopWording()
    }

    /// One Sonnet pass after the user stops naming, so five saves do not start five calls.
    private func scheduleClean() {
        cleanGeneration += 1
        let token = cleanGeneration
        cleaning = true
        notice = "Saved. Sonnet 5.5 will update the wording, then the summary."
        Task {
            notice = "Sonnet 5.5 is updating the wording…"
            let result = await model.scheduleSpeakerWording(document)
            guard token == cleanGeneration else { return }
            if result.skipped { return }
            cleaning = false
            if let failure = result.message {
                notice = failure
                noticeIsError = !failure.hasPrefix("Stopped.")
            } else if result.wrote {
                notice = "Wording updated. The summary is being rewritten."
                noticeIsError = false
            } else {
                notice = "Wording updated by Claude Sonnet 5.5."
                noticeIsError = false
            }
        }
    }
}

/// Plays a range of the system track. The meeting player keeps the mixed file for the whole recording.
@MainActor
@Observable
private final class SpeakerClipPlayer {
    private(set) var playingID: String?
    private let player = AVPlayer()
    private var token = 0

    func play(id: String, url: URL, start: Double, end: Double) {
        token += 1
        let current = token
        playingID = id
        let seconds = max(0.4, end - start)
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        let begin = CMTime(seconds: max(0, start), preferredTimescale: 600)
        player.seek(to: begin, toleranceBefore: .zero, toleranceAfter: .zero)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard current == token else { return }
            player.play()
            try? await Task.sleep(for: .seconds(seconds))
            guard current == token else { return }
            pause()
        }
    }

    func pause() {
        token += 1
        player.pause()
        playingID = nil
    }
}

// MARK: - Processing

/// The five steps with checkmarks, the current one with progress, and Retry on failure.
struct ProcessingStatusView: View {
    let meta: MeetingMeta
    let activity: ProcessingQueue.Activity?
    var waitingReason: String?
    var stopping = false
    let onRetry: () -> Void
    var onStop: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            row("Recorded", done: meta.status != .recording, current: meta.status == .recording, progress: nil)
            ForEach(PipelineStage.allCases, id: \.self) { stage in
                let done = meta.completedStages.contains(stage)
                let isCurrent = activity?.stage == stage
                row(stage.displayName, done: done, current: isCurrent, progress: isCurrent ? activity?.progress : nil,
                    failed: meta.failure?.stage == stage)
            }
            if let failure = meta.failure {
                VStack(alignment: .leading, spacing: 8) {
                    Text(failure.message.hasPrefix("Stopped.") ? failure.message : "\(failure.stage.displayName) failed: \(failure.message)")
                        .font(.callout)
                        .foregroundStyle(Theme.fg)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Your audio is safe. Retry picks up at this step.")
                        .font(.caption)
                        .foregroundStyle(Theme.fg2)
                    Button(action: onRetry) {
                        Text("Retry")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(Theme.accentFill, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 6)
            } else if activity != nil || stopping {
                Button(stopping ? "Stopping…" : "Stop") { onStop() }
                    .disabled(stopping)
                    .help(stopping
                          ? "Sonnet stops immediately. The on-device summary finishes its current pass, then stops. The last saved transcript stays."
                          : "Stop this step. The last saved transcript and summary stay, and you can run it again.")
            } else if let waitingReason {
                Text(waitingReason)
                    .font(.callout)
                    .foregroundStyle(Theme.fg2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Button("Open Settings to download it") { AppModel.shared.openSettings() }
                        .buttonStyle(.link)
                    Button("Stop") { onStop() }
                }
            } else if activity == nil, meta.status != .recording {
                Text("Waiting. Processing pauses while you record and runs one meeting at a time.")
                    .font(.caption)
                    .foregroundStyle(Theme.fg2)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line))
    }

    private func row(_ title: String, done: Bool, current: Bool, progress: Double?, failed: Bool = false) -> some View {
        HStack(spacing: 10) {
            ZStack {
                if failed {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                } else if done {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                } else if current {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "circle").foregroundStyle(Theme.fg3)
                }
            }
            .frame(width: 18)
            Text(title)
                .foregroundStyle(done || current ? Theme.fg : Theme.fg2)
            if let progress {
                ProgressView(value: progress).frame(width: 120)
                Text("\(Int(progress * 100))%").font(.caption.monospacedDigit()).foregroundStyle(Theme.fg2)
            }
        }
        .font(.system(size: 13.5))
    }
}
