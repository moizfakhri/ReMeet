import AppKit
import Observation
import ReMeetKit
import SwiftUI

/// State the bubble's SwiftUI content reads and writes.
@MainActor
@Observable
final class BubbleState {
    var expanded = false
    /// The bubble's fixed corner: true when it sits in the right half of its screen. The
    /// glass is pinned to this corner so resizing the window never moves it on screen.
    var anchorTrailing = true
    /// Seconds left before the recording stops because the call ended, nil otherwise.
    var callEndCountdown: Int?
    var draft = ""
    /// Seconds from recording start when the field was opened; this becomes the note's `t`.
    var openedAt: Double = 0
    var focusRequest = 0
}

/// The floating note bubble: a non-activating panel over every Space (full-screen calls
/// included). Collapsed it is the recording pill; expanded it is the note field. It only
/// becomes key while the field is open, and hands focus back to the app that had it.
@MainActor
final class BubbleController: NSObject, NSWindowDelegate {
    /// Clear space around the glass card inside the window. The glass draws a soft shadow;
    /// with only 4 pt the window edge cut it off into a grey rectangle below the card.
    static let margin: CGFloat = 24
    /// The visible cards (pill and note field); the window is a card plus `margin` all round.
    static let pillCard = CGSize(width: 272, height: 40)
    static let noteCard = CGSize(width: 352, height: 206)
    static let collapsedSize = CGSize(width: pillCard.width + 2 * margin, height: pillCard.height + 2 * margin)
    static let expandedSize = CGSize(width: noteCard.width + 2 * margin, height: noteCard.height + 2 * margin)
    private static let frameKey = "bubbleFrame"

    let state = BubbleState()
    private let recorder: RecorderService
    /// Where finished notes go (the recorder's notes.json in the app).
    var onNote: ((MeetingNote) -> Void)?
    /// Seconds since recording start, or nil when not recording.
    var timestamp: () -> Double?
    var isHiddenBySetting: () -> Bool = { !UserDefaults.standard.bool(forKey: SettingsKey.showBubble) }
    var isRecordingActive: () -> Bool
    /// This recording's hide, separate from the Settings toggle.
    private var manuallyHidden = false
    /// Show the pill for this recording even when Settings has it off.
    private var sessionShown = false
    private var screenSharing = false
    private var broughtBackDuringShare = false
    private var shareWatch: Task<Void, Never>?

    private var panel: BubblePanel?
    private var previousApp: NSRunningApplication?
    static let morph = Animation.smooth(duration: 0.3)

    init(recorder: RecorderService) {
        self.recorder = recorder
        timestamp = { [weak recorder] in recorder?.noteTimestamp() }
        isRecordingActive = { [weak recorder] in recorder?.isRecording ?? false }
        super.init()
        onNote = { [weak recorder] in recorder?.addNote($0) }
    }

    var isVisible: Bool { panel?.isVisible ?? false }
    var panelForTesting: NSPanel? { panel }

    /// Recording started: show the pill unless hidden in Settings.
    func recordingStarted() {
        manuallyHidden = false
        sessionShown = false
        screenSharing = false
        broughtBackDuringShare = false
        state.expanded = false
        state.draft = ""
        refreshPill()
    }

    /// Hide the pill for this recording. The window goes away; it is not marked invisible
    /// to screen capture.
    func hidePill() {
        hoverWork?.cancel()
        manuallyHidden = true
        sessionShown = false
        broughtBackDuringShare = false
        state.expanded = false
        panel?.orderOut(nil)
    }

    /// Bring the pill back, including during a detected screen share.
    func showPill() {
        manuallyHidden = false
        sessionShown = true
        if screenSharing { broughtBackDuringShare = true }
        refreshPill()
    }

    func noteScreenShare(_ sharing: Bool) {
        if !sharing { broughtBackDuringShare = false }
        screenSharing = sharing
        guard !state.expanded else { return }
        refreshPill()
    }

