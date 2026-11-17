import ReMeetKit
import SwiftUI

/// Right-side transcript (⌘T): speaker blocks with times, your notes inline, rename a
/// speaker by clicking the name, click a time to play from there, ⌘F to find.
struct TranscriptInspector: View {
    @Environment(AppModel.self) private var model
    let document: MeetingDocument?
    let player: PlayerModel
    @State private var query = ""
    @State private var matchIndex = 0
    @State private var finding = false
    @State private var renaming: String?
    @State private var renameText = ""
    @FocusState private var findFocused: Bool
    @State private var picks: [WordPick] = []
    @State private var voiceName = ""
    @State private var voiceNotice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            voiceNaming
            Divider()
            if let transcript = document?.transcript, !transcript.segments.isEmpty {
                content(transcript)
            } else {
                Spacer()
                Text(document == nil ? "" : "The transcript appears here once the meeting has been transcribed.")
                    .font(.callout)
                    .foregroundStyle(Theme.fg2)
                    .multilineTextAlignment(.center)
                    .padding(24)
                    .frame(maxWidth: .infinity)
                Spacer()
            }
        }
        .background(Theme.surface)
        // ⌘F lives in the View menu; it opens the transcript and asks for the find field.
        .onChange(of: model.transcriptFindPending, initial: true) { _, pending in
            guard pending else { return }
            model.transcriptFindPending = false
            openFind()
        }
        .alert("Rename speaker", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let renaming, let document {
                    document.renameSpeaker(renaming, to: renameText)
                    model.library.refresh(document.folder)
                    model.reindex(document.folder)
                    Task { _ = await model.scheduleSpeakerWording(document) }
                }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("Only this voice is renamed. Other people in the meeting keep their names.")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Transcript").font(Fonts.section)
            if let count = document?.transcript?.wordCount, count > 0 {
                Text("\(count.formatted()) words")
                    .font(.caption)
                    .foregroundStyle(Theme.fg2)
            }
            Spacer()
            if finding {
                TextField("Find", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                    .focused($findFocused)
                    .onSubmit { step(1) }
                    .onKeyPress(.escape) {
                        finding = false
                        query = ""
                        return .handled
                    }
                Text(matchLabel).font(.caption.monospacedDigit()).foregroundStyle(Theme.fg2)
                Button { step(-1) } label: { Image(systemName: "chevron.up").frame(width: 22, height: 22).contentShape(Rectangle()) }
                    .buttonStyle(.plain).help("Previous match")
                Button { step(1) } label: { Image(systemName: "chevron.down").frame(width: 22, height: 22).contentShape(Rectangle()) }
                    .buttonStyle(.plain).help("Next match (Return)")
            } else {
                ShortcutHint("⌘F to find")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func content(_ transcript: Transcript) -> some View {
        let blocks = Self.blocks(transcript.segments, notes: document?.notes ?? [])
        let matches = matchingBlockIDs(blocks)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(blocks) { block in
                        blockView(block, isMatch: matches.indices.contains(matchIndex) && matches[matchIndex] == block.id,
                                  playing: player.isPlaying && block.contains(player.currentTime))
                            .id(block.id)
                    }
                }
                .padding(16)
            }
            .onChange(of: model.transcriptJump) { _, t in
                guard let t, let target = blocks.last(where: { $0.start <= t + 0.5 }) ?? blocks.first else { return }
                withAnimation { proxy.scrollTo(target.id, anchor: .top) }
                model.transcriptJump = nil
            }
            .onChange(of: matchIndex) { _, index in
                if matches.indices.contains(index) { withAnimation { proxy.scrollTo(matches[index], anchor: .center) } }
            }
            .onChange(of: query) {
                matchIndex = 0
                if let first = matches.first { proxy.scrollTo(first, anchor: .center) }
            }
            .onAppear {
                if let t = model.transcriptJump, let target = blocks.last(where: { $0.start <= t + 0.5 }) {
                    proxy.scrollTo(target.id, anchor: .top)
                    model.transcriptJump = nil
                }
            }
        }
    }

    @ViewBuilder private func blockView(_ block: Block, isMatch: Bool, playing: Bool) -> some View {
        switch block.kind {
        case .note(let note):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(note.kind == .bookmark ? "Bookmark" : note.kind == .action ? "Your action item" : "Your note")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                timeButton(note.t)
                Text(highlighted(note.text))
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Theme.fg)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.mark, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                if isMatch { RoundedRectangle(cornerRadius: 8).stroke(Theme.accent, lineWidth: 1.5) }
            }
        case .speech(let speaker, let segments):
            let spoken = Self.spokenWords(segments)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Button {
                        renameText = document?.speakers.names[speaker] ?? ""
                        renaming = speaker
                    } label: {
                        Text(document?.speakers.displayName(for: speaker) ?? speaker)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(speaker == SpeakerNames.youID ? Theme.accent : Theme.fg)
                            .hitTarget()
                    }
                    .buttonStyle(.plain)
                    .help("Rename this speaker")
                    timeButton(block.start)
                }
                let active = player.isPlaying
                    ? WordLayout.activeIndex(at: player.currentTime, words: spoken.map {
                        TranscriptWord(text: $0.text, start: $0.start, end: $0.end)
                    })
                    : nil
                FlowLayout(spacing: 4, lineSpacing: 3) {
                    ForEach(Array(spoken.enumerated()), id: \.element.id) { index, word in
                        wordButton(word, speaker: speaker, ordered: spoken, active: active == index)
                    }
                }
            }
            .padding(.leading, playing ? 8 : 0)
            .overlay(alignment: .leading) {
                if playing { Capsule().fill(Theme.accent).frame(width: 2) }
            }
            .background(isMatch ? Theme.mark.opacity(0.6) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private var voiceNaming: some View {
        let speaker = VoiceClip.speaker(picks.map(\.speaker))
        return VStack(alignment: .leading, spacing: 6) {
            if let speaker {
                HStack(spacing: 8) {
                    TextField("Name this voice", text: $voiceName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { saveVoice(speaker) }
                    Button("Save") { saveVoice(speaker) }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    Button("Clear") { picks = [] }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.fg2)
                }
                Text("This name is kept with the voice and offered in later meetings. It does not merge anyone.")
                    .font(.caption)
                    .foregroundStyle(Theme.fg2)
            } else if !picks.isEmpty {
                Text("Select words from one person.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let voiceNotice {
                Text(voiceNotice)
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, speaker == nil && picks.isEmpty && voiceNotice == nil ? 0 : 10)
    }

    private func wordButton(_ word: WordPick, speaker: String, ordered: [WordPick], active: Bool) -> some View {
        let chosen = picks.contains(word)
        let found = !query.isEmpty && word.text.localizedCaseInsensitiveContains(query)
        return Button {
            let shift = NSEvent.modifierFlags.contains(.shift)
            player.play(from: word.start)
            choose(word, speaker: speaker, ordered: ordered, shift: shift)
        } label: {
            Text(word.text)
                .font(.system(size: 13.5))
                .foregroundStyle(active ? Theme.accent : Theme.fg)
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(active || found ? Theme.mark : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                .overlay {
                    if chosen { RoundedRectangle(cornerRadius: 4).stroke(Theme.accent, lineWidth: 1) }
                }
        }
        .buttonStyle(.plain)
        .help("Play from this word. Shift-click to select a sentence, then name that voice.")
    }

    private func choose(_ word: WordPick, speaker: String, ordered: [WordPick], shift: Bool) {
        if shift, let anchor = picks.first, anchor.speaker == speaker,
           let from = ordered.firstIndex(of: anchor), let to = ordered.firstIndex(of: word) {
            picks = Array(ordered[min(from, to)...max(from, to)])
        } else {
            picks = [word]
            voiceName = document?.speakers.names[speaker] ?? ""
        }
        voiceNotice = nil
    }

    private func saveVoice(_ speaker: String) {
        let name = voiceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let document else { return }
        document.renameSpeaker(speaker, to: name)
        model.library.refresh(document.folder)
        model.reindex(document.folder)
        voiceNotice = "Saved \(document.speakers.displayName(for: speaker))."
        picks = []
        Task { _ = await model.scheduleSpeakerWording(document) }
    }

    private func timeButton(_ t: Double) -> some View {
        Button { player.play(from: t) } label: {
            Text(TimeFormat.clock(t))
                .font(Fonts.monoSmall)
                .foregroundStyle(Theme.fg3)
                .hitTarget()
        }
        .buttonStyle(.plain)
        .help("Play from here")
    }

    // MARK: - Find

    private func openFind() {
        finding = true
        DispatchQueue.main.async { findFocused = true }
    }

    private func matchingBlockIDs(_ blocks: [Block]) -> [String] {
        guard !query.isEmpty else { return [] }
        return blocks.filter { $0.searchText.localizedCaseInsensitiveContains(query) }.map(\.id)
    }

    private var matchLabel: String {
        guard let transcript = document?.transcript, !query.isEmpty else { return "" }
        let count = matchingBlockIDs(Self.blocks(transcript.segments, notes: document?.notes ?? [])).count
        return count == 0 ? "0" : "\(min(matchIndex + 1, count))/\(count)"
    }

    private func step(_ delta: Int) {
        guard let transcript = document?.transcript else { return }
        let count = matchingBlockIDs(Self.blocks(transcript.segments, notes: document?.notes ?? [])).count
        guard count > 0 else { return }
        matchIndex = (matchIndex + delta + count) % count
    }

    private func highlighted(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        guard !query.isEmpty else { return attributed }
        var searchRange = attributed.startIndex..<attributed.endIndex
        while let range = attributed[searchRange].range(of: query, options: .caseInsensitive) {
            attributed[range].backgroundColor = Theme.mark
            attributed[range].foregroundColor = Theme.accent
            searchRange = range.upperBound..<attributed.endIndex
        }
        return attributed
    }

    // MARK: - Blocks

    struct Block: Identifiable {
        enum Kind {
            case speech(speaker: String, segments: [TranscriptSegment])
            case note(MeetingNote)
        }

        var id: String
        var start: Double
        var end: Double
        var kind: Kind

        func contains(_ t: Double) -> Bool { t >= start && t < end }

        var searchText: String {
            switch kind {
            case .speech(_, let segments): segments.map(\.text).joined(separator: " ")
            case .note(let note): note.text
            }
        }
    }

    struct WordPick: Hashable, Identifiable {
        var id: String
        var text: String
        var speaker: String
        var start: Double
        var end: Double
    }

    static func spokenWords(_ segments: [TranscriptSegment]) -> [WordPick] {
        segments.flatMap { segment in
            WordLayout.words(text: segment.text, start: segment.start, end: segment.end, timed: segment.words)
                .enumerated()
                .map { index, word in
                    WordPick(id: "\(segment.id)#\(index)", text: word.text, speaker: segment.speaker,
                             start: word.start, end: word.end)
                }
        }
    }

    /// Consecutive segments of one speaker become one block; notes sit between them by time.
    static func blocks(_ segments: [TranscriptSegment], notes: [MeetingNote]) -> [Block] {
        var blocks: [Block] = []
        for item in Stitcher.interleave(segments, notes: notes) {
            switch item {
            case .note(let note):
                blocks.append(Block(id: "n\(note.id)", start: note.t, end: note.t, kind: .note(note)))
            case .segment(let s):
                if let last = blocks.last, case .speech(let speaker, var segments) = last.kind, speaker == s.speaker {
                    segments.append(s)
                    blocks[blocks.count - 1] = Block(id: last.id, start: last.start, end: s.end,
                                                     kind: .speech(speaker: speaker, segments: segments))
                } else {
                    blocks.append(Block(id: "s\(s.start)-\(s.speaker)", start: s.start, end: s.end,
                                        kind: .speech(speaker: s.speaker, segments: [s])))
                }
            }
        }
        return blocks
    }
}

/// Words wrap onto the next line. A single Text cannot make each word its own button.
private struct FlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 280
        var x: CGFloat = 0
        var y: CGFloat = 0
        var row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += row + lineSpacing
                row = 0
            }
            x += size.width + spacing
            row = max(row, size.height)
        }
        return CGSize(width: width, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += row + lineSpacing
                row = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}
