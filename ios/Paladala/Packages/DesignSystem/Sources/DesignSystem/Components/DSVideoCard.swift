import SwiftUI

/// Small label pinned to a cover's top-leading corner (為你推薦, 新一集, 直播).
public struct DSVideoBadge: Sendable, Equatable {
    public enum Style: Sendable { case primary, tertiary, live }

    public let text: String
    public let style: Style

    public init(_ text: String, style: Style = .tertiary) {
        self.text = text
        self.style = style
    }
}

/// Discover-feed card: true 16:9 cover, duration pill, two-line title and one
/// meta line with a polygon UP avatar. The cover is a slot so the app keeps
/// its own image pipeline; pass `DSCoverPlaceholder` while it loads.
public struct DSVideoCard<Cover: View>: View {
    public enum Prominence: Sendable {
        /// Grid cell: 20 pt cover radius, 14/20 title.
        case standard
        /// Lead item of a feed: 28 pt cover radius, larger title and avatar.
        case hero
    }

    private let title: String
    private let author: String
    private let viewsText: String
    private let durationText: String?
    private let authorID: String?
    private let badge: DSVideoBadge?
    private let prominence: Prominence
    private let cover: Cover
    @DSPalette private var c

    public init(
        title: String,
        author: String,
        viewsText: String,
        durationText: String? = nil,
        authorID: String? = nil,
        badge: DSVideoBadge? = nil,
        prominence: Prominence = .standard,
        @ViewBuilder cover: () -> Cover
    ) {
        self.title = title
        self.author = author
        self.viewsText = viewsText
        self.durationText = durationText
        self.authorID = authorID
        self.badge = badge
        self.prominence = prominence
        self.cover = cover()
    }

    private var avatarShape: DSShape { DSShape.avatar(forID: authorID ?? author) }

    public var body: some View {
        let hero = prominence == .hero
        VStack(alignment: .leading, spacing: hero ? DSSpacing.m - 2 : DSSpacing.s) {
            Color.clear
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .background(c.surfaceContainer)
                .overlay { cover.clipped() }
                .overlay(alignment: .topLeading) { badgeView.padding(hero ? DSSpacing.m : DSSpacing.s) }
                .overlay(alignment: .bottomTrailing) { durationView.padding(hero ? DSSpacing.m : DSSpacing.s) }
                .clipShape(RoundedRectangle.ds(hero ? DSRadius.sheet : DSRadius.card))

            if hero {
                HStack(alignment: .top, spacing: DSSpacing.m - 2) {
                    avatar(size: 36)
                    VStack(alignment: .leading, spacing: DSSpacing.xxs) {
                        titleText(role: .sectionTitle, lines: 2)
                        meta(showsAvatar: false)
                    }
                }
            } else {
                titleText(role: .labelL, lines: 2, reservesLines: true)
                meta(showsAvatar: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var badgeView: some View {
        if let badge {
            let fill: Color = switch badge.style {
            case .primary: c.primary
            case .tertiary: c.tertiaryContainer
            case .live: c.error
            }
            let ink: Color = switch badge.style {
            case .primary: c.onPrimary
            case .tertiary: c.onTertiaryContainer
            case .live: c.onError
            }
            Text(badge.text)
                .dsText(.labelM)
                .foregroundStyle(ink)
                .padding(.horizontal, DSSpacing.s)
                .padding(.vertical, DSSpacing.xxs)
                .background(fill, in: RoundedRectangle.ds(DSRadius.inner))
        }
    }

    @ViewBuilder
    private var durationView: some View {
        if let durationText {
            Text(durationText)
                .font(DSFont.badge)
                .foregroundStyle(c.onScrim)
                .padding(.horizontal, DSSpacing.s - 1)
                .padding(.vertical, DSSpacing.xxs)
                .background(c.scrim, in: RoundedRectangle.ds(DSRadius.inner))
        }
    }

    private func avatar(size: CGFloat) -> some View {
        Rectangle()
            .fill(c.tertiaryContainer)
            .frame(width: size, height: size)
            .clipShape(DSPolygon(avatarShape))
    }

    private func titleText(role: DSTextRole, lines: Int, reservesLines: Bool = false) -> some View {
        Text(title)
            .dsText(role)
            .foregroundStyle(c.onSurface)
            .lineLimit(lines, reservesSpace: reservesLines)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func meta(showsAvatar: Bool) -> some View {
        HStack(spacing: DSSpacing.xs + 2) {
            if showsAvatar { avatar(size: 16) }
            Text(author).lineLimit(1)
            Text("·")
            Text(viewsText).lineLimit(1).layoutPriority(1)
        }
        .dsText(.labelM)
        .monospacedDigit()
        .foregroundStyle(c.onSurfaceVariant)
    }
}

/// Default two-column feed layout (adaptive: more columns on wider screens).
public struct DSFeedGrid<Content: View>: View {
    private let content: Content
    private let columns = [
        GridItem(.adaptive(minimum: 150, maximum: 280), spacing: DSSpacing.m, alignment: .top)
    ]

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        LazyVGrid(columns: columns, spacing: DSSpacing.l) {
            content
        }
        .padding(.horizontal, DSSpacing.gutter)
    }
}
