//
//  LocalHLSProxyServer.swift
//  Paladala
//
//  Loopback HTTP server that synthesises an HLS master playlist
//  for a single `BiliPlayback` and proxies the underlying m4s
//  segments byte-for-byte from the B站 CDN, with the right
//  `Referer` injected.
//
//  Why this exists
//  ---------------
//  B站 increasingly returns DASH manifests for higher-quality
//  sources (1080P+, 4K, 大会员, 杜比). `AVPlayer` cannot
//  play DASH natively.  Standing up a 127.0.0.1 HTTP server
//  and feeding it a master.m3u8 we synthesise in memory is the
//  simplest way to get AVPlayer to play that DASH payload —
//  no third-party SDK, no transcoding, no per-segment hand
//  rolling.
//
//  Architecture
//  ------------
//
//       AVPlayer
//          │  GET http://127.0.0.1:NNNN/playlist.m3u8
//          ▼
//   LocalHLSProxyServer (Network.framework, 127.0.0.1 only)
//          │   ├─  playlist.m3u8 → synthesise HLS master in memory
//          │   ├─  video.m3u8    → synthesise video media playlist
//          │   ├─  audio.m3u8    → synthesise audio media playlist
//          │   └─  seg?u=…       → URLSession.fetch(realURL)
//          │                       + Referer + User-Agent
//          ▼
//       Data → NWConnection.send → AVPlayer
//
//  Notes
//  -----
//  * Loopback only.  The listener binds to 127.0.0.1; no other
//    device on the LAN can reach the port.
//  * iOS 14+ still requires `NSLocalNetworkUsageDescription`
//    even for loopback; the Info.plist declares one.
//  * The server is a process-wide singleton; the singleton
//    pattern matches the previous AliPlayer / bridge approach
//    (one playback at a time per `PlayerController`).
//  * We use Apple's first-party `Network.framework` rather
//    than Swifter / GCDWebServer to keep the dependency
//    surface at zero — the rest of the app is pure AVFoundation.
//

import Foundation
import Darwin
import Network

// MARK: - errors

/// Errors thrown by `LocalHLSProxyServer` itself (as opposed
/// to upstream / SIDX errors, which live under
/// `PlaybackPreparationError`).  Today only the listener-wait
/// timeout pathway surfaces one of these — every other
/// failure mode continues to throw `PlaybackPreparationError`
/// so existing call sites don't have to learn a new error
/// type.
enum ProxyServerError: Error {
    case listenerTimeout
    case lanShareUnavailable(String)
}

extension ProxyServerError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .listenerTimeout:
            return "Timed out while starting the local stream server."
        case .lanShareUnavailable(let reason):
            return reason
        }
    }
}

// MARK: - public surface

/// A 127.0.0.1-only HTTP server that exposes an HLS manifest
/// for a single `BiliPlayback`.  Always access through
/// `LocalHLSProxyServer.shared`.
final class LocalHLSProxyServer: @unchecked Sendable {
    /// OS-chosen port (`0`).  `NWListener.start` picks a real
    /// loopback port on its own; the `requiredLocalEndpoint`
    /// setting in `ensureListener()` uses `.any`, so passing
    /// `0` here is just a placeholder for the field declared
    /// below — the value gets overwritten by the listener's
    /// `.ready` state callback (`p.rawValue`) once the kernel
    /// hands us a port.  Exposed publicly so cold-launch tests
    /// can construct isolated proxy instances via
    /// `@testable import Paladala`.
    static let shared = LocalHLSProxyServer(port: 0)

    /// Optional host → preferred-IP resolver. When set,
    /// `replaceMediaURL(_:)` and `rewrite(_:pinHost:)` will
    /// substitute the resolved IP for the original host
    /// before forwarding upstream. Designed to be set by
    /// `CDNManager` after an akamTester-style speed run so
    /// the lowest-latency IP from the user's vantage point
    /// becomes the "default" target for every segment
    /// request — the "强制使用延迟最低 + 速度最大的端点"
    /// mode.
    ///
    /// `nil` (the default) means "no resolver — use the URL
    /// host verbatim" so the rest of the proxy continues to
    /// work without any customisation.
    ///
    /// **Why this is host-only, not IP-only**: `URLSession`
    /// does not let us specify a different SNI from the URL
    /// host. If we substitute an IP into the URL, the TLS
    /// ClientHello will carry the IP as the SNI and B站's
    /// CDN edge (cert is for `*.akamaized.net`) will reject
    /// it. We work around this by leaving the URL host as
    /// the original domain and just hinting the resolver —
    /// the actual TCP / TLS connection still goes through
    /// the system DNS for now, which (for anycast hosts like
    /// akamai) routes to a nearby edge anyway. A future
    /// revision can swap `URLSession` for `Network.framework`
    /// upstream to lock to a specific IP at the SNI layer.
    var customHostResolver: (@Sendable (String) -> String?)? {
        get { readCustomHostResolver() }
        set { writeCustomHostResolver(newValue) }
    }
    private let customHostResolverLock = NSLock()
    private var _customHostResolver: (@Sendable (String) -> String?)?
    private func readCustomHostResolver() -> (@Sendable (String) -> String?)? {
        customHostResolverLock.lock(); defer { customHostResolverLock.unlock() }
        return _customHostResolver
    }
    private func writeCustomHostResolver(_ resolver: (@Sendable (String) -> String?)?) {
        customHostResolverLock.lock(); defer { customHostResolverLock.unlock() }
        _customHostResolver = resolver
    }

    /// The result of a successful SIDX preparation.  Built
    /// by `preparePlayback(...)` and consumed by
    /// `publishAndStart(...)` which writes the indices into
    /// the proxy's manifest cache.  Value type so it can
    /// cross closure / Task boundaries safely.
    ///
    /// **Not marked `Sendable`** because `TrackSegmentIndex`
    /// itself doesn't declare conformance; the proxy is a
    /// `final class` (not an `actor`), so all async hops
    /// stay on the same instance and the Sendable check
    /// isn't required by the concurrency checker.
    struct PreparedPlayback {
        let video: TrackSegmentIndex
        let audio: TrackSegmentIndex?
    }

    /// Coarse-grained lifecycle state for the proxy.  The
    /// old `baseURL`-only model conflated "NWListener bound a
    /// port" with "the SIDX manifest is ready to serve" —
    /// Build 181's 503 storm was a direct consequence.
    /// `manifestReady` is the only state in which a `URL` is
    /// safe to hand to AVPlayer.
    enum ProxyState: CustomStringConvertible {
        case idle
        case listening(port: UInt16)
        case manifestReady(PreparedPlayback)
        case failed(String)

        var description: String {
            switch self {
            case .idle: return "idle"
            case .listening(let port): return "listening(port: \(port))"
            case .manifestReady(let p):
                return "manifestReady(video: \(p.video.fragments.count), audio: \(p.audio?.fragments.count ?? 0))"
            case .failed(let reason): return "failed(\(reason))"
            }
        }
    }

    /// Returns the proxy's current lifecycle state.  Safe
    /// to call from any queue; reads are protected by
    /// `lock`.  Used by `PlayerController.loadPlayback(...)`
    /// to gate AVPlayer binding on `.manifestReady`.
    var currentState: ProxyState {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    /// Convenience for tests and diagnostics.
    var isManifestReady: Bool {
        if case .manifestReady = currentState { return true }
        return false
    }

    /// Convenience for tests and diagnostics.
    var currentPlaylistURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        guard let baseURL else { return nil }
        return baseURL.appendingPathComponent("playlist.m3u8")
    }