    /// Polls while a recording is running. Self-tests call `recordingStarted` without this.
    func startShareWatch() {
        guard shareWatch == nil else { return }
        shareWatch = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, self.isRecordingActive() {
                self.noteScreenShare(ScreenShareMonitor.isSharing)
                try? await Task.sleep(for: .milliseconds(1500))
            }
            self?.shareWatch = nil
        }
    }

    private func refreshPill() {
        let shouldShow = RecordingPill.visible(
            recording: isRecordingActive(),
            settingAllows: !isHiddenBySetting(),
            manuallyHidden: manuallyHidden,
            sessionShown: sessionShown,
            screenSharing: screenSharing,
            broughtBackDuringShare: broughtBackDuringShare,
            callEnding: state.callEndCountdown != nil)
        if shouldShow {
            if !state.expanded { show(expanded: false) }
        } else if !state.expanded {
            panel?.orderOut(nil)
        }
    }

    /// Recording stopped: put any typed text in as a note, then go away.
    func recordingStopped() {
        if state.expanded, !state.draft.trimmingCharacters(in: .whitespaces).isEmpty {
            submit(command: false)
        }
        state.expanded = false
        panel?.orderOut(nil)
    }

    /// ⌥⌘N, the menu bar Note button, a click on the pill, or a hover that rests on it.
    func openNoteField() {
        hoverWork?.cancel()
        // Silent no-op when idle: a system beep is loud and easy to mistake for an
        // app glitch (⌥⌘N outside a recording has nothing to attach a note to).
        guard let t = timestamp() else { return }
        if !state.expanded {
            let front = NSWorkspace.shared.frontmostApplication
            previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
            state.openedAt = t
            state.draft = ""
        }
        show(expanded: true)
        focusField()
    }

    /// How long the pointer has to rest before the note field opens. Hide stays clickable
    /// during this wait. A shorter hover does nothing.
    static let hoverOpenDelay: TimeInterval = 1.75

    /// Pointer entered or left the floating bar. A resting hover opens the note field
    /// and focuses it, so typing does not take a click. Leaving with an empty draft
    /// closes the field; a draft stays up.
    func pointerHover(_ inside: Bool) {
        hoverWork?.cancel()
        if inside {
            guard !state.expanded, isRecordingActive(), timestamp() != nil, panel?.isVisible == true else { return }
            guard NSEvent.pressedMouseButtons == 0 else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.state.expanded, self.panel?.isVisible == true,
                      NSEvent.pressedMouseButtons == 0 else { return }
                self.openNoteField()
            }
            hoverWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverOpenDelay, execute: work)
        } else if state.expanded {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.state.expanded,
                      self.state.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                self.cancel()
            }
            hoverWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
        }
    }

    private var hoverWork: DispatchWorkItem?

    private func focusField() {
        panel?.makeKey()
        state.focusRequest += 1
        // The text field is created in the same turn as makeKey. Focusing again on the
        // next turn is what actually makes it first responder in a non-activating panel.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.state.expanded else { return }
            self.panel?.makeKey()
            self.state.focusRequest += 1
        }
    }

    /// Return (note or, if empty, bookmark) or Command-Return (action item).
    func submit(command: Bool) {
        let note = NoteTiming.resolve(text: state.draft, command: command, t: state.openedAt)
        onNote?(note)
        state.draft = ""
        collapse()
    }

    /// Escape: close the field without saving.
    func cancel() {
        state.draft = ""
        collapse()
    }

    /// The call ended: show the countdown in the pill when it is allowed on screen.
    /// A manual hide or a detected screen share keeps it hidden; the menu bar still
    /// offers Keep recording. Nil clears the countdown.
    func callEndCountdown(_ seconds: Int?) {
        state.callEndCountdown = seconds
        guard !state.expanded else { return }
        refreshPill()
    }

    func keepRecording() {
        AppModel.shared.keepRecordingAfterCallEnd()
    }

    func stopRecording() {
        recorder.stop()
    }

    // MARK: - Panel

    private func collapse() {
        hoverWork?.cancel()
        let shouldShow = RecordingPill.visible(
            recording: isRecordingActive(),
            settingAllows: !isHiddenBySetting(),
            manuallyHidden: manuallyHidden,
            sessionShown: sessionShown,
            screenSharing: screenSharing,
            broughtBackDuringShare: broughtBackDuringShare,
            callEnding: state.callEndCountdown != nil)
        if !shouldShow {
            state.expanded = false
            panel?.orderOut(nil)
        } else {
            // Shrink the glass inside the big window first, then the window: shrinking the
            // window first cut the note field off mid-morph.
            withAnimation(Self.morph) {
                state.expanded = false
            } completion: { [weak self] in
                guard let self, !self.state.expanded else { return }
                self.resize(to: Self.collapsedSize)
            }
        }
        panel?.resignKey()
        previousApp?.activate()
        previousApp = nil
    }

    private func show(expanded: Bool) {
        let panel = self.panel ?? makePanel()
        guard expanded else {
            state.expanded = false
            resize(to: Self.collapsedSize)
            panel.orderFrontRegardless()
            return
        }
        if !state.expanded {
            // Grow the window first and lay it out with the pill still pinned to its corner,
            // then morph. Doing both in one pass animated the glass from the pill's old
            // window coordinates, so it flew in from the wrong side.
            if panel.frame.size == Self.collapsedSize {
                let screen = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
                state.anchorTrailing = BubbleGeometry.anchorsRight(panel.frame, on: screen)
            }
            resize(to: Self.expandedSize)
            panel.contentView?.layoutSubtreeIfNeeded()
            withAnimation(Self.morph) { state.expanded = true }
        }
        panel.orderFrontRegardless()
    }

    private func resize(to size: CGSize) {
        guard let panel, panel.frame.size != size else { return }
        let frame = BubbleGeometry.resize(panel.frame, to: size, anchorRight: state.anchorTrailing)
        panel.setFrame(frame, display: true, animate: false)
    }

    private func makePanel() -> BubblePanel {
        let visible = NSScreen.screens.map(\.visibleFrame)
        // The card sits 16 pt from the screen corner; the window's clear margin may run past it.
        var frame = BubbleGeometry.defaultFrame(size: Self.collapsedSize,
                                                visibleFrame: NSScreen.main?.visibleFrame ?? .zero,
                                                margin: 16 - Self.margin)
        if let saved = UserDefaults.standard.string(forKey: Self.frameKey) {
            var restored = NSRectFromString(saved)
            // A frame saved by a build with a different margin: keep the card where it was.
            restored = restored.insetBy(dx: (restored.width - Self.collapsedSize.width) / 2,
                                        dy: (restored.height - Self.collapsedSize.height) / 2)
            if restored.width > 0 { frame = BubbleGeometry.clamp(restored, to: visible, margin: 8 - Self.margin) }
        }
        let screen = NSScreen.screens.first { $0.visibleFrame.intersects(frame) }?.visibleFrame
            ?? NSScreen.main?.visibleFrame ?? .zero
        state.anchorTrailing = BubbleGeometry.anchorsRight(frame, on: screen)
        let panel = BubblePanel(contentRect: frame)
        let root = BubbleView(controller: self, state: state)
            .environment(AppModel.shared)
            .tint(Theme.accentFill)
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        panel.contentView = hosting
        panel.onHover = { [weak self] inside in self?.pointerHover(inside) }
        panel.delegate = self
        self.panel = panel
        panel.installHoverTracking()
        return panel
    }

    nonisolated func windowDidMove(_ notification: Notification) {
        MainActor.assumeIsolated {
            // Only the pill's own frame is remembered, not the note field or a frame mid-morph.
            guard let panel, !state.expanded, panel.frame.size == Self.collapsedSize else { return }
            UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: Self.frameKey)
        }
    }
}

/// Borderless, transparent, non-activating: typing in it never brings ReMeet to the front.
final class BubblePanel: NSPanel {
    init(contentRect: CGRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        acceptsMouseMovedEvents = true
    }

    var onHover: ((Bool) -> Void)?
    private var hoverTracking: NSTrackingArea?

    func installHoverTracking() {
        guard let content = contentView else { return }
        if let hoverTracking { content.removeTrackingArea(hoverTracking) }
        // Only the card counts as hovering, not the clear margin around it.
        let area = NSTrackingArea(rect: content.bounds.insetBy(dx: BubbleController.margin - 4, dy: BubbleController.margin - 4),
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        content.addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
