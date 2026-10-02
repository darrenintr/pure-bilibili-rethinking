import SwiftUI

/// Type roles. All are Dynamic Type text styles; CJK falls back to PingFang
/// automatically.
public enum DSFont {
    public static let screenTitle = Font.title2.weight(.semibold)
    public static let sectionTitle = Font.headline
    public static let cardTitle = Font.subheadline.weight(.medium)
    public static let body = Font.body
    public static let meta = Font.caption
    public static let badge = Font.caption2.weight(.semibold).monospacedDigit()
}
