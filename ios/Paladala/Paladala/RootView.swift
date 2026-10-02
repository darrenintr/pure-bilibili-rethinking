import SwiftUI

struct RootView: View {
    let repository: PaladalaRepository

    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var networkMonitor: NetworkMonitor
    @EnvironmentObject private var miniPlayerStore: MiniPlayerStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("paladala.didOnboard") private var didOnboard: Bool = false
    /// Timestamp of the most recent transition out of `.active`
    /// (i.e. when the user locked the screen or switched apps).
    /// Used by the `scenePhase` change handler to decide whether
    /// the upcoming `.active` is a "long" background — if it
    /// is, we tear down `LocalHLSProxyServer` so the next
    /// `serve(playback:)` starts on a fresh port.  Without
    /// this the user gets a stuck spinner and `NSURLError
    /// -1004 "Could not connect to the server."` for every
    /// video they try to play after the screen has been
    /// locked for more than a few seconds.
    @State private var lastBackgroundAt: Date?
    /// One-shot gate for the OnboardingView presentation.
    /// Flipped to `true` from `onAppear` so the
    /// `fullScreenCover` binding only evaluates after the
    /// first frame has rendered.  Previously the binding
    /// was `!didOnboard` evaluated on every body call —
    /// that pushed the OnboardingView onto the screen
    /// before any other init could claim the first frame.
    @State private var hasPresentedFirstFrame: Bool = false
    /// One-shot app opening overlay. It is mounted above the
    /// root shell only for the first launch moment, then removed
    /// from the hierarchy so it cannot intercept navigation,
    /// sheets, or video gestures.
    @State private var isOpeningAnimationVisible: Bool = true
    /// The threshold above which a background → foreground
    /// transition is treated as "long" and triggers a proxy
    /// teardown.  Picked at 5 s: shorter than that and we
    /// would race the user's own quick app-switches; longer
    /// than that and iOS has had time to suspend the
    /// `NWListener` and the upstream `URLSession` leg.
    private static let longBackgroundThreshold: TimeInterval = 5

    /// Mirror of `networkMonitor.isOnline` so the `RootView.body`
    /// re-evaluates when connectivity changes. We don't observe the
    /// published value directly in the modifier because `.animation`
    /// takes an `Equatable` value, not a binding.
    private var networkMonitorIsOnline: Bool { networkMonitor.isOnline }

