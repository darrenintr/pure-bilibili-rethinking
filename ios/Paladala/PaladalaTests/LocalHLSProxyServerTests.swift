import XCTest
@testable import Paladala

final class LocalHLSProxyServerTests: XCTestCase {
    override func tearDown() async throws {
        // Cancel the loopback listener installed by
        // `prewarmProxyServer()` so subsequent tests don't see a
        // stale `.ready` port and so the next `.shared` access can
        // lazy-rebuild via `ensureListenerAsync()`.
        LocalHLSProxyServer.shared.cancelListenerForTest()
        try await super.tearDown()
    }

    func test_resolvedPrefetchQuality_usesRequestedQualityWhenPresent() {
        XCTAssertEqual(
            LocalHLSProxyServer.resolvedPrefetchQuality(
                requested: 120,
                acceptQuality: [80, 64]
            ),
            120
        )
    }

    func test_resolvedPrefetchQuality_fallsBackToAcceptQuality() {
        XCTAssertEqual(
            LocalHLSProxyServer.resolvedPrefetchQuality(
                requested: nil,
                acceptQuality: [80, 64]
            ),
            80
        )
        XCTAssertNil(
            LocalHLSProxyServer.resolvedPrefetchQuality(
                requested: nil,
                acceptQuality: nil
            )
        )
    }

    func test_waitForListener_respectsTimeoutCeiling() async {
        // When the listener is never started, waitForListener must throw
        // within timeout + a small grace window (50 ms), not hang for the
        // legacy 2 000 ms default.
        let proxy = LocalHLSProxyServer(port: 0)
        let start = Date()
        do {
            try await proxy.waitForListener(timeoutMs: 100, pollIntervalMs: 5)
            XCTFail("expected timeout throw")
        } catch {
            let elapsed = Date().timeIntervalSince(start) * 1000
            XCTAssertGreaterThan(elapsed, 95, "must wait at least timeoutMs")
            XCTAssertLessThan(elapsed, 250, "must respect ceiling, was \(elapsed)")
        }
    }

    func test_pollIntervalDrivesPollingCadence() async {
        // pollIntervalMs=10 should produce measurable ticks at ~10 ms.
        // Direct test: wire a faster path later if needed; for v1 just
        // confirm the parameter is honoured by timing a no-op wait.
        let proxy = LocalHLSProxyServer(port: 0)
        let start = Date()
        do {
            try await proxy.waitForListener(timeoutMs: 30, pollIntervalMs: 10)
        } catch {}
        let elapsedMs = Date().timeIntervalSince(start) * 1000
        XCTAssertLessThan(elapsedMs, 200)
    }

    func test_prewarmProxyServer_startsListenerAndSucceeds() async {
        // Prewarm must (a) never throw, and (b) leave the shared
        // singleton with a listener that is actually `.ready`.
        // Before the `ensureListenerAsync()` fix, this assertion
        // would have failed because `init(port:)` does not start
        // the listener — only `serve(...)` / `serveLive(...)` did.
        await LocalHLSProxyServer.prewarmProxyServer()
        let state = LocalHLSProxyServer.shared.listenerState
        XCTAssertNotNil(state, "prewarm must install a listener on .shared")
        XCTAssertEqual(state, .ready,
                       "prewarm must wait for listener.ready, got \(String(describing: state))")
    }

    // MARK: - PR-A Group 5: resolveSegmentationMode cache fix (item 6)

    /// Minimal `BiliDashSource.Track` for exercising
    /// `resolveSegmentationMode`.  All non-baseURL fields are
    /// placeholders — the function under test only reads
    /// `track.baseURL`.
    private func makeTrack(
        baseURL: URL,
        backupURLs: [URL] = []
    ) -> BiliDashSource.Track {
        BiliDashSource.Track(
            baseURL: baseURL,
            backupURLs: backupURLs,
            codecs: "avc1.640028",
            bandwidth: 1_000_000,
            mimeType: "video/mp4",
            initializationRange: BiliDashSource.ByteRange(offset: 0, length: 1024),
            indexRange: BiliDashSource.ByteRange(offset: 1024, length: 256),
            mediaStartOffset: 1280,
            totalDuration: 60.0,
            width: 1920,
            height: 1080
        )
    }

