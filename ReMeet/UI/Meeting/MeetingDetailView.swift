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
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                MeetingChatPanel(document: document, player: player, showTranscript: $showTranscript)
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
                        Button("Dismiss") { model.queue.clearNotice(document.folder) }
                            .buttonStyle(.plain)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                    }
                }
                SpeakerNamingSection(document: document, meetingPlayer: player)
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
                if let summary = document.summary {
                    SummarySections(summary: summary, document: document, onJump: jump)
                }
                if !document.notes.isEmpty || document.meta.status != .recording {
                    NotesSection(document: document, player: player, onJump: jump)
                }
                if let summary = document.summary {
                    PointsSection(title: "Decisions", points: summary.decisions, onJump: jump)
                    PointsSection(title: "Open questions", points: summary.openQuestions, onJump: jump)
                    footer
                }
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.top, 28)
            .padding(.bottom, 120)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.surface)
        .overlay(alignment: .bottom) {
            PlayerCapsule(player: player, notes: document.notes)
                .padding(.bottom, 18)
                .padding(.horizontal, 24)
        }
        .onAppear {
            title = document.meta.title
            scrollToChatIfNeeded(proxy)
        }
        .onDisappear { if titleFocused { commitTitle() } }
        .onChange(of: document.meta.title) { _, new in if !titleFocused { title = new } }
        .onChange(of: model.chatFocusPending) { _, _ in scrollToChatIfNeeded(proxy) }
        }
    }

    private func scrollToChatIfNeeded(_ proxy: ScrollViewProxy) {
        guard model.chatFocusPending else { return }
        proxy.scrollTo(MeetingChatPanel.anchorID, anchor: .top)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Title", text: $title, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Fonts.title)
                .foregroundStyle(Theme.fg)
                .focused($titleFocused)
                .onSubmit(commitTitle)
                .onChange(of: titleFocused) { _, focused in if !focused { commitTitle() } }
            HStack(spacing: 6) {
                Text(document.meta.startTime.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                Text("·")
                Text(document.meta.startTime.formatted(date: .omitted, time: .shortened))
                Text("·")
                Text(TimeFormat.duration(document.meta.effectiveDuration))
                if let count = document.transcript?.wordCount, count > 0 {
                    Text("·")
                    Text("\(count.formatted()) words")
                }
                callSpeakerMenu
                engineMenu
                if let app = MeetingApps.displayName(for: document.meta.sourceApp) {
                    Text(app)
                        .font(.system(size: 12))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 1)
                        .overlay(Capsule().stroke(Theme.line))
                }
            }
            .font(.system(size: 13))
            .lineLimit(1)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(Theme.fg2)
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
            } else if let written = document.meta.processing.transcriptionEngine, !written.isEmpty {
                Text(written.contains("Sonnet") ? "Wording: \(written)" : "Wording: \(written). Sonnet 5.5 has not cleaned this yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(written.contains("Sonnet") ? Theme.fg2 : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var callSpeakerMenu: some View {
        Menu {
            Button("Auto") { model.applyCallSpeakers(document, count: nil) }
            Divider()
            ForEach(1...8, id: \.self) { count in
                Button("\(count)") { model.applyCallSpeakers(document, count: count) }
            }
        } label: {
            Text(document.meta.expectedCallSpeakers.map { "\($0) call" } ?? "Call speakers")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
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
            Text(wordingLabel)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
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
        document.meta.status != .recording && AppModel.reprocessStart(document.folder) < .summarize
    }

    private var meetingEngineLabel: String {
        if let raw = document.meta.processing.requestedTranscriptionEngine,
           let engine = TranscriptionEngine.resolve(raw) {
            let shown = engine == .sonnet ? TranscriptionEngine.fast : engine
            return shown.shortLabel
        }
        return "Engine"
    }

    @ViewBuilder private var footer: some View {
        let p = document.meta.processing
        HStack(spacing: 6) {
            if let seconds = p.summarySeconds {
                Text("Written \(summaryAttribution(p.summaryBackend)) in \(TimeFormat.duration(seconds))")
            }
            if let backend = p.summaryBackend {
                Text("·")
                Text([backend, p.summaryModel].compactMap { $0 }.joined(separator: " "))
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.fg3)
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

    private func summaryAttribution(_ backend: String?) -> String {
        if backend == "Gemini" { return "by Gemini" }
        if backend?.contains("Sonnet") == true { return "by Sonnet" }
        return "on this Mac"
    }

    private func commitTitle() {
        let before = document.meta.title
        document.rename(title)
        guard document.meta.title != before else { return }
        model.library.refresh(document.folder)
        model.reindex(document.folder)
    }

    private func jump(_ t: Double) {
        player.play(from: max(0, t - 1))
        model.transcriptJump = t
        showTranscript = true
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
    let summary: MeetingSummary
    let document: MeetingDocument
    let onJump: (Double) -> Void

    var body: some View {
        if !summary.summary.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Summary")
                ForEach(summary.summary) { point in
                    BulletRow(text: point.text, t: point.t, onJump: onJump)
                }
            }
        }
        if !summary.actionItems.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Action items")
                ForEach(summary.actionItems) { item in
                    ActionItemRow(item: item, onJump: onJump) { done in
                        document.setActionItem(item, done: done)
                    }
                }
            }
        }
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
    let onJump: (Double) -> Void
    let onToggle: (Bool) -> Void
    @State private var hovering = false

    var body: some View {
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
            Text([item.owner, item.due].compactMap { $0 }.joined(separator: ", "))
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.fg2)
        }
        .onHover { hovering = $0 }
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
                Button {
                    let note = MeetingNote(t: (player.currentTime * 10).rounded() / 10, text: "", kind: .note)
                    save(document.notes + [note])
                    draft = ""
                    editing = note.id
                } label: {
                    Label("Add at \(TimeFormat.clock(player.currentTime))", systemImage: "plus")
                        .font(.system(size: 12))
                        .hitTarget()
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                .help("Add a note at the player's position")
            }
            if document.summary != nil, model.notesChangedSinceSummary(document) {
                HStack(spacing: 10) {
                    Text("Your notes changed since the summary was written.")
                        .font(.callout).foregroundStyle(Theme.fg2)
                    Spacer()
                    Button("Regenerate summary") {
                        model.regenerateSummary(document.folder, backend: model.summaryBackend)
                    }
                    .buttonStyle(.glassProminent)
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

/// One row per non-user voice: a short clip from the call track, a name, and at most one voiceprint suggestion.
private struct SpeakerNamingSection: View {
    @Environment(AppModel.self) private var model
    let document: MeetingDocument
    let meetingPlayer: PlayerModel
    @State private var drafts: [String: String] = [:]
    @State private var memory = SpeakerMemory()
    @State private var preview = SpeakerClipPlayer()
    @State private var savedID: String?
    @State private var notice: String?
    @State private var noticeIsError = false
    @State private var cleaning = false
    @State private var cleanGeneration = 0

    private var people: [String] {
        var seen: [String] = []
        for segment in document.transcript?.segments ?? [] where segment.source == .system && segment.speaker != SpeakerNames.youID {
            if !seen.contains(segment.speaker) { seen.append(segment.speaker) }
        }
        return seen
    }

    private var suggestions: [String: String] {
        let embeddings = document.diarization?.embeddings ?? [:]
        let offered = memory.suggestions(for: embeddings, existing: document.speakers)
        return Dictionary(uniqueKeysWithValues: offered.map { ($0.speaker, $0.name) })
    }

    var body: some View {
        let ids = people
        if !ids.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Who else spoke")
                Text("Select their words in the transcript and type their name. ReMeet remembers that voice for the next meeting. Two rows that are the same person stay separate until you merge them.")
                    .font(.caption)
                    .foregroundStyle(Theme.fg2)
                    .fixedSize(horizontal: false, vertical: true)
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
                    row(id, people: ids, alike: alike[id])
                }
            }
            .task(id: document.folder.id) { load(ids) }
            .onChange(of: document.speakers) { _, _ in
                for id in ids where drafts[id] == nil {
                    drafts[id] = document.speakers.names[id] ?? ""
                }
            }
        }
    }

    private var alike: [String: SpeakerLikeness.Pair] {
        let pairs = SpeakerLikeness.pairs(document.diarization?.embeddings ?? [:], order: people)
        return Dictionary(uniqueKeysWithValues: pairs.map { ($0.source, $0) })
    }

    private func row(_ id: String, people: [String], alike: SpeakerLikeness.Pair?) -> some View {
        let clip = SpeakerClip.excerpt(speaker: id, segments: document.transcript?.segments ?? [])
        let canPlay = clip != nil && document.folder.exists(.system16k)
        let playing = preview.playingID == id
        let sameName = duplicate(of: id, among: people)
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
                Text(document.speakers.displayName(for: id))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.fg)
                if savedID == id && !cleaning {
                    Text("Saved")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
                Spacer(minLength: 8)
                if let name = suggestions[id] {
                    Button("Sounds like \(name)") { commit(id, name: name) }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .help("Use this saved voice for this person only")
                }
                mergeMenu(id, people: people)
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

    private func load(_ ids: [String]) {
        memory = SpeakerMemoryFile.load(SpeakerMemoryFile.url(beside: document.folder))
        var next: [String: String] = [:]
        for id in ids { next[id] = document.speakers.names[id] ?? "" }
        drafts = next
    }

    private func toggleClip(_ id: String) {
        if preview.playingID == id {
            preview.pause()
            return
        }
        guard let clip = SpeakerClip.excerpt(speaker: id, segments: document.transcript?.segments ?? []),
              document.folder.exists(.system16k) else { return }
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
        model.library.refresh(document.folder)
        model.reindex(document.folder)
        scheduleClean()
    }

    private func commit(_ id: String, name: String) {
        drafts[id] = name
        document.renameSpeaker(id, to: name)
        memory = SpeakerMemoryFile.load(SpeakerMemoryFile.url(beside: document.folder))
        savedID = id
        notice = "Saved \(document.speakers.displayName(for: id))."
        noticeIsError = false
        model.library.refresh(document.folder)
        model.reindex(document.folder)
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
                    Button("Retry", action: onRetry)
                        .buttonStyle(.glassProminent)
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
