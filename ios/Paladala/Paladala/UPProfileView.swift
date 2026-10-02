import SwiftUI

/// Active sub-tab on the UP profile. The picker at the top of
/// the scroll body drives which section renders below. Stored
/// in `@AppStorage` so the user's last choice survives a
/// relaunch — most users default to `.posts` but power users
/// who drop into the "动态" / "收藏" tabs regularly get the
/// tab they were on last.
enum UPProfileTab: String, CaseIterable, Identifiable, Codable, Sendable {
    case posts
    case dynamics
    case favorites

    var id: String { rawValue }

    var title: String {
        switch self {
        case .posts: "投稿"
        case .dynamics: "動態"
        case .favorites: "收藏"
        }
    }
}

/// View model for `UPProfileView`. Drives the three independent
/// loads (card, stats, videos page 1) with `async let` so the
/// header, stats row, and video list all populate in parallel.
/// Pagination uses the same `loadMore(repository:)` shape as
/// `HistoryListViewModel` / `FavoriteFolderVideosViewModel` so
/// the future "merge into the existing account-list" refactor
/// is a copy-paste away.
///
/// v0.5.0 adds: relation status (follow button), sub-tab
/// dispatch (posts / dynamics / favorites), and per-tab
/// pagination of dynamic posts.
@MainActor
final class UPProfileViewModel: ObservableObject {
    @Published var card: BiliUserCard?
    @Published var followingCount: String = "--"
    @Published var followerCount: String = "--"
    @Published var dynamicCount: String = "--"
    @Published var videos: [BiliVideo] = []
    @Published var isLoading = false
    @Published var isLoadingMore = false
    @Published var hasMore = true
    @Published var errorMessage: String?

    // MARK: - v0.5.0 additions

    /// Relation between the signed-in user and `mid`. Defaults
    /// to `.notRelated`; refreshed alongside the other loads.
    /// The follow button reads this directly so the icon and
    /// label can flip without an extra round-trip.
    @Published var relation: BiliRelation = .notRelated
    /// `true` while a follow / unfollow request is in flight —
    /// disables the follow button so a double-tap doesn't fire
    /// two `act=1`/`act=2` POSTs in quick succession.
    @Published var isModifyingRelation = false
    /// One-shot toast for follow success / failure. `nil`
    /// clears the toast.
    @Published var relationToast: String?

    /// Dynamic posts for the `.dynamics` tab. Loaded lazily —
    /// empty until the user first switches to the tab.
    @Published var dynamicItems: [DynamicPost] = []
    @Published var isLoadingDynamics = false
    @Published var dynamicHasMore = true
    /// UP's public favorite folders. Loaded lazily too.
    @Published var favoriteFolders: [FavoriteFolderSummary] = []
    @Published var isLoadingFavorites = false

    private var nextPage = 1
    private var dynamicNextOffset: String = ""
    private let mid: Int64

    init(mid: Int64) {
        self.mid = mid
    }

    func load(repository: PaladalaRepository, selfMid: Int64 = 0) async {
        guard mid > 0 else {
            errorMessage = "無效的 UP ID"
            return
        }
        isLoading = true
        errorMessage = nil
        nextPage = 1
        // Fire the four independent reads in parallel. The
        // card fetch is the slowest (WBI-signed); the stats
        // fan-out is fast; the videos page is medium; the
        // relation check requires auth and short-circuits to
        // `.notRelated` for signed-out callers.
        async let cardResult = try? await repository.userCardInfo(mid: mid)
        async let statsResult = try? await repository.userStats(mid: mid)
        async let videosResult = (try? await repository.userVideos(mid: mid, page: 1)) ?? (videos: [], hasMore: false)
        async let relationResult = (selfMid > 0)
            ? (try? await repository.userRelation(target: mid, selfMid: selfMid)) ?? .notRelated
            : BiliRelation.notRelated

        let (loadedCard, loadedStats, loadedVideos, loadedRelation) = await (cardResult, statsResult, videosResult, relationResult)
        card = loadedCard
        if let loadedStats {
            followingCount = loadedStats.following
            followerCount = loadedStats.follower
            dynamicCount = loadedStats.dynamic
        }
        videos = loadedVideos.videos
        hasMore = loadedVideos.hasMore
        nextPage = 2
        relation = loadedRelation
        isLoading = false
    }

