import Foundation

/// A color in OKLCH (perceptual lightness, chroma, hue in degrees), the space the Fern
/// theme is specified in. Converted to sRGB once; SwiftUI only ever sees sRGB.
public struct OKLCH: Sendable, Equatable {
    public var l: Double
    public var c: Double
    public var h: Double
    public var alpha: Double

    public init(_ l: Double, _ c: Double, _ h: Double, alpha: Double = 1) {
        self.l = l
        self.c = c
        self.h = h
        self.alpha = alpha
    }

    /// Gamma-encoded sRGB components, clamped to 0...1.
    public var srgb: RGBA {
        let hr = h * .pi / 180
        let a = c * cos(hr)
        let b = c * sin(hr)

        // OKLab -> LMS (cube roots) -> linear sRGB, Björn Ottosson's reference matrices.
        let l_ = l + 0.3963377774 * a + 0.2158037573 * b
        let m_ = l - 0.1055613458 * a - 0.0638541728 * b
        let s_ = l - 0.0894841775 * a - 1.2914855480 * b
        let ll = l_ * l_ * l_
        let mm = m_ * m_ * m_
        let ss = s_ * s_ * s_

        let r = 4.0767416621 * ll - 3.3077115913 * mm + 0.2309699292 * ss
        let g = -1.2684380046 * ll + 2.6097574011 * mm - 0.3413193965 * ss
        let bl = -0.0041960863 * ll - 0.7034186147 * mm + 1.7076147010 * ss
        return RGBA(r: Self.encode(r), g: Self.encode(g), b: Self.encode(bl), a: alpha)
    }

    private static func encode(_ x: Double) -> Double {
        let v = x <= 0.0031308 ? 12.92 * x : 1.055 * pow(max(x, 0), 1 / 2.4) - 0.055
        return min(max(v, 0), 1)
    }

    /// sRGB -> OKLCH, used by tests to check round trips against known values.
    public static func from(srgb: RGBA) -> OKLCH {
        func decode(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let r = decode(srgb.r), g = decode(srgb.g), b = decode(srgb.b)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        let L = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        let A = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        let B = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        var hue = atan2(B, A) * 180 / .pi
        if hue < 0 { hue += 360 }
        return OKLCH(L, (A * A + B * B).squareRoot(), hue, alpha: srgb.a)
    }
}

public struct RGBA: Sendable, Equatable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    public init(hex: UInt32, alpha: Double = 1) {
        self.init(r: Double((hex >> 16) & 0xFF) / 255, g: Double((hex >> 8) & 0xFF) / 255,
                  b: Double(hex & 0xFF) / 255, a: alpha)
    }

    public var hexString: String {
        let parts = [r, g, b].map { Int(($0 * 255).rounded()) }
        return String(format: "#%02x%02x%02x", parts[0], parts[1], parts[2])
    }

    public func withAlpha(_ a: Double) -> RGBA { RGBA(r: r, g: g, b: b, a: a) }
}
