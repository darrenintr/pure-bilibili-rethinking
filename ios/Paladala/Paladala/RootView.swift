import SwiftUI
import DesignSystem

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
        }
        .paladalaToggleStyle()
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
        .overlay {
            if isOpeningAnimationVisible {
                SplashView {
                    isOpeningAnimationVisible = false
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
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
            TabView(selection: $router.selectedTab) {
                Tab(MainTab.home.title, systemImage: MainTab.home.symbolName, value: MainTab.home) {
                    LazyTabNavStack(tag: MainTab.home, activeTag: router.selectedTab, path: $router.homePath) {
                        HomeView(repository: repository, heroNamespace: heroNamespace)
                            .paladalaNavDestinations(repository: repository, heroNamespace: heroNamespace)
                    }
                }
                Tab(MainTab.dynamic.title, systemImage: MainTab.dynamic.symbolName, value: MainTab.dynamic) {
                    LazyTabNavStack(tag: MainTab.dynamic, activeTag: router.selectedTab, path: $router.dynamicPath) {
                        DynamicFeedView(repository: repository, heroNamespace: heroNamespace)
                            .paladalaNavDestinations(repository: repository, heroNamespace: heroNamespace)
                    }
                }
                Tab(MainTab.live.title, systemImage: MainTab.live.symbolName, value: MainTab.live) {
                    LazyTabNavStack(tag: MainTab.live, activeTag: router.selectedTab, path: $router.livePath) {
                        LiveRoomsView(repository: repository)
                            .paladalaNavDestinations(repository: repository, heroNamespace: heroNamespace)
                    }
                }
                Tab(MainTab.profile.title, systemImage: MainTab.profile.symbolName, value: MainTab.profile) {
                    LazyTabNavStack(tag: MainTab.profile, activeTag: router.selectedTab, path: $router.profilePath) {
                        ProfileSettingsView(repository: repository)
                            .paladalaNavDestinations(repository: repository, heroNamespace: heroNamespace)
                    }
                }
                // iOS 26 native search tab — the magnifier separates
                // into its own capsule at the trailing edge of the
                // tab bar and expands with the system's Liquid Glass
                // morph, auto-focusing the `.searchable` inside.
                Tab(value: MainTab.search, role: .search) {
                    NavigationStack {
                        SearchTabView(repository: repository, heroNamespace: heroNamespace)
                            .paladalaNavDestinations(repository: repository, heroNamespace: heroNamespace)
                    }
                }
            }
            .paladalaTabBarBehavior()
    }
}

private struct PadRootView: View {
    let repository: PaladalaRepository
    @EnvironmentObject private var router: AppRouter
    @Namespace private var heroNamespace

    var body: some View {
        // iPadOS 18+ native sidebar-adaptable TabView. In regular
        // width it renders as a Liquid Glass sidebar; when the user
        // collapses it (system toggle, top-leading), the tabs morph
        // into the floating top bar — the exact Apple TV behaviour.
        // Replaces the hand-rolled NavigationSplitView + custom
        // sidebar list, which could never replicate that morph.
        TabView(selection: $router.selectedTab) {
            Tab(MainTab.home.title, systemImage: MainTab.home.symbolName, value: MainTab.home) {
                LazyTabNavStack(tag: MainTab.home, activeTag: router.selectedTab, path: $router.homePath) {
                    HomeView(repository: repository, heroNamespace: heroNamespace, iPadColumns: 3)
                        .paladalaNavDestinations(repository: repository, heroNamespace: heroNamespace)
                }
            }
            Tab(MainTab.dynamic.title, systemImage: MainTab.dynamic.symbolName, value: MainTab.dynamic) {
                LazyTabNavStack(tag: MainTab.dynamic, activeTag: router.selectedTab, path: $router.dynamicPath) {
                    DynamicFeedView(repository: repository, heroNamespace: heroNamespace)
                        .paladalaNavDestinations(repository: repository, heroNamespace: heroNamespace)
                }
            }
            Tab(MainTab.live.title, systemImage: MainTab.live.symbolName, value: MainTab.live) {
                LazyTabNavStack(tag: MainTab.live, activeTag: router.selectedTab, path: $router.livePath) {
                    LiveRoomsView(repository: repository)
                        .paladalaNavDestinations(repository: repository, heroNamespace: heroNamespace)
                }
            }
            Tab(MainTab.profile.title, systemImage: MainTab.profile.symbolName, value: MainTab.profile) {
                LazyTabNavStack(tag: MainTab.profile, activeTag: router.selectedTab, path: $router.profilePath) {
                    ProfileSettingsView(repository: repository)
                        .paladalaNavDestinations(repository: repository, heroNamespace: heroNamespace)
                }
            }
            // iOS 26 native search tab: the magnifier lives in the
            // tab bar / sidebar footer and expands with the system's
            // Liquid Glass morph animation (Apple Music pattern).
            // `.searchable` inside auto-focuses when the tab opens.
            Tab(value: MainTab.search, role: .search) {
                NavigationStack {
                    SearchTabView(repository: repository, heroNamespace: heroNamespace)
                        .paladalaNavDestinations(repository: repository, heroNamespace: heroNamespace)
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
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

/// Native system tab bar on every OS version — iOS 26 renders
/// it as Liquid Glass, earlier versions as system material.
/// The custom DSNavBar / Street overlays are deleted.
private struct _RemovedLegacyChromeModifiers: ViewModifier {
    func body(content: Content) -> some View { content }
}


/// Shared navigation-destination registrations, applied inside each
/// tab's own `NavigationStack`. Every tab can therefore push videos,
/// replies, UP profiles, bangumi and local downloads independently —
/// the Apple-native per-tab stack pattern.
private struct PaladalaNavDestinations: ViewModifier {
    let repository: PaladalaRepository
    let heroNamespace: Namespace.ID?

    func body(content: Content) -> some View {
        content
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
                    BangumiSeasonDetailView(repository: repository, seasonId: seasonId)
                }
            }
            .navigationDestination(for: UPProfileRoute.self) { route in
                switch route {
                case .up(let mid):
                    UPProfileView(mid: mid, repository: repository)
                }
            }
    }
}

extension View {
    func paladalaNavDestinations(repository: PaladalaRepository, heroNamespace: Namespace.ID?) -> some View {
        modifier(PaladalaNavDestinations(repository: repository, heroNamespace: heroNamespace))
    }
}

/// Per-tab `NavigationStack` + lazy arming. Combines `LazyTab`'s
/// deferred `@StateObject` construction with each tab owning its
/// navigation stack, which is what makes `.navigationTitle`,
/// `.toolbar` and `.searchable` inside the tab render in the bar
/// (they cannot propagate through a TabView to an outer stack).
private struct LazyTabNavStack<Tag: Hashable, V: View>: View {
    let tag: Tag
    let activeTag: Tag?
    @Binding var path: NavigationPath
    @ViewBuilder let content: () -> V

    @State private var armed: Bool = false

    var body: some View {
        // Always render the stack — gating the content behind the
        // armed/EmptyView conditional made iOS 26's TabView hide the
        // tab *items* of unvisited tabs entirely (the bar collapsed to
        // showing only the tabs the user had already opened). The
        // lazy-init cost of four tabs is negligible next to a broken
        // tab bar.
        NavigationStack(path: $path) {
            content()
        }
    }
}
