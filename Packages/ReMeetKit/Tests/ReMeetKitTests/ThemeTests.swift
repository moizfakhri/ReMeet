import Testing
@testable import ReMeetKit

struct ThemeTests {
    @Test func oklchAnchors() {
        #expect(OKLCH(1, 0, 0).srgb.hexString == "#ffffff")
        #expect(OKLCH(0, 0, 0).srgb.hexString == "#000000")
        // sRGB red is OKLCH(0.62796 0.25768 29.23) (Ottosson's reference values).
        let red = OKLCH(0.62796, 0.25768, 29.2339).srgb
        #expect(abs(red.r - 1) < 0.002 && red.g < 0.002 && red.b < 0.002)
    }

    @Test func roundTrip() {
        for hex: UInt32 in [0x3A7D44, 0xE5383B, 0x0B0D0C, 0xF4F7F2, 0x8899AA] {
            let rgb = RGBA(hex: hex)
            let back = OKLCH.from(srgb: rgb).srgb
            #expect(back.hexString == rgb.hexString, "\(rgb.hexString) -> \(back.hexString)")
        }
    }

    @Test func fernAccentIsGreen() {
        for accent in [Palette.light().accent, Palette.dark().accent] {
            #expect(accent.g > accent.r && accent.g > accent.b)
            let hue = OKLCH.from(srgb: accent).h
            // Gamut clamping can shift hue slightly; it must stay near 150.
            #expect(abs(hue - 150) < 3, "hue \(hue)")
        }
    }

    /// Values cross-checked against the CSS Color 4 reference conversion, so an accidental change to the recipe or the math shows up.
    @Test func fernSnapshot() {
        let light = Palette.light(), dark = Palette.dark()
        #expect(light.accent.hexString == "#2b7440")
        #expect(dark.accent.hexString == "#76be86")
        #expect(light.bg.hexString == "#f2f8f0")
        #expect(dark.bg.hexString == "#090c08")
    }

    @Test func textContrast() {
        let light = Palette.light(), dark = Palette.dark()
        #expect(light.fg.contrastRatio(against: light.surface) > 12)
        #expect(dark.fg.contrastRatio(against: dark.surface) > 12)
        #expect(light.fg2.contrastRatio(against: light.surface) > 4.5)
        #expect(dark.fg2.contrastRatio(against: dark.surface) > 4.5)
        // White on the light accent and near-black on the dark accent (primary button text).
        #expect(light.onAccent.contrastRatio(against: light.accent) > 4.5)
        #expect(dark.onAccent.contrastRatio(against: dark.accent) > 4.5)
        #expect(light.mark.a == 0.13 && dark.mark.a == 0.17)
        #expect(light.recording == dark.recording)
    }

    /// WCAG AA everywhere text or icons sit on a Fern color (4.5:1 body text, 3:1 graphics).
    /// Regression: white on the light-green selection in dark mode was 2.2:1.
    @Test func wcagContrastPairs() {
        func over(_ c: RGBA, _ b: RGBA) -> RGBA {
            RGBA(r: c.r * c.a + b.r * (1 - c.a), g: c.g * c.a + b.g * (1 - c.a), b: c.b * c.a + b.b * (1 - c.a))
        }
        for (name, p) in [("light", Palette.light()), ("dark", Palette.dark())] {
            let pairs: [(String, RGBA, RGBA, Double)] = [
                ("white text on accent fill", p.onAccentFill, p.accentFill, 4.5),
                ("white text on recording fill", RGBA(hex: 0xFFFFFF), p.recordingFill, 4.5),
                ("on-accent text on accent", p.onAccent, p.accent, 4.5),
                ("accent text on surface", p.accent, p.surface, 4.5),
                ("accent text on mark", p.accent, over(p.mark, p.surface), 4.5),
                ("fg on mark", p.fg, over(p.mark, p.surface), 4.5),
                ("fg2 on mark", p.fg2, over(p.mark, p.surface), 4.5),
                ("fg2 on surface", p.fg2, p.surface, 4.5),
                ("fg3 hints on surface", p.fg3, p.surface, 4.5),
                ("fg3 hints on bg", p.fg3, p.bg, 4.5),
                ("recording label on surface", p.recordingLabel, p.surface, 4.5),
                ("level bars on surface", p.accent, p.surface, 3.0),
                ("white stop icon on recording red", RGBA(hex: 0xFFFFFF), p.recording, 3.0),
                ("white stop icon on recording fill", RGBA(hex: 0xFFFFFF), p.recordingFill, 4.5),
            ]
            for (label, text, background, minimum) in pairs {
                let ratio = text.contrastRatio(against: background)
                #expect(ratio >= minimum, "\(name): \(label) is \(String(format: "%.2f", ratio)):1, needs \(minimum)")
            }
        }
    }
}
