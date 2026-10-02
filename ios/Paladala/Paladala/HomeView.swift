import SwiftUI

struct HomeView: View {
    let repository: PaladalaRepository
    /// Optional namespace for the hero / zoom navigation
    /// transition. Threaded down to each `VideoCard` so the
    /// cover image registers as a `matchedTransitionSource`.
    /// `nil` disables the transition (the card still works,
    /// the navigation just falls back to the system
    /// cross-fade).
    let heroNamespace: Namespace.ID?
    /// Number of grid columns on iPad regular-width layouts.
    /// `PadRootView` picks 2 (sidebar visible) or 3 (sidebar
    /// collapsed) based on `columnVisibility` so the video grid
    /// re-flows when the user pulls the sidebar away.  Phone
    /// layouts always use 1 column regardless of this value.
    let iPadColumns: Int

    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var authStore: AuthStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @StateObject private var model = HomeViewModel()
    @State private var isShortVideoFeedPresented = false
    @AppStorage("paladala.materialDesign") private var materialDesign: MaterialDesign = .liquidGlass
    /// Observed so SwiftUI re-evaluates the toolbar's
    /// `.badge(downloadStore.records.count)` whenever a
    /// record is added or removed — without this observation the
    /// pill was frozen at the count rendered on first body eval
    /// (Performance audit #2 / Polish agent).
    @ObservedObject private var downloadStore = DownloadStore.shared

    init(
        repository: PaladalaRepository,
        heroNamespace: Namespace.ID? = nil,
        iPadColumns: Int = 2
    ) {
        self.repository = repository
        self.heroNamespace = heroNamespace
        self.iPadColumns = iPadColumns
    }

    /// Resolved on every call so account switches in
    /// `ProfileSettingsView` are reflected in the follow-feed filter
    /// on the next refresh — the view model never caches it.
    private var accountMid: Int64 { authStore.activeAccount?.mid ?? 0 }

    private var columns: [GridItem] {
        // Street Minimal keeps the phone feed editorial and linear:
        // one full-width card at a time. Regular-width layouts
        // use `iPadColumns` (set by `PadRootView` to 2 with the
        // sidebar visible or 3 when the user collapses it for
        // more screen real estate).
        if horizontalSizeClass == .regular {
            return Array(
                repeating: GridItem(.flexible(), spacing: 32, alignment: .top),
                count: max(2, iPadColumns)
            )
        }
        return [GridItem(.flexible(), alignment: .top)]
    }

    /// Street-style search bar extracted out of `body` so the
    /// body expression stays under the Swift type-checker
    /// budget.  Lives in `.safeAreaInset(edge: .top)` so it
    /// sits flush with the nav bar above and pushes the feed
    /// content below.
    private var searchBar: some View {
        UISearchFieldBridge(
            text: $model.searchQuery,
            prompt: "搜尋 Bilibili 影片和 UP 主",
            onSubmit: {
                model.clearSuggestions()
                model.category = .search
                Task {
                    await model.load(repository: repository, accountMid: accountMid)
                    await model.runAllSearch(repository: repository)
                }
            },
            onQueryChanged: { query in
                model.searchQueryChanged(query, repository: repository)
            }
        )
        .padding(.horizontal, PaladalaTheme.Spacing.l)
        .padding(.vertical, PaladalaTheme.Spacing.s)
        .background(PaladalaTheme.paper)
    }

