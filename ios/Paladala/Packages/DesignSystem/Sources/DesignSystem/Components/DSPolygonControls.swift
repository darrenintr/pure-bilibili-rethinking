import SwiftUI

/// Description of a polygon action (點讚 / 投幣 / 收藏): the shape it turns
/// into when active and how far that shape tilts.
public struct DSPolygonAction: Sendable {
    public let title: String
    public let systemImage: String
    public let activeShape: DSShape
    public let activeRotation: Double

    public init(title: String, systemImage: String, activeShape: DSShape, activeRotation: Double) {
        self.title = title
        self.systemImage = systemImage
        self.activeShape = activeShape
        self.activeRotation = activeRotation
    }

    public static let like = DSPolygonAction(title: "點讚", systemImage: "hand.thumbsup", activeShape: .burst, activeRotation: 15)
    public static let coin = DSPolygonAction(title: "投幣", systemImage: "yensign.circle", activeShape: .cookie9, activeRotation: 20)
    public static let favorite = DSPolygonAction(title: "收藏", systemImage: "star", activeShape: .clover4, activeRotation: 45)
}

/// Round toggle that morphs into a polygon when on. The shape carries the
/// state: idle is a circle, active is a tilted polygon in the primary colour.
public struct DSPolygonToggle: View {
    private let action: DSPolygonAction
    private let count: String?
    @Binding private var isOn: Bool
    @DSPalette private var c

    public init(_ action: DSPolygonAction, count: String? = nil, isOn: Binding<Bool>) {
        self.action = action
        self.count = count
        self._isOn = isOn
    }

    public var body: some View {
        Button {
            isOn.toggle()
        } label: {
            VStack(spacing: DSSpacing.xs + 2) {
                ZStack {
                    Rectangle()
                        .fill(isOn ? c.primary : c.surfaceHighest)
                        .clipShape(DSPolygon(isOn ? action.activeShape : .circle))
                        .rotationEffect(.degrees(isOn ? action.activeRotation : 0))
                    Image(systemName: action.systemImage)
                        .symbolVariant(isOn ? .fill : .none)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(isOn ? c.onPrimary : c.onSurfaceVariant)
                }
                .frame(width: DSSize.polygonAction, height: DSSize.polygonAction)
                if let count {
                    Text(count)
                        .dsText(.labelM)
                        .monospacedDigit()
                        .foregroundStyle(c.onSurfaceVariant)
                }
            }
            .frame(minWidth: DSSize.polygonAction)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .dsSpatial(DSMotion.spatialFast, value: isOn)
        .dsEffects(value: isOn)
        .accessibilityLabel(action.title)
        .accessibilityValue(count ?? "")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Switch whose thumb is a small circle when off and a tilted "sunny" polygon
/// when on.
public struct DSToggleStyle: ToggleStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        DSSwitchBody(configuration: configuration)
    }
}

public extension ToggleStyle where Self == DSToggleStyle {
    static var dsSwitch: DSToggleStyle { DSToggleStyle() }
}

private struct DSSwitchBody: View {
    let configuration: ToggleStyleConfiguration
    @DSPalette private var c

    var body: some View {
        let on = configuration.isOn
        HStack(spacing: DSSpacing.m) {
            configuration.label
            Spacer(minLength: DSSpacing.m)
            Button {
                configuration.isOn.toggle()
            } label: {
                Capsule()
                    .fill(on ? c.primary : c.surfaceHighest)
                    .overlay(Capsule().strokeBorder(on ? c.primary : c.outline, lineWidth: 2))
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(on ? c.onPrimary : c.outline)
                            .frame(width: on ? 26 : 16, height: on ? 26 : 16)
                            .clipShape(DSPolygon(on ? .sunny : .circle))
                            .rotationEffect(.degrees(on ? 30 : 0))
                            .offset(x: on ? 27 : 9)
                    }
                    .frame(width: 56, height: 34)
                    .frame(minWidth: DSSize.segment, minHeight: DSSize.segment)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .dsSpatial(DSMotion.spatialFast, value: on)
            .dsEffects(value: on)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(on ? "開" : "關")
    }
}

// MARK: - Avatar

/// UP avatar clipped to a polygon. Pass the creator's id and the same creator
/// always gets the same shape.
public struct DSAvatar<Content: View>: View {
    private let shape: DSShape
    private let size: CGFloat
    private let content: Content

    public init(shape: DSShape, size: CGFloat = 40, @ViewBuilder content: () -> Content) {
        self.shape = shape
        self.size = size
        self.content = content()
    }

    public var body: some View {
        content
            .frame(width: size, height: size)
            .clipShape(DSPolygon(shape))
            .accessibilityHidden(true)
    }
}

public extension DSAvatar where Content == DSAvatarInitial {
    /// Initial-letter avatar on the tertiary container.
    init(initial: String, id: String, size: CGFloat = 40) {
        self.init(shape: DSShape.avatar(forID: id), size: size) {
            DSAvatarInitial(initial: initial, size: size)
        }
    }
}

public struct DSAvatarInitial: View {
    let initial: String
    let size: CGFloat
    @DSPalette private var c

    public var body: some View {
        Text(String(initial.prefix(1)))
            .font(.system(size: size * 0.42, weight: .heavy, design: .rounded))
            .foregroundStyle(c.onTertiaryContainer)
            .frame(width: size, height: size)
            .background(c.tertiaryContainer)
    }
}