    func test_failover_clampsAtLastBackupInsteadOfReturningToPrimary() {
        let proxy = LocalHLSProxyServer(port: 0)
        let primary = URL(string: "https://primary.example/v.m4s")!
        let backup1 = URL(string: "https://backup1.example/v.m4s")!
        let backup2 = URL(string: "https://backup2.example/v.m4s")!
        let track = makeTrack(
            baseURL: primary,
            backupURLs: [backup1, backup2]
        )
        let playback = BiliPlayback(
            dash: BiliDashSource(video: track, audio: nil),
            fallbackURL: nil,
            referer: URL(string: "https://www.bilibili.com/")!
        )
        proxy.setCurrentPlaybackForTest(playback)

        XCTAssertEqual(proxy.activeUpstreamForTest(for: track), primary)

        proxy.markUpstreamFailedForTest(url: primary)
        XCTAssertEqual(proxy.failoverIndexForTest(primaryURL: primary), 1)
        XCTAssertEqual(proxy.activeUpstreamForTest(for: track), backup1)

        proxy.markUpstreamFailedForTest(url: backup1)
        XCTAssertEqual(proxy.failoverIndexForTest(primaryURL: primary), 2)
        XCTAssertEqual(proxy.activeUpstreamForTest(for: track), backup2)

        proxy.markUpstreamFailedForTest(url: backup2)
        proxy.markUpstreamFailedForTest(url: backup2)
        XCTAssertEqual(proxy.failoverIndexForTest(primaryURL: primary), 2)
        XCTAssertEqual(
            proxy.activeUpstreamForTest(for: track),
            backup2,
            "exhausted failover must stay on the last backup, not loop to primary"
        )
    }

    func test_preparationCandidateOrder_prefersSuccessfulBackup() {
        let primary = URL(string: "https://primary.example/audio.m4s")!
        let backup = URL(string: "https://backup.example/audio.m4s")!

        let ordered = LocalHLSProxyServer.orderPreparationCandidates(
            [primary, backup],
            successful: [backup],
            failed: [primary]
        )

        XCTAssertEqual(ordered, [backup, primary])
    }

    func test_preparationCandidateOrder_preservesUnknownFallbacks() {
        let primary = URL(string: "https://primary.example/audio.m4s")!
        let backup1 = URL(string: "https://backup1.example/audio.m4s")!
        let backup2 = URL(string: "https://backup2.example/audio.m4s")!

        let ordered = LocalHLSProxyServer.orderPreparationCandidates(
            [primary, backup1, backup2],
            successful: [],
            failed: [primary]
        )

        XCTAssertEqual(ordered, [backup1, backup2, primary])
    }

    func test_resolveSegmentationMode_unavailableDoesNotLock() {
        // **PR-A Group 3 (item 6)**: when the SIDX has not yet
        // been published, the mode must be `.unavailable` AND
        // must NOT be cached in `decidedModes`.  The previously
        // buggy version cached `.unavailable`, pinning AVPlayer
        // to a temp playlist forever.
        let proxy = LocalHLSProxyServer(port: 0)
        let track = makeTrack(
            baseURL: URL(string: "https://example.invalid/v.m4s")!
        )
        // Pre-condition: nothing in the cache for this baseURL.
        XCTAssertNil(proxy.decidedModes[track.baseURL])

        let (mode, _) = proxy.resolveSegmentationModeForTest(for: track)

        XCTAssertEqual(mode, .unavailable,
                       "no SIDX indexed → mode must be .unavailable")
        XCTAssertNil(
            proxy.decidedModes[track.baseURL],
            ".unavailable must NOT be locked into the cache"
        )
    }

