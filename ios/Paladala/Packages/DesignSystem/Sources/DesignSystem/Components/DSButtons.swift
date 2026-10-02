import SwiftUI

/// Shared surface for every Expressive button. At rest the button is fully
/// round; while pressed it squares off to `DSRadius.pressed` and scales to 0.95
/// on the fast spatial spring.
struct DSButtonSurface: View {
    enum Kind {
        case primary, tonal, outlined, text
        case iconFilled, iconTonal, iconStandard
    }

    let kind: Kind
    let height: CGFloat
    /// Fixed width for icon buttons; nil hugs the label.
    let width: CGFloat?
    /// Resting corner radius; nil = fully round.
    let restingRadius: CGFloat?
    let configuration: ButtonStyleConfiguration

    @DSPalette private var c
    @Environment(\.isEnabled) private var isEnabled

    private var background: Color {
        switch kind {
        case .primary, .iconFilled: c.primary
        case .tonal: c.secondaryContainer
        case .iconTonal: c.surfaceHighest
        case .outlined, .text, .iconStandard: .clear
        }
    }

    private var foreground: Color {
        switch kind {
        case .primary, .iconFilled: c.onPrimary
        case .tonal: c.onSecondaryContainer
        case .iconTonal: c.onSurface
        case .outlined: c.onSurfaceVariant
        case .text: c.primary
        case .iconStandard: c.onSurfaceVariant
        }
    }

    var body: some View {
        let pressed = configuration.isPressed
        let resting = restingRadius ?? height / 2
        let radius = pressed ? DSRadius.pressed : resting
        configuration.label
            .labelStyle(DSButtonLabelStyle())
            .foregroundStyle(foreground)
            .padding(.horizontal, width == nil ? (kind == .text ? DSSpacing.m + 2 : DSSpacing.xl - 4) : 0)
            .frame(width: width, height: height)
            .frame(minWidth: DSSize.buttonSmall)
            .background(background, in: RoundedRectangle.ds(radius))
            .overlay {
                if kind == .outlined {
                    RoundedRectangle.ds(radius).strokeBorder(c.outline, lineWidth: 1)
                }
            }
            .contentShape(RoundedRectangle.ds(radius))
            .scaleEffect(pressed ? 0.95 : 1)
            .opacity(isEnabled ? 1 : 0.38)
            .dsSpatial(DSMotion.spatialFast, value: pressed)
    }
}

/// Label + icon spacing used inside buttons.
struct DSButtonLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: DSSpacing.s) {
            configuration.icon
            configuration.title
        }
    }
}

public enum DSButtonSize: Sendable {
    /// 56 pt — the one hero action on a screen.
    case large
    /// 48 pt — default.
    case regular
    /// 40 pt — inline, dense rows.
    case small

    var height: CGFloat {
        switch self {
        case .large: DSSize.buttonLarge
        case .regular: DSSize.button
        case .small: DSSize.buttonSmall
        }
    }

    var role: DSTextRole {
        switch self {
        case .large: .titleM
        case .regular, .small: .labelL
        }
    }
}

/// Filled primary button. Pink (or the seed colour) is reserved for the main
/// action on a screen.
public struct DSPrimaryButtonStyle: ButtonStyle {
    private let size: DSButtonSize

    public init(size: DSButtonSize = .regular) {
        self.size = size
    }

    public func makeBody(configuration: Configuration) -> some View {
        DSButtonSurface(
            kind: .primary, height: size.height, width: nil,
            restingRadius: nil, configuration: configuration
        )
        .dsText(size.role)
    }
}

/// Secondary-container button: the quiet companion to a primary action.
public struct DSTonalButtonStyle: ButtonStyle {
    private let size: DSButtonSize

    public init(size: DSButtonSize = .regular) {
        self.size = size
    }

    public func makeBody(configuration: Configuration) -> some View {
        DSButtonSurface(
            kind: .tonal, height: size.height, width: nil,
            restingRadius: nil, configuration: configuration
        )
        .dsText(size.role)
    }
}

/// Outlined button for low-emphasis actions such as 下載.
public struct DSOutlinedButtonStyle: ButtonStyle {
    private let size: DSButtonSize

    public init(size: DSButtonSize = .regular) {
        self.size = size
    }

    public func makeBody(configuration: Configuration) -> some View {
        DSButtonSurface(
            kind: .outlined, height: size.height, width: nil,
            restingRadius: nil, configuration: configuration
        )
        .dsText(size.role)
    }
}

/// Text-only button in the primary colour.
public struct DSTextButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        DSButtonSurface(
            kind: .text, height: DSSize.buttonSmall, width: nil,
            restingRadius: nil, configuration: configuration
        )
        .dsText(.labelL)
    }
}

/// Square icon button. `.filled` is the primary action (resting radius 14),
/// `.tonal` the neutral round button (search, filter, settings).
public struct DSIconButtonStyle: ButtonStyle {
    public enum Variant: Sendable {
        case filled, tonal, standard
    }

    private let variant: Variant
    private let size: CGFloat

    public init(_ variant: Variant = .tonal, size: CGFloat = DSSize.button) {
        self.variant = variant
        self.size = size
    }