    func loadMore(repository: PaladalaRepository) async {
        guard !isLoading, !isLoadingMore, hasMore, mid > 0 else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await repository.userVideos(mid: mid, page: nextPage)
            // Dedupe by `bvid` so a server-side re-order between
            // pages does not produce duplicate rows. The
            // home-feed / favorites lists use the same guard.
            let seen = Set(videos.map(\.id))
            videos.append(contentsOf: page.videos.filter { !seen.contains($0.id) })
            hasMore = page.hasMore
            nextPage += 1
        } catch {
            errorMessage = "載入更多失敗"
        }
    }

    /// Lazy load of dynamic posts for the `.dynamics` tab.
    /// Runs the first page on first call, then pages on
    /// subsequent calls via `dynamicNextOffset`. `repository`
    /// is the same dependency the view model already uses —
    /// threaded through rather than pulled from a singleton
    /// so the test surface stays hermetic.
    func ensureDynamicsLoaded(repository: PaladalaRepository) async {
        // Skip if we already have items, are currently
        // loading, or have reached the end of the feed.
        // An empty list with `dynamicHasMore == true` is
        // the legitimate "load me now" trigger.
        guard dynamicItems.isEmpty, !isLoadingDynamics, dynamicHasMore else { return }
        await loadDynamics(repository: repository)
    }

    func loadDynamics(repository: PaladalaRepository) async {
        guard !isLoadingDynamics, dynamicHasMore, mid > 0 else { return }
        isLoadingDynamics = true
        defer { isLoadingDynamics = false }
        do {
            let page = try await repository.userDynamic(hostMid: mid, offset: dynamicNextOffset)
            // Dedupe by id so a server-side re-order does not
            // produce duplicates across paginated loads.
            let seen = Set(dynamicItems.map(\.id))
            dynamicItems.append(contentsOf: page.items.filter { !seen.contains($0.id) })
            dynamicHasMore = page.hasMore
            dynamicNextOffset = page.nextOffset
        } catch {
            errorMessage = "載入動態失敗"
        }
    }

    /// Lazy load of the UP's public favorite folders. The
    /// endpoint returns the full list in a single call — no
    /// pagination needed.
    func ensureFavoritesLoaded(repository: PaladalaRepository) async {
        guard !isLoadingFavorites, favoriteFolders.isEmpty, mid > 0 else { return }
        isLoadingFavorites = true
        defer { isLoadingFavorites = false }
        do {
            favoriteFolders = try await repository.userFavoriteFolders(upMid: mid)
        } catch {
            errorMessage = "載入收藏失敗"
        }
    }

    /// Toggle the follow / unfollow relation. `act = 1` to
    /// follow, `act = 2` to unfollow — Bilibili's exact codes.
    /// On success the local `relation` flips to the optimistic
    /// new value; on failure the toast surfaces the upstream
    /// error message.
    func toggleFollow(repository: PaladalaRepository) async {
        guard !isModifyingRelation, mid > 0 else { return }
        isModifyingRelation = true
        defer { isModifyingRelation = false }
        let newAct = relation.isFollowing ? 2 : 1
        // Optimistic UI flip — the round-trip is fast on Wi-Fi
        // but the user expects the icon to change immediately.
        let optimistic = relation.isFollowing ? BiliRelation.notRelated : BiliRelation.followed
        let previous = relation
        relation = optimistic
        do {
            _ = try await repository.modifyRelation(target: mid, act: newAct)
            relationToast = optimistic.isFollowing ? "已關注" : "已取消關注"
        } catch {
            relation = previous
            relationToast = "操作失敗，請重試"
        }
    }
}

/// Public profile screen for a UP (content creator). Pushed onto
/// the navigation stack by `AppRouter.openUP(mid:)` when the
/// user taps the owner name in `VideoDetailView`'s nav bar.
/// Three sub-tabs (投稿 / 动态 / 收藏) drive the section under
/// the header. Tapping a row in any section pushes another
/// destination — `VideoDetailView` for posts / attached videos,
/// `FavoriteFolderVideosView` for favorite folders.
struct UPProfileView: View {
    let mid: Int64
    let repository: PaladalaRepository

    @StateObject private var model: UPProfileViewModel
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var authStore: AuthStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("paladala.materialDesign") private var materialDesign: MaterialDesign = .liquidGlass
    @AppStorage("paladala.upProfileTab") private var storedTab: UPProfileTab = .posts
    @State private var canAutoLoadMorePosts = true