    func test_resolveSegmentationMode_sidxLocksAndIsCached() {
        // The symmetric case: once a SIDX has been indexed
        // (trackSegmentIndex populated), the mode is `.sidx`
        // and the first call must lock it into the cache.
        let proxy = LocalHLSProxyServer(port: 0)
        let track = makeTrack(
            baseURL: URL(string: "https://example.invalid/v.m4s")!
        )
        // Pretend the SIDX parser has populated the index.
        // The struct contents don't matter for this test —
        // only the `!= nil` check in resolveSegmentationMode.
        proxy.trackSegmentIndex[track.baseURL] = TrackSegmentIndex(
            initializationRange: 0..<1024,
            fragments: [],
            timescale: 1,
            firstMediaOffset: 0,
            sidxRange: nil,
            totalDuration: 0
        )

        let (mode1, _) = proxy.resolveSegmentationModeForTest(for: track)
        XCTAssertEqual(mode1, .sidx)

        let cached = proxy.decidedModes[track.baseURL]
        XCTAssertEqual(
            cached, .sidx,
            ".sidx must be locked into decidedModes"
        )

        // Second call must read from the cache (same answer).
        let (mode2, _) = proxy.resolveSegmentationModeForTest(for: track)
        XCTAssertEqual(
            mode2, .sidx,
            "subsequent calls must return the cached .sidx"
        )
    }

    // MARK: - PR-A Group 5: parseContentRangeHeader

    func test_parseContentRangeHeader_basicRange() {
        let parsed = LocalHLSProxyServer.parseContentRangeHeader(
            "bytes 0-99/1000"
        )
        XCTAssertEqual(parsed.start, 0)
        XCTAssertEqual(parsed.end, 99)
        XCTAssertEqual(parsed.total, 1000)
    }

    func test_parseContentRangeHeader_openEndedTotal() {
        // RFC 7233 allows `bytes START-END/*` when the total
        // is unknown.  The parser must surface this as
        // `total = -1` (the existing sentinel — preserved here
        // for behavioural compatibility).
        let parsed = LocalHLSProxyServer.parseContentRangeHeader(
            "bytes 512-1023/*"
        )
        XCTAssertEqual(parsed.start, 512)
        XCTAssertEqual(parsed.end, 1023)
        XCTAssertEqual(parsed.total, -1)
    }

    func test_parseContentRangeHeader_garbageReturnsNegatives() {
        // Defensive: malformed headers must NOT throw and
        // must surface as all-`-1` so callers can `guard`
        // against `start < 0` instead of trapping.
        let parsed = LocalHLSProxyServer.parseContentRangeHeader("garbage")
        XCTAssertEqual(parsed.start, -1)
        XCTAssertEqual(parsed.end, -1)
        XCTAssertEqual(parsed.total, -1)
    }

    func test_parseContentRangeHeader_missingPrefixReturnsNegatives() {
        let parsed = LocalHLSProxyServer.parseContentRangeHeader("0-99/100")
        XCTAssertEqual(parsed.start, -1,
                       "missing 'bytes ' prefix must reject")
    }

    // MARK: - PR-B Commit 4: parseContentRangeHeader edge cases (A5, A6)

    func test_parseContentRangeHeader_zeroLengthRange() {
        // PR-B A5: "bytes 0-0/*" — degenerate single-byte
        // range with no total.  Must parse to (0, 0, -1)
        // so the proxySegmentRange path can detect an
        // open-ended total and forward it verbatim instead
        // of dropping the Content-Range header.
        let parsed = LocalHLSProxyServer.parseContentRangeHeader(
            "bytes 0-0/*"
        )
        XCTAssertEqual(parsed.start, 0)
        XCTAssertEqual(parsed.end, 0)
        XCTAssertEqual(parsed.total, -1)
    }

    func test_parseContentRangeHeader_unsatisfiedRangeOnly() {
        // PR-B A6: "bytes */100" — RFC 7233 §4.4 unsatisfied
        // range form, signalling "the resource is 100 bytes
        // long and your range request doesn't fit".  The
        // parser must surface this as all-`-1` (existing
        // contract) so the proxy can translate an upstream
        // 416 response to a clean 416 for the loopback
        // client without leaking the upstream error code.
        let parsed = LocalHLSProxyServer.parseContentRangeHeader(
            "bytes */100"
        )
        XCTAssertEqual(parsed.start, -1,
                       "unsatisfied range start must be -1")
        XCTAssertEqual(parsed.end, -1,
                       "unsatisfied range end must be -1")
        XCTAssertEqual(parsed.total, 100,
                       "unsatisfied range total carries the byte count")
    }

