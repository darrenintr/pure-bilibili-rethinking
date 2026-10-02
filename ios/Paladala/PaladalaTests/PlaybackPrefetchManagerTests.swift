import XCTest
@testable import Paladala

/// Unit tests for the LRU-and-disk half of
/// `PlaybackPrefetchManager`.  We deliberately do *not*
/// exercise the network path (`prefetch(...)` kicks off a
/// real `URLSession.download`) — that is an integration-
/// test concern that requires either a local mock CDN
/// (covered by the existing proxy tests) or the iPad
/// itself.
///
/// These tests cover the *deterministic* pieces that are
/// easy to break with a refactor:
///   - `PrefetchEntry` Codable round-trip (so the on-disk
///     `meta.json` stays readable across versions).
///   - `cacheKey` format (so directory names are stable
///     and the on-disk cache survives a manager relaunch
///     with the same data).
///   - `fileURL` placement (so the proxy and the manager
///     agree on where to find `video.m4s`/`audio.m4s`).
final class PlaybackPrefetchManagerTests: XCTestCase {

    // MARK: - cacheKey

    func test_cacheKey_format() {
        // Stable format: `bvid_qn_cid`.  Raw form (no
        // hash) so a quick `ls <Caches>/Paladala/Prefetch/`
        // is debuggable on the iPad.
        XCTAssertEqual(
            PlaybackPrefetchManager.cacheKey(
                bvid: "BV1kN3m6eEPK", qn: 80, cid: 12345
            ),
            "BV1kN3m6eEPK_80_12345"
        )
    }

    func test_cacheKey_collapsesCidDifferencesAcrossQuality() {
        // Different qn → different key, even with the same
        // bvid+cid.  The cache must not let 1080p bytes
        // satisfy a 4K request.
        let lo = PlaybackPrefetchManager.cacheKey(
            bvid: "BV1UHNi6aEAe", qn: 80, cid: 999
        )
        let hi = PlaybackPrefetchManager.cacheKey(
            bvid: "BV1UHNi6aEAe", qn: 120, cid: 999
        )
        XCTAssertNotEqual(lo, hi)
    }

    func test_primaryUpstreamURL_prefersBaseURLOverBackup() {
        let primary = URL(string: "https://primary.example/video.m4s")!
        let backup = URL(string: "https://backup.example/video.m4s")!
        let track = BiliDashSource.Track(
            baseURL: primary,
            backupURLs: [backup],
            codecs: "avc1.640028",
            bandwidth: 1_000_000,
            mimeType: "video/mp4",
            initializationRange: .init(offset: 0, length: 128),
            indexRange: .init(offset: 128, length: 32),
            mediaStartOffset: 160,
            totalDuration: 10,
            width: 1920,
            height: 1080,
            qualityId: 80
        )

        XCTAssertEqual(
            PlaybackPrefetchManager.primaryUpstreamURL(track: track),
            primary
        )
    }

    // MARK: - PrefetchEntry Codable

    func test_entry_codableRoundTrip() throws {
        // meta.json on disk must round-trip losslessly so
        // a process restart can rebuild the cache index.
        // The on-disk format is the contract between the
        // manager and iOS Caches/ persistence — break it
        // and every existing entry becomes invisible on
        // next launch.
        let now = Date(timeIntervalSince1970: 1_726_000_000)
        let entry = PrefetchEntry(
            bvid: "BV1kN3m6eEPK",
            qn: 80,
            cid: 39_974_341_932,
            videoSize: 26_034_294,
            audioSize: 425_374,
            createdAt: now,
            lastAccessedAt: now
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(entry)
        let decoded = try decoder.decode(PrefetchEntry.self, from: data)
        XCTAssertEqual(decoded, entry)
    }

    func test_entry_videoOnly_audioSizeNilRoundTrips() throws {
        // The 1% of playurl responses that surface a
        // video-only DASH (no audio track) must round-trip
        // `audioSize = nil` through Codable — the proxy
        // will play video-only for these, the LRU counts
        // total bytes from `videoSize + (audioSize ?? 0)`.
        let now = Date(timeIntervalSince1970: 1_726_000_000)
        let entry = PrefetchEntry(
            bvid: "BV1videoOnlyExample",
            qn: 32,
            cid: 1,
            videoSize: 5_000_000,
            audioSize: nil,
            createdAt: now,
            lastAccessedAt: now
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(entry)
        let decoded = try decoder.decode(PrefetchEntry.self, from: data)
        XCTAssertNil(decoded.audioSize)
        XCTAssertEqual(decoded.videoSize, 5_000_000)
        XCTAssertEqual(decoded.totalBytes, 5_000_000)
    }

    func test_entry_totalBytes_sumsVideoPlusAudio() {
        let now = Date(timeIntervalSince1970: 1_726_000_000)
        let withAudio = PrefetchEntry(
            bvid: "BVx", qn: 80, cid: 1,
            videoSize: 26_000_000, audioSize: 400_000,
            createdAt: now, lastAccessedAt: now
        )
        XCTAssertEqual(withAudio.totalBytes, 26_400_000)
        let videoOnly = PrefetchEntry(
            bvid: "BVx", qn: 32, cid: 1,
            videoSize: 5_000_000, audioSize: nil,
            createdAt: now, lastAccessedAt: now
        )
        XCTAssertEqual(videoOnly.totalBytes, 5_000_000)
    }

    // MARK: - fileURL placement

    func test_fileURL_videoMapsToVideoM4S() {
        // The proxy reads from `<key>/video.m4s`; if the
        // manager ever moved the file (e.g. to
        // `video-init.m4s`), the proxy would 404 every
        // cache hit and silently fall back to the B站
        // Range path — a high-priority bug that's hard
        // to detect from logs alone.
        let dir = URL(fileURLWithPath: "/tmp/prefetch")
        let entry = makeEntry()
        let url = PlaybackPrefetchManager.fileURL(
            in: dir, entry: entry, kind: .video
        )
        XCTAssertEqual(url.lastPathComponent, "video.m4s")
        XCTAssertTrue(
            url.path.contains(entry.cacheKey),
            "video.m4s must live under the cacheKey subdir"
        )
    }

    func test_fileURL_audioMapsToAudioM4S() {
        let dir = URL(fileURLWithPath: "/tmp/prefetch")
        let entry = makeEntry()
        let url = PlaybackPrefetchManager.fileURL(
            in: dir, entry: entry, kind: .audio
        )
        XCTAssertEqual(url.lastPathComponent, "audio.m4s")
    }

    // MARK: - helpers

    private func makeEntry() -> PrefetchEntry {
        PrefetchEntry(
            bvid: "BV1kN3m6eEPK",
            qn: 80,
            cid: 39_974_341_932,
            videoSize: 26_034_294,
            audioSize: 425_374,
            createdAt: Date(timeIntervalSince1970: 1_726_000_000),
            lastAccessedAt: Date(timeIntervalSince1970: 1_726_000_000)
        )
    }
}
