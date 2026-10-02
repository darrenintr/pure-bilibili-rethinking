//
//  PlaybackPrefetchManager.swift
//  Paladala
//
//  Auto-prefetch-to-disk for the HLS proxy.  On a video
//  start, the manager downloads the whole video (and audio)
//  m4s files in the background and serves subsequent
//  `/segment` requests from the on-disk copy.
//
//  Why
//  ----
//  B站 returns DASH, not HLS — the local proxy synthesises
//  an HLS master + media playlists so AVPlayer can parse the
//  stream.  Today every AVPlayer segment request turns into
//  a separate Range request to the B站 CDN.  That costs
//  ~200–500 ms of RTT per segment, plus a real failure mode
//  where AVPlayer's "Segment exceeds specified bandwidth for
//  variant" check rejects a VBR peak that under-declared in
//  the master BANDWIDTH attribute.  By holding the whole
//  file on disk, every segment is read in O(1) from the
//  local file system, and the per-segment bitrate is exactly
//  the sidx-declared size/duration — so the master
//  BANDWIDTH the proxy computes from sidx fragments is also
//  the AVPlayer-side truth.
//
//  Lifecycle
//  ---------
//  1. `LocalHLSProxyServer.serve(playback:)` is called.
//  2. The proxy calls `manager.prefetch(bvid:qn:cid:playback:)`
//     on a background Task — non-blocking.
//  3. The manager checks the cache:
//     - hit  → call `entryAndTouch(...)` on the existing
//              entry, return immediately.
//     - miss → start a download Task that pulls the m4s
//              bytes via `URLSession.download(for:)` into
//              a temp file, then atomically renames into
//              the cache dir and writes `meta.json`.
//  4. The proxy meanwhile serves the first few segments
//     from the B站 CDN (existing Range path).  When the
//     prefetch finishes, the proxy's next segment request
//     hits the local file and the rest of the playback is
//     local.
//
//  Cache directory
//  ---------------
//  `<Caches>/Paladala/Prefetch/<bvid>_<qn>_<cid>/` with
//  three files: `meta.json`, `video.m4s`, `audio.m4s`
//  (audio optional).  `Caches/` because under storage
//  pressure iOS may purge the cache, which is fine —
//  prefetch is best-effort, the B站 Range fallback always
//  works.
//
//  LRU
//  ---
//  Total bytes on disk capped at `sizeCapBytes` (default
//  2 GB).  When a new entry pushes the total over the
//  cap, the manager sorts entries by `lastAccessedAt`
//  ascending and evicts the oldest until the total is
//  back under the cap.  Eviction is `O(n log n)` per
//  insert, which is fine for a cache with tens of
//  entries (each video is 30–200 MB → at most ~10–60
//  entries at the 2 GB cap).
//

import Foundation

/// Cache metadata for one prefetched (bvid, qn, cid) triple.
/// `cid` is part of the identity because the same bvid can
/// surface multiple P-numbers under different cids (e.g.
/// season episodes).
struct PrefetchEntry: Codable, Equatable, Sendable {
    /// Bilibili bvid, e.g. `BV1kN3m6eEPK`.  Always starts
    /// with `BV` in the modern format.
    let bvid: String
    /// Quality id (16/32/64/80/112/116/120/...).  Different
    /// qualities get separate cache entries because the
    /// upstream m4s bytes are not interchangeable.
    let qn: Int
    /// Content id.  Together with bvid, this is the
    /// canonical "what video is this" key for the
    /// prefetch cache.
    let cid: Int64
    /// Bytes of the cached video m4s file.
    let videoSize: Int64
    /// Bytes of the cached audio m4s file.  `nil` for
    /// video-only playurl responses.
    let audioSize: Int64?
    /// When the entry first committed.  Set once, never
    /// mutated.  LRU uses `lastAccessedAt`, not this.
    let createdAt: Date
    /// Most recent read-segment timestamp.  Updated on
    /// every `entryAndTouch` / `readSegment` call.
    var lastAccessedAt: Date

    var totalBytes: Int64 {
        videoSize + (audioSize ?? 0)
    }

    /// Directory name in the cache.  Raw form (no hash)
    /// so a quick `ls <Caches>/Paladala/Prefetch/` is
    /// debuggable on the iPad.
    var cacheKey: String {
        "\(bvid)_\(qn)_\(cid)"
    }
}

