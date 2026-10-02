import SwiftUI

/// 4pt spacing scale.
public enum DSSpacing {
    public static let xxs: CGFloat = 2
    public static let xs: CGFloat = 4
    public static let s: CGFloat = 8
    public static let m: CGFloat = 12
    public static let l: CGFloat = 16
    public static let xl: CGFloat = 24
    public static let xxl: CGFloat = 32

    /// Horizontal page gutter.
    public static let gutter: CGFloat = l
}

/// Continuous corner radii: 8 · 12 · 16 · 28 · full. Covers are 16:9 at 20,
/// sheets and cards-on-surface at 28. No hard borders or offset shadows.
public enum DSRadius {
    /// Inner corners of a connected button group.
    public static let inner: CGFloat = 8
    public static let chip: CGFloat = 12
    public static let control: CGFloat = 16
    /// Video covers.
    public static let card: CGFloat = 20
    /// Sheets, panels, hero covers, nav bar.
    public static let sheet: CGFloat = 28
    /// Press target: a pressed round button squares off to this.
    public static let pressed: CGFloat = 12
    /// Stands in for "fully round" — clamps to half the shortest side.
    public static let full: CGFloat = 999
}

public extension RoundedRectangle {
    /// Continuous rounded rectangle with a `DSRadius` value.
    static func ds(_ radius: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }
}

/// Fixed control sizes (all ≥ 44 pt touch targets except dense in-player ones).
public enum DSSize {
    public static let buttonLarge: CGFloat = 56
    public static let button: CGFloat = 48
    public static let buttonSmall: CGFloat = 40
    public static let chip: CGFloat = 36
    public static let segment: CGFloat = 44
    public static let polygonAction: CGFloat = 56
    public static let navBar: CGFloat = 80
    public static let navIndicator = CGSize(width: 60, height: 36)
}