    var body: some View {
        ZStack {
            PaladalaTheme.canvas
                .ignoresSafeArea()

            Group {
                if horizontalSizeClass == .regular {
                    PadRootView(repository: repository)
                } else {
                    PhoneRootView(repository: repository)
                }
            }
        }
        .onAppear {
            // First frame has been rendered.  This is the
            // canonical "time to first frame" anchor — anything
            // visible on screen from here onward is post-load
            // and gets attributed to interactive time, not
            // cold-start time.
            LaunchMetrics.shared.mark(.firstRootViewAppeared)
            router.consumePendingIntentRoute()
            // Flip the OnboardingView gate so the fullScreenCover
            // can present after this frame.  Deferred from
            // initial body eval so a fresh launch that hasn't
            // onboarded yet doesn't pay the OnboardingView
            // construction cost on the cold-start critical path.
            if !hasPresentedFirstFrame {
                hasPresentedFirstFrame = true
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                // Recreate the local HLS proxy on the long
                // background → foreground path.  iOS suspends
                // the `NWListener` and the upstream
                // `URLSession` legs while we are backgrounded;
                // the listener's `state` callback never fires
                // `.cancelled`, so the proxy stays alive-but-
                // dead and every video opened after a long
                // lock screen fails with `NSURLError -1004`.
                // Tearing the proxy down here forces the
                // next `serve(playback:)` to allocate a new
                // port and a fresh upstream session.
                let backgroundDuration: TimeInterval? =
                    lastBackgroundAt.map {
                        Date().timeIntervalSince($0)
                    }
                let wasLong = (backgroundDuration ?? 0)
                    >= Self.longBackgroundThreshold
                diagLog(.lifecycle, "app.foreground", details: [
                    "backgroundSeconds":
                        backgroundDuration.map { String(format: "%.2f", $0) }
                            ?? "unknown",
                    "longBackground": wasLong
                ])
                if wasLong {
                    LocalHLSProxyServer.shared.recreateForResume()
                }
                lastBackgroundAt = nil
                Analytics.log("app_foreground")
                router.consumePendingIntentRoute()
            case .background:
                lastBackgroundAt = Date()
                diagLog(.lifecycle, "app.background")
                Analytics.log("app_background")
            case .inactive:
                diagLog(.lifecycle, "app.inactive")
                Analytics.log("app_inactive")
            @unknown default:
                break
            }
        }
        .onOpenURL { url in
            handle(url)
        }
        .sheet(isPresented: $router.isLoginSheetPresented) {
            // Apple's iOS 26 sheet guidance: surface a drag
            // indicator so the user can see the sheet is
            // dismissable without first trying to drag. The
            // explicit "关闭" toolbar button is the primary
            // dismiss affordance; the indicator is the
            // secondary gesture affordance.
            LoginSheet()
                .presentationDragIndicator(.visible)
                .presentationBackground(PaladalaTheme.paper)
                .presentationCornerRadius(0)
        }
        .paladalaToggleStyle()
        .modifier(StreetTabBarModifier())
        .fullScreenCover(isPresented: Binding(
            get: { hasPresentedFirstFrame && !didOnboard },
            set: { newValue in
                if newValue == false { didOnboard = true }
            }
        )) {
            OnboardingView()
        }
        .overlay(alignment: .top) {
            OfflineBanner()
                .animation(.easeOut(duration: 0.18),
                           value: networkMonitorIsOnline)
        }
        .overlay(alignment: .bottomTrailing) {
            // Pad the mini-player off the tab bar and the safe area.
            // 16pt on the trailing edge, 80pt on the bottom (above
            // the tab bar's glass chrome). On iPad we offset further
            // so the overlay doesn't collide with the sidebar's
            // resize handle.
            HStack {
                Spacer(minLength: 16)
                MiniPlayerOverlay()
                    .frame(maxWidth: horizontalSizeClass == .regular ? 360 : 340)
            }
            .padding(.trailing, horizontalSizeClass == .regular ? 32 : 16)
            .padding(.bottom, horizontalSizeClass == .regular ? 32 : 80)
            .animation(.easeOut(duration: 0.18),
                       value: miniPlayerIsShowing)
        }
        .overlay {
            if isOpeningAnimationVisible {
                OpeningScreenAnimation {
                    isOpeningAnimationVisible = false
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
    }

    /// Mirror of `miniPlayerStore.isShowingMiniPlayer` so the
    /// overlay's animation key is value-based, not environment-based.
    private var miniPlayerIsShowing: Bool {
        miniPlayerStore.isShowingMiniPlayer
    }

    private func handle(_ url: URL) {
        guard url.scheme == "paladala" || url.scheme == "paladala" else { return }
        switch url.host {
        case "home":
            router.open(.home)
        case "dynamic":
            router.open(.dynamic)
        case "live":
            router.open(.live)
        case "music":
            router.open(.home)
        case "settings":
            router.open(.profile)
        case "search":
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "q" })?
                .value ?? ""
            router.openSearch(query)
        case "login":
            router.openLogin()
        case "up":
            // `paladala://up/<mid>` deep link — resolve the
            // numeric mid from the first path component and
            // push the UP profile. Falls through silently on
            // a non-numeric mid so a malformed URL never
            // crashes the app.
            let mid = Int64(url.pathComponents.first(where: { $0 != "/" }) ?? "")
            if let mid, mid > 0 {
                router.openUP(mid: mid)
            }
        default:
            break
        }
    }
}

private struct OpeningScreenAnimation: View {
    let onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tileScale: CGFloat = 0.88
    @State private var tileOffset: CGFloat = 18
    @State private var tileOpacity: Double = 0
    @State private var playScale: CGFloat = 0.8
    @State private var playOpacity: Double = 0
    @State private var titleOffset: CGFloat = 14
    @State private var titleOpacity: Double = 0
    @State private var accentProgress: CGFloat = 0
    @State private var screenOpacity: Double = 1

