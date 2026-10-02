//
//  PlayerView.swift
//  Paladala
//
//  AVKit-backed player surfaces.  The inline player hosts
//  `AVPlayerViewController` directly so the system owns the
//  playback chrome and tap-to-show / tap-to-hide behaviour.
//  The fullscreen player uses the same AVKit controller so it
//  gets the system Done button and PiP for free.
//
//  Both bind to the *same* `AVPlayer` on the shared
//  `PlayerController`, so inline ↔ fullscreen ↔ inline keeps
//  the playhead continuous.
//

import AVFoundation
import AVKit
import SwiftUI
import DesignSystem

// MARK: - Inline surface

/// Inline player using the native `AVPlayerViewController`
/// transport.  Full-frame SwiftUI gesture overlays must not sit
/// above this view, because they prevent AVKit from receiving the
/// single taps that reveal the system controls.
struct PlayerView: View {
    let playback: BiliPlayback
    let video: BiliVideo
    let repository: PaladalaRepository
    let subtitleTrack: BiliLyricTrack?
    let danmakuItems: [BiliDanmakuItem]
    @ObservedObject var controller: PlayerController
    /// Optional sleep timer.  Owned by `VideoDetailView` as a
    /// `@StateObject` so the same instance survives inline ↔
    /// fullscreen transitions and the countdown never resets.
    /// When `nil`, the HUD simply doesn't render.
    @ObservedObject var sleepTimer: SleepTimer

    /// Brightness-plugin snapshot.  Pulled once on appear so
    /// toggling a plugin does not force the inline player to
    /// re-render every frame; the view only needs the cached
    /// value here.  `nil` = no overlay.
    @State private var brightnessCache: PluginBrightnessRule?

    var body: some View {
        ZStack {
            // Inline AVPlayerViewController surface. Switched from the
            // custom UIView + AVPlayerLayer wrapper to the
            // native AVKit view controller so the user gets the
            // built-in playback chrome:
            //   - Single tap anywhere on the player surfaces
            //     the system play / pause + scrubber + AirPlay
            //     for ~3 s, then auto-hides.
            //   - Second tap (or a tap on the chrome itself)
            //     hides it immediately.
            //   - Built-in Picture-in-Picture button appears in
            //     the chrome when the system reports PiP is
            //     possible (same notification we already
            //     observe). We do not need to draw our own PiP
            //     button any more.
            //
            // The representable is iOS 16+ (we gate it via
            // `#available` because `requiresLinearPlayback`
            // was added in 16 and we want a clean fallback for
            // any future iOS 17 deployment target drop).
            NativeInlinePlayerRepresentable(
                player: controller.player,
                controller: controller,
                subtitleTrack: subtitleTrack,
                danmakuItems: danmakuItems
            )

            // Keep transient status above the player, but avoid any
            // full-frame transparent gesture layer here. The system
            // controller's own recognisers need to receive taps in
            // order to reveal and hide the playback controls.
            // PlayerTimedTextOverlay is now hosted inside
            // contentOverlayView so it persists into native fullscreen.
            ZStack {
                if (controller.isBuffering || controller.playbackState == .preparing) && controller.playerError == nil {
                    loadingOverlay
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }

                if let error = controller.playerError {
                    playbackErrorOverlay(error: error, controller: controller)
                        .transition(.opacity)
                }

                SponsorSkipToast()

                if sleepTimer.isActive {
                    SleepTimerHUDView(timer: sleepTimer)
                        .padding(.top, 12)
                        .padding(.trailing, 12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .transition(.opacity)
                }

                // Plugin brightness filter sits behind the
                // chrome overlay so the system transport
                // still gets its taps — `allowsHitTesting(false)`
                // is what guarantees that.
                if let b = brightnessCache {
                    brightnessOverlay(b)
                }
            }
        }
        .onAppear {
            // Snapshot once per appearance; toggling plugins
            // mid-playback is a rare action and the inline
            // player tearing down its tree to re-render is
            // worse than a one-frame stale overlay.
            brightnessCache = PluginManager.shared.brightnessRule()
        }
    }

    /// Plugin-driven dimming. Static `Color` overlays only —
    /// no `Material`, no `.blur`, so the AVPlayer compositor
    /// doesn't add an extra full-frame pass on each video
    /// frame. The warm cast is `.softLight`-blended onto the
    /// dim layer; capped at 0.25 opacity to avoid clipping.
    @ViewBuilder
    private func brightnessOverlay(_ rule: PluginBrightnessRule) -> some View {
        if let level = rule.level, level > 0 {
            Color.black.opacity(max(0, min(1, 1.0 - level)))
                .allowsHitTesting(false)
        }
        if let warm = rule.warmth, warm > 0 {
            Color.orange.opacity(min(0.25, warm * 0.25))
                .blendMode(.softLight)
                .allowsHitTesting(false)
        }
    }

    /// Spinner + KB/s readout shown during stalls.
    private var loadingOverlay: some View {
        VStack(spacing: 6) {
            if PaladalaTheme.activeVariant == .expressive {
                DSLoadingIndicator(size: 32, contained: true)
            } else {
                ProgressView().tint(.white).controlSize(.regular)
            }
            Text(formatNetworkSpeed(controller.networkSpeed))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.9))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            .black.opacity(0.55),
            in: RoundedRectangle(
                cornerRadius: PaladalaTheme.cornerRadius,
                style: PaladalaTheme.cornerStyle
            )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading video")
    }

