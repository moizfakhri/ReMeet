import Foundation

/// The Fern theme from the build spec: a few numbers, everything else derived.
/// Neutrals are hue 140 at very low chroma; one green accent at hue 150.
public struct ThemeRecipe: Sendable {
    public var neutralHue: Double
    public var neutralChroma: Double
    public var accentHue: Double
    public var accentChroma: Double
    public var accentLightnessLight: Double
    public var accentLightnessDark: Double
    public var onAccentLight: RGBA
    public var onAccentDark: RGBA

    public static let fern = ThemeRecipe(
        neutralHue: 140, neutralChroma: 0.012,
        accentHue: 150, accentChroma: 0.11,
        accentLightnessLight: 0.50, accentLightnessDark: 0.74,
        onAccentLight: RGBA(hex: 0xFFFFFF), onAccentDark: RGBA(hex: 0x0B0D0C))
}

/// Resolved sRGB colors for one appearance.
public struct Palette: Sendable, Equatable {
    public var bg: RGBA
    public var surface: RGBA
    public var fg: RGBA
    public var fg2: RGBA
    public var fg3: RGBA
    public var line: RGBA
    public var accent: RGBA
    public var mark: RGBA
    public var onAccent: RGBA
    /// Solid fills that carry white text or icons (selected rows, prominent buttons, toggles).
    /// The dark-mode `accent` (L .74) is for text and glyphs on dark surfaces; with white text
    /// on it contrast was 2.2:1, so fills use the L .50 green in both modes (5.7:1).
    public var accentFill: RGBA
    /// Text and icons on `accentFill`.
    public var onAccentFill: RGBA
    /// Recording is always this red, in every theme and appearance (dot, level warnings).
    public var recording: RGBA
    /// Button fills in recording red (Stop): a darker shade so white text reaches 4.5:1.
    public var recordingFill: RGBA
    /// Caption / error text in recording red on surface (darker than the live dot).
    public var recordingLabel: RGBA

    public static let recordingRed = RGBA(hex: 0xE5383B)
    public static let recordingFillRed = OKLCH(0.52, 0.19, 25).srgb

    public static func light(_ t: ThemeRecipe = .fern) -> Palette {
        let h = t.neutralHue, c = t.neutralChroma
        let fg = OKLCH(0.23, c * 1.6, h)
        let accent = OKLCH(t.accentLightnessLight, t.accentChroma, t.accentHue)
        return Palette(
            bg: OKLCH(0.972, c, h).srgb,
            surface: OKLCH(0.995, c * 0.4, h).srgb,
            fg: fg.srgb,
            fg2: OKLCH(0.48, c * 1.6, h).srgb,
            // Spec L .66 measured 3.1:1 on the page; .54 reaches AA (4.5:1) for small hints.
            fg3: OKLCH(0.54, c, h).srgb,
            line: OKLCH(0.25, c * 2, h, alpha: 0.10).srgb,
            accent: accent.srgb,
            mark: accent.srgb.withAlpha(0.13),
            onAccent: t.onAccentLight,
            accentFill: OKLCH(t.accentLightnessLight, t.accentChroma, t.accentHue).srgb,
            onAccentFill: RGBA(hex: 0xFFFFFF),
            recording: recordingRed,
            recordingFill: recordingFillRed,
            // Spec recording red on surface was ~4.2:1; darker for captions on light.
            recordingLabel: OKLCH(0.52, 0.19, 25).srgb)
    }

    public static func dark(_ t: ThemeRecipe = .fern) -> Palette {
        let h = t.neutralHue, c = t.neutralChroma
        let accent = OKLCH(t.accentLightnessDark, t.accentChroma, t.accentHue)
        return Palette(
            bg: OKLCH(0.15, c, h).srgb,
            surface: OKLCH(0.20, c * 1.4, h).srgb,
            fg: OKLCH(0.96, c * 0.6, h).srgb,
            fg2: OKLCH(0.74, c, h).srgb,
            // Spec L .55 measured 3.7:1 on the page; .64 reaches AA (4.5:1) for small hints.
            fg3: OKLCH(0.64, c, h).srgb,
            line: RGBA(r: 1, g: 1, b: 1, a: 0.09),
            accent: accent.srgb,
            mark: accent.srgb.withAlpha(0.17),
            onAccent: t.onAccentDark,
            accentFill: OKLCH(t.accentLightnessLight, t.accentChroma, t.accentHue).srgb,
            onAccentFill: RGBA(hex: 0xFFFFFF),
            recording: recordingRed,
            recordingFill: recordingFillRed,
            // Spec recording red on dark surface was ~4.3:1; lighter for captions on dark.
            recordingLabel: OKLCH(0.68, 0.16, 25).srgb)
    }
}

extension RGBA {
    /// WCAG relative luminance, used to sanity-check text contrast in tests.
    public var relativeLuminance: Double {
        func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    public func contrastRatio(against other: RGBA) -> Double {
        let a = relativeLuminance, b = other.relativeLuminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}