    var body: some View {
        GeometryReader { geo in
            ZStack {
                background

                VStack(alignment: .leading, spacing: PaladalaTheme.Spacing.xxl) {
                    ZStack {
                        Rectangle()
                            .fill(PaladalaTheme.ink)
                            .frame(width: 118, height: 118)
                            .offset(
                                x: PaladalaTheme.hardShadowOffset,
                                y: PaladalaTheme.hardShadowOffset
                            )

                        Rectangle()
                            .fill(PaladalaTheme.biliPink)
                            .frame(width: 118, height: 118)
                            .overlay {
                                Rectangle()
                                    .strokeBorder(
                                        PaladalaTheme.ink,
                                        lineWidth: PaladalaTheme.borderWidth
                                    )
                            }

                        Image(systemName: "play.fill")
                            .font(.system(size: 42, weight: .black))
                            .foregroundStyle(PaladalaTheme.ink)
                            .offset(x: 3)
                            .scaleEffect(playScale)
                            .opacity(playOpacity)

                        Text("PLAY")
                            .font(PaladalaTheme.FontRole.labelMono)
                            .foregroundStyle(PaladalaTheme.paper)
                            .padding(.horizontal, PaladalaTheme.Spacing.s)
                            .padding(.vertical, PaladalaTheme.Spacing.xs)
                            .background(PaladalaTheme.ink)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                            .padding(PaladalaTheme.Spacing.s)
                    }
                    .frame(width: 118, height: 118)
                    .scaleEffect(tileScale)
                    .offset(y: tileOffset)
                    .opacity(tileOpacity)

                    VStack(alignment: .leading, spacing: PaladalaTheme.Spacing.s) {
                        Text("PALADALA")
                            .font(PaladalaTheme.FontRole.displayMedium)
                            .foregroundStyle(PaladalaTheme.ink)
                            .tracking(-1)

                        Text("PURE BILIBILI // NATIVE IOS")
                            .font(PaladalaTheme.FontRole.labelMono)
                            .foregroundStyle(PaladalaTheme.paper)
                            .padding(.horizontal, PaladalaTheme.Spacing.s)
                            .padding(.vertical, PaladalaTheme.Spacing.xs)
                            .background(PaladalaTheme.ink)

                        HStack(spacing: 0) {
                            Rectangle()
                                .fill(PaladalaTheme.biliPink)
                                .frame(width: 74, height: 7)
                            Rectangle()
                                .fill(PaladalaTheme.ink)
                                .frame(width: 32, height: 7)
                        }
                        .scaleEffect(x: accentProgress, anchor: .leading)
                    }
                    .opacity(titleOpacity)
                    .offset(y: titleOffset)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .padding(.horizontal, PaladalaTheme.Spacing.xxxl)
                .padding(.bottom, geo.safeAreaInsets.bottom + PaladalaTheme.Spacing.xxl)
            }
            .opacity(screenOpacity)
            .ignoresSafeArea()
        }
        .onAppear { run() }
    }

    private var background: some View {
        ZStack {
            PaladalaTheme.canvas

            VStack(spacing: 0) {
                HStack {
                    Text("/// SIGNAL_01")
                        .font(PaladalaTheme.FontRole.labelMono)
                        .foregroundStyle(PaladalaTheme.paper)
                    Spacer()
                    Text("PALADALA")
                        .font(PaladalaTheme.FontRole.labelMono)
                        .foregroundStyle(PaladalaTheme.paper)
                }
                .padding(.horizontal, PaladalaTheme.Spacing.l)
                .frame(height: 34)
                .background(PaladalaTheme.ink)

                Spacer()

                HStack(spacing: PaladalaTheme.Spacing.s) {
                    Rectangle()
                        .fill(PaladalaTheme.biliPink)
                        .frame(maxWidth: .infinity)
                        .frame(height: 7)
                    Rectangle()
                        .fill(PaladalaTheme.ink)
                        .frame(width: 46, height: 7)
                }
                .padding(.horizontal, PaladalaTheme.Spacing.l)
                .padding(.bottom, PaladalaTheme.Spacing.l)
                .scaleEffect(x: accentProgress, anchor: .leading)
            }
        }
    }

    private func run() {
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.18)) {
                tileOpacity = 1
                playOpacity = 1
                titleOpacity = 1
                titleOffset = 0
                tileScale = 1
                tileOffset = 0
                playScale = 1
                accentProgress = 1
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 650_000_000)
                withAnimation(.easeOut(duration: 0.18)) {
                    screenOpacity = 0
                }
                try? await Task.sleep(nanoseconds: 180_000_000)
                onFinished()
            }
            return
        }

        withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) {
            tileOpacity = 1
            tileScale = 1
            tileOffset = 0
        }
        withAnimation(.spring(response: 0.36, dampingFraction: 0.68).delay(0.12)) {
            playOpacity = 1
            playScale = 1
        }
        withAnimation(.easeOut(duration: 0.32).delay(0.18)) {
            titleOpacity = 1
            titleOffset = 0
        }
        withAnimation(.easeInOut(duration: 0.42).delay(0.24)) {
            accentProgress = 1
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_250_000_000)
            withAnimation(.easeInOut(duration: 0.32)) {
                screenOpacity = 0
                tileScale = 1.04
            }
            try? await Task.sleep(nanoseconds: 340_000_000)
            onFinished()
        }
    }
}