    private func formatNetworkSpeed(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 0 else { return "—" }
        if bytesPerSecond >= 1_000_000 {
            return String(format: "%.1f MB/s", bytesPerSecond / 1_000_000)
        }
        if bytesPerSecond >= 1_000 {
            return String(format: "%.0f KB/s", bytesPerSecond / 1_000)
        }
        return String(format: "%.0f B/s", bytesPerSecond)
    }

    /// Recovery surface shown above the AVPlayer layer when
    /// `PlayerController.playerError` is non-nil.  Branched on
    /// the `RecoveryAction` so a live 403 lands on the login
    /// sheet (via `AppRouter.openLogin()`) instead of retrying
    /// the same dead request.
    @ViewBuilder
    private func playbackErrorOverlay(
        error: PlayerPlaybackError,
        controller: PlayerController
    ) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title)
                .foregroundStyle(PaladalaTheme.biliPink)
            Text(error.title)
                .font(.headline)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Text(error.message)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
            Button {
                Haptics.tap()
                switch error.recoveryAction {
                case .signInAgain:
                    AppRouter.postOpenLoginRequest()
                case .retryPlayback, .retrySeek:
                    controller.retryPlayback()
                }
            } label: {
                Label(error.recoveryAction.buttonLabel,
                      systemImage: "arrow.clockwise")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.white)
            .foregroundStyle(.black)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.75))
    }
}

// MARK: - SponsorBlock skip toast

private struct SponsorSkipToast: View {
    @State private var segment: SponsorSegment?
    @State private var show = false

    var body: some View {
        Group {
            if show, let segment {
                HStack(spacing: 6) {
                    Image(systemName: "forward.fill")
                        .font(.caption.weight(.bold))
                        .symbolEffect(.bounce, value: show)
                    Text("已跳過")
                        .font(.caption.weight(.medium))
                    Text(SponsorCategory(rawValue: segment.category)?.displayName ?? segment.category)
                        .font(.caption.weight(.bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(PaladalaTheme.biliPink)
                .overlay {
                    Rectangle()
                        .strokeBorder(.black, lineWidth: PaladalaTheme.borderWidth)
                }
                .background {
                    Rectangle()
                        .fill(.black)
                        .offset(
                            x: PaladalaTheme.hardShadowOffset,
                            y: PaladalaTheme.hardShadowOffset
                        )
                }
                .scaleEffect(show ? 1 : 0.5, anchor: .top)
                .opacity(show ? 1 : 0)
                .offset(y: show ? 0 : -20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 6)
            }
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.65, blendDuration: 0.2), value: show)
        .onReceive(NotificationCenter.default.publisher(for: .paladalaSponsorSegmentSkipped)) { note in
            guard let seg = note.object as? SponsorSegment else { return }
            segment = seg
            show = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                show = false
            }
        }
    }
}

// MARK: - Login-routing helper

/// Notification posted by `PlayerView` (which does not own an
/// `AppRouter` EnvironmentObject) when a recovery button
/// needs to open the login sheet.  `PaladalaApp.body` listens
/// for this and forwards to its captured router.
extension Notification.Name {
    static let paladalaRequestOpenLogin = Notification.Name(
        "app.paladala.ios.requestOpenLogin"
    )
    /// Posted by `AVPlayerController` when the current item
    /// reaches the end of its playable duration.
    /// `VideoDetailView` subscribes to drive the YouTube-style
    /// "next up" overlay + auto-play behaviour. Posted on the
    /// main queue; subscribers do not need to hop threads.
    static let paladalaVideoDidPlayToEnd = Notification.Name(
        "app.paladala.ios.videoDidPlayToEnd"
    )
}

extension AppRouter {
    /// Fire the cross-process login request.  Used by view
    /// layers that can't easily thread the AppRouter down
    /// from the environment (e.g. `PlayerView` inside
    /// `VideoDetailView` which holds the controller as an
    /// `@ObservedObject`).
    static func postOpenLoginRequest() {
        NotificationCenter.default.post(
            name: .paladalaRequestOpenLogin,
            object: nil
        )
    }
}

/// Fullscreen overlay player.  We present this inside
/// `.fullScreenCover` from `VideoDetailView` and let AVKit drive
/// the controls — there is no Paladala-branded scrubber, no
/// custom auto-hide, no tap-to-toggle.  AVKit's
/// `AVPlayerViewController` brings a system "Done" button (which
/// the SwiftUI `VideoPlayer` does not), AirPlay routing, and
/// optional Picture-in-Picture for free.  Seek failures are
/// handled inside AVKit by clamping the scrubber to a valid
/// range — the build-81 crash from `Slider.onEditingChanged`
/// driving `player.seek(to:)` past the end of the playable
/// bytes is no longer reachable.
///
/// The `PlayerController` is owned by `VideoDetailView`; this
/// view only binds the existing `AVPlayer` into an
/// `AVPlayerViewController`, so the playhead and play / pause
/// state stay continuous across inline ↔ fullscreen.
// MARK: - Fullscreen surface

struct FullscreenPlayerView: View {
    let video: BiliVideo
    let playback: BiliPlayback
    let repository: PaladalaRepository
    let subtitleTrack: BiliLyricTrack?
    let danmakuItems: [BiliDanmakuItem]
    @ObservedObject var controller: PlayerController
    /// Same timer instance as the inline player — see
    /// `PlayerView.sleepTimer`.  HUD only renders when the
    /// timer is in flight, matching the inline behaviour.
    @ObservedObject var sleepTimer: SleepTimer

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            AVPlayerSurfaceRepresentable(
                video: video,
                playback: playback,
                repository: repository,
                subtitleTrack: subtitleTrack,
                danmakuItems: danmakuItems,
                controller: controller
            ) {
                // Tapping outside the controls dismisses the
                // fullscreen cover, matching the "tap-to-dismiss"
                // gesture the rest of the app uses.
                dismiss()
            }
            .ignoresSafeArea()

