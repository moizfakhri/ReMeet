import AppKit
import ReMeetKit
import SwiftUI

/// Fern colors as appearance-aware SwiftUI colors. Values come from ReMeetKit's Palette,
/// which is unit-tested; this file only adapts them to light and dark.
enum Theme {
    static let bg = dynamic(\.bg)
    static let surface = dynamic(\.surface)
    static let fg = dynamic(\.fg)
    static let fg2 = dynamic(\.fg2)
    static let fg3 = dynamic(\.fg3)
    static let line = dynamic(\.line)
    static let accent = dynamic(\.accent)
    static let mark = dynamic(\.mark)
    static let onAccent = dynamic(\.onAccent)
    /// Solid fills carrying white text: tint for buttons, toggles and selections (5.7:1).
    static let accentFill = dynamic(\.accentFill)
    static let recording = dynamic(\.recording)
    /// Recording-red button fills (Stop), dark enough for white text.
    static let recordingFill = dynamic(\.recordingFill)
    /// Recording caption / error text on surface (AA vs the live-dot red).
    static let recordingLabel = dynamic(\.recordingLabel)

    static let nsAccent = dynamicNS(\.accent)

    private static let light = Palette.light()
    private static let dark = Palette.dark()

    private static func dynamic(_ key: KeyPath<Palette, RGBA>) -> Color {
        Color(nsColor: dynamicNS(key))
    }

    private static func dynamicNS(_ key: KeyPath<Palette, RGBA>) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let c = (isDark ? dark : light)[keyPath: key]
            return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a)
        }
    }
}

enum Fonts {
    static let title = Font.system(size: 30, weight: .semibold, design: .default)
    static let timer = Font.system(size: 30, weight: .medium, design: .monospaced)
    static let mono = Font.system(.body, design: .monospaced)
    static let monoSmall = Font.system(size: 11.5, design: .monospaced)
    static let section = Font.system(size: 15, weight: .semibold)
}

/// The user's appearance choice in Settings > General.
enum AppearanceSetting: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

/// Raycast-style shortcut hint shown next to an action.
struct ShortcutHint: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.fg3)
            .monospacedDigit()
    }
}

extension View {
    /// Grows the clickable area by `inset` on every side without moving anything: a plain
    /// button is otherwise only clickable on its text's tight frame, so a click a few points
    /// off a time stamp or chevron did nothing.
    func hitTarget(_ inset: CGFloat = 4) -> some View {
        padding(inset).contentShape(Rectangle()).padding(-inset)
    }

    /// A sidebar row whose whole highlight is clickable. The row draws its own padding and
    /// zeroes the list's insets, so the area under the highlight and the tap area are one rect
    /// (with the list's default insets, clicks just above or below the text missed).
    func sidebarRow(selected: Bool, action: @escaping () -> Void) -> some View {
        padding(.vertical, 5)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
            .listRowBackground(
                RoundedRectangle(cornerRadius: 8)
                    .fill(selected ? Theme.mark : .clear)
                    .padding(.horizontal, 8))
            .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}
