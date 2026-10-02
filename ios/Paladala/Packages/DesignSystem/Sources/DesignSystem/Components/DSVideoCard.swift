import SwiftUI

/// Discover-feed card: true 16:9 cover, duration pill, two-line title and one
/// meta line. The cover is a slot so the app keeps its own image pipeline.
public struct DSVideoCard<Cover: View>: View {
    private let title: String
    private let author: String
    private let viewsText: String
    private let durationText: String?
    private let cover: Cover

    public init(
        title: String,
        author: String,
        viewsText: String,
        durationText: String? = nil,
        @ViewBuilder cover: () -> Cover
    ) {
        self.title = title
        self.author = author
        self.viewsText = viewsText
        self.durationText = durationText
        self.cover = cover()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.s) {
            Color.clear
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .background(DSColor.surfaceMuted)
                .overlay { cover.clipped() }
                .overlay(alignment: .bottomTrailing) {
                    if let durationText {
                        Text(durationText)
                            .font(DSFont.badge)
                            .foregroundStyle(.white)
                            .padding(.horizontal, DSSpacing.s - 2)
                            .padding(.vertical, DSSpacing.xxs)
                            .background(DSColor.scrim, in: Capsule())
                            .padding(DSSpacing.s - 2)
                    }
                }
                .clipShape(RoundedRectangle.ds(DSRadius.card))

            Text(title)
                .font(DSFont.cardTitle)
                .foregroundStyle(DSColor.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: DSSpacing.xs) {
                Text(author).lineLimit(1)
                Text("·")
                Text(viewsText).lineLimit(1).layoutPriority(1)
            }
            .font(DSFont.meta)
            .foregroundStyle(DSColor.textSecondary)
        }
        .accessibilityElement(children: .combine)
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