private struct PhoneRootView: View {
    let repository: PaladalaRepository
    @EnvironmentObject private var router: AppRouter
    /// Single shared namespace for the hero / zoom transition
    /// between the feed grids and `VideoDetailView`. Declared
    /// at the nav-stack root so the same namespace is visible
    /// to both the source (cards in the feed tabs) and the
    /// destination (`VideoDetailView`).
    @Namespace private var heroNamespace

    var body: some View {
        NavigationStack(path: $router.path) {
            TabView(selection: $router.selectedTab) {
                // Each tab body is wrapped in LazyTab so the inner
                // View (and its `@StateObject` / @State) is only
                // constructed when the user first selects that tab.
                // State is preserved across tab switches via the
                // wrapper's own @State, so going to Settings and back
                // does not re-init HomeView. PR-A, audit #5.
                LazyTab(tag: MainTab.home, activeTag: router.selectedTab) {
                    HomeView(repository: repository, heroNamespace: heroNamespace)
                }
                .tabItem {
                    // Apple's recommended "select bounce" — the
                    // SF Symbol scales up + back down when the
                    // value flips. Previously the binder was
                    // `selectedTab` itself, which made every
                    // tab icon observe the same value and
                    // bounce on every switch. The bool
                    // per-tab now flips only for the freshly
                    // selected one, matching HIG.
                    Label {
                        Text(MainTab.home.title)
                    } icon: {
                        Image(systemName: MainTab.home.symbolName)
                            .symbolEffect(.bounce, value: router.selectedTab == MainTab.home)
                    }
                }
                .tag(MainTab.home)

                LazyTab(tag: MainTab.dynamic, activeTag: router.selectedTab) {
                    DynamicFeedView(repository: repository, heroNamespace: heroNamespace)
                }
                .tabItem {
                    Label {
                        Text(MainTab.dynamic.title)
                    } icon: {
                        Image(systemName: MainTab.dynamic.symbolName)
                            .symbolEffect(.bounce, value: router.selectedTab == MainTab.dynamic)
                    }
                }
                .tag(MainTab.dynamic)

                LazyTab(tag: MainTab.live, activeTag: router.selectedTab) {
                    LiveRoomsView(repository: repository)
                }
                .tabItem {
                    Label {
                        Text(MainTab.live.title)
                    } icon: {
                        Image(systemName: MainTab.live.symbolName)
                            .symbolEffect(.bounce, value: router.selectedTab == MainTab.live)
                    }
                }
                .tag(MainTab.live)

                LazyTab(tag: MainTab.profile, activeTag: router.selectedTab) {
                    ProfileSettingsView(repository: repository)
                }
                .tabItem {
                    Label {
                        Text(MainTab.profile.title)
                    } icon: {
                        Image(systemName: MainTab.profile.symbolName)
                            .symbolEffect(.bounce, value: router.selectedTab == MainTab.profile)
                    }
                }
                .tag(MainTab.profile)
            }
            .paladalaTabBarBehavior()
            .navigationDestination(for: BiliVideo.self) { video in
                VideoDetailView(video: video, repository: repository, heroNamespace: heroNamespace)
            }
            .navigationDestination(for: ProfileRoute.self) { route in
                profileRouteView(route, repository: repository)
            }
            .navigationDestination(for: ReplyRoute.self) { route in
                ReplyListView(video: route.video, rootComment: route.rootComment, repository: repository)
            }
            .navigationDestination(for: LocalVideoRoute.self) { route in
                switch route {
                case .local(let record):
                    VideoDetailView(
                        video: record.video,
                        repository: repository,
                        heroNamespace: heroNamespace,
                        localRecord: record
                    )
                }
            }
            .navigationDestination(for: BangumiRoute.self) { route in
                switch route {
                case .timeline:
                    BangumiHomeView(repository: repository, heroNamespace: heroNamespace)
                case .seasonDetail(let seasonId):
                    BangumiSeasonDetailView(
                        repository: repository,
                        seasonId: seasonId
                    )
                }
            }
            .navigationDestination(for: UPProfileRoute.self) { route in
                switch route {
                case .up(let mid):
                    UPProfileView(mid: mid, repository: repository)
                }
            }
        }
        // System-provided interactive pop gesture handles back
        // navigation; `NavigationStack` (iOS 16+) ships with
        // swipe-from-edge built in. No custom gesture needed.
    }
}