            if sleepTimer.isActive {
                SleepTimerHUDView(timer: sleepTimer)
                    .padding(.top, 12)
                    .padding(.trailing, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .transition(.opacity)
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .safeAreaInset(edge: .top) {
            // Keep the Paladala title pill above the system
            // transport so the user still sees which video they
            // are watching, even with AVKit's chrome. The share
            // button is anchored to the trailing edge so a long
            // video title shrinks the pill rather than clipping
            // the button off-screen.
            HStack(spacing: 8) {
                Text(video.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        .black.opacity(0.55),
                        in: RoundedRectangle(
                            cornerRadius: PaladalaTheme.cornerRadius,
                            style: PaladalaTheme.cornerStyle
                        )
                    )
                Spacer(minLength: 8)
                if let shareURL = video.shareURL {
                    ShareLink(
                        item: shareURL,
                        subject: Text(video.title),
                        label: {
                            Image(systemName: "square.and.arrow.up")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(8)
                                .background(.black.opacity(0.72))
                                .overlay {
                                    Rectangle()
                                        .strokeBorder(.white, lineWidth: 1)
                                }
                        }
                    )
                    .accessibilityLabel(L10n.common.share)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
    }
}

// MARK: - UIKit bridge

/// `UIViewControllerRepresentable` for `AVPlayerViewController`,
/// used by `FullscreenPlayerView`.  SwiftUI's `VideoPlayer`
/// already wraps this class for the inline case, but it does
/// not expose the system "Done" button that `.fullScreenCover`
/// callers expect — going one layer down gives us the
/// `doneButton` (and `enterFullScreen`/`exitFullScreen` /
/// AirPlay / PiP for free if we ever need them).
///
/// We hold a strong reference to the controller in the
/// `Coordinator` so the `AVPlayer` outlives any SwiftUI
/// re-render of the representable.  When the view is replaced
/// the controller's `viewController` weak ref goes nil and the
/// next `updateUIViewController` no-ops.  The
/// `PlayerController` itself is owned by `VideoDetailView` and
/// torn down on `onDisappear`.
private struct AVPlayerSurfaceRepresentable: UIViewControllerRepresentable {
    let video: BiliVideo
    let playback: BiliPlayback
    let repository: PaladalaRepository
    let subtitleTrack: BiliLyricTrack?
    let danmakuItems: [BiliDanmakuItem]
    let controller: PlayerController
    let onDismiss: () -> Void

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let avController = AVPlayerViewController()
        avController.player = controller.player
        avController.showsPlaybackControls = true
        avController.videoGravity = .resizeAspect
        avController.allowsPictureInPicturePlayback = true
        avController.delegate = context.coordinator
        
        // Embed the custom overlays in the contentOverlayView.
        // This ensures they sit correctly between the video and the system controls.
        if let overlayView = avController.contentOverlayView {
            let overlay = FullscreenPlayerOverlay(
                video: video,
                repository: repository,
                subtitleTrack: subtitleTrack,
                danmakuItems: danmakuItems,
                controller: controller
            )
            let hostingController = UIHostingController(rootView: overlay)
            hostingController.view.backgroundColor = .clear
            context.coordinator.overlayHostingController = hostingController
            
            let view = hostingController.view!
            view.translatesAutoresizingMaskIntoConstraints = false
            overlayView.addSubview(view)
            
            NSLayoutConstraint.activate([
                view.centerXAnchor.constraint(equalTo: overlayView.centerXAnchor),
                view.centerYAnchor.constraint(equalTo: overlayView.centerYAnchor),
                view.widthAnchor.constraint(equalTo: overlayView.widthAnchor),
                view.heightAnchor.constraint(equalTo: overlayView.heightAnchor)
            ])
        }
        
        context.coordinator.avPlayerViewController = avController
        context.coordinator.onDismiss = onDismiss
        context.coordinator.playerController = self.controller
        
        return avController
    }

    func updateUIViewController(
        _ uiViewController: AVPlayerViewController,
        context: Context
    ) {
        if uiViewController.player !== controller.player {
            uiViewController.player = controller.player
        }
        context.coordinator.onDismiss = onDismiss
        context.coordinator.playerController = self.controller
        
        // Update the hosted SwiftUI view's state
        context.coordinator.overlayHostingController?.rootView = FullscreenPlayerOverlay(
            video: video,
            repository: repository,
            subtitleTrack: subtitleTrack,
            danmakuItems: danmakuItems,
            controller: controller
        )
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, AVPlayerViewControllerDelegate, @unchecked Sendable {
        weak var avPlayerViewController: AVPlayerViewController?
        var playerController: PlayerController?
        var onDismiss: () -> Void = {}
        var overlayHostingController: UIHostingController<FullscreenPlayerOverlay>?
        
        // MARK: - AVPlayerViewControllerDelegate

        // PR-C Task 5: `AVPlayerViewControllerDelegate` declares
        // its methods as nonisolated.  The previous
        // `@MainActor` annotation on these witnesses meant
        // Swift 6's strict check rejected the conformance.
        // The body of every delegate method now hops to the
        // main actor via a structured `Task { @MainActor in
        // … }` because the targets (`coordinator`,
        // `playerController`, `onDismiss`) are all
        // `@MainActor`-isolated.  The hop is fire-and-forget
        // — AVKit's delegate contract does not require the
        // delegate method to synchronously finish its work
        // before returning.

        nonisolated func playerViewController(
            _ playerViewController: AVPlayerViewController,
            willEndFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator
        ) {
            Task { @MainActor in
                coordinator.animate(alongsideTransition: nil) { context in
                    if !context.isCancelled {
                        self.onDismiss()
                    }
                }
            }
        }

        nonisolated func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
            Task { @MainActor in
                self.playerController?.setPiPActive(true)
            }
        }

        nonisolated func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
            Task { @MainActor in
                self.playerController?.setPiPActive(false)
            }
        }

        nonisolated func playerViewController(
            _ playerViewController: AVPlayerViewController,
            restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
        ) {
            completionHandler(true)
        }
    }
}

/// Extracted overlay for the fullscreen surface to be hosted
/// in AVPlayerViewController's contentOverlayView.
/// Combines the double-tap gesture, the long-press 2x speed gesture,
/// and the buffering indicator.
private struct FullscreenPlayerOverlay: View {
    let video: BiliVideo
    let repository: PaladalaRepository
    let subtitleTrack: BiliLyricTrack?
    let danmakuItems: [BiliDanmakuItem]
    @ObservedObject var controller: PlayerController

    @GestureState private var isLongPressing = false
    @State private var showingSpeedBadge = false

    var body: some View {
        ZStack {
            PlayerTimedTextOverlay(
                currentTime: controller.currentTime,
                subtitleTrack: subtitleTrack,
                danmakuItems: danmakuItems,
                mode: .fullscreen
            )
            .allowsHitTesting(false)

            // Invisible gesture layer
            Color.clear
                .contentShape(Rectangle())
                // Long press for 2x speed
                // Using a sequence of LongPress + Drag ensures we don't steal
                // immediate single/double taps from the underlying views.
                .gesture(
                    LongPressGesture(minimumDuration: 0.4)
                        .sequenced(before: DragGesture(minimumDistance: 0))
                        .updating($isLongPressing) { value, state, _ in
                            switch value {
                            case .second(true, let drag):
                                state = drag != nil
                            default:
                                state = false
                            }
                        }
                )
                .onChange(of: isLongPressing) { _, isPressing in
                    if isPressing {
                        controller.setRate(2.0)
                        showingSpeedBadge = true
                        Haptics.medium()
                    } else {
                        controller.setRate(1.0)
                        showingSpeedBadge = false
                    }
                }
            
            DoubleTapOverlay(
                video: video,
                repository: repository,
                controller: controller
            )
            
            VStack {
                if showingSpeedBadge {
                    HStack {
                        Spacer()
                        Text("2.0x 快進中")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                .black.opacity(0.6),
                                in: RoundedRectangle(
                                    cornerRadius: PaladalaTheme.cornerRadius,
                                    style: PaladalaTheme.cornerStyle
                                )
                            )
                            .padding(.top, 40)
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
                Spacer()
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: showingSpeedBadge)

            SponsorSkipToast()

            if controller.isBuffering {
                VStack(spacing: 10) {
                    ProgressView()
                        .tint(.white)
                        .controlSize(.large)
                    Text(formatNetworkSpeed(controller.networkSpeed))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(
                    .black.opacity(0.6),
                    in: RoundedRectangle(
                        cornerRadius: PaladalaTheme.cornerRadius,
                        style: PaladalaTheme.cornerStyle
                    )
                )
                .transition(.opacity)
            }
        }
        .animation(.default, value: controller.isBuffering)
    }

    private func formatNetworkSpeed(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 0 else { return "—" }
        if bytesPerSecond >= 1_000_000 {
            return String(format: "%.1f MB/s", bytesPerSecond / 1_000_000)
        }
        if bytesPerSecond >= 1_000 {
            return String(format: "%.0f KB/s", bytesPerSecond / 1_000)
        }
        return String(format: "%.0f B/s", bytesPerSecond)
    }
}

// MARK: - Timed text overlay

private struct PlayerTimedTextOverlay: View {
    enum Mode: Equatable {
        case inline
        case fullscreen
    }

    let currentTime: Double
    let subtitleTrack: BiliLyricTrack?
    let danmakuItems: [BiliDanmakuItem]
    let mode: Mode

    private var activeSubtitle: String? {
        guard let track = subtitleTrack, !track.lines.isEmpty else { return nil }
        let index = track.index(at: currentTime)
        guard track.lines.indices.contains(index) else { return nil }
        let line = track.lines[index]
        guard line.startTime <= currentTime + 0.25 else { return nil }
        return line.text
    }

    private var activeDanmaku: [BiliDanmakuItem] {
        guard !danmakuItems.isEmpty, currentTime.isFinite else { return [] }
        let lower = max(0, currentTime - 4.5)
        let lowerIndex = firstIndex(atLeast: lower)
        let upperIndex = firstIndex(greaterThan: currentTime)
        guard lowerIndex < upperIndex else { return [] }
        return Array(danmakuItems[lowerIndex..<upperIndex].suffix(3))
    }

    /// Danmaku arrives sorted by timestamp from the XML parser. Binary
    /// boundaries keep the 1 Hz overlay update O(log n) instead of filtering
    /// the complete (often thousands-item) array on every tick.
    private func firstIndex(atLeast value: Double) -> Int {
        var low = 0
        var high = danmakuItems.count
        while low < high {
            let mid = low + (high - low) / 2
            if danmakuItems[mid].time < value {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    private func firstIndex(greaterThan value: Double) -> Int {
        var low = 0
        var high = danmakuItems.count
        while low < high {
            let mid = low + (high - low) / 2
            if danmakuItems[mid].time <= value {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                danmakuStack
                    .id(mode)
                    .frame(
                        maxWidth: .infinity,
                        alignment: mode == .fullscreen ? .center : .leading
                    )
                    .padding(.horizontal, mode == .fullscreen ? 88 : 14)
                    .padding(.top, mode == .fullscreen ? 78 : 14)
                    .transition(.move(edge: .top).combined(with: .opacity))

                Spacer(minLength: 0)
            }

            if let activeSubtitle {
                VStack {
                    Spacer(minLength: 0)
                    subtitleText(activeSubtitle)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 34)
                }
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: mode)
        .animation(.easeOut(duration: 0.16), value: activeSubtitle)
        .animation(.easeOut(duration: 0.16), value: activeDanmaku)
    }

    private var danmakuStack: some View {
        VStack(alignment: mode == .fullscreen ? .center : .leading, spacing: 6) {
            ForEach(activeDanmaku) { item in
                Text(item.text)
                    .font((mode == .fullscreen ? Font.subheadline : Font.caption).weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .multilineTextAlignment(mode == .fullscreen ? .center : .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.68))
                    .overlay {
                        Rectangle().strokeBorder(.white.opacity(0.8), lineWidth: 1)
                    }
            }
        }
    }

    private func subtitleText(_ text: String) -> some View {
        Text(text)
            .font(.headline.weight(.semibold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(.black.opacity(0.72))
            .overlay {
                Rectangle().strokeBorder(.white.opacity(0.85), lineWidth: 1)
            }
    }
}

// MARK: - Double-tap overlay

/// Transparent overlay that catches double-tap gestures on the
/// player and partitions them into three vertical zones:
///
/// * **Left third** — `seek(by: -10)` and flash a `gobackward.10`
///   badge. Paladala users expect YouTube-style ±10s skips.
/// * **Right third** — `seek(by: +10)` and flash a `goforward.10`
///   badge.
/// * **Middle third** — like the video. Flash a heart badge and
///   fire `PaladalaRepository.likeVideo(...)` if the user is
///   signed in. Anonymous users still see the heart animation
///   (local-only); the API call is best-effort and its
///   failure is silent.
///
/// The overlay sits *above* the AVPlayer surface and uses
/// `SpatialTapGesture(count: 2)`. We deliberately do NOT also
/// handle single-taps — that's the system's job (toggle the
/// transport). The double-tap recogniser does not consume
/// single-taps because `SpatialTapGesture(count: 2)` waits for
/// the second tap before firing.
private struct DoubleTapOverlay: View {
    let video: BiliVideo
    let repository: PaladalaRepository
    @ObservedObject var controller: PlayerController

    /// Which badge to flash. `nil` means no badge is visible.
    @State private var badge: BadgeKind?
    /// Tracks the last badge-fired timestamp so a second
    /// double-tap in quick succession re-uses the existing
    /// transition instead of stacking on top of itself.
    @State private var badgeToken: Int = 0
    /// First-launch gesture hint visibility. We start hidden
    /// and flip to `true` in `onAppear` when
    /// `didShowGestureHint` is still `false`. Auto-dismiss
    /// after 4s and on any tap. The two state values are
    /// kept separate so a SwiftUI re-evaluation that reads
    /// `didShowGestureHint` outside of an explicit user
    /// action cannot accidentally re-show the hint.
    @State private var isShowingHint: Bool = false
    /// In-flight 4s auto-dismiss task. Held so `onDisappear`
    /// can cancel it and a tap can cancel it before the
    /// sleep elapses.
    @State private var hintDismissTask: Task<Void, Never>?
    /// Persistent "did we ever show the hint" flag. Backed
    /// by `@AppStorage` so the hint appears exactly once per
    /// install, even across reinstall + iCloud restore
    /// scenarios where the OS may unmount the overlay
    /// without firing `onDisappear`.
    @AppStorage("paladala.didShowGestureHint") private var didShowGestureHint: Bool = false
    @EnvironmentObject private var authStore: AuthStore

    private enum BadgeKind: Equatable {
        case backward
        case forward
        case like

        /// SF Symbol name drawn inside the badge. Lives on
        /// the enum so the badge View doesn't need access to
        /// the overlay's private types.
        var symbolName: String {
            switch self {
            case .backward: return "gobackward.10"
            case .forward:  return "goforward.10"
            case .like:     return "heart.fill"
            }
        }
    }

    var body: some View {
        // The recogniser is bound to a `Color.clear` so the
        // overlay is fully transparent in steady state. The
        // badge is layered on top of the recogniser but
        // `allowsHitTesting(false)` lets taps fall through to
        // the underlying gesture. We use a `GeometryReader` to
        // capture the live overlay width so the third
        // breakpoints track the actual player size (different
        // on iPhone vs iPad, different in inline vs fullscreen
        // vs mini-player).
        GeometryReader { geo in
            Color.clear
                .contentShape(Rectangle())
                .simultaneousGesture(
                    SpatialTapGesture(count: 2)
                        .onEnded { event in
                            let zone = DoubleTapZone.classify(
                                point: event.location,
                                width: geo.size.width
                            )
                            handleDoubleTap(zone: zone)
                        }
                )
                // Single-tap recogniser — only used to dismiss
                // the first-launch gesture hint. Attached as a
                // `simultaneousGesture` so it does not steal
                // taps from the double-tap recogniser above
                // (SwiftUI dispatches both gestures; the
                // single-tap onEnded simply hides the hint
                // while the double-tap onEnded still runs the
                // seek/like animation).
                .simultaneousGesture(
                    TapGesture(count: 1)
                        .onEnded { dismissHint() }
                )
                .overlay {
                    if let badge {
                        DoubleTapBadge(symbol: badge.symbolName)
                            .id(badgeToken)
                            .transition(.scale.combined(with: .opacity))
                            .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .bottom) {
                    if isShowingHint {
                        GestureHint()
                            .padding(.bottom, 28)
                            .padding(.horizontal, 20)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: badge)
                .animation(.easeInOut(duration: 0.25), value: isShowingHint)
        }
        .onAppear {
            // First-launch only. Subsequent opens read
            // `didShowGestureHint == true` and skip the
            // appearance transition entirely.
            guard !didShowGestureHint else { return }
            isShowingHint = true
            hintDismissTask?.cancel()
            hintDismissTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard !Task.isCancelled else { return }
                dismissHint()
            }
        }
        .onDisappear {
            // Cancelling the task prevents the closure from
            // re-running while the view is mid-tear-down —
            // without it we have observed the hint flipping
            // back to visible for one frame on the way out.
            hintDismissTask?.cancel()
            hintDismissTask = nil
            // Treat an early disappearance as a dismiss:
            // the inline DoubleTapOverlay tears down when
            // fullscreen is presented, which would cancel
            // the 4s timer before it fires. Mark the hint
            // as shown so the fullscreen overlay (or any
            // future inline re-mount) doesn't re-show it.
            if isShowingHint {
                isShowingHint = false
                didShowGestureHint = true
            }
        }
    }

    /// Persist the dismiss and tear down the in-flight
    /// auto-dismiss task. Idempotent — calling it twice in
    /// quick succession (tap + 4s timer) is a no-op the
    /// second time because the `guard isShowingHint` check
    /// short-circuits before any state writes.
    private func dismissHint() {
        guard isShowingHint else { return }
        isShowingHint = false
        // The flag is also written from `onDisappear` for
        // the early-tear-down path; writing it here too is
        // cheap and keeps the function idempotent.
        didShowGestureHint = true
        hintDismissTask?.cancel()
        hintDismissTask = nil
    }

    private func handleDoubleTap(zone: DoubleTapZone) {
        switch zone {
        case .left:
            Haptics.medium()
            controller.seek(by: -10)
            show(badge: .backward)
        case .right:
            Haptics.medium()
            controller.seek(by: +10)
            show(badge: .forward)
        case .middle:
            Haptics.tap()
            show(badge: .like)
            // Fire the like request best-effort. The
            // animation is local-only; the API call does
            // not gate the visual feedback. If the user is
            // anonymous `authStore.activeAccount` is nil —
            // skip the network call (Paladala's API would
            // 401 anyway).
            if authStore.activeAccount != nil {
                Task { try? await repository.likeVideo(video: video, action: 1) }
            }
        }
    }

    private func show(badge kind: BadgeKind) {
        badge = kind
        badgeToken &+= 1
        // Auto-dismiss the badge after a short delay.
        // The user can fire a new badge while one is
        // visible; the token bump restarts the animation.
        let token = badgeToken
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            if token == badgeToken {
                badge = nil
            }
        }
    }
}

/// Partition a tap point into left / middle / right thirds
/// along the X axis. The breakpoints are ratios of the live
/// overlay width so the gesture adapts to phone vs iPad vs
/// fullscreen vs split-view players without hard-coded
/// coordinates. The overlay's coordinate space is the local
/// frame of the `Color.clear` host that owns the gesture, so
/// `point.x` is in `[0, width]`.
private enum DoubleTapZone {
    case left, middle, right

    static func classify(point: CGPoint, width: CGFloat) -> DoubleTapZone {
        guard width > 0 else { return .middle }
        let x = max(0, min(width, point.x))
        let third = width / 3
        if x < third { return .left }
        if x < third * 2 { return .middle }
        return .right
    }
}

/// Big SF Symbol badge that flashes on top of the player
/// when a double-tap is recognised. Drawn with a black
/// shadow so it stays legible over bright video frames.
private struct DoubleTapBadge: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 88, weight: .bold))
            .foregroundStyle(.white)
            .padding(20)
            .background(.black.opacity(0.66))
            .overlay {
                Rectangle().strokeBorder(.white, lineWidth: 1)
            }
    }
}

/// First-launch gesture legend shown on top of the player.
/// Surfaces the same three double-tap zones the gesture
/// recogniser handles (left = -10s, right = +10s, centre =
/// like), plus a hint about the system seek-bar. The pill
/// is non-interactive (`allowsHitTesting(false)`) so taps
/// fall through to the underlying `DoubleTapOverlay` and
/// dismiss the hint via the single-tap recogniser added in
/// the same overlay.
private struct GestureHint: View {
    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                hintIcon(symbol: "gobackward.10", title: "雙擊左側", subtitle: "後退 10s")
                hintIcon(symbol: "heart.fill", title: "雙擊中心", subtitle: "點贊")
                hintIcon(symbol: "goforward.10", title: "雙擊右側", subtitle: "前進 10s")
            }
            .font(.caption2)
            Text("底欄拖動可跳轉進度")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white.opacity(0.78))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            .black.opacity(0.6),
            in: RoundedRectangle(
                cornerRadius: PaladalaTheme.cornerRadius,
                style: PaladalaTheme.cornerStyle
            )
        )
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.player.gestureHint)
    }