    var currentLANPlaylistURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        guard let lanBaseURL else { return nil }
        if currentLivePlayback != nil {
            return lanBaseURL.appendingPathComponent("live/manifest.m3u8")
        }
        return lanBaseURL.appendingPathComponent("playlist.m3u8")
    }

    enum PlaybackPreparationError: Error, CustomStringConvertible {
        case noDash
        case missingSIDXRange(host: String)
        case sidxFetchFailed(host: String, reason: String)
        case sidxParseFailed(host: String, reason: String)
        case segmentValidationFailed(host: String, reason: String)
        case listenerFailed(String)

        var description: String {
            switch self {
            case .noDash:
                return "playback has no DASH source"
            case .missingSIDXRange(let host):
                return "missing SIDX range for \(host)"
            case .sidxFetchFailed(let host, let reason):
                return "SIDX fetch failed for \(host): \(reason)"
            case .sidxParseFailed(let host, let reason):
                return "SIDX parse failed for \(host): \(reason)"
            case .segmentValidationFailed(let host, let reason):
                return "segment validation failed for \(host): \(reason)"
            case .listenerFailed(let reason):
                return "listener failed: \(reason)"
            }
        }
    }

    private enum RangeFetchError: Error, CustomStringConvertible {
        case invalidResponse
        case unexpectedStatus(Int)
        case missingContentRange
        case mismatchedContentRange(expected: String, actual: String)
        case mismatchedLength(expected: Int, actual: Int)
        case requestFailed(String)
        case timedOut

        var description: String {
            switch self {
            case .invalidResponse:
                return "invalid response"
            case .unexpectedStatus(let status):
                return "unexpected HTTP status \(status)"
            case .missingContentRange:
                return "missing Content-Range"
            case .mismatchedContentRange(let expected, let actual):
                return "Content-Range mismatch expected \(expected), actual \(actual)"
            case .mismatchedLength(let expected, let actual):
                return "length mismatch expected \(expected), actual \(actual)"
            case .requestFailed(let message):
                return "request failed: \(message)"
            case .timedOut:
                return "request timed out"
            }
        }
    }

    /// `http://127.0.0.1:NNNN/` once the listener is ready.
    /// `nil` before the first `serve(playback:)` call hands a
    /// port to us.  The URL is stable for the lifetime of the
    /// process unless `stop()` is called.
    /// **All reads and writes must hold `lock`.**  Use
    /// `safeBaseURL` for safe reads from any queue.
    private(set) var baseURL: URL?
    private var lanBaseURL: URL?

    /// Thread-safe read of `baseURL`.  Holds `lock` for the
    /// duration of the read so it is safe to call from any queue.
    var safeBaseURL: URL? {
        lock.lock(); defer { lock.unlock() }
        return baseURL
    }

    var safeLANBaseURL: URL? {
        lock.lock(); defer { lock.unlock() }
        return lanBaseURL
    }

    /// Async waiter for the listener to bind a port.  Resolves
    /// once `self.listener?.state == .ready`.  Replaces the
    /// legacy 2 s-semaphore-paced `waitForReady` with a tight
    /// 5 ms / 500 ms poll loop — bound by the 2026-07-03
    /// cold-start audit item #8.  The narrower ceiling matters
    /// because the very first call after a long background
    /// used to wait the full 2 s for a listener the OS already
    /// had ready (the proxy was simply rebooting off a cached
    /// listener), and that delay lived on the playback critical
    /// path.
    ///
    /// Returns `Void` (not the bound port): callers that need
    /// the URL/port read `safeBaseURL` / `currentPlaylistURL`
    /// *after* this returns — the listener-state observer has
    /// already populated both by the time `.ready` fires.
    ///
    /// **Important**: this only waits for the *listener* to
    /// be ready.  For the manifest to be available too, use
    /// `publishAndStart(...)`, which composes listener + SIDX
    /// prep + manifest publish into a single awaitable.
    internal func waitForListener(
        timeoutMs: Int = 500,
        pollIntervalMs: Int = 5
    ) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
            // PR-C Task 4: explicit `[weak self]` so the
            // @Sendable Task closure doesn't capture a strong
            // reference to this non-MainActor final class.
            // `cont` is the Continuation, captured strongly on
            // purpose so the Task can resume it; the listener
            // check is the only self access.
            Task { @MainActor [weak self] in
                while true {
                    guard let self else {
                        cont.resume(throwing: CancellationError()); return
                    }
                    // Check readiness before the deadline. The MainActor task
                    // can be scheduled after the nominal timeout even though
                    // NWListener already became ready on its own queue.
                    if let listener = self.listener, listener.state == .ready {
                        cont.resume(); return
                    }
                    if Date() >= deadline {
                        cont.resume(throwing: ProxyServerError.listenerTimeout); return
                    }
                    try? await Task.sleep(nanoseconds: UInt64(pollIntervalMs) * 1_000_000)
                }
            }
        }
    }

    /// Pre-warm the process-wide `LocalHLSProxyServer.shared`
    /// at cold-launch so the very first `serve(playback:)`
    /// doesn't pay the NWListener-bind cost on the playback
    /// critical path.  Best-effort: a failure logs once via
    /// `DiagnosticLogger` and is swallowed — the caller must
    /// never see an exception thrown from cold-launch
    /// housekeeping.
    ///
    /// Calls `ensureListenerAsync()` first so the singleton
    /// actually has a listener running before we poll for
    /// `.ready`; without this, the loop was a no-op and the
    /// 500 ms ceiling always tripped, logging
    /// `proxy_prewarm_failed` on every cold launch.
    /// Idempotent: re-invoking after a listener is already
    /// bound is a cheap no-op (see `ensureListener()`).
    static func prewarmProxyServer() async {
        do {
            let server = LocalHLSProxyServer.shared
            try await server.ensureListenerAsync()
            try await server.waitForListener(timeoutMs: 500, pollIntervalMs: 5)
        } catch {
            diagLog(.playback, "proxy_prewarm_failed",
                    details: ["error": String(describing: error)])
        }
    }

    /// Total bytes streamed from the B站 CDN to AVPlayer.
    /// Sampled by `PlayerController.refresh()` for the
    /// network-speed overlay on the loading screen.
    private(set) var byteCount: Int64 = 0

    // MARK: lifecycle

    /// **Build 182 async entry point.**  Orchestrates the full
    /// prepare-then-publish-then-listen sequence and returns
    /// the playlist URL *only* once the manifest is ready
    /// to be served.  AVPlayer may safely be bound to the
    /// returned URL — it will not see a 503 from a
    /// not-yet-populated SIDX cache.
    ///
    /// **PR-C (Phase 2)**: when `bvid` and `cid` are both
    /// non-nil, the call also kicks off a background
    /// `PlaybackPrefetchManager` download so subsequent
    /// `/segment` requests can serve from disk instead of
    /// the B站 CDN.  Prefetch is best-effort: the manifest
    /// is served regardless of download progress, and the
    /// segment router falls back to the existing Range
    /// path until the local file lands.
    ///
    /// Steps:
    /// 1. Reset the previous playback state while keeping the listener bound.
    /// 2. `beginServing()` bumps the generation counter.
    /// 3. `preparePlayback(...)` fetches and validates SIDX
    ///    for both tracks in parallel.
    /// 4. `publishAndStart(...)` writes the prepared indices
    ///    to the manifest cache, ensures the listener is
    ///    bound, and waits for the listener to be `.ready`.
    func serve(playback: BiliPlayback,
               bvid: String? = nil,
               cid: Int64? = nil) async throws -> URL {
        guard playback.dash != nil else {
            throw PlaybackPreparationError.noDash
        }
        diagLog(.playback, "LocalHLSProxyServer serve started",
                details: [
                    "hasAudio": playback.dash?.audio != nil,
                    "bvid": bvid ?? "",
                    "cid": cid.map(String.init) ?? "",
                    "prefetchable": bvid != nil && cid != nil
                ])
        // Reset the previous VOD session without cancelling the process-wide
        // loopback listener. Cold-start prewarm may already have published
        // this port; cancelling it here lets the old NWListener's delayed
        // .cancelled callback race the replacement listener and clear the
        // new baseURL while manifest preparation is in flight.
        resetPlaybackStateKeepingListener()

        if prepSession == nil {
            prepSession = Self.makePrepSession()
        }

        // Stash playback + context under lock.  Whether we
        // end up reading from disk (localContext) or
        // upstream (CDN) is decided later by `isLocalMode()`
        // based on this same flag.
        setCurrentPlayback(playback)

        // Seed probe cache synchronously when the file is
        // already on disk; otherwise kick off upstream
        // `Range: bytes=0-0` probes so the first media
        // playlist can be multi-segment.
        primeProbesForCurrentPlayback()

        let generation = beginServing()

        // Skip SIDX prep entirely for downloaded playback —
        // the bytes live on disk and the segment router
        // already reads from `localContext`.
        if playback.localContext == nil {
            let prepared = try await preparePlayback(
                playback,
                generation: generation
            )
            try Task.checkCancellation()
            guard generation == currentPrepGenerationValue() else {
                diagLog(.playback, "LocalHLSProxyServer manifest prep stale",
                        details: [
                            "generation": generation,
                            "currentGeneration": currentPrepGenerationValue()
                        ])
                throw CancellationError()
            }
            // **PR-C (Phase 2)**: record the prefetch
            // identity so the segment router can read from
            // the on-disk cache once the prefetch finishes.
            // For the local-mode branch we leave it nil —
            // the local router reads from `localContext`,
            // not from the prefetch cache, so we don't want
            // segment requests to try to look up the wrong
            // bvid/cid.
            // Keep the same quality fallback used by the prefetch
            // trigger.  Some playurl responses omit the selected
            // track's `id`; in that case `selectedVideoQn` is nil,
            // but the prefetch is keyed by the first accept-quality
            // value.  Persisting the resolved qn here lets the
            // segment router find that cache entry after it lands.
            setCurrentIdentity(
                bvid: bvid,
                cid: cid,
                qn: Self.resolvedPrefetchQuality(
                    requested: playback.selectedVideoQn,
                    acceptQuality: playback.acceptQuality
                )
            )
            let url = try await publishAndStart(
                prepared: prepared,
                generation: generation
            )
            // **PR-C (Phase 2)**: kick off the auto-prefetch
            // in the background.  The segment router will
            // serve the first few segments from the existing
            // B站 Range path while the prefetch downloads;
            // once the file lands on disk the router
            // automatically switches to the local copy
            // (commit 2 of this series).  No-op when either
            // bvid or cid is missing — the caller didn't
            // have the identity handy, e.g. for the LAN
            // share helper.
            triggerPrefetchIfPossible(
                bvid: bvid, cid: cid,
                qn: playback.selectedVideoQn,
                playback: playback
            )
            return url
        } else {
            // Local playback: no SIDX prep.  Just ensure
            // the listener, wait for `.ready`, and emit
            // an empty `PreparedPlayback` whose `video` is
            // placeholder (the HTTP router never reads it
            // for the local code path).
            // We pass the video track from the local
            // manifest so the router's `cachedSegmentIndex`
            // short-circuits correctly.
            guard let placeholder = localOnlyPlaceholder(playback: playback) else {
                throw PlaybackPreparationError.noDash
            }
            // Local path: write the placeholder as the
            // manifest so `currentState` is `.manifestReady`.
            return try await publishAndStart(
                prepared: placeholder,
                generation: generation
            )
        }
    }

    /// Build a placeholder `PreparedPlayback` for the local
    /// (downloaded) playback path.  The HTTP router for
    /// local-mode reads bytes directly from disk and never
    /// asks for `video.fragments`, so the placeholder can
    /// carry an empty index as long as the cache lookup
    /// returns it consistently.
    private func localOnlyPlaceholder(playback: BiliPlayback) -> PreparedPlayback? {
        // We need a real TrackSegmentIndex for the cache
        // write; synthesize a zero-fragment one that the
        // HTTP handlers will ignore (local routing path
        // reads from `localContext`, not from the SIDX
        // index).
        guard let dash = playback.dash else { return nil }
        let initRange = dash.video.initializationRange
        let placeholderRange = initRange.offset..<(initRange.offset + initRange.length)
        let placeholder = TrackSegmentIndex(
            initializationRange: placeholderRange,
            fragments: [],
            timescale: 1,
            firstMediaOffset: 0,
            sidxRange: nil,
            totalDuration: 0
        )
        return PreparedPlayback(video: placeholder, audio: nil)
    }

    /// **PR-C (Phase 2)**: kick off the background auto-
    /// prefetch for a freshly-served playback.  No-op when
    /// any of bvid / cid / qn is missing — the caller
    /// didn't have the identity handy (e.g. LAN share).
    /// Detached at `.utility` so the segment router isn't
    /// held up by the download scheduler.
    private func triggerPrefetchIfPossible(
        bvid: String?,
        cid: Int64?,
        qn: Int?,
        playback: BiliPlayback
    ) {
        // **PR-C (Phase 2 — fix)**: B站's playurl response
        // does not always include the `id` field on the
        // selected DASH video track, so `playback.selectedVideoQn`
        // (which we get via `dash.video.qualityId`) is
        // frequently nil.  Without a qn we have no
        // stable cache key and the original
        // `guard let qn else { return }` silently
        // skipped the prefetch.  Fall back to the
        // highest qn the upstream is willing to serve
        // (the first entry of `acceptQuality`, which is
        // B站's reported ladder).  Different qn values
        // get separate cache entries anyway, so a wrong
        // fallback just causes a one-time re-download
        // the first time the user picks a different
        // quality — not a correctness issue.
        let resolvedQn = Self.resolvedPrefetchQuality(
            requested: qn,
            acceptQuality: playback.acceptQuality
        )
        // **PR-C (Phase 2 — fix, take 2)**: route these
        // through `diagLog(.playback, ...)` rather than
        // `bpLog(...)`.  The previous take-1 fix used
        // `bpLog`, which only writes to
        // `Logger.shared.logs` (cap 1000, in-memory), and
        // the diagnostic export only takes the LAST 100
        // of those via `suffix(100)`.  Build 327 confirmed
        // the truncation: a hot-path video with hundreds
        // of `loadedTimeRanges` / `upstream response` log
        // lines pushed the trigger entry out of the tail
        // window even though the function ran.  `diagLog`
        // persists into `DiagnosticLogger.events` and the
        // on-disk `log.jsonl`, both of which are dumped
        // verbatim into the diagnostic report's
        // `Diagnostic events` section.
        guard let bvid, let cid, let resolvedQn else {
            diagLog(.playback, "LocalHLSProxyServer triggerPrefetch skipped",
                    details: [
                        "bvid": bvid ?? "nil",
                        "cid": cid.map(String.init) ?? "nil",
                        "requestedQn": qn.map(String.init) ?? "nil",
                        "resolvedQn": resolvedQn.map(String.init) ?? "nil",
                        "acceptQualityFirst":
                            playback.acceptQuality?.first.map(String.init)
                            ?? "nil",
                        "hasDash": playback.dash != nil ? "true" : "false"
                    ])
            return
        }
        diagLog(.playback, "LocalHLSProxyServer triggerPrefetch firing",
                details: [
                    "bvid": bvid,
                    "cid": String(cid),
                    "qn": String(resolvedQn),
                    "requestedQn": qn.map(String.init) ?? "nil",
                    "acceptQualityFirst":
                        playback.acceptQuality?.first.map(String.init)
                        ?? "nil",
                    "hasDash": playback.dash != nil ? "true" : "false"
                ])
        Task.detached(priority: .utility) {
            await PlaybackPrefetchManager.shared.prefetch(
                bvid: bvid, qn: resolvedQn, cid: cid, playback: playback
            )
        }
    }

    /// Resolves the quality used in the prefetch cache key. Bilibili
    /// sometimes omits the selected track's representation id, while
    /// still returning `accept_quality`; both the trigger and the
    /// segment router must use this exact fallback to address the same
    /// cache entry.
    static func resolvedPrefetchQuality(
        requested: Int?,
        acceptQuality: [Int]?
    ) -> Int? {
        requested ?? acceptQuality?.first
    }

    /// Begin a new serving generation.  Bumps
    /// `currentPrepGeneration` under `lock` and clears any
    /// stale manifest state.  Returns the new generation
    /// value; the caller passes it through to `preparePlayback`
    /// and `publishAndStart` to keep them mutually consistent.
    func beginServing() -> UInt64 {
        lock.lock()
        // Preserve the no-reset invariant introduced for
        // Build 182: even `stop()` no longer resets the
        // counter to zero, so an in-flight prep never sees
        // its captured generation suddenly become "stale".
        // We still clear the manifest cache here because
        // a brand-new playback has different bytes.
        trackSegmentIndex.removeAll()
        decidedModes.removeAll()
        failoverIndex.removeAll()
        currentPrepGeneration &+= 1
        let newGeneration = currentPrepGeneration
        lock.unlock()
        diagLog(.playback, "LocalHLSProxyServer generation bumped",
                details: ["generation": newGeneration])
        return newGeneration
    }

    /// Thread-safe read of `currentPrepGeneration` for
    /// callers (like the playlist handler) that compare a
    /// captured generation against the current value.
    func currentPrepGenerationValue() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        return currentPrepGeneration
    }

    private func setCurrentPlayback(_ playback: BiliPlayback) {
        lock.lock()
        currentPlayback = playback
        localContext = playback.localContext
        lock.unlock()
    }

    /// **PR-C (Phase 2 — local-prefetch routing)**: stash the
    /// bvid + cid that identify the active prefetch cache
    /// entry, so the segment router can match incoming
    /// `/segment` requests to on-disk bytes.  Set under
    /// `lock` by `serve(playback:bvid:cid:)`; cleared by
    /// `stop()`.  `nil` for non-prefetchable paths
    /// (downloaded playback via `serveLocal(playback:)`,
    /// LAN share, live).
    private func setCurrentIdentity(
        bvid: String?, cid: Int64?, qn: Int?
    ) {
        lock.lock()
        currentBvid = bvid
        currentCid = cid
        currentQn = qn
        lock.unlock()
    }

    private func setCurrentLivePlayback(_ playback: BiliLivePlayback) {
        lock.lock()
        currentLivePlayback = playback
        lock.unlock()
    }

    private func setFailoverIndex(_ index: Int, for primaryURL: URL) {
        lock.lock()
        failoverIndex[primaryURL] = index
        lock.unlock()
    }

    private func publishPreparedManifest(_ prepared: PreparedPlayback) -> (URL?, URL?) {
        lock.lock()
        let videoURL = currentPlayback?.dash?.video.baseURL
        let audioURL = currentPlayback?.dash?.audio?.baseURL
        trackSegmentIndex.removeAll()
        decidedModes.removeAll()
        if let videoURL {
            trackSegmentIndex[videoURL] = prepared.video
        }
        if let audio = prepared.audio, let audioURL {
            trackSegmentIndex[audioURL] = audio
        }
        state = .manifestReady(prepared)
        lock.unlock()
        return (videoURL, audioURL)
    }

    private func isServing(playback: BiliPlayback) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard currentPlayback == playback, baseURL != nil else { return false }
        if case .manifestReady = state { return true }
        return false
    }

    private func ensureShareablePlaybackState() throws {
        lock.lock()
        let hasLive = currentLivePlayback != nil
        let hasVOD: Bool = {
            guard currentPlayback != nil, baseURL != nil else { return false }
            if case .manifestReady = state { return true }
            return false
        }()
        lock.unlock()
        guard hasLive || hasVOD else {
            throw ProxyServerError.lanShareUnavailable("No prepared playback to share")
        }
    }

    private static func primaryLANIPv4Address() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else {
            return nil
        }
        defer { freeifaddrs(ifaddr) }

        var candidates: [(score: Int, address: String)] = []
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = ptr {
            defer { ptr = interface.pointee.ifa_next }
            let flags = Int32(interface.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0,
                  (flags & IFF_LOOPBACK) == 0,
                  let addr = interface.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                addr,
                socklen_t(MemoryLayout<sockaddr_in>.size),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }
            let name = String(cString: interface.pointee.ifa_name)
            let address = String(cString: host)
            let score: Int
            if name == "en0" {
                score = 0
            } else if name.hasPrefix("en") {
                score = 1
            } else if name.hasPrefix("bridge") || name.hasPrefix("utun") {
                score = 10
            } else {
                score = 5
            }
            candidates.append((score, address))
        }
        return candidates.sorted { lhs, rhs in
            if lhs.score == rhs.score { return lhs.address < rhs.address }
            return lhs.score < rhs.score
        }.first?.address
    }

    /// Serve a Bilibili live HLS stream.
    ///
    /// Live streams are different from the VOD case in two ways:
    ///   1. There is no DASH source — the upstream gives us a
    ///      pre-built `playlist.m3u8` whose segment URIs point
    ///      directly at the B站 CDN.
    ///   2. The m3u8 is **live** — every refresh (every few
    ///      seconds) can list new segments and the proxy must
    ///      re-fetch on each request, not synthesise a static
    ///      playlist from a SIDX.
    ///
    /// We solve this by:
    ///   - caching the upstream m3u8 URL + referer in
    ///     `currentLivePlayback`,
    ///   - returning a `127.0.0.1/live/manifest.m3u8` URL that
    ///     AVPlayer binds to,
    ///   - serving `/live/manifest.m3u8` by fetching the
    ///     upstream m3u8 with the proper `Referer` + iOS UA,
    ///     rewriting every segment URI back through the proxy
    ///     (`/live/seg?u=<base64url>`),
    ///   - serving `/live/seg?u=...` as a byte-passthrough
    ///     (reusing the same upstream-host + Referer rules
    ///     that the VOD `proxySegment(..., .passthrough)`
    ///     path enforces).
    ///
    /// CDNs in `playback.hlsCandidates` are tried in order on
    /// each manifest fetch; the first one that returns 200 wins,
    /// and the manifest rewrites reflect the *winning* URL.
    /// If all CDNs 403/404 the proxy surfaces a 502 to AVPlayer
    /// so it can report a transient upstream failure.
    func serveLive(playback: BiliLivePlayback) async throws -> URL {
        guard !playback.hlsCandidates.isEmpty else {
            throw PlaybackPreparationError.noDash
        }
        diagLog(.playback, "LocalHLSProxyServer serveLive started",
                details: [
                    "roomID": playback.roomID,
                    "candidates": playback.hlsCandidates.count
                ])

        // Start the listener if it isn't already up.  The VOD
        // path (`serve(_:)` / `publishAndStart(_:)`) goes
        // through `ensureListenerAsync(...)` on its own, but the
        // live path used to just *wait* for an existing listener
        // — when a user opens a live room as their very first
        // playback (no prior VOD), no listener exists yet, so
        // `waitForListener` timed out at its 2 s deadline and
        // `LivePlayerView.loadPlayback(...)` silently fell back to
        // the direct CDN URL, where AVPlayer 403s on signed m3u8
        // segments.  Surfaced via the build-195 diagnostic report
        // (room 7734200, 2026-07-06): the gap between
        // "serveLive started" and "Initialising AVPlayerController
        // using direct asset" was exactly 2 005 ms.
        try await ensureListenerAsync()

        // Wait for the listener to report `.ready` before
        // returning.  We do not need the SIDX-prep /
        // manifest-publish pipeline the VOD path uses, but we
        // still need a port to point AVPlayer at.
        try await waitForListener()

        // Stash the live state under lock.  Routes read it on
        // every request so swapping `serveLive(...)` is
        // immediately observable.
        setCurrentLivePlayback(playback)

        guard let base = safeBaseURL else {
            throw PlaybackPreparationError.noDash
        }
        return base.appendingPathComponent("live/manifest.m3u8")
    }

    /// SIDX preparation for the current playback.  Replaces
    /// the old `prepareRemotePlayback(_:)` and runs video +
    /// audio in parallel via two `async let` bindings wrapped
    /// in `raceWithDeadline` so the 10-second build-180
    /// hang-guard is preserved.
    func preparePlayback(
        _ playback: BiliPlayback,
        generation: UInt64
    ) async throws -> PreparedPlayback {
        guard let dash = playback.dash else {
            throw PlaybackPreparationError.noDash
        }
        let referer = playback.referer.absoluteString
        diagLog(.playback, "Playback manifest prep started", details: [
            "generation": generation,
            "hasAudio": dash.audio != nil
        ])
        defer {
            // No-op defer — error logging happens in catch
            // blocks below so we can include the generation.
        }

        // Per-track deadline: protects against upstream
        // hang on the first byte-range fetch.  Even with
        // video + audio in parallel, each track is still
        // bounded to 10 s wall-clock — without this, a
        // single hung fetch could swallow the entire
        // startup budget.
        let perTrackDeadlineSeconds: Double = 10

        do {
            // Prepare both tracks concurrently. The previous sequential
            // awaits made audio start only after video validation, so a
            // slow audio CDN could be cancelled during music startup.
            async let videoIndex = raceWithDeadline(
                seconds: perTrackDeadlineSeconds,
                label: "video"
            ) {
                try await self.prepareTrackSegmentIndex(
                    dash.video, kind: "video", referer: referer
                )
            }
            async let audioIndex = self.prepareOptionalAudioIndex(
                dash.audio,
                referer: referer,
                deadline: perTrackDeadlineSeconds
            )

            let preparedVideo = try await videoIndex
            let preparedAudio = try await audioIndex

            diagLog(.playback, "Playback manifest prep completed", details: [
                "generation": generation,
                "videoReferences": preparedVideo.fragments.count,
                "audioReferences": preparedAudio?.fragments.count ?? 0
            ])
            return PreparedPlayback(video: preparedVideo, audio: preparedAudio)
        } catch let err where err is CancellationError {
            // The user (or `retryPlayback()`) cancelled the
            // load — that's a normal teardown, not a
            // failure.  Log it under a distinct channel so
            // the diagnostic dump no longer reads "Playback
            // manifest prep failed" every time the user
            // switches source / host mid-prep.  Real
            // failures still hit the catch-all below.
            diagLog(.playback, "Playback manifest prep cancelled", details: [
                "generation": generation
            ])
            throw err
        } catch {
            diagLog(.playback, "Playback manifest prep failed", details: [
                "generation": generation,
                "error": "\(error)"
            ])
            throw error
        }
    }

    private func prepareOptionalAudioIndex(
        _ track: BiliDashSource.Track?,
        referer: String,
        deadline: Double
    ) async throws -> TrackSegmentIndex? {
        guard let track else { return nil }
        return try await raceWithDeadline(
            seconds: deadline,
            label: "audio"
        ) {
            try await self.prepareTrackSegmentIndex(
                track, kind: "audio", referer: referer
            )
        }
    }

    /// Race `work` against a deadline sleep.  Whichever
    /// finishes first wins; the loser is cancelled.  Used
    /// to preserve the per-track 10s budget introduced in
    /// build 180 when the parallel `async let` shape would
    /// otherwise lose the timeout.
    private func raceWithDeadline<T: Sendable>(
        seconds: Double,
        label: String,
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await work()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw PlaybackPreparationError.segmentValidationFailed(
                    host: label,
                    reason: "\(label) prep deadline"
                )
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw PlaybackPreparationError.segmentValidationFailed(
                    host: label,
                    reason: "\(label) prep produced no result"
                )
            }
            return first
        }
    }

    /// Write the prepared manifest to the proxy's cache and
    /// ensure the listener is bound.  Awaits the listener's
    /// `.ready` state and returns the playlist URL only
    /// after `state == .manifestReady`.  Returns the
    /// generation match check; if a newer prep superseded
    /// this one while we were awaiting, throws
    /// `CancellationError` so the caller can return without
    /// binding AVPlayer.
    func publishAndStart(
        prepared: PreparedPlayback,
        generation: UInt64
    ) async throws -> URL {
        // Generation gate — refuse to publish if the
        // current generation has moved on.
        guard generation == currentPrepGenerationValue() else {
            diagLog(.playback, "LocalHLSProxyServer publishAndStart stale",
                    details: [
                        "generation": generation,
                        "currentGeneration": currentPrepGenerationValue()
                    ])
            throw CancellationError()
        }

        // Look up the URL keys for the cache from the
        // active playback (PreparedPlayback doesn't carry
        // them — TrackSegmentIndex is opaque to its DTO).
        // Read under `lock` so a concurrent `stop()`
        // can't nil out `currentPlayback` mid-publish.
        let videoURL: URL?
        let audioURL: URL?
        (videoURL, audioURL) = publishPreparedManifest(prepared)

        diagLog(.playback, "Playback manifest ready", details: [
            "generation": generation,
            "videoReferences": prepared.video.fragments.count,
            "audioReferences": prepared.audio?.fragments.count ?? 0
        ])

        // Ensure listener is running and wait for it.
        try await ensureListenerAsync()
        try await waitForListener()

        guard let url = currentPlaylistURL else {
            throw PlaybackPreparationError.listenerFailed("listener bound but baseURL is nil")
        }
        return url
    }

    /// Async variant of `ensureListener()`.  Idempotent;
    /// starts the listener if not already running.
    func ensureListenerAsync() async throws {
        if listener != nil { return }
        try ensureListener()
    }

    /// Seed `probedSizes` / kick off upstream size probes
    /// for the current playback.  Pulled out of `serve()`
    /// so `serveLocal()` and `serve(playback:) async`
    /// share the same probe behaviour.
    private func primeProbesForCurrentPlayback() {
        guard let playback = currentPlayback else { return }
        if let local = playback.localContext {
            if let video = playback.dash?.video {
                registerLocalFileSize(
                    for: video,
                    directory: local.directory,
                    fileName: "video.media"
                )
            }
            if let audio = playback.dash?.audio {
                registerLocalFileSize(
                    for: audio,
                    directory: local.directory,
                    fileName: "audio.media"
                )
            }
        } else {
            let referer = playback.referer.absoluteString
            if let video = playback.dash?.video {
                startMediaTotalProbe(for: video, referer: referer)
            }
            if let audio = playback.dash?.audio {
                startMediaTotalProbe(for: audio, referer: referer)
            }
            for track in [playback.dash?.video, playback.dash?.audio]
                .compactMap({ $0 }) {
                for backup in track.backupURLs {
                    startMediaTotalProbe(forBackup: backup, referer: referer)
                }
            }
        }
    }

    /// Clear per-playback state while retaining the process-wide loopback
    /// listener and its stable base URL. `serve(playback:)` uses this when
    /// switching VOD sessions; full lifecycle teardown still goes through
    /// `stop()`. Keeping the listener avoids an old NWListener cancellation
    /// callback clearing the URL published by a newly-created listener.
    private func resetPlaybackStateKeepingListener() {
        var streamsToCancel: [StreamingProxyTask] = []
        lock.lock()
        currentPlayback = nil
        localContext = nil
        currentLivePlayback = nil
        currentBvid = nil
        currentCid = nil
        currentQn = nil
        probedSizes.removeAll()
        probeInFlight.removeAll()
        failedProbes.removeAll()
        failoverIndex.removeAll()
        trackSegmentIndex.removeAll()
        decidedModes.removeAll()
        inFlightRanges.removeAll()
        streamsToCancel = Array(activeStreams.values)
        activeStreams.removeAll()
        if baseURL != nil, port != 0 {
            state = .listening(port: port)
        } else {
            state = .idle
        }
        lock.unlock()
        for stream in streamsToCancel {
            stream.cancel()
        }
        diagLog(.playback, "LocalHLSProxyServer playback state reset",
                details: ["keptListener": listener != nil])
    }

    /// Stop the server.  After this call `baseURL` is `nil`
    /// and any in-flight connections are cancelled.  Calling
    /// `serve(playback:)` again will start a fresh listener
    /// (with a new OS-assigned port).
    func stop() {
        // **PR-B B6**: per-resource diagnostic logs so a
        // user-initiated stop mid-stream produces forensic
        // evidence of which subsystem died first.  The
        // final aggregate `"LocalHLSProxyServer stopped"`
        // log line at the end still fires as a summary.
        var streamsToCancel: [StreamingProxyTask] = []
        let hadPrep = prepSession != nil
        diagLog(.proxy, "stop: cancelling prepSession",
                details: ["hadSession": hadPrep])
        // Cancel any in-flight SIDX preparation *before* we
        // clear the dictionaries it writes to.  Build 182:
        // prep runs inline in `serve(playback:) async`; the
        // awaiting task is the caller's `loadTask`, and
        // cancellation propagates via `Task.checkCancellation`
        // inside the prep body.  URLSession invalidate
        // below drops any in-flight `URLSessionDataTask`s
        // even if the cooperative cancellation has not
        // landed yet.
        prepSession?.invalidateAndCancel()
        prepSession = nil
        let hadListener = listener != nil
        diagLog(.proxy, "stop: listener.cancel",
                details: ["hadListener": hadListener])
        listener?.cancel()
        listener = nil
        lanListener?.cancel()
        lanListener = nil
        lock.lock()
        currentPlayback = nil
        localContext = nil
        currentLivePlayback = nil
        // **PR-C (Phase 2)**: drop the active prefetch
        // identity so a subsequent `serve(...)` for a
        // different video doesn't try to read segments from
        // the previous video's cache entry.
        currentBvid = nil
        currentCid = nil
        currentQn = nil
        // Drop cached upstream probes too — after a long
        // background the cached byte sizes may belong to a
        // CDN file that has since been re-ranged.
        probedSizes.removeAll()
        probeInFlight.removeAll()
        // Failover cursors also reset on stop — a new
        // playback should always start on its primary CDN.
        failoverIndex.removeAll()
        // Drop parsed SIDX indices — they belong to the
        // playback we just stopped. The next serve(playback:)
        // will re-fetch + parse for the new video.
        trackSegmentIndex.removeAll()
        // Clear session-mode decisions so the next playback
        // re-evaluates SIDX availability from scratch.
        decidedModes.removeAll()
        // Build 182: do NOT reset `currentPrepGeneration` to 0.
        // An in-flight prep's captured `myGeneration` would
        // suddenly become stale and the result would be
        // discarded.  Bumping happens in `beginServing()` at
        // the start of every new playback — that's the
        // single source of truth for "is this prep still
        // current?".
        inFlightRanges.removeAll()
        let streamCount = activeStreams.count
        diagLog(.proxy, "stop: cancelling streams",
                details: ["count": streamCount])
        streamsToCancel = Array(activeStreams.values)
        activeStreams.removeAll()
        port = 0
        baseURL = nil
        lanBaseURL = nil
        state = .idle
        lock.unlock()
        for stream in streamsToCancel {
            stream.cancel()
        }
        diagLog(.playback, "LocalHLSProxyServer stopped")
    }

    /// Recreate the proxy from scratch.  Equivalent to
    /// `stop()` followed by a forced listener drop — used by
    /// the lifecycle handler in `RootView` when the app
    /// returns from a long background, because iOS will have
    /// suspended the `NWListener` and the `URLSession`
    /// upstream legs while we were backgrounded, and the
    /// listener's `state` callback never fires the
    /// `.cancelled` we rely on for detection.  Without this,
    /// every video opened after a long lock screen returns
    /// `NSURLError -1004 "Could not connect to the server."`
    /// because the proxy is alive-but-dead.  Calling this
    /// guarantees the next `serve(playback:)` rebuilds the
    /// listener on a fresh port.
    func recreateForResume() {
        let wasRunning = (listener != nil)
        stop()
        diagLog(.playback, "LocalHLSProxyServer recreateForResume",
                details: ["wasRunning": wasRunning])
    }

    /// Serve a `BiliPlayback` whose bytes are already on
    /// disk.  Same wire contract as `serve(playback:)` —
    /// AVPlayer sees a 127.0.0.1 loopback HTTP server
    /// returning HLS — but the init / media bytes are read
    /// from `playback.localContext.directory` instead of
    /// the B 站 CDN.  Falls back to `serve(playback:) async`
    /// if `playback.localContext` is `nil`, so callers can
    /// use `serveLocal` as a single entry point.
    ///
    /// **Build 182**: now async and routes through the same
    /// `serve(playback:)` orchestrator (which detects the
    /// `localContext` and skips SIDX prep).  Retained as a
    /// named entry point so future callers (e.g. the
    /// download manager) can dispatch to the right path
    /// without inspecting `localContext`.
    func serveLocal(playback: BiliPlayback) async throws -> URL {
        return try await serve(playback: playback)
    }

    /// Start a second listener bound to all local interfaces and
    /// return a shareable HLS URL for devices on the same LAN.
    /// The normal player keeps using the loopback listener; this
    /// method only exposes the already-prepared manifest/cache.
    func lanShareURL(for playback: BiliPlayback) async throws -> URL {
        if !isServing(playback: playback) {
            _ = try await serve(playback: playback)
        }
        try ensureShareablePlaybackState()
        try await ensureLANListenerAsync()
        try await waitForLANListener()
        guard let url = currentLANPlaylistURL else {
            throw ProxyServerError.lanShareUnavailable("LAN listener has no URL")
        }
        return url
    }

    /// Idempotent listener bootstrap.  Pulled out of
    /// `serve(playback:)` so `serveLocal(playback:)` can
    /// reuse the exact same listener setup.
    private func ensureListener() throws {
        if listener != nil { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: .any
        )
        let listener = try NWListener(using: params)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let p = self.listener?.port {
                    self.lock.lock()
                    self.port = p.rawValue
                    self.baseURL = URL(
                        string: "http://127.0.0.1:\(p.rawValue)"
                    )
                    // Update coarse-grained state to
                    // `.listening`.  Only moves to
                    // `.manifestReady` after `publishAndStart`
                    // has written the SIDX cache.
                    if case .listening = self.state {
                        // Already listening; idempotent.
                    } else if case .manifestReady = self.state {
                        // Don't downgrade — a ready listener
                        // with a published manifest stays
                        // `.manifestReady`.
                    } else {
                        self.state = .listening(port: p.rawValue)
                    }
                    let issuedURL = self.baseURL?.absoluteString ?? "nil"
                    let issuedGen = self.currentPrepGeneration
                    self.lock.unlock()
                    diagLog(.playback, "LocalHLSProxyServer listener ready",
                            details: ["port": p.rawValue])
                    // PR-A Group 2: emit `session_url_issued`
                    // alongside the listener-ready signal so the
                    // diagnostic log shows which URL was actually
                    // bound to this prep generation.  Without
                    // this, a crash report or stale-segment 503
                    // has to be cross-referenced against the
                    // generation log to find the URL — and the
                    // generation log doesn't include the URL.
                    diagLog(.playback, "session_url_issued", details: [
                        "url": issuedURL,
                        "generation": issuedGen
                    ])
                }
            case .failed(let error):
                self.lock.lock()
                if case .manifestReady = self.state {
                    // Don't downgrade — keep the manifest
                    // available; the next request will surface
                    // the listener failure.
                } else {
                    self.state = .failed(error.localizedDescription)
                }
                self.lock.unlock()
                diagLog(.playback, "LocalHLSProxyServer listener failed",
                        details: ["error": error.localizedDescription])
            case .cancelled:
                self.lock.lock()
                self.port = 0
                self.baseURL = nil
                if case .listening = self.state {
                    self.state = .idle
                }
                // `.manifestReady` is preserved — the
                // manifest cache is still valid; the next
                // `ensureListener` will rebind the port.
                self.lock.unlock()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection: connection)
        }
        listener.start(queue: queue)
    }

    private func ensureLANListenerAsync() async throws {
        if lanListener != nil, lanBaseURL != nil { return }
        try ensureLANListener()
    }

    private func ensureLANListener() throws {
        if lanListener != nil { return }
        guard let lanAddress = Self.primaryLANIPv4Address() else {
            throw ProxyServerError.lanShareUnavailable("No Wi-Fi or LAN IPv4 address")
        }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.any),
            port: .any
        )
        let listener = try NWListener(using: params)
        lanListener = listener
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let p = listener.port {
                    self.lock.lock()
                    self.lanBaseURL = URL(
                        string: "http://\(lanAddress):\(p.rawValue)"
                    )
                    let issuedURL = self.lanBaseURL?.absoluteString ?? "nil"
                    self.lock.unlock()
                    diagLog(.proxy, "LAN stream listener ready",
                            details: ["url": issuedURL])
                }
            case .failed(let error):
                self.lock.lock()
                self.lanBaseURL = nil
                self.lock.unlock()
                diagLog(.proxy, "LAN stream listener failed",
                        details: ["error": error.localizedDescription])
            case .cancelled:
                self.lock.lock()
                self.lanBaseURL = nil
                self.lock.unlock()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection: connection)
        }
        listener.start(queue: queue)
    }

    private func waitForLANListener(
        timeoutMs: Int = 500,
        pollIntervalMs: Int = 5
    ) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
            Task { [weak self] in
                while Date() < deadline {
                    guard let self else {
                        cont.resume(throwing: CancellationError()); return
                    }
                    if self.currentLANPlaylistURL != nil {
                        cont.resume(); return
                    }
                    try? await Task.sleep(nanoseconds: UInt64(pollIntervalMs) * 1_000_000)
                }
                cont.resume(throwing: ProxyServerError.listenerTimeout)
            }
        }
    }

    /// Stat the on-disk m4s file for `track` and seed the
    /// probe cache with the byte count.  `track.baseURL` is
    /// the upstream CDN URL — we still key the cache by
    /// that URL so failover diagnostics use the same lookup
    /// shape for local and remote playback.
    private func registerLocalFileSize(
        for track: BiliDashSource.Track,
        directory: URL,
        fileName: String
    ) {
        let url = directory.appendingPathComponent(fileName)
        // PR-B B10: previously a missing local m4s file
        // silently fell through the `try?` to the next
        // resolution path.  Now logged so an operator can
        // tell whether a download was attempted at all
        // (probe cache populated) vs. a local file was
        // missing from disk (probe cache empty + log line).
        let attrs: [FileAttributeKey: Any]
        do {
            attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            diagLog(.network,
                    "registerLocalFileSize: stat failed",
                    details: [
                        "path": url.path,
                        "error": error.localizedDescription
                    ])
            return
        }
        guard let attrs = attrs as [FileAttributeKey: Any]?,
              let size = attrs[.size] as? Int64,
              size > 0 else {
            bpLog("LocalHLSProxyServer local file size failed: \(url.path)")
            Analytics.recordError(
                NSError(domain: "paladala.proxy", code: 0, userInfo: [
                    NSLocalizedDescriptionKey: "local file size failed",
                    "path": url.path
                ]),
                context: "proxy_localFileSize"
            )
            return
        }
        lock.lock()
        probedSizes[track.baseURL] = size
        lock.unlock()
    }

    // MARK: internals

    private let queue = DispatchQueue(label: "Paladala.LocalHLSProxy")
    fileprivate let lock = NSRecursiveLock()
    private var listener: NWListener?
    private var lanListener: NWListener?
    /// Test seam — exposes the listener's current state for XCTest assertions.
    /// Mirrors the `private(set) var baseURL: URL?` access pattern used elsewhere.
    internal var listenerState: NWListener.State? { listener?.state }
    /// Test seam — cancels the underlying `NWListener` so XCTest's `tearDown`
    /// can release the loopback port bound by `prewarmProxyServer()` without
    /// reaching into the still-`private` `listener` property (which is not
    /// visible across module boundaries even with `@testable import`).
    internal func cancelListenerForTest() { listener?.cancel() }
    private var port: UInt16 = 0
    private var currentPlayback: BiliPlayback?
    /// **PR-C (Phase 2)**: identity of the active prefetch
    /// cache entry.  See `setCurrentIdentity(bvid:cid:qn:)` for
    /// lifetime.  Read by `proxySegment` / `proxySegmentRange`
    /// to route a segment request to the on-disk bytes when
    /// the prefetch has completed.
    private var currentBvid: String?
    private var currentCid: Int64?
    /// Resolved video quality used by the active prefetch entry.
    /// This is usually `dash.video.qualityId`, but falls back to
    /// `acceptQuality.first` when Bilibili omits the track id.
    private var currentQn: Int?
    /// Live playback state.  Mirrors `currentPlayback` for the
    /// `/live/manifest.m3u8` + `/live/seg` routes; null when the
    /// last `serve(playback:)` was a VOD stream (or nothing).
    private var currentLivePlayback: BiliLivePlayback?
    /// Long-lived `URLSession` used by the SIDX-preparation code
    /// path.  Replaces the per-call ephemeral `URLSession` that
    /// the original sync implementation created inside
    /// `fetchExactRange` — one session per playback keeps the
    /// TCP/TLS handshake cost down and gives `stop()` a single
    /// target to `invalidateAndCancel()` when a new playback
    /// supersedes an in-flight preparation.  Recreated lazily on
    /// next `serve(playback:)` if `stop()` invalidated it.
    private var prepSession: URLSession?
    /// `Task` running the current SIDX preparation.  Held so
    /// `stop()` can cancel an in-flight prep the next time the
    /// user opens a video (or `recreateForResume()` is called
    /// after returning from background).
    ///
    /// **Build 182**: prep runs inline inside `serve(playback:)
    /// async` via `await`, so cancellation propagates via
    /// `Task.checkCancellation` checks inside the prep body
    /// rather than a stored handle.  This field is kept as
    /// documentation only — a future caller that kicks off
    /// background prep can resume storing it here.
    private var preparationTask: Task<Void, Error>? = nil
    /// Generation counter bumped at the start of every
    /// `preparePlayback`.  Snapshotted alongside
    /// `decidedModes` so a `/video.m3u8` request that captured
    /// the previous playback's mode decision does not leak
    /// through after the proxy re-serves with a new playback.
    /// **Build 182**: never reset to `0`.  `stop()` leaves
    /// the counter alone so an in-flight prep never sees its
    /// captured generation suddenly become stale; the bump
    /// lives entirely in `beginServing()`.
    fileprivate var currentPrepGeneration: UInt64 = 0

    /// Coarse-grained lifecycle state.  Updated under `lock`
    /// by `ensureListener()` and `publishAndStart(...)`.
    /// Read by `PlayerController.loadPlayback(...)` to gate
    /// AVPlayer binding on `.manifestReady`.  See
    /// `ProxyState` for the rationale.
    fileprivate var state: ProxyState = .idle
    /// When the active playback is a downloaded video, this
    /// points at the on-disk directory holding its init/media
    /// m4s files.  Set by `serveLocal(playback:)`; the
    /// segment router reads it to decide whether to fetch
    /// from disk vs. the upstream CDN.
    private var localContext: LocalPlaybackContext?
    private var activeStreams: [UUID: StreamingProxyTask] = [:]
    /// Tracks in-flight upstream byte ranges so we can detect and
    /// resolve overlaps when AVPlayer issues concurrent sub-segment
    /// requests (e.g., two overlapping `/media` ranges for the same
    /// CDN URL).  Key is the upstream URL string, value is the range
    /// start/end plus the stream ID holding that range.
    fileprivate var inFlightRanges: [String: (start: Int64, end: Int64, streamID: UUID)] = [:]

    // MARK: upstream media size probe
    //
    // The proxy records upstream m4s total file size for
    // diagnostics and failover decisions. The size is discovered by issuing a
    // `Range: bytes=0-0` GET to the upstream URL; B站's CDN
    // replies 206 with `Content-Range: bytes 0-0/TOTAL`.
    //
    // The probe fires on URLSession's own background queue and
    // updates probe state directly under `lock`.
    private var probedSizes: [URL: Int64] = [:]
    private var probeInFlight: Set<URL> = []
    /// URLs whose lightweight size probe completed without a usable
    /// `Content-Range`.  Keeping failures separate from "not started" lets
    /// preparation prefer a backup that has already proved healthy instead
    /// of repeating a request against a known-bad primary CDN.
    private var failedProbes: Set<URL> = []
    /// CDN failover cursor. Keyed by the track's primary URL,
    /// value is the index into the track's `backupURLs` array
    /// that should serve the next playlist (and segment
    /// request). Index 0 means "use primary", 1 means "use
    /// backupURLs[0]", etc. Reset to empty by `serve(playback:)`
    /// at the start of every new playback so a fresh load
    /// always prefers the primary. Touched only under `lock`.
    private var failoverIndex: [URL: Int] = [:]
    /// Per-track parsed `sidx` (Segment Index Box). Keyed by the
    /// track's primary upstream URL so concurrent playbacks of
    /// different videos don't collide. Populated by
    /// `prepareRemotePlayback(_:)` before the listener starts;
    /// cleared by `stop()`.
    ///
    /// Why this exists: equal-byte HLS segments are invalid for
    /// fragmented MP4. MP4 is VBR, and arbitrary byte boundaries
    /// can land inside `mdat`. The sidx carries the real
    /// `moof+mdat` fragment byte ranges and durations, so it is
    /// the only source allowed to publish a multi-segment media
    /// playlist.
    internal var trackSegmentIndex: [URL: TrackSegmentIndex] = [:]

    /// Which segmentation strategy to use for a track in the
    /// current playback session.  Decided once on the first
    /// `video.m3u8` / `audio.m3u8` request and never changes
    /// for the lifetime of the session — prevents AVPlayer
    /// from seeing a different segment structure mid-stream
    /// when the async SIDX fetch completes after the playlist
    /// was already served.
    ///
    /// **PR-A Group 5 fix**: was `fileprivate`.  Bumped to
    /// `internal` because `decidedModes` (a dictionary keyed
    /// by `URL` and valued by this enum) is `internal` for
    /// test inspection of the cache-lock-in fix (item 6).
    /// Swift forbids a more-public property type from
    /// referencing a less-public nested type.
    internal enum SegmentationMode: Hashable {
        /// SIDX-driven fragments with real byte ranges and
        /// durations (the spec-conformant path).
        case sidx
        /// No validated segment index is available. This is a
        /// hard preparation failure for remote playback.
        case unavailable
    }

    /// Per-track segmentation mode for the current playback.
    /// Keyed by `track.baseURL`.  Populated on first playlist
    /// request; cleared by `stop()`.
    internal var decidedModes: [URL: SegmentationMode] = [:]

    /// Kick off a `Range: bytes=0-0` GET to the upstream track
    /// URL.  Idempotent.  Safe to call from any thread; the
    /// URLSession callback runs on URLSession's queue and
    /// touches probe state only under `lock`.
    private func startMediaTotalProbe(
        for track: BiliDashSource.Track,
        referer: String
    ) {
        let key = track.baseURL
        lock.lock()
        if probedSizes[key] != nil || probeInFlight.contains(key) {
            lock.unlock()
            return
        }
        probeInFlight.insert(key)
        lock.unlock()

        var req = URLRequest(url: track.baseURL)
        req.setValue(referer, forHTTPHeaderField: "Referer")
        req.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) "
            + "Version/18.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        req.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        req.httpMethod = "GET"

        URLSession.shared.dataTask(with: req) { [weak self] _, response, _ in
            guard let self else { return }
            let total: Int64? = (response as? HTTPURLResponse).flatMap { http in
                let cr = http.value(forHTTPHeaderField: "Content-Range") ?? ""
                let (_, _, parsedTotal) =
                    LocalHLSProxyServer.parseContentRangeHeader(cr)
                return parsedTotal > 0 ? parsedTotal : nil
            }
            self.finishMediaTotalProbe(url: key, total: total)
        }.resume()
    }

    /// Warm the probe cache for a backup CDN host so the first
    /// failover is instant.  Same wire format as
    /// `startMediaTotalProbe(for:referer:)` but keyed by the
    /// backup URL itself (not the parent track) — the
    /// `probedSizes` cache is keyed by URL. No-op if the probe
    /// is already cached or in flight.
    private func startMediaTotalProbe(
        forBackup backup: URL,
        referer: String
    ) {
        lock.lock()
        if probedSizes[backup] != nil || probeInFlight.contains(backup) {
            lock.unlock()
            return
        }
        probeInFlight.insert(backup)
        lock.unlock()

        var req = URLRequest(url: backup)
        req.setValue(referer, forHTTPHeaderField: "Referer")
        req.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) "
            + "Version/18.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        req.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        req.httpMethod = "GET"
        URLSession.shared.dataTask(with: req) { [weak self] _, response, _ in
            guard let self else { return }
            let total: Int64? = (response as? HTTPURLResponse).flatMap { http in
                let cr = http.value(forHTTPHeaderField: "Content-Range") ?? ""
                let (_, _, parsedTotal) =
                    LocalHLSProxyServer.parseContentRangeHeader(cr)
                return parsedTotal > 0 ? parsedTotal : nil
            }
            self.finishMediaTotalProbe(url: backup, total: total)
            diagLog(.playback, "LocalHLSProxyServer backup probe",
                    details: [
                        "host": backup.host ?? "",
                        "totalBytes": total ?? -1,
                        "success": total != nil
                    ])
        }.resume()
    }

    /// Pick the upstream URL that should serve this track right
    /// now, honouring the failover cursor.  Returns the
    /// primary when no failover has been triggered; advances
    /// through `track.backupURLs` as the cursor moves.
    ///
    /// Called only from `respondMediaPlaylist(...)` — both
    /// the playlist-embedded URL and the segment fetches use
    /// the same picker, so a single cursor move flips every
    /// subsequent request on the same connection.
    private func activeUpstream(for track: BiliDashSource.Track) -> URL {
        lock.lock()
        defer { lock.unlock() }
        let idx = failoverIndex[track.baseURL] ?? 0
        let candidates = [track.baseURL] + track.backupURLs
        guard !candidates.isEmpty else { return track.baseURL }
        let safeIndex = min(max(idx, 0), candidates.count - 1)
        return candidates[safeIndex]
    }

    /// Advance the failover cursor for `primaryURL` to the
    /// next backup.  Called when an upstream fetch returns
    /// 5xx, the connection times out, or the byte-range
    /// response is malformed.  Idempotent — calling past the
    /// end of the backup list is a no-op (the playlist will
    /// keep using the last-known host, and AVPlayer will
    /// surface the underlying error to the user).
    fileprivate func markUpstreamFailed(primaryURL: URL) {
        lock.lock()
        guard let dash = currentPlayback?.dash else {
            lock.unlock()
            return
        }
        let tracks = [dash.video, dash.audio].compactMap { $0 }
        guard let track = tracks.first(where: { $0.baseURL == primaryURL }) else {
            lock.unlock()
            return
        }
        let maxIndex = track.backupURLs.count
        let current = failoverIndex[primaryURL] ?? 0
        let next = min(current + 1, maxIndex)
        failoverIndex[primaryURL] = next
        lock.unlock()
        diagLog(.playback, "LocalHLSProxyServer failover",
                details: [
                    "primary": primaryURL.host ?? "",
                    "newIndex": next,
                    "maxIndex": maxIndex,
                    "exhausted": next == current && current == maxIndex
                ])
    }

    /// Resolve which track this URL belongs to and bump its
    /// failover cursor.  Used by `StreamingProxyTask` when a
    /// 5xx comes back from an upstream — the task only knows
    /// the URL it just tried, not the track DTO.  Lookup is
    /// O(tracks × backups) per call (typically 2 tracks × ≤3
    /// backups = 6 URL comparisons), so we keep the helper
    /// synchronous.  Fires at most once per failed segment —
    /// not hot enough to warrant a URL→primary hash.
    fileprivate func markUpstreamFailed(url: URL) {
        let dash: BiliDashSource? = {
            lock.lock(); defer { lock.unlock() }
            return currentPlayback?.dash
        }()
        guard let dash else { return }
        for track in [dash.video, dash.audio].compactMap({ $0 }) {
            let candidates = [track.baseURL] + track.backupURLs
            if candidates.contains(url) {
                // Failover is keyed by the *primary* URL —
                // that's how `activeUpstream(for:)` reads it.
                markUpstreamFailed(primaryURL: track.baseURL)
                return
            }
        }
    }

    /// Resolve the next upstream URL a `StreamingProxyTask`
    /// should switch to after its current `upstream` host
    /// returned a transport-level failure (timeout, DNS,
    /// connection lost). Pairs with `markUpstreamFailed(url:)`
    /// — the caller MUST have already advanced the
    /// `failoverIndex` cursor for the relevant track before
    /// calling this helper, otherwise it returns the same
    /// host the task is already on (and the retry becomes a
    /// no-op).
    ///
    /// Returns `nil` when `upstream` doesn't belong to any
    /// currently-loaded track (e.g. the playback was swapped
    /// out under us). In that case the caller should fall
    /// back to the original behaviour of marking the host
    /// failed and continuing with the task's stored URL.
    fileprivate func reboundUpstream(after upstream: URL) -> URL? {
        let dash: BiliDashSource? = {
            lock.lock(); defer { lock.unlock() }
            return currentPlayback?.dash
        }()
        guard let dash else { return nil }
        for track in [dash.video, dash.audio].compactMap({ $0 }) {
            let candidates = [track.baseURL] + track.backupURLs
            if candidates.contains(upstream) {
                return activeUpstream(for: track)
            }
        }
        return nil
    }

    internal func setCurrentPlaybackForTest(_ playback: BiliPlayback) {
        setCurrentPlayback(playback)
    }

    internal func activeUpstreamForTest(
        for track: BiliDashSource.Track
    ) -> URL {
        activeUpstream(for: track)
    }

    internal func markUpstreamFailedForTest(url: URL) {
        markUpstreamFailed(url: url)
    }

    internal func failoverIndexForTest(primaryURL: URL) -> Int? {
        lock.lock(); defer { lock.unlock() }
        return failoverIndex[primaryURL]
    }

    /// Probe completion: cache the size.
    /// Runs on URLSession's background queue; touches only
    /// `probedSizes` under `lock`.
    private func finishMediaTotalProbe(url: URL, total: Int64?) {
        lock.lock()
        probeInFlight.remove(url)
        if let total {
            probedSizes[url] = total
            failedProbes.remove(url)
        } else {
            failedProbes.insert(url)
        }
        lock.unlock()
        diagLog(.playback, "LocalHLSProxyServer probe media total",
                details: [
                    "host": url.host ?? "",
                    "totalBytes": total ?? -1,
                    "success": total != nil
                ])
    }

    /// Clear probe state when the playback swaps.  The proxy
    /// is a process-wide singleton; if a previous playback
    /// probed sizes for its tracks, those sizes don't apply
    /// to the new playback and must be evicted.
    private func resetMediaTotalProbes() {
        lock.lock()
        probedSizes.removeAll()
        probeInFlight.removeAll()
        failedProbes.removeAll()
        lock.unlock()
    }

    // MARK: - SIDX fetch + cache
    //
    // The proxy parses the upstream `sidx` box at serve() time
    // and caches the resulting TrackSegmentIndex per primary
    // upstream URL. The playlist generator then emits one
    // `EXT-X-BYTERANGE` per validated sidx reference against
    // the real `/media` resource.

    private struct RangeFetchOutcome: Sendable {
        let data: Data
        let status: Int
        let contentRange: String?
        let contentLength: Int64?
        let elapsedMs: Int
    }

    private func prepareTrackSegmentIndex(
        _ track: BiliDashSource.Track,
        kind: String,
        referer: String
    ) async throws -> TrackSegmentIndex {
        var failures: [String] = []
        let candidates = [track.baseURL] + track.backupURLs
        let orderedCandidates = await preparationCandidates(from: candidates)
        for candidate in orderedCandidates {
            try Task.checkCancellation()
            do {
                let index = try await prepareTrackSegmentIndex(
                    track,
                    kind: kind,
                    referer: referer,
                    sourceURL: candidate
                )
                let selectedIndex = candidates.firstIndex(of: candidate) ?? 0
                setFailoverIndex(selectedIndex, for: track.baseURL)
                return index
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures.append("\(candidate.host ?? ""): \(error)")
            }
        }
        throw PlaybackPreparationError.segmentValidationFailed(
            host: track.baseURL.host ?? "",
            reason: failures.joined(separator: " | ")
        )
    }

    /// Give the parallel size probes a short opportunity to identify a
    /// healthy CDN, then put proven candidates first while preserving API
    /// order within each group.  This is intentionally bounded: preparation
    /// must still make progress when every probe is slow or inconclusive.
    private func preparationCandidates(from candidates: [URL]) async -> [URL] {
        for _ in 0..<20 {
            let snapshot = mediaProbeSnapshot(for: candidates)
            if !snapshot.successful.isEmpty || snapshot.inFlight.isEmpty {
                let ordered = Self.orderPreparationCandidates(
                    candidates,
                    successful: snapshot.successful,
                    failed: snapshot.failed
                )
                if ordered.first != candidates.first {
                    diagLog(.playback, "Playback preparation preferred probed CDN",
                            details: [
                                "selectedHost": ordered.first?.host ?? "",
                                "primaryHost": candidates.first?.host ?? "",
                                "successfulProbeCount": snapshot.successful.count,
                                "failedProbeCount": snapshot.failed.count
                            ])
                }
                return ordered
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
            if Task.isCancelled { return candidates }
        }
        let snapshot = mediaProbeSnapshot(for: candidates)
        return Self.orderPreparationCandidates(
            candidates,
            successful: snapshot.successful,
            failed: snapshot.failed
        )
    }

    private func mediaProbeSnapshot(
        for candidates: [URL]
    ) -> (successful: Set<URL>, failed: Set<URL>, inFlight: Set<URL>) {
        lock.lock(); defer { lock.unlock() }
        let candidateSet = Set(candidates)
        return (
            Set(probedSizes.keys).intersection(candidateSet),
            failedProbes.intersection(candidateSet),
            probeInFlight.intersection(candidateSet)
        )
    }

    /// Stable candidate ranking, exposed internally for regression tests.
    /// Proven-good hosts lead, unknown hosts remain eligible, and known probe
    /// failures are attempted last as a final fallback.
    internal static func orderPreparationCandidates(
        _ candidates: [URL],
        successful: Set<URL>,
        failed: Set<URL>
    ) -> [URL] {
        candidates.enumerated().sorted { lhs, rhs in
            func rank(_ url: URL) -> Int {
                if successful.contains(url) { return 0 }
                if failed.contains(url) { return 2 }
                return 1
            }
            let leftRank = rank(lhs.element)
            let rightRank = rank(rhs.element)
            return leftRank == rightRank ? lhs.offset < rhs.offset : leftRank < rightRank
        }.map(\.element)
    }

    private func prepareTrackSegmentIndex(
        _ track: BiliDashSource.Track,
        kind: String,
        referer: String,
        sourceURL: URL
    ) async throws -> TrackSegmentIndex {
        try Task.checkCancellation()
        let prepStarted = Date()
        if Self.preparationLogEnabled {
            diagLog(.playback, "\(kind) prepare started", details: [
                "kind": kind,
                "host": sourceURL.host ?? "",
                "backupCount": track.backupURLs.count
            ])
        }
        defer {
            if Self.preparationLogEnabled {
                diagLog(.playback, "\(kind) prepare ended", details: [
                    "kind": kind,
                    "host": sourceURL.host ?? "",
                    "elapsedMs": Int(Date().timeIntervalSince(prepStarted) * 1000)
                ])
            }
        }
        guard let indexRange = track.indexRange else {
            throw PlaybackPreparationError.missingSIDXRange(
                host: sourceURL.host ?? ""
            )
        }

        let fileSize: UInt64
        do {
            fileSize = try await fetchFileSize(
                url: sourceURL,
                referer: referer,
                kind: kind
            )
        } catch {
            throw PlaybackPreparationError.sidxFetchFailed(
                host: sourceURL.host ?? "",
                reason: "\(error)"
            )
        }
        let sidxRange = indexRange.offset ..< (indexRange.offset + indexRange.length)
        let initRange = playlistInitializationRange(for: track)

        // Guard: if the SIDX offset from the API exceeds the CDN file size
        // (schema drift / CDN file was replaced since the API response), the
        // resulting inverted range would crash `fetchExactRange`'s
        // `precondition(!range.isEmpty)`.  Surface as a clean preparation
        // failure instead.
        let sidxUpperBound = Int64(fileSize)
        guard sidxRange.lowerBound < sidxUpperBound else {
            throw PlaybackPreparationError.sidxFetchFailed(
                host: sourceURL.host ?? "",
                reason: "sidx offset \(sidxRange.lowerBound) >= fileSize \(fileSize)"
            )
        }

        let prefixLength: Int64 = 64 * 1024
        let combinedEnd = min(
            sidxUpperBound,
            max(sidxRange.upperBound, sidxRange.upperBound + prefixLength)
        )
        // Defensive: ensure the range is valid even when the SIDX upper bound
        // and prefix produce a value ≤ sidxRange.lowerBound.
        let combinedRange = combinedEnd > sidxRange.lowerBound
            ? sidxRange.lowerBound..<combinedEnd
            : sidxRange.lowerBound..<sidxUpperBound

        let combined: RangeFetchOutcome
        do {
            combined = try await fetchExactRange(
                url: sourceURL,
                range: combinedRange,
                referer: referer,
                purpose: "\(kind) sidx+prefix"
            )
        } catch {
            throw PlaybackPreparationError.sidxFetchFailed(
                host: sourceURL.host ?? "",
                reason: "\(error)"
            )
        }

        let sidxLength = Int(sidxRange.upperBound - sidxRange.lowerBound)
        let sidxData = combined.data.prefix(sidxLength)
        let parsed: SIDX
        do {
            parsed = try parseSIDX(
                Data(sidxData),
                absoluteOffset: UInt64(indexRange.offset)
            )
        } catch {
            throw PlaybackPreparationError.sidxParseFailed(
                host: sourceURL.host ?? "",
                reason: "\(error)"
            )
        }

        let index = makeTrackSegmentIndex(
            initializationRange: initRange,
            sidxRange: sidxRange,
            sidx: parsed
        )
        let validated: TrackSegmentIndex
        do {
            validated = try await validatedSegmentIndex(
                index,
                upstream: sourceURL,
                referer: referer,
                mediaStartOffset: track.mediaStartOffset,
                fileSize: Int64(fileSize),
                combinedRange: combinedRange,
                combinedData: combined.data
            )
        } catch {
            throw PlaybackPreparationError.segmentValidationFailed(
                host: sourceURL.host ?? "",
                reason: "\(error)"
            )
        }

        diagLog(.playback, "\(kind) SIDX parsed", details: [
            "references": validated.fragments.count,
            "firstMediaOffset": validated.firstMediaOffset,
            "fileSize": fileSize,
            "selectedHost": sourceURL.host ?? "",
            "mapRange": "\(validated.initializationRange.lowerBound)"
                + "-\(validated.initializationRange.upperBound - 1)",
            "sidxRange": "\(sidxRange.lowerBound)-\(sidxRange.upperBound - 1)",
            "combinedRange": "\(combinedRange.lowerBound)-\(combinedRange.upperBound - 1)",
            "elapsedMs": combined.elapsedMs
        ])
        return validated
    }

    private func fetchFileSize(
        url: URL,
        referer: String,
        kind: String
    ) async throws -> UInt64 {
        // `serve(playback:)` starts a lightweight bytes=0-0 probe before
        // SIDX preparation. Reuse that result instead of issuing a second
        // request for the same range; on some Bilibili CDN hosts the second
        // request can sit behind the first for several seconds and make the
        // player appear stuck at 0:00.
        for _ in 0..<20 {
            let cached = cachedProbeSize(for: url)
            if let cached, cached > 0 {
                return UInt64(cached)
            }
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let outcome = try await fetchExactRange(
            url: url,
            range: 0..<1,
            referer: referer,
            purpose: "\(kind) file-size"
        )
        guard let contentRange = outcome.contentRange,
              let totalString = contentRange.split(separator: "/").last,
              let total = UInt64(totalString) else {
            throw RangeFetchError.missingContentRange
        }
        return total
    }

    /// Locking is kept in a synchronous helper because Swift 6 forbids
    /// calling `NSLock` APIs directly across an async suspension boundary.
    private func cachedProbeSize(for url: URL) -> Int64? {
        lock.lock(); defer { lock.unlock() }
        return probedSizes[url]
    }

    private func fetchExactRange(
        url: URL,
        range: Range<Int64>,
        referer: String,
        purpose: String
    ) async throws -> RangeFetchOutcome {
        precondition(!range.isEmpty)
        let startTime = Date()
        let end = range.upperBound - 1
        let expectedLength = Int(range.upperBound - range.lowerBound)
        let requestedRange = "bytes=\(range.lowerBound)-\(end)"
        var request = URLRequest(url: url)
        request.setValue(requestedRange, forHTTPHeaderField: "Range")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) "
            + "Version/18.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        // Per-request cap; the session's `timeoutIntervalForRequest`
        // is the ceiling when this is unset.
        request.timeoutInterval = 10

        // Async fetch on the long-lived prep session.  No
        // `DispatchSemaphore` — this is the whole point of the
        // deadlock fix: the awaiting task suspends instead of
        // blocking the calling thread.
        try Task.checkCancellation()
        guard let prepSession else {
            // `stop()` ran while this request was in-flight.
            // Surface as a hard timeout so the per-track
            // deadline race above can pick it up cleanly.
            throw RangeFetchError.timedOut
        }
        // PR-C: diagnostic — confirms whether the await on
        // `prepSession.data(...)` is the hang point in the
        // Swift 6 regression where the AVPlayer never reaches
        // .playing.  Pair with the "returned" log below; if
        // "entered" fires but "returned" never does, the
        // URLSession continuation is starved.
        diagLog(.proxy, "fetchExactRange entered",
                details: [
                    "purpose": purpose,
                    "url": url.absoluteString,
                    "requestedRange": requestedRange
                ])
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await prepSession.data(for: request)
        } catch is CancellationError {
            logRangeFetchFailure(
                purpose: purpose,
                url: url,
                requestedRange: requestedRange,
                status: nil,
                contentRange: nil,
                contentLength: nil,
                dataCount: nil,
                elapsedMs: elapsedMilliseconds(since: startTime),
                error: RangeFetchError.timedOut
            )
            throw RangeFetchError.timedOut
        } catch {
            let wrapped = RangeFetchError.requestFailed(
                "\(type(of: error)) \(error.localizedDescription)"
            )
            logRangeFetchFailure(
                purpose: purpose,
                url: url,
                requestedRange: requestedRange,
                status: nil,
                contentRange: nil,
                contentLength: nil,
                dataCount: nil,
                elapsedMs: elapsedMilliseconds(since: startTime),
                error: wrapped
            )
            throw wrapped
        }
        // PR-C: diagnostic — partner of "fetchExactRange entered"
        // above.  Emitted only on the success path; the catch
        // blocks above own the failure paths and already log
        // via `logRangeFetchFailure`.
        diagLog(.proxy, "fetchExactRange returned",
                details: [
                    "purpose": purpose,
                    "url": url.absoluteString,
                    "bytes": data.count,
                    "elapsedMs": elapsedMilliseconds(since: startTime)
                ])
        try Task.checkCancellation()

        let elapsed = elapsedMilliseconds(since: startTime)
        guard let http = response as? HTTPURLResponse else {
            logRangeFetchFailure(
                purpose: purpose,
                url: url,
                requestedRange: requestedRange,
                status: nil,
                contentRange: nil,
                contentLength: nil,
                dataCount: data.count,
                elapsedMs: elapsed,
                error: RangeFetchError.invalidResponse
            )
            throw RangeFetchError.invalidResponse
        }
        let contentRange = http.value(forHTTPHeaderField: "Content-Range")
        let contentLength = http.value(forHTTPHeaderField: "Content-Length")
            .flatMap(Int64.init)
        guard http.statusCode == 206 else {
            let error = RangeFetchError.unexpectedStatus(http.statusCode)
            logRangeFetchFailure(
                purpose: purpose,
                url: url,
                requestedRange: requestedRange,
                status: http.statusCode,
                contentRange: contentRange,
                contentLength: contentLength,
                dataCount: data.count,
                elapsedMs: elapsed,
                error: error
            )
            throw error
        }
        let expectedPrefix = "bytes \(range.lowerBound)-\(end)/"
        guard let contentRange else {
            let error = RangeFetchError.missingContentRange
            logRangeFetchFailure(
                purpose: purpose,
                url: url,
                requestedRange: requestedRange,
                status: http.statusCode,
                contentRange: nil,
                contentLength: contentLength,
                dataCount: data.count,
                elapsedMs: elapsed,
                error: error
            )
            throw error
        }
        guard contentRange.hasPrefix(expectedPrefix) else {
            let error = RangeFetchError.mismatchedContentRange(
                expected: expectedPrefix,
                actual: contentRange
            )
            logRangeFetchFailure(
                purpose: purpose,
                url: url,
                requestedRange: requestedRange,
                status: http.statusCode,
                contentRange: contentRange,
                contentLength: contentLength,
                dataCount: data.count,
                elapsedMs: elapsed,
                error: error
            )
            throw error
        }
        guard data.count == expectedLength else {
            let error = RangeFetchError.mismatchedLength(
                expected: expectedLength,
                actual: data.count
            )
            logRangeFetchFailure(
                purpose: purpose,
                url: url,
                requestedRange: requestedRange,
                status: http.statusCode,
                contentRange: contentRange,
                contentLength: contentLength,
                dataCount: data.count,
                elapsedMs: elapsed,
                error: error
            )
            throw error
        }
        return RangeFetchOutcome(
            data: data,
            status: http.statusCode,
            contentRange: contentRange,
            contentLength: contentLength,
            elapsedMs: elapsed
        )
    }

    private func logRangeFetchFailure(
        purpose: String,
        url: URL,
        requestedRange: String,
        status: Int?,
        contentRange: String?,
        contentLength: Int64?,
        dataCount: Int?,
        elapsedMs: Int,
        error: Error
    ) {
        diagLog(.playback, "metadata range fetch failed", details: [
            "purpose": purpose,
            "selectedHost": url.host ?? "",
            "requestedRange": requestedRange,
            "status": status ?? -1,
            "contentRange": contentRange ?? "",
            "contentLength": contentLength ?? -1,
            "dataCount": dataCount ?? -1,
            "elapsedMs": elapsedMs,
            "error": "\(error)"
        ])
    }

    private func elapsedMilliseconds(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }

    /// Snapshot a previously-parsed TrackSegmentIndex for
    /// `track`.  Returns nil if the sidx hasn't been fetched
    /// yet (or fetch failed) — caller falls back to single-
    /// segment playlist.
    fileprivate func cachedSegmentIndex(
        for track: BiliDashSource.Track
    ) -> TrackSegmentIndex? {
        lock.lock(); defer { lock.unlock() }
        return trackSegmentIndex[track.baseURL]
    }

    /// True when the proxy has a parsed SIDX for this track.
    /// Remote playback prepares this before the listener starts;
    /// a missing index is a hard playlist error.
    fileprivate func hasSegmentIndex(
        for track: BiliDashSource.Track
    ) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return trackSegmentIndex[track.baseURL] != nil
    }

    private func playlistInitializationRange(
        for track: BiliDashSource.Track
    ) -> Range<Int64> {
        let initStart = track.initializationRange.offset
        let initEndExclusive = track.initializationRange.offset
            + track.initializationRange.length
        if let indexRange = track.indexRange,
           indexRange.offset > initStart,
           indexRange.offset < initEndExclusive {
            return initStart..<indexRange.offset
        }
        return initStart..<initEndExclusive
    }

    private enum SegmentBoundaryValidationError: Error, CustomStringConvertible {
        case fetchFailed(index: Int, offset: Int64)
        case invalidStart(index: Int, offset: Int64, first16Bytes: String)

        var description: String {
            switch self {
            case .fetchFailed(let index, let offset):
                return "failed to fetch segment \(index) prefix at \(offset)"
            case .invalidStart(let index, let offset, let first16Bytes):
                return "segment \(index) starts at invalid MP4 box offset \(offset): \(first16Bytes)"
            }
        }
    }

    private func validatedSegmentIndex(
        _ index: TrackSegmentIndex,
        upstream: URL,
        referer: String,
        mediaStartOffset: Int64,
        fileSize: Int64,
        combinedRange: Range<Int64>,
        combinedData: Data
    ) async throws -> TrackSegmentIndex {
        // Build 182 structural pre-check: validate every
        // fragment's byte range is sane (positive length, in
        // bounds, past the init range) without a network
        // round-trip.  This catches a malformed SIDX before
        // we waste round-trips on prefix fetches.
        for (i, fragment) in index.fragments.enumerated() {
            let fragmentByteCount = fragment.byteRange.upperBound
                - fragment.byteRange.lowerBound
            guard fragmentByteCount > 0 else {
                throw SegmentBoundaryValidationError.invalidStart(
                    index: i,
                    offset: fragment.byteRange.lowerBound,
                    first16Bytes: "zero-length fragment"
                )
            }
            guard fragment.byteRange.upperBound <= fileSize else {
                throw SegmentBoundaryValidationError.invalidStart(
                    index: i,
                    offset: fragment.byteRange.lowerBound,
                    first16Bytes: "outside fileSize \(fileSize)"
                )
            }
            guard fragment.byteRange.lowerBound >= mediaStartOffset else {
                throw SegmentBoundaryValidationError.invalidStart(
                    index: i,
                    offset: fragment.byteRange.lowerBound,
                    first16Bytes: "before mediaStartOffset \(mediaStartOffset)"
                )
            }
        }

        // **Build 182 sampling**: previously we validated the
        // 4 KiB prefix of every fragment via a serial
        // `fetchExactRange`, which for a 10-minute VOD =
        // ~170 segments * 2 tracks = 340 round-trips and
        // blew the 10s deadline race.  Now we sample:
        //   - segment 0 always (the combined buffer already
        //     covers it; free)
        //   - middle and last only when --full-validate or
        //     DEBUG macro is on (production keeps just [0])
        let samples = Self.validationSampleIndices(
            count: index.fragments.count,
            full: Self.fullValidationEnabled
        )
        var validatedPrefixes: [Int: String] = [:]
        for sampleIndex in samples {
            try Task.checkCancellation()
            let fragment = index.fragments[sampleIndex]
            let fragmentByteCount = fragment.byteRange.upperBound
                - fragment.byteRange.lowerBound
            let prefixLength = min(Int64(4096), fragmentByteCount)
            guard prefixLength > 0 else {
                throw SegmentBoundaryValidationError.fetchFailed(
                    index: sampleIndex,
                    offset: fragment.byteRange.lowerBound
                )
            }
            let prefixRange = fragment.byteRange.lowerBound
                ..< (fragment.byteRange.lowerBound + prefixLength)
            let prefix: Data
            if combinedRange.lowerBound <= prefixRange.lowerBound,
               combinedRange.upperBound >= prefixRange.upperBound {
                let start = Int(prefixRange.lowerBound - combinedRange.lowerBound)
                let end = start + Int(prefixLength)
                prefix = combinedData.subdata(in: start..<end)
            } else {
                let outcome = try await fetchExactRange(
                    url: upstream,
                    range: prefixRange,
                    referer: referer,
                    purpose: "segment \(sampleIndex) prefix"
                )
                prefix = outcome.data
            }
            let first16 = Self.hexPrefix(prefix, count: 16)
            guard Self.isValidFragmentStart(prefix) else {
                diagLog(.playback,
                        "LocalHLSProxyServer segment boundary rejected",
                        details: [
                            "segmentationMode": "sidx",
                            "host": upstream.host ?? "",
                            "segmentIndex": sampleIndex,
                            "firstMediaOffset": index.firstMediaOffset,
                            "referencedSize": fragmentByteCount,
                            "first16BytesAtSegmentStart": first16,
                            "mapRange": "\(index.initializationRange.lowerBound)"
                                + "-\(index.initializationRange.upperBound - 1)",
                            "sidxRange": index.sidxRange.map {
                                "\($0.lowerBound)-\($0.upperBound - 1)"
                            } ?? "",
                        ])
                throw SegmentBoundaryValidationError.invalidStart(
                    index: sampleIndex,
                    offset: fragment.byteRange.lowerBound,
                    first16Bytes: first16
                )
            }
            if sampleIndex == 0 || Self.requestMetadataLogEnabled {
                diagLog(.playback,
                        sampleIndex == 0
                            ? "segment 0 validated"
                            : "LocalHLSProxyServer segment boundary validated",
                        details: [
                            "segmentationMode": "sidx",
                            "host": upstream.host ?? "",
                            "segmentIndex": sampleIndex,
                            "firstMediaOffset": index.firstMediaOffset,
                            "referencedSize": fragmentByteCount,
                            "first16BytesAtSegmentStart": first16,
                            "mapRange": "\(index.initializationRange.lowerBound)"
                                + "-\(index.initializationRange.upperBound - 1)",
                            "sidxRange": index.sidxRange.map {
                                "\($0.lowerBound)-\($0.upperBound - 1)"
                            } ?? "",
                        ])
            }
            validatedPrefixes[sampleIndex] = first16
        }

        // Build the result.  All fragments are emitted (the
        // SIDX is authoritative for the byte ranges); only
        // the prefix hex was sampled.
        let fragments: [MediaFragment] = index.fragments.map { fragment in
            let i = index.fragments.firstIndex(of: fragment) ?? 0
            let hex = validatedPrefixes[i] ?? ""
            return MediaFragment(
                byteRange: fragment.byteRange,
                startTime: fragment.startTime,
                duration: fragment.duration,
                startsWithSAP: fragment.startsWithSAP,
                startPrefixHex: hex
            )
        }
        return TrackSegmentIndex(
            initializationRange: index.initializationRange,
            fragments: fragments,
            timescale: index.timescale,
            firstMediaOffset: index.firstMediaOffset,
            sidxRange: index.sidxRange,
            totalDuration: index.totalDuration
        )
    }

    /// Build 182 sampling helper.  Returns the indices of
    /// fragments whose prefix should be network-validated.
    /// In release builds this is always `[0]` (cheapest path
    /// that catches the most common failure: SIDX pointing
    /// at a non-fragment byte offset).  With
    /// `--full-validate` launch arg or DEBUG builds, also
    /// sample the middle and last fragments.
    static func validationSampleIndices(count: Int, full: Bool) -> [Int] {
        guard count > 1 else { return [0] }
        if full {
            return Array(Set([0, count / 2, count - 1])).sorted()
        }
        return [0]
    }

    /// True when the proxy should network-validate more than
    /// just `segment 0`.  Driven by a launch argument
    /// (`--full-validate`) and the DEBUG macro so TestFlight
    /// builds can flip it on without a rebuild.
    static var fullValidationEnabled: Bool {
        if ProcessInfo.processInfo.arguments.contains("--full-validate") {
            return true
        }
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    private static func isValidFragmentStart(_ data: Data) -> Bool {
        let allowedBeforeMoof = Set(["styp", "emsg", "prft", "free", "skip", "moof"])
        var cursor = 0
        var scanned = 0
        while cursor + 8 <= data.count, scanned < 16 {
            guard let header = mp4BoxHeader(in: data, at: cursor),
                  allowedBeforeMoof.contains(header.type) else {
                return false
            }
            if header.type == "moof" {
                return cursor < 64 * 1024
            }
            let next = cursor + header.size
            if next > data.count {
                return false
            }
            cursor = next
            scanned += 1
        }
        return false
    }

    private static func mp4BoxHeader(
        in data: Data,
        at offset: Int
    ) -> (size: Int, type: String)? {
        guard offset >= 0, offset + 8 <= data.count else { return nil }
        let size32 = UInt32(data[offset]) << 24
            | UInt32(data[offset + 1]) << 16
            | UInt32(data[offset + 2]) << 8
            | UInt32(data[offset + 3])
        let type = String(
            bytes: data[(offset + 4)..<(offset + 8)],
            encoding: .ascii
        ) ?? ""
        if size32 == 1 {
            guard offset + 16 <= data.count else { return nil }
            var size64: UInt64 = 0
            for i in 0..<8 {
                size64 = (size64 << 8) | UInt64(data[offset + 8 + i])
            }
            guard size64 <= UInt64(Int.max) else { return nil }
            return (Int(size64), type)
        }
        guard size32 >= 8 else { return nil }
        return (Int(size32), type)
    }

    private static func hexPrefix(_ data: Data, count: Int) -> String {
        data.prefix(count)
            .map { String(format: "%02x", $0) }
            .joined(separator: " ")
    }

    /// Construct a proxy.  `port` is the *seed* value for the
    /// `port` field; `0` (the default) lets the kernel pick
    /// the loopback port via the `requiredLocalEndpoint`
    /// `.any` setting in `ensureListener()`.  Exposed as
    /// `internal` so `PaladalaTests` can build isolated
    /// instances without colliding with the process-wide
    /// `shared` singleton.
    internal init(port: UInt16 = 0) {
        self.port = port
        prepSession = Self.makePrepSession()
    }

    /// Build the long-lived prep `URLSession`.  Pulled out of
    /// `init` so `stop()` → `serve(playback:)` can rebuild it
    /// after a previous playback was cancelled.
    private static func makePrepSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10
        cfg.timeoutIntervalForResource = 12
        cfg.httpMaximumConnectionsPerHost = 8
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }

    // MARK: diagnostic helpers

    /// Toggle for the raw-wire diagnostic dump in
    /// `dumpWireBytes`.  Off by default — the byte dumps
    /// dominate the per-segment log cost (each fMP4 segment
    /// produces ~3 dumps that together write 1.5 KB of binary
    /// to the JSONL and run a `JSONEncoder` round-trip), and
    /// a 5-minute 1080P video at 200 segments generates ~1,000
    /// diagLog calls during a single playback. Flip to `true`
    /// locally to debug the scrubber-seek-to-unbuffered bug.
    fileprivate static let wireDumpEnabled = false

    /// Toggle for the per-segment request / response metadata
    /// lines — `upstream request`, `Content-Length sanity`,
    /// `multi-segment playlist`, `single-segment playlist
    /// fallback`. Each fires once per fMP4 segment and
    /// dictionary-allocates on the calling queue, then hops to
    /// main for the in-memory ring append and to the disk
    /// queue for the JSONL write. Off by default for the same
    /// reason as `wireDumpEnabled`; flip on locally when
    /// debugging segment-level issues.
    fileprivate static let requestMetadataLogEnabled = false

    /// Toggle for the per-track SIDX-preparation log lines —
    /// `video prepare started`, `video prepare ended`,
    /// `Playback preparation started`, `Playback preparation
    /// completed`.  Runs once per playback so the per-call
    /// cost is negligible; default on so the diagnostic stream
    /// always shows which track prepped slowly or hung.
    fileprivate static let preparationLogEnabled = true

    /// Render the first 500 bytes of `data` as UTF-8 so the
    /// diagnostic log shows the actual HTTP framing we put on
    /// the wire.  If the chunk is not valid UTF-8 (binary m4s
    /// body), fall back to the ASCII-printable slice so the
    /// log still shows the bytes that look human-readable.
    /// `label` is the marker name we want to see in the log
    /// (e.g. `DOWNSTREAM RESPONSE HEADER`).
    fileprivate static func dumpWireBytes(_ data: Data, label: String) -> String {
        let prefix = data.prefix(500)
        if let s = String(data: prefix, encoding: .utf8) {
            return "====== \(label) ======\n\(s)\n==========================="
        }
        let printable = prefix.filter { $0 >= 0x20 && $0 < 0x7F }
        let ascii = String(decoding: printable, as: UTF8.self)
        return "====== \(label) [binary \(prefix.count)/\(data.count) bytes] ======\n\(ascii)\n==========================="
    }

    /// Parse `Content-Range: bytes START-END/TOTAL` into a
    /// tuple.  Returns `(-1, -1, -1)` for missing or
    /// malformed headers so the caller can fall back to the
    /// upstream `Content-Length`.  We compare `end - start + 1`
    /// against `Content-Length` to detect the trap-2 mismatch
    /// (hand-rolled HTTP server accidentally sends a
    /// Content-Length that doesn't match the body).
    internal static func parseContentRangeHeader(_ s: String)
        -> (start: Int64, end: Int64, total: Int64)
    {
        guard s.hasPrefix("bytes ") else { return (-1, -1, -1) }
        let body = s.dropFirst("bytes ".count)
        let parts = body.split(separator: "/", maxSplits: 1)
        guard parts.count == 2 else { return (-1, -1, -1) }
        let rangeParts = parts[0].split(separator: "-", maxSplits: 1)
        guard rangeParts.count == 2,
              let start = Int64(rangeParts[0]),
              let end = Int64(rangeParts[1]) else {
            return (-1, -1, -1)
        }
        let total: Int64
        if parts[1] == "*" {
            total = -1
        } else {
            total = Int64(parts[1]) ?? -1
        }
        return (start, end, total)
    }

    // MARK: connection handling

    private func accept(connection: NWConnection) {
        // Short, stable ID for this TCP connection so we can
        // correlate lifecycle events with the request(s) we
        // serve on it.  If AVPlayer ever reuses a connection
        // for a second Range request (trap 3 — keep-alive
        // reuse) we want to see two upstream requests with
        // the same `conn` rather than two anonymous ones.
        let connID = UUID().uuidString.prefix(8)
        diagLog(.network,
                "LocalHLSProxyServer accept",
                details: [
                    "conn": String(connID),
                    "endpoint": "\(connection.endpoint)"
                ])
        connection.start(queue: queue)
        receiveHeader(
            connection: connection,
            accumulated: Data(),
            connID: String(connID)
        )
    }

    /// Read the request header bytes in chunks until we see
    /// CRLFCRLF.  AVPlayer sends headers of a few hundred
    /// bytes; one read is usually enough.
    private func receiveHeader(
        connection: NWConnection,
        accumulated: Data,
        connID: String
    ) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1024
        ) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            if let error = error {
                diagLog(.network,
                        "LocalHLSProxyServer receive error",
                        details: [
                            "conn": connID,
                            "error": error.localizedDescription
                        ])
                diagLog(.network,
                        "LocalHLSProxyServer conn close",
                        details: ["conn": connID, "reason": "receive error"])
                connection.cancel()
                return
            }
            var buf = accumulated
            if let data = data { buf.append(data) }
            // End-of-headers marker.
            if buf.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) != nil {
                self.route(requestBytes: buf, connection: connection,
                           connID: connID)
                return
            }
            if isComplete {
                diagLog(.network,
                        "LocalHLSProxyServer conn close",
                        details: ["conn": connID, "reason": "eof without crlf crlf"])
                connection.cancel()
                return
            }
            self.receiveHeader(connection: connection, accumulated: buf,
                               connID: connID)
        }
    }

    /// Route a complete request to the right handler.
    private func route(requestBytes: Data,
                       connection: NWConnection,
                       connID: String) {
        guard let req = HTTPRequest.parse(data: requestBytes) else {
            respondError(connection: connection, status: 400,
                         reason: "bad request", connID: connID)
            return
        }
        let pathOnly = req.path.split(separator: "?", maxSplits: 1)
            .first.map(String.init) ?? req.path
        // Diagnostic log — Build 183 added because the
        // endpoint self-test reported `/playlist.m3u8`
        // returning 404 even though it is in the case list
        // below; logging the parsed path tells us whether
        // the request URL is malformed or the dispatch is.
        diagLog(.playback,
                "LocalHLSProxyServer route",
                details: [
                    "conn": connID,
                    "path": pathOnly,
                    "method": req.method
                ])
        // Local-playback path: read init/media from disk
        // instead of the upstream CDN.  Same HLS wire
        // contract, so the route keys are unchanged; only
        // the segment handler differs.
        let isLocal = isLocalMode()
        switch pathOnly {
        case "/playlist.m3u8":
            respondMasterPlaylist(connection: connection, connID: connID)
        case "/video.m3u8":
            respondMediaPlaylist(for: .video, connection: connection,
                                 connID: connID)
        case "/audio.m3u8":
            respondMediaPlaylist(for: .audio, connection: connection,
                                 connID: connID)
        case "/version":
            respondVersion(connection: connection, connID: connID)
        case "/diag":
            respondDiag(connection: connection, connID: connID)
        case "/init":
            if isLocal {
                proxyLocalSegment(
                    req: req, connection: connection,
                    kind: .initRange, connID: connID
                )
            } else {
                proxySegment(req: req, connection: connection,
                             mode: .initRange, connID: connID)
            }
        case "/media":
            if isLocal {
                proxyLocalSegment(
                    req: req, connection: connection,
                    kind: .mediaRange, connID: connID
                )
            } else {
                proxySegment(req: req, connection: connection,
                             mode: .mediaRange, connID: connID)
            }
        case "/segment":
            // Per-fragment URL emitted by the SIDX-driven
            // playlist generator.  Each fragment gets its own
            // URL keyed by (?k=video|audio, ?n=<idx>); the
            // segment handler looks up the cached SIDX, finds
            // the upstream byte range the sidx points at, and
            // returns the bytes as a single 200 OK.  AVPlayer
            // sees one URL per fragment, which is what it
            // expects from a normal HLS server.
            if isLocal {
                respondError(connection: connection, status: 404,
                             reason: "local mode: no /segment", connID: connID)
            } else {
                proxySegmentRange(req: req, connection: connection,
                                  connID: connID)
            }
        default:
            if pathOnly.hasPrefix("/seg") {
                if isLocal {
                    respondError(connection: connection, status: 404,
                                 reason: "local mode: no /seg",
                                 connID: connID)
                } else {
                    proxySegment(req: req, connection: connection,
                                 mode: .passthrough, connID: connID)
                }
            } else if pathOnly == "/live/manifest.m3u8" {
                respondLiveManifest(connection: connection, connID: connID)
            } else if pathOnly.hasPrefix("/live/seg") {
                proxyLiveSegment(req: req, connection: connection, connID: connID)
            } else {
                respondError(connection: connection, status: 404,
                             reason: "no route", connID: connID)
            }
        }
    }

    private func respondVersion(connection: NWConnection, connID: String) {
        let version = AppVersion.current.versionLine
        respondText(
            connection: connection,
            connID: connID,
            body: version
        )
    }

    private func respondDiag(connection: NWConnection, connID: String) {
        let text = """
        \(AppVersion.current.versionLine)
        Marketing: \(AppVersion.current.marketingVersion)
        Build: \(AppVersion.current.buildNumber)
        Fingerprint: \(AppVersion.current.identifier)
        Release: \(AppVersion.current.releaseType)
        State: \(currentState)
        """
        respondText(
            connection: connection,
            connID: connID,
            body: text
        )
    }

    /// True when the active playback is a downloaded video
    /// with on-disk bytes.  Re-checked on every request so
    /// swapping `currentPlayback` immediately flips the
    /// routing decision.
    fileprivate func isLocalMode() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return localContext != nil
    }

    // MARK: m3u8 synthesise

    private func snapshot() -> (BiliDashSource, String)? {
        lock.lock(); defer { lock.unlock() }
        guard let p = currentPlayback,
              let dash = p.dash else { return nil }
        return (dash, p.referer.absoluteString)
    }

    private enum MediaKind { case video, audio }

    /// HLS master playlist `BANDWIDTH` attribute components.
    /// Returned as a struct (instead of a tuple) so the test
    /// target can pin the formula without having to import
    /// tuple shape conventions.  `bandwidth` is the value to
    /// emit in `EXT-X-STREAM-INF:BANDWIDTH=`; the other fields
    /// are diagnostic breadcrumbs that the runtime logs.
    struct MasterBandwidthDecision: Equatable {
        /// The final `BANDWIDTH=` value (bits/s).
        let bandwidth: Int
        /// Peak bits/s observed across the video sidx.
        let videoPeakBps: Int64
        /// Peak bits/s observed across the audio sidx.
        let audioPeakBps: Int64
        /// `max(videoPeakBps, audioPeakBps)`.
        let measuredPeakBps: Int64
        /// `declaredVideoBps + declaredAudioBps` from the
        /// upstream DASH JSON.
        let declaredBps: Int64
    }

    /// Compute the `BANDWIDTH=` attribute for the master
    /// playlist.  The chosen value is the upper bound of:
    ///   1. `measuredPeakBps * 1.15` — 1.15× safety covers
    ///      the per-frame VBR jitter (8–10%) that any single
    ///      peak sample misses.
    ///   2. `declaredBps * 1.5` — sidx-absent fallback.  We
    ///      over-declare rather than under, because
    ///      under-declaration triggers AVPlayer's
    ///      `CoreMediaError -12318 "Segment exceeds
    ///      specified bandwidth for variant"` check and
    ///      stalls the pipeline.
    ///
    /// Exposed as `internal static` so the XCTest target
    /// can pin the formula against a future refactor.
    static func masterPlaylistBandwidthDecision(
        declaredVideoBps: Int,
        declaredAudioBps: Int,
        videoFragments: [MediaFragment],
        audioFragments: [MediaFragment]
    ) -> MasterBandwidthDecision {
        func peakBitsPerSec(in fragments: [MediaFragment]) -> Int64 {
            // bytes * 8 / seconds = bits per second.
            // Skip zero-duration fragments (sidx entries
            // with `d=0` are valid but can't be measured).
            fragments
                .filter { $0.duration > 0 }
                .map { frag -> Int64 in
                    let bytes = Int64(frag.byteRange.upperBound
                                      - frag.byteRange.lowerBound)
                    return bytes * 8 / Int64(frag.duration)
                }
                .max() ?? 0
        }
        let videoPeak = peakBitsPerSec(in: videoFragments)
        let audioPeak = peakBitsPerSec(in: audioFragments)
        let measuredPeak = max(videoPeak, audioPeak)
        let fromMeasured = Int(Double(measuredPeak) * 1.15)
        let declaredBps = Int64(declaredVideoBps) + Int64(declaredAudioBps)
        let fromDeclared = Int(Double(declaredBps) * 1.5)
        let chosen = max(fromMeasured, fromDeclared)
        return MasterBandwidthDecision(
            bandwidth: chosen,
            videoPeakBps: videoPeak,
            audioPeakBps: audioPeak,
            measuredPeakBps: measuredPeak,
            declaredBps: declaredBps
        )
    }

    private func respondMasterPlaylist(connection: NWConnection,
                                      connID: String) {
        guard let (source, _) = snapshot(),
              let baseURL = safeBaseURL else {
            respondError(connection: connection, status: 503,
                         reason: "no playback", connID: connID)
            return
        }
        // BANDWIDTH attribute (HLS RFC 8216 §4.3.4.2) must
        // be the upper bound across all segments.  B站's
        // DASH JSON `bandwidth` is the *average* bitrate,
        // which under-reports VBR peaks by 1.4–2× — especially
        // for HEVC content, where it triggers AVPlayer's
        // CoreMediaError -12318 "Segment exceeds specified
        // bandwidth for variant" check and stalls the
        // pipeline mid-playback.  Use the actual sidx peak
        // (or fall back to the declared value) and apply a
        // small safety margin so the AVPlayer variant check
        // never trips on a legitimate segment.
        let (videoSegments, audioSegments): (TrackSegmentIndex?, TrackSegmentIndex?) = {
            lock.lock(); defer { lock.unlock() }
            let videoURL = source.video.baseURL
            let audioURL = source.audio?.baseURL
            return (trackSegmentIndex[videoURL],
                    audioURL.flatMap { trackSegmentIndex[$0] })
        }()
        let decision = Self.masterPlaylistBandwidthDecision(
            declaredVideoBps: source.video.bandwidth,
            declaredAudioBps: source.audio?.bandwidth ?? 0,
            videoFragments: videoSegments?.fragments ?? [],
            audioFragments: audioSegments?.fragments ?? []
        )
        let totalBandwidth = decision.bandwidth
        if decision.measuredPeakBps > 0 || decision.declaredBps > 0 {
            diagLog(.playback,
                    "LocalHLSProxyServer master BANDWIDTH",
                    details: [
                        "videoPeakBps": decision.videoPeakBps,
                        "audioPeakBps": decision.audioPeakBps,
                        "measuredPeakBps": decision.measuredPeakBps,
                        "declaredBps": decision.declaredBps,
                        "chosenBps": totalBandwidth
                    ])
        }

        var lines: [String] = [
            "#EXTM3U",
            "#EXT-X-VERSION:6",
            "#EXT-X-INDEPENDENT-SEGMENTS",
        ]
        if source.audio != nil {
            lines.append(
                "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aac\","
                + "NAME=\"default\",DEFAULT=YES,AUTOSELECT=YES,"
                + "URI=\"\(localURL(baseURL: baseURL, path: "audio.m3u8"))\""
            )
        }
        var streamInf = "#EXT-X-STREAM-INF:"
        streamInf += "BANDWIDTH=\(totalBandwidth)"
        streamInf += ",CODECS=\"\(source.video.codecs)"
        if let a = source.audio { streamInf += ",\(a.codecs)" }
        streamInf += "\""
        if let width = source.video.width, width > 0,
           let height = source.video.height, height > 0 {
            streamInf += ",RESOLUTION=\(width)x\(height)"
        }
        if source.audio != nil {
            streamInf += ",AUDIO=\"aac\""
        }
        lines.append(streamInf)
        lines.append(localURL(baseURL: baseURL, path: "video.m3u8"))
        lines.append("")
        respondText(connection: connection, connID: connID,
                    body: lines.joined(separator: "\n"))
    }

    private func respondMediaPlaylist(
        for kind: MediaKind,
        connection: NWConnection,
        connID: String
    ) {
        guard let (source, _) = snapshot(),
              let baseURL = safeBaseURL else {
            respondError(connection: connection, status: 503,
                         reason: "no playback", connID: connID)
            return
        }
        let track: BiliDashSource.Track?
        switch kind {
        case .video: track = source.video
        case .audio: track = source.audio
        }
        guard let track = track else {
            respondError(connection: connection, status: 404,
                         reason: "no track", connID: connID)
            return
        }
        // Track label used only for diagnostics.
        let trackLabel = (kind == .video) ? "video" : "audio"
        diagLog(.playback,
                "LocalHLSProxyServer media playlist build started",
                details: [
                    "conn": connID,
                    "kind": trackLabel,
                    "host": track.baseURL.host ?? ""
                ])

        // Encode the upstream URL as a base64url query parameter.
        // The init/media endpoints then apply absolute upstream
        // byte ranges, so AVPlayer sees normal HLS resources while
        // Bili's CDN receives the Range requests it expects.
        let encoded = base64urlEncode(activeUpstream(for: track).absoluteString)
        let initRange = playlistInitializationRange(for: track)
        guard initRange.lowerBound < initRange.upperBound else {
            diagLog(.playback,
                    "LocalHLSProxyServer invalid init range",
                    details: [
                        "conn": connID,
                        "kind": trackLabel,
                        "lower": initRange.lowerBound,
                        "upper": initRange.upperBound
                    ])
            respondError(connection: connection, status: 503,
                         reason: "invalid init range",
                         extraHeaders: ["Retry-After": "0"],
                         connID: connID)
            return
        }
        let initURL = localURL(
            baseURL: baseURL,
            path: "init",
            queryItems: [
                URLQueryItem(name: "u", value: encoded),
                URLQueryItem(
                    name: "range",
                    value: "\(initRange.lowerBound)"
                        + "-\(initRange.upperBound - 1)"
                )
            ]
        )

        // Resolve the segmentation mode once per session.
        // On first call: SIDX if already cached and validated,
        // otherwise fail the playlist request. The decision is
        // locked in for the entire playback — AVPlayer never sees
        // a mid-stream playlist switch.
        let (mode, capturedGeneration) = resolveSegmentationMode(for: track)
        // Generation check: if `serve(playback:)` ran since we
        // captured the mode, the SIDX we are about to serve may
        // belong to the previous playback.  Refuse — the client
        // will retry, the next request will see the new
        // generation, and the new SIDX (or 503 if the new prep
        // has not finished yet) will be served.
        let currentGeneration: UInt64 = {
            lock.lock(); defer { lock.unlock() }
            return currentPrepGeneration
        }()
        guard currentGeneration == capturedGeneration else {
            diagLog(.playback,
                    "LocalHLSProxyServer stale generation rejecting playlist",
                    details: [
                        "conn": connID,
                        "kind": trackLabel,
                        "captured": capturedGeneration,
                        "current": currentGeneration
                    ])
            respondError(connection: connection, status: 503,
                         reason: "stale prep generation",
                         extraHeaders: ["Retry-After": "0"],
                         connID: connID)
            return
        }
        switch mode {
        case .sidx:
            guard let index = cachedSegmentIndex(for: track) else {
                // Race with stop() — unlikely but defensive.
                respondError(connection: connection, status: 503,
                             reason: "sidx vanished",
                             extraHeaders: ["Retry-After": "0"],
                             connID: connID)
                return
            }
            let targetDuration = max(1, Int(
                index.maxFragmentDuration.rounded(.up)
            ))
            var lines: [String] = [
                "#EXTM3U",
                "#EXT-X-VERSION:7",
                "#EXT-X-PLAYLIST-TYPE:VOD",
                "#EXT-X-TARGETDURATION:\(targetDuration)",
                "#EXT-X-MEDIA-SEQUENCE:0",
                "#EXT-X-MAP:URI=\"\(initURL)\"",
            ]
            for (idx, frag) in index.fragments.enumerated() {
                let segmentURL = localURL(
                    baseURL: baseURL,
                    path: "segment",
                    queryItems: [
                        URLQueryItem(name: "u", value: encoded),
                        URLQueryItem(name: "k", value: trackLabel),
                        URLQueryItem(name: "n", value: "\(idx)")
                    ]
                )
                lines.append(
                    "#EXTINF:\(String(format: "%.3f", frag.duration)),"
                )
                lines.append(segmentURL)
            }
            lines.append("#EXT-X-ENDLIST")
            lines.append("")
            if Self.requestMetadataLogEnabled {
                diagLog(.playback,
                        "LocalHLSProxyServer SIDX-driven playlist",
                        details: [
                            "conn": connID,
                            "segmentationMode": "sidx",
                            "kind": trackLabel,
                            "fragments": index.fragments.count,
                            "firstMediaOffset": index.firstMediaOffset,
                            "referencedSize":
                                index.fragments.first.map {
                                    $0.byteRange.upperBound - $0.byteRange.lowerBound
                                } ?? 0,
                            "first16BytesAtSegmentStart":
                                index.fragments.first?.startPrefixHex ?? "",
                            "mapRange": "\(index.initializationRange.lowerBound)"
                                + "-\(index.initializationRange.upperBound - 1)",
                            "sidxRange": index.sidxRange.map {
                                "\($0.lowerBound)-\($0.upperBound - 1)"
                            } ?? "",
                            "targetDuration": targetDuration,
                            "totalDuration": String(
                                format: "%.3f", index.totalDuration
                            )
                        ])
            }
            respondText(connection: connection, connID: connID,
                        body: lines.joined(separator: "\n"))

        case .unavailable:
            diagLog(.playback,
                    "LocalHLSProxyServer segment index unavailable",
                    details: [
                        "conn": connID,
                        "segmentationMode": "unavailable",
                        "kind": trackLabel,
                        "mapRange": "\(initRange.lowerBound)"
                            + "-\(initRange.upperBound - 1)",
                        "sidxRange": track.indexRange.map {
                            "\($0.offset)-\($0.endOffset)"
                        } ?? ""
                    ])
            // Explicit `Retry-After: 0` so AVPlayer retries
            // the playlist request on its next scheduler
            // tick rather than any intermediary applying a
            // default backoff.
            respondError(connection: connection, status: 503,
                         reason: "segment index unavailable",
                         extraHeaders: ["Retry-After": "0"],
                         connID: connID)
        }
    }

    /// Decide the segmentation mode for `track` on the first
    /// playlist request, then lock it in for the session.
    /// SIDX is used only when already cached and validated;
    /// otherwise the request fails. We never synthesize equal-
    /// byte or direct-MP4 segments for remote playback.
    ///
    /// Returns the mode *together with* the prep generation
    /// that was current at the time of the decision.  The
    /// caller (`respondMediaPlaylist`) verifies the generation
    /// still matches `currentPrepGeneration` under `lock`
    /// before serving — if a fresh `serve(playback:)` has
    /// bumped the generation, the captured decision is stale
    /// and we must treat it as not-ready (503).
    private func resolveSegmentationMode(for track: BiliDashSource.Track)
        -> (SegmentationMode, UInt64)
    {
        lock.lock(); defer { lock.unlock() }
        if let mode = decidedModes[track.baseURL] {
            return (mode, currentPrepGeneration)
        }
        let mode: SegmentationMode =
            trackSegmentIndex[track.baseURL] != nil ? .sidx : .unavailable
        // **PR-A Group 3 (item 6)**: only cache a *stable* answer
        // (`.sidx`).  When the SIDX has not yet been published
        // (`.unavailable`) we MUST NOT lock the mode in, or
        // AVPlayer will pin a temp playlist and race the SIDX
        // publish.  Leave `.unavailable` uncached so the next
        // request re-evaluates once the SIDX has been indexed.
        let locked = (mode == .sidx)
        if locked {
            decidedModes[track.baseURL] = mode
        }
        diagLog(.playback,
                "LocalHLSProxyServer segmentation mode",
                details: [
                    "host": track.baseURL.host ?? "",
                    "segmentationMode": mode == .sidx ? "sidx" : "unavailable",
                    "generation": currentPrepGeneration,
                    "locked": locked
                ])
        return (mode, currentPrepGeneration)
    }

    /// **PR-A Group 5**: test-only forwarder for
    /// `resolveSegmentationMode`.  Lets the unit test suite
    /// exercise the cache lock-in / no-lock-in behaviour
    /// without having to construct a full DASH session.
    internal func resolveSegmentationModeForTest(
        for track: BiliDashSource.Track
    ) -> (SegmentationMode, UInt64) {
        resolveSegmentationMode(for: track)
    }

    // MARK: segment proxy

    fileprivate enum ProxyMode {
        case passthrough
        case initRange
        case mediaRange

        var logName: String {
            switch self {
            case .passthrough: return "passthrough"
            case .initRange: return "init"
            case .mediaRange: return "media"
            }
        }
    }

    /// Serve one fMP4 fragment by SIDX index.  Route handler
    /// for `/segment?u=…&k=video|audio&n=<idx>` — the URL
    /// shape the SIDX-driven playlist generator emits.