private struct PadRootView: View {
    let repository: PaladalaRepository
    @EnvironmentObject private var router: AppRouter
    /// Single shared namespace for the hero / zoom transition.
    @Namespace private var heroNamespace
    /// Sidebar visibility. The collapse button flips this to
    /// `.detailOnly`; the system chevron / drag handle brings it
    /// back to `.all`. `NavigationSplitView` owns the actual
    /// show/hide animation — we just hand it a binding.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    /// Tabs rendered in the sidebar's main list. Excludes `.profile`
    /// because the new design surfaces 我的 as a user card at the
    /// bottom of the sidebar instead of a regular row. The five-case
    /// `MainTab` enum stays unchanged so the phone tab bar keeps
    /// working.
    private static let sidebarTabs: [MainTab] = [.home, .dynamic, .live]

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            PadSidebar(
                tabs: Self.sidebarTabs,
                columnVisibility: $columnVisibility
            )
            .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 320)
        } detail: {
            NavigationStack(path: $router.path) {
                selectedView
                    .navigationDestination(for: BiliVideo.self) { video in
                        VideoDetailView(video: video, repository: repository, heroNamespace: heroNamespace)
                    }
                    .navigationDestination(for: ProfileRoute.self) { route in
                        profileRouteView(route, repository: repository)
                    }
                    .navigationDestination(for: ReplyRoute.self) { route in
                        ReplyListView(video: route.video, rootComment: route.rootComment, repository: repository)
                    }
                    .navigationDestination(for: LocalVideoRoute.self) { route in
                        switch route {
                        case .local(let record):
                            VideoDetailView(
                                video: record.video,
                                repository: repository,
                                heroNamespace: heroNamespace,
                                localRecord: record
                            )
                        }
                    }
                    .navigationDestination(for: BangumiRoute.self) { route in
                        switch route {
                        case .timeline:
                            BangumiHomeView(repository: repository, heroNamespace: heroNamespace)
                        case .seasonDetail(let seasonId):
                            BangumiSeasonDetailView(
                                repository: repository,
                                seasonId: seasonId
                            )
                        }
                    }
                    .navigationDestination(for: UPProfileRoute.self) { route in
                        switch route {
                        case .up(let mid):
                            UPProfileView(mid: mid, repository: repository)
                        }
                    }
            }
            // System-provided interactive pop gesture handles
            // back navigation; no custom recognizer needed.
        }
    }

    @ViewBuilder
    private var selectedView: some View {
        // Wrap the tab content in a ZStack keyed by `router.selectedTab`
        // so swapping tabs animates the outgoing / incoming view
        // with a crossfade + slide instead of a hard cut.  The
        // `.id(...)` on the inner view forces SwiftUI to discard the
        // previous tab's state (scroll position, async tasks) which
        // also fixes the "iPad sidebar tap doesn't switch" symptom —
        // without the id the navigation stack would sometimes keep
        // showing the prior destination when both tabs route to the
        // same `NavigationStack` shape.
        //
        // iPad column count: 3 when the sidebar is hidden
        // (`.detailOnly` / `.doubleColumn`-ish), 2 when it is
        // visible.  Threaded down to `HomeView` so the video grid
        // re-flows on sidebar collapse / expand.
        let iPadColumns = (columnVisibility == .detailOnly) ? 3 : 2
        ZStack {
            switch router.selectedTab {
            case .home:
                HomeView(
                    repository: repository,
                    heroNamespace: heroNamespace,
                    iPadColumns: iPadColumns
                )
                    .transition(ScreenSwitchTransition.active)
                    .id(MainTab.home)
            case .dynamic:
                DynamicFeedView(repository: repository, heroNamespace: heroNamespace)
                    .transition(ScreenSwitchTransition.active)
                    .id(MainTab.dynamic)
            case .live:
                LiveRoomsView(repository: repository)
                    .transition(ScreenSwitchTransition.active)
                    .id(MainTab.live)
            case .profile:
                ProfileSettingsView(repository: repository)
                    .transition(ScreenSwitchTransition.active)
                    .id(MainTab.profile)
            }
        }
        .animation(ScreenSwitchTransition.animation, value: router.selectedTab)
    }
}

