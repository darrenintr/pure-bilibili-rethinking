import Foundation

/// An 8-bit sRGB colour. Foundation-only so the colour engine can be unit
/// tested without SwiftUI.
public struct DSRGB: Sendable, Hashable {
    public let r: UInt8
    public let g: UInt8
    public let b: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// Parses `#RGB` or `#RRGGBB` (the `#` is optional). Returns nil if invalid.
    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let n = UInt32(s, radix: 16) else { return nil }
        self.init(r: UInt8((n >> 16) & 255), g: UInt8((n >> 8) & 255), b: UInt8(n & 255))
    }

    /// Uppercase `#RRGGBB`.
    public var hex: String {
        String(format: "#%02X%02X%02X", r, g, b)
    }

    public static let black = DSRGB(r: 0, g: 0, b: 0)
    public static let white = DSRGB(r: 255, g: 255, b: 255)

    /// Paladala's default seed (Bili pink).
    public static let biliPink = DSRGB(r: 0xFF, g: 0x61, b: 0x94)
}

/// Scheme variants. Each maps the seed's hue/chroma onto the six palettes
/// differently (see `DSColorEngine.palettes`).
public enum DSVariant: String, CaseIterable, Sendable {
    /// Primary pushed to the most chroma each tone allows. The default.
    case vibrant
    /// Primary hue rotated 240° from the seed.
    case expressive
    /// Calm, low-chroma tonal spot. Good for long reading screens.
    case tonal
    /// Primary keeps the seed's own chroma, so cover-art seeds look like the cover.
    case fidelity
}

/// Tonal colour engine. Tone is CIELAB L*, so contrast is predictable: tone 40
/// on 100 and tone 80 on 20 both clear 4.5:1. Chroma is clipped to the sRGB
/// gamut per tone.
public enum DSColorEngine {
    // D65 white point (X, Z; Y = 100) and CIE constants.
    private static let xn = 95.047
    private static let zn = 108.883
    private static let kappa = 24389.0 / 27.0
    private static let epsilon = 216.0 / 24389.0

    private static func linearize(_ c: Double) -> Double {
        let v = c / 255
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    private static func gamma(_ c: Double) -> Double {
        255 * (c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055)
    }

    private static func f(_ t: Double) -> Double {
        t > epsilon ? cbrt(t) : (kappa * t + 16) / 116
    }

    private static func fInverse(_ t: Double) -> Double {
        t * t * t > epsilon ? t * t * t : (116 * t - 16) / kappa
    }

    /// CIELAB L*, chroma and hue (degrees, 0..<360) of an sRGB colour.
    public static func lch(_ rgb: DSRGB) -> (l: Double, c: Double, h: Double) {
        let r = linearize(Double(rgb.r)), g = linearize(Double(rgb.g)), b = linearize(Double(rgb.b))
        let x = f((0.4124 * r + 0.3576 * g + 0.1805 * b) * 100 / xn)
        let y = f(0.2126 * r + 0.7152 * g + 0.0722 * b)
        let z = f((0.0193 * r + 0.1192 * g + 0.9505 * b) * 100 / zn)
        let a = 500 * (x - y), bb = 200 * (y - z)
        var h = atan2(bb, a) * 180 / .pi
        h = (h + 360).truncatingRemainder(dividingBy: 360)
        return (116 * y - 16, hypot(a, bb), h)
    }

    /// Linear-light sRGB for an L*C*h colour (may fall outside 0...1).
    private static func linearRGB(l: Double, c: Double, h: Double) -> (Double, Double, Double) {
        let rad = h * .pi / 180
        let fy = (l + 16) / 116
        let fx = fy + c * cos(rad) / 500
        let fz = fy - c * sin(rad) / 200
        let x = fInverse(fx) * xn / 100
        let y = fInverse(fy)
        let z = fInverse(fz) * zn / 100
        return (
            3.2406 * x - 1.5372 * y - 0.4986 * z,
            -0.9689 * x + 1.8758 * y + 0.0415 * z,
            0.0557 * x - 0.204 * y + 1.057 * z
        )
    }

    private static func inGamut(_ c: (Double, Double, Double)) -> Bool {
        [c.0, c.1, c.2].allSatisfy { $0 >= -0.0005 && $0 <= 1.0005 }
    }

    /// The colour at hue `h`, chroma `c`, tone `t` (0...100), chroma reduced
    /// until it fits the sRGB gamut.
    public static func tone(hue h: Double, chroma c: Double, tone t: Double) -> DSRGB {
        if t <= 0 { return .black }
        if t >= 100 { return .white }
        var lin = linearRGB(l: t, c: c, h: h)
        if !inGamut(lin) {
            var lo = 0.0, hi = c
            for _ in 0..<16 {
                let m = (lo + hi) / 2
                if inGamut(linearRGB(l: t, c: m, h: h)) { lo = m } else { hi = m }
            }
            lin = linearRGB(l: t, c: lo, h: h)
        }
        func byte(_ v: Double) -> UInt8 {
            UInt8(min(255, max(0, gamma(v))).rounded())
        }
        return DSRGB(r: byte(lin.0), g: byte(lin.1), b: byte(lin.2))
    }

    /// One tonal palette: a fixed hue and chroma sampled at any tone.
    public struct Palette: Sendable, Equatable {
        public let hue: Double
        public let chroma: Double

        public init(hue: Double, chroma: Double) {
            self.hue = hue
            self.chroma = chroma
        }

        public func tone(_ t: Double) -> DSRGB {
            DSColorEngine.tone(hue: hue, chroma: chroma, tone: t)
        }
    }

    /// The six palettes every scheme is read from.
    public struct Palettes: Sendable, Equatable {
        public let primary: Palette
        public let secondary: Palette
        public let tertiary: Palette
        public let neutral: Palette
        public let neutralVariant: Palette
        public let error: Palette
    }

    /// The 13 tones shown in the palette strips.
    public static let displayTones: [Double] = [0, 10, 20, 30, 40, 50, 60, 70, 80, 90, 95, 99, 100]

    public static func palettes(seed: DSRGB, variant: DSVariant) -> Palettes {
        let (_, c, h) = lch(seed)
        // (hue offset, chroma) for primary, secondary, tertiary, neutral, neutral variant.
        let spec: [(Double, Double)]
        switch variant {
        case .vibrant:
            spec = [(0, 200), (15, 24), (45, 32), (0, 5), (0, 7)]
        case .expressive:
            spec = [(240, 40), (15, 24), (75, 32), (15, 4), (15, 6)]
        case .tonal:
            spec = [(0, 36), (0, 16), (60, 24), (0, 3), (0, 4.5)]
        case .fidelity:
            spec = [(0, c), (0, max(c - 32, c / 2)), (60, c * 0.6 + 8), (0, c / 16), (0, c / 16 + 2)]
        }
        let p = spec.map { Palette(hue: (h + $0.0).truncatingRemainder(dividingBy: 360), chroma: $0.1) }
        return Palettes(
            primary: p[0], secondary: p[1], tertiary: p[2],
            neutral: p[3], neutralVariant: p[4],
            error: Palette(hue: 32, chroma: 70)
        )
    }
}

/// Every colour role for one seed / variant / mode.
public struct DSScheme: Sendable, Equatable {
    public let primary: DSRGB
    public let onPrimary: DSRGB
    public let primaryContainer: DSRGB
    public let onPrimaryContainer: DSRGB

