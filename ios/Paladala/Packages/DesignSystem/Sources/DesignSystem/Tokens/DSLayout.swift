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

/// Continuous corner radii. No hard borders or offset shadows in v2.
public enum DSRadius {
    public static let chip: CGFloat = 10
    public static let card: CGFloat = 14
    public static let sheet: CGFloat = 24
}

public extension RoundedRectangle {
    /// Continuous rounded rectangle with a `DSRadius` value.
    static func ds(_ radius: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }
}
