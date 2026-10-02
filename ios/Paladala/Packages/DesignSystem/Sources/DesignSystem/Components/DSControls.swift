import SwiftUI

/// Filled accent capsule button.
public struct DSPrimaryButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Font.subheadline.weight(.semibold))
            .foregroundStyle(DSColor.onAccent)
            .padding(.horizontal, DSSpacing.l)
            .padding(.vertical, DSSpacing.m - 2)
            .frame(minHeight: 44)
            .background(
                Capsule().fill(configuration.isPressed ? DSColor.accentStrong : DSColor.accent)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(DSMotion.quick, value: configuration.isPressed)
    }
}

public extension ButtonStyle where Self == DSPrimaryButtonStyle {
    static var dsPrimary: DSPrimaryButtonStyle { DSPrimaryButtonStyle() }
}

/// Selectable filter / category chip.
public struct DSChip: View {
    private let title: String
    private let isSelected: Bool
    private let action: () -> Void

    public init(_ title: String, isSelected: Bool, action: @escaping () -> Void) {
        self.title = title
        self.isSelected = isSelected
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(title)
                .font(Font.subheadline.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? DSColor.onAccent : DSColor.textPrimary)
                .padding(.horizontal, DSSpacing.m)
                .frame(minHeight: 36)
                .background(
                    RoundedRectangle.ds(DSRadius.chip)
                        .fill(isSelected ? DSColor.accent : DSColor.surfaceMuted)
                )
        }
        .buttonStyle(.plain)
        .animation(DSMotion.quick, value: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Section title with an optional trailing action.
public struct DSSectionHeader: View {
    private let title: String
    private let actionTitle: String?
    private let action: (() -> Void)?

    public init(_ title: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.title = title
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        HStack {
            Text(title)
                .font(DSFont.sectionTitle)
                .foregroundStyle(DSColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(DSFont.meta)
                    .foregroundStyle(DSColor.textSecondary)
            }
        }
        .padding(.horizontal, DSSpacing.gutter)
    }
}
