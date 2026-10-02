import SwiftUI

public extension Color {
    /// sRGB colour from an engine colour.
    init(_ rgb: DSRGB) {
        self.init(
            .sRGB,
            red: Double(rgb.r) / 255,
            green: Double(rgb.g) / 255,
            blue: Double(rgb.b) / 255,
            opacity: 1
        )
    }
}

/// SwiftUI colour roles for one scheme. Names follow the Expressive roles:
/// `primary` for the main action, `*Container` for tonal fills, `surface*`
/// for the elevation ladder.
public struct DSColors: Sendable, Equatable {
    public let scheme: DSScheme

    public init(_ scheme: DSScheme) {
        self.scheme = scheme
    }

    public var primary: Color { Color(scheme.primary) }
    public var onPrimary: Color { Color(scheme.onPrimary) }
    public var primaryContainer: Color { Color(scheme.primaryContainer) }
    public var onPrimaryContainer: Color { Color(scheme.onPrimaryContainer) }

    public var secondary: Color { Color(scheme.secondary) }
    public var onSecondary: Color { Color(scheme.onSecondary) }
    public var secondaryContainer: Color { Color(scheme.secondaryContainer) }
    public var onSecondaryContainer: Color { Color(scheme.onSecondaryContainer) }

    public var tertiary: Color { Color(scheme.tertiary) }
    public var onTertiary: Color { Color(scheme.onTertiary) }
    public var tertiaryContainer: Color { Color(scheme.tertiaryContainer) }
    public var onTertiaryContainer: Color { Color(scheme.onTertiaryContainer) }

    public var error: Color { Color(scheme.error) }
    public var onError: Color { Color(scheme.onError) }
    public var errorContainer: Color { Color(scheme.errorContainer) }
    public var onErrorContainer: Color { Color(scheme.onErrorContainer) }

    public var surface: Color { Color(scheme.surface) }
    public var surfaceDim: Color { Color(scheme.surfaceDim) }
    public var surfaceBright: Color { Color(scheme.surfaceBright) }
    public var surfaceLowest: Color { Color(scheme.surfaceLowest) }
    public var surfaceLow: Color { Color(scheme.surfaceLow) }
    public var surfaceContainer: Color { Color(scheme.surfaceContainer) }
    public var surfaceHigh: Color { Color(scheme.surfaceHigh) }
    public var surfaceHighest: Color { Color(scheme.surfaceHighest) }

    public var onSurface: Color { Color(scheme.onSurface) }
    public var onSurfaceVariant: Color { Color(scheme.onSurfaceVariant) }
    public var outline: Color { Color(scheme.outline) }
    public var outlineVariant: Color { Color(scheme.outlineVariant) }

    public var inverseSurface: Color { Color(scheme.inverseSurface) }
    public var inverseOnSurface: Color { Color(scheme.inverseOnSurface) }
    public var inversePrimary: Color { Color(scheme.inversePrimary) }

    /// Text and icons drawn over a cover image (always light on dark).
    public var onScrim: Color { .white }
    /// Scrim behind a duration pill etc. (56% black).
    public var scrim: Color { Color.black.opacity(0.56) }
}

/// A seed colour plus a scheme variant. Both light and dark schemes are
/// generated up front, so switching appearance never recomputes.
public struct DSTheme: Sendable, Equatable {
    public let seed: DSRGB
    public let variant: DSVariant
    public let light: DSColors
    public let dark: DSColors

    public init(seed: DSRGB = .biliPink, variant: DSVariant = .vibrant) {
        self.seed = seed
        self.variant = variant
        self.light = DSColors(DSScheme(seed: seed, variant: variant, dark: false))
        self.dark = DSColors(DSScheme(seed: seed, variant: variant, dark: true))
    }

    /// Convenience for a `#RRGGBB` seed; falls back to Bili pink when invalid.
    public init(seedHex: String, variant: DSVariant = .vibrant) {
        self.init(seed: DSRGB(hex: seedHex) ?? .biliPink, variant: variant)
    }

    public func colors(for colorScheme: ColorScheme) -> DSColors {
        colorScheme == .dark ? dark : light
    }

    /// Bili pink, vibrant — the shipping default.
    public static let paladala = DSTheme()

    /// The eight seed choices offered in Settings → 主題色.
    public static let seeds: [DSSeed] = [
        DSSeed(name: "Bili 粉", rgb: DSRGB(r: 0xFF, g: 0x61, b: 0x94), shape: .cookie9),
        DSSeed(name: "珊瑚", rgb: DSRGB(r: 0xFF, g: 0x7A, b: 0x45), shape: .clover4),
        DSSeed(name: "琥珀", rgb: DSRGB(r: 0xF2, g: 0xB7, b: 0x05), shape: .pentagon),
        DSSeed(name: "青檸", rgb: DSRGB(r: 0x7B, g: 0xC0, b: 0x43), shape: .flower),
        DSSeed(name: "湖水綠", rgb: DSRGB(r: 0x1F, g: 0xA3, b: 0xA3), shape: .gem),
        DSSeed(name: "天藍", rgb: DSRGB(r: 0x3D, g: 0x7B, b: 0xF7), shape: .cookie6),
        DSSeed(name: "紫羅蘭", rgb: DSRGB(r: 0x8A, g: 0x5C, b: 0xF6), shape: .clover8),
        DSSeed(name: "石墨", rgb: DSRGB(r: 0x5F, g: 0x6B, b: 0x7A), shape: .square)
    ]
}

/// A selectable seed swatch and the polygon that represents it.
public struct DSSeed: Sendable, Equatable, Identifiable {
    public let name: String
    public let rgb: DSRGB
    public let shape: DSShape
    public var id: String { rgb.hex }

    public init(name: String, rgb: DSRGB, shape: DSShape) {
        self.name = name
        self.rgb = rgb
        self.shape = shape
    }
}

private struct DSThemeKey: EnvironmentKey {
    static let defaultValue = DSTheme.paladala
}

public extension EnvironmentValues {
    /// The active seed theme. Set with `.dsTheme(_:)`.
    var dsTheme: DSTheme {
        get { self[DSThemeKey.self] }
        set { self[DSThemeKey.self] = newValue }
    }
}

public extension View {
    /// Re-themes everything below this view from one seed.
    func dsTheme(_ theme: DSTheme) -> some View {
        environment(\.dsTheme, theme)
    }

    func dsTheme(seed: DSRGB, variant: DSVariant = .vibrant) -> some View {
        environment(\.dsTheme, DSTheme(seed: seed, variant: variant))
    }
}

/// Resolves the colour roles for the current theme and appearance.
///
///     @DSPalette private var c
///     Text("hi").foregroundStyle(c.onSurface)
@propertyWrapper
public struct DSPalette: DynamicProperty {
    @Environment(\.dsTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    public init() {}

    public var wrappedValue: DSColors { theme.colors(for: colorScheme) }
}
