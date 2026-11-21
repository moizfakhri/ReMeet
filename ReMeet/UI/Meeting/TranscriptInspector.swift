import AppKit
import ReMeetKit
import SwiftUI

/// Right-side transcript (⌘T): speaker blocks with times, your notes inline, rename a
/// speaker by clicking the name, click a word or time to play from there, ⌘F to find.
///
/// Rendered by an AppKit `NSTextView` + `NSAttributedString` (like Weeve) instead of
/// thousands of SwiftUI word buttons in a `FlowLayout`. Handles 10,000+ words in <2 ms,
/// supports native text selection/copy, instant Find, and zero-relayout active-word
/// highlighting via `NSLayoutManager` temporary attributes.
struct TranscriptInspector: View {
    @Environment(AppModel.self) private var model
    let document: MeetingDocument?
    let player: PlayerModel

    @State private var query = ""
    @State private var matchIndex = 0
    @State private var matchCount = 0
    @State private var finding = false
    @State private var renaming: String?
    @State private var renameText = ""
    @FocusState private var findFocused: Bool
    @State private var selectedSpeaker: String?
    @State private var selectionHasMixedSpeakers = false
    @State private var voiceName = ""
    @State private var voiceNotice: String?
    @State private var clearSelectionToken = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            voiceNaming
            Divider()
            if let document, let transcript = document.transcript, !transcript.segments.isEmpty {
                TranscriptTextView(
                    documentID: document.folder.id,
                    transcript: transcript,
                    notes: document.notes,
                    speakers: document.speakers,
                    player: player,
                    query: query,
                    matchIndex: matchIndex,
                    jumpTime: model.transcriptJump,
                    clearSelectionToken: clearSelectionToken,
                    onJumpConsumed: { model.transcriptJump = nil },
                    onMatchCountChanged: { count in
                        if matchCount != count {
                            matchCount = count
                            if matchIndex >= count { matchIndex = 0 }
                        }
                    },
                    onPlayAt: { t in player.play(from: t) },
                    onRenameSpeaker: { speakerID in
                        renameText = document.speakers.names[speakerID] ?? ""
                        renaming = speakerID
                    },
                    onWordSelectionChanged: { speakerID, mixed in
                        selectedSpeaker = speakerID
                        selectionHasMixedSpeakers = mixed
                        if let speakerID {
                            voiceName = document.speakers.names[speakerID] ?? ""
                        }
                        voiceNotice = nil
                    }
                )
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
        .onChange(of: document?.folder.id) { _, _ in
            selectedSpeaker = nil
            selectionHasMixedSpeakers = false
            voiceName = ""
            voiceNotice = nil
            matchIndex = 0
        }
        .onChange(of: query) { _, _ in
            matchIndex = 0
        }
        .alert("Rename speaker", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let renaming, let document {
                    document.renameSpeaker(renaming, to: renameText)
                    model.library.refresh(document.folder)
                    model.documentEdited(document, reindexSearch: true)
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
            if let count = document?.wordCount, count > 0 {
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
                if !query.isEmpty {
                    Text(matchCount == 0 ? "0" : "\(min(matchIndex + 1, matchCount))/\(matchCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.fg2)
                }
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

    private var voiceNaming: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let speaker = selectedSpeaker {
                HStack(spacing: 8) {
                    TextField("Name this voice", text: $voiceName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { saveVoice(speaker) }
                    Button("Save") { saveVoice(speaker) }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    Button("Clear") {
                        selectedSpeaker = nil
                        selectionHasMixedSpeakers = false
                        clearSelectionToken += 1
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.fg2)
                }
                Text("This name is kept with the voice and offered in later meetings. It does not merge anyone.")
                    .font(.caption)
                    .foregroundStyle(Theme.fg2)
            } else if selectionHasMixedSpeakers {
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
        .padding(.bottom, selectedSpeaker == nil && !selectionHasMixedSpeakers && voiceNotice == nil ? 0 : 10)
    }

    private func saveVoice(_ speaker: String) {
        let name = voiceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let document else { return }
        document.renameSpeaker(speaker, to: name)
        model.library.refresh(document.folder)
        model.documentEdited(document, reindexSearch: true)
        voiceNotice = "Saved \(document.speakers.displayName(for: speaker))."
        selectedSpeaker = nil
        selectionHasMixedSpeakers = false
        clearSelectionToken += 1
        Task { _ = await model.scheduleSpeakerWording(document) }
    }

    private func openFind() {
        finding = true
        DispatchQueue.main.async { findFocused = true }
    }

    private func step(_ delta: Int) {
        guard matchCount > 0 else { return }
        matchIndex = (matchIndex + delta + matchCount) % matchCount
    }
}

// MARK: - AppKit NSTextView transcript renderer

/// Thin SwiftUI bridge that isolates playback ticks: `TranscriptTextView` observes `player`
/// inside its own body so the surrounding `TranscriptInspector` chrome never re-evaluates at 10 Hz.
private struct TranscriptTextView: View {
    let documentID: String
    let transcript: Transcript
    let notes: [MeetingNote]
    let speakers: SpeakerNames
    let player: PlayerModel
    let query: String
    let matchIndex: Int
    let jumpTime: Double?
    let clearSelectionToken: Int
    let onJumpConsumed: () -> Void
    let onMatchCountChanged: (Int) -> Void
    let onPlayAt: (Double) -> Void
    let onRenameSpeaker: (String) -> Void
    let onWordSelectionChanged: (String?, Bool) -> Void

    var body: some View {
        TranscriptRepresentable(
            documentID: documentID,
            transcript: transcript,
            notes: notes,
            speakers: speakers,
            isPlaying: player.isPlaying,
            currentTime: player.isPlaying ? player.currentTime : -1,
            query: query,
            matchIndex: matchIndex,
            jumpTime: jumpTime,
            clearSelectionToken: clearSelectionToken,
            onJumpConsumed: onJumpConsumed,
            onMatchCountChanged: onMatchCountChanged,
            onPlayAt: onPlayAt,
            onRenameSpeaker: onRenameSpeaker,
            onWordSelectionChanged: onWordSelectionChanged
        )
    }
}

private struct TranscriptRepresentable: NSViewRepresentable {
    let documentID: String
    let transcript: Transcript
    let notes: [MeetingNote]
    let speakers: SpeakerNames
    let isPlaying: Bool
    let currentTime: Double
    let query: String
    let matchIndex: Int
    let jumpTime: Double?
    let clearSelectionToken: Int
    let onJumpConsumed: () -> Void
    let onMatchCountChanged: (Int) -> Void
    let onPlayAt: (Double) -> Void
    let onRenameSpeaker: (String) -> Void
    let onWordSelectionChanged: (String?, Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(containerSize: NSSize(width: 340, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)

        let textView = InteractiveTranscriptTextView(frame: .zero, textContainer: textContainer)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 14, height: 14)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.linkTextAttributes = [:]
        textView.coordinator = context.coordinator
        textView.delegate = context.coordinator

        scroll.documentView = textView
        context.coordinator.textView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.onPlayAt = onPlayAt
        c.onRenameSpeaker = onRenameSpeaker
        c.onWordSelectionChanged = onWordSelectionChanged
        c.onMatchCountChanged = onMatchCountChanged

        let contentChanged = c.documentID != documentID
            || c.transcript != transcript
            || c.notes != notes
            || c.speakers != speakers

        if contentChanged {
            c.documentID = documentID
            c.transcript = transcript
            c.notes = notes
            c.speakers = speakers
            c.rebuildDocument()
            c.applyQuery(query, matchIndex: matchIndex, force: true)
        } else if c.lastQuery != query || c.lastMatchIndex != matchIndex {
            c.applyQuery(query, matchIndex: matchIndex, force: false)
        }

        if c.lastClearSelectionToken != clearSelectionToken {
            c.lastClearSelectionToken = clearSelectionToken
            c.clearPickedRange()
        }

        c.updatePlaybackHighlight(isPlaying: isPlaying, currentTime: currentTime)

        if let jumpTime {
            c.scrollToTime(jumpTime)
            DispatchQueue.main.async { onJumpConsumed() }
        }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        struct WordSpan {
            var range: NSRange
            var start: Double
            var end: Double
            var speaker: String
        }

        struct BlockAnchor {
            var start: Double
            var range: NSRange
        }

        struct ClickTarget {
            enum Kind {
                case speaker(String)
                case time(Double)
            }
            var range: NSRange
            var kind: Kind
        }

        weak var textView: InteractiveTranscriptTextView?
        var documentID: String = ""
        var transcript: Transcript?
        var notes: [MeetingNote] = []
        var speakers = SpeakerNames()

        var onPlayAt: ((Double) -> Void)?
        var onRenameSpeaker: ((String) -> Void)?
        var onWordSelectionChanged: ((String?, Bool) -> Void)?
        var onMatchCountChanged: ((Int) -> Void)?

        private var wordSpans: [WordSpan] = []
        private var blockAnchors: [BlockAnchor] = []
        private var clickTargets: [ClickTarget] = []
        private var activeWordRange: NSRange?
        private var pickedWordAnchorIndex: Int?
        private var pickedHighlightRange: NSRange?
        private var matchRanges: [NSRange] = []
        var lastQuery = ""
        var lastMatchIndex = 0
        var lastClearSelectionToken = 0

        func rebuildDocument() {
            guard let textView, let transcript else { return }
            activeWordRange = nil
            pickedWordAnchorIndex = nil
            pickedHighlightRange = nil
            wordSpans.removeAll(keepingCapacity: true)
            blockAnchors.removeAll(keepingCapacity: true)
            clickTargets.removeAll(keepingCapacity: true)

            let built = NSMutableAttributedString()
            let speakerFont = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
            let timeFont = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
            let bodyFont = NSFont.systemFont(ofSize: 13.5, weight: .regular)
            let noteFont = NSFont.systemFont(ofSize: 13.5, weight: .medium)
            let noteLabelFont = NSFont.systemFont(ofSize: 12, weight: .semibold)

            let headerParagraph = NSMutableParagraphStyle()
            headerParagraph.paragraphSpacingBefore = 12
            headerParagraph.paragraphSpacing = 2

            let firstHeaderParagraph = NSMutableParagraphStyle()
            firstHeaderParagraph.paragraphSpacingBefore = 0
            firstHeaderParagraph.paragraphSpacing = 2

            let bodyParagraph = NSMutableParagraphStyle()
            bodyParagraph.lineSpacing = 3
            bodyParagraph.paragraphSpacing = 4

            let noteParagraph = NSMutableParagraphStyle()
            noteParagraph.paragraphSpacingBefore = 10
            noteParagraph.paragraphSpacing = 6
            noteParagraph.headIndent = 8
            noteParagraph.firstLineHeadIndent = 8

            // Group consecutive segments of the same speaker, interleaved with notes.
            var blocks: [(start: Double, kind: BlockKind)] = []
            for item in Stitcher.interleave(transcript.segments, notes: notes) {
                switch item {
                case .note(let note):
                    blocks.append((note.t, .note(note)))
                case .segment(let s):
                    if let last = blocks.last, case .speech(let sp, var segs) = last.kind, sp == s.speaker {
                        segs.append(s)
                        blocks[blocks.count - 1].kind = .speech(speaker: sp, segments: segs)
                    } else {
                        blocks.append((s.start, .speech(speaker: s.speaker, segments: [s])))
                    }
                }
            }

            for (blockIndex, block) in blocks.enumerated() {
                let blockStartLoc = built.length
                switch block.kind {
                case .note(let note):
                    let kindLabel = note.kind == .bookmark ? "Bookmark"
                        : note.kind == .action ? "Your action item" : "Your note"
                    built.append(NSAttributedString(string: "▎ \(kindLabel)  ", attributes: [
                        .font: noteLabelFont,
                        .foregroundColor: Theme.nsAccent,
                        .backgroundColor: Theme.nsMark,
                        .paragraphStyle: noteParagraph,
                    ]))
                    let timeLoc = built.length
                    let timeStr = TimeFormat.clock(note.t)
                    built.append(NSAttributedString(string: timeStr, attributes: [
                        .font: timeFont,
                        .foregroundColor: Theme.nsFg2,
                        .backgroundColor: Theme.nsMark,
                        .paragraphStyle: noteParagraph,
                    ]))
                    clickTargets.append(ClickTarget(
                        range: NSRange(location: timeLoc, length: (timeStr as NSString).length),
                        kind: .time(note.t)))
                    let noteText = note.text.isEmpty ? " " : "  \(note.text) "
                    built.append(NSAttributedString(string: "\(noteText)\n", attributes: [
                        .font: noteFont,
                        .foregroundColor: Theme.nsFg,
                        .backgroundColor: Theme.nsMark,
                        .paragraphStyle: noteParagraph,
                    ]))
                    blockAnchors.append(BlockAnchor(
                        start: block.start,
                        range: NSRange(location: blockStartLoc, length: built.length - blockStartLoc)))

                case .speech(let speaker, let segments):
                    let pStyle = blockIndex == 0 ? firstHeaderParagraph : headerParagraph
                    let nameLoc = built.length
                    let displayName = speakers.displayName(for: speaker)
                    let nameColor = speaker == SpeakerNames.youID ? Theme.nsAccent : Theme.nsFg
                    built.append(NSAttributedString(string: displayName, attributes: [
                        .font: speakerFont,
                        .foregroundColor: nameColor,
                        .paragraphStyle: pStyle,
                    ]))
                    clickTargets.append(ClickTarget(
                        range: NSRange(location: nameLoc, length: (displayName as NSString).length),
                        kind: .speaker(speaker)))

                    built.append(NSAttributedString(string: "  ", attributes: [
                        .font: timeFont,
                        .paragraphStyle: pStyle,
                    ]))

                    let timeLoc = built.length
                    let timeStr = TimeFormat.clock(block.start)
                    built.append(NSAttributedString(string: "\(timeStr)\n", attributes: [
                        .font: timeFont,
                        .foregroundColor: Theme.nsFg3,
                        .paragraphStyle: pStyle,
                    ]))
                    clickTargets.append(ClickTarget(
                        range: NSRange(location: timeLoc, length: (timeStr as NSString).length),
                        kind: .time(block.start)))

                    var firstWord = true
                    for segment in segments {
                        let timed = WordLayout.words(text: segment.text, start: segment.start,
                                                     end: segment.end, timed: segment.words)
                        for word in timed {
                            if !firstWord {
                                built.append(NSAttributedString(string: " ", attributes: [
                                    .font: bodyFont,
                                    .foregroundColor: Theme.nsFg,
                                    .paragraphStyle: bodyParagraph,
                                ]))
                            }
                            firstWord = false
                            let loc = built.length
                            built.append(NSAttributedString(string: word.text, attributes: [
                                .font: bodyFont,
                                .foregroundColor: Theme.nsFg,
                                .paragraphStyle: bodyParagraph,
                            ]))
                            let len = built.length - loc
                            wordSpans.append(WordSpan(
                                range: NSRange(location: loc, length: len),
                                start: word.start,
                                end: word.end,
                                speaker: speaker))
                        }
                    }
                    built.append(NSAttributedString(string: "\n", attributes: [
                        .font: bodyFont,
                        .paragraphStyle: bodyParagraph,
                    ]))
                    blockAnchors.append(BlockAnchor(
                        start: block.start,
                        range: NSRange(location: blockStartLoc, length: built.length - blockStartLoc)))
                }
            }

            textView.textStorage?.setAttributedString(built)
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            // Keep wordSpans sorted by range.location (naturally sorted during append).
        }

        private enum BlockKind {
            case speech(speaker: String, segments: [TranscriptSegment])
            case note(MeetingNote)
        }

        // MARK: - Playback word highlight (O(log W), zero text relayout)

        func updatePlaybackHighlight(isPlaying: Bool, currentTime: Double) {
            guard let lm = textView?.layoutManager else { return }
            let nextRange: NSRange?
            if isPlaying, currentTime >= 0, let index = activeWordIndex(at: currentTime) {
                nextRange = wordSpans[index].range
            } else {
                nextRange = nil
            }
            guard nextRange != activeWordRange else { return }
            if let old = activeWordRange {
                lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: old)
                lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: old)
            }
            activeWordRange = nextRange
            if let next = nextRange {
                lm.addTemporaryAttribute(.backgroundColor, value: Theme.nsMark, forCharacterRange: next)
                lm.addTemporaryAttribute(.foregroundColor, value: Theme.nsAccent, forCharacterRange: next)
            }
        }

        private func activeWordIndex(at time: Double) -> Int? {
            // Word spans follow chronological block order; scan nearby or binary-search by start.
            // Interleaved tracks can have small overlaps, so check a tiny window around the upper bound.
            guard !wordSpans.isEmpty else { return nil }
            var lo = 0
            var hi = wordSpans.count - 1
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                if wordSpans[mid].start <= time {
                    lo = mid
                } else {
                    hi = mid - 1
                }
            }
            let lower = max(0, lo - 4)
            let upper = min(wordSpans.count - 1, lo + 4)
            for i in lower...upper {
                if time >= wordSpans[i].start && time < wordSpans[i].end { return i }
            }
            // Match WordLayout.activeIndex fallback: last word that already started within the same block.
            if time >= wordSpans[lo].start && time <= wordSpans[lo].end + 0.35 { return lo }
            return nil
        }

        // MARK: - Find (⌘F)

        func applyQuery(_ query: String, matchIndex: Int, force: Bool) {
            guard let textView, let lm = textView.layoutManager else { return }
            let queryChanged = force || query != lastQuery
            lastQuery = query
            lastMatchIndex = matchIndex

            if queryChanged {
                for range in matchRanges {
                    lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
                }
                matchRanges.removeAll(keepingCapacity: true)
                let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    let full = textView.string as NSString
                    var searchRange = NSRange(location: 0, length: full.length)
                    while searchRange.length > 0 {
                        let found = full.range(of: trimmed, options: .caseInsensitive, range: searchRange)
                        guard found.location != NSNotFound else { break }
                        matchRanges.append(found)
                        let nextLoc = found.location + found.length
                        searchRange = NSRange(location: nextLoc, length: full.length - nextLoc)
                    }
                    for range in matchRanges {
                        lm.addTemporaryAttribute(.backgroundColor, value: Theme.nsMark, forCharacterRange: range)
                    }
                }
                let count = matchRanges.count
                DispatchQueue.main.async { [weak self] in
                    self?.onMatchCountChanged?(count)
                }
            }

            if matchRanges.indices.contains(matchIndex) {
                let target = matchRanges[matchIndex]
                textView.scrollRangeToVisible(target)
                textView.showFindIndicator(for: target)
            }
        }

        // MARK: - Scroll jump

        func scrollToTime(_ t: Double) {
            guard let textView else { return }
            guard let anchor = blockAnchors.last(where: { $0.start <= t + 0.5 }) ?? blockAnchors.first else { return }
            textView.scrollRangeToVisible(anchor.range)
        }

        // MARK: - Click & Selection (play word, rename speaker, voice naming)

        func handleClick(at charIndex: Int, shift: Bool) -> Bool {
            // 1. Speaker name or timestamp click
            if let target = clickTargets.first(where: { NSLocationInRange(charIndex, $0.range) }) {
                switch target.kind {
                case .speaker(let id):
                    onRenameSpeaker?(id)
                case .time(let t):
                    onPlayAt?(t)
                }
                return true
            }

            // 2. Word click: seek & play, plus voice naming pick (with Shift-click range)
            if let idx = wordIndex(atCharacter: charIndex) {
                let span = wordSpans[idx]
                onPlayAt?(span.start)
                if shift, let anchor = pickedWordAnchorIndex, wordSpans.indices.contains(anchor),
                   wordSpans[anchor].speaker == span.speaker {
                    let lo = min(anchor, idx)
                    let hi = max(anchor, idx)
                    let start = wordSpans[lo].range.location
                    let end = wordSpans[hi].range.location + wordSpans[hi].range.length
                    setPickedRange(NSRange(location: start, length: end - start))
                    onWordSelectionChanged?(span.speaker, false)
                } else {
                    pickedWordAnchorIndex = idx
                    setPickedRange(span.range)
                    onWordSelectionChanged?(span.speaker, false)
                }
                return true
            }
            return false
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            let selected = textView.selectedRange()
            guard selected.length > 0 else { return }
            // Drag-selecting text lets users both copy AND name a speaker if all words belong to one speaker.
            let overlapping = wordSpans.filter { NSIntersectionRange($0.range, selected).length > 0 }
            guard !overlapping.isEmpty else { return }
            clearPickedRange()
            let speakersInSelection = Set(overlapping.map(\.speaker))
            if speakersInSelection.count == 1, let only = speakersInSelection.first {
                onWordSelectionChanged?(only, false)
            } else {
                onWordSelectionChanged?(nil, true)
            }
        }

        func clearPickedRange() {
            pickedWordAnchorIndex = nil
            if let old = pickedHighlightRange, let lm = textView?.layoutManager {
                lm.removeTemporaryAttribute(.underlineStyle, forCharacterRange: old)
                lm.removeTemporaryAttribute(.underlineColor, forCharacterRange: old)
            }
            pickedHighlightRange = nil
        }

        private func setPickedRange(_ range: NSRange) {
            clearPickedRange()
            pickedHighlightRange = range
            if let lm = textView?.layoutManager {
                lm.addTemporaryAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, forCharacterRange: range)
                lm.addTemporaryAttribute(.underlineColor, value: Theme.nsAccent, forCharacterRange: range)
            }
        }

        private func wordIndex(atCharacter loc: Int) -> Int? {
            var lo = 0
            var hi = wordSpans.count - 1
            while lo <= hi {
                let mid = (lo + hi) / 2
                let r = wordSpans[mid].range
                if loc < r.location {
                    hi = mid - 1
                } else if loc >= r.location + r.length {
                    lo = mid + 1
                } else {
                    return mid
                }
            }
            return nil
        }

        func isInteractive(atCharacter loc: Int) -> Bool {
            clickTargets.contains { NSLocationInRange(loc, $0.range) } || wordIndex(atCharacter: loc) != nil
        }
    }
}

/// Custom `NSTextView` that distinguishes a quick click (play word / rename speaker / shift-pick)
/// from a drag selection (native text selection + copy + multi-word voice naming).
private final class InteractiveTranscriptTextView: NSTextView {
    weak var coordinator: TranscriptRepresentable.Coordinator?
    private var mouseDownPoint: NSPoint?

    override func mouseDown(with event: NSEvent) {
        let down = convert(event.locationInWindow, from: nil)
        let shift = event.modifierFlags.contains(.shift)
        if shift {
            let idx = characterIndexForInsertion(at: down)
            if idx < (string as NSString).length,
               coordinator?.handleClick(at: idx, shift: true) == true {
                return
            }
        }
        mouseDownPoint = down
        super.mouseDown(with: event)
        // `super.mouseDown` runs the drag loop until mouseUp; if it was a plain click (no drag selection),
        // handle word play / speaker rename / timestamp seek.
        guard selectedRange().length == 0, let down = mouseDownPoint else { return }
        let up = convert(event.locationInWindow, from: nil)
        let moved = hypot(up.x - down.x, up.y - down.y)
        guard moved < 4 else { return }
        let idx = characterIndexForInsertion(at: down)
        guard idx < (string as NSString).length else { return }
        _ = coordinator?.handleClick(at: idx, shift: false)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
    }
}