///
/// Each fragment is fetched as a single upstream Range request
/// and returned as `200 OK` with `Content-Length` set to the
/// fragment's real byte count.  No `EXT-X-BYTERANGE` magic —
/// AVPlayer treats this as a normal HLS segment and the timeline
/// never drifts.
fileprivate func proxySegmentRange(
    req: HTTPRequest,
    connection: NWConnection,
    connID: String
) {
    // **PR-A Group 3 (item 7, D7)**: capture the prep
    // generation at handler entry.  Any subsequent increment
    // (e.g. `stop()` / new session) makes this request stale;
    // the guard below returns 503 + Retry-After so AVPlayer
    // backs off and re-fetches against the new session.
    let capturedGen = currentPrepGenerationValue()
    guard guardSegmentGeneration(
        capturedGen: capturedGen,
        connection: connection,
        connID: connID
    ) != nil else { return }
    // **PR-A Group 2 + Group 3**: log `segment_request` only
    // AFTER the generation guard passes so stale-prep requests
    // don't pollute the playback log.
    let pathOnly = req.path.split(separator: "?", maxSplits: 1).first
        .map(String.init) ?? req.path
    let queryOnly = req.path.split(separator: "?", maxSplits: 1).last
        .map(String.init) ?? ""
    diagLog(.playback, "segment_request", details: [
        "conn": connID,
        "path": pathOnly,
        "query": queryOnly,
        "generation": capturedGen
    ])
    guard let (source, referer) = snapshot() else {
        respondError(connection: connection, status: 503,
                     reason: "no playback", connID: connID)
        return
    }
    let query = req.path.split(separator: "?", maxSplits: 1)
        .last.map(String.init) ?? ""
    let params = parseQuery(query)
    guard let encoded = params["u"],
          let upstreamString = base64urlDecode(encoded),
          let upstream = URL(string: upstreamString) else {
        respondError(connection: connection, status: 400,
                     reason: "missing u", connID: connID)
        return
    }
    let track: BiliDashSource.Track
    switch params["k"] {
    case "video": track = source.video
    case "audio":
        guard let a = source.audio else {
            respondError(connection: connection, status: 404,
                         reason: "no audio track", connID: connID)
            return
        }
        track = a
    default:
        respondError(connection: connection, status: 400,
                     reason: "missing k", connID: connID)
        return
    }
    guard let nString = params["n"], let idx = Int(nString), idx >= 0 else {
        respondError(connection: connection, status: 400,
                     reason: "missing n", connID: connID)
        return
    }
    guard let index = cachedSegmentIndex(for: track),
          idx < index.fragments.count else {
        // SIDX not parsed yet (or invalid index).  Fall back to
        // /media?from=mediaStartOffset so the player still gets
        // bytes — at the cost of full-file streaming for this
        // one fragment.  AVPlayer will retry the playlist and
        // pick up the SIDX-driven form on the next pass.
        let encodedFallback = base64urlEncode(
            activeUpstream(for: track).absoluteString
        )
        let fallbackURL = localURL(
            path: "media",
            queryItems: [
                URLQueryItem(name: "u", value: encodedFallback),
                URLQueryItem(
                    name: "from",
                    value: "\(track.mediaStartOffset)"
                )
            ]
        )
        diagLog(.playback, "/segment: sidx not ready, falling back",
                details: [
                    "conn": connID,
                    "n": nString,
                    "fallback": fallbackURL
                ])
        respondError(connection: connection, status: 503,
                     reason: "sidx not ready",
                     extraHeaders: ["Retry-After": "0"],
                     connID: connID)
        return
    }

    let frag = index.fragments[idx]
    // **PR-C (Phase 2)**: try the on-disk prefetch cache
    // before issuing the B站 Range request.  `frag.byteRange`
    // is in upstream-file coordinates (the same ones the
    // cache file was written from), so a hit serves the
    // exact bytes AVPlayer would have got over the wire.
    if let (bvid, cid, qn) = currentIdentity(),
       let kind = kindForTrackKind(params["k"]),
       let hit = tryLocalSegment(
            bvid: bvid, qn: qn, cid: cid, kind: kind,
            absRange: frag.byteRange
       ) {
        diagLog(.playback,
                "LocalHLSProxyServer /segment served from local cache",
                details: [
                    "conn": connID,
                    "kind": params["k"] ?? "?",
                    "n": idx,
                    "range": "\(frag.byteRange.lowerBound)"
                        + "-\(frag.byteRange.upperBound - 1)",
                    "bytes": hit.data.count,
                    "fileSize": hit.totalSize
                ])
        touchPrefetchEntry(bvid: bvid, qn: qn, cid: cid)
        // `/segment` uses a 200 OK + full-body response
        // (not 206 + Content-Range) because each segment
        // is its own self-contained resource per the
        // SIDX-driven playlist.  See the original
        // `StreamingProxyTask` instantiation below.
        respondBytes(
            connection: connection,
            status: 200,
            contentType: "video/mp4",
            body: hit.data,
            extraHeaders: ["Content-Length": "\(hit.data.count)"],
            connID: connID,
            label: "LOCAL segment[\(idx)] \(frag.byteRange.lowerBound)"
                + "-\(frag.byteRange.upperBound - 1)"
        )
        return
    }
    let activeURL = activeUpstream(for: track)
    var upstreamReq = URLRequest(url: activeURL)
    upstreamReq.setValue(referer, forHTTPHeaderField: "Referer")
    upstreamReq.setValue(
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) "
        + "Version/18.0 Mobile/15E148 Safari/604.1",
        forHTTPHeaderField: "User-Agent"
    )
    let byteCount = frag.byteRange.count
    upstreamReq.setValue(
        "bytes=\(frag.byteRange.lowerBound)-\(frag.byteRange.upperBound - 1)",
        forHTTPHeaderField: "Range"
    )
    upstreamReq.httpMethod = "GET"

    let stream = StreamingProxyTask(
        server: self,
        connection: connection,
        upstream: activeURL,
        request: upstreamReq,
        mode: "segment[\(idx)]",
        // Segment URLs are independent resources — no Range
        // shifting math, AVPlayer treats each as a self-
        // contained segment.
        clientSentRange: false,
        contentRangeShift: nil,
        passContentRange: false,
        connID: connID,
        rangeStart: frag.byteRange.lowerBound,
        rangeEnd: frag.byteRange.upperBound - 1
    )
    retain(stream: stream)
    stream.start()

    if Self.requestMetadataLogEnabled {
        diagLog(.playback, "LocalHLSProxyServer /segment served",
                details: [
                    "conn": connID,
                    "kind": params["k"] ?? "?",
                    "n": idx,
                    "startTime": String(format: "%.3f", frag.startTime),
                    "duration": String(format: "%.3f", frag.duration),
                    "byteRange": "\(frag.byteRange.lowerBound)"
                        + "-\(frag.byteRange.upperBound - 1)",
                    "bytes": byteCount
                ])
    }
}

    /// Proxy a single segment request.  AVPlayer issues
    /// `GET /init?...` for the fMP4 map and `GET /media?...`
    /// for the playable media data.  We translate those into
    /// absolute upstream byte ranges, then forward to the CDN
    /// with the right `Referer` and `User-Agent`.  The upstream
    /// body is streamed into the loopback response as it arrives;
    /// buffering the whole m4s first makes AVPlayer sit forever
    /// in `waitingToPlayAtSpecifiedRate`.
    private func proxySegment(
        req: HTTPRequest,
        connection: NWConnection,
        mode: ProxyMode,
        connID: String
    ) {
        // **PR-A Group 3 (item 7, D7)**: capture the prep
        // generation at handler entry.  See proxySegmentRange
        // for rationale.
        let capturedGen = currentPrepGenerationValue()
        guard guardSegmentGeneration(
            capturedGen: capturedGen,
            connection: connection,
            connID: connID
        ) != nil else { return }
        // **PR-A Group 2 + Group 3**: log `segment_request`
        // only AFTER the generation guard passes.
        let pathOnly = req.path.split(separator: "?", maxSplits: 1).first
            .map(String.init) ?? req.path
        let queryOnly = req.path.split(separator: "?", maxSplits: 1).last
            .map(String.init) ?? ""
        diagLog(.playback, "segment_request", details: [
            "conn": connID,
            "path": pathOnly,
            "query": queryOnly,
            "mode": "\(mode)",
            "generation": capturedGen
        ])
        guard let (source, referer) = snapshot() else {
            respondError(connection: connection, status: 503,
                         reason: "no playback", connID: connID)
            return
        }
        let query = req.path.split(separator: "?", maxSplits: 1)
            .last.map(String.init) ?? ""
        let params = parseQuery(query)
        guard let encoded = params["u"],
              let upstreamString = base64urlDecode(encoded),
              let upstream = URL(string: upstreamString) else {
            respondError(connection: connection, status: 400,
                         reason: "missing u", connID: connID)
            return
        }
        // Refuse to proxy anything other than the B站 CDN
        // (or localhost, in dev).  This is a defence-in-depth
        // check; the segment URL is generated by us, so it
        // should always be a B站 URL anyway.
        guard let host = upstream.host,
              isAllowedUpstreamHost(host) else {
            respondError(connection: connection, status: 400,
                         reason: "bad upstream host", connID: connID)
            return
        }
        // **PR-C (Phase 2)**: parse the downstream Range
        // header early so the local-cache branch (below)
        // can match the same `clientRange` semantics that
        // the upstream Range branch uses.  `AVPlayer` is
        // strict about 206/Content-Range for byte-range
        // requests; pulling this forward keeps the two
        // branches consistent.
        let clientRange = req.headers["range"]
        // **PR-C (Phase 2)**: before doing a B站 Range
        // request, try the on-disk prefetch cache.  A hit
        // returns the bytes synchronously (FileHandle is
        // sync) so we never block on the network.  The LRU
        // touch fires after the response, on a background
        // Task, so the segment delivery itself stays on
        // the fast path.
        if let (bvid, cid, qn) = currentIdentity(),
           let kind = kindForUpstream(upstream, in: source),
           let absRange = absoluteByteRange(
                mode: mode, params: params, clientRange: clientRange
           ),
           let hit = tryLocalSegment(
                bvid: bvid, qn: qn, cid: cid, kind: kind,
                absRange: absRange
           ) {
            diagLog(.playback,
                    "LocalHLSProxyServer segment served from local cache",
                    details: [
                        "conn": connID,
                        "kind": kind == .video ? "video" : "audio",
                        "range": "\(absRange.lowerBound)"
                            + "-\(absRange.upperBound - 1)",
                        "bytes": hit.data.count,
                        "fileSize": hit.totalSize
                    ])
            touchPrefetchEntry(bvid: bvid, qn: qn, cid: cid)
            respondLocalSegment(
                connection: connection, mode: mode,
                absRange: absRange, totalSize: hit.totalSize,
                body: hit.data, connID: connID
            )
            return
        }
        var upstreamReq = URLRequest(url: upstream)
        upstreamReq.setValue(referer, forHTTPHeaderField: "Referer")
        upstreamReq.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) "
            + "Version/18.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        // Track the downstream Range so we can decide whether
        // to mirror 206/Content-Range or fall back to 200.
        // `AVPlayer` is strict: when it asks for `Range: bytes=…`,
        // it MUST see `206 Partial Content` plus a matching
        // `Content-Range` header, otherwise it abandons the
        // stream.  When it asks for the whole resource (no
        // Range), we MUST return `200 OK` with the full body.
        var contentRangeShift: Int64?
        var passContentRange = false
        switch mode {
        case .passthrough:
            // Forward Range if AVPlayer sent one (it does for
            // seeks).  B站 supports byte-range, so the forward is
            // safe.
            if let range = clientRange {
                upstreamReq.setValue(range, forHTTPHeaderField: "Range")
                passContentRange = true
            }
        case .initRange:
            // `/init` is a *logical* sub-resource that covers
            // only the fMP4 `ftyp`/`moov`/`sidx` bytes.
            // Record the sub-resource's absolute upstream
            // offset as the Content-Range shift so the
            // response can convert the upstream's absolute
            // `Content-Range` into the relative coordinates
            // AVPlayer expects for `/init` (the same way we
            // already do for `/media`).
            guard let range = parseByteRange(params["range"]) else {
                respondError(connection: connection, status: 400,
                             reason: "missing init range", connID: connID)
                return
            }
            upstreamReq.setValue(
                Self.httpRangeHeader(offset: range.offset, end: range.endOffset),
                forHTTPHeaderField: "Range"
            )
            contentRangeShift = range.offset
        case .mediaRange:
            guard let startString = params["from"],
                  let start = Int64(startString) else {
                respondError(connection: connection, status: 400,
                             reason: "missing media range", connID: connID)
                return
            }
            // Optional end byte.  When the multi-segment
            // playlist emits `/media?from=X&to=Y`, the server
            // only wants those exact bytes; without a Range
            // header from AVPlayer we have to synthesise one
            // for the upstream.
            let endString = params["to"]
            let end = endString.flatMap { Int64($0) }
            if let range = clientRange,
               let shifted = Self.shiftedRangeHeader(range, by: start) {
                upstreamReq.setValue(shifted, forHTTPHeaderField: "Range")
                contentRangeShift = start
            } else {
                upstreamReq.setValue(
                    Self.httpRangeHeader(offset: start, end: end),
                    forHTTPHeaderField: "Range"
                )
                contentRangeShift = start
            }
        }
        _ = source  // Keep the playback snapshot alive while
                    // the URLSession request is queued.

        // Virtual dynamic splicing (v2): the proxy used to
        // cancel in-flight requests whose byte range overlapped
        // with the new one — the theory was that AVPlayer
        // would otherwise see two streams deliver competing
        // bytes into the same socket and CoreMedia would emit
        // -19602 decode errors.
        //
        // In practice the cancellation is what was killing
        // playback.  AVPlayer issues 5-10 concurrent connections
        // per buffer fill; some of those connections carry
        // *adjacent* or *identical* byte ranges that the player
        // uses as a redundancy / pre-fetch mechanism.  When the
        // proxy pre-emptively cancelled the older connection,
        // the downstream socket closed mid-write, AVPlayer
        // threw away the partial response, and the buffer never
        // accumulated.  The player then stalled at the seek
        // point (`currentTime` stuck at the saved resume value,
        // `loadedTimeRanges` permanently empty) because every
        // request got cancelled before its bytes could land.
        //
        // The right behaviour is the user's "give generously":
        // honour AVPlayer's Range header, fetch whatever
        // upstream bytes are needed (the upstream CDN itself
        // serves arbitrary byte ranges — we don't need to do
        // any proxy-side concatenation), and let multiple
        // concurrent streams complete.  AVPlayer will discard
        // whatever it doesn't need; the upstream CDN handles
        // concurrent Range requests against the same file just
        // fine (it's their primary workload).
        //
        // We *do* keep the in-flight tracking below, but purely
        // for diagnostics — no cancellation, no pre-emption.
        // The "double-delivery" risk the old code was guarding
        // against never actually reproduced in the field; the
        // user-visible symptom it caused (post-seek stalls) is
        // far worse than the hypothetical it was preventing.
        let upstreamKey = upstream.absoluteString
        var reqStart: Int64?
        var reqEnd: Int64?

        if let rangeHeader = upstreamReq.value(forHTTPHeaderField: "Range"),
           rangeHeader.hasPrefix("bytes=") {
            let spec = rangeHeader.dropFirst("bytes=".count).trimmingCharacters(in: .whitespaces)
            let bounds = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            if bounds.count == 2, let rs = Int64(bounds[0]) {
                reqStart = rs
                if !bounds[1].isEmpty, let re = Int64(bounds[1]) {
                    reqEnd = re
                } else {
                    reqEnd = Int64.max // Representing until EOF
                }
            }
        } else if mode == .mediaRange {
            // If no range header was added (meaning we request to EOF), we still want to track it.
            if let startString = params["from"], let rs = Int64(startString) {
                reqStart = rs
                if let endString = params["to"], let re = Int64(endString) {
                    reqEnd = re
                } else {
                    reqEnd = Int64.max
                }
            }
        }

        if let rs = reqStart, let re = reqEnd {
            // Diagnostic-only: count concurrent in-flight streams
            // against the same upstream URL.  The actual dict
            // entry is registered in `StreamingProxyTask.start()`
            // (L3913-3918) with the *real* stream UUID; if we
            // pre-registered here with a throwaway UUID the
            // entry would briefly claim a slot no stream owns,
            // and `unregisterRange()` (L3932) — which checks
            // `existing.streamID == id` against the real UUID —
            // would leak the entry on cancellation.  Reading here
            // without writing is safe: any earlier request for
            // the same URL has already done its real-reg under
            // the same `lock`, so the fanout count is accurate
            // by the time this `proxySegmentRange` runs.
            lock.lock()
            let fanout = inFlightRanges[upstreamKey] != nil ? 1 : 0
            lock.unlock()
            if fanout > 0,
               Self.requestMetadataLogEnabled {
                diagLog(.network,
                        "LocalHLSProxyServer concurrent in-flight stream",
                        details: [
                            "conn": connID,
                            "mode": mode.logName,
                            "newRange": "\(rs)-\(re)"
                        ])
            }
        }

        if Self.requestMetadataLogEnabled {
            diagLog(.playback,
                    "LocalHLSProxyServer upstream request",
                    details: [
                        "conn": connID,
                        "mode": mode.logName,
                        "host": upstream.host ?? "",
                        "hasReferer": upstreamReq.value(
                            forHTTPHeaderField: "Referer"
                        ) != nil,
                        "range": upstreamReq.value(
                            forHTTPHeaderField: "Range"
                        ) ?? ""
                    ])
        }
        let stream = StreamingProxyTask(
            server: self,
            connection: connection,
            upstream: upstream,
            request: upstreamReq,
            mode: mode.logName,
            clientSentRange: clientRange != nil,
            contentRangeShift: contentRangeShift,
            passContentRange: passContentRange,
            connID: connID,
            rangeStart: reqStart,
            rangeEnd: reqEnd
        )
        retain(stream: stream)
        stream.start()
    }

    // MARK: local segment handler

    /// Local-mode equivalent of `proxySegment`.  Reads the
    /// init / media m4s file from `localContext.directory`
    /// and serves the requested byte range straight to the
    /// downstream socket — no upstream network call, no
    /// `URLSession`, no `Referer` rewrite.
    ///
    /// Status / `Content-Range` rules match `proxySegment`:
    ///   - no client Range → `200 OK` with the full body
    ///   - client Range   → `206 Partial Content` with a
    ///     matching `Content-Range` header
    fileprivate func proxyLocalSegment(
        req: HTTPRequest,
        connection: NWConnection,
        kind: ProxyMode,
        connID: String
    ) {
        // **PR-A Group 3 (item 7, D7)**: capture the prep
        // generation at handler entry.  See proxySegmentRange
        // for rationale.
        let capturedGen = currentPrepGenerationValue()
        guard guardSegmentGeneration(
            capturedGen: capturedGen,
            connection: connection,
            connID: connID
        ) != nil else { return }
        // **PR-A Group 2 + Group 3**: log `segment_request`
        // only AFTER the generation guard passes.
        let pathOnly = req.path.split(separator: "?", maxSplits: 1).first
            .map(String.init) ?? req.path
        let queryOnly = req.path.split(separator: "?", maxSplits: 1).last
            .map(String.init) ?? ""
        diagLog(.playback, "segment_request", details: [
            "conn": connID,
            "path": pathOnly,
            "query": queryOnly,
            "kind": "\(kind)",
            "generation": capturedGen
        ])
        let context: LocalPlaybackContext? = {
            lock.lock(); defer { lock.unlock() }
            return localContext
        }()
        guard let context else {
            respondError(connection: connection, status: 503,
                         reason: "no local context", connID: connID)
            return
        }
        let query = req.path.split(separator: "?", maxSplits: 1)
            .last.map(String.init) ?? ""
        let params = parseQuery(query)

        // Decode the upstream URL from the `u` query
        // parameter so we can match it against the active
        // `BiliDashSource` and decide whether this
        // init/media request is for the video or the audio
        // track.  Same wire contract as the upstream path.
        let source: BiliDashSource? = {
            lock.lock(); defer { lock.unlock() }
            return currentPlayback?.dash
        }()
        guard let source else {
            respondError(connection: connection, status: 503,
                         reason: "no source", connID: connID)
            return
        }
        guard let encoded = params["u"],
              let upstreamString = base64urlDecode(encoded),
              let upstream = URL(string: upstreamString) else {
            respondError(connection: connection, status: 400,
                         reason: "missing u", connID: connID)
            return
        }
        let mediaLabel: String
        let track: BiliDashSource.Track
        if source.video.baseURL == upstream {
            mediaLabel = "video"
            track = source.video
        } else if let audio = source.audio, audio.baseURL == upstream {
            mediaLabel = "audio"
            track = audio
        } else {
            respondError(connection: connection, status: 400,
                         reason: "unknown upstream", connID: connID)
            return
        }

        // Resolve the on-disk file path and the absolute
        // byte range the caller is asking for.  The wire
        // contract mirrors the upstream path: `/init` reads
        // from `track.initializationRange`, `/media` reads
        // from `track.mediaStartOffset` for the rest of the
        // file.
        let (fileURL, requestStart, requestEnd): (URL, Int64, Int64?) = {
            switch kind {
            case .initRange:
                guard let range = parseByteRange(params["range"]) else {
                    return (context.directory, 0, nil)
                }
                let url = context.directory
                    .appendingPathComponent("\(mediaLabel).init")
                let localStart = max(
                    0,
                    range.offset - track.initializationRange.offset
                )
                let localEnd = max(
                    localStart,
                    range.endOffset - track.initializationRange.offset
                )
                return (url, localStart, localEnd)
            case .mediaRange:
                guard let startString = params["from"],
                      let start = Int64(startString) else {
                    return (context.directory, 0, nil)
                }
                let endString = params["to"].flatMap { Int64($0) }
                let url = context.directory
                    .appendingPathComponent("\(mediaLabel).media")
                let localStart = max(0, start - track.mediaStartOffset)
                let localEnd = endString.map {
                    max(localStart, $0 - track.mediaStartOffset)
                }
                return (url, localStart, localEnd)
            case .passthrough:
                return (context.directory, 0, nil)
            }
        }()

        // PR-B B10: previously a missing local file fell through
        // to a 404 with no diagnostic; operators couldn't tell
        // whether the 404 was correct (file genuinely absent)
        // or whether `attributesOfItem` had thrown on a
        // permissions error.  Now logged so the dump
        // distinguishes the two failure modes.
        let fileSize: Int64? = {
            do {
                let attrs = try FileManager.default
                    .attributesOfItem(atPath: fileURL.path)
                return attrs[.size] as? Int64
            } catch {
                diagLog(.network,
                        "local file stat failed",
                        details: [
                            "path": fileURL.path,
                            "error": error.localizedDescription
                        ])
                return nil
            }
        }()
        guard let fileSize, fileSize > 0 else {
            respondError(connection: connection, status: 404,
                         reason: "missing local file", connID: connID)
            return
        }
        // Clamp the requested range to the file size.
        let endInclusive: Int64
        if let requestEnd {
            endInclusive = min(requestEnd, fileSize - 1)
        } else {
            endInclusive = fileSize - 1
        }
        let clampedStart = min(max(0, requestStart), fileSize - 1)
        guard clampedStart <= endInclusive else {
            respondError(connection: connection, status: 416,
                         reason: "range not satisfiable", connID: connID)
            return
        }
        let byteCount = endInclusive - clampedStart + 1

        // Read the bytes synchronously.  The files are
        // bounded (a typical VOD is 50-100 MB) and AVPlayer
        // typically asks for a sub-range; for a full-file
        // read we still serve it in one shot because the
        // player is happy to receive the whole segment
        // before issuing the next range.
        let data: Data
        do {
            let handle = try FileHandle(forReadingFrom: fileURL)
            // PR-B B11: refactor `defer { try? handle.close() }`
            // to log on close-failure.  The handle itself is
            // already opened (this is a defer, not the open),
            // so the failure mode is a kernel-level EBADF /
            // EIO on close (very rare but observable when
            // the file is concurrently replaced by a
            // download write).  Logged so a "second-half of
            // the byte range was 0 bytes" complaint can be
            // disambiguated from a "second-half close failed"
            // complaint (different remediation).
            defer {
                do {
                    try handle.close()
                } catch {
                    diagLog(.network,
                            "FileHandle.close failed",
                            details: [
                                "path": fileURL.path,
                                "error": error.localizedDescription
                            ])
                }
            }
            try handle.seek(toOffset: UInt64(clampedStart))
            data = handle.readData(ofLength: Int(byteCount))
        } catch {
            respondError(connection: connection, status: 500,
                         reason: "read failed: \(error.localizedDescription)",
                         connID: connID)
            return
        }

        let clientSentRange = req.headers["range"] != nil
        let status = clientSentRange ? 206 : 200
        var extra: [String: String] = ["Accept-Ranges": "bytes"]
        if clientSentRange {
            extra["Content-Range"] =
                "bytes \(clampedStart)-\(endInclusive)/\(fileSize)"
        }
        let mime: String
        switch kind {
        case .initRange, .mediaRange: mime = "video/mp4"
        case .passthrough:            mime = "video/mp4"
        }
        respondBytes(
            connection: connection,
            status: status,
            contentType: mime,
            body: data,
            extraHeaders: extra,
            connID: connID,
            label: "LOCAL SEGMENT"
        )
    }

    // MARK: response helpers

    private func respondText(connection: NWConnection,
                             connID: String,
                             body: String) {
        respondBytes(
            connection: connection,
            status: 200,
            contentType: "application/vnd.apple.mpegurl",
            body: Data(body.utf8),
            connID: connID,
            label: "DOWNSTREAM RESPONSE HEADER+SMALL BODY"
        )
    }

    // MARK: live

    /// Snapshot the active live playback.  Returns the cached
    /// state (upstream m3u8 URL list + referer) under lock.
    fileprivate func liveSnapshot() -> (candidates: [URL], referer: String)? {
        lock.lock(); defer { lock.unlock() }
        guard let p = currentLivePlayback,
              !p.hlsCandidates.isEmpty else { return nil }
        return (p.hlsCandidates, p.referer.absoluteString)
    }

    /// `GET /live/manifest.m3u8` — fetch the upstream m3u8 with
    /// the proper Referer + iOS UA, rewrite every segment URI
    /// back through this proxy (`/live/seg?u=<base64url>`), and
    /// return the rewritten m3u8.  Tries the CDN candidates in
    /// order; the first one that returns 200 wins.
    private func respondLiveManifest(connection: NWConnection,
                                     connID: String) {
        guard let (candidates, referer) = liveSnapshot() else {
            respondError(connection: connection, status: 503,
                         reason: "no live playback", connID: connID)
            return
        }
        diagLog(.playback, "/live/manifest fetch started",
                details: ["conn": connID, "candidates": candidates.count])

        // Walk the candidates in order.  Each fetch is async; the
        // first one that produces a 200 OK text body wins and we
        // rewrite the manifest to point at the proxy.
        // PR-C Task 4: explicit `[weak self]` so the @Sendable
        // Task closure doesn't capture a strong reference to
        // this non-MainActor final class.  Captures of
        // `candidates` / `referer` / `connID` / `connection`
        // are Sendable values (URL, String, NWConnection) so
        // they cross the closure boundary cleanly.
        Task { [weak self] in
            guard let self else { return }
            for (idx, candidate) in candidates.enumerated() {
                do {
                    let body = try await fetchLiveManifestBody(
                        url: candidate, referer: referer, connID: connID
                    )
                    let rewritten = rewriteLiveManifest(
                        body: body,
                        baseURL: candidate,
                        connID: connID
                    )
                    diagLog(.playback, "/live/manifest served",
                            details: [
                                "conn": connID,
                                "winning": idx,
                                "upstream": candidate.host ?? "?"
                            ])
                    respondText(
                        connection: connection,
                        connID: connID,
                        body: rewritten
                    )
                    return
                } catch {
                    diagLog(.playback, "/live/manifest candidate failed",
                            details: [
                                "conn": connID,
                                "candidate": candidate.host ?? "?",
                                "error": String(describing: error)
                            ])
                    continue
                }
            }
            respondError(connection: connection, status: 502,
                         reason: "all live candidates failed",
                         connID: connID)
        }
    }

    /// Fetch the upstream m3u8 body.  Uses the prep session so we
    /// reuse the same TLS handshake; a 5-second deadline caps the
    /// wait so a dead CDN can't stall the player.
    private func fetchLiveManifestBody(url: URL,
                                       referer: String,
                                       connID: String) async throws -> String {
        var req = URLRequest(url: url)
        req.setValue(referer, forHTTPHeaderField: "Referer")
        req.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) "
            + "Version/18.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        req.setValue("https://live.bilibili.com", forHTTPHeaderField: "Origin")
        guard let host = url.host, isAllowedUpstreamHost(host) else {
            throw URLError(.badURL)
        }
        let manifestRequest = req
        let session = prepSession ?? Self.makePrepSession()
        let (data, response) = try await raceWithDeadline(
            seconds: 5.0,
            label: "live-manifest"
        ) {
            try await session.data(for: manifestRequest)
        }
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw URLError(.init(rawValue: code))
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Rewrite the upstream m3u8 so every segment URI is served
    /// by us (`/live/seg?u=<base64url>`) instead of going direct
    /// to the CDN.  Bilibili playlists use absolute paths like
    /// `/live-bvc/.../123.ts` and full URLs interchangeably, so
    /// we resolve each non-`#EXT` line against the m3u8's base
    /// URL before encoding.
    private func rewriteLiveManifest(body: String,
                                     baseURL: URL,
                                     connID: String) -> String {
        // Matches `#EXT-X-MAP:URI="<some-uri>"` (HLSv6 fMP4 init
        // segment).  The URI may be absolute, scheme-less
        // (`//host/path`), or relative to the manifest — capture
        // the inner content of the `URI="..."` attribute so we
        // can rewrite it through the proxy alongside the regular
        // segments.  Without this rewrite AVPlayer fetches the
        // init segment directly from the B 站 CDN, which 403s
        // without the loopback Referer/UA — and the player stalls
        // on the first keyframe.  Surfaces on every fMP4 live
        // room (verified on room 7734200, 2026-07-06 via
        // `scripts/probe_live_endpoints.py`).
        // PR-B B12: previously `try?` silently fell
        // through to a no-op regex if the pattern was
        // malformed (it isn't — the pattern is a literal —
        // but a future change could introduce a runtime
        // failure that then vanishes).  Now logged so the
        // operator can see the failure rather than chase
        // a phantom "#EXT-X-MAP line didn't rewrite"
        // bug.
        let extXMapPattern: NSRegularExpression?
        do {
            extXMapPattern = try NSRegularExpression(
                pattern: #"#EXT-X-MAP:URI=\"([^\"]+)\""#
            )
        } catch {
            diagLog(.proxy,
                    "rewriteLiveBody: NSRegularExpression failed",
                    details: ["error": error.localizedDescription])
            extXMapPattern = nil
        }

        var out: [String] = []
        for raw in body.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = String(raw)
            // Header / metadata lines pass through unchanged —
            // except `#EXT-X-MAP` which carries a URI that must
            // go through this proxy.
            if line.isEmpty {
                out.append(line)
                continue
            }
            if line.hasPrefix("#EXT-X-MAP:") {
                if let regex = extXMapPattern,
                   let match = regex.firstMatch(
                    in: line, range: NSRange(line.startIndex..., in: line)
                   ),
                   let uriRange = Range(match.range(at: 1), in: line),
                   let inner = URL(
                    string: String(line[uriRange]), relativeTo: baseURL
                   )?.absoluteURL,
                   let rewritten = rewriteLiveURI(inner) {
                    let prefix = line[..<uriRange.lowerBound]
                    let suffix = line[uriRange.upperBound...]
                    out.append("\(prefix)\(rewritten)\(suffix)")
                } else {
                    out.append(line)
                }
                continue
            }
            if line.hasPrefix("#") {
                out.append(line)
                continue
            }
            guard let resolved = URL(string: line, relativeTo: baseURL)?
                .absoluteURL,
                  let rewritten = rewriteLiveURI(resolved) else {
                out.append(line)
                continue
            }
            out.append(rewritten)
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// Rewrite a single upstream URI to `/live/seg?u=<base64url>`.
    /// Extracted so both the segment-line and `#EXT-X-MAP` paths
    /// can share the exact same encoding rules.
    private func rewriteLiveURI(_ resolved: URL) -> String? {
        let encoded = base64urlEncode(resolved.absoluteString)
        return "/live/seg?u=\(encoded)"
    }

    /// `GET /live/seg?u=<base64url>` — byte-passthrough the
    /// upstream segment.  Mirrors the VOD
    /// `proxySegment(..., .passthrough)` rules: forward Range
    /// headers, allow only B站 CDN hosts, send the room's
    /// Referer + iOS UA.  Reuses the prep session so we share
    /// the connection pool with the manifest fetch.
    private func proxyLiveSegment(req: HTTPRequest,
                                  connection: NWConnection,
                                  connID: String) {
        guard let (_, referer) = liveSnapshot() else {
            respondError(connection: connection, status: 503,
                         reason: "no live playback", connID: connID)
            return
        }
        let query = req.path.split(separator: "?", maxSplits: 1)
            .last.map(String.init) ?? ""
        let params = parseQuery(query)
        guard let encoded = params["u"],
              let upstreamString = base64urlDecode(encoded),
              let upstream = URL(string: upstreamString) else {
            respondError(connection: connection, status: 400,
                         reason: "missing u", connID: connID)
            return
        }
        guard let host = upstream.host,
              isAllowedUpstreamHost(host) else {
            respondError(connection: connection, status: 400,
                         reason: "bad upstream host", connID: connID)
            return
        }
        var upstreamReq = URLRequest(url: upstream)
        upstreamReq.setValue(referer, forHTTPHeaderField: "Referer")
        upstreamReq.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) "
            + "Version/18.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        if let range = req.headers["range"] {
            upstreamReq.setValue(range, forHTTPHeaderField: "Range")
        }
        let liveSegmentRequest = upstreamReq
        let session = prepSession ?? Self.makePrepSession()
        // PR-C Task 4: explicit `[weak self]` so the @Sendable
        // Task closure doesn't capture a strong reference to
        // this non-MainActor final class.  `upstreamReq`,
        // `session`, `connection`, and `connID` are Sendable
        // values (URLRequest, URLSession, NWConnection, String).
        Task { [weak self] in
            guard let self else { return }
            do {
                let (data, response) = try await raceWithDeadline(
                    seconds: 8.0,
                    label: "live-seg"
                ) {
                    try await session.data(for: liveSegmentRequest)
                }
                guard let http = response as? HTTPURLResponse else {
                    respondError(connection: connection, status: 502,
                                 reason: "bad upstream response",
                                 connID: connID)
                    return
                }
                let status = http.statusCode
                if !(200..<300).contains(status) {
                    respondError(connection: connection, status: status,
                                 reason: "upstream returned \(status)",
                                 connID: connID)
                    return
                }
                // Forward Content-Length / Content-Range so
                // AVPlayer's byte accounting matches the bytes
                // we actually send.  Without Content-Range on a
                // 206 response AVPlayer abandons the stream.
                var extra: [String: String] = [:]
                if let cl = http.value(forHTTPHeaderField: "Content-Length") {
                    extra["Content-Length"] = cl
                }
                if let cr = http.value(forHTTPHeaderField: "Content-Range") {
                    extra["Content-Range"] = cr
                }
                // Live ts / fMP4 segments are octet-stream; let
                // AVPlayer sniff the container from the bytes
                // themselves by omitting Content-Type.
                respondBytes(
                    connection: connection,
                    status: status,
                    contentType: http.value(forHTTPHeaderField: "Content-Type")
                        ?? "application/octet-stream",
                    body: data,
                    extraHeaders: extra,
                    connID: connID,
                    label: "DOWNSTREAM LIVE SEGMENT"
                )
            } catch {
                // PR-B B2: previously the proxyLiveSegment
                // catch silently emitted only the 502 to
                // the client and the `error` description
                // stringified into the response body.  No
                // diagnostic survived in the dump — the
                // operator couldn't distinguish a URLSession
                // race-with-deadline timeout from an
                // upstream connection refused from a
                // JSON-decoding failure.  Now logged with
                // the error description so the dump shows
                // the exact failure mode.
                diagLog(.proxy,
                        "proxyLiveSegment: handler failed",
                        details: [
                            "conn": connID,
                            "error": error.localizedDescription
                        ])
                respondError(connection: connection, status: 502,
                             reason: "upstream fetch failed: \(error)",
                             connID: connID)
            }
        }
    }

    private func respondError(
        connection: NWConnection,
        status: Int,
        reason: String,
        extraHeaders: [String: String] = [:],
        connID: String
    ) {
        Analytics.recordError(
            NSError(domain: "paladala.proxy", code: status, userInfo: [
                NSLocalizedDescriptionKey: reason,
                "connID": connID
            ]),
            context: "proxy_respondError"
        )
        let body = "{\"error\":\"\(reason)\"}"
        respondBytes(
            connection: connection,
            status: status,
            contentType: "application/json",
            body: Data(body.utf8),
            extraHeaders: extraHeaders,
            connID: connID,
            label: "DOWNSTREAM ERROR RESPONSE"
        )
    }

    /// **PR-A Group 3 (item 7, D7)** — return the current prep
    /// generation if it still matches `capturedGen`, otherwise
    /// respond 503 + `Retry-After: 0` and return `nil`.  Used
    /// by `/init`, `/media`, `/segment` handlers so that an
    /// in-flight request for a previous playback session cannot
    /// serve stale bytes to the AVPlayer of a new session.
    internal func guardSegmentGeneration(
        capturedGen: UInt64,
        connection: NWConnection,
        connID: String
    ) -> UInt64? {
        let current: UInt64 = {
            lock.lock(); defer { lock.unlock() }
            return currentPrepGeneration
        }()
        guard current == capturedGen else {
            diagLog(.playback, "segment_generation_stale", details: [
                "conn": connID,
                "captured": capturedGen,
                "current": current
            ])
            respondError(
                connection: connection,
                status: 503,
                reason: "stale prep generation",
                extraHeaders: ["Retry-After": "0"],
                connID: connID
            )
            return nil
        }
        return current
    }

    /// **PR-B Commit 4 (A4 test)**: test-only seam for
    /// `guardSegmentGeneration`.  Returns the boolean guard
    /// result (`true` = current, `false` = stale) WITHOUT
    /// calling `respondError`, so the test can exercise the
    /// stale detection logic without a live `NWConnection`.
    /// Mirrors the production function's read-side logic
    /// exactly: reads `currentPrepGeneration` under `lock`
    /// and compares.
    internal func guardSegmentGenerationForTest(
        capturedGen: UInt64,
        connection: NWConnection?,
        connID: String
    ) -> UInt64? {
        let current: UInt64 = {
            lock.lock(); defer { lock.unlock() }
            return currentPrepGeneration
        }()
        // Match the production guard: stale → nil.  The
        // `connection` parameter is intentionally unused
        // here (production would `respondError` on the
        // stale path; this seam drops that side effect so
        // the test can run without a real connection).
        _ = connection
        guard current == capturedGen else {
            return nil
        }
        return current
    }

    // MARK: - local prefetch cache (PR-C Phase 2)

    /// **PR-C (Phase 2)**: try to read a segment from the
    /// on-disk prefetch cache.  Returns the bytes plus the
    /// total file size (needed for the `Content-Range`
    /// header), or `nil` on a miss — caller falls through
    /// to the B站 Range path.  Misses are silent (no log);
    /// the caller logs the success path so the next
    /// diagnostic dump will show `source: local` vs
    /// `source: upstream`.
    private func tryLocalSegment(
        bvid: String,
        qn: Int,
        cid: Int64,
        kind: PrefetchKind,
        absRange: Range<Int64>
    ) -> (data: Data, totalSize: Int64)? {
        let key = PlaybackPrefetchManager.cacheKey(
            bvid: bvid, qn: qn, cid: cid
        )
        let dir = PlaybackPrefetchManager.shared.cacheDirectory
            .appendingPathComponent(key, isDirectory: true)
        let filename = (kind == .video) ? "video.m4s" : "audio.m4s"
        let fileURL = dir.appendingPathComponent(filename)
        // `attributesOfItem` is the cheap way to learn the
        // on-disk size without opening the file twice
        // (and works even if the file is mid-write from
        // a concurrent prefetch).
        guard let attrs = try? FileManager.default
                .attributesOfItem(atPath: fileURL.path),
              let totalSize = (attrs[.size] as? Int64)
        else {
            // **PR-C (Phase 2 — fix, take 3)**: log a
            // local-cache miss so the next diagnostic
            // shows whether the segment fell through to
            // the B站 Range path because the cache file
            // didn't exist yet (prefetch hasn't reached
            // that range), the cache dir is missing, or
            // an I/O error happened.  One line per miss
            // is high-cardinality but it's the only way
            // to disambiguate "AVPlayer kept streaming
            // from upstream" from "AVPlayer used local
            // cache but the bytes were wrong" once the
            // `served from local cache` log has the
            // miss count next to it.
            diagLog(.playback,
                    "LocalHLSProxyServer /segment local cache miss",
                    details: [
                        "key": key,
                        "kind": kind == .video ? "video" : "audio",
                        "range":
                            "\(absRange.lowerBound)"
                            + "-\(absRange.upperBound - 1)",
                        "filePath": fileURL.path
                    ])
            return nil
        }
        // Clamp the requested range to the actual file
        // size.  `absRange.upperBound` may be `Int64.max`
        // for "read to EOF" ranges; clamping here turns
        // that into a real bound so the FileHandle read
        // doesn't have to.
        let clampedEnd = min(absRange.upperBound, totalSize)
        guard clampedEnd > absRange.lowerBound else { return nil }
        let clamped = absRange.lowerBound..<clampedEnd
        guard let handle = try? FileHandle(forReadingFrom: fileURL)
        else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(clamped.lowerBound))
            // `FileHandle.read(upToCount:)` returns `Data?`
            // — nil means EOF (which here is also a miss;
            // the cache file is shorter than the caller
            // expected, treat as a clean miss instead of
            // serving a truncated payload).
            guard let data = try handle.read(
                upToCount: Int(clamped.count)
            ) else { return nil }
            return (data: data, totalSize: totalSize)
        } catch {
            return nil
        }
    }

    /// **PR-C (Phase 2)**: respond to a local-cache hit
    /// with the same 206/Content-Range framing the B站 CDN
    /// would have returned.  Mirrors what
    /// `StreamingProxyTask` does on the upstream success
    /// path so AVPlayer can't tell the difference.
    private func respondLocalSegment(
        connection: NWConnection,
        mode: ProxyMode,
        absRange: Range<Int64>,
        totalSize: Int64,
        body: Data,
        connID: String
    ) {
        let endInclusive = absRange.upperBound - 1
        let contentRange = "bytes \(absRange.lowerBound)"
            + "-\(endInclusive)/\(totalSize)"
        respondBytes(
            connection: connection,
            status: 206,
            contentType: "video/mp4",
            body: body,
            extraHeaders: ["Content-Range": contentRange],
            connID: connID,
            label: "LOCAL \(mode.logName) \(absRange.lowerBound)"
                + "-\(endInclusive)"
        )
    }

    /// **PR-C (Phase 2)**: read the current prefetch
    /// identity (bvid + cid + qn) under the proxy's lock.
    /// Returns `nil` for any of the three missing — caller
    /// falls through to the B站 Range path.
    private func currentIdentity() -> (bvid: String, cid: Int64, qn: Int)? {
        lock.lock(); defer { lock.unlock() }
        guard let bvid = currentBvid,
              let cid = currentCid,
              let qn = currentQn
        else { return nil }
        return (bvid, cid, qn)
    }

    /// **PR-C (Phase 2)**: map an upstream URL back to a
    /// `PrefetchKind` (video/audio) by matching against
    /// the active DASH source.  Returns `nil` if the URL
    /// doesn't correspond to either track (in which case
    /// the local cache can't help anyway — the request is
    /// for a different resource).
    private func kindForUpstream(
        _ upstream: URL,
        in source: BiliDashSource
    ) -> PrefetchKind? {
        let upstreamString = upstream.absoluteString
        if source.video.baseURL.absoluteString == upstreamString {
            return .video
        }
        if let audio = source.audio,
           audio.baseURL.absoluteString == upstreamString {
            return .audio
        }
        // Backup URLs share the same bytes as the primary,
        // so they can satisfy the same local read.  The
        // prefetch always downloads the primary (per
        // `primaryUpstreamURL` in the manager), so a
        // backup-URL request reads from the same file.
        if source.video.backupURLs.contains(where: {
            $0.absoluteString == upstreamString
        }) {
            return .video
        }
        if let audio = source.audio,
           audio.backupURLs.contains(where: {
            $0.absoluteString == upstreamString
           }) {
            return .audio
        }
        return nil
    }

    /// **PR-C (Phase 2)**: compute the absolute upstream
    /// byte range for the current request, in upstream-
    /// file coordinates.  Each `ProxyMode` derives the
    /// range differently:
    ///   - `.initRange`  — from the `range=` query param,
    ///     already in upstream coordinates.
    ///   - `.mediaRange` — from `from=` / `to=` query
    ///     params, upstream coordinates.
    ///   - `.passthrough` — from the client `Range` header,
    ///     also upstream coordinates (we never shift the
    ///     client's Range for passthrough).
    /// Returns `nil` if the params are missing or
    /// malformed — caller falls through to the B站 Range
    /// path so the existing 400 error surface still
    /// applies.
    private func absoluteByteRange(
        mode: ProxyMode,
        params: [String: String],
        clientRange: String?
    ) -> Range<Int64>? {
        switch mode {
        case .initRange:
            guard let rangeStr = params["range"],
                  let r = parseByteRange(rangeStr) else { return nil }
            return r.offset..<(r.offset + r.length)
        case .mediaRange:
            guard let startStr = params["from"],
                  let start = Int64(startStr) else { return nil }
            if let toStr = params["to"], let end = Int64(toStr) {
                return start..<(end + 1)
            }
            // No `to` — read to EOF.  `Int64.max` is
            // clamped against the actual file size by
            // `tryLocalSegment` above.
            return start..<Int64.max
        case .passthrough:
            guard let rangeStr = clientRange,
                  let r = parseByteRange(rangeStr) else { return nil }
            return r.offset..<(r.offset + r.length)
        }
    }

    /// **PR-C (Phase 2)**: fire the LRU `entryAndTouch`
    /// asynchronously after a local-cache hit.  Best-
    /// effort; a failure here just means the LRU sees a
    /// stale timestamp on next launch, which only affects
    /// eviction order, not correctness.  Fire-and-forget
    /// so the segment response doesn't wait on the actor
    /// hop.
    private func touchPrefetchEntry(bvid: String, qn: Int, cid: Int64) {
        Task.detached(priority: .background) {
            _ = await PlaybackPrefetchManager.shared.entryAndTouch(
                bvid: bvid, qn: qn, cid: cid
            )
        }
    }

    /// **PR-C (Phase 2)**: helper for the `/segment` route,
    /// which keys its `k=` query param by string instead
    /// of by upstream URL match.  Returns `nil` for any
    /// value other than the two we know how to map —
    /// caller falls through to the B站 Range path.
    private func kindForTrackKind(_ k: String?) -> PrefetchKind? {
        switch k {
        case "video": return .video
        case "audio": return .audio
        default: return nil
        }
    }

    private func respondBytes(
        connection: NWConnection,
        status: Int,
        contentType: String,
        body: Data,
        extraHeaders: [String: String] = [:],
        connID: String,
        label: String
    ) {
        var response = httpHeaderData(
            status: status,
            contentType: contentType,
            contentLength: Int64(body.count),
            extraHeaders: extraHeaders
        )
        response.append(body)
        if Self.wireDumpEnabled {
            // Diagnostic: dump the actual bytes we are about
            // to hand to `connection.send` so we can see the
            // on-wire framing (CRLF + double-CRLF terminator,
            // Content-Length, headers, etc.).
            diagLog(.network,
                    "LocalHLSProxyServer wire bytes",
                    details: [
                        "conn": connID,
                        "label": label,
                        "bytes": Self.dumpWireBytes(response, label: label)
                    ])
        }
        connection.send(
            content: response,
            completion: .contentProcessed { _ in
                // PR-B B7: log the connection.cancel()
                // that fires after a successful body send.
                // Without this line, the only signal in
                // the dump is the connection-state
                // transition a few ms later; the operator
                // can't tell whether the cancel was
                // expected (response complete) or a
                // peer-closed race.
                diagLog(.proxy,
                        "respondBytes: connection.cancel",
                        details: [
                            "conn": connID,
                            "label": label,
                            "status": status,
                            "bytesSent": body.count
                        ])
                connection.cancel()
            }
        )
    }

    fileprivate func sendHeader(
        connection: NWConnection,
        sendGroup: DispatchGroup,
        status: Int,
        contentType: String,
        contentLength: Int64?,
        extraHeaders: [String: String] = [:],
        connID: String? = nil
    ) {
        let header = httpHeaderData(
            status: status,
            contentType: contentType,
            contentLength: contentLength,
            extraHeaders: extraHeaders
        )
        if Self.wireDumpEnabled {
            diagLog(.network,
                    "LocalHLSProxyServer wire bytes",
                    details: [
                        "conn": connID ?? "",
                        "label": "DOWNSTREAM RESPONSE HEADER",
                        "bytes": Self.dumpWireBytes(
                            header,
                            label: "DOWNSTREAM RESPONSE HEADER"
                        )
                    ])
        }
        // **PR-B D1 (CRITICAL)**: pair every header send
        // with a `sendGroup.enter()` so `finishWhenSendsDrain`
        // can't fire on a count of zero and race the header
        // write.  Previously the 5xx exhaustion path AND
        // the Content-Range 502 path called `sendHeader` and
        // then immediately scheduled drain / cancel — if the
        // drain closure ran before the header bytes hit the
        // wire, `connection.cancel` would terminate the
        // send mid-flight and AVPlayer would see a truncated
        // status line.
        sendGroup.enter()
        connection.send(
            content: header,
            completion: .contentProcessed { _ in
                sendGroup.leave()
            }
        )
    }

    private func httpHeaderData(
        status: Int,
        contentType: String,
        contentLength: Int64?,
        extraHeaders: [String: String] = [:]
    ) -> Data {
        let reason = reasonPhrase(for: status)
        var headerLines = [
            "HTTP/1.1 \(status) \(reason)",
            "Content-Type: \(contentType)",
        ]
        for key in extraHeaders.keys.sorted() {
            headerLines.append("\(key): \(extraHeaders[key] ?? "")")
        }
        if let contentLength {
            headerLines.append("Content-Length: \(contentLength)")
        }
        headerLines += [
            "Connection: close",
            "Cache-Control: no-store",
            "",
            "",
        ]
        return Data(headerLines.joined(separator: "\r\n").utf8)
    }

    private func retain(stream: StreamingProxyTask) {
        lock.lock()
        activeStreams[stream.id] = stream
        lock.unlock()
    }

    fileprivate func finishStream(id: UUID) {
        lock.lock()
        activeStreams.removeValue(forKey: id)
        lock.unlock()
    }

    fileprivate func addStreamedBytes(_ count: Int) {
        lock.lock()
        byteCount += Int64(count)
        lock.unlock()
    }

    private func reasonPhrase(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        default:  return "OK"
        }
    }

    // MARK: utilities

    private func parseQuery(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in s.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 {
                let k = String(kv[0])
                let v = String(kv[1])
                out[k] = v.removingPercentEncoding ?? v
            }
        }
        return out
    }

    private func localURL(
        path: String,
        queryItems: [URLQueryItem] = []
    ) -> String {
        guard let baseURL = safeBaseURL else { return "" }
        return localURL(baseURL: baseURL, path: path, queryItems: queryItems)
    }

    private func localURL(
        baseURL: URL,
        path: String,
        queryItems: [URLQueryItem] = []
    ) -> String {
        let url = baseURL.appendingPathComponent(path)
        guard !queryItems.isEmpty else {
            return url.absoluteString
        }
        var components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = queryItems
        return components?.url?.absoluteString ?? url.absoluteString
    }

    private func parseByteRange(
        _ raw: String?
    ) -> BiliDashSource.ByteRange? {
        guard let raw else { return nil }
        let bounds = raw.split(separator: "-", maxSplits: 1)
        guard bounds.count == 2,
              let start = Int64(bounds[0]),
              let end = Int64(bounds[1]),
              end >= start else {
            return nil
        }
        return BiliDashSource.ByteRange(
            offset: start,
            length: end - start + 1
        )
    }

    fileprivate static func httpRangeHeader(offset: Int64, end: Int64?) -> String {
        if let end {
            return "bytes=\(offset)-\(end)"
        }
        return "bytes=\(offset)-"
    }

    fileprivate static func shiftedRangeHeader(
        _ header: String,
        by offset: Int64
    ) -> String? {
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("bytes=") else {
            return nil
        }
        let spec = trimmed.dropFirst("bytes=".count)
        guard !spec.contains(",") else { return nil }
        let bounds = spec.split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard bounds.count == 2,
              !bounds[0].isEmpty,
              let relativeStart = Int64(bounds[0]) else {
            return nil
        }
        let absoluteStart = offset + relativeStart
        if bounds[1].isEmpty {
            return Self.httpRangeHeader(offset: absoluteStart, end: nil)
        }
        guard let relativeEnd = Int64(bounds[1]),
              relativeEnd >= relativeStart else {
            return nil
        }
        return Self.httpRangeHeader(
            offset: absoluteStart,
            end: offset + relativeEnd
        )
    }

    /// Converts an upstream `Content-Range: bytes X-Y/Z` header to
    /// client-side relative coordinates by subtracting `offset`.
    ///
    /// The denominator (Z) is preserved exactly as-is — it must always
    /// be the original CDN file's total byte count.  AVPlayer tracks
    /// the file's total duration via this value; shrinking it per
    /// segment (e.g. Z→Z−offset) causes the playback timeline to
    /// contract with every new segment and ultimately triggers
    /// `-19602` decode errors.
    fileprivate func shiftedContentRange(
        _ header: String,
        by offset: Int64
    ) -> String? {
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("bytes ") else {
            return nil
        }
        let payload = trimmed.dropFirst("bytes ".count)
        let rangeAndTotal = payload.split(
            separator: "/",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard rangeAndTotal.count == 2 else { return nil }
        let bounds = rangeAndTotal[0].split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard bounds.count == 2,
              let absoluteStart = Int64(bounds[0]),
              let absoluteEnd = Int64(bounds[1]),
              absoluteStart >= offset,
              absoluteEnd >= absoluteStart else {
            return nil
        }
        let relativeStart = absoluteStart - offset
        let relativeEnd = absoluteEnd - offset

        let totalPart: String
        if rangeAndTotal[1] == "*" {
            totalPart = "*"
        } else if let absoluteTotal = Int64(rangeAndTotal[1]) {
            let relativeTotal = absoluteTotal - offset
            totalPart = "\(relativeTotal)"
        } else {
            return nil
        }

        return "bytes \(relativeStart)-\(relativeEnd)/\(totalPart)"
    }

    private func isAllowedUpstreamHost(_ host: String) -> Bool {
        let lower = host.lowercased()
        if lower == "127.0.0.1" || lower == "localhost" {
            return true
        }
        let allowedDomains = [
            "bilivideo.com",
            "bilivideo.cn",
            "hdslb.com",
            "bilibili.com",
            "akamaized.net",
            "szbdyd.com",
        ]
        return allowedDomains.contains { domain in
            lower == domain || lower.hasSuffix(".\(domain)")
        }
    }

    private func base64urlEncode(_ s: String) -> String {
        Data(s.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func base64urlDecode(_ s: String) -> String? {
        var t = s
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t.append("=") }
        guard let d = Data(base64Encoded: t) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    fileprivate func mimeType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "m3u8":               return "application/vnd.apple.mpegurl"
        case "m4s", "mp4", "mov":  return "video/mp4"
        case "aac":                return "audio/aac"
        case "ts":                 return "video/mp2t"
        default:                   return "application/octet-stream"
        }
    }
}