    private var kind: DSButtonSurface.Kind {
        switch variant {
        case .filled: .iconFilled
        case .tonal: .iconTonal
        case .standard: .iconStandard
        }
    }

    public func makeBody(configuration: Configuration) -> some View {
        DSButtonSurface(
            kind: kind, height: size, width: size,
            restingRadius: variant == .filled ? 14 : nil,
            configuration: configuration
        )
        .font(.system(size: 20, weight: .semibold, design: .rounded))
    }
}

public extension ButtonStyle where Self == DSPrimaryButtonStyle {
    static var dsPrimary: DSPrimaryButtonStyle { DSPrimaryButtonStyle() }
    static func dsPrimary(_ size: DSButtonSize) -> DSPrimaryButtonStyle { DSPrimaryButtonStyle(size: size) }
}

public extension ButtonStyle where Self == DSTonalButtonStyle {
    static var dsTonal: DSTonalButtonStyle { DSTonalButtonStyle() }
    static func dsTonal(_ size: DSButtonSize) -> DSTonalButtonStyle { DSTonalButtonStyle(size: size) }
}

public extension ButtonStyle where Self == DSOutlinedButtonStyle {
    static var dsOutlined: DSOutlinedButtonStyle { DSOutlinedButtonStyle() }
}

public extension ButtonStyle where Self == DSTextButtonStyle {
    static var dsTextButton: DSTextButtonStyle { DSTextButtonStyle() }
}

public extension ButtonStyle where Self == DSIconButtonStyle {
    static func dsIcon(_ variant: DSIconButtonStyle.Variant = .tonal, size: CGFloat = DSSize.button) -> DSIconButtonStyle {
        DSIconButtonStyle(variant, size: size)
    }
}

// MARK: - Connected button group

/// Connected segmented buttons: the selected item rounds fully, neighbours
/// keep 8 pt inner corners.
public struct DSButtonGroup<Item: Hashable>: View {
    private let items: [Item]
    private let title: (Item) -> String
    @Binding private var selection: Item
    @DSPalette private var c

    public init(_ items: [Item], selection: Binding<Item>, title: @escaping (Item) -> String) {
        self.items = items
        self._selection = selection
        self.title = title
    }

    public var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(items.enumerated()), id: \.element) { index, item in
                segment(item, index: index)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func segment(_ item: Item, index: Int) -> some View {
        let on = item == selection
        let full = DSSize.segment / 2
        let inner = DSRadius.inner
        let first = index == 0, last = index == items.count - 1
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: on || first ? full : inner,
            bottomLeadingRadius: on || first ? full : inner,
            bottomTrailingRadius: on || last ? full : inner,
            topTrailingRadius: on || last ? full : inner,
            style: .continuous
        )
        return Button {
            selection = item
        } label: {
            Text(title(item))
                .dsText(.labelL)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(on ? c.onPrimary : c.onSurfaceVariant)
                .frame(maxWidth: .infinity, minHeight: DSSize.segment)
                .padding(.horizontal, DSSpacing.s)
                .background(on ? c.primary : c.surfaceHighest, in: shape)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .dsSpatial(DSMotion.spatialFast, value: on)
        .dsEffects(value: on)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

public extension DSButtonGroup where Item == String {
    init(_ items: [String], selection: Binding<String>) {
        self.init(items, selection: selection, title: { $0 })
    }
}

// MARK: - Chip

/// Selectable filter / category chip. Selected: secondary container with a
/// check and a 12 pt squircle; unselected: outlined and fully round.
public struct DSChip: View {
    private let title: String
    private let isSelected: Bool
    private let action: () -> Void
    @DSPalette private var c

    public init(_ title: String, isSelected: Bool, action: @escaping () -> Void) {
        self.title = title
        self.isSelected = isSelected
        self.action = action
    }

    public var body: some View {
        let shape = RoundedRectangle.ds(isSelected ? DSRadius.chip : DSSize.chip / 2)
        Button(action: action) {
            HStack(spacing: DSSpacing.xs + 2) {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .transition(.scale.combined(with: .opacity))
                }
                Text(title).dsText(.labelL)
            }
            .foregroundStyle(isSelected ? c.onSecondaryContainer : c.onSurfaceVariant)
            .padding(.horizontal, DSSpacing.l - 2)
            .frame(minHeight: DSSize.chip)
            .background(isSelected ? c.secondaryContainer : .clear, in: shape)
            .overlay(shape.strokeBorder(isSelected ? c.secondaryContainer : c.outlineVariant, lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .dsSpatial(DSMotion.spatialFast, value: isSelected)
        .dsEffects(value: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Section header

/// Section title with an optional trailing action.
public struct DSSectionHeader: View {
    private let title: String
    private let actionTitle: String?
    private let action: (() -> Void)?
    @DSPalette private var c

    public init(_ title: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.title = title
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        HStack {
            Text(title)
                .dsText(.sectionTitle)
                .foregroundStyle(c.onSurface)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.dsTextButton)
            }
        }
        .padding(.horizontal, DSSpacing.gutter)
    }
}
