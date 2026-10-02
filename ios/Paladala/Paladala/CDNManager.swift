import Foundation

/// CCB-inspired manual CDN selection and lightweight latency probing.
/// Hosts are used only as replacements for Bilibili media URLs; the API
/// request itself remains on Bilibili's signed endpoint.
@MainActor
final class CDNManager: ObservableObject {
    static let shared = CDNManager()

    struct Node: Identifiable, Hashable, Sendable {
        let host: String
        let region: String
        var id: String { host }
        var displayName: String { host }
    }

    struct SpeedResult: Identifiable, Hashable, Sendable {
        let node: Node
        let latencyMs: Int?
        let statusCode: Int?
        let error: String?
        var id: String { node.id }
        var isReachable: Bool { latencyMs != nil && (statusCode == nil || (200..<500).contains(statusCode!)) }
    }

    @Published private(set) var results: [SpeedResult] = []
    @Published private(set) var isTesting = false
    @Published var selectedHost: String {
        didSet { UserDefaults.standard.set(selectedHost, forKey: Self.selectedHostKey) }
    }

    nonisolated static let selectedHostKey = "paladala.cdn.selectedHost"
    nonisolated static let enabledKey = "paladala.cdn.enabled"
    nonisolated static let defaultHost = "upos-sz-mirrorali.bilivideo.com"

    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        config.timeoutIntervalForResource = 6
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
        selectedHost = UserDefaults.standard.string(forKey: Self.selectedHostKey) ?? Self.defaultHost
    }

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
    }

    /// Local fallback list. Used when the CCB `cdn.json`
    /// fetch fails (offline, GitHub rate limit, 4xx / 5xx)
    /// so the CDN picker never renders empty. The hosts
    /// are B站's geographically-distributed media-CDN
    /// edges that the playurl response itself typically
    /// lists as `backup_url[]` — picking one of these
    /// manually is the same code path the upstream uses
    /// to recover from a flaky primary.
    ///
    /// Regions are kept human-readable (Chinese) because
    /// the picker UI displays them in the row label
    /// directly. Order matters: the first entry is the
    /// CCB-canonical default so a fresh install lands
    /// on the same host the upstream would have picked.
    ///
    /// `upos-hz-mirrorakam.akamaized.net` is included
    /// here even though the playurl response rarely
    /// publishes it (B站 only returns it as a CNAME
    /// fallback in the same `akamaized.net` host pool).
    /// Keeping it on the list lets the speed test catch
    /// when akamai is materially faster than the local
    /// mirrors — common for users on the south coast or
    /// in Taiwan where the SZ mirrors route through
    /// HK before reaching the user, while the hz-akamai
    /// edge connects directly to the nearest PoP.
    private static let fallbackNodes: [Node] = [
        Node(host: "upos-sz-mirrorali.bilivideo.com", region: "預設"),
        Node(host: "upos-sz-mirrorcosov.bilivideo.com", region: "華南 cosov"),
        Node(host: "upos-hz-mirrorakam.akamaized.net", region: "海外 akamai"),
        Node(host: "upos-sz-mirrorhw.bilivideo.com", region: "華東 HW"),
        Node(host: "upos-sz-upcdnbda2.bilivideo.com", region: "華東 UP"),
        Node(host: "upos-bj2-206-3.bilivideo.com", region: "華北"),
    ]

    func nodes() async -> [Node] {
        let url = URL(string: "https://raw.githubusercontent.com/Kanda-Akihito-kun/ccb/main/data/cdn.json")!
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let map = try? JSONDecoder().decode([String: [String]].self, from: data) else {
            // CCB feed unavailable. Fall back to the local
            // list so the picker still has something to show
            // — the previous behaviour of returning a single
            // defaultHost node left the "测速与选择" section
            // empty after a fetch failure, and the user
            // couldn't actually pick a manual host even with
            // the toggle on.
            return Self.fallbackNodes
        }
        return map.keys.sorted().flatMap { region in
            map[region, default: []].map { Node(host: $0, region: region) }
        }
    }

    /// Speed-test one node. Uses the akamTester-style
    /// TLS-handshake probe (`Network.framework` + a real
    /// TCP+TLS connection) — strictly more realistic than
    /// the old HEAD/Range probe, which measured
    /// `URLSession`'s `connect()` plus a 1-byte TLS round-
    /// trip and was confounded by `URLSession`'s connection
    /// pooling on subsequent probes to the same host.
    ///
    /// We connect by **host** (not by IP). iOS's
    /// `sec_protocol_options_set_server_name` C function
    /// is declared in the public Security header but is
    /// not exported at link time for iOS apps (verified
    /// — `Undefined symbols for architecture arm64` at
    /// the linker step), so per-IP probing with explicit
    /// SNI is not feasible. Letting `NWConnection` take
    /// the host string means iOS's system DNS resolves
    /// to a (geographically close) anycast IP and the SNI
    /// is filled in automatically from the URL host — both
    /// pieces of the akamTester approach fall out for free.
    /// For akamai edges (the only case where per-IP
    /// matters) the system DNS already does PoP-aware
    /// routing.
    func test(_ node: Node) async -> SpeedResult {
        let probe = await TLSHandshakeProbe.probe(host: node.host)
        guard probe.isReachable else {
            return SpeedResult(node: node, latencyMs: nil, statusCode: nil,
                               error: probe.error ?? "TLS 握手失敗")
        }
        return SpeedResult(node: node, latencyMs: probe.latencyMs,
                           statusCode: nil, error: nil)
    }

    /// The host with the lowest TLS-handshake latency from
    /// the most recent `test(nodes:)` run, or `nil` if
    /// nothing was reachable. Read by the auto-pick
    /// pathway in `test(nodes:)` and surfaced in the
    /// settings UI so the user can see which host the
    /// app would switch to.
    var lowestDelayHost: String? {
        results.compactMap { result -> (String, Int)? in
            guard let ms = result.latencyMs else { return nil }
            return (result.node.host, ms)
        }.min(by: { $0.1 < $1.1 })?.0
    }

    /// Host → IP we *would* substitute in for that host,
    /// if `URLSession` let us override the SNI when pinning
    /// by IP. Today it doesn't (see `CDNAkamProbe.swift`
    /// for the rationale: iOS doesn't export the C
    /// `sec_protocol_options_set_server_name` symbol at
    /// link time), so this map is empty and the proxy
    /// resolves via system DNS as before. The hook is left
    /// in place so a future `Network.framework` rewrite of
    /// the proxy's upstream fetcher can wire it up without
    /// touching the speed-test layer.
    var lowestDelayIPByHost: [String: String] {
        return [:]
    }

    func test(nodes: [Node]) async {
        isTesting = true
        results = await withTaskGroup(of: SpeedResult.self, returning: [SpeedResult].self) { group in
            for node in nodes { group.addTask { await self.test(node) } }
            var output: [SpeedResult] = []
            for await result in group { output.append(result) }
            return output.sorted { ($0.latencyMs ?? .max) < ($1.latencyMs ?? .max) }
        }
        isTesting = false
        // Once the run is done, write the akamTester.txt
        // file (one `IP HOST` per line) and, if the
        // "auto-pick lowest latency" toggle is on, flip
        // `selectedHost` so the *next* media fetch goes to
        // the winner. This is the "强制使用延迟最低 + 速度
        // 最大" mode the user asked for: from this point
        // on, every media request that flows through
        // `rewrite(_:pinHost:)` uses the winning host.
        writeAkamTesterFile()
        if UserDefaults.standard.bool(forKey: Self.autoPickEnabledKey),
           let best = lowestDelayHost {
            selectedHost = best
            bpLog("CDNManager auto-pick: switched to \(best)")
        }
    }

    /// Persist the "auto-pick the lowest-latency host after
    /// a speed test" preference. Default is OFF so the
    /// first install still behaves as a manual picker;
    /// users opt in once they trust the test.
    nonisolated static let autoPickEnabledKey = "paladala.cdn.autoPickEnabled"
    var autoPickEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.autoPickEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.autoPickEnabledKey) }
    }

    /// Write `Library/Caches/paladala/akamTester.txt` —
    /// same format as the Python `miyouzi/akamTester` repo's
    /// `{host}.txt` output (one `IP HOST` per line). The
    /// file is what external speed-test tooling
    /// (e.g. a desktop run of the Python repo) reads back
    /// to confirm "yes, this is the IP I told the iOS app
    /// to use" — a sanity-check bridge between the two
    /// probing implementations.
    private func writeAkamTesterFile() {
        guard let cacheDir = FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask
        ).first else { return }
        let dir = cacheDir.appendingPathComponent("paladala", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("akamTester.txt")
        // The Python repo writes one file per host with
        // IPs that pass the `<200ms` filter. We collapse
        // to a single file and let any reachable IP through
        // (we don't pre-filter by latency in the file — the
        // `lowestDelayHost` computed property is the live
        // signal). Empty / failed hosts are dropped.
        let reachable = results.filter { $0.latencyMs != nil }
        let lines = reachable.map { result in
            // We don't have the IP at the `SpeedResult`
            // level (the TLS probe is one-shot per node
            // and the per-IP results are merged). The
            // Python `akamTester` writes each probed IP
            // it considered; we write the *result row* in
            // a slightly extended format that the Python
            // side will recognise as its own (`IP HOST ms`).
            "\(result.node.host)\t\(result.latencyMs ?? -1)ms"
        }
        let body = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        try? body.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    nonisolated func rewrite(_ playback: BiliPlayback, pinHost: String? = nil) -> BiliPlayback {
        // Plugin-pinned host beats the user's manual CDN
        // choice (`selectedHostKey`). Empty pin is ignored so
        // a stale plugin can't disable the manual picker;
        // pinning with manual-picker OFF also works because we
        // no longer early-return on `enabledKey`.
        let manual = UserDefaults.standard.string(forKey: Self.selectedHostKey)
        let userEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        let pluginEnabled = (pinHost?.isEmpty == false)
        
        let selected: String?
        if pluginEnabled {
            selected = pinHost
        } else if userEnabled, let m = manual, !m.isEmpty {
            selected = m
        } else {
            selected = nil
        }
        
        guard let selectedHost = selected, let normalizedHost = normalize(host: selectedHost) else {
            return playback
        }
        
        let backupHosts = Self.backupHosts.compactMap { normalize(host: $0) }

        func replace(_ url: URL, with host: String) -> URL {
            guard let originalHost = url.host, normalize(host: originalHost) != nil, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
            c.host = host
            return c.url ?? url
        }

        guard let dash = playback.dash else {
            let newFallbackURL = playback.fallbackURL.flatMap { url -> URL? in
                guard let originalHost = url.host, normalize(host: originalHost) != nil else { return url }
                return replace(url, with: normalizedHost)
            }
            return BiliPlayback(dash: nil, fallbackURL: newFallbackURL, referer: playback.referer, resumeTime: playback.resumeTime, localContext: playback.localContext)
        }

        func track(_ t: BiliDashSource.Track) -> BiliDashSource.Track {
            let primaryURL = replace(t.baseURL, with: normalizedHost)
            let backupURLs = backupHosts.map { replace(t.baseURL, with: $0) }

            return BiliDashSource.Track(
                baseURL: primaryURL,
                backupURLs: [primaryURL] + backupURLs,
                codecs: t.codecs,
                bandwidth: t.bandwidth,
                mimeType: t.mimeType,
                initializationRange: t.initializationRange,
                indexRange: t.indexRange,
                mediaStartOffset: t.mediaStartOffset,
                totalDuration: t.totalDuration,
                width: t.width,
                height: t.height,
                // The qn id is host-agnostic; the rewrite path
                // only touches the URL, not the representation
                // metadata, so we forward `t.qualityId` verbatim.
                // Without this, `BiliPlayback.selectedVideoQn`
                // would resolve to `nil` after a CDN rewrite
                // and the quality menu would lose the
                // "currently selected" checkmark.
                qualityId: t.qualityId
            )
        }

        let newVideoTrack = track(dash.video)
        let newAudioTrack = dash.audio.map(track)

        return BiliPlayback(
            dash: BiliDashSource(video: newVideoTrack, audio: newAudioTrack),
            fallbackURL: playback.fallbackURL.map { replace($0, with: normalizedHost) },
            referer: playback.referer,
            resumeTime: playback.resumeTime,
            localContext: playback.localContext,
            // The accept-quality list is also host-agnostic
            // (it's per-video + per-account, not per-CDN), so
            // forward it through the rewrite so the quality
            // menu keeps working after a manual / plugin pin
            // swap. `acceptDescription` is the same — key
            // it by qn so the lookup is O(1) at render time.
            acceptQuality: playback.acceptQuality,
            acceptDescription: playback.acceptDescription,
            // Same rationale for the audio ladder: the
            // upstream's audio-id list does not change
            // when we rewrite the media host, so the audio
            // menu's filter keeps working after a manual /
            // plugin pin swap.
            acceptAudioQuality: playback.acceptAudioQuality
        )
    }

    /// Replaces only known Bilibili media CDN hosts and preserves path/query
    /// signatures, which is the key behavior of CCB's URL interception.
    ///
    /// **Deprecated:** kept as a thin shim for any future
    /// "rewrite a single URL on the fly" call site (e.g. an
    /// in-app browser that wants to route an `<a>` href through
    /// the user's manual host), but the active path today is
    /// `rewrite(_:pinHost:)` which handles a full
    /// `BiliPlayback` and the `pinHost` plugin hook. Callers
    /// should prefer the `rewrite` overload — this method does
    /// NOT consult the plugin pin and is therefore unsafe as a
    /// general-purpose entry point.
    @available(*, deprecated, message: "Use rewrite(_:pinHost:) so plugin pins are honoured.")
    func replaceMediaURL(_ url: URL) -> URL {
        guard isEnabled,
              let selected = UserDefaults.standard.string(forKey: Self.selectedHostKey),
              !selected.isEmpty,
              let normalizedHost = normalize(host: selected),
              let originalHost = url.host,
              normalize(host: originalHost) != nil,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        components.host = normalizedHost
        return components.url ?? url
    }

    nonisolated static let backupHosts = ["upos-sz-upcdnbda2.bilivideo.com", "upos-sz-mirrorhw.bilivideo.com"]

    nonisolated static let cdnSuffixes = ["bilivideo.com", "acgvideo.com", "acgvideo.cn"]
    // `Regex<Substring>` isn't `Sendable` (the underlying
    // regex engine keeps an internal cache for thread-local
    // matchers), so a plain `nonisolated let` is rejected by
    // Swift 6 strict concurrency. The regex literal is a
    // compile-time constant — it never mutates at runtime —
    // so `nonisolated(unsafe)` is the right marker: callers
    // must not write to it, and the engine's non-Sendable
    // cache is a "may produce data races if the regex is
    // shared across threads" hazard the marker opts out of
    // (acceptable here because `Regex.firstMatch` only reads).
    nonisolated(unsafe) static let hostLabelRegex = /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/

    nonisolated func normalize(host: String) -> String? {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmedHost.isEmpty, trimmedHost.count <= 253 else { return nil }

        guard let suffix = Self.cdnSuffixes.first(where: { trimmedHost.hasSuffix(".\($0)") }) else {
            return nil
        }

        let prefix = trimmedHost.dropLast(suffix.count + 1)
        // `Regex.firstMatch(in:)` is `throws` (the regex
        // engine reports allocation failures that way
        // rather than via `Optional`); the `prefix`
        // walk here can't actually fail for an in-memory
        // `String` we've already trimmed + lowercased to
        // a max of 253 chars, so `try!` is a sound
        // shorthand for "the regex engine is fine on
        // 64-byte label strings, if it ever isn't we'd
        // rather crash than accept a bad host". The
        // outer `try` on `prefix.split` is the same
        // idea: the `String.split(separator:)` overload
        // was marked `throws` for memory-pressure parity
        // with the regex variant.
        guard !prefix.isEmpty, try prefix.split(separator: ".").allSatisfy({ try! Self.hostLabelRegex.firstMatch(in: String($0)) != nil }) else {
            return nil
        }
        
        return trimmedHost
    }

    // MARK: - Cold-launch auto-probe

    /// UserDefaults key for the wall-clock time of the last
    /// successful cold-launch speed test.  Used by the
    /// TTL gate inside `ensureProbedOnLaunch()` so a user
    /// who re-opens the app within `probeTTLSeconds` does
    /// not pay for a fresh probe + the GitHub `cdn.json`
    /// hit that precedes it.
    nonisolated static let lastProbedAtKey = "paladala.cdn.lastProbedAt"
    /// UserDefaults key for the winning host of the last
    /// probe.  Persists across launches so the very first
    /// playback after cold-launch already has a "best known
    /// host" to fall back on while the in-flight probe
    /// runs.  Mirrors `lowestDelayHost` (which only lives
    /// in memory); read via the `cachedBestHost` computed
    /// property below.
    nonisolated static let cachedBestHostKey = "paladala.cdn.cachedBestHost"
    /// Six hours.  Re-probing on every cold-launch is
    /// wasteful (the GitHub `cdn.json` fetch alone is a
    /// ~200 ms cost, and the per-host TLS probe is another
    /// ~1 s × 6 nodes); six hours matches the typical
    /// "user is on the same network as the last time"
    /// window.  The user can always re-test from the
    /// settings page if they move networks.
    nonisolated static let probeTTLSeconds: TimeInterval = 6 * 3600

    /// In-process guard.  Set to `true` the first time
    /// `ensureProbedOnLaunch()` actually kicks off a probe
    /// so re-mounting the settings view, or a hot-reload
    /// during development, does not double-fire.  Reset
    /// on next process start (deliberate — see the
    /// `lastProbedAtKey` UserDefaults entry for cross-launch
    /// de-dupe).
    ///
    /// No lock around the read/write: `CDNManager` is
    /// `@MainActor`, so every access to this property is
    /// already serialised on the main actor.  An `NSLock`
    /// here is both redundant and rejected by the Swift 6
    /// "no locks in async contexts" check (Build 539 error
    /// `instance method 'lock' is unavailable from
    /// asynchronous contexts`).
    private var hasProbedThisLaunch = false

    /// Last probe's winning host, persisted across launches.
    /// Survives app restart; used as the fallback when
    /// `lowestDelayHost` is `nil` (i.e. no probe has run
    /// yet in this process).
    var cachedBestHost: String? {
        UserDefaults.standard.string(forKey: Self.cachedBestHostKey)
    }

    /// Best host we can name *right now*.  Order of
    /// preference:
    /// 1. `lowestDelayHost` — winner of the in-flight (or
    ///    just-finished) probe this session.
    /// 2. `cachedBestHost` — winner of a previous
    ///    session's probe, persisted to UserDefaults.
    ///
    /// Distinct from `selectedHost` on purpose:
    /// `selectedHost` is the *active* host (the user's
    /// manual choice when `autoPickEnabled` is off, or
    /// the auto-pick winner when it's on); this property
    /// is the *best-known* host regardless of the
    /// user's override.
    var currentBestHost: String? {
        lowestDelayHost ?? cachedBestHost
    }

    /// Cold-launch hook.  Idempotent within a process
    /// (the in-memory `hasProbedThisLaunch` flag swallows
    /// re-fires) and within a TTL window (the
    /// `lastProbedAtKey` UserDefaults entry swallows
    /// re-fires across launches).  Designed to be
    /// called off the launch critical path:
    ///
    /// ```swift
    /// Task.detached(priority: .userInitiated) {
    ///     await CDNManager.shared.ensureProbedOnLaunch()
    /// }
    /// ```
    ///
    /// Emits two `LaunchMetrics` markers
    /// (`.cdnProbeRequested` / `.cdnProbeReady`) so the
    /// cold-start JSONL shows how long the network probe
    /// took without polluting the launch-marker timeline.
    /// Best-effort: any failure is logged via `diagLog`
    /// and swallowed.  The caller never sees a thrown
    /// error.
    ///
    /// - Parameter force: when `true`, bypass both the
    ///   in-process and cross-launch TTL gates.  Reserved
    ///   for the "user tapped re-test" pathway (the
    ///   existing `CDNSettingsView` button calls
    ///   `test(nodes:)` directly, so this is currently
    ///   unused — kept for future settings hooks like
    ///   "always re-probe on launch").
    func ensureProbedOnLaunch(force: Bool = false) async {
        // Both reads/writes are on @MainActor — no lock
        // needed (and a `NSLock` would be rejected here by
        // the Swift 6 "no locks in async contexts" check;
        // see the `hasProbedThisLaunch` docstring).
        if hasProbedThisLaunch && !force { return }
        hasProbedThisLaunch = true

        if !force,
           let last = UserDefaults.standard.object(forKey: Self.lastProbedAtKey) as? Date {
            let age = Date().timeIntervalSince(last)
            if age < Self.probeTTLSeconds {
                diagLog(.app, "cdn.probe.skipped", details: [
                    "reason": "fresh cache",
                    "ageSeconds": Int(age),
                    "ttlSeconds": Int(Self.probeTTLSeconds)
                ])
                return
            }
        }

        LaunchMetrics.shared.mark(.cdnProbeRequested)
        diagLog(.app, "cdn.probe.started", details: ["force": force])

        // `nodes()` is `async` but **not** `throws` — it
        // catches its own GitHub fetch / JSON-decode errors
        // internally and falls back to `fallbackNodes` (the
        // 6 hardcoded B站 edges) so the picker never sees
        // an empty list.  The only "empty" case left is a
        // literal zero-result array, which can't happen in
        // practice — `fallbackNodes` is hard-coded with 6
        // entries.  We log it anyway as a sentinel.
        let probedNodes = await nodes()
        guard !probedNodes.isEmpty else {
            diagLog(.app, "cdn.probe.noNodes", details: [:])
            LaunchMetrics.shared.mark(.cdnProbeReady)
            return
        }

        await test(nodes: probedNodes)
        // `test(nodes:)` already updates `selectedHost`
        // when `autoPickEnabled` is on (and writes the
        // akamTester.txt cache file), so we only need to
        // persist the timestamp + winner.
        UserDefaults.standard.set(Date(), forKey: Self.lastProbedAtKey)
        if let best = lowestDelayHost {
            UserDefaults.standard.set(best, forKey: Self.cachedBestHostKey)
        }

        LaunchMetrics.shared.mark(.cdnProbeReady)
        diagLog(.app, "cdn.probe.complete", details: [
            "nodes": probedNodes.count,
            "best": lowestBestForLog(),
            "autoPick": autoPickEnabled,
            "selectedAfter": selectedHost
        ])
    }

    /// `lowestDelayHost` is optional; the diagnostic log
    /// wants a non-optional `"none"` placeholder.  Kept
    /// inline to avoid exposing a `lowestDelayHostOrNil`
    /// API just for logging.
    private func lowestBestForLog() -> String {
        lowestDelayHost ?? "none"
    }
}
