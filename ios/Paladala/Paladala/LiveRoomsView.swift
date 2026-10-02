import AVKit
import SwiftUI

struct LiveRoomsView: View {
    let repository: PaladalaRepository

    @StateObject private var model = LiveViewModel()
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage("paladala.materialDesign") private var materialDesign: MaterialDesign = .liquidGlass

    private var columns: [GridItem] {
        if horizontalSizeClass == .regular {
            return Array(
                repeating: GridItem(.flexible(), spacing: 32, alignment: .top),
                count: 2
            )
        }
        return [GridItem(.flexible(), alignment: .top)]
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if let error = model.errorMessage {
                    ErrorBanner(message: error)
                }
                if model.isLoading && model.rooms.isEmpty {
                    // Skeleton grid mirrors the live room card
                    // shape so the cross-fade from loading to
                    // loaded does not shift layout.
                    SkeletonGrid(
                        columns: horizontalSizeClass == .regular ? 2 : 1,
                        columnSpacing: 32,
                        rowSpacing: 32
                    )
                        .padding(.top, 4)
                } else if model.rooms.isEmpty {
                    ContentUnavailableView(
                        model.errorMessage == nil ? "暫無直播間" : "直播間列表暫不可用",
                        systemImage: "play.tv",
                        description: Text(model.errorMessage == nil
                                          ? "稍後再來，下拉重新整理試試。"
                                          : "Bilibili 未返回公開的直播列表。")
                    )
                    .frame(maxWidth: .infinity, minHeight: 260)
                    .overlay(alignment: .bottom) {
                        Button {
                            Haptics.tap()
                            Task { await model.load(repository: repository) }
                        } label: {
                            Label("重試", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(PaladalaGlassButtonStyle(materialDesign: materialDesign))
                        .padding(.bottom, 24)
                    }
                } else {
                    LazyVGrid(columns: columns, spacing: 32) {
                        ForEach(model.rooms) { room in
                            LiveRoomCard(room: room)
                        }
                    }
                }
            }
            .padding(PaladalaTheme.contentPadding)
        }
        .background(Color.clear)
        .scrollIndicators(.hidden)
        .navigationTitle("Live")
        // Tapping a `LiveRoomCard` pushes a `LiveRoute.room(room)` onto
        // the router's navigation path. `LivePlayerView` then resolves
        // the playback URLs and drives the VLC player + HLS/FLV toggle.
        .navigationDestination(for: LiveRoute.self) { route in
            switch route {
            case .room(let room):
                LivePlayerView(room: room, repository: repository)
            }
        }
        .task {
            await model.load(repository: repository)
        }
        .refreshable {
            Haptics.medium()
            await model.load(repository: repository)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Haptics.tap()
                    Task { await model.load(repository: repository) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh")
            }
        }
        .modifier(LiveToolbarGlassModifier(materialDesign: materialDesign))
    }
}

/// Live-room playback surface.  Resolves the playback URLs on
/// appear (one network round-trip to `getRoomPlayInfo`) and
/// drives AVKit's `VideoPlayer` (a `AVPlayerViewController` in
/// SwiftUI clothing) with the HLS URL.  AVPlayer can only
/// consume HLS — the FLV path was previously handled by VLC
/// but is no longer supported, so the format toggle was
/// dropped from the toolbar.
private struct LivePlayerView: View {
    let room: BiliLiveRoom
    let repository: PaladalaRepository

    @EnvironmentObject private var router: AppRouter
    @State private var playback: BiliLivePlayback?
    @State private var errorMessage: String?
    /// Created lazily once `playback` is loaded, because the
    /// controller's init needs the active stream URL.
    @State private var controller: PlayerController?
    /// Re-render trigger.  Bumped every time `controller`
    /// publishes (via `.onReceive(controller?.objectWillChange)`
    /// in `body`).  We can't use `@ObservedObject` directly
    /// because the controller is constructed lazily after the
    /// view mounts.
    @State private var controllerVersion: Int = 0