/// Animation contract for tab → tab screen swaps. Centralised
/// here so the iPad sidebar (`PadRootView.selectedView`), the
/// phone tab bar, and any future navigation root all use the
/// same crossfade + slight scale curve.  Tweak the curve in one
/// place and the whole app picks it up.
@MainActor
enum ScreenSwitchTransition {
    /// The transition applied to the outgoing / incoming tab content.
    /// `.opacity` keeps both views readable mid-animation; `.scale`
    /// adds a subtle 2 % depth cue so the change reads as motion,
    /// not a blink.  Marked `@MainActor` so the `AnyTransition`
    /// / `Animation` storage is reachable from the same isolation
    /// domain SwiftUI views live in (the types themselves are not
    /// `Sendable`).
    static let active: AnyTransition = .asymmetric(
        insertion: .opacity.combined(with: .scale(scale: 0.985))
            .combined(with: .offset(y: 6)),
        removal: .opacity.combined(with: .scale(scale: 1.01))
    )

    /// Driver animation — slightly bouncy so the swap feels alive
    /// rather than mechanical, but tuned short enough (260 ms) that
    /// the user never waits for the chrome to settle.
    static let animation: Animation = .spring(response: 0.26, dampingFraction: 0.86)
}

/// New iPad sidebar matching the redesigned mockup:
///
///  ┌────────────────────────────┐
///  │ 🏠  首頁   (pink pill)      │   <- active row gets a
///  │ 🧭  動態                    │      rounded pink capsule
///  │ ((•))  直播                 │
///  │                            │
///  │  ┌──────┐                  │   <- user card: avatar +
///  │  │ {un} │ 我的              │      username + 我的 label
///  │  └──────┘                  │
///  │                            │
///  │ ≡<  收合                    │   <- collapse button
///  └────────────────────────────┘
///
/// All copy is Traditional Chinese; the pink highlight uses
/// `PaladalaTheme.biliPink` to stay consistent with the rest of
/// the app.
private struct PadSidebar: View {
    let tabs: [MainTab]
    @Binding var columnVisibility: NavigationSplitViewVisibility

    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var authStore: AuthStore