    init(mid: Int64, repository: PaladalaRepository) {
        self.mid = mid
        self.repository = repository
        _model = StateObject(wrappedValue: UPProfileViewModel(mid: mid))
    }

    /// The currently-selected sub-tab. We resolve through the
    /// `binding(...)` helper so the segmented picker and the
    /// scroll body agree on which section renders.
    private var selectedTab: UPProfileTab { storedTab }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                statsRow
                tabPicker
                Group {
                    switch selectedTab {
                    case .posts: postsSection
                    case .dynamics: dynamicsSection
                    case .favorites: favoritesSection
                    }
                }
                // `.id(...)` on the section group is what
                // makes the `withAnimation` on tab-switch
                // actually trigger a fade / slide transition.
                // Without it the switch is instantaneous and
                // SwiftUI doesn't see a state change worth
                // animating.
                .id(selectedTab)
                .transition(sectionTransition)
            }
            .padding(16)
        }
        .navigationTitle(model.card?.name ?? "UP 主")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .task {
            // `selfMid` is forwarded so the follow button can
            // know whether the signed-in user is already
            // following the UP. Signed-out callers see
            // `.notRelated` and a "关注" CTA that bounces to
            // the login sheet on tap.
            await model.load(
                repository: repository,
                selfMid: authStore.activeAccount?.mid ?? 0
            )
        }
        // Lazy-load the dynamics / favorites sections as the
        // user opens each tab. The `task(id:)` modifier
        // restarts the task whenever `selectedTab` flips,
        // which is exactly the trigger we want — switching
        // away cancels the in-flight load via structured
        // concurrency.
        .task(id: selectedTab) {
            switch selectedTab {
            case .posts:
                break
            case .dynamics:
                await model.ensureDynamicsLoaded(repository: repository)
            case .favorites:
                await model.ensureFavoritesLoaded(repository: repository)
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            // Share menu. Three actions wrapped in a single
            // `.menu` so the toolbar stays at one item
            // regardless of locale. ShareLink produces the
            // standard iOS share sheet, the other two buttons
            // mutate UIPasteboard / UIApplication directly.
            Menu {
                if let card = model.card {
                    ShareLink(
                        item: URL(string: "https://space.bilibili.com/\(card.mid)")!,
                        subject: Text(card.name)
                    ) {
                        Label("分享", systemImage: "square.and.arrow.up")
                    }
                }
                Button {
                    UIPasteboard.general.string = "\(mid)"
                    Haptics.success()
                } label: {
                    Label("複製 UID", systemImage: "doc.on.doc")
                }
                Button {
                    if let url = URL(string: "https://space.bilibili.com/\(mid)") {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("瀏覽器開啟", systemImage: "safari")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.body.weight(.medium))
            }
            .accessibilityLabel("UP 主頁更多操作")
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        if let card = model.card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 14) {
                    avatar(for: card)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Text(card.name)
                                .font(PaladalaTheme.FontRole.headline)
                                .foregroundStyle(
                                    vipBadgeNicknameColor(for: card.vipBadge)
                                        ?? PaladalaTheme.ink
                                )
                                .textCase(.uppercase)
                            if let badge = card.vipBadge, badge.isActive {
                                VipBadgeView(badge: badge, size: .standard)
                            } else if card.vipType > 0 {
                                // Legacy fallback — older persisted
                                // `BiliUserCard`s without a decoded
                                // `vipBadge` still render a chip
                                // via the cheap `vipType > 0` test
                                // the previous layout used.
                                Image(systemName: "crown.fill")
                                    .foregroundStyle(PaladalaTheme.biliPink)
                                    .accessibilityLabel("大會員")
                            }
                        }
                        Text("UID: \(card.mid)")
                            .font(PaladalaTheme.FontRole.labelMono)
                            .foregroundStyle(PaladalaTheme.mutedInk)
                        if card.level > 0 {
                            // Render the level as a small capsule so
                            // it's easy to scan. Bilibili's level is
                            // 0-6; we map it to LV1..LV6 verbatim.
                            Text("LV\(card.level)")
                                .font(PaladalaTheme.FontRole.labelMono)
                                .foregroundStyle(PaladalaTheme.ink)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(PaladalaTheme.biliPink)
                                .overlay {
                                    Rectangle()
                                        .strokeBorder(
                                            PaladalaTheme.ink,
                                            lineWidth: PaladalaTheme.hairlineWidth
                                        )
                                }
                        }
                    }
                    Spacer()
                    followButton
                }
                if !card.sign.isEmpty {
                    Text(card.sign)
                        .font(PaladalaTheme.FontRole.bodySmall)
                        .foregroundStyle(PaladalaTheme.mutedInk)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
            }
            .padding(14)
            .paladalaCardSurface(materialDesign)
        } else if model.isLoading {
            HStack(spacing: 14) {
                Rectangle()
                    .fill(PaladalaTheme.coolGray)
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 8) {
                    Rectangle()
                        .fill(PaladalaTheme.coolGray)
                        .frame(width: 120, height: 16)
                    Rectangle()
                        .fill(PaladalaTheme.coolGray)
                        .frame(width: 80, height: 12)
                }
                Spacer()
            }
            .paladalaShimmer()
            .padding(14)
            .paladalaCardSurface(materialDesign)
        } else if let error = model.errorMessage {
            // The card fetch failed but the videos might still
            // load. Show a small inline banner rather than
            // swallowing the error.
            Text(error)
                .font(.subheadline)
                .foregroundStyle(PaladalaTheme.biliPink)
                .padding(14)
                .paladalaCardSurface(materialDesign)
        }
        // Toast for follow success / failure. Renders as a
        // small floating label below the header; clears
        // itself after 1.6s via a Task spawned by the model.
        if let toast = model.relationToast {
            Text(toast)
                .font(PaladalaTheme.FontRole.labelMono)
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.black.opacity(0.84))
                .overlay {
                    Rectangle().strokeBorder(.white, lineWidth: 1)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
                .task(id: toast) {
                    try? await Task.sleep(nanoseconds: 1_600_000_000)
                    if model.relationToast == toast {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            model.relationToast = nil
                        }
                    }
                }
        }
    }

    @ViewBuilder
    private func avatar(for card: BiliUserCard) -> some View {
        if let url = card.faceURL {
            ResilientImage(url: url, maximumPixelSize: 192)
                .frame(width: 64, height: 64)
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
                .frame(width: 64, height: 64)
                .overlay(
                    Image(systemName: "person.fill")
                        .font(.title)
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

    // MARK: - Follow button

    @ViewBuilder
    private var followButton: some View {
        // Four states: signed-out (no relation, tap → login
        // sheet), not-following (CTA "关注"), already-
        // following ("已关注" with a checkmark), blocked
        // ("已拉黑" disabled). Each gets a distinct visual
        // so the user can tell at a glance which side of
        // the relation they're on.
        let isLoggedIn = authStore.activeAccount != nil
        let isBlocked = model.relation == .blocked
        let isFollowing = model.relation.isFollowing
        let title: String = {
            if isBlocked { return "已拉黑" }
            if !isLoggedIn { return "關注" }
            return isFollowing ? "已關注" : "關注"
        }()
        let symbol: String = isBlocked
            ? "hand.raised.slash"
            : (isFollowing ? "checkmark" : "plus")
        Button {
            Haptics.tap()
            if !isLoggedIn {
                router.openLogin()
                return
            }
            // Blocked users can't toggle from the client —
            // Bilibili's `/x/relation/modify` rejects with
            // -102 when the target is on the user's block
            // list. We refuse to even try.
            guard !isBlocked else { return }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                model.relationToast = nil
            }
            Task { await model.toggleFollow(repository: repository) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.caption.weight(.bold))
                Text(title)
                    .font(PaladalaTheme.FontRole.labelMono)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .foregroundStyle(
                isBlocked
                    ? PaladalaTheme.mutedInk
                    : PaladalaTheme.ink
            )
            .background {
                Rectangle()
                    .fill(
                        isBlocked
                            ? PaladalaTheme.coolGray
                            : (isFollowing ? PaladalaTheme.paper : PaladalaTheme.biliPink)
                    )
            }
            .overlay {
                Rectangle()
                    .strokeBorder(
                        PaladalaTheme.ink,
                        lineWidth: PaladalaTheme.borderWidth
                    )
            }
        }
        .buttonStyle(PaladalaPressBounceButtonStyle())
        .disabled(model.isModifyingRelation || isBlocked)
        .opacity(model.isModifyingRelation ? 0.55 : 1.0)
        .animation(.easeInOut(duration: 0.18), value: model.relation)
        .animation(.easeInOut(duration: 0.18), value: model.isModifyingRelation)
    }

    // MARK: - Stats

    /// Stat pills row. 粉丝 and 关注 display public counts;
    /// 动态 is interactive and switches to the `.dynamics`
    /// sub-tab so the count and content live next to each other.
    private var statsRow: some View {
        HStack(spacing: 8) {
            statPill(
                label: "粉絲",
                value: model.followerCount,
                systemImage: "person.2",
                interactive: false
            )
            statPill(
                label: "關注",
                value: model.followingCount,
                systemImage: "person.crop.circle.badge.checkmark",
                interactive: false
            )
            statPill(
                label: "動態",
                value: model.dynamicCount,
                systemImage: "rectangle.stack",
                interactive: true,
                action: { switchTab(.dynamics) }
            )
        }
        .padding(14)
        .paladalaCardSurface(materialDesign)
    }

    private func statPill(
        label: String,
        value: String,
        systemImage: String,
        interactive: Bool,
        action: (() -> Void)? = nil
    ) -> some View {
        let content = HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.caption.weight(.black))
                .foregroundStyle(PaladalaTheme.ink)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(PaladalaTheme.FontRole.cardTitle)
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())
                Text(label)
                    .font(PaladalaTheme.FontRole.labelMono)
                    .foregroundStyle(PaladalaTheme.mutedInk)
            }
            Spacer(minLength: 0)
            if interactive {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .background(PaladalaTheme.coolGray)
        .overlay {
            Rectangle()
                .strokeBorder(PaladalaTheme.ink, lineWidth: PaladalaTheme.hairlineWidth)
        }
        // Tappable pills wrap in a Button so the user gets a
        // built-in hit target + accessibility affordance;
        // non-interactive pills render as plain VStack to
        // avoid a phantom button frame.
        return Group {
            if interactive, let action {
                Button {
                    Haptics.selection()
                    action()
                } label: {
                    content
                }
                .buttonStyle(PaladalaPressBounceButtonStyle())
            } else {
                content
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func switchTab(_ tab: UPProfileTab) {
        guard storedTab != tab else { return }
        let animation: Animation? = reduceMotion
            ? .easeInOut(duration: 0.16)
            : .spring(response: 0.32, dampingFraction: 0.85)
        withAnimation(animation) {
            storedTab = tab
        }
    }

    private var sectionTransition: AnyTransition {
        if reduceMotion {
            return .opacity
        }
        return .asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity),
            removal: .opacity
        )
    }

    // MARK: - Tab picker

    private var tabPicker: some View {
        HStack(spacing: 8) {
            ForEach(UPProfileTab.allCases) { tab in
                Button {
                    switchTab(tab)
                } label: {
                    Text(tab.title)
                        .font(PaladalaTheme.FontRole.labelMono)
                        .frame(maxWidth: .infinity, minHeight: 42)
                }
                .buttonStyle(.plain)
                .paladalaSelectionChip(
                    isSelected: storedTab == tab,
                    design: materialDesign
                )
            }
        }
        .accessibilityLabel("UP 主頁分頁")
    }

    // MARK: - Posts section

    @ViewBuilder
    private var postsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("投稿")
                    .font(PaladalaTheme.FontRole.sectionHeader)
                    .textCase(.uppercase)
                Spacer()
                if model.isLoadingMore {
                    ProgressView().controlSize(.small)
                }
            }
            if let error = model.errorMessage, model.videos.isEmpty {
                ErrorBanner(message: error)
            } else if model.videos.isEmpty && model.isLoading {
                ForEach(0..<3, id: \.self) { _ in
                    rowSkeleton
                }
            } else if model.videos.isEmpty {
                ContentUnavailableView(
                    "暫無投稿",
                    systemImage: "film.stack",
                    description: Text("該 UP 暫未釋出影片，或資料載入失敗。")
                )
                .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.videos.enumerated()), id: \.element.id) { index, video in
                        NavigationLink(value: video) {
                            UPVideoListRow(video: video)
                        }
                        .buttonStyle(PaladalaPressBounceButtonStyle())
                        if video.id != model.videos.last?.id {
                            Divider()
                                .padding(.leading, UPVideoListRow.thumbnailWidth + 12)
                        }
                    }
                }
                postsLoadMoreFooter
            }
        }
        .padding(14)
        .paladalaCardSurface(materialDesign)
    }

    @ViewBuilder
    private var postsLoadMoreFooter: some View {
        if model.isLoadingMore {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("載入更多…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        } else if model.hasMore && !model.videos.isEmpty {
            Button {
                Haptics.selection()
                Task { await model.loadMore(repository: repository) }
            } label: {
                Label("載入更多影片", systemImage: "arrow.down.circle")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(PaladalaGlassButtonStyle(materialDesign: materialDesign))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .onAppear {
                guard canAutoLoadMorePosts else { return }
                canAutoLoadMorePosts = false
                Task { await model.loadMore(repository: repository) }
            }
            .onDisappear {
                canAutoLoadMorePosts = true
            }
        } else if !model.hasMore && !model.videos.isEmpty {
            Text("— 沒有更多了 —")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
    }

    private var rowSkeleton: some View {
        HStack(spacing: 12) {
            Rectangle()
                .fill(PaladalaTheme.coolGray)
                .frame(width: 112, height: 70)
            VStack(alignment: .leading, spacing: 6) {
                Rectangle()
                    .fill(PaladalaTheme.coolGray)
                    .frame(height: 12)
                Rectangle()
                    .fill(PaladalaTheme.coolGray)
                    .frame(width: 180, height: 12)
                Rectangle()
                    .fill(PaladalaTheme.coolGray)
                    .frame(width: 90, height: 10)
            }
        }
        .paladalaShimmer()
    }

    // MARK: - Dynamics section

    @ViewBuilder
    private var dynamicsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("動態")
                    .font(PaladalaTheme.FontRole.sectionHeader)
                    .textCase(.uppercase)
                Spacer()
                if model.isLoadingDynamics {
                    ProgressView().controlSize(.small)
                }
            }
            if model.dynamicItems.isEmpty && model.isLoadingDynamics {
                ForEach(0..<3, id: \.self) { _ in
                    dynamicRowSkeleton
                }
            } else if model.dynamicItems.isEmpty {
                ContentUnavailableView(
                    "暫無動態",
                    systemImage: "rectangle.stack.badge.minus",
                    description: Text("該 UP 暫未釋出動態，或動態載入失敗。")
                )
                .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                ForEach(Array(model.dynamicItems.enumerated()), id: \.element.id) { index, post in
                    DynamicCardRow(post: post, repository: repository)
                    // Same infinite-scroll lookahead as
                    // `postsSection` — within the last 4 items
                    // (dynamic posts are bigger than video
                    // rows, so the buffer can be smaller).
                    if model.dynamicHasMore, index >= model.dynamicItems.count - 4 {
                        Color.clear
                            .frame(height: 1)
                            .onAppear {
                                Task { await model.loadDynamics(repository: repository) }
                            }
                    }
                    if post.id != model.dynamicItems.last?.id {
                        Divider()
                    }
                }
                if model.isLoadingDynamics {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("載入更多…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                } else if !model.dynamicHasMore && !model.dynamicItems.isEmpty {
                    Text("— 沒有更多了 —")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
            }
        }
        .padding(14)
        .paladalaCardSurface(materialDesign)
    }

    private var dynamicRowSkeleton: some View {
        HStack(alignment: .top, spacing: 12) {
            Rectangle()
                .fill(PaladalaTheme.coolGray)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 6) {
                Rectangle()
                    .fill(PaladalaTheme.coolGray)
                    .frame(width: 120, height: 12)
                Rectangle()
                    .fill(PaladalaTheme.coolGray)
                    .frame(maxWidth: .infinity)
                    .frame(height: 12)
            }
        }
        .paladalaShimmer()
    }

    // MARK: - Favorites section

    @ViewBuilder
    private var favoritesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("收藏")
                    .font(PaladalaTheme.FontRole.sectionHeader)
                    .textCase(.uppercase)
                Spacer()
                if model.isLoadingFavorites {
                    ProgressView().controlSize(.small)
                }
            }
            if model.favoriteFolders.isEmpty && model.isLoadingFavorites {
                ForEach(0..<3, id: \.self) { _ in
                    folderSkeleton
                }
            } else if model.favoriteFolders.isEmpty {
                ContentUnavailableView(
                    "暫無公開收藏",
                    systemImage: "folder.badge.questionmark",
                    description: Text("該 UP 沒有公開收藏夾。")
                )
                .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                ForEach(model.favoriteFolders) { folder in
                    NavigationLink(value: ProfileRoute.favoriteFolder(folder)) {
                        folderRow(folder)
                    }
                    .buttonStyle(PaladalaPressBounceButtonStyle())
                    if folder.id != model.favoriteFolders.last?.id {
                        Divider()
                    }
                }
            }
        }
        .padding(14)
        .paladalaCardSurface(materialDesign)
    }

    @ViewBuilder
    private func folderRow(_ folder: FavoriteFolderSummary) -> some View {
        HStack(spacing: 12) {
            ResilientImage(url: folder.coverURL, maximumPixelSize: 256)
                .frame(width: 64, height: 64)
                .clipShape(Rectangle())
                .overlay {
                    Rectangle()
                        .strokeBorder(
                            PaladalaTheme.ink,
                            lineWidth: PaladalaTheme.borderWidth
                        )
                }
            VStack(alignment: .leading, spacing: 4) {
                Text(folder.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("\(folder.mediaCount) 個影片")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if !folder.ownerName.isEmpty {
                    Text(folder.ownerName)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var folderSkeleton: some View {
        HStack(spacing: 12) {
            Rectangle()
                .fill(PaladalaTheme.coolGray)
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 6) {
                Rectangle()
                    .fill(PaladalaTheme.coolGray)
                    .frame(width: 140, height: 14)
                Rectangle()
                    .fill(PaladalaTheme.coolGray)
                    .frame(width: 80, height: 10)
            }
        }
        .paladalaShimmer()
    }
}

/// One dynamic card in the UP profile's "动态" sub-tab.
/// Pulled out of the parent so the same chrome is reusable
/// when v0.6 adds a "热门动态" tab on the follow feed.
private struct DynamicCardRow: View {
    let post: DynamicPost
    let repository: PaladalaRepository
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                avatar
                VStack(alignment: .leading, spacing: 2) {
                    Text(post.author)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(post.timeLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            if !post.text.isEmpty {
                Text(post.text)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let video = post.attachedVideo {
                NavigationLink(value: video) {
                    UPVideoListRow(video: video)
                }
                .buttonStyle(PaladalaPressBounceButtonStyle())
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var avatar: some View {
        if let url = post.authorAvatarURL {
            ResilientImage(url: url, maximumPixelSize: 144)
                .frame(width: 36, height: 36)
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
                .frame(width: 36, height: 36)
                .overlay(
                    Image(systemName: "person.fill")
                        .font(.caption)
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

/// One row in the published-videos list. Mirrors
/// `AccountContentViews.VideoListRow` but is local to this file
/// because the latter is `private` to its enclosing file and
/// the two will diverge (this one drops the subtitle because
/// we already know the owner — every row here is by the same UP).
private struct UPVideoListRow: View {
    let video: BiliVideo
    static let thumbnailWidth: CGFloat = 112
    private static let thumbnailHeight: CGFloat = 70
    private static let rowHeight: CGFloat = 86

    var body: some View {
        HStack(spacing: 12) {
            ResilientImage(url: video.coverURL, maximumPixelSize: 480)
                .frame(width: Self.thumbnailWidth, height: Self.thumbnailHeight)
                .clipShape(Rectangle())
                .overlay {
                    Rectangle()
                        .strokeBorder(
                            PaladalaTheme.ink,
                            lineWidth: PaladalaTheme.borderWidth
                        )
                }
            VStack(alignment: .leading, spacing: 6) {
                Text(video.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                HStack(spacing: 10) {
                    Label(video.viewCount.compactCount, systemImage: "play.fill")
                    Label(video.danmakuCount.compactCount, systemImage: "text.bubble")
                    Spacer(minLength: 0)
                    if video.duration > 0 {
                        Text(video.duration.mmss)
                            .monospacedDigit()
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .frame(maxHeight: Self.thumbnailHeight, alignment: .top)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: Self.rowHeight, maxHeight: Self.rowHeight, alignment: .center)
        .contentShape(Rectangle())
    }
}
