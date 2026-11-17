import AppKit
import SwiftUI

/// Settings could open "and do nothing": the window came back at its last position, on a
/// different display than the one being used (ReMeet > Settings… from the app menu does not
/// go through `AppModel.openSettings`). Whenever the window becomes key while it sits on
/// another screen than the pointer, it is centered on the pointer's screen. Clicking the
/// window itself never moves it, since the pointer is then on its screen.
struct FollowPointerScreen: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {}

    final class Probe: NSView {
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                                              object: window, queue: .main) { [weak window] _ in
                MainActor.assumeIsolated { window.map(Self.moveToPointerScreen) }
            }
            Self.moveToPointerScreen(window)
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }

        @MainActor
        static func moveToPointerScreen(_ window: NSWindow) {
            let pointer = NSEvent.mouseLocation
            guard let target = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }),
                  window.screen != target else { return }
            let area = target.visibleFrame
            var frame = window.frame
            frame.origin.x = area.midX - frame.width / 2
            frame.origin.y = area.midY - frame.height / 2
            window.setFrame(frame, display: true)
            window.makeKeyAndOrderFront(nil)
        }
    }
}