    /// One column in the legend. SF Symbol on top, two-line
    /// label below. Kept as a private helper so the
    /// `GestureHint` body stays scannable.
    private func hintIcon(symbol: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
            Text(title)
                .font(.caption2.weight(.semibold))
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.78))
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Native inline AVPlayerViewController wrapper

/// SwiftUI bridge that hosts an `AVPlayerViewController` for
/// the inline player surface. Replaces the previous
/// UIView + `AVPlayerLayer` wrapper (and the hand-rolled
/// `AVPictureInPictureController`) so the user gets the
/// system's native playback chrome:
///   - Single tap anywhere on the player surfaces the
///     play / pause + scrubber + AirPlay + PiP overlay for
///     ~3 s, then auto-hides.
///   - Second tap (or a tap on the chrome) hides it
///     immediately.
///   - Built-in Picture-in-Picture button appears in the
///     chrome when the system reports PiP is possible.
///
/// We deliberately keep the fullscreen path on its own
/// `AVPlayerSurfaceRepresentable` (also wrapping
/// `AVPlayerViewController`) — that one adds a custom title
/// pill + share button in a safe-area inset, which we do not
/// want in the inline layout.
struct NativeInlinePlayerRepresentable: UIViewControllerRepresentable {
    let player: AVPlayer
    let controller: PlayerController
    let subtitleTrack: BiliLyricTrack?
    let danmakuItems: [BiliDanmakuItem]

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        vc.showsPlaybackControls = true
        vc.videoGravity = .resizeAspect
        vc.allowsPictureInPicturePlayback = true
        if #available(iOS 14.2, *) {
            vc.canStartPictureInPictureAutomaticallyFromInline = true
        }
        if #available(iOS 16, *) {
            vc.requiresLinearPlayback = false
        }
        vc.delegate = context.coordinator
        context.coordinator.avPlayerViewController = vc
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        if vc.player !== player {
            vc.player = player
        }
        context.coordinator.playerController = controller
        context.coordinator.overlayHost?.rootView = InlinePlayerOverlay(
            controller: controller,
            subtitleTrack: subtitleTrack,
            danmakuItems: danmakuItems
        )
        // Set up the gesture + badge once the view is loaded.
        context.coordinator.setUpPlayerOverlays()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    final class Coordinator: NSObject, AVPlayerViewControllerDelegate, @unchecked Sendable {
        var playerController: PlayerController
        weak var avPlayerViewController: AVPlayerViewController?
        fileprivate var overlayHost: UIHostingController<InlinePlayerOverlay>?
        private var didSetUpOverlays = false

        init(controller: PlayerController) {
            self.playerController = controller
        }

        /// Set up the long-press gesture recogniser and overlay host
        /// inside the contentOverlayView. Idempotent — only runs
        /// once per coordinator lifecycle.  Marked `@MainActor`
        /// because every UIKit handle it touches (`vc.view`,
        /// `vc.contentOverlayView`, `NSLayoutConstraint.activate`,
        /// `UIHostingController`) is `@MainActor`-isolated
        /// under Swift 6.
        @MainActor
        func setUpPlayerOverlays() {
            guard !didSetUpOverlays, let vc = avPlayerViewController else { return }
            didSetUpOverlays = true

            let longPress = UILongPressGestureRecognizer(
                target: self,
                action: #selector(handleLongPress(_:))
            )
            longPress.minimumPressDuration = 0.4
            longPress.delaysTouchesBegan = false
            longPress.cancelsTouchesInView = false
            vc.view.addGestureRecognizer(longPress)

            // Force-load the view if not already loaded so
            // contentOverlayView is guaranteed non-nil.
            _ = vc.view
            guard let overlayView = vc.contentOverlayView else { return }
            let overlay = InlinePlayerOverlay(
                controller: playerController,
                subtitleTrack: nil,
                danmakuItems: []
            )
            let hostingController = UIHostingController(rootView: overlay)
            hostingController.view.backgroundColor = .clear
            hostingController.view.isUserInteractionEnabled = false
            self.overlayHost = hostingController

            let view = hostingController.view!
            view.translatesAutoresizingMaskIntoConstraints = false
            overlayView.addSubview(view)

            NSLayoutConstraint.activate([
                view.centerXAnchor.constraint(equalTo: overlayView.centerXAnchor),
                view.centerYAnchor.constraint(equalTo: overlayView.centerYAnchor),
                view.widthAnchor.constraint(equalTo: overlayView.widthAnchor),
                view.heightAnchor.constraint(equalTo: overlayView.heightAnchor)
            ])
        }

        @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            // `@objc` selectors are nonisolated.  The
            // gesture recognizer's `state` is `@MainActor`
            // (UIKit).  UIKit delivers gesture callbacks on
            // the main thread, so `assumeIsolated` is the
            // correct bridge — the alternative (a
            // `Task { @MainActor in … }` hop) would defer
            // the state switch by a runloop turn and the
            // haptic would land after the visual state
            // update.
            MainActor.assumeIsolated {
                switch gesture.state {
                case .began:
                    Task { @MainActor in
                        self.playerController.setRate(2.0)
                        self.playerController.isLongPressingSpeed = true
                    }
                    Haptics.medium()
                case .ended, .cancelled:
                    Task { @MainActor in
                        self.playerController.setRate(1.0)
                        self.playerController.isLongPressingSpeed = false
                    }
                default:
                    break
                }
            }
        }

        /// Whether the player was actively playing before the
        /// fullscreen transition began, so we can resume on
        /// dismiss (AVKit pauses when exiting native fullscreen).
        private var wasPlayingBeforeFullscreen = false

        // PR-C Task 5: see the note on the first
        // `AVPlayerViewControllerDelegate` cluster above;
        // these witnesses follow the same `nonisolated`
        // shape so Swift 6 accepts the conformance.

        nonisolated func playerViewController(
            _ playerViewController: AVPlayerViewController,
            willBeginFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator
        ) {
            NSLog("[Paladala][fullscreen] willBeginFullScreen")
            Task { @MainActor in
                self.wasPlayingBeforeFullscreen = self.playerController.player.timeControlStatus == .playing
                self.playerController.isNativeFullscreenActive = true
            }
        }

        nonisolated func playerViewController(
            _ playerViewController: AVPlayerViewController,
            willEndFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator
        ) {
            NSLog("[Paladala][fullscreen] willEndFullScreen, wasPlaying=%d", wasPlayingBeforeFullscreen)
            Task { @MainActor in
                coordinator.animate(alongsideTransition: nil) { [weak self] context in
                    NSLog("[Paladala][fullscreen] willEndFullScreen completion, cancelled=%d", context.isCancelled ? 1 : 0)
                    guard let self, !context.isCancelled else { return }
                    self.playerController.isNativeFullscreenActive = false
                    // AVKit pauses when exiting native fullscreen.
                    // Resume if it was playing before entering.
                    if self.wasPlayingBeforeFullscreen {
                        self.playerController.player.play()
                    }
                }
            }
        }
    }
}

