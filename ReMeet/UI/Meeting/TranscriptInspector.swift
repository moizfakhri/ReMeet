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
    @State private var assignTarget: SpeakerAssignTarget?
    @FocusState private var findFocused: Bool
    @State private var selectedSpeaker: String?
    @State private var selectedSegmentIndices = IndexSet()
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
                    onClickSpeaker: { speakerID, indices in
                        let stored = document.speakers.names[speakerID] ?? ""
                        let hasRealName = !SpeakerMemory.isPlaceholder(stored)
                        let scope: SpeakerAssignTarget.Scope = (speakerID == SpeakerNames.youID || hasRealName) ? .thisTurn : .allTurns
                        assignTarget = SpeakerAssignTarget(speakerID: speakerID, segmentIndices: IndexSet(indices), scope: scope)
                    },
                    onWordSelectionChanged: { speakerID, indices, mixed in
                        selectedSpeaker = speakerID
                        selectedSegmentIndices = indices
                        selectionHasMixedSpeakers = mixed
                        if let speakerID {
                            let stored = document.speakers.names[speakerID] ?? ""
                            voiceName = SpeakerMemory.isPlaceholder(stored) ? "" : stored
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
            selectedSegmentIndices = IndexSet()
            selectionHasMixedSpeakers = false
            voiceName = ""
            voiceNotice = nil
            assignTarget = nil
            matchIndex = 0
        }
        .onChange(of: query) { _, _ in
            matchIndex = 0
        }
        .sheet(item: $assignTarget) { target in
            if let document {
                SpeakerAssignSheet(
                    document: document,
                    target: target,
                    onDone: { message in
                        voiceNotice = message
                        selectedSpeaker = nil
                        selectedSegmentIndices = IndexSet()
                        selectionHasMixedSpeakers = false
                        clearSelectionToken += 1
                    }
                )
                .environment(model)
            }
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
                    .frame(minWidth: 80, maxWidth: 150)
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
                Button {
                    openFind()
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.fg2)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Find in transcript (⌘F)")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var voiceNaming: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let speaker = selectedSpeaker, let document {
                HStack(spacing: 6) {
                    TextField("Name or split turn", text: $voiceName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { saveVoice(speaker) }
                    Button("All turns") { saveVoice(speaker) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .help("Rename \(document.speakers.displayName(for: speaker)) across the whole meeting and save voiceprint")
                    if !selectedSegmentIndices.isEmpty {
                        Button("This turn") { splitSelectedTurn(from: speaker) }
                            .buttonStyle(.plain)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Theme.fg)
                            .help("Reassign or split out only the selected turn to this person")
                    }
                    Button("Pick…") {
                        let stored = document.speakers.names[speaker] ?? ""
                        let hasName = !SpeakerMemory.isPlaceholder(stored)
                        assignTarget = SpeakerAssignTarget(
                            speakerID: speaker,
                            segmentIndices: selectedSegmentIndices,
                            scope: (speaker == SpeakerNames.youID || hasName) ? .thisTurn : .allTurns
                        )
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.fg2)
                    .help("Pick from meeting speakers, calendar invitees, or People")
                    Button {
                        selectedSpeaker = nil
                        selectedSegmentIndices = IndexSet()
                        selectionHasMixedSpeakers = false
                        clearSelectionToken += 1
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.fg3)
                    }
                    .buttonStyle(.plain)
                    .help("Clear selection")
                }
            } else if selectionHasMixedSpeakers, !selectedSegmentIndices.isEmpty, document != nil {
                HStack(spacing: 8) {
                    Text("\(selectedSegmentIndices.count) turns selected")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.fg2)
                    Spacer()
                    Button("Assign to person…") {
                        assignTarget = SpeakerAssignTarget(
                            speakerID: "",
                            segmentIndices: selectedSegmentIndices,
                            scope: .thisTurn
                        )
                    }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    Button("Clear") {
                        selectedSpeaker = nil
                        selectedSegmentIndices = IndexSet()
                        selectionHasMixedSpeakers = false
                        clearSelectionToken += 1
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(Theme.fg2)
                }
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
        selectedSegmentIndices = IndexSet()
        selectionHasMixedSpeakers = false
        clearSelectionToken += 1
        Task { _ = await model.scheduleSpeakerWording(document) }
    }

    private func splitSelectedTurn(from speaker: String) {
        let name = voiceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !selectedSegmentIndices.isEmpty, let document else { return }
        if let existingID = document.callSpeakers.first(where: {
            document.speakers.displayName(for: $0).caseInsensitiveCompare(name) == .orderedSame
        }), existingID != speaker {
            document.reassignSegments(at: selectedSegmentIndices, toSpeakerID: existingID)
            voiceNotice = "Moved turn to \(document.speakers.displayName(for: existingID))."
        } else {
            document.splitSegmentsToNewSpeaker(at: selectedSegmentIndices, named: name)
            voiceNotice = "Split turn to \(name)."
        }
        model.library.refresh(document.folder)
        model.documentEdited(document, reindexSearch: true)
        selectedSpeaker = nil
        selectedSegmentIndices = IndexSet()
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
    let onClickSpeaker: (String, [Int]) -> Void
    let onWordSelectionChanged: (String?, IndexSet, Bool) -> Void

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
            onClickSpeaker: onClickSpeaker,
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
    let onClickSpeaker: (String, [Int]) -> Void
    let onWordSelectionChanged: (String?, IndexSet, Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WidthTrackingScrollView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 320, height: 400))
    }

    func makeNSView(context: Context) -> WidthTrackingScrollView {
        let scroll = WidthTrackingScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(containerSize: NSSize(width: 300, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)

        let textView = InteractiveTranscriptTextView(frame: .zero, textContainer: textContainer)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 14, height: 12)
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

    func updateNSView(_ scroll: WidthTrackingScrollView, context: Context) {
        let c = context.coordinator
        c.onPlayAt = onPlayAt
        c.onClickSpeaker = onClickSpeaker
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

        scroll.syncDocumentWidth()
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
            var segmentIndex: Int
        }

        struct BlockAnchor {
            var start: Double
            var range: NSRange
        }

        struct ClickTarget {
            enum Kind {
                case speaker(String, [Int])
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
        var onClickSpeaker: ((String, [Int]) -> Void)?
        var onWordSelectionChanged: ((String?, IndexSet, Bool) -> Void)?
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
            var segIndex = 0
            for item in Stitcher.interleave(transcript.segments, notes: notes) {
                switch item {
                case .note(let note):
                    blocks.append((note.t, .note(note)))
                case .segment(let s):
                    let indexed = (index: segIndex, segment: s)
                    segIndex += 1
                    if let last = blocks.last, case .speech(let sp, var segs) = last.kind, sp == s.speaker {
                        segs.append(indexed)
                        blocks[blocks.count - 1].kind = .speech(speaker: sp, segments: segs)
                    } else {
                        blocks.append((s.start, .speech(speaker: s.speaker, segments: [indexed])))
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

                case .speech(let speaker, let indexedSegments):
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
                        kind: .speaker(speaker, indexedSegments.map(\.index))))

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
                    for (segmentIndex, segment) in indexedSegments {
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
                                speaker: speaker,
                                segmentIndex: segmentIndex))
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
            case speech(speaker: String, segments: [(index: Int, segment: TranscriptSegment)])
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
                case .speaker(let id, let indices):
                    onClickSpeaker?(id, indices)
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
                    let indices = IndexSet(wordSpans[lo...hi].map(\.segmentIndex))
                    setPickedRange(NSRange(location: start, length: end - start))
                    onWordSelectionChanged?(span.speaker, indices, false)
                } else {
                    pickedWordAnchorIndex = idx
                    setPickedRange(span.range)
                    onWordSelectionChanged?(span.speaker, IndexSet([span.segmentIndex]), false)
                }
                return true
            }
            return false
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            let selected = textView.selectedRange()
            guard selected.length > 0 else { return }
            // Drag-selecting text lets users both copy AND name/split a speaker turn.
            let overlapping = wordSpans.filter { NSIntersectionRange($0.range, selected).length > 0 }
            guard !overlapping.isEmpty else { return }
            clearPickedRange()
            let indices = IndexSet(overlapping.map(\.segmentIndex))
            let speakersInSelection = Set(overlapping.map(\.speaker))
            if speakersInSelection.count == 1, let only = speakersInSelection.first {
                onWordSelectionChanged?(only, indices, false)
            } else {
                onWordSelectionChanged?(nil, indices, true)
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

// MARK: - Turn & Speaker Assignment Sheet

private struct SpeakerAssignTarget: Identifiable, Equatable {
    enum Scope: String, CaseIterable, Identifiable {
        case thisTurn = "This turn"
        case allTurns = "All turns"
        var id: String { rawValue }
    }

    let id = UUID()
    let speakerID: String
    let segmentIndices: IndexSet
    var scope: Scope
}

private struct SpeakerAssignSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let document: MeetingDocument
    let target: SpeakerAssignTarget
    let onDone: (String) -> Void

    @State private var scope: SpeakerAssignTarget.Scope
    @State private var nameInput = ""

    init(document: MeetingDocument, target: SpeakerAssignTarget, onDone: @escaping (String) -> Void) {
        self.document = document
        self.target = target
        self.onDone = onDone
        _scope = State(initialValue: target.speakerID.isEmpty ? .thisTurn : target.scope)
        if target.scope == .allTurns, !target.speakerID.isEmpty {
            let stored = document.speakers.names[target.speakerID] ?? ""
            _nameInput = State(initialValue: SpeakerMemory.isPlaceholder(stored) ? "" : stored)
        }
    }

    private var currentLabel: String {
        target.speakerID.isEmpty ? "Selected turns" : document.speakers.displayName(for: target.speakerID)
    }

    private var canEditAllTurns: Bool {
        !target.speakerID.isEmpty && target.speakerID != SpeakerNames.youID
    }

    private var invitees: [String] {
        let q = nameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let store = PeopleStore(profiles: model.hub.people.map(\.profile))
        var seen: [String] = []
        for att in document.meta.calendarAttendees where att.status != .declined {
            let raw = att.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !SpeakerMemory.isPlaceholder(raw) else { continue }
            let resolved = store.find(named: raw, email: att.email)?.name
                ?? PersonName.parse(raw).canonicalDisplayName
            guard !SpeakerMemory.isPlaceholder(resolved),
                  !SpeakerMemory.namesMatch(resolved, AppModel.recorderName) else { continue }
            if !seen.contains(where: { SpeakerMemory.namesMatch($0, resolved) }) {
                seen.append(resolved)
            }
        }
        return seen.filter { q.isEmpty || $0.localizedCaseInsensitiveContains(q) }
    }

    private var filteredPeople: [PersonSummary] {
        let q = nameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.hub.people.filter { p in
            !invitees.contains(where: { SpeakerMemory.namesMatch($0, p.profile.name) })
                && (q.isEmpty || p.profile.name.localizedCaseInsensitiveContains(q))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(scope == .thisTurn ? "Assign \(currentLabel)" : "Rename \(currentLabel)")
                    .font(.headline)
                Spacer()
                if canEditAllTurns && !target.segmentIndices.isEmpty {
                    Picker("Scope", selection: $scope) {
                        ForEach(SpeakerAssignTarget.Scope.allCases) { s in
                            Text(s.rawValue).tag(s)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 175)
                }
            }

            HStack(spacing: 8) {
                TextField(scope == .thisTurn ? "Type or search a person to assign…" : "Type name for all turns…", text: $nameInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { applyTypedName() }
                AccentCapsuleButton(
                    title: scope == .thisTurn ? "Assign" : "Save",
                    small: true
                ) {
                    applyTypedName()
                }
                .disabled(nameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    // Other speakers already in this recording (You + call speakers)
                    let otherIDs = ([SpeakerNames.youID] + document.callSpeakers).filter { $0 != target.speakerID }
                    if !otherIDs.isEmpty {
                        Text("In this recording")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.fg3)
                        WrappingFlowLayout(spacing: 6, lineSpacing: 6) {
                            ForEach(otherIDs, id: \.self) { id in
                                let label = id == SpeakerNames.youID
                                    ? "You (\(AppModel.recorderName))"
                                    : document.speakers.displayName(for: id)
                                Button {
                                    assignToExistingSpeaker(id: id)
                                } label: {
                                    HStack(spacing: 5) {
                                        if id != SpeakerNames.youID {
                                            PersonAvatarView(name: label, size: 16)
                                        }
                                        Text(label)
                                            .font(.system(size: 12, weight: .medium))
                                    }
                                    .foregroundStyle(Theme.fg)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 4)
                                    .background(Theme.mark.opacity(0.65), in: Capsule())
                                    .overlay(Capsule().stroke(Theme.accent.opacity(0.25)))
                                }
                                .buttonStyle(.plain)
                                .help(scope == .thisTurn
                                      ? "Move this turn to \(label)"
                                      : "Merge all \(currentLabel) turns into \(label)")
                            }
                        }
                    }

                    if !invitees.isEmpty {
                        Text("Calendar invite")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.fg3)
                            .padding(.top, 2)
                        WrappingFlowLayout(spacing: 6, lineSpacing: 6) {
                            ForEach(invitees, id: \.self) { personName in
                                personPickChip(name: personName, badge: "calendar")
                            }
                        }
                    }

                    if !filteredPeople.isEmpty {
                        Text("People")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.fg3)
                            .padding(.top, 2)
                        WrappingFlowLayout(spacing: 6, lineSpacing: 6) {
                            ForEach(filteredPeople.prefix(16)) { person in
                                personPickChip(name: person.profile.name,
                                               badge: person.hasVoiceprint ? "waveform" : nil)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 200)

            HStack {
                if scope == .allTurns,
                   !target.speakerID.isEmpty,
                   !SpeakerMemory.isPlaceholder(document.speakers.names[target.speakerID] ?? "") {
                    Button("Clear name & unlearn voice", role: .destructive) {
                        document.clearSpeakerName(target.speakerID)
                        finish(with: "Cleared \(currentLabel).")
                    }
                    .controlSize(.small)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 410)
    }

    private func personPickChip(name: String, badge: String?) -> some View {
        Button {
            nameInput = name
            applyTypedName()
        } label: {
            HStack(spacing: 5) {
                PersonAvatarView(name: name, size: 16)
                Text(name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                if let badge {
                    Image(systemName: badge)
                        .font(.system(size: 9.5))
                        .foregroundStyle(Theme.accent)
                }
            }
            .foregroundStyle(Theme.fg)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Theme.bg, in: Capsule())
            .overlay(Capsule().stroke(Theme.line))
        }
        .buttonStyle(.plain)
    }

    private func assignToExistingSpeaker(id existingID: String) {
        let label = existingID == SpeakerNames.youID ? "You" : document.speakers.displayName(for: existingID)
        if scope == .thisTurn, !target.segmentIndices.isEmpty {
            document.reassignSegments(at: target.segmentIndices, toSpeakerID: existingID)
            finish(with: "Moved turn to \(label).")
        } else if !target.speakerID.isEmpty {
            document.mergeSpeakers(from: target.speakerID, into: existingID)
            finish(with: "Merged into \(label).")
        }
    }

    private func applyTypedName() {
        let trimmed = nameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if scope == .allTurns, canEditAllTurns {
            document.renameSpeaker(target.speakerID, to: trimmed)
            finish(with: "Renamed to \(trimmed).")
        } else if !target.segmentIndices.isEmpty {
            if trimmed.caseInsensitiveCompare("You") == .orderedSame
                || (!AppModel.recorderName.isEmpty && trimmed.caseInsensitiveCompare(AppModel.recorderName) == .orderedSame) {
                document.reassignSegments(at: target.segmentIndices, toSpeakerID: SpeakerNames.youID)
                finish(with: "Moved turn to You.")
            } else if let existingID = document.callSpeakers.first(where: {
                document.speakers.displayName(for: $0).caseInsensitiveCompare(trimmed) == .orderedSame
            }) {
                document.reassignSegments(at: target.segmentIndices, toSpeakerID: existingID)
                finish(with: "Moved turn to \(document.speakers.displayName(for: existingID)).")
            } else {
                document.splitSegmentsToNewSpeaker(at: target.segmentIndices, named: trimmed)
                finish(with: "Split turn as \(trimmed).")
            }
        }
    }

    private func finish(with message: String) {
        model.library.refresh(document.folder)
        model.documentEdited(document, reindexSearch: true)
        onDone(message)
        dismiss()
        Task { _ = await model.scheduleSpeakerWording(document) }
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

/// Ensures `NSTextContainer` and `NSTextView` width track the actual viewport width whenever
/// the inspector pane resizes, eliminating horizontal clipping at narrow inspector widths.
private final class WidthTrackingScrollView: NSScrollView {
    private var lastSyncedWidth: CGFloat = 0

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func layout() {
        super.layout()
        syncDocumentWidth()
    }

    func syncDocumentWidth() {
        guard let textView = documentView as? NSTextView else { return }
        let width = contentSize.width
        guard width > 20, abs(width - lastSyncedWidth) > 0.5 else { return }
        lastSyncedWidth = width
        if abs(textView.frame.width - width) > 0.5 {
            var frame = textView.frame
            frame.size.width = width
            textView.frame = frame
        }
        if let container = textView.textContainer {
            let targetWidth = max(40, width - 2 * textView.textContainerInset.width)
            if abs(container.containerSize.width - targetWidth) > 0.5 {
                container.containerSize = NSSize(width: targetWidth, height: .greatestFiniteMagnitude)
                DispatchQueue.main.async { [weak textView] in
                    guard let textView, let container = textView.textContainer else { return }
                    textView.layoutManager?.ensureLayout(for: container)
                    textView.needsDisplay = true
                }
            }
        }
    }
}
