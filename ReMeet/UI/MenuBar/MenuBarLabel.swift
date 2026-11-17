import AppKit
import ReMeetKit
import SwiftUI

/// What the menu bar icon shows, most urgent first.
enum MenuBarStatus: Equatable {
    case idle
    case recording(elapsed: TimeInterval)
    case processing(progress: Double?)
    case ready
    case problem
}

/// Always alive (unlike the popover content), so it also registers the window openers.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        content
            .onAppear {
                model.register(openWindow: openWindow, openSettings: openSettings)
                model.showFirstLaunchIfNeeded()
            }
    }

    @ViewBuilder private var content: some View {
        switch model.menuBarStatus {
        case .idle:
            Image(systemName: "waveform")
                .accessibilityLabel("ReMeet")
        case .recording(let elapsed):
            HStack(spacing: 4) {
                Image(nsImage: MenuBarImages.recordingDot)
                Text(TimeFormat.timer(elapsed)).monospacedDigit()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("ReMeet, recording, \(TimeFormat.clock(elapsed))")
        case .processing(let progress):
            HStack(spacing: 3) {
                Image(systemName: "waveform")
                if let progress {
                    Text("\(Int(progress * 100))%").monospacedDigit()
                } else {
                    Image(systemName: "ellipsis")
                }
            }
        case .ready:
            Image(nsImage: MenuBarImages.readyGlyph)
                .accessibilityLabel("ReMeet, summary ready")
        case .problem:
            Image(systemName: "exclamationmark.triangle")
                .accessibilityLabel("ReMeet, needs attention")
        }
    }
}

/// Non-template images so the red dot stays red in the menu bar (template images are tinted).
enum MenuBarImages {
    static let recordingDot: NSImage = {
        let image = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            NSColor(srgbRed: 0xE5 / 255, green: 0x38 / 255, blue: 0x3B / 255, alpha: 1).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }()

    /// The waveform glyph with a small accent dot: a new summary is ready.
    static let readyGlyph: NSImage = {
        let symbol = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Summary ready")!
        let size = NSSize(width: 20, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            let tinted = symbol.withSymbolConfiguration(.init(pointSize: 13, weight: .regular)
                .applying(.init(paletteColors: [.labelColor]))) ?? symbol
            tinted.draw(in: NSRect(x: 0, y: 1, width: 15, height: 14))
            Theme.nsAccent.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.maxX - 6, y: rect.maxY - 6, width: 6, height: 6)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }()
}