/// Combined overlay hosted inside AVPlayerViewController.contentOverlayView
/// so timed text (subtitles + danmaku) persists into native fullscreen.
fileprivate struct InlinePlayerOverlay: View {
    @ObservedObject var controller: PlayerController
    let subtitleTrack: BiliLyricTrack?
    let danmakuItems: [BiliDanmakuItem]

    var body: some View {
        ZStack {
            PlayerTimedTextOverlay(
                currentTime: controller.currentTime,
                subtitleTrack: subtitleTrack,
                danmakuItems: danmakuItems,
                mode: .inline
            )
            .allowsHitTesting(false)

            InlineSpeedBadge(controller: controller)
        }
    }
}

/// Speed badge rendered above the video layer, driven by
/// `controller.isLongPressingSpeed`. No gesture recogniser
/// here — the gesture is a UIKit `UILongPressGestureRecognizer`
/// on the contentOverlayView.
fileprivate struct InlineSpeedBadge: View {
    @ObservedObject var controller: PlayerController

    var body: some View {
        VStack {
            if controller.isLongPressingSpeed {
                HStack {
                    Spacer()
                    Text("2.0x 快進中")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            .black.opacity(0.6),
                            in: RoundedRectangle(
                                cornerRadius: PaladalaTheme.cornerRadius,
                                style: PaladalaTheme.cornerStyle
                            )
                        )
                        .padding(.top, 40)
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            Spacer()
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: controller.isLongPressingSpeed)
    }
}