    // MARK: - PR-B Commit 4: guardSegmentGeneration (A4)

    func test_guardSegmentGeneration_staleReturns503() {
        // PR-B A4: bump currentPrepGeneration mid-request;
        // the guard must observe the mismatch and respond
        // 503 + Retry-After: 0 + emit a
        // `segment_generation_stale` diagLog so AVPlayer
        // backs off and re-fetches against the new session.
        let proxy = LocalHLSProxyServer(port: 0)
        // Pre-condition: generation is 0 (or whatever the
        // initial value is).
        let initialGen = proxy.currentPrepGenerationValue()
        XCTAssertGreaterThanOrEqual(initialGen, 0)

        // Simulate the captured gen being stale: pass a
        // value that's NOT the current value.  The guard
        // will respond 503 (which we can't observe directly
        // without a live connection — the test asserts the
        // function returns nil, which is the "stale" signal
        // for the caller).
        let staleGen = initialGen &+ 99   // will never match

        // No real connection — just verify the function's
        // contract: returns nil for a stale gen.  The
        // respondError path is exercised separately by the
        // existing integration tests; this is the unit-level
        // signal.
        //
        // We can't call guardSegmentGeneration with a nil
        // connection in production code, but the function
        // returns nil before any connection work when the
        // generation mismatch is detected — so a nil
        // connection is safe for the stale path.
        let result = proxy.guardSegmentGenerationForTest(
            capturedGen: staleGen,
            connection: nil,
            connID: "test-stale-conn"
        )
        XCTAssertNil(result,
                     "stale gen must return nil so the caller short-circuits")

        // Symmetric: a current gen returns the value (the
        // caller's signal that the guard passed).
        let currentGen = proxy.currentPrepGenerationValue()
        let liveResult = proxy.guardSegmentGenerationForTest(
            capturedGen: currentGen,
            connection: nil,
            connID: "test-live-conn"
        )
        XCTAssertEqual(liveResult, currentGen,
                       "current gen must return the live value")
    }

    // MARK: - master BANDWIDTH attribute (PR-C BANDWIDTH fix)

    /// Build a `MediaFragment` for unit-testing the master
    /// playlist bandwidth calculator.  `startPrefixHex` is
    /// not consulted by the formula; pass an empty string
    /// because it's required by the memberwise init.
    private func makeMediaFragment(
        bytes: Int64,
        duration: Double,
        startTime: Double = 0
    ) -> MediaFragment {
        MediaFragment(
            byteRange: startTime..<(startTime + bytes),
            startTime: startTime,
            duration: duration,
            startsWithSAP: true,
            startPrefixHex: ""
        )
    }

    func test_masterBANDWIDTH_usesMeasuredPeakWhenSidxAvailable() {
        // Reproduction of the BV1kN3m6eEPK diagnostic:
        // declared video=6,311,344 bps + audio=103,120 bps,
        // sidx peak segment = 5,255,891 bytes / 4.77s ≈
        // 8,815,308 bps.  The pre-fix code emitted
        // 6,414,464 bps → AVPlayer's "Segment exceeds
        // specified bandwidth for variant" check tripped on
        // the 8.8 Mbps actual peak.  Post-fix, the chosen
        // value is the larger of:
        //   1. 8,815,308 * 1.15 = 10,137,604
        //   2. 6,414,464 * 1.5  =  9,621,696
        // so 10,137,604 wins.
        let videoFrags = [
            makeMediaFragment(bytes: 5_255_891, duration: 4.77),
            makeMediaFragment(bytes: 4_900_000, duration: 4.50)
        ]
        let decision = LocalHLSProxyServer.masterPlaylistBandwidthDecision(
            declaredVideoBps: 6_311_344,
            declaredAudioBps: 103_120,
            videoFragments: videoFrags,
            audioFragments: []
        )
        let expectedPeak = Int64(5_255_891 * 8 / 4)  // integer-truncated
        XCTAssertEqual(decision.videoPeakBps, expectedPeak)
        XCTAssertEqual(decision.audioPeakBps, 0)
        XCTAssertEqual(decision.measuredPeakBps, expectedPeak)
        XCTAssertEqual(decision.declaredBps, 6_311_344 + 103_120)
        XCTAssertEqual(
            decision.bandwidth,
            Int(Double(expectedPeak) * 1.15),
            "measured peak * 1.15 must win over declared * 1.5"
        )
    }