    var body: some View {
        VStack(spacing: PaladalaTheme.Spacing.xl) {
            tabList
            Spacer(minLength: 0)
            userCard
            collapseButton
        }
        .padding(.horizontal, PaladalaTheme.Spacing.xl)
        .padding(.top, PaladalaTheme.Spacing.xxl)
        .padding(.bottom, PaladalaTheme.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(PaladalaTheme.canvas)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(PaladalaTheme.ink)
                .frame(width: PaladalaTheme.borderWidth)
                .accessibilityHidden(true)
        }
    }

    private var tabList: some View {
        VStack(spacing: PaladalaTheme.Spacing.m) {
            ForEach(tabs) { tab in
                SidebarRow(
                    tab: tab,
                    isActive: router.selectedTab == tab
                ) {
                    router.open(tab)
                }
            }
        }
    }

    @ViewBuilder
    private var userCard: some View {
        Button {
            router.open(.profile)
        } label: {
            HStack(spacing: PaladalaTheme.Spacing.m) {
                sidebarAvatar
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: PaladalaTheme.Spacing.xs) {
                    Text(usernameText)
                        .font(PaladalaTheme.FontRole.headline)
                        .foregroundStyle(PaladalaTheme.ink)
                        .lineLimit(1)
                    Text("我的")
                        .font(PaladalaTheme.FontRole.labelMono)
                        .foregroundStyle(PaladalaTheme.ink)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.black))
                    .foregroundStyle(PaladalaTheme.ink)
            }
            .padding(.horizontal, PaladalaTheme.Spacing.m)
            .padding(.vertical, PaladalaTheme.Spacing.s)
            .modifier(StreetSidebarSurface(
                fill: router.selectedTab == .profile
                    ? PaladalaTheme.biliPink
                    : PaladalaTheme.paper
            ))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var collapseButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.22)) {
                columnVisibility = .detailOnly
            }
        } label: {
            HStack(spacing: PaladalaTheme.Spacing.m) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.title3)
                    .foregroundStyle(PaladalaTheme.ink)
                    .frame(width: 24)
                Text("收合")
                    .font(PaladalaTheme.FontRole.labelMono)
                    .foregroundStyle(PaladalaTheme.ink)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, PaladalaTheme.Spacing.m)
            .padding(.vertical, PaladalaTheme.Spacing.m)
            .modifier(StreetSidebarSurface(fill: PaladalaTheme.paper))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var usernameText: String {
        authStore.activeAccount?.name ?? "未登入"
    }

    @ViewBuilder
    private var sidebarAvatar: some View {
        let isNative = PaladalaTheme.activeVariant == .iosNative
        if let url = authStore.activeAccount?.faceURL {
            ResilientImage(url: url)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: isNative ? 12 : 0,
                        style: .continuous
                    )
                )
                .overlay {
                    if !isNative {
                        Rectangle()
                            .strokeBorder(
                                PaladalaTheme.ink,
                                lineWidth: PaladalaTheme.borderWidth
                            )
                    }
                }
        } else {
            RoundedRectangle(cornerRadius: isNative ? 12 : 0, style: .continuous)
                .fill(PaladalaTheme.biliPink)
                .overlay(
                    Image(systemName: "person.fill")
                        .font(.body)
                        .foregroundStyle(PaladalaTheme.ink)
                )
                .overlay {
                    if !isNative {
                        Rectangle()
                            .strokeBorder(
                                PaladalaTheme.ink,
                                lineWidth: PaladalaTheme.borderWidth
                            )
                    }
                }
        }
    }
}