    /// Search bar plus a live keystroke-rate suggestions
    /// dropdown.  Wrapped in a VStack so the dropdown sits
    /// flush under the bridge and the whole stack is one
    /// `safeAreaInset` insertion.  The dropdown is empty
    /// (and therefore zero-height) when the user hasn't
    /// typed yet, so it doesn't push the feed content
    /// down at idle.
    private var searchBarSection: some View {
        VStack(spacing: 0) {
            searchBar
            if !model.searchQuery.isEmpty && !model.searchSuggestions.isEmpty {
                SuggestionList(
                    suggestions: model.searchSuggestions,
                    onSelect: { suggestion in
                        // Tap-to-fill: mirror the old
                        // `.searchCompletion` behaviour.  The
                        // bridge updates its text via the
                        // binding, then we run the same
                        // submit path so the feed jumps to
                        // the chosen result without waiting
                        // for the user to hit the keyboard's
                        // search button.
                        model.searchQuery = suggestion.displayName
                        model.clearSuggestions()
                        model.category = .search
                        Task {
                            await model.load(repository: repository, accountMid: accountMid)
                            await model.runAllSearch(repository: repository)
                        }
                    }
                )
            }
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            feedContent(scrollProxy: proxy)
                .background(Color.clear)
                .navigationTitle("Paladala")
                // Apple large-title guidance for top-level
                // navigation: the title collapses into the
                // chrome on scroll and re-expands when the
                // scroll returns to top. The system handles
                // the animation; we just enable the mode.
                //
                // iOS Native variant gets `.large` so the user
                // sees the full 28pt title at the top of the
                // feed (Apple's recommended top-level nav look);
                // Street stays on `.inline` because the hard-edged
                // style works better with a permanently compact
                // title.
                .navigationBarTitleDisplayMode(
                    PaladalaTheme.activeVariant == .iosNative ? .large : .inline
                )
                // PR-fix-2026-07-10: replace `.searchable` with
                // a hand-rolled `UISearchFieldBridge` so the
                // search bar carries Street Minimal chrome
                // (paper background, 1.5pt ink border, no
                // rounding, SF-Symbol magnifier).  The system
                // `.searchable` rendered a glass capsule that
                // didn't fit the rest of the chrome.  The
                // trade-off is that `.searchSuggestions` no
                // longer wires up automatically — see the
                // bridge's doc-comment for follow-up.
                //
                // Extracted into `searchBarSection` (private
                // computed property) so the body expression
                // stays readable for the Swift type-checker
                // and so the live keystroke suggestions have
                // somewhere to live under the bridge.
                .safeAreaInset(edge: .top, spacing: 0) { searchBarSection }
                // PR-fix-2026-07-10: the trailing toolbar
                // column (5 icons on the right of the nav
                // bar) was rendering with the iOS 26 Liquid
                // Glass material on top of the paper nav bar,
                // making the icons look like they were
                // floating on a separate tinted surface.  The
                // right SwiftUI hook for this is
                // `.toolbarBackground(_:for: .navigationBar)`
                // — earlier I tried a UIKit
                // `UIBarButtonItemAppearance` route that
                // doesn't exist on iOS 26, but the SwiftUI
                // modifier does.  Pair with
                // `.toolbarBackground(.visible, ...)` so the
                // paper background stays visible during
                // scroll, otherwise the system re-introduces
                // the glass material when the user scrolls
                // the feed.
                .toolbarBackground(PaladalaTheme.paper, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        if PaladalaTheme.activeVariant == .iosNative {
                            // iOS Native: 2 icons (refresh + profile).
                            // Downloads / short-video / notifications
                            // live in a "..." Menu (or in the iOS Native
                            // search suggestions).  Apple's recommended
                            // top-level nav pattern is 1-2 toolbar icons
                            // so the system Liquid Glass surface stays
                            // uncluttered.
                            Button {
                                Haptics.tap()
                                Task { await model.load(repository: repository, accountMid: accountMid) }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .accessibilityLabel(L10n.home.refresh)
                            Menu {
                                Button {
                                    Haptics.tap()
                                    router.open(.downloads)
                                } label: {
                                    Label("離線快取", systemImage: "arrow.down.circle")
                                }
                                .badge(downloadStore.records.count)
                                Button {
                                    Haptics.tap()
                                    isShortVideoFeedPresented = true
                                } label: {
                                    Label("短影片", systemImage: "rectangle.portrait.on.rectangle.portrait")
                                }
                                Button {
                                    Haptics.tap()
                                    router.open(.dynamic)
                                } label: {
                                    Label("動態", systemImage: "bell")
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                            .accessibilityLabel("更多")
                            Button {
                                Haptics.tap()
                                router.open(.profile)
                            } label: {
                                Image(systemName: "person.crop.circle")
                            }
                            .accessibilityLabel("我的")
                        } else {
                            // Street Minimal: 5 icons on the right of
                            // the nav bar.  The hard-edged toolbar chrome
                            // is part of the brand and works well with
                            // the rest of the Street components.
                            Button {
                                Haptics.tap()
                                router.open(.downloads)
                            } label: {
                                Label("離線快取", systemImage: "arrow.down.circle")
                            }
                            .badge(downloadStore.records.count)
                            Button {
                                Haptics.tap()
                                isShortVideoFeedPresented = true
                            } label: {
                                Label("短影片", systemImage: "rectangle.portrait.on.rectangle.portrait")
                            }
                            Button {
                                Haptics.tap()
                                Task { await model.load(repository: repository, accountMid: accountMid) }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .accessibilityLabel(L10n.home.refresh)
                            Button {
                                Haptics.tap()
                                router.open(.dynamic)
                            } label: {
                                Image(systemName: "bell")
                            }
                            .accessibilityLabel("動態")
                            Button {
                                Haptics.tap()
                                router.open(.profile)
                            } label: {
                                Image(systemName: "person.crop.circle")
                            }
                            .accessibilityLabel("我的")
                        }
                    }
                }
                .modifier(HomeToolbarGlassModifier(materialDesign: materialDesign))
                .task {
                    // PR-A Task 9: bootstrap once per view-model
                    // lifetime. Try the on-disk cache first so the
                    // first frame paints from the snapshot while the
                    // network request is still in flight; fall back
                    // to network on a miss. Pull-to-refresh is the
                    // manual re-bootstrap path.
                    if !model.didBootstrap {
                        let cached = await FeedCacheWarmer.shared.seedFromCache(key: "home")
                        if let cached {
                            model.seedFromCache(cached)
                        }
                        model.markBootstrapped()
                        LaunchMetrics.shared.mark(.firstFeedCached)
                        await Task.yield()
                        LaunchMetrics.shared.mark(.firstFeedNetworkStart)
                        await model.load(
                            repository: repository,
                            accountMid: accountMid,
                            preservingExistingContent: cached != nil
                        )
                        LaunchMetrics.shared.mark(.firstFeedNetworkComplete)
                    }
                }
                .onChange(of: model.category) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("feedTop", anchor: .top)
                    }
                    Task { await model.load(repository: repository, accountMid: accountMid) }
                }
                .onChange(of: model.popularSubCategory) { _, _ in
                    guard model.category == .popular else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("feedTop", anchor: .top)
                    }
                    Task { await model.load(repository: repository, accountMid: accountMid) }
                }
                .onChange(of: router.pendingSearchQuery) { _, query in
                    Task { await model.applyIntentSearch(query, repository: repository, accountMid: accountMid) }
                }
                .onChange(of: accountMid) { _, _ in
                    guard model.category == .follow else { return }
                    Task { await model.load(repository: repository, accountMid: accountMid) }
                }
                .onReceive(NotificationCenter.default.publisher(for: .homeShowBundledFallback)) { _ in
                    model.showBundledFallback(repository: repository)
                }
                .fullScreenCover(isPresented: $isShortVideoFeedPresented) {
                    ShortVideoFeedView(repository: repository)
                }
        }
    }

