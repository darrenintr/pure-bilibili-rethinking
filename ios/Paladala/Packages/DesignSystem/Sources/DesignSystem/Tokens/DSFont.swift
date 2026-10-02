import SwiftUI

/// Type roles. SF Pro Rounded for Latin and PingFang TC for Chinese — the
/// platform equivalents of the design's Google Sans Flex + Noto Sans TC.
///
/// `DSFont` are Dynamic Type text styles for simple call sites. For the exact
/// Expressive scale (size / line height / weight) use `.dsText(_:)`.
public enum DSFont {
    public static let screenTitle = Font.system(.title2, design: .rounded).weight(.semibold)
    public static let sectionTitle = Font.system(.headline, design: .rounded)
    public static let cardTitle = Font.system(.subheadline, design: .rounded).weight(.semibold)
    public static let body = Font.system(.body, design: .rounded)
    public static let meta = Font.system(.caption, design: .rounded)
    public static let badge = Font.system(.caption2, design: .rounded).weight(.semibold).monospacedDigit()
}

/// The Expressive type scale.
public enum DSTextRole: CaseIterable, Sendable {
    case displayL, displayM, displayS
    case headlineM, headlineS
    /// 18/24 bold — screen section titles and hero video titles.
    case sectionTitle
    case titleL, titleM
    case bodyL, bodyM
    case labelL, labelM

    /// Point size at the default Dynamic Type setting.
    public var size: CGFloat {
        switch self {
        case .displayL: 57
        case .displayM: 45
        case .displayS: 36
        case .headlineM: 28
        case .headlineS: 24
        case .sectionTitle: 18
        case .titleL: 22
        case .titleM: 16
        case .bodyL: 16
        case .bodyM: 14
        case .labelL: 14
        case .labelM: 12
        }
    }

    public var lineHeight: CGFloat {
        switch self {
        case .displayL: 64
        case .displayM: 52
        case .displayS: 44
        case .headlineM: 36
        case .headlineS: 32
        case .sectionTitle: 24
        case .titleL: 28
        case .titleM: 22
        case .bodyL: 24
        case .bodyM: 20
        case .labelL: 20
        case .labelM: 16
        }
    }

    public var weight: Font.Weight {
        switch self {
        case .displayL, .displayM: .heavy
        case .displayS, .headlineM, .headlineS, .sectionTitle: .bold
        case .titleL, .titleM, .labelL: .semibold
        case .bodyL, .bodyM: .regular
        case .labelM: .medium
        }
    }

    /// Text style the role scales with.
    public var textStyle: Font.TextStyle {
        switch self {
        case .displayL: .largeTitle
        case .displayM, .displayS: .title
        case .headlineM, .headlineS: .title2
        case .titleL: .title3
        case .sectionTitle: .headline
        case .titleM, .bodyL, .labelL: .body
        case .bodyM: .subheadline
        case .labelM: .caption
        }
    }

    /// Letter spacing in points at the default size.
    public var tracking: CGFloat {
        switch self {
        case .displayL: -1
        case .displayM: -0.6
        case .displayS: -0.5
        default: 0
        }
    }
}

private struct DSTextModifier: ViewModifier {
    let role: DSTextRole
    @ScaledMetric private var size: CGFloat

    init(role: DSTextRole) {
        self.role = role
        _size = ScaledMetric(wrappedValue: role.size, relativeTo: role.textStyle)
    }

    func body(content: Content) -> some View {
        let scale = size / role.size
        content
            .font(.system(size: size, weight: role.weight, design: .rounded))
            .tracking(role.tracking * scale)
            .lineSpacing(max(0, role.lineHeight * scale - size * 1.2))
    }
}

public extension View {
    /// Applies an Expressive type role (rounded design, scales with Dynamic Type).
    func dsText(_ role: DSTextRole) -> some View {
        modifier(DSTextModifier(role: role))
    }
}