/// One row in the iPad sidebar. Every row uses the same hard-edged
/// paper surface; the active destination switches to signal pink.
private struct SidebarRow: View {
    let tab: MainTab
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: PaladalaTheme.Spacing.m) {
                Image(systemName: tab.sidebarSymbolName)
                    .font(.body.weight(.black))
                    .frame(width: 24)
                    .foregroundStyle(PaladalaTheme.ink)
                Text(tab.title)
                    .font(PaladalaTheme.FontRole.labelMono)
                    .foregroundStyle(PaladalaTheme.ink)
                Spacer(minLength: 0)
                if isActive {
                    Rectangle()
                        .fill(PaladalaTheme.ink)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, PaladalaTheme.Spacing.l)
            .padding(.vertical, PaladalaTheme.Spacing.m)
            .modifier(StreetSidebarSurface(
                fill: isActive ? PaladalaTheme.biliPink : PaladalaTheme.paper
            ))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct StreetSidebarSurface: ViewModifier {
    let fill: Color

    @ViewBuilder
    func body(content: Content) -> some View {
        if PaladalaTheme.activeVariant == .iosNative {
            // iOS Native: rounded corner, no border, no hard shadow,
            // system `fill` background. The active tab still uses
            // `PaladalaTheme.biliPink` as the accent fill so the
            // "selected" affordance is preserved — the user can
            // override via system tint if the brand color ever
            // changes, but the active-state cue stays consistent.
            content
                .background(
                    fill,
                    in: RoundedRectangle(
                        cornerRadius: PaladalaTheme.cornerRadius,
                        style: PaladalaTheme.cornerStyle
                    )
                )
        } else {
            content
                .background {
                    ZStack {
                        Rectangle()
                            .fill(PaladalaTheme.ink)
                            .offset(
                                x: PaladalaTheme.hardShadowOffset,
                                y: PaladalaTheme.hardShadowOffset
                            )
                        Rectangle()
                            .fill(fill)
                    }
                }
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

@MainActor
@ViewBuilder
private func profileRouteView(_ route: ProfileRoute, repository: PaladalaRepository) -> some View {
    switch route {
    case .history:
        HistoryListView(repository: repository)
    case .favorites(let mid):
        FavoriteFoldersView(repository: repository, mid: mid)
    case .favoriteFolder(let folder):
        FavoriteFolderVideosView(repository: repository, folder: folder)
    case .watchLater:
        WatchLaterListView(repository: repository)
    case .downloads:
        DownloadedVideosView(repository: repository)
    case .bangumiTimeline:
        // The deep-link entry from the profile quick
        // action. `AppRouter.openBangumiTimeline()` also
        // flips `selectedTab` to `.bangumi` so the
        // dedicated tab is highlighted when the user
        // backs out.
        BangumiHomeView(repository: repository, heroNamespace: nil)
    }
}

/// Keep the native tab bar semantics while forcing an opaque paper
/// background and signal-pink selection. This avoids translucent
/// material without replacing the accessible system `TabView`.
/// iOS Native is a no-op so the system draws its default tab bar
/// (with the user-chosen accent color tint — no pink override).
private struct StreetTabBarModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if PaladalaTheme.activeVariant == .iosNative {
            content
        } else {
            content
                .toolbarBackground(PaladalaTheme.paper, for: .tabBar)
                .toolbarBackground(.visible, for: .tabBar)
                .tint(PaladalaTheme.biliPink)
        }
    }
}
