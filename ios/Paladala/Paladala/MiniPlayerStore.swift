import AVFoundation
import Combine
import SwiftUI

/// Single source of truth for the active video player. Hoists both
/// `PlayerController` and `WatchSession` out of `VideoDetailView`
/// so the player survives the view's dismissal: when the user taps
/// "back" (or swipes back) the inline surface goes away but the
/// `AVPlayer` keeps running, the history reporter keeps ticking,
/// and a floating mini-player surfaces at the bottom-trailing of
/// `RootView`.
///
/// Lifecycle
/// ---------
/// 1. `VideoDetailView` calls `bind(video:playback:repository:)` in
///    `.onChange(of: model.playback)`. The store creates a
///    `PlayerController` (which starts the local HLS proxy for VOD
///    DASH) and starts a `WatchSession`.
/// 2. `VideoDetailView.onDisappear` calls `detachInline()`. The
///    playback is torn down (the mini-player was removed in
///    playing. The `MiniPlayerOverlay` becomes visible.
/// 3. The user taps the mini-player; `MiniPlayerOverlay` calls
///    `router.openVideo(currentVideo)` which re-pushes the video
///    onto the navigation path. `VideoDetailView` re-mounts and
///    re-binds. `bind` is idempotent: if `currentVideo.id` matches
///    and the controller is alive, the store skips the rebuild, so
///    the playhead is continuous and `progress=0` is not re-fired.
/// 4. The user taps the mini-player's "X" — `close()` tears down the
///    controller and the watch session. The local HLS proxy is
///    stopped; native PiP covers continue-watching.
@MainActor
final class MiniPlayerStore: ObservableObject {
    @Published private(set) var currentVideo: BiliVideo?
    @Published private(set) var controller: PlayerController?

    /// Mirror of the controller's `@Published` state so SwiftUI
    /// views observing the store can react to playhead changes
    /// without holding a direct reference to the controller.
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isPlaying: Bool = true
    @Published private(set) var isBuffering: Bool = false
    @Published private(set) var networkSpeed: Double = 0

    private var watchSession: WatchSession?
    private var cancellables: Set<AnyCancellable> = []
    /// Last `BiliPlayback` value the store was bound to.  Used
    /// by `bind(...)` to short-circuit a re-bind with the same
    /// playback without rebuilding the controller — important
    /// because the freshly-built `PlayerController`'s duration
    /// is still `.nan` / `.zero` for the first ~250 ms, so
    /// duration-based idempotency was racy with the
    /// `onChange(of:, initial: true)` + `onAppear` pair that
    /// both call `bind` on first appear.
    private var pendingPlayback: BiliPlayback?
    /// Whether a detail view currently owns the inline surface.
    /// Drives end-of-PiP teardown: when PiP stops and no inline
    /// view is attached, the session has nowhere to go back to.
    private var inlineAttached = false
    private var controllerBoundAt = Date.distantPast