    public let secondary: DSRGB
    public let onSecondary: DSRGB
    public let secondaryContainer: DSRGB
    public let onSecondaryContainer: DSRGB

    public let tertiary: DSRGB
    public let onTertiary: DSRGB
    public let tertiaryContainer: DSRGB
    public let onTertiaryContainer: DSRGB

    public let error: DSRGB
    public let onError: DSRGB
    public let errorContainer: DSRGB
    public let onErrorContainer: DSRGB

    public let surface: DSRGB
    public let surfaceDim: DSRGB
    public let surfaceBright: DSRGB
    public let surfaceLowest: DSRGB
    public let surfaceLow: DSRGB
    public let surfaceContainer: DSRGB
    public let surfaceHigh: DSRGB
    public let surfaceHighest: DSRGB

    public let onSurface: DSRGB
    public let onSurfaceVariant: DSRGB
    public let outline: DSRGB
    public let outlineVariant: DSRGB

    public let inverseSurface: DSRGB
    public let inverseOnSurface: DSRGB
    public let inversePrimary: DSRGB

    public let palettes: DSColorEngine.Palettes
    public let isDark: Bool

    public init(seed: DSRGB, variant: DSVariant = .vibrant, dark: Bool) {
        let pal = DSColorEngine.palettes(seed: seed, variant: variant)
        let d = dark
        palettes = pal
        isDark = d

        primary = pal.primary.tone(d ? 80 : 40)
        onPrimary = pal.primary.tone(d ? 20 : 100)
        primaryContainer = pal.primary.tone(d ? 30 : 90)
        onPrimaryContainer = pal.primary.tone(d ? 90 : 10)

        secondary = pal.secondary.tone(d ? 80 : 40)
        onSecondary = pal.secondary.tone(d ? 20 : 100)
        secondaryContainer = pal.secondary.tone(d ? 30 : 90)
        onSecondaryContainer = pal.secondary.tone(d ? 90 : 10)

        tertiary = pal.tertiary.tone(d ? 80 : 40)
        onTertiary = pal.tertiary.tone(d ? 20 : 100)
        tertiaryContainer = pal.tertiary.tone(d ? 30 : 90)
        onTertiaryContainer = pal.tertiary.tone(d ? 90 : 10)

        error = pal.error.tone(d ? 80 : 40)
        onError = pal.error.tone(d ? 20 : 100)
        errorContainer = pal.error.tone(d ? 30 : 90)
        onErrorContainer = pal.error.tone(d ? 90 : 10)

        surface = pal.neutral.tone(d ? 6 : 98)
        surfaceDim = pal.neutral.tone(d ? 6 : 87)
        surfaceBright = pal.neutral.tone(d ? 24 : 98)
        surfaceLowest = pal.neutral.tone(d ? 4 : 100)
        surfaceLow = pal.neutral.tone(d ? 10 : 96)
        surfaceContainer = pal.neutral.tone(d ? 12 : 94)
        surfaceHigh = pal.neutral.tone(d ? 17 : 92)
        surfaceHighest = pal.neutral.tone(d ? 22 : 90)

        onSurface = pal.neutral.tone(d ? 90 : 10)
        onSurfaceVariant = pal.neutralVariant.tone(d ? 80 : 30)
        outline = pal.neutralVariant.tone(d ? 60 : 50)
        outlineVariant = pal.neutralVariant.tone(d ? 30 : 80)

        inverseSurface = pal.neutral.tone(d ? 90 : 20)
        inverseOnSurface = pal.neutral.tone(d ? 20 : 95)
        inversePrimary = pal.primary.tone(d ? 40 : 80)
    }
}
