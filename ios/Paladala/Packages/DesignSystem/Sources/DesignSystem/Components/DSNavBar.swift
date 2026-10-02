import SwiftUI

/// The four top-level destinations. Each tab owns a polygon.
public enum DSMainTab: CaseIterable, Hashable, Sendable {
    case discover, following, library, me

    public var title: String {
        switch self {
        case .discover: "探索"
        case .following: "關注"
        case .library: "片庫"
        case .me: "我的"
        }
    }

    public var systemImage: String {
        switch self {
        case .discover: "house"
        case .following: "person.2"
        case .library: "play.rectangle.on.rectangle"
        case .me: "person"
        }
    }

    public var shape: DSShape {
        switch self {
        case .discover: .cookie9
        case .following: .clover8
        case .library: .puffy
        case .me: .sunny
        }
    }
}

/// One entry of a `DSNavBar`.
public struct DSNavItem<Tab: Hashable>: Identifiable {
    public let tab: Tab
    public let title: String
    public let systemImage: String
    public let shape: DSShape
    public var showsDot: Bool
    public var id: Tab { tab }

    public init(tab: Tab, title: String, systemImage: String, shape: DSShape, showsDot: Bool = false) {
        self.tab = tab
        self.title = title
        self.systemImage = systemImage
        self.shape = shape
        self.showsDot = showsDot
    }
}

/// Bottom navigation bar. On select, the indicator grows from a dot and
/// morphs into the tab's own polygon.
public struct DSNavBar<Tab: Hashable>: View {
    private let items: [DSNavItem<Tab>]
    @Binding private var selection: Tab
    @DSPalette private var c

    public init(_ items: [DSNavItem<Tab>], selection: Binding<Tab>) {
        self.items = items
        self._selection = selection
    }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(items) { item in
                tab(item)
            }
        }
        .frame(height: DSSize.navBar)
        .background(c.surfaceHigh, in: RoundedRectangle.ds(DSRadius.sheet))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("主要導覽")
    }

    private func tab(_ item: DSNavItem<Tab>) -> some View {
        let on = item.tab == selection
        return Button {
            selection = item.tab
        } label: {
            VStack(spacing: DSSpacing.xs) {
                ZStack {
                    Rectangle()
                        .fill(c.secondaryContainer)
                        .clipShape(DSPolygon(on ? item.shape : .circle))
                        .scaleEffect(on ? 1 : 0.2)
                        .opacity(on ? 1 : 0)
                    Image(systemName: item.systemImage)
                        .symbolVariant(on ? .fill : .none)
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(on ? c.onSecondaryContainer : c.onSurfaceVariant)
                    if item.showsDot && !on {
                        Circle().fill(c.error)
                            .frame(width: 8, height: 8)
                            .offset(x: 14, y: -10)
                    }
                }
                .frame(width: DSSize.navIndicator.width, height: DSSize.navIndicator.height)
                Text(item.title)
                    .font(.system(size: 12, weight: on ? .bold : .medium, design: .rounded))
                    .foregroundStyle(on ? c.onSurface : c.onSurfaceVariant)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .dsSpatial(DSMotion.spatialFast, value: on)
        .dsEffects(value: on)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }
}

public extension DSNavBar where Tab == DSMainTab {
    /// The standard Discover / Following / Library / Me bar.
    init(selection: Binding<DSMainTab>) {
        self.init(
            DSMainTab.allCases.map {
                DSNavItem(tab: $0, title: $0.title, systemImage: $0.systemImage, shape: $0.shape)
            },
            selection: selection
        )
    }
}