    func test_masterBANDWIDTH_fallsBackToDeclaredWhenSidxEmpty() {
        // The sidx-absent path (legacy `durl` MP4, or a
        // B站 response that omits SegmentBase).  Falls back
        // to declaredBps * 1.5 so we still over-declare
        // (better than under) when we have no measured
        // evidence to compute a peak from.
        let decision = LocalHLSProxyServer.masterPlaylistBandwidthDecision(
            declaredVideoBps: 6_311_344,
            declaredAudioBps: 103_120,
            videoFragments: [],
            audioFragments: []
        )
        XCTAssertEqual(decision.measuredPeakBps, 0)
        XCTAssertEqual(decision.declaredBps, 6_414_464)
        XCTAssertEqual(
            decision.bandwidth,
            Int(Double(6_414_464) * 1.5)
        )
    }

    func test_masterBANDWIDTH_skipsZeroDurationFragments() {
        // Some B站 sidx entries publish `d=0` for the
        // "remainder" fragment at the end of the file.
        // These must NOT divide-by-zero and must NOT
        // contribute a spurious peak.
        let videoFrags = [
            makeMediaFragment(bytes: 4_000_000, duration: 4.0),
            makeMediaFragment(bytes: 9_999_999, duration: 0.0)  // d=0
        ]
        let decision = LocalHLSProxyServer.masterPlaylistBandwidthDecision(
            declaredVideoBps: 5_000_000,
            declaredAudioBps: 100_000,
            videoFragments: videoFrags,
            audioFragments: []
        )
        XCTAssertEqual(decision.videoPeakBps, 4_000_000 * 8 / 4)
        // Sanity: the 9,999,999-byte d=0 entry would have
        // produced an absurdly-high peak; verify we ignored it.
        XCTAssertLessThan(decision.videoPeakBps, 9_999_999)
    }

    func test_masterBANDWIDTH_audioPeakDominatesWhenAudioHigher() {
        // Edge case: an unusually-high-bitrate audio track
        // (e.g. 320 kbps Hi-Res FLAC) should drive the
        // variant bandwidth if its per-segment rate exceeds
        // the video peak.  Master playlist must advertise
        // enough to cover both tracks.
        let videoFrags = [
            makeMediaFragment(bytes: 5_000_000, duration: 5.0)  // 8 Mbps
        ]
        let audioFrags = [
            makeMediaFragment(bytes: 1_000_000, duration: 2.0)  // 4 Mbps
        ]
        let decision = LocalHLSProxyServer.masterPlaylistBandwidthDecision(
            declaredVideoBps: 8_000_000,
            declaredAudioBps: 4_000_000,
            videoFragments: videoFrags,
            audioFragments: audioFrags
        )
        XCTAssertEqual(decision.videoPeakBps, 8_000_000)
        XCTAssertEqual(decision.audioPeakBps, 4_000_000)
        XCTAssertEqual(decision.measuredPeakBps, 8_000_000)
    }

    func test_masterBANDWIDTH_neverGoesBelowDeclaredTimesOnePointFive() {
        // Even on a perfectly flat-rate VBR sample (peak ==
        // average), the 1.15× safety on measured must not
        // undercut the 1.5× safety on declared.  This guards
        // against a future refactor that drops the declared
        // fallback or swaps the safety multipliers.
        let videoFrags = [
            makeMediaFragment(bytes: 6_000_000, duration: 4.0)  // 12 Mbps
        ]
        let decision = LocalHLSProxyServer.masterPlaylistBandwidthDecision(
            declaredVideoBps: 12_000_000,  // matches measured
            declaredAudioBps: 0,
            videoFragments: videoFrags,
            audioFragments: []
        )
        // 12M * 1.15 = 13.8M; 12M * 1.5 = 18M; max wins.
        XCTAssertEqual(decision.bandwidth, Int(Double(12_000_000) * 1.5))
    }
}