private final class StreamingProxyTask: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let id = UUID()

    /// Strong reference to the owning proxy.  The
    /// `LocalHLSProxyServer` singleton is a process-lifetime
    /// object (the brief and pre-existing code treat it
    /// as a process singleton, see `recreateForResume()`
    /// which clears `activeStreams` rather than
    /// deallocating the proxy itself), so a strong
    /// reference here cannot create a leak.  The previous
    /// `weak var` triggered Swift 6's "stored property of
    /// Sendable-conforming class is mutable" error because
    /// the class is implicitly treated as Sendable in the
    /// delegate-queue dispatch context; `let` satisfies
    /// the Sendable storage check.
    private let server: LocalHLSProxyServer
    private let connection: NWConnection
    // `var` (not `let`) so the transport-error failover path
    // in `didCompleteWithError` can rebind this task to the
    // next backup host. The mutation is serialised on the
    // `delegateQueue` (maxConcurrentOperationCount == 1),
    // and the previous host stays accessible via the
    // outbound URL capture if a follow-up diagnostic ever
    // needs it.
    private var upstream: URL
    private let request: URLRequest
    private let mode: String
    /// Short, stable ID for the TCP connection that originated
    /// this request.  Propagated into every diagnostic marker
    /// so we can correlate lifecycle events on the same
    /// socket — particularly useful for the keep-alive-reuse
    /// hypothesis (trap 3).
    fileprivate let connID: String
    /// Absolute byte range this stream is fetching from the
    /// upstream.  Used to detect overlaps with other in-flight
    /// streams so we can cancel the older one and avoid
    /// double-delivery decode errors (-19602).
    private let rangeStart: Int64?
    private let rangeEnd: Int64?
    /// `true` if the loopback client (AVPlayer) sent a
    /// `Range` header.  When `true`, our downstream response
    /// MUST use `206 Partial Content` and include a
    /// `Content-Range` header — AVPlayer aborts any
    /// partial-content request that does not get a 206.
    /// When `false`, the response MUST be `200 OK` with no
    /// `Content-Range` header.
    private let clientSentRange: Bool
    private let contentRangeShift: Int64?
    private let passContentRange: Bool
    private let sendGroup = DispatchGroup()
    private let delegateQueue: OperationQueue

    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var didSendHeader = false
    private var didFinish = false
    /// Diagnostic counters for the downstream body stream
    /// (only touched when `LocalHLSProxyServer.wireDumpEnabled`
    /// is `true`).  Used to emit the body-totals log line on
    /// completion so we can cross-check the actual bytes we
    /// pushed to `connection.send` against the
    /// `Content-Length` we promised in the header.
    private var downstreamChunksSent = 0
    private var downstreamBytesSent: Int64 = 0
    /// Set as soon as we see a downstream send failure
    /// (e.g. AVPlayer tore the socket down in
    /// `onDisappear`).  Guards against continuing to
    /// drain a 71 MB upstream response into a dead
    /// `NWConnection`.
    private var downstreamBroken = false
    /// Total bytes that have arrived from the upstream
    /// across every attempt so far.  On a mid-stream
    /// upstream failure we re-issue the same Range shifted
    /// to `bytesReceivedFromUpstream` so the downstream
    /// (AVPlayer) sees one continuous byte stream — it
    /// never knows the upstream socket was reset.
    private var bytesReceivedFromUpstream: Int64 = 0
    /// 0 = the very first request, 1..3 = retries.  Capped
    /// at `Self.maxRetries` total attempts to avoid an
    /// infinite loop if the upstream keeps failing.
    private var upstreamAttempt: Int = 0
    /// Set when we abort the current upstream task on
    /// purpose to schedule a retry (e.g. 5xx response, or a
    /// retryable transport error).  Without this flag the
    /// resulting `URLError.cancelled` in
    /// `didCompleteWithError` would look identical to the
    /// "we cancelled because the downstream went away"
    /// path and we'd never retry.
    private var cancelledForRetry = false
    /// **PR-B D3**: set when the Content-Range header
    /// from the upstream doesn't match the Range we asked
    /// for.  Without this flag a late `didReceive data`
    /// callback (URLSession's `.cancel` is asynchronous)
    /// could slip past the `downstreamBroken` guard and
    /// trigger a synthesised 200 header for a socket we
    /// have already decided to fail.  Mirrors
    /// `cancelledForRetry` (L3800).
    private var cancelledForRangeMismatch = false
    /// **PR-B B4**: gate so the "didReceive data first-chunk"
    /// diagnostic fires exactly once per task.  Without
    /// this gate, the log would repeat for every segment
    /// in a long video (one line per segment) and drown
    /// out the more interesting "first byte arrived N ms
    /// after the request" signal that operators actually
    /// use to spot slow-start upstream issues.
    private var firstChunkLogged = false

    /// Maximum number of times we re-issue the upstream
    /// request after the first attempt.  With base backoff
    /// 100ms and a 3× multiplier the worst-case extra wait
    /// is 100+300+900 = 1300ms — short enough that the
    /// `controller.isBuffering` overlay shows briefly but
    /// AVPlayer does not give up.
    private static let maxRetries: Int = 3
    private static let baseBackoffSeconds: Double = 0.1

    init(
        server: LocalHLSProxyServer,
        connection: NWConnection,
        upstream: URL,
        request: URLRequest,
        mode: String,
        clientSentRange: Bool,
        contentRangeShift: Int64?,
        passContentRange: Bool,
        connID: String,
        rangeStart: Int64?,
        rangeEnd: Int64?
    ) {
        self.server = server
        self.connection = connection
        // `var` (not `let`) so the failover path in
        // `didCompleteWithError` can swap in the next
        // backup host after a transport-level failure
        // instead of hammering the same hung edge.
        // Mutations happen exclusively on the
        // `delegateQueue` (which is serial), so the
        // single-property mutation is race-free.
        self.upstream = upstream
        self.request = request
        self.mode = mode
        self.clientSentRange = clientSentRange
        self.contentRangeShift = contentRangeShift
        self.passContentRange = passContentRange
        self.connID = connID
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
        self.delegateQueue = OperationQueue()
        self.delegateQueue.maxConcurrentOperationCount = 1
        super.init()
        // Watch the loopback connection for peer-initiated
        // close.  When AVPlayer goes to fullscreen it tears
        // down in-flight segments; the OS then drives the
        // `NWConnection` into `.cancelled` (or `.failed` on
        // a RST).  We use that signal to stop the upstream
        // URLSession task immediately so we don't keep
        // pulling bytes from the B站 CDN for a dead
        // downstream socket.  The handler is installed in
        // `init` (not when the first send happens) so we
        // catch disconnects that arrive *before* the first
        // body send, which would otherwise slip through the
        // `connection.send` error path entirely.
        //
        // The handler runs on the connection's queue
        // (`LocalHLSProxyServer.queue`, the listener queue).
        // `task?.cancel()` is safe to call from any thread;
        // URLSession will route the resulting
        // `didCompleteWithError(NSURLErrorCancelled)` to the
        // serial `delegateQueue` where the existing branch
        // at `urlSession(_:task:didCompleteWithError:)` calls
        // `finishWhenSendsDrain()` for clean teardown.
        self.connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .cancelled:
                // .cancelled means we (or AVPlayer tearing
                // the socket down on host switch / source
                // change / user navigated away) asked the
                // connection to close.  It is NOT a broken
                // downstream — log a single quiet line so the
                // diagnostic dump still records the teardown
                // but the operator (or anyone reading the
                // dump) doesn't read it as a real B站 / CDN
                // failure.  The URLSession
                // didCompleteWithError(NSURLErrorCancelled)
                // branch elsewhere handles actual teardown.
                let reason = "connection state: \(state)"
                self.delegateQueue.addOperation { [weak self] in
                    guard let self else { return }
                    guard !self.downstreamBroken else { return }
                    diagLog(.network,
                            "LocalHLSProxyServer downstream closed",
                            details: [
                                "conn": self.connID,
                                "mode": self.mode,
                                "reason": reason
                            ])
                }
            case .failed:
                // .failed is a real upstream / peer-initiated
                // close (POSIX 54 "Connection reset by peer",
                // TLS errors, etc.) — surface it as a broken
                // downstream so the existing failure handlers
                // can mark the host for failover.
                let reason = "connection state: \(state)"
                self.delegateQueue.addOperation { [weak self] in
                    self?.markDownstreamBroken(reason: reason)
                }
            default:
                break
            }
        }
    }

    func start() {
        startSession()
        // Register this stream's byte range so overlapping
        // requests from concurrent AVPlayer tasks can be caught.
        if let rs = rangeStart, let re = rangeEnd {
            let key = upstream.absoluteString
            server.lock.lock()
            server.inFlightRanges[key] = (rs, re, id)
            server.lock.unlock()
        }
        startUpstreamTask(attempt: 0)
    }

    /// Cancel this stream and unregister its byte range so any
    /// overlapping new request can proceed without competing
    /// with a dead socket.
    fileprivate func cancel() {
        delegateQueue.addOperation { [weak self] in
            guard let self else { return }
            // PR-B B3: first-line log so the operator can
            // see every cancellation, not just the ones that
            // happen to trigger a downstream event.
            diagLog(.proxy,
                    "StreamingProxyTask.cancel",
                    details: [
                        "id": self.id.uuidString,
                        "downstreamBroken": self.downstreamBroken,
                        "cancelledForRetry": self.cancelledForRetry,
                        "url": self.upstream.absoluteString
                    ])
            self.task?.cancel()
            self.connection.cancel()
            self.session?.finishTasksAndInvalidate()
            self.unregisterRange()
        }
    }

    private func unregisterRange() {
        guard let rs = rangeStart, let re = rangeEnd else { return }
        let key = upstream.absoluteString
        server.lock.lock()
        if let existing = server.inFlightRanges[key],
           existing.streamID == id,
           existing.start == rs, existing.end == re {
            server.inFlightRanges.removeValue(forKey: key)
        }
        server.lock.unlock()
    }

    /// Mark the downstream socket as gone and stop pulling
    /// bytes from the B站 CDN for it.  Idempotent — the
    /// `stateUpdateHandler` (peer-initiated close) and the
    /// `connection.send` completion (we noticed on write)
    /// can both call in, and the first writer wins.  Logs a
    /// single `downstream closed` line on the *first* call
    /// so the diagnostic stream still shows the specific
    /// reason without spamming duplicates when both paths
    /// fire on the same disconnect.
    ///
    /// We deliberately do NOT call `connection.cancel()`
    /// here.  When the send-error path triggers us, there
    /// is an in-flight `connection.send` whose completion
    /// closure still has to `sendGroup.leave()` — cancelling
    /// the connection mid-send would prevent that and leave
    /// `finishWhenSendsDrain()` waiting forever.  The
    /// existing `urlSession(_:task:didCompleteWithError:)`
    /// path handles `NSURLErrorCancelled` and drives the
    /// connection cancel via `sendGroup.notify` once the
    /// drain is complete.
    fileprivate func markDownstreamBroken(reason: String) {
        if downstreamBroken { return }
        downstreamBroken = true
        // `task` is the URLSession upstream leg; cancelling
        // it stops further `didReceive data` callbacks.
        task?.cancel()
        session?.invalidateAndCancel()
        diagLog(.network,
                "LocalHLSProxyServer downstream closed",
                details: [
                    "conn": connID,
                    "mode": mode,
                    "reason": reason
                ])
        // PR-A Group 2: emit a structured
        // `downstream_broken_cancelling_stream` event so the
        // diagnostic log can be grepped for "when did each
        // stream leg die?" without parsing the free-form
        // `reason` field.  The existing "downstream closed"
        // log stays for human-readable context.
        diagLog(.playback,
                "downstream_broken_cancelling_stream",
                details: [
                    "conn": connID,
                    "streamID": "\(mode)",
                    "reason": reason
                ])
    }

    /// One-shot URLSession construction.  Kept separate from
    /// `startUpstreamTask(attempt:)` so the session survives
    /// across retries — creating a fresh `URLSession` per
    /// attempt would burn a new TCP + TLS handshake per
    /// retry, which both slows down recovery and defeats
    /// connection pooling on subsequent segments.
    private func startSession() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        let session = URLSession(
            configuration: configuration,
            delegate: self,
            delegateQueue: delegateQueue
        )
        self.session = session
    }

    /// (Re)issue the upstream request.  On a retry the
    /// Range header is shifted by `bytesReceivedFromUpstream`
    /// so the CDN hands us the bytes that were lost when
    /// the previous attempt's socket died.  The downstream
    /// (AVPlayer) sees those bytes appended to the stream it
    /// already has — no AVPlayer-side retry, no gap.
    private func startUpstreamTask(attempt: Int) {
        guard let session else { return }
        upstreamAttempt = attempt
        cancelledForRetry = false
        let shifted = shiftedRequest(startingAt: bytesReceivedFromUpstream)
        let task = session.dataTask(with: shifted)
        self.task = task
        task.resume()
    }

    /// Build a new `URLRequest` for the upstream that picks
    /// up where the previous attempt left off.  We mutate a
    /// copy of the original request so the referer / user
    /// agent / host we already validated are preserved.
    private func shiftedRequest(startingAt offset: Int64) -> URLRequest {
        var newRequest = request
        guard offset > 0 else { return newRequest }
        let originalRange = request.value(forHTTPHeaderField: "Range")
        let newRange: String
        if let originalRange,
           let shifted = LocalHLSProxyServer.shiftedRangeHeader(
                originalRange, by: offset
           ) {
            // Original was `bytes=start-end` or
            // `bytes=start-` — shift the start by
            // `bytesReceivedFromUpstream` so the next
            // attempt asks for the bytes we have not yet
            // received.
            newRange = shifted
        } else {
            // Original had no Range header (we asked for
            // the whole file).  Switch to a Range request
            // starting at `offset` so the CDN does not
            // resend the bytes the downstream already has.
            newRange = LocalHLSProxyServer.httpRangeHeader(
                offset: offset, end: nil
            )
        }
        newRequest.setValue(newRange, forHTTPHeaderField: "Range")
        return newRequest
    }

    /// True for transport-level errors that are safe to
    /// retry: the network connection died mid-flight, the
    /// request timed out, or we could not connect.  These
    /// are the exact failure modes we saw in the build-82
    /// diagnostic report — B站's CDN reset our socket
    /// mid-stream (`URLError.networkConnectionLost`, code
    /// -1005) and we previously gave up after one try.
    private func isRetryable(_ nsError: NSError) -> Bool {
        guard nsError.domain == NSURLErrorDomain else { return false }
        switch nsError.code {
        case NSURLErrorTimedOut,                 // -1001
             NSURLErrorCannotConnectToHost,      // -1004
             NSURLErrorNetworkConnectionLost,    // -1005
             NSURLErrorDNSLookupFailed,          // -1006
             NSURLErrorNotConnectedToInternet:   // -1009
            return true
        default:
            return false
        }
    }

    /// Schedule the next upstream attempt on the delegate
    /// queue (serial, `maxConcurrentOperationCount = 1`)
    /// so we never race with `didCompleteWithError` from
    /// the previous attempt.  Emits a single retry log line
    /// so the diagnostic stream shows the recovery.
    private func scheduleRetry(reason: String, attempt: Int) {
        let backoff = Self.baseBackoffSeconds * pow(3.0, Double(attempt - 1))
        diagLog(.network,
                "LocalHLSProxyServer upstream retry",
                details: [
                    "mode": mode,
                    "attempt": attempt,
                    "maxRetries": Self.maxRetries,
                    "bytesReceived": bytesReceivedFromUpstream,
                    "backoffMs": Int(backoff * 1000),
                    "reason": reason
                ])
        // PR-C Task 3: `DispatchQueue.global().asyncAfter` is
        // replaced with a detached Task that sleeps for the
        // backoff and then re-enters the same code path. The
        // Task is fire-and-forget — it is intentionally not
        // cancellable because the previous DispatchQueue site
        // wasn't either (URLSession's delegate queue handles
        // the rest of the lifecycle). `startUpstreamTask` is
        // synchronous and dispatches onto the URLSession
        // delegate queue internally, so the Task body can
        // return immediately after it.
        //
        // The new task's `URLSessionDataDelegate` callbacks
        // still arrive on the serial `delegateQueue`, so the
        // retry does not race with any in-flight callbacks
        // from the previous attempt — by the time we get
        // here `didCompleteWithError` has already returned
        // and URLSession will not send more events for the
        // old task.
        let backoffNanos = UInt64(backoff * 1_000_000_000)
        Task.detached(priority: .userInitiated) { [weak self] in
            try? await Task.sleep(nanoseconds: backoffNanos)
            self?.startUpstreamTask(attempt: attempt)
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        // Race guard.  The connection's queue and the
        // URLSession delegate queue are different; a
        // `connection.send` failure on the listener queue
        // can flip `downstreamBroken` *after* a response
        // callback has already been enqueued on the
        // delegate queue.  Without this guard we would
        // synthesise a 200/206 header and write it to a
        // dead socket — another `NWError 57` log line for
        // no benefit.  The cancel disposition propagates
        // straight to `didCompleteWithError(NSURLErrorCancelled)`
        // which the existing branch already handles.
        if downstreamBroken {
            completionHandler(.cancel)
            return
        }
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finishWithError(reason: "bad upstream response")
            return
        }
        // Short-circuit upstream 5xx before we write any
        // header to the downstream — sending even a partial
        // 5xx body through the loopback would leave
        // AVPlayer's parser in a state where it cannot
        // accept the retried response on the next attempt.
        if (500...599).contains(http.statusCode) {
            cancelledForRetry = true
            completionHandler(.cancel)
            // CDN failover: a 5xx from the upstream is the
            // signal the host is degraded.  Move the cursor
            // forward so the next playlist emission uses the
            // backup.  The task captures `upstream` at
            // construction time — that's the URL we just got
            // the 5xx from, which is enough for the helper to
            // resolve the parent track and bump the cursor.
            // No-op if we're already at the end of the backup
            // list for this track.  `server` was already
            // unwrapped by the `guard let server, let http = ...`
            // at the top of this branch, so we call through
            // directly — re-binding with `if let` would shadow
            // the local with the same name and produce a
            // "must have Optional type" error.
            server.markUpstreamFailed(url: upstream)
            if upstreamAttempt < Self.maxRetries {
                // Still have retries left — wait for a
                // fresh upstream attempt with the Range
                // shifted by `bytesReceivedFromUpstream`,
                // then write its response to the same
                // downstream socket that is still waiting.
                scheduleRetry(
                    reason: "5xx: \(http.statusCode)",
                    attempt: upstreamAttempt + 1
                )
                return
            }
            // Retries exhausted — send a clean 502 to
            // AVPlayer so its parser sees a valid HTTP
            // response (not a 206 wrapping a 5xx body),
            // then tear down.
            server.sendHeader(
                connection: connection,
                sendGroup: sendGroup,
                status: 502,
                contentType: "application/json",
                contentLength: nil,
                connID: connID
            )
            didSendHeader = true
            diagLog(.network,
                    "Upstream segment error",
                    details: [
                        "mode": mode,
                        "attempts": Self.maxRetries + 1,
                        "error": "5xx: \(http.statusCode)"
                    ])
            finishWhenSendsDrain()
            return
        }
        didSendHeader = true
        var extraHeaders: [String: String] = ["Accept-Ranges": "bytes"]
        let upstreamContentRange = http.value(forHTTPHeaderField: "Content-Range")

        // Decide downstream status.  AVPlayer's strict rule:
        //   - if the client sent `Range: bytes=…`, the response
        //     MUST be `206 Partial Content` with a matching
        //     `Content-Range` header.  Anything else and the
        //     stream is abandoned.
        //   - if the client did not send Range, the response
        //     MUST be `200 OK` with the full body.  Returning
        //     206 here is also legal but `Content-Range` must
        //     match, so we play it safe with 200.
        // `/init` and `/media` are *logical* sub-resources of
        // the upstream m4s file, but from the client's
        // perspective they look like whole documents — so when
        // the client does NOT send Range we answer `200`, and
        // when it DOES send Range we answer `206` with a
        // `Content-Range` that has been shifted down to the
        // sub-resource's byte coordinates.
        //
        // NOTE: `/init` and `/media` are NOT symmetric:
        //   * `/init` is a *logical* sub-resource — AVPlayer
        //     never asks for a Range on it, and the body is
        //     the init bytes in their entirety. 200 OK +
        //     Content-Length is correct.
        //   * `/media` is a *partial* sub-resource — its
        //     body is a slice of the upstream file (init
        //     bytes are served separately by `/init`).
        //     Even when the single-segment playlist
        //     fallback is in effect and AVPlayer does not
        //     send a Range, the HTTP contract is still
        //     206 + Content-Range, because the resource is
        //     a slice of a larger file.  Returning 200
        //     here makes AVPlayer RST the socket
        //     (NWError 54) and/or blacklist the track.
        let isInitSubResource = (mode == "init")
        let status: Int
        if clientSentRange {
            // Client asked for a byte range — MUST be 206.
            status = 206
            if let shift = contentRangeShift,
               let upstreamContentRange,
               let shifted = server.shiftedContentRange(
                    upstreamContentRange,
                    by: shift
               ) {
                // `/init` or `/media` with a known shift:
                // convert the upstream's absolute Content-Range
                // down to the sub-resource's relative bytes so
                // AVPlayer can apply it to the `/init` or
                // `/media` URL it asked for.
                extraHeaders["Content-Range"] = shifted
            } else if let upstreamContentRange {
                // `/seg` passthrough or no shift recorded:
                // forward the upstream's Content-Range
                // verbatim — it is already in the client's
                // coordinates.
                extraHeaders["Content-Range"] = upstreamContentRange
            }
        } else if isInitSubResource {
            // `/init` (no client Range): serve the upstream's
            // 206 body as a flat `200 OK` resource.  Drop
            // `Content-Range` so AVPlayer treats the body as
            // a complete sub-resource.
            status = 200
        } else {
            // `/media` (no client Range) and `/seg` (no client
            // Range): pass the upstream status through.  B 站
            // answered 206 because we asked for a Range; we
            // shift the absolute Content-Range down to a
            // *relative* range the client can use against the
            // logical sub-resource.
            status = http.statusCode
            if let upstreamContentRange,
               let shift = contentRangeShift,
               let shifted = server.shiftedContentRange(
                    upstreamContentRange,
                    by: shift
               ) {
                extraHeaders["Content-Range"] = shifted
            } else if let upstreamContentRange {
                // **Build 250 fix**: when no shift is
                // recorded (e.g. a track landed in the
                // un-shifted codepath, or `mode` is not
                // "passthrough"), forward the upstream's
                // Content-Range verbatim instead of
                // dropping it.  Without this fallback, a
                // 206 with no Content-Range reaches
                // AVPlayer and triggers CoreMediaError
                // -12666 ("have 206 with no
                // Content-Range, and no end length"),
                // which the recovery loop then has to
                // paper over.  Forwarding the absolute
                // range is at worst a length mismatch
                // AVPlayer can tolerate, at best an exact
                // match.
                extraHeaders["Content-Range"] = upstreamContentRange
            }
        }
        let contentLength = http.expectedContentLength >= 0
            ? http.expectedContentLength
            : nil
        // Trap-2 sanity check: cross-check the upstream's
        // `Content-Length` against the bytes implied by the
        // `Content-Range` header.  For a 206 response the
        // body length must equal `end - start + 1`.  If
        // they don't match, the upstream is either broken
        // or we miscomputed the Range shift — both would
        // make AVPlayer kill the socket.
        let (rangeStart, rangeEnd, rangeTotal) = LocalHLSProxyServer
            .parseContentRangeHeader(upstreamContentRange ?? "")
        let computed: Int64 = (rangeStart >= 0 && rangeEnd >= rangeStart)
            ? (rangeEnd - rangeStart + 1)
            : -1

        // **PR-A Group 3 (item 8, D6)**: when we requested a
        // Range from upstream and got a 206 response, the
        // upstream's Content-Range MUST match what we asked
        // for.  If it doesn't (buggy upstream, CDN race, etc.)
        // returning the wrong slice to AVPlayer produces
        // decode errors and silent stalls.  Reject with 502 —
        // do NOT auto-retry, since retrying the same request
        // against the same upstream will hit the same bug
        // (per D6: avoid amplifying buggy upstreams).
        //
        // **Build 250 fix**: on a retry, the upstream request
        // is shifted by `bytesReceivedFromUpstream` so the
        // CDN hands us the bytes the previous attempt already
        // lost.  The 206 Content-Range we expect back is
        // therefore the ORIGINAL request's start + that
        // offset, not the original start.  Without this
        // shift the retry path produced a spurious
        // `content_range_mismatch` 502 even though the
        // upstream was correctly answering the shifted
        // request (diagnostic build 250: expected
        // 24153788-25806548, actual 25266620-26919380 — a
        // delta of 1112832 that exactly matched the logged
        // `bytesReceived`).
        if let reqStart = self.rangeStart, let reqEnd = self.rangeEnd,
           http.statusCode == 206,
           rangeStart >= 0, rangeEnd >= rangeStart {
            // Both ends shift by the retry offset: see
            // `shiftedRequest(startingAt:)` which builds the
            // new Range header from the original range and the
            // `bytesReceivedFromUpstream` delta.
            let shift = bytesReceivedFromUpstream
            let expectedStart = reqStart + shift
            let expectedEnd = reqEnd + shift
            if rangeStart != expectedStart || rangeEnd != expectedEnd {
                diagLog(.playback, "content_range_mismatch", details: [
                    "conn": connID,
                    "mode": mode,
                    "path": upstream.path,
                    "expected": "\(expectedStart)-\(expectedEnd)",
                    "actual": "\(rangeStart)-\(rangeEnd)",
                    "total": rangeTotal,
                    "retryOffset": bytesReceivedFromUpstream
                ])
                // **PR-B D2**: mirror the 5xx exhaustion path
                // above.  Without `didSendHeader = true` AND
                // `finishWhenSendsDrain()` here, a late
                // `didReceive data` callback (URLSession's
                // `.cancel` is asynchronous) could slip past
                // the `!didSendHeader` guard in `didReceive
                // data` and synthesise a 200 header for a
                // socket we have already decided to fail.
                cancelledForRangeMismatch = true   // **D3**: guards late data callbacks
                server.sendHeader(
                    connection: connection,
                    sendGroup: sendGroup,
                    status: 502,
                    contentType: "application/json",
                    contentLength: nil,
                    connID: connID
                )
                didSendHeader = true
                finishWhenSendsDrain()
                completionHandler(.cancel)
                return
            }
        }
        let upstreamCL: Int64 = http.expectedContentLength >= 0
            ? http.expectedContentLength
            : -1
        if LocalHLSProxyServer.requestMetadataLogEnabled {
            diagLog(.network,
                    "LocalHLSProxyServer Content-Length sanity",
                    details: [
                        "conn": connID,
                        "mode": mode,
                        "upstreamStatus": http.statusCode,
                        "expectedContentLength": upstreamCL,
                        "parsedContentRange": upstreamContentRange ?? "",
                        "parsedRangeStart": rangeStart,
                        "parsedRangeEnd": rangeEnd,
                        "parsedRangeTotal": rangeTotal,
                        "computedEndMinusStartPlus1": computed,
                        "matches": upstreamCL < 0 || computed < 0
                            || upstreamCL == computed
                    ])
        }
        diagLog(.playback,
                "LocalHLSProxyServer upstream response",
                details: [
                    "conn": connID,
                    "mode": mode,
                    "status": http.statusCode,
                    "downstreamStatus": status,
                    "contentLength": contentLength ?? -1,
                    "contentRange": upstreamContentRange ?? "",
                    "mimeType": http.mimeType ?? "",
                    "host": upstream.host ?? ""
                ])
        server.sendHeader(
            connection: connection,
            sendGroup: sendGroup,
            status: status,
            contentType: http.mimeType
                ?? server.mimeType(for: upstream.pathExtension),
            contentLength: contentLength,
            extraHeaders: extraHeaders,
            connID: connID
        )
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        // **PR-B D3**: if the Content-Range mismatch path
        // (the upstream returned the wrong bytes for our
        // Range request) has already fired, late
        // `didReceive data` callbacks from URLSession's
        // internal queue can land here AFTER we've sent
        // the 502 to AVPlayer.  Drop them silently — the
        // connection is on its way out via
        // `finishWhenSendsDrain`.
        if cancelledForRangeMismatch { return }
        // Track every byte that arrives from upstream, even
        // when the downstream is broken, so the retry path
        // can shift the Range header by however much we did
        // manage to pull before the connection died.  See
        // `shiftedRequest(startingAt:)`.
        bytesReceivedFromUpstream += Int64(data.count)
        // Once the loopback client (AVPlayer) goes away
        // (e.g. `VideoDetailView.onDisappear`), the
        // downstream socket is dead.  Stop feeding the
        // upstream pipe immediately — every extra `send`
        // is an `NWError 57 — Socket is not connected` log
        // line, and a 71 MB video with a few hundred
        // segments will spam the diagnostic log for several
        // seconds otherwise.
        if downstreamBroken { return }
        // First chunk arrives without a prior `didReceive
        // response` (which only fires for 2xx/206).  In that
        // case the upstream returned a 200 without explicit
        // length headers (B站 CDN sometimes does that for
        // /init), so we have to synthesise the header here.
        if !didSendHeader {
            // Defensive: the body-byte path already
            // bailed on `downstreamBroken` above, but if
            // the flag was flipped *after* we passed that
            // check (queue race), don't synthesise a 200
            // header for a socket that just died.
            if downstreamBroken { return }
            server.sendHeader(
                connection: connection,
                sendGroup: sendGroup,
                status: 200,
                contentType: server.mimeType(
                    for: upstream.pathExtension
                ) ?? "application/octet-stream",
                contentLength: nil,
                connID: connID
            )
            didSendHeader = true
            // PR-B B4: log the first-chunk synthesis exactly
            // once per task.  Useful diagnostic for spotting
            // "upstream returned 200 with no headers (B站 CDN
            // behaviour for /init)" — a slow-start signal
            // that operators can correlate with a slow-start
            // user-visible stall.
            if !firstChunkLogged {
                firstChunkLogged = true
                diagLog(.proxy,
                        "didReceive data first-chunk synthesised header",
                        details: [
                            "conn": connID,
                            "id": id.uuidString,
                            "bytes": data.count,
                            "path": upstream.path
                        ])
            }
        }
        if LocalHLSProxyServer.wireDumpEnabled {
            downstreamChunksSent += 1
            downstreamBytesSent += Int64(data.count)
            if downstreamChunksSent == 1 {
                diagLog(.network,
                        "LocalHLSProxyServer wire bytes",
                        details: [
                            "conn": connID,
                            "label": "DOWNSTREAM BODY FIRST CHUNK",
                            "chunkBytes": data.count,
                            "bytes": LocalHLSProxyServer.dumpWireBytes(
                                data,
                                label: "DOWNSTREAM BODY FIRST CHUNK"
                            )
                        ])
            }
        }
        server.addStreamedBytes(data.count)
        sendGroup.enter()
        connection.send(
            content: data,
            completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                let errorDescription = error?.localizedDescription
                self.delegateQueue.addOperation { [weak self] in
                    guard let self else { return }
                    if let errorDescription {
                    // Mark the downstream as dead but do NOT
                    // cancel the connection here — doing so
                    // kills in-flight send completions before
                    // they can `leave()` the sendGroup, which
                    // leaves `finishWhenSendsDrain()` waiting
                    // forever for a drain that never completes
                    // and causes AVPlayer to see a truncated
                    // body (fewer bytes than Content-Length)
                    // leading to -19602 decode failures.
                    // Instead, mark broken + cancel the
                    // upstream task; `didCompleteWithError`
                    // with `NSURLErrorCancelled` will then
                    // arrive on the delegate queue, the
                    // existing branch handles it via
                    // `finishWhenSendsDrain()` which cancels
                    // the connection once all queued send
                    // completions have left the sendGroup.
                        let wasAlreadyBroken = self.downstreamBroken
                        self.markDownstreamBroken(
                            reason: "send error: \(errorDescription)"
                        )
                        guard !wasAlreadyBroken else {
                            self.sendGroup.leave()
                            return
                        }
                        diagLog(.network,
                                "LocalHLSProxyServer downstream send error",
                                details: [
                                    "conn": self.connID,
                                    "mode": self.mode,
                                    "error": errorDescription
                                ])
                    }
                    self.sendGroup.leave()
                }
            }
        )
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            let nsError = error as NSError
            // 1. Cancellation we triggered from the 5xx
            //    short-circuit in `didReceive response`
            //    means "give up on this response and retry".
            //    The flag distinguishes that from a real
            //    cancellation (downstream dead, etc.).
            if cancelledForRetry {
                // scheduleRetry was already called from
                // didReceive response — nothing to do here.
                return
            }
            // 2. Cancellation triggered by `downstreamBroken`
            //    is expected when AVPlayer goes away
            //    mid-fetch; it is *not* a real upstream
            //    failure and must not be retried (the
            //    downstream is gone anyway).
            if nsError.code == NSURLErrorCancelled {
                finishWhenSendsDrain()
                return
            }
            // 3. Retryable transport-level failure with the
            //    downstream still alive.  These are the
            //    hard hangs the user-visible "Media file
            //    not received in 11s" error traces back to
            //    — the upstream edge has accepted the TCP
            //    connection but never started returning
            //    bytes, and AVPlayer's own 11s abort fires
            //    before our per-host retry budget (3 × 10s
            //    + backoff = ~31s) can finish.
            //
            //    Strategy: do **not** retry the same host
            //    three times — that's what got us here.
            //    Mark this host as failed so the server's
            //    `failoverIndex` cursor advances past it,
            //    re-resolve `self.upstream` to whatever the
            //    cursor now points at, and schedule a
            //    single retry on the next host.  If that
            //    retry also fails, the next call into
            //    `markUpstreamFailed` advances the cursor
            //    again, so by attempt 3 we've usually
            //    walked the whole `backupURLs` list.
            if isRetryable(nsError),
               upstreamAttempt < Self.maxRetries,
               !downstreamBroken {
                server.markUpstreamFailed(url: upstream)
                if let nextURL = server.reboundUpstream(
                    after: upstream
                ), nextURL != upstream {
                    upstream = nextURL
                }
                scheduleRetry(
                    reason: nsError.localizedDescription,
                    attempt: upstreamAttempt + 1
                )
                return
            }
            if isRetryable(nsError), !downstreamBroken {
                server.markUpstreamFailed(url: upstream)
            }
            // 4. Non-retryable error or retries exhausted —
            //    surface it as the final upstream failure.
            diagLog(.network,
                    "Upstream segment error",
                    details: [
                        "conn": connID,
                        "mode": mode,
                        "attempts": upstreamAttempt + 1,
                        "error": nsError.localizedDescription
                    ])
            if !didSendHeader {
                server.sendHeader(
                    connection: connection,
                    sendGroup: sendGroup,
                    status: 502,
                    contentType: "application/json",
                    contentLength: nil,
                    connID: connID
                )
            }
        }
        logBodyTotalsIfNeeded()
        finishWhenSendsDrain()
    }

    /// Emit the diagnostic body-totals log line.  Only
    /// fires when `LocalHLSProxyServer.wireDumpEnabled`
    /// is on; gives us a single line per stream that
    /// cross-checks the bytes pushed to `connection.send`
    /// against the `Content-Length` promised in the
    /// header (the trap-2 mismatch check).
    private func logBodyTotalsIfNeeded() {
        guard LocalHLSProxyServer.wireDumpEnabled else { return }
        diagLog(.network,
                "LocalHLSProxyServer downstream body totals",
                details: [
                    "conn": connID,
                    "mode": mode,
                    "upstreamBytes": bytesReceivedFromUpstream,
                    "downstreamChunks": downstreamChunksSent,
                    "downstreamBytes": downstreamBytesSent,
                    "matches": bytesReceivedFromUpstream == downstreamBytesSent
                ])
    }

    private func finishWithError(reason: String) {
        diagLog(.network,
                "LocalHLSProxyServer stream failed",
                details: [
                    "conn": connID,
                    "mode": mode,
                    "reason": reason
                ])
        if !didSendHeader {
            server.sendHeader(
                connection: connection,
                sendGroup: sendGroup,
                status: 502,
                contentType: "application/json",
                contentLength: nil,
                connID: connID
            )
        }
        logBodyTotalsIfNeeded()
        finishWhenSendsDrain()
    }

    private func finishWhenSendsDrain() {
        // PR-B B5: log every entry.  Without this, an
        // operator reading the dump sees only the eventual
        // connection.state=.cancelled transition and can't
        // tell whether the drain finished cleanly (one
        // pending send completed) or was a no-op (no sends
        // in flight when the drain was scheduled).
        diagLog(.proxy,
                "finishWhenSendsDrain",
                details: ["id": id.uuidString])
        guard !didFinish else { return }
        didFinish = true
        unregisterRange()
        sendGroup.notify(queue: .global(qos: .utility)) { [weak self] in
            guard let self else { return }
            self.connection.cancel()
            self.session?.finishTasksAndInvalidate()
            self.server.finishStream(id: self.id)
        }
    }
}

// MARK: - HTTP request parser

/// Minimal HTTP/1.1 request header parser.  We only need the
/// method, path, and headers — there is never a request body
/// for the endpoints we expose.
struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]

    static func parse(data: Data) -> HTTPRequest? {
        guard let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        let lines = str.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ").map(String.init)
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            if let colon = line.firstIndex(of: ":") {
                let k = String(line[..<colon]).lowercased()
                let v = String(line[line.index(after: colon)...])
                    .trimmingCharacters(in: .whitespaces)
                headers[k] = v
            }
        }
        return HTTPRequest(
            method: parts[0],
            path: parts[1],
            headers: headers
        )
    }
}
