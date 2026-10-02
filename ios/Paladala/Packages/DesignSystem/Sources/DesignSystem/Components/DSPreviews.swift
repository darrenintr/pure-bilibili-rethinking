import SwiftUI

private struct DSPreviewFeed: View {
    var body: some View {
        ScrollView {
            DSFeedGrid {
                ForEach(0..<6, id: \.self) { i in
                    DSVideoCard(
                        title: "示例影片標題 \(i)：這是一個很長的標題用來測試兩行截斷效果",
                        author: "UP 主 \(i)",
                        viewsText: "\(DSFormat.count(123_456 * (i + 1)))觀看",
                        durationText: DSFormat.duration(seconds: 215 + i * 400),
                        authorID: "\(i)",
                        badge: i == 0 ? DSVideoBadge("新一集") : nil
                    ) {
                        DSCoverPlaceholder(seed: "BV\(i)")
                    }
                }
            }
        }
        .background(DSPreviewBackground())
    }
}

private struct DSPreviewBackground: View {
    @DSPalette private var c
    var body: some View { c.surface.ignoresSafeArea() }
}

#Preview("Feed – light") {
    DSPreviewFeed()
}

#Preview("Feed – dark, skeleton") {
    ScrollView {
        DSFeedGrid {
            ForEach(0..<4, id: \.self) { _ in DSVideoCardSkeleton() }
        }
    }
    .background(DSPreviewBackground())
    .preferredColorScheme(.dark)
}

#Preview("Feed – azure seed, dark") {
    DSPreviewFeed()
        .dsTheme(seed: DSRGB(r: 0x3D, g: 0x7B, b: 0xF7))
        .preferredColorScheme(.dark)
}

#Preview("Hero card") {
    DSVideoCard(
        title: "深水埗電子街尋寶：$200 組一台復古掌機",
        author: "硬件小館",
        viewsText: "18.2萬 觀看",
        durationText: "12:48",
        badge: DSVideoBadge("為你推薦", style: .primary),
        prominence: .hero
    ) {
        DSCoverPlaceholder(seed: "hero", ambient: true)
    }
    .padding()
    .background(DSPreviewBackground())
}

private struct DSControlsPreview: View {
    @State private var segment = "推薦"
    @State private var liked = false
    @State private var coined = false
    @State private var starred = true
    @State private var chip = true
    @State private var tab = DSMainTab.discover
    @State private var sync = true
    @DSPalette private var c

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DSSpacing.xl) {
                DSSectionHeader("按鈕", actionTitle: "全部") {}
                HStack(spacing: DSSpacing.s) {
                    Button { } label: { Label("立即播放", systemImage: "play.fill") }
                        .buttonStyle(.dsPrimary(.large))
                    Button("稍後再看") {}.buttonStyle(.dsTonal)
                    Button("下載") {}.buttonStyle(.dsOutlined)
                }
                HStack(spacing: DSSpacing.s) {
                    Button("全部回覆") {}.buttonStyle(.dsTextButton)
                    Button { } label: { Image(systemName: "magnifyingglass") }
                        .buttonStyle(.dsIcon(.tonal))
                        .accessibilityLabel("搜尋")
                    Button { } label: { Image(systemName: "arrow.down.to.line") }
                        .buttonStyle(.dsIcon(.filled))
                        .accessibilityLabel("下載")
                }
                DSButtonGroup(["推薦", "熱門", "追番", "直播"], selection: $segment)
                    .padding(.horizontal, DSSpacing.gutter)

                HStack(spacing: DSSpacing.m) {
                    DSPolygonToggle(.like, count: "1.2萬", isOn: $liked)
                    DSPolygonToggle(.coin, count: "3,481", isOn: $coined)
                    DSPolygonToggle(.favorite, count: "8,902", isOn: $starred)
                }
                .padding(.horizontal, DSSpacing.gutter)

                HStack {
                    DSChip("1080P+", isSelected: chip) { chip.toggle() }
                    DSChip("可下載", isSelected: false) {}
                }
                .padding(.horizontal, DSSpacing.gutter)

                Toggle("播放時從封面取色", isOn: $sync)
                    .toggleStyle(.dsSwitch)
                    .dsText(.bodyL)
                    .padding(.horizontal, DSSpacing.gutter)

                VStack(alignment: .leading, spacing: DSSpacing.m) {
                    DSWavyProgress(
                        value: 0.35, isPlaying: true,
                        segments: [DSProgressSegment(start: 0.62, end: 0.73)]
                    )
                    HStack(spacing: DSSpacing.xl) {
                        DSLoadingIndicator()
                        DSLoadingIndicator(contained: true)
                    }
                }
                .padding(.horizontal, DSSpacing.gutter)

                DSNavBar(selection: $tab)
                    .padding(.horizontal, DSSpacing.gutter)
            }
            .padding(.vertical, DSSpacing.l)
        }
        .background(DSPreviewBackground())
    }
}

#Preview("Controls – light") {
    DSControlsPreview()
}

#Preview("Controls – dark, violet seed") {
    DSControlsPreview()
        .dsTheme(seed: DSRGB(r: 0x8A, g: 0x5C, b: 0xF6))
        .preferredColorScheme(.dark)
}

#Preview("Controls – AX5") {
    DSControlsPreview()
        .dynamicTypeSize(.accessibility5)
}

#Preview("Shape library") {
    ScrollView {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: DSSpacing.l) {
            ForEach(DSShape.allCases, id: \.self) { shape in
                VStack(spacing: DSSpacing.s) {
                    Rectangle()
                        .fill(DSTheme.paladala.light.primary)
                        .frame(width: 64, height: 64)
                        .clipShape(DSPolygon(shape))
                    Text(shape.label).dsText(.labelM)
                }
            }
        }
        .padding()
    }
}

#Preview("Glass bar") {
    Text("Mini player")
        .padding()
        .dsGlassBar()
        .padding()
        .background(DSPreviewBackground())
}