/// Track kind within a prefetch entry.  Maps 1:1 to the
/// on-disk filenames (`video.m4s`, `audio.m4s`).
enum PrefetchKind: String, Codable, Sendable {
    case video
    case audio
}

/// Auto-prefetch manager.  One singleton per process; the
/// actor isolation serialises mutations of the cache
/// index, the on-disk meta files, and the in-flight Task
/// tracker.
///
/// Read API (`entry(...)`, `readSegment(...)`) is safe to
/// call from any context — the actor hop is cheap and
/// non-blocking from the caller's perspective.
actor PlaybackPrefetchManager {
    /// Process-wide singleton.  Initialised at first
    /// access; `init` reads the on-disk cache and
    /// rebuilds the in-memory index before any caller
    /// sees a partial state.
    static let shared = PlaybackPrefetchManager()

    /// LRU size cap.  Defaults to 2 GB.  Set once at
    /// init from a `UserDefaults` override (settable from
    /// `ProfileSettingsView`); mutable in theory so a
    /// future "clear cache" UI can lower it to 0 and
    /// trigger immediate eviction.  Kept `nonisolated`
    /// because it's read by the eviction path on the
    /// actor but written only from the UI thread on
    /// cold launch.
    nonisolated let sizeCapBytes: Int64

    /// Where the cache lives.  `Caches/Paladala/Prefetch/`.
    /// `nonisolated` because it's set at init and never
    /// mutated, so concurrent reads from non-actor
    /// callers (e.g. diagnostic dumps) don't pay an
    /// actor-hop cost.
    nonisolated let cacheDirectory: URL

    /// Foreground URLSession used for prefetch downloads.
    /// Foreground is intentional: prefetch is best-effort,
    /// the user expects it to pause when the app goes to
    /// background, and a foreground session streams bytes
    /// to a temp file (via `.download(for:)`) more
    /// directly than a background session.
    private let downloadSession: URLSession

    /// In-memory cache index.  Keyed by
    /// `PrefetchEntry.cacheKey`.
    private var entries: [String: PrefetchEntry] = [:]

    /// In-flight download tasks.  Keyed by
    /// `PrefetchEntry.cacheKey`.  A second
    /// `prefetch(...)` call for the same key finds the
    /// existing Task and returns its result — no
    /// double-download.
    private var inFlight: [String: Task<Void, Never>] = [:]

    /// Convenience: total bytes across all entries.  Kept
    /// as a cached sum so the LRU size cap check is O(1)
    /// instead of O(n) per insert.
    private var totalBytes: Int64 = 0

    // MARK: - init

    init(sizeCapBytesOverride: Int64? = nil) {
        let defaultsMB = UserDefaults.standard
            .integer(forKey: "paladala.prefetch.sizeCapMB")
        let resolvedCap: Int64 = {
            if let override = sizeCapBytesOverride, override > 0 {
                return override
            }
            if defaultsMB > 0 {
                return Int64(defaultsMB) * 1_048_576
            }
            return 2 * 1024 * 1024 * 1024  // 2 GB default
        }()
        self.sizeCapBytes = resolvedCap

        let caches = try? FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = (caches ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("Paladala", isDirectory: true)
            .appendingPathComponent("Prefetch", isDirectory: true)
        self.cacheDirectory = dir

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60 * 5  // 5 min cap per download
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 4
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.downloadSession = URLSession(configuration: config)

        // Create the cache dir eagerly so subsequent
        // FileManager ops don't race with first use.
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )

        Task { await self.bootstrapFromDisk() }
    }

    /// Read the on-disk cache and rebuild the in-memory
    /// index.  Called once from `init` (deferred to a
    /// Task so `init` itself doesn't need to be async).
    /// Entries with missing files are dropped silently
    /// (the file may have been deleted out from under us
    /// — e.g. iOS purged the Caches dir).
    private func bootstrapFromDisk() async {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        for dir in contents {
            let metaURL = dir.appendingPathComponent("meta.json")
            guard let data = try? Data(contentsOf: metaURL),
                  let entry = try? Self.decoder.decode(
                    PrefetchEntry.self, from: data
                  ) else {
                continue
            }
            // Drop entries whose video.m4s is gone
            // (Caches purge, manual deletion, …).  The
            // audio file is allowed to be missing for
            // video-only entries.
            let videoURL = dir.appendingPathComponent("video.m4s")
            guard fm.fileExists(atPath: videoURL.path) else {
                try? fm.removeItem(at: dir)
                continue
            }
            entries[entry.cacheKey] = entry
            totalBytes += entry.totalBytes
        }
        bpLog("PlaybackPrefetchManager bootstrap: "
              + "\(entries.count) entries, \(totalBytes) bytes")
    }

    // MARK: - public read API

    /// Returns the entry for `(bvid, qn, cid)` if it has
    /// committed to disk.  Does *not* touch
    /// `lastAccessedAt` — callers that serve from the
    /// cache should use `entryAndTouch(...)` instead so
    /// the LRU sees fresh state.
    func entry(bvid: String, qn: Int, cid: Int64) -> PrefetchEntry? {
        entries[Self.cacheKey(bvid: bvid, qn: qn, cid: cid)]
    }

    /// Like `entry(...)` but bumps `lastAccessedAt` and
    /// rewrites `meta.json` so the LRU eviction sees the
    /// new timestamp after a process restart.  Used by
    /// the proxy on every cache-hit segment read.
    func entryAndTouch(
        bvid: String, qn: Int, cid: Int64
    ) -> PrefetchEntry? {
        let key = Self.cacheKey(bvid: bvid, qn: qn, cid: cid)
        guard var e = entries[key] else { return nil }
        e.lastAccessedAt = Date()
        entries[key] = e
        writeMetaFile(entry: e)
        return e
    }

    /// Read a byte range from a prefetched m4s.  Returns
    /// `nil` for any failure (entry missing, file gone,
    /// seek/read error).  The proxy treats `nil` as
    /// "fall back to the B站 Range path".
    func readSegment(
        bvid: String,
        qn: Int,
        cid: Int64,
        kind: PrefetchKind,
        byteRange: Range<Int64>
    ) -> Data? {
        guard let entry = entryAndTouch(
            bvid: bvid, qn: qn, cid: cid
        ) else { return nil }
        let fileURL = Self.fileURL(
            in: cacheDirectory, entry: entry, kind: kind
        )
        guard let handle = try? FileHandle(forReadingFrom: fileURL)
        else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(byteRange.lowerBound))
            return try handle.read(
                upToCount: Int(byteRange.count)
            )
        } catch {
            return nil
        }
    }

    // MARK: - prefetch trigger

    /// Kick off a prefetch in the background.  Idempotent:
    /// a second call for the same `(bvid, qn, cid)` while
    /// a download is in flight just returns — no
    /// double-download, no contention on the staging dir.
    func prefetch(
        bvid: String,
        qn: Int,
        cid: Int64,
        playback: BiliPlayback
    ) {
        let key = Self.cacheKey(bvid: bvid, qn: qn, cid: cid)
        // **PR-C (Phase 2 — fix, take 2)**: route through
        // `diagLog(.playback, ...)` so this evidence lands
        // in the persistent `Diagnostic events` stream
        // instead of being truncated by
        // `Logger.shared.logs.suffix(100)` in the
        // diagnostic tail.  Without this, build 327 left
        // us blind to whether the trigger ever spawned
        // the prefetch task.
        diagLog(.playback, "PlaybackPrefetchManager.prefetch entered",
                details: [
                    "bvid": bvid,
                    "qn": String(qn),
                    "cid": String(cid),
                    "cacheHit": entries[key] != nil ? "true" : "false",
                    "inFlight": inFlight[key] != nil ? "true" : "false",
                    "hasDash": playback.dash != nil ? "true" : "false"
                ])
        if entries[key] != nil {
            // Already on disk — just touch the entry so
            // the LRU treats this as a fresh use.
            _ = entryAndTouch(bvid: bvid, qn: qn, cid: cid)
            return
        }
        if inFlight[key] != nil {
            return
        }
        let task: Task<Void, Never> = Task { [weak self] in
            await self?.runPrefetch(
                bvid: bvid, qn: qn, cid: cid, playback: playback
            )
        }
        inFlight[key] = task
    }

    // MARK: - LRU eviction

    /// Drop oldest entries until the total is back under
    /// `sizeCapBytes`.  Called after every successful
    /// commit.  O(n log n) per insert; at 2 GB / 30 MB
    /// per video that's ~67 entries, so the sort is
    /// cheap.
    private func enforceSizeCap() {
        guard totalBytes > sizeCapBytes else { return }
        let sorted = entries.values.sorted {
            $0.lastAccessedAt < $1.lastAccessedAt
        }
        for victim in sorted {
            if totalBytes <= sizeCapBytes { break }
            evictEntry(victim)
        }
    }

    private func evictEntry(_ entry: PrefetchEntry) {
        let dir = cacheDirectory.appendingPathComponent(
            entry.cacheKey, isDirectory: true
        )
        try? FileManager.default.removeItem(at: dir)
        entries.removeValue(forKey: entry.cacheKey)
        totalBytes -= entry.totalBytes
    }

    // MARK: - download

    /// Background download.  Streams both video and audio
    /// in parallel via `URLSession.bytes(for:)`, writes
    /// them to a staging dir, then atomically renames to
    /// the final cache dir and writes `meta.json`.  On
    /// any video-side failure the staging dir is removed
    /// and no entry is added to the index.  Audio
    /// failures fall through to a video-only cache entry
    /// (AVPlayer will play video-only for that small
    /// subset of tracks).
    private func runPrefetch(
        bvid: String,
        qn: Int,
        cid: Int64,
        playback: BiliPlayback
    ) async {
        let key = Self.cacheKey(bvid: bvid, qn: qn, cid: cid)
        defer { inFlight.removeValue(forKey: key) }

        // `BiliDashSource.Track` does not carry an absolute
        // `size` field - B站 playurl publishes bandwidth
        // (bps) and total duration (seconds) only; the real
        // file size is only known after the upstream
        // Content-Length comes back.  So we estimate the
        // prefetch target as `bandwidth * totalDuration / 8`
        // (within plus or minus 5 percent for any real
        // video) and also log the raw `bandwidth` and
        // `totalDuration` so the reader can recompute.
        // Both fields default to 0 when `dash` is nil
        // (the entry log fires before the
        // `guard let dash` so a missing dash is still
        // recorded).
        let videoTrack = playback.dash?.video
        let audioTrack = playback.dash?.audio
        let videoEstimatedBytes: Int64 = {
            guard let t = videoTrack else { return 0 }
            return Int64(t.bandwidth) * Int64(t.totalDuration) / 8
        }()
        let audioEstimatedBytes: Int64 = {
            guard let t = audioTrack else { return 0 }
            return Int64(t.bandwidth) * Int64(t.totalDuration) / 8
        }()

        // **PR-C (Phase 2 — fix, take 3)**: convert the
        // bpLog at this entry to diagLog so the next
        // diagnostic always shows whether `runPrefetch`
        // actually started (vs being silently skipped),
        // and how big the upstream target is.  bpLog
        // gets truncated by `Logger.shared.logs.suffix(100)`
        // during hot-path video sessions; diagLog is
        // persisted to disk and dumped verbatim.
        diagLog(.playback, "PlaybackPrefetchManager.runPrefetch started",
                details: [
                    "bvid": bvid,
                    "qn": String(qn),
                    "cid": String(cid),
                    "videoBandwidthBps": String(videoTrack?.bandwidth ?? 0),
                    "videoTotalDurationS":
                        String(format: "%.3f", videoTrack?.totalDuration ?? 0),
                    "videoEstimatedBytes": String(videoEstimatedBytes),
                    "audioBandwidthBps": String(audioTrack?.bandwidth ?? 0),
                    "audioTotalDurationS":
                        String(format: "%.3f", audioTrack?.totalDuration ?? 0),
                    "audioEstimatedBytes": String(audioEstimatedBytes)
                ])

        guard let dash = playback.dash else {
            diagLog(.playback,
                    "PlaybackPrefetchManager.runPrefetch skipped: no dash",
                    details: [
                        "bvid": bvid,
                        "qn": String(qn),
                        "cid": String(cid)
                    ])
            return
        }

        let staging = cacheDirectory
            .appendingPathComponent(
                "\(key).staging-\(UUID().uuidString)",
                isDirectory: true
            )
        do {
            try FileManager.default.createDirectory(
                at: staging, withIntermediateDirectories: true
            )
        } catch {
            bpLog("PlaybackPrefetchManager staging mkdir failed: \(error)")
            diagLog(.playback,
                    "PlaybackPrefetchManager staging mkdir failed",
                    details: [
                        "bvid": bvid,
                        "qn": String(qn),
                        "cid": String(cid),
                        "error": String(describing: error)
                    ])
            return
        }

        let videoStaging = staging.appendingPathComponent("video.m4s")
        let audioStaging = staging.appendingPathComponent("audio.m4s")

        // The first upstream URL for each track.  For a
        // one-shot download we don't have probing the way
        // the proxy's `preparationCandidates` does, so we
        // pick the primary (or first backup) and accept
        // that a dead CDN will surface as an HTTP error.
        let videoURL = Self.primaryUpstreamURL(track: dash.video)
        let audioURL = dash.audio.map { Self.primaryUpstreamURL(track: $0) }

        async let videoResult: Result<Int64, Error> = runDownload(
            url: videoURL,
            referer: playback.referer.absoluteString,
            dst: videoStaging
        )
        let audioR: Result<Int64?, Error> = await {
            guard let audioURL else { return .success(nil) }
            return await runDownload(
                url: audioURL,
                referer: playback.referer.absoluteString,
                dst: audioStaging
            ).map { .some($0) }
        }()
        let videoR = await videoResult

        guard case .success(let videoSize) = videoR else {
            bpLog("PlaybackPrefetchManager video download failed: "
                  + "\(String(describing: videoR))")
            diagLog(.playback,
                    "PlaybackPrefetchManager video download failed",
                    details: [
                        "bvid": bvid,
                        "qn": String(qn),
                        "cid": String(cid),
                        "result": String(describing: videoR)
                    ])
            try? FileManager.default.removeItem(at: staging)
            return
        }
        // Audio is best-effort: if audio fails, keep the
        // video file and cache it as a video-only entry.
        // AVPlayer will play video-only (no audio) for
        // that small subset of tracks.
        let audioSize: Int64?
        switch audioR {
        case .success(let s): audioSize = s
        case .failure(let e):
            bpLog("PlaybackPrefetchManager audio download failed "
                  + "(continuing video-only): \(e)")
            diagLog(.playback,
                    "PlaybackPrefetchManager audio download failed",
                    details: [
                        "bvid": bvid,
                        "qn": String(qn),
                        "cid": String(cid),
                        "error": String(describing: e)
                    ])
            audioSize = nil
            try? FileManager.default.removeItem(at: audioStaging)
        }

        // Atomic commit: rename the staging dir to the
        // final cache key.  `moveItem` is atomic on the
        // same volume.
        let finalDir = cacheDirectory
            .appendingPathComponent(key, isDirectory: true)
        do {
            try FileManager.default.moveItem(at: staging, to: finalDir)
        } catch {
            bpLog("PlaybackPrefetchManager commit rename failed: \(error)")
            diagLog(.playback,
                    "PlaybackPrefetchManager commit rename failed",
                    details: [
                        "bvid": bvid,
                        "qn": String(qn),
                        "cid": String(cid),
                        "error": String(describing: error)
                    ])
            try? FileManager.default.removeItem(at: staging)
            return
        }

        let now = Date()
        let entry = PrefetchEntry(
            bvid: bvid,
            qn: qn,
            cid: cid,
            videoSize: videoSize,
            audioSize: audioSize,
            createdAt: now,
            lastAccessedAt: now
        )
        entries[entry.cacheKey] = entry
        totalBytes += entry.totalBytes
        writeMetaFile(entry: entry)

        enforceSizeCap()

        bpLog("PlaybackPrefetchManager committed: "
              + "key=\(key) video=\(videoSize) audio=\(audioSize ?? -1) "
              + "total=\(totalBytes)")
        diagLog(.playback, "PlaybackPrefetchManager committed",
                details: [
                    "key": key,
                    "videoSize": String(videoSize),
                    "audioSize": String(audioSize ?? -1),
                    "cacheTotal": String(totalBytes)
                ])
    }

    /// Run one upstream download, return Result so
    /// `async let` parallel-join can collect both legs.
    private func runDownload(
        url: URL,
        referer: String,
        dst: URL
    ) async -> Result<Int64, Error> {
        do {
            let bytes = try await streamM4SToFile(
                url: url,
                referer: referer,
                dst: dst
            )
            return .success(bytes)
        } catch {
            return .failure(error)
        }
    }

    /// Stream an upstream m4s to disk.  Uses
    /// `URLSession.download(for:)` (iOS 15+) which writes
    /// the response body to a temp file behind the scenes
    /// — never holds the bytes in memory.  We then move
    /// the temp file to `dst` and report its size.
    ///
    /// `download(for:)` is preferred over `bytes(for:)`
    /// here because the latter yields `UInt8`-by-`UInt8`
    /// (one allocation per byte — O(file size) overhead),
    /// whereas `download(for:)` uses the system's existing
    /// download path.
    private func streamM4SToFile(
        url: URL,
        referer: String,
        dst: URL
    ) async throws -> Int64 {
        var req = URLRequest(url: url)
        req.setValue(referer, forHTTPHeaderField: "Referer")
        req.setValue(Self.biliUserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        req.setValue("gzip, deflate", forHTTPHeaderField: "Accept-Encoding")
        req.setValue("https://www.bilibili.com", forHTTPHeaderField: "Origin")
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        let (tmpFile, response) = try await downloadSession.download(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(status) else {
            // Clean up the temp file even on HTTP error.
            try? FileManager.default.removeItem(at: tmpFile)
            throw PrefetchError.upstreamStatus(status)
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: tmpFile.path)
        let size = (attrs?[.size] as? Int64) ?? 0
        // Move (not copy) the temp file to the staging
        // location.  `moveItem` is atomic on the same
        // volume, so a crash mid-commit leaves the
        // staging dir as the only artifact and the cache
        // stays consistent.
        do {
            if FileManager.default.fileExists(atPath: dst.path) {
                try FileManager.default.removeItem(at: dst)
            }
            try FileManager.default.moveItem(at: tmpFile, to: dst)
        } catch {
            try? FileManager.default.removeItem(at: tmpFile)
            throw PrefetchError.ioFailure("\(error)")
        }
        return size
    }

    // MARK: - helpers

    /// Cache key builder.  Public-static so the test
    /// target can pin the format independently.
    static func cacheKey(
        bvid: String, qn: Int, cid: Int64
    ) -> String {
        "\(bvid)_\(qn)_\(cid)"
    }

    /// First upstream URL for a track.  The base URL is the
    /// primary candidate; backup URLs remain available to the
    /// proxy's failover path if this best-effort prefetch fails.
    /// We do *not* probe here (the existing proxy's
    /// `preparationCandidates` runs the probe); prefetch should
    /// start with the same primary candidate the active playback
    /// selected.
    static func primaryUpstreamURL(
        track: BiliDashSource.Track
    ) -> URL {
        return track.baseURL
    }

    /// Path to a single m4s file for an entry.
    static func fileURL(
        in cacheDirectory: URL,
        entry: PrefetchEntry,
        kind: PrefetchKind
    ) -> URL {
        let dir = cacheDirectory.appendingPathComponent(
            entry.cacheKey, isDirectory: true
        )
        switch kind {
        case .video: return dir.appendingPathComponent("video.m4s")
        case .audio: return dir.appendingPathComponent("audio.m4s")
        }
    }

    /// JSON-encodes `entry` and writes it to
    /// `<cacheDir>/<key>/meta.json`.  Best-effort — a
    /// write failure here just means the LRU sees a stale
    /// timestamp on next launch, which only affects
    /// eviction order, not correctness.
    private func writeMetaFile(entry: PrefetchEntry) {
        let dir = cacheDirectory.appendingPathComponent(
            entry.cacheKey, isDirectory: true
        )
        let metaURL = dir.appendingPathComponent("meta.json")
        guard let data = try? Self.encoder.encode(entry) else { return }
        try? data.write(to: metaURL, options: .atomic)
    }

    /// Shared JSON encoder / decoder.  Dates as ISO-8601
    /// strings for cross-platform readability (a `file
    /// <meta.json>` on the iPad should be human-grokkable).
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// User-Agent for upstream fetches.  Mirrors what the
    /// proxy uses for its in-flight Range requests so the
    /// prefetch doesn't get a different fingerprint from
    /// the range requests that follow.
    private static let biliUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) "
        + "Version/18.0 Mobile/15E148 Safari/604.1"
}

/// Internal error type.  Surface-area kept small because
/// the proxy only needs "did it fail" — any thrown error
/// is treated as "fall back to B站 Range path".
enum PrefetchError: Error, CustomStringConvertible {
    case upstreamStatus(Int)
    case ioFailure(String)

    var description: String {
        switch self {
        case .upstreamStatus(let s):
            return "upstream returned HTTP \(s)"
        case .ioFailure(let detail):
            return "I/O failure: \(detail)"
        }
    }
}
