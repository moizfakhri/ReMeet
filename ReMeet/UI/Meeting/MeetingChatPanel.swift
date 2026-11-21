import ReMeetKit
import SwiftUI

/// Weeve-style "find an answer" ask box for the open meeting.
struct MeetingChatPanel: View {
    static let anchorID = "meeting-chat"

    @Environment(AppModel.self) private var model
    let document: MeetingDocument
    let player: PlayerModel
    @Binding var showTranscript: Bool

    @State private var scope: MeetingChatScope = .thisMeeting
    @State private var question = ""
    @State private var thread = MeetingChatThread()
    @State private var errorText: String?
    @State private var loading = false
    @State private var askTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    private var answerBackend: MeetingChatAnswerBackend { model.chatAnswerBackend }

    private var canAsk: Bool {
        switch answerBackend {
        case .sonnet: ClaudeSonnet.isAvailable
        case .mlx: model.models.isReady(.summaryLLM)
        }
    }

    private var canSubmit: Bool {
        canAsk && (loading || !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var isExpanded: Bool {
        !thread.turns.isEmpty || loading || errorText != nil || focused || !question.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isExpanded {
                HStack(alignment: .center, spacing: 8) {
                    Label("Ask about meetings", systemImage: "sparkles")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.fg2)
                    Spacer(minLength: 8)
                    Picker("Scope", selection: $scope) {
                        ForEach(availableScopes) { value in
                            Text(value.label).tag(value)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(maxWidth: 310)
                    .disabled(loading)
                }
            }
            if !thread.turns.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(thread.turns.enumerated()), id: \.offset) { _, turn in
                        if turn.role == .user {
                            Text(turn.text)
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(Theme.fg)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                                .padding(.top, 2)
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(turn.text)
                                    .font(.callout)
                                    .foregroundStyle(Theme.fg2)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                                if !turn.sources.isEmpty {
                                    SourcePills(sources: turn.sources, titles: sourceTitles(from: turn.sources))
                                }
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.bg, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
            if let errorText {
                Text(errorText)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if loading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(loadingMessage)
                        .font(.callout)
                        .foregroundStyle(Theme.fg2)
                }
            } else if !canAsk {
                Text(emptyMessage)
                    .font(.caption)
                    .foregroundStyle(Theme.fg2)
            }
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.accent)
                TextField("Ask about decisions, action items, or what someone said… (⌘L)", text: $question, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.fg)
                    .lineLimit(1...4)
                    .focused($focused)
                    .disabled(!canAsk || loading)
                    .onSubmit { if canAsk { submit() } }
                if !isExpanded {
                    Menu {
                        ForEach(availableScopes) { value in
                            Button {
                                scope = value
                            } label: {
                                if scope == value {
                                    Label(value.label, systemImage: "checkmark")
                                } else {
                                    Text(value.label)
                                }
                            }
                        }
                    } label: {
                        Text(scope.label)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Theme.fg2)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Choose whether to search this meeting, this folder, or all recordings")
                }
                Button {
                    loading ? cancel() : submit()
                } label: {
                    Text(loading ? "Stop" : "Ask")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(canSubmit ? Color.white : Theme.fg3)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(canSubmit ? Theme.accentFill : Theme.line.opacity(0.6), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, isExpanded ? 12 : 9)
        .background(Theme.bg.opacity(0.75), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(focused ? Theme.accent.opacity(0.6) : Theme.line))
        .onAppear {
            consumeChatFocus()
        }
        .task(id: document.folder.id) {
            cancel()
            question = ""
            errorText = nil
            scope = .thisMeeting
            let url = MeetingChatThread.fileURL(in: document.folder)
            let loaded = await Task.detached(priority: .userInitiated) {
                MeetingChatThread.load(from: url)
            }.value
            guard !Task.isCancelled else { return }
            thread = loaded
        }
        .onChange(of: document.meta.collectionID) { _, _ in
            if document.meta.collectionID == nil, scope == .thisFolder {
                scope = .thisMeeting
            }
        }
        .onChange(of: model.chatFocusPending) { _, _ in consumeChatFocus() }
        .onDisappear {
            cancel()
        }
    }

    private var emptyMessage: String {
        switch answerBackend {
        case .sonnet where !ClaudeSonnet.isAvailable:
            "Install the Claude CLI at ~/.local/bin/claude to ask questions. ReMeet does not use an API key. Settings can switch Chat to the on-device model."
        case .mlx where !model.models.isReady(.summaryLLM):
            "Download the built-in summary model in Settings to answer on this Mac, or switch Chat answers back to Sonnet."
        default:
            "Ask about decisions, action items, or what someone said. Follow-ups keep this thread. Answers cite the transcript."
        }
    }

    private var loadingMessage: String {
        switch scope {
        case .allRecordings, .thisFolder:
            return answerBackend == .mlx ? "Searching your recordings and asking the on-device model…" : "Searching your recordings and asking Sonnet…"
        case .thisMeeting:
            let tokens = MeetingChunkBuilder.estimatedTokens(
                transcript: document.transcript,
                summary: document.summary,
                notes: document.notes
            )
            if tokens > MeetingChunkBuilder.fullContextTokenLimit {
                return answerBackend == .mlx ? "Searching this meeting and asking the on-device model…" : "Searching this meeting and asking Sonnet…"
            }
            return answerBackend == .mlx ? "Asking the on-device model…" : "Asking Sonnet…"
        }
    }

    private var availableScopes: [MeetingChatScope] {
        if document.meta.collectionID == nil {
            return [.thisMeeting, .allRecordings]
        }
        return MeetingChatScope.allCases
    }

    private func consumeChatFocus() {
        guard model.chatFocusPending else { return }
        focused = true
        DispatchQueue.main.async { model.chatFocusPending = false }
    }

    private func submit() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !loading, canAsk else { return }
        loading = true
        errorText = nil
        let recorderName = UserDefaults.standard.string(forKey: SettingsKey.userName) ?? ""
        let context = MeetingChatService.Context(
            document: document,
            chunkIndex: model.chunkIndex,
            recorderName: recorderName
        )
        let activeScope = scope
        let history = thread.turns
        let embedder = model
        askTask?.cancel()
        askTask = Task {
            let result = await MeetingChatService.answer(
                question: text,
                scope: activeScope,
                context: context,
                history: history,
                embedQuery: { query in await embedder.embedChatQuery(query) }
            ) { question, passages, history, recorderName in
                try await embedder.answerChat(question: question, passages: passages, history: history, recorderName: recorderName)
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                loading = false
                switch result {
                case .success(let value):
                    guard !value.answer.isEmpty else { return }
                    thread = thread.appending(question: text, answer: value)
                    try? thread.save(to: MeetingChatThread.fileURL(in: document.folder))
                    question = ""
                case .failure(let error):
                    if let chat = error as? MeetingChatError {
                        errorText = chat.errorDescription
                    } else if let haiku = error as? HaikuBridgeError {
                        errorText = haiku.errorDescription
                    } else if error is CancellationError {
                        errorText = nil
                    } else {
                        errorText = error.localizedDescription
                    }
                }
            }
        }
    }

    private func cancel() {
        ClaudeSonnet.stop(.chat)
        askTask?.cancel()
        askTask = nil
        loading = false
    }

    private func sourceTitles(from sources: [MeetingChatSource]) -> [String: String] {
        var titles: [String: String] = [:]
        for source in sources {
            if source.meetingID == document.folder.id {
                titles[source.meetingID] = document.meta.title
            } else if let item = model.library.items.first(where: { $0.id == source.meetingID }) {
                titles[source.meetingID] = item.meta.title
            } else if let title = try? model.chunkIndex?.meetingTitle(for: source.meetingID) {
                titles[source.meetingID] = title
            }
        }
        return titles
    }

    @ViewBuilder
    private func SourcePills(sources: [MeetingChatSource], titles: [String: String]) -> some View {
        FlowLayout(spacing: 6) {
            ForEach(sources) { source in
                let title = titles[source.meetingID] ?? source.meetingID
                Button {
                    followCitation(source)
                } label: {
                    Text("\(title) · \(source.label) · \(TimeFormat.clock(source.start))")
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Theme.mark, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func followCitation(_ source: MeetingChatSource) {
        showTranscript = true
        if source.meetingID == document.folder.id {
            player.play(from: max(0, source.start - 1))
            model.transcriptJump = source.start
        } else {
            model.openCitation(meetingID: source.meetingID, start: source.start,
                               switchingFrom: document.folder.id)
        }
    }
}

/// Simple left-to-right wrap for source pills.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
    }
}