    /// The scrollable feed body. The `ScrollViewReader` lives in `body`
    /// so the `proxy` it provides is in scope for the `.refreshable`
    /// modifier, which needs to scroll back to the top of the feed.
    @ViewBuilder
    private func feedContent(scrollProxy proxy: ScrollViewProxy) -> some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                Color.clear
                    .frame(height: 0)
                    .id("feedTop")

                categoryStrip
                if model.category == .popular {
                    popularSubCategoryStrip
                }
                if let error = model.errorMessage {
                    VStack(spacing: 10) {
                        ErrorBanner(message: error)
                        Button {
                            model.showBundledFallback(repository: repository)
                        } label: {
                            Label("檢視離線樣例", systemImage: "wifi.slash")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                if model.isShowingBundledFallback {
                    HomeOfflineBanner {
                        Task {
                            await model.load(repository: repository, accountMid: accountMid)
                            withAnimation(.easeOut(duration: 0.25)) {
                                proxy.scrollTo("feedTop", anchor: .top)
                            }
                        }
                    }
                }
                if model.isLoading && model.videos.isEmpty && model.liveRooms.isEmpty && model.dynamicItems.isEmpty {
                    // Skeleton grid only on the *first* load — once
                    // any data is in `videos` / `liveRooms` /
                    // `dynamicItems` we let the user see what we have
                    // and use the inline "加载更多" spinner at the
                    // bottom for paginated loads.
                    SkeletonGrid(
                        columns: horizontalSizeClass == .regular ? 2 : 1,
                        columnSpacing: 32,
                        rowSpacing: 32
                    )
                        .padding(.top, 4)
                } else if model.category == .live && !model.liveRooms.isEmpty {
                    LazyVGrid(columns: columns, spacing: 32) {
                        ForEach(model.liveRooms) { room in
                            LiveRoomCard(room: room)
                        }
                    }
                } else if model.category == .follow {
                    DynamicFeedList(model: model, repository: repository)
                } else if model.videos.isEmpty && !(model.category == .search && !model.searchUsers.isEmpty) {
                    HomeEmptyState(
                        category: model.category,
                        searchQuery: model.searchQuery,
                        hasError: model.errorMessage != nil,
                        onRetry: {
                            Task { await model.load(repository: repository, accountMid: accountMid) }
                        }
                    )
                } else {
                    if model.category == .search && !model.searchUsers.isEmpty {
                        SearchUserResultsStrip(users: model.searchUsers)
                            .padding(.bottom, 2)
                    }
                    LazyVGrid(columns: columns, spacing: 32) {
                        ForEach(Array(model.videos.enumerated()), id: \.element.id) { index, video in
                            VideoCard(
                                video: video,
                                repository: repository,
                                heroNamespace: heroNamespace,
                                action: { router.openVideo(video) }
                            )
                            .frame(maxWidth: .infinity)
                            .id(video.id)
                            // PR-5 (M5): dropped the per-card
                            // `model.firstPageAnimated` animation.
                            // 20 simultaneously-animating layers
                            // (each with its own `delay(Double * 0.035)`
                            // modifier) cost ~12 transition closures
                            // per grid and re-evaluated every body
                            // pass — for the same visible effect.
                            // The root-level `.animation(...)` on
                            // `LazyVGrid` (set inside `feedContent`)
                            // carries the same fan-in.
                            .onAppear {
                                triggerLoadMoreIfNeeded(currentIndex: index)
                            }
                        }
                    }
                    paginationFooter
                }
            }
            .padding(PaladalaTheme.contentPadding)
        }
        .scrollIndicators(.hidden)
        .refreshable {
            Haptics.medium()
            await model.load(repository: repository, accountMid: accountMid)
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo("feedTop", anchor: .top)
            }
        }
    }

    private var categoryStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            PaladalaGlassContainer(materialDesign: materialDesign, spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(HomeCategory.androidTabs) { category in
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                model.category = category
                            }
                            Haptics.selection()
                        } label: {
                            Text(category.title)
                                .font(PaladalaTheme.FontRole.labelMono)
                                .padding(.horizontal, 13)
                                .padding(.vertical, 9)
                                .paladalaSelectionChip(
                                    isSelected: model.category == category,
                                    design: materialDesign
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var popularSubCategoryStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            PaladalaGlassContainer(materialDesign: materialDesign, spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(PopularSubCategory.allCases) { subCategory in
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                model.popularSubCategory = subCategory
                            }
                            Haptics.selection()
                        } label: {
                            Text(subCategory.title)
                                .font(PaladalaTheme.FontRole.labelMono)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .paladalaSelectionChip(
                                    isSelected: model.popularSubCategory == subCategory,
                                    design: materialDesign
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var paginationFooter: some View {
        if model.isLoadingMore {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("載入更多…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
        } else if model.videos.count > 0 && model.category != .live {
            // Replace the "— 没有更多了 —" caption with a real action. The
            // user can either pull-to-refresh, tap the "换一批" button to
            // re-request the next page (works when the upstream endpoint
            // sometimes returned a short page), or tap "重新加载" when the
            // current list is the bundled offline sample set.
            VStack(spacing: 10) {
                if model.isShowingBundledFallback {
                    Text("當前展示離線樣例資料")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    Button {
                        Task { await model.load(repository: repository, accountMid: accountMid) }
                    } label: {
                        Label("重新整理", systemImage: "arrow.clockwise")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        Task { await model.loadNextBatch(repository: repository, accountMid: accountMid) }
                    } label: {
                        Label("換一批", systemImage: "infinity")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 12)
        } else if model.category == .follow && model.dynamicHasMore && !model.dynamicItems.isEmpty {
            Button {
                Task { await model.loadMore(repository: repository, accountMid: accountMid) }
            } label: {
                Label("檢視更多關注動態", systemImage: "arrow.down.circle")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .frame(maxWidth: .infinity)
            .padding(.top, 12)
        }
    }

    private func triggerLoadMoreIfNeeded(currentIndex: Int) {
        // Pre-fetch when the user gets within the last four visible cells of
        // the loaded page. Anything tighter makes the bottom of the grid feel
        // empty for a moment; anything looser wastes requests.
        let threshold = max(0, model.videos.count - 4)
        guard currentIndex >= threshold else { return }
        Task { await model.loadMore(repository: repository, accountMid: accountMid) }
    }
}

private struct HomeOfflineBanner: View {
    let onRetry: () -> Void
    @AppStorage("paladala.materialDesign") private var materialDesign: MaterialDesign = .liquidGlass

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi.slash")
                .font(.title3)
                .foregroundStyle(PaladalaTheme.biliPink)
            VStack(alignment: .leading, spacing: 2) {
                Text("網路異常 · 當前為離線樣例")
                    .font(.subheadline.weight(.semibold))
                Text("下拉或點“重新載入”即可拉取 Bilibili 公共內容源。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("重新載入", action: onRetry)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(12)
        .paladalaCardSurface(materialDesign)
    }
}

private struct SearchUserResultsStrip: View {
    let users: [BiliUserSearchResult]
    @EnvironmentObject private var router: AppRouter
    @AppStorage("paladala.materialDesign") private var materialDesign: MaterialDesign = .liquidGlass

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("相關 UP 主", systemImage: "person.2")
                .font(.subheadline.weight(.semibold))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(users) { user in
                        Button {
                            Haptics.selection()
                            router.openUP(mid: user.mid)
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 8) {
                                    ResilientImage(
                                        url: user.faceURL,
                                        maximumPixelSize: 160
                                    )
                                        .frame(width: 42, height: 42)
                                        .clipShape(Rectangle())
                                        .overlay {
                                            Rectangle()
                                                .strokeBorder(
                                                    PaladalaTheme.ink,
                                                    lineWidth: PaladalaTheme.borderWidth
                                                )
                                        }
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(user.name)
                                            .font(.subheadline.weight(.semibold))
                                            .lineLimit(1)
                                        Text("\(user.fans.compactCount) 粉絲 · \(user.videos.compactCount) 影片")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                if !user.sign.isEmpty {
                                    Text(user.sign)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            .frame(width: 210, alignment: .leading)
                            .padding(12)
                            .paladalaCardSurface(materialDesign)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
private final class ShortVideoFeedViewModel: ObservableObject {
    @Published var videos: [BiliVideo] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private var freshIndex = 0

    func load(repository: PaladalaRepository, replacing: Bool = true) async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        do {
            let next = try await repository.shortVideoFeed(freshIndex: freshIndex)
            freshIndex += 1
            if replacing {
                videos = next
            } else {
                let existing = Set(videos.map(\.id))
                videos.append(contentsOf: next.filter { !existing.contains($0.id) })
            }
        } catch {
            errorMessage = "短影片載入失敗：\(error.localizedDescription)"
        }
        isLoading = false
    }
}

private struct ShortVideoFeedView: View {
    let repository: PaladalaRepository

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var router: AppRouter
    @StateObject private var model = ShortVideoFeedViewModel()

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            GeometryReader { geo in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.videos.enumerated()), id: \.element.id) { index, video in
                            ShortVideoPage(video: video, size: geo.size) {
                                dismiss()
                                router.openVideo(video)
                            }
                            .onAppear {
                                if index >= max(0, model.videos.count - 3) {
                                    Task { await model.load(repository: repository, replacing: false) }
                                }
                            }
                        }
                        if model.isLoading && model.videos.isEmpty {
                            ProgressView()
                                .tint(.white)
                                .frame(width: geo.size.width, height: geo.size.height)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .ignoresSafeArea()
            }

            if let error = model.errorMessage, model.videos.isEmpty {
                ErrorBanner(message: error)
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }

            Button {
                Haptics.tap()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(.black.opacity(0.72))
                    .overlay {
                        Rectangle().strokeBorder(.white, lineWidth: 1)
                    }
            }
            .padding(.top, 18)
            .padding(.trailing, 16)
        }
        .task {
            if model.videos.isEmpty {
                await model.load(repository: repository)
            }
        }
    }
}

private struct ShortVideoPage: View {
    let video: BiliVideo
    let size: CGSize
    let open: () -> Void

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            CoverImage(url: video.coverURL)
                .frame(width: size.width, height: size.height)
                .clipped()
                .overlay {
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.3), .black.opacity(0.86)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }

            VStack(alignment: .leading, spacing: 12) {
                Text(video.title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(3)
                Text(video.ownerName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.86))
                    .lineLimit(1)
                HStack(spacing: 10) {
                    Label("播放", systemImage: "play.fill")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(PaladalaTheme.biliPink)
                        .overlay {
                            Rectangle().strokeBorder(.black, lineWidth: 1)
                        }
                    Text(video.duration.mmss)
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.white.opacity(0.82))
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 44)
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
    }
}

private struct HomeEmptyState: View {
    let category: HomeCategory
    let searchQuery: String
    let hasError: Bool
    var isLoggedIn = false
    var onRetry: (() -> Void)? = nil
    @AppStorage("paladala.materialDesign") private var materialDesign: MaterialDesign = .liquidGlass

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(description)
        } actions: {
            HStack(spacing: 10) {
                if let onRetry {
                    Button {
                        Haptics.tap()
                        onRetry()
                    } label: {
                        Label("重試", systemImage: "arrow.clockwise")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                }
                Button {
                    Haptics.tap()
                    // The bundled-fallback call is bound at the
                    // call-site (HomeView) — the empty state view
                    // itself does not know the repository. Surface
                    // the action via the environment instead.
                    NotificationCenter.default.post(name: .homeShowBundledFallback, object: nil)
                } label: {
                    Label("檢視離線樣例", systemImage: "wifi.slash")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 260)
    }

    private var title: String {
        if hasError { return "內容載入失敗" }
        if category == .follow { return isLoggedIn ? "暫無關注動態" : "關注內容需要登入" }
        if category == .live { return "暫無直播間" }
        if category == .search && searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "搜尋 Bilibili"
        }
        return "暫無影片"
    }

    private var systemImage: String {
        if category == .follow { return "person.2" }
        if category == .live { return "play.tv" }
        if category == .search { return "magnifyingglass" }
        return "play.rectangle"
    }

    private var description: String {
        if hasError { return "下拉重試或檢視離線樣例。" }
        if category == .follow {
            return isLoggedIn
                ? "當前賬號暫時沒有可展示的關注動態，下拉重新整理或稍後再試。"
                : "登入賬號後檢視關注 UP 主的影片、專欄、番劇和直播開播動態。"
        }
        if category == .live {
            return "下拉重新整理 Bilibili 公共直播列表。"
        }
        if category == .search && searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "輸入關鍵詞後載入 Bilibili 公共搜尋結果。"
        }
        return "換個關鍵詞，或切換到熱門、排行榜、分割槽內容。"
    }
}

extension Notification.Name {
    /// Posted by `HomeEmptyState` when the user taps the "查看离线
    /// 样例" button. The home view subscribes and calls
    /// `model.showBundledFallback(repository:)`. We use a
    /// notification so the empty-state view stays decoupled from
    /// the repository.
    static let homeShowBundledFallback = Notification.Name("paladala.home.showBundledFallback")
}

/// Applies Liquid Glass background to the navigation bar toolbar
/// on the home screen.
private struct HomeToolbarGlassModifier: ViewModifier {
    let materialDesign: MaterialDesign

    func body(content: Content) -> some View {
        if materialDesign == .liquidGlass {
            content.paladalaNavBarGlass(.liquidGlass)
        } else {
            content
        }
    }
}

/// Follow-tab renderer. Each card reuses the chrome shape from
/// `DynamicFeedView` (avatar row + text + optional attached video)
/// so the visual language matches the standalone 动态 tab. The list
/// also pre-fetches the next offset page when the user approaches
/// the bottom — same trigger window as `DynamicFeedView`.
private struct DynamicFeedList: View {
    let model: HomeViewModel
    let repository: PaladalaRepository
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var authStore: AuthStore

    var body: some View {
        if model.dynamicNeedsLogin {
            HomeEmptyState(
                category: .follow,
                searchQuery: "",
                hasError: false,
                isLoggedIn: authStore.isLoggedIn
            )
        } else if model.dynamicItems.isEmpty && !model.isLoading {
            HomeEmptyState(
                category: .follow,
                searchQuery: "",
                hasError: false,
                isLoggedIn: authStore.isLoggedIn
            )
        } else {
            LazyVStack(spacing: 14) {
                ForEach(Array(model.dynamicItems.enumerated()), id: \.element.id) { index, post in
                    DynamicPostCard(post: post)
                        .onAppear {
                            if index >= max(0, model.dynamicItems.count - 5) {
                                Task { await model.loadMore(repository: repository, accountMid: authStore.activeAccount?.mid ?? 0) }
                            }
                        }
                }
                if model.isLoadingMore {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
            }
        }
    }
}

/// Card chrome for a single dynamic post. Mirrors the rows in
/// `DynamicFeedView` so the follow tab and the standalone 动态 tab
/// render the same shapes — same avatar, same text, same attached
/// `VideoCard`. Kept private to this file because the public
/// `DynamicFeedView` body inlines its own copy; refactoring both to
/// share this type is the next cleanup pass once we know which shapes
/// the follow tab needs.
private struct DynamicPostCard: View {
    let post: DynamicPost
    @EnvironmentObject private var router: AppRouter
    @AppStorage("paladala.materialDesign") private var materialDesign: MaterialDesign = .liquidGlass

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                avatar
                VStack(alignment: .leading, spacing: 2) {
                    Text(post.author)
                        .font(.headline)
                    HStack(spacing: 6) {
                        Text(post.timeLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if post.kind == .liveStarted {
                            Text("· 開播")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(PaladalaTheme.biliPink)
                        } else if post.kind == .article {
                            Text("· 專欄")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        } else if post.kind == .forward {
                            Text("· 轉發")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
            }
            if !post.text.isEmpty {
                Text(post.text)
                    .font(.subheadline)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let video = post.attachedVideo {
                VideoCard(video: video, action: { router.openVideo(video) })
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .paladalaCardSurface(materialDesign)
    }

    @ViewBuilder
    private var avatar: some View {
        if let url = post.authorAvatarURL {
            ResilientImage(url: url, maximumPixelSize: 160)
                .frame(width: 42, height: 42)
                .clipShape(Rectangle())
                .overlay {
                    Rectangle()
                        .strokeBorder(
                            PaladalaTheme.ink,
                            lineWidth: PaladalaTheme.borderWidth
                        )
                }
        } else {
            Rectangle()
                .fill(PaladalaTheme.biliPink)
                .frame(width: 42, height: 42)
                .overlay(
                    Text(String(post.author.prefix(1)))
                        .font(PaladalaTheme.FontRole.cardTitle)
                        .foregroundStyle(PaladalaTheme.ink)
                )
                .overlay {
                    Rectangle()
                        .strokeBorder(
                            PaladalaTheme.ink,
                            lineWidth: PaladalaTheme.borderWidth
                        )
                }
        }
    }
}

/// One row in the `.searchSuggestions` list. Renders the raw
/// upstream HTML (with `<em class="suggest_high_light">` spans)
/// via `AttributedString` so the matched substring lights up in
/// pink. Falls back to the plain-text `displayName` if HTML
/// decoding fails (which can happen if the upstream changes its
/// highlight markup).
///
/// Note: 2026-07-10 — `.searchSuggestions` is no longer wired
/// in `HomeView` (we use `UISearchFieldBridge` instead, which
/// doesn't integrate with the system suggestion pipeline).  This
/// row type is kept for the day someone re-introduces a
/// SwiftUI-driven suggestion list beside the bridge.
private struct SuggestionRow: View {
    let suggestion: BiliSearchSuggestion

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            if let attributed = parseHighlighted() {
                Text(attributed)
                    .font(.body)
                    .lineLimit(1)
            } else {
                Text(suggestion.displayName)
                    .font(.body)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if suggestion.bvid != nil || suggestion.aid != nil {
                Image(systemName: "play.rectangle.fill")
                    .font(.caption)
                    .foregroundStyle(PaladalaTheme.biliPink)
            }
        }
        .padding(.vertical, 2)
    }

    private var iconName: String {
        if suggestion.bvid != nil { return "play.rectangle" }
        if suggestion.aid != nil { return "doc.text" }
        return "magnifyingglass"
    }

    /// Render the upstream highlight spans as a styled
    /// `AttributedString`. Returns `nil` if the HTML is
    /// malformed (e.g. upstream changed the highlight
    /// element) so the row can fall back to plain text
    /// without crashing the suggestion strip.
    private func parseHighlighted() -> AttributedString? {
        // The upstream uses `<em class="suggest_high_light">…</em>`
        // around the matched substring.  We strip every other
        // tag and keep the matched text, then wrap it in
        // `AttributedString` with a pink foreground.
        let stripped = suggestion.name.replacingOccurrences(
            of: #"<em class="suggest_high_light">"#,
            with: "",
            options: .regularExpression
        )
        let strippedEnd = stripped.replacingOccurrences(
            of: "</em>",
            with: ""
        )
        let plain = strippedEnd.replacingOccurrences(
            of: #"<[^>]+>"#,
            with: "",
            options: .regularExpression
        )
        // Find the matched range by reconstructing where the
        // open tag was — simple text search for the user's
        // current query isn't worth the extra coupling, so
        // we just render plain text in the highlight color
        // when we don't know exactly what to bold.
        var attributed = AttributedString(plain)
        if let range = attributed.range(of: plain) {
            attributed[range].foregroundColor = PaladalaTheme.biliPink
            attributed[range].font = .body.weight(.semibold)
        }
        return attributed
    }
}

/// Live keystroke-rate suggestions dropdown.  Re-introduced
/// 2026-07-10 after the `.searchable` swap dropped the
/// system `.searchSuggestions` pipeline.  Each row is a
/// `Button` so the whole row is tappable; tapping fills the
/// search field with the suggestion's `displayName` and
/// runs the same submit path the keyboard's search button
/// would have triggered.
///
/// Visual: 1.5pt ink borders + dividers + paper background,
/// matching the rest of the Street chrome.  Sits flush
/// under `UISearchFieldBridge` because both are children of
/// the same `VStack` in `searchBarSection`.
private struct SuggestionList: View {
    let suggestions: [BiliSearchSuggestion]
    let onSelect: (BiliSearchSuggestion) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(suggestions) { suggestion in
                Button {
                    onSelect(suggestion)
                } label: {
                    SuggestionRow(suggestion: suggestion)
                        .padding(.horizontal, PaladalaTheme.Spacing.l)
                        .padding(.vertical, PaladalaTheme.Spacing.s)
                }
                .buttonStyle(.plain)
                if suggestion.id != suggestions.last?.id {
                    Rectangle()
                        .fill(PaladalaTheme.ink.opacity(0.12))
                        .frame(height: PaladalaTheme.hairlineWidth)
                }
            }
        }
        .background(PaladalaTheme.paper)
        .overlay(alignment: .bottom) {
            Rectangle()
                .strokeBorder(
                    PaladalaTheme.ink,
                    lineWidth: PaladalaTheme.borderWidth
                )
        }
    }
}

