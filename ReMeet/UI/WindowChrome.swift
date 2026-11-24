import AppKit
import SwiftUI

/// Keeps a SwiftUI window resizable in both directions.
///
/// `NavigationSplitView` (and a hosting view whose `sizingOptions` include the
/// current size) writes `contentMinSize` to whatever the window happens to be.
/// After that the window can grow and then refuses to shrink, and a later layout
/// pass fights the split columns. Pin the real minimum on every resize.
struct WindowChrome: NSViewRepresentable {
    var minSize: CGSize

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PinView {
        let view = PinView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ view: PinView, context: Context) {
        context.coordinator.minSize = minSize
        view.coordinator = context.coordinator
        context.coordinator.apply(to: view.window)
    }

    final class Coordinator: NSObject {
        var minSize = CGSize(width: 760, height: 500)
        private weak var window: NSWindow?

        func attach(_ window: NSWindow?) {
            guard let window else { return }
            if self.window !== window {
                if let old = self.window {
                    NotificationCenter.default.removeObserver(self, name: NSWindow.didResizeNotification, object: old)
                    NotificationCenter.default.removeObserver(self, name: NSWindow.didEndLiveResizeNotification, object: old)
                }
                self.window = window
                NotificationCenter.default.addObserver(self, selector: #selector(windowChanged), name: NSWindow.didResizeNotification, object: window)
                NotificationCenter.default.addObserver(self, selector: #selector(windowChanged), name: NSWindow.didEndLiveResizeNotification, object: window)
            }
            apply(to: window)
        }

        @objc private func windowChanged() { apply(to: window) }

        func apply(to window: NSWindow?) {
            guard let window, window.styleMask.contains(.titled) else { return }
            if !window.styleMask.contains(.resizable) { window.styleMask.insert(.resizable) }
            let min = NSSize(width: minSize.width, height: minSize.height)
            if window.contentMinSize != min {
                window.contentMinSize = min
                let frameMin = window.frameRect(forContentRect: NSRect(origin: .zero, size: min)).size
                var frame = window.frame
                var resized = false
                if frame.width < frameMin.width { frame.size.width = frameMin.width; resized = true }
                if frame.height < frameMin.height { frame.size.height = frameMin.height; resized = true }
                if resized, window.isVisible {
                    DispatchQueue.main.async { [weak window] in
                        guard let window, window.isVisible else { return }
                        window.setFrame(frame, display: true, animate: true)
                    }
                }
            }
            let cap = NSSize(width: 16_000, height: 12_000)
            if window.contentMaxSize.width < 8_000 || window.contentMaxSize.height < 8_000 {
                window.contentMaxSize = cap
            }
        }
    }

    final class PinView: NSView {
        weak var coordinator: Coordinator?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            coordinator?.attach(window)
        }

        override func layout() {
            super.layout()
            coordinator?.apply(to: window)
        }
    }
}