    var body: some View {
        ZStack {
            PaladalaTheme.canvas.ignoresSafeArea()
            VStack(spacing: 0) {
                playerSurface
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16 / 9, contentMode: .fit)
                metadataPanel
            }
            playerErrorOverlay
        }
        .navigationTitle(room.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadPlayback()
        }
        .onAppear {
            // Start the Live Activity banner as soon as
            // the user lands on the live room. The
            // coordinator is a no-op on devices / iOS
            // versions that don't support ActivityKit, so
            // wrapping it in `if #available` is enough to
            // keep the iOS 17 floor clean.
            if #available(iOS 16.1, *) {
                LiveActivityCoordinator.shared.start(for: room)
            }
        }
        .onDisappear {
            controller?.tearDown()
            controller = nil
            if #available(iOS 16.1, *) {
                LiveActivityCoordinator.shared.end()
            }
        }
        // Mirror the controller's `playerError` publication into
        // a `@State` token so the body re-evaluates and the
        // overlay re-renders. The view doesn't observe the
        // controller directly (see `controllerVersion` rationale
        // above).
        .onChange(of: controller?.playerError) { _, _ in
            controllerVersion &+= 1
        }
    }

    @ViewBuilder
    private var playerSurface: some View {
        if let controller {
            // `VideoPlayer` wraps `AVPlayerViewController` and
            // gives the live room a system-standard HLS
            // transport (play / pause / time labels / AirPlay /
            // PiP).  The `AVPlayer` is the shared one on
            // `PlayerController`, so toggling between this
            // surface and any future fullscreen view keeps
            // playback continuous.
            VideoPlayer(player: controller.player)
        } else if let errorMessage {
            ContentUnavailableView(
                "無法播放該直播間",
                systemImage: "exclamationmark.triangle",
                description: Text(errorMessage)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView()
                .controlSize(.large)
                .tint(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Recovery surface shown when `PlayerController` flags a
    /// playback error (live CDN 403, item decode failure, 10s
    /// stall, etc.).  Branched on the `RecoveryAction` so a
    /// 403 lands on the login sheet instead of retrying the
    /// same dead request.
    @ViewBuilder
    private var playerErrorOverlay: some View {
        if let error = controller?.playerError {
            ContentUnavailableView {
                Label(error.title, systemImage: "exclamationmark.triangle")
            } description: {
                Text(error.message)
            } actions: {
                Button {
                    Haptics.tap()
                    switch error.recoveryAction {
                    case .signInAgain:
                        router.openLogin()
                    case .retryPlayback, .retrySeek:
                        controller?.retryPlayback()
                    }
                } label: {
                    Label(error.recoveryAction.buttonLabel,
                          systemImage: "arrow.clockwise")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(PaladalaGlassButtonStyle(materialDesign: .liquidGlass))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
        }
    }

    /// Build the controller lazily on first appearance, then
    /// mirror its `objectWillChange` into a `@State` token so
    /// the body re-evaluates when `playerError` (a `@Published`
    /// property on the controller) flips.  The token pattern
    /// is the standard workaround for late-arriving
    /// `ObservableObject`s — `LivePlayerView` is constructed
    /// before the controller, so we can't use `@ObservedObject`.
    private var metadataPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(room.title)
                .font(PaladalaTheme.FontRole.headline)
                .foregroundStyle(PaladalaTheme.ink)
                .textCase(.uppercase)
            HStack(spacing: 8) {
                Text(room.hostName)
                Text("·")
                Text(room.areaName)
            }
            .font(PaladalaTheme.FontRole.labelMono)
            .foregroundStyle(PaladalaTheme.mutedInk)
            // Color-only status indicators must pair with an
            // icon + shape per HIG. We use both the brand-pink
            // "watching" label and a system-red dot to encode
            // the live status; `accessibilityHidden(true)` keeps
            // the decorative dot from being read aloud so the
            // label is the single source of truth.
            HStack(spacing: 6) {
                Rectangle()
                    .fill(PaladalaTheme.biliPink)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text("\(room.viewerCount.compactCount) watching")
                    .font(PaladalaTheme.FontRole.labelMono)
                    .foregroundStyle(PaladalaTheme.biliPink)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(PaladalaTheme.Spacing.l)
        .paladalaStreetPanel(fill: PaladalaTheme.paper)
    }

    private func loadPlayback() async {
        do {
            let resolved = try await repository.livePlayback(for: room)
            playback = resolved
            // Build the shared controller the first time
            // playback loads. AVPlayer can consume HLS natively
            // but cannot decode FLV — the FLV path was previously
            // handled by VLC. With the move to AVPlayer, the
            // controller is created from the HLS URL when the
            // room offers one. If only FLV is offered, we surface
            // a friendly error and skip controller init.
            if let hlsURL = resolved.hlsURL {
                if controller == nil {
                    // Prefer the local HLS proxy so we get CDN
                    // failover (Bilibili's live CDN edges 403
                    // more often than VOD). The proxy also
                    // strips the upstream Referer / UA from
                    // every request, which is what AVPlayer
                    // needs to avoid the CDN's 403 on signed
                    // m3u8 URLs. Falls back to the direct URL
                    // if the proxy can't bind a port (e.g.
                    // a previous teardown left it dead).
                    let livePlayback: BiliPlayback
                    if let proxyURL = try? await LocalHLSProxyServer.shared
                        .serveLive(playback: resolved) {
                        livePlayback = BiliPlayback(
                            dash: nil,
                            fallbackURL: proxyURL,
                            referer: resolved.referer
                        )
                    } else {
                        livePlayback = BiliPlayback(
                            dash: nil,
                            fallbackURL: hlsURL,
                            referer: resolved.referer
                        )
                    }
                    controller = PlayerController(playback: livePlayback)
                }
            } else {
                errorMessage = "該直播間僅提供 FLV 流，AVPlayer 暫不支援。請改用支援 FLV 的客戶端。"
                controller = nil
            }
            errorMessage = nil
        } catch {
            errorMessage = "直播間地址解析失敗：\(error.localizedDescription)"
        }
    }
}

/// Applies Liquid Glass background to the live rooms toolbar.
private struct LiveToolbarGlassModifier: ViewModifier {
    let materialDesign: MaterialDesign

    func body(content: Content) -> some View {
        if materialDesign == .liquidGlass {
            content.paladalaNavBarGlass(.liquidGlass)
        } else {
            content
        }
    }
}