    /// Bind a new playback to the store. Idempotent: if the same
    /// video is already bound **and the playback represents the
    /// same playable content**, the call returns without
    /// rebuilding the controller or re-firing `WatchSession.start()`.
    ///
    /// **PR-X (Issue 1 — fullscreen↔PiP "video ended" regression)**:
    /// equality is by `BiliPlayback.contentIdentity`, NOT by the
    /// default `Hashable` conformance.  The default hash compares
    /// every field including the session-specific query string
    /// inside `dash.video.baseURL` / `backupURLs` (which carry
    /// `upsig` / `uipk` / `deadline` / `mid` / `trid` and rotate
    /// on every B站 playurl fetch).  Before PR-X, a re-fetch of
    /// the same video produced a `BiliPlayback` that compared
    /// `!=` to the previously-bound one even though the actual
    /// playable content was identical, so this method tore down
    /// the active controller and built a new one — the user saw
    /// a visible "video restart" when toggling fullscreen / PiP
    /// and SwiftUI re-fired `.task` → `model.load` → new playurl.
    /// `contentIdentity` excludes the rotating query string while
    /// keeping the host (CDN failover matters), byte ranges, qn,
    /// codec, dimensions, ladders, and the local download path
    /// — so genuine quality switches / fallback swaps / download
    /// re-opens still trigger a clean teardown + rebuild, but a
    /// session-token-only re-fetch of the same video is a no-op.
    func bind(video: BiliVideo, playback: BiliPlayback, repository: PaladalaRepository) {
        // A retained session older than this is rebuilt instead of
        // resumed: CDN signed URLs carry a deadline, and resuming
        // with stale links would 403/expiry-loop on retry. A fresh
        // navigation re-fetches playurl anyway, so rebuilding costs
        // nothing in that path.
        var resumePositionAfterRebuild: Double = 0
        if let current = currentVideo,
           current.id == video.id,
           Date().timeIntervalSince(controllerBoundAt) > 1800,
           controller != nil {
            // Rebuilding for fresh signed URLs must not lose the
            // playhead — the user is mid-video, and a restart at
            // zero would overwrite their saved progress. Seeks
            // issued before the item binds are replayed by the
            // controller (`pendingUserSeek`), so this is safe to
            // apply blindly right after construction.
            resumePositionAfterRebuild = controller?.currentTime ?? 0
            teardownController()
        }
        if let current = currentVideo,
           current.id == video.id,
           let pendingPlayback,
           pendingPlayback.contentIdentity == playback.contentIdentity {
            // Same video, same content — keep the existing
            // controller and watch session.  Hide the mini-player
            // if a previous navigation push surfaced it so the
            // inline player re-takes over.
            // Re-entering the detail page (back from a child
            // route like the creator profile) means the user is
            // watching again — resume the paused session.
            inlineAttached = true
            // `PlayerController.play()` (not raw `player.play()`):
            // it rewinds first when the retained item is sitting
            // at its end, so reopening a finished video replays
            // from zero instead of sticking on the last frame.
            // …Unless the video already ENDED and the user never
            // asked for a replay: the end card owns that state,
            // so leave the player paused.
            if let controller,
               !(controller.duration > 0 && controller.currentTime >= controller.duration - 0.5) {
                controller.play()
            }
            diagLog(.playback, "MiniPlayerStore.bind: idempotent re-bind",
                    details: ["videoID": video.id])
            return
        }

        // Switching to a different video, or a quality change
        // (different `BiliPlayback` value for the same video),
        // or the first bind.  Tear down any previous controller
        // first so the local HLS proxy is free to be re-served
        // with the new DASH source.
        teardownController()

        let newController = PlayerController(playback: playback, video: video)
        controller = newController
        if resumePositionAfterRebuild > 1 {
            newController.seek(to: resumePositionAfterRebuild)
        }
        currentVideo = video
        pendingPlayback = playback

        // Mirror the controller's @Published state into the store.
        // `objectWillChange` would be more efficient but Combine
        // makes it tricky to fold multiple sources into a single
        // stream, and a 4-state mirror is cheap enough.
        cancellables.removeAll()
        cancellables.insert(
            newController.$currentTime
                .receive(on: RunLoop.main)
                .sink { [weak self] in self?.currentTime = $0 }
        )
        cancellables.insert(
            newController.$duration
                .receive(on: RunLoop.main)
                .sink { [weak self] in self?.duration = $0 }
        )
        cancellables.insert(
            newController.$isPlaying
                .receive(on: RunLoop.main)
                .sink { [weak self] in self?.isPlaying = $0 }
        )
        cancellables.insert(
            newController.$isBuffering
                .receive(on: RunLoop.main)
                .sink { [weak self] in self?.isBuffering = $0 }
        )
        cancellables.insert(
            newController.$networkSpeed
                .receive(on: RunLoop.main)
                .sink { [weak self] in self?.networkSpeed = $0 }
        )

        // Start the history reporter. WatchSession reads
        // `currentTime` and `isPlaying` from the controller every
        // 30 seconds.
        inlineAttached = true
        controllerBoundAt = Date()

        // When PiP ends and no inline view is attached, the
        // session has nowhere to surface — tear it down rather
        // than leaking a paused controller forever.
        cancellables.insert(
            newController.$isPictureInPictureActive
                .receive(on: RunLoop.main)
                .sink { [weak self, weak newController] active in
                    guard let self, !active, !self.inlineAttached else { return }
                    guard self.controller === newController else { return }
                    diagLog(.playback, "PlaybackStore: PiP ended without inline → teardown")
                    self.teardownController()
                }
        )

        let session = WatchSession(
            repository: repository,
            aid: video.aid,
            cid: video.cid,
            getCurrentSeconds: { [weak newController] in newController?.currentTime ?? 0 },
            isActive: { [weak newController] in newController?.isPlaying ?? false }
        )
        session.start()
        watchSession = session
        diagLog(.playback, "MiniPlayerStore.bind: created new controller", details: ["videoID": video.id])
    }

    /// Called by `VideoDetailView.onDisappear` (outside the
    /// fullscreen grace window) to surface the mini-player. The
    /// controller keeps running; only the inline surface goes
    /// away.
    ///
    /// If the user has disabled `miniPlayerOnExit` in
    /// `ProfileSettingsView` we tear the controller down
    /// instead — the user explicitly opted out, so leaving the
    /// video screen should fully stop playback, not leave a
    /// floating window behind.
    func detachInline() {
        // Leaving the detail page never leaves visible or audible
        // playback behind, but the session is retained so a
        // child-route round trip (creator profile, replies) comes
        // back to exactly where the user left off instead of
        // restarting at zero and overwriting the saved position.
        // The controller is torn down when a different video
        // binds, or when PiP ends without the inline view
        // reclaiming the session.
        guard let controller else { return }
        inlineAttached = false
        if controller.isPictureInPictureActive {
            // PiP owns the surface now — keep the player running
            // or the floating window freezes mid-playback.
            diagLog(.playback, "PlaybackStore.detachInline: PiP active, keep running")
            return
        }
        diagLog(.playback, "PlaybackStore.detachInline: pause + retain")
        // Controller-level pause clears `wantsToPlay` — pausing the
        // raw player would leave the intent set, and a still-loading
        // item would then auto-start (audibly!) after the user has
        // already left the page.
        controller.pause()
    }


    func play() {
        controller?.player.play()
    }

    func pause() {
        controller?.player.pause()
    }

    func togglePlayPause() {
        guard let player = controller?.player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            player.play()
        }
    }

    func seek(to seconds: Double) {
        guard let player = controller?.player else { return }
        let target = max(0, min(seconds, duration))
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }

    private func teardownController() {
        watchSession?.stop()
        watchSession = nil
        controller?.tearDown()
        controller = nil
        cancellables.removeAll()
        currentVideo = nil
        pendingPlayback = nil
        currentTime = 0
        duration = 0
        isPlaying = true
        isBuffering = false
        networkSpeed = 0
    }

}
