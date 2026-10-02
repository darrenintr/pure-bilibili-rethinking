import SwiftUI
import UIKit

/// Semantic color tokens for Design v2.
///
/// Every token resolves through the system trait collection, so dark mode,
/// increased contrast and grouped/elevated backgrounds come for free. Pink is
/// the only brand color and is reserved for primary actions, live badges and
/// progress.
public enum DSColor {
    /// Brand accent (#FF6194).
    public static let accent = Color(red: 1.0, green: 0.38, blue: 0.58)
    /// Accent pressed / on-light variant with enough contrast for text.
    public static let accentStrong = Color(red: 0.86, green: 0.19, blue: 0.43)
    /// Text drawn on top of `accent`.
    public static let onAccent = Color.white

    /// Page background.
    public static let background = Color(uiColor: .systemGroupedBackground)
    /// Cards, sheets and grouped rows.
    public static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    /// Chips, inset fields, skeleton base.
    public static let surfaceMuted = Color(uiColor: .tertiarySystemFill)

    public static let textPrimary = Color(uiColor: .label)
    public static let textSecondary = Color(uiColor: .secondaryLabel)
    public static let textTertiary = Color(uiColor: .tertiaryLabel)
    public static let separator = Color(uiColor: .separator)

    /// Scrim behind text overlaid on a cover image (duration pill etc).
    public static let scrim = Color.black.opacity(0.55)

    public static let success = Color(uiColor: .systemGreen)
    public static let warning = Color(uiColor: .systemOrange)
    public static let danger = Color(uiColor: .systemRed)
}
