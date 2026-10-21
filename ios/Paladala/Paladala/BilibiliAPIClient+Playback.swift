import Foundation

// UGC playurl (`/x/player/wbi/playurl`) and its DASH/durl payload.

extension BilibiliAPIClient {
    func playbackURL(
        bvid: String,
        aid: Int = 0,
        cid: Int,
        preferredQn: Int = 80,
        preferredAudioQuality: Int = BiliAudioQuality.defaultID
    ) async throws -> BiliPlayback {
        // The current canonical path is `/x/player/wbi/playurl` — the
        // non-wbi alias is being phased out.  The `fnval` bitmask is:
        //   1   = legacy MP4 (returns an empty `durl` for most items
        //         today, which is why `fnval=0/1` produces the
        //         "Playback is unavailable" error).
        //   16  = DASH manifest.
        //   64  = HLS master playlist (what AVPlayer can natively
        //         consume on iOS — increasingly empty for high
        //         quality sources).
        //   4048 = HLS + DASH + MP4 + FLV — the bitmask we use to
        //         ask for "everything at once".  The local HLS
        //         proxy (`LocalHLSProxyServer`) re-serves the DASH
        //         half as HLS over a 127.0.0.1 listener, so we
        //         never have to fall back to a third-party SDK.
        // We then walk a `qn` chain from 1080P down to 360P because
        // the upstream returns an empty `dash` when the requested
        // quality is gated (region lock, VIP paywall, 4K-only
        // source).  Cap at three retries so a misbehaving upstream
        // cannot wedge the device.  `gaia_source=view-card` is the
        // same hint the web player sends — Bilibili loosens the
        // 1080P gate slightly for it.
        let identity: [URLQueryItem]
        if !bvid.isEmpty {
            identity = [URLQueryItem(name: "bvid", value: bvid)]
        } else if aid > 0 {
            identity = [URLQueryItem(name: "avid", value: "\(aid)")]
        } else {
            throw BilibiliAPIError.missingIdentity
        }
        let finalBvid = bvid.isEmpty ? "av\(aid)" : bvid

        // Read the diagnostic-dump flag once per call.  The flag
        // is a UserDefaults Bool that can be flipped from the
        // iOS Settings app (search "paladala.dumpPlayURL") or by
        // the runtime "Run-time flags" panel on the deep
        // diagnostic report screen.  When on, the first
        // playurl response of the session is dumped to the
        // log verbatim (first 4 KB) so we can see exactly
        // which fields the upstream returned and what they're
        // called.  We persist the "dumped" marker back to
        // UserDefaults so a transient network failure on the
        // first attempt doesn't end up dumping all 4 qns.
        let defaults = UserDefaults.standard
        let dumpPlayURLKey = "paladala.dumpPlayURL"
        let dumpPlayURLDoneKey = "paladala.dumpPlayURL.done"
        let dumpPlayURL = defaults.bool(forKey: dumpPlayURLKey)
        let alreadyDumped = defaults.bool(forKey: dumpPlayURLDoneKey)

        // The qn ladder, but reordered so the user's preferred
        // quality is tried first. The remaining ladder entries
        // (lower qualities the user can fall back to when their
        // pick is gated by VIP / region lock) follow in their
        // canonical descending order. If the user picked 360P we
        // don't loop — that already is the bottom of the chain.
        //
        // The chain covers every Bili-published qn from 8K HDR
        // (131) all the way down to 360P smooth (16) — that
        // way a VIP pick on a video that only has 1080P still
        // gets a clean fallback to the highest entry the
        // upstream actually returned.
        //
        // VIP-gated entries (112 / 116 / 120 / 125 / 126 / 127 /
        // 128 / 129 / 130 / 131) are included in the chain so
        // a VIP user's pick flows through naturally; a non-VIP
        // user that somehow lands on a gated qn falls through
        // the chain just like a region-locked pick, ending at
        // the first entry the upstream actually returned.
        let canonicalChain: [Int] = [
            131, // 8K HDR
            130, // 4K HDR
            129, // 4K Hi-Res
            128, // 1080P Hi-Res
            127, // 8K
            126, // Dolby Vision
            125, // HDR
            120, // 4K
            116, // 1080P60
            112, // 1080P+ high bitrate
            80,  // 1080P high
            64,  // 720P high
            32,  // 480P clear
            16   // 360P smooth
        ]
        let qnChain: [Int]
        if let idx = canonicalChain.firstIndex(of: preferredQn) {
            qnChain = Array(canonicalChain[idx...])
        } else if canonicalChain.contains(preferredQn) {
            qnChain = canonicalChain
        } else {
            // Unknown qn (e.g. legacy caller passing a value we
            // don't model) — keep canonical behaviour.
            qnChain = canonicalChain
        }
        var lastError: Error = BilibiliAPIError.missingData
        for qn in qnChain {
            let queryItems: [URLQueryItem] = identity + [
                URLQueryItem(name: "cid", value: "\(cid)"),
                URLQueryItem(name: "qn", value: "\(qn)"),
                // D++: ask for everything; we only consume the
                // DASH branch in `bestPlayback` below.  The
                // legacy `durl` MP4 path is kept as a last-resort
                // fallback in case the upstream refuses to
                // surface DASH for the requested quality.
                URLQueryItem(name: "fnval", value: "4048"),
                URLQueryItem(name: "fnver", value: "0"),
                URLQueryItem(name: "fourk", value: "1"),
                URLQueryItem(name: "gaia_source", value: "view-card")
            ]
            do {
                let payload: APIResponse<PlayURLPayload> = try await get(
                    baseURL: baseURL,
                    path: "/x/player/wbi/playurl",
                    queryItems: queryItems,
                    signWithWBI: true,
                    dumpRawBody: dumpPlayURL && !alreadyDumped,
                    dumpTag: "playurl qn=\(qn) bvid=\(finalBvid)"
                )
                // Persist the "dumped" marker so the next
                // session (or a retry within this session
                // after a transient failure) does not dump
                // again.  Reset by toggling the user-facing
                // flag in Settings.
                if dumpPlayURL && !alreadyDumped {
                    defaults.set(true, forKey: dumpPlayURLDoneKey)
                }
                try payload.requireOK()
                if let playback = payload.value?.bestPlayback(
                    referer: "https://www.bilibili.com/video/\(finalBvid)",
                    preferredAudioQuality: preferredAudioQuality
                ) {
                    return playback
                }
                lastError = BilibiliAPIError.noPlayableFormat
            } catch {
                // Bubble up immediately on identity / network errors so
                // the UI can surface them; only fall through on
                // quality-gated responses.
                if case BilibiliAPIError.missingIdentity = error { throw error }
                if case BilibiliAPIError.http = error { throw error }
                lastError = error
            }
        }
        throw lastError
    }
}

/// One entry in `data.accept_description` returned by
/// `/x/player/playurl`. Used as a fallback label source for
/// `BiliVideoQuality` entries we don't model in the enum
/// ladder. The wire shape is roughly:
///   {
///     "qn": 80,
///     "display": "1080P 高清"
///   }
/// `display` is the user-facing string; B站 sometimes also
/// returns a `description` key (without the trailing `_`)
/// in older PGC responses — we accept both.  All fields are
/// optional so a sparse entry decodes to a usable stub
/// instead of throwing the whole `accept_description` array.
struct AcceptQualityDescription: Decodable, Sendable {
    let qn: Int
    let display: String?

    enum CodingKeys: String, CodingKey {
        case qn
        case display
        // Aliases for the older surfaces / PGC paths.
        case descriptionKey = "description"
        case desc
        case text
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // `qn` is the only mandatory field — without it the
        // entry is meaningless (the menu keys by qn, not by
        // display text).  Throw to drop the whole array on a
        // bad entry rather than silently miss-rendering a row.
        self.qn = try container.decode(Int.self, forKey: .qn)
        self.display = try container.decodeIfPresent(
            String.self, forKey: .display
        ) ?? container.decodeIfPresent(String.self, forKey: .descriptionKey)
            ?? container.decodeIfPresent(String.self, forKey: .desc)
            ?? container.decodeIfPresent(String.self, forKey: .text)
    }
}

struct PlayURLPayload: Decodable, Sendable {
    let durl: [DURL]?
    let dash: Dash?
    /// Native HLS slot surfaced when the request used `fnval &
    /// 64`.  The shape is the same as the legacy `durl` array
    /// (one URL per quality) but B站 has been known to also
    /// serve a single `hls_url` string here.  We accept both —
    /// the only thing the player needs is the master playlist
    /// URL.
    ///
    /// Why this matters:  AVPlayer consumes HLS natively.  When
    /// B站 returns an HLS master, we hand it directly to
    /// `AVURLAsset` with a `Referer` header injection and
    /// `LocalHLSProxyServer` is not involved at all.  When
    /// B站 only returns DASH, the local proxy now exposes the
    /// fMP4 init/media byte ranges as HLS so AVPlayer can parse
    /// the stream without a third-party decoder.
    let hls: [DURL]?
    /// Total media duration in seconds, surfaced at the payload
    /// top level (Bili mirrors it in both the legacy `timelength`
    /// and the DASH `mediaInfo.duration` paths).
    let duration: Double?
    /// The set of video qn values B站 is willing to serve for
    /// this video + this account. Sourced from
    /// `data.accept_quality` (a bare `[Int]`, e.g.
    /// `[16, 32, 64, 80, 112, 116]` for a 1080P60 upload). The
    /// player / quality menu use this to *only* render rows the
    /// upstream actually returns — without it, the menu shows
    /// every ladder entry and tapping 4K on a video that only
    /// has 1080P forces a needless playurl round-trip that
    /// ends in `code -62002` ("请开通大会员") for non-VIP and a
    /// generic failure for VIP. `nil` when the upstream omits
    /// the field (legacy PGC or future API drift) — the menu
    /// falls back to the full ladder in that case so a missing
    /// field is non-fatal.
    let acceptQuality: [Int]?
    /// Human-readable ladder the upstream publishes alongside
    /// `accept_quality`, e.g. `{"qn": 80, "display": "1080P 高清"}`.
    /// Used as a *fallback label* for qn values we don't model
    /// in `BiliVideoQuality` (B站 occasionally rolls a test
    /// ladder and the new qn shows up here before the SwiftUI
    /// menu grows an enum case for it). `nil` when missing —
    /// menu falls through to the bare "<qn>P" formatter.
    let acceptDescription: [AcceptQualityDescription]?
    /// Audio ladder the upstream is willing to serve, sourced
    /// from `data.accept_audio_quality` (a bare `[Int]` of
    /// audio ids — 30216 / 30232 / 30250 / 30280). The audio
    /// quality menu reads this to *only* render rows the
    /// server actually returned; without it, the menu
    /// hard-codes the full 4-step ladder and tapping 320 kbps
    /// Hi-Res on a video that only has 128 kbps AAC forces
    /// a playurl round-trip that ends in a no-track return.
    /// `nil` for legacy PGC / non-DASH responses (which
    /// still surface the menu's full ladder).
    let acceptAudioQuality: [Int]?

    /// Tolerant decoder.  Bilibili serves `hls` and `durl` in
    /// several observed shapes:
    ///   * `hls`: array of `{url, size, length}` (preferred)
    ///   * `hls`: single `{url, ...}` object
    ///   * `hls_url` / `hlsUrl`: bare URL string
    ///   * `h5_url` / `h4_url` / `h3_url`: B站's per-quality
    ///     HLS slots, named after the `qn` ladder.  These are
    ///     bare URL strings, usually `m3u8` master playlists.
    /// We normalise all of them into a `[DURL]?` so the call
    /// sites can use a single `?.first?.url` lookup.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        if let arr = try? container.decode([DURL].self, forKey: DynamicKey("durl")) {
            self.durl = arr
        } else if let single = try? container.decode(DURL.self, forKey: DynamicKey("durl")) {
            self.durl = [single]
        } else {
            self.durl = nil
        }
        if let arr = try? container.decode([DURL].self, forKey: DynamicKey("hls")) {
            self.hls = arr
        } else if let single = try? container.decode(DURL.self, forKey: DynamicKey("hls")) {
            self.hls = [single]
        } else if let s = container.decodeString(keys: [
            "hls_url", "hlsUrl",
            // Per-quality HLS slots observed on B站 playurl
            // responses.  The number after `h` is the qn
            // (e.g. 80 = 1080P, 64 = 720P, 32 = 480P, 16 =
            // 360P).  We accept all of them in priority
            // order — the first non-nil wins.
            "h5_url", "h4_url", "h3_url", "h2_url", "h1_url",
            "h5Url", "h4Url", "h3Url", "h2Url", "h1Url"
        ]), let url = URL(string: s) {
            self.hls = [DURL.fromURL(url)]
        } else {
            self.hls = nil
        }
        self.dash = try? container.decode(Dash.self, forKey: DynamicKey("dash"))
        // B站 publish two top-level fields for the same value:
        //   * `duration` — seconds (modern API)
        //   * `timelength` — milliseconds (legacy, still seen on
        //     some `dash` responses)
        // `decodeDouble(keys:)` reads either key as a raw Double,
        // so reading both as the same unit is the difference
        // between a 60s clip and a 16.7h one.  Decode the seconds
        // field first, fall back to ms / 1000.
        if let seconds = container.decodeDouble(keys: ["duration"]) {
            self.duration = seconds
        } else if let ms = container.decodeDouble(keys: ["timelength"]) {
            self.duration = ms / 1000.0
        } else {
            self.duration = nil
        }
        // `accept_quality` is a bare `[Int]` on the modern
        // surface. We tolerate a missing field (legacy / PGC)
        // and a single-int typo (some testing surfaces emit
        // `80` instead of `[80]`) so one upstream glitch
        // doesn't black-hole the menu.  Integers only —
        // `BiliVideoQuality.rawValue` is `Int`, so anything
        // non-integral would have no consumer.
        if let array = try? container.decode([Int].self, forKey: DynamicKey("accept_quality")) {
            self.acceptQuality = array
        } else if let single = container.decodeInt(keys: ["accept_quality"]) {
            self.acceptQuality = [single]
        } else {
            self.acceptQuality = nil
        }
        self.acceptDescription = try? container.decode(
            [AcceptQualityDescription].self,
            forKey: DynamicKey("accept_description")
        )
        // `accept_audio_quality` shares the wire shape with
        // `accept_quality` (a bare `[Int]` of audio ids). The
        // tolerant single-int fallback below handles the
        // rare testing surfaces that emit `30232` instead of
        // `[30232]`. Same "missing field is non-fatal"
        // semantics — the audio menu falls back to the full
        // ladder so legacy PGC / non-DASH responses still
        // get a usable menu.
        if let array = try? container.decode(
            [Int].self, forKey: DynamicKey("accept_audio_quality")
        ) {
            self.acceptAudioQuality = array
        } else if let single = container.decodeInt(keys: ["accept_audio_quality"]) {
            self.acceptAudioQuality = [single]
        } else {
            self.acceptAudioQuality = nil
        }
    }

    /// D++ path.  Return a `BiliPlayback` even if the upstream
    /// only gives us a single `durl` MP4 — that case falls
    /// through to the legacy direct-URL fallback and the player
    /// uses it with no bridge.
    func bestPlayback(
        referer: String,
        preferredAudioQuality: Int = BiliAudioQuality.defaultID
    ) -> BiliPlayback? {
        let refererURL = URL(string: referer)!
        // Project the upstream `accept_description` into a
        // qn-keyed `[Int: String]` so the quality menu can
        // resolve a label in O(1) without re-walking the
        // array per render. `nil` for the legacy PGC path
        // (the field is missing) or for an empty list (the
        // upstream responded with an empty array — treat as
        // missing). Entries with a nil `display` are dropped
        // here so the menu's "label or fallback" code path
        // is the single point of truth.
        let acceptDescriptionByQn: [Int: String]? = {
            guard let entries = acceptDescription, !entries.isEmpty else { return nil }
            var out: [Int: String] = [:]
            out.reserveCapacity(entries.count)
            for entry in entries {
                if let display = entry.display, !display.isEmpty {
                    out[entry.qn] = display
                }
            }
            return out.isEmpty ? nil : out
        }()

        // `accept_audio_quality` is B站's optional explicit
        // "the audio ladder the upstream is willing to serve"
        // declaration. In practice, **most playurl surfaces
        // (UGC, PGC, fnval variants) omit the field entirely**
        // — the upstream replies with `dash.audio[]` only
        // and the caller has to derive the available ids
        // from each audio track's `id`. Falling through to
        // `nil` would force the audio menu back to the
        // 4-step static ladder (a regression — the menu
        // would happily offer 320 kbps Hi-Res on a video
        // whose dash only has 128 kbps AAC, then fail the
        // refetch). The `dash.audio[].id` projection is a
        // safe fallback: B站 always emits the dash block
        // for DASH responses, and every audio track carries
        // its quality id.
        let resolvedAcceptAudioQuality: [Int]? = {
            if let explicit = acceptAudioQuality, !explicit.isEmpty {
                return explicit
            }
            if let dash = self.dash, !dash.audio.isEmpty {
                let ids = dash.audio.compactMap { $0.id }
                return ids.isEmpty ? nil : Array(Set(ids)).sorted()
            }
            return nil
        }()

        // 1) Prefer the upstream HLS master if B站 gave us one
        //    (fnval & 64).  AVPlayer consumes HLS natively and
        //    we just inject the `Referer` header on the
        //    `AVURLAsset` — no proxy, no synthesised playlist,
        //    no spinning-stall.  This is the path that actually
        //    plays today.
        if let url = hls?.first?.url {
            diagLog(.playback,
                    "Selected HLS playback",
                    details: [
                        "url": url.absoluteString,
                        "hlsCount": hls?.count ?? 0
                    ])
            return BiliPlayback(
                dash: nil,
                fallbackURL: url,
                referer: refererURL,
                acceptQuality: acceptQuality,
                acceptDescription: acceptDescriptionByQn,
                acceptAudioQuality: resolvedAcceptAudioQuality
            )
        }

        // 1.5) Diagnostic breadcrumb: log the response shape we
        //      actually got.  The user has reported multiple
        //      videos returning DASH but no HLS — knowing which
        //      fields were present (and which were absent) is
        //      the difference between "decoder missed a key" and
        //      "B站 never returned HLS for this qn".
        diagLog(.playback,
                "playurl response shape",
                details: [
                    "hasDash": dash != nil,
                    "hasDurl": (durl?.isEmpty ?? true) == false,
                    "hasHls": (hls?.isEmpty ?? true) == false,
                    "dashVideoCount": dash?.video.count ?? 0,
                    "dashAudioCount": dash?.audio.count ?? 0,
                    "durlCount": durl?.count ?? 0,
                    "acceptQuality": acceptQuality ?? [],
                    "acceptDescriptionCount": acceptDescription?.count ?? 0,
                    "acceptAudioQuality": resolvedAcceptAudioQuality ?? []
                ])

        // 2) DASH path.  B站 ships DASH manifests for 1080P+
        //    and most modern sources.  The loopback HLS proxy
        //    re-serves the DASH fMP4 tracks with `EXT-X-MAP`
        //    init sections and byte-range shifted media
        //    requests, which is the AVPlayer-compatible path
        //    when no upstream HLS master is present.
        if let dashSource = dash?.biliDashSource(duration: duration) {
            diagLog(.playback,
                    "Selected DASH playback",
                    details: [
                        "videoCount": dash?.video.count ?? 0,
                        "audioCount": dash?.audio.count ?? 0,
                        "videoCodecs":
                            dash?.video.map { $0.codecs }.joined(separator: ",") ?? "",
                        "audioCodecs":
                            dash?.audio
                                .compactMap { $0.codecs }
                                .joined(separator: ",") ?? "",
                        "videoCodec": dashSource.video.codecs,
                        "audioCodec": dashSource.audio?.codecs ?? "",
                        "videoBandwidth": dashSource.video.bandwidth,
                        "hasVideoInit": true,
                        "hasAudioInit": dashSource.audio != nil,
                        "hlsAvailable": false
                    ])
            return BiliPlayback(
                dash: dashSource,
                fallbackURL: nil,
                referer: refererURL,
                acceptQuality: acceptQuality,
                acceptDescription: acceptDescriptionByQn,
                acceptAudioQuality: resolvedAcceptAudioQuality
            )
        }
        // Diagnose why DASH was unusable.  This shows up in
        // the diagnostic export and is the difference between
        // "the qn we asked for only ships HEVC" and "no
        // AVC track at this qn at all" and so on.  We log
        // even when the proxy is going to be the path —
        // useful when comparing qn=80 vs qn=64 across
        // different videos.
        if let dash, dash.biliDashSource(duration: duration) == nil {
            diagLog(.playback,
                    "DASH rejected by AVPlayer-compat filter",
                    details: [
                        "videoCount": dash.video.count,
                        "audioCount": dash.audio.count,
                        "videoCodecs":
                            dash.video.map { $0.codecs }.joined(separator: ","),
                        "audioCodecs":
                            dash.audio
                                .compactMap { $0.codecs }
                                .joined(separator: ","),
                        "hasVideoInit":
                            dash.video.contains {
                                $0.segmentBase?.initializationByteRange != nil
                            },
                        "hasAudioInit":
                            dash.audio.contains {
                                $0.segmentBase?.initializationByteRange != nil
                            }
                    ])
        }

        // 3) Fall back to the legacy `durl` MP4 when the upstream
        //    returned no DASH and no HLS.  This is rarer every
        //    year, but the Web preview endpoints sometimes
        //    still surface it.
        if let url = durl?.first?.url {
            diagLog(.playback,
                    "Selected legacy durl MP4",
                    details: ["url": url.absoluteString])
            return BiliPlayback(
                dash: nil,
                fallbackURL: url,
                referer: refererURL,
                acceptQuality: acceptQuality,
                acceptDescription: acceptDescriptionByQn,
                acceptAudioQuality: resolvedAcceptAudioQuality
            )
        }
        return nil
    }

    struct DURL: Decodable {
        /// Tolerant decoder:  B站 writes `durl` entries as
        /// `{url, size, length, ...}` but the HLS slot
        /// occasionally surfaces just a string.  Accept both
        /// so the same struct can decode the two response
        /// shapes.
        let url: URL

        /// Manual memberwise init.  Adding the custom
        /// `init(from decoder:)` below suppresses Swift's
        /// synthesised memberwise init, so we declare it
        /// explicitly for the `fromURL(_:)` factory path.
        init(url: URL) { self.url = url }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let s = try? container.decode(String.self),
               let u = URL(string: s) {
                self.url = u
            } else {
                let nested = try decoder.container(keyedBy: DynamicKey.self)
                guard let s = nested.decodeString(keys: ["url", "backup_url", "base_url"]) else {
                    throw DecodingError.dataCorruptedError(
                        in: container,
                        debugDescription: "DURL: missing url field"
                    )
                }
                guard let u = URL(string: s) else {
                    throw DecodingError.dataCorruptedError(
                        in: container,
                        debugDescription: "DURL: not a valid URL: \(s)"
                    )
                }
                self.url = u
            }
        }

        /// Factory used by `PlayURLPayload.init(from:)` to
        /// wrap a bare URL discovered under `hls_url` etc.
        static func fromURL(_ u: URL) -> DURL {
            DURL(url: u)
        }
    }

    struct Dash: Decodable {
        let video: [DashVideo]
        let audio: [DashMedia]
        /// The DASH manifest's own duration field, in milliseconds.
        /// Bilibili writes it next to the AdaptationSets.  We
        /// divide by 1000 to get seconds for the HLS master.
        let duration: Double?
        /// `minBufferTime`, used as a hint for EXT-X-TARGETDURATION
        /// when the segment count is not exposed.  Bilibili
        /// writes this as a number (e.g. `1.5`), not a string,
        /// even though the legacy MPD spec called for a duration
        /// string.  Decode it as `Double?` so the manifest
        /// round-trips; the value is currently unused downstream
        /// (`bestPlayback` only consults `video` / `audio` /
        /// `duration`), but we keep the field so the JSON
        /// decoder doesn't blow up on a future API change.
        let minBufferTime: Double?

        enum CodingKeys: String, CodingKey {
            case video, audio, duration
            case minBufferTime = "minBufferTime"
        }

        /// Translate the parsed MPD-shaped DTO into the flat
        /// `BiliDashSource` the local HLS proxy wants.  Picking
        /// the "preferred" video is the same rule the previous
        /// `bestPlayback` used: prefer `avc1` (H.264) so the
        /// synthesised HLS master does not have to carry H.265
        /// in the CODECS attribute (AVPlayer does support `hvc1`
        /// in fMP4 segments, but AVC keeps the battery cooler).
        ///
        /// AVPlayer compatibility filter (2026-06):
        ///   * Video: only accept `avc1` (H.264) tracks.  HEVC
        ///     (`hev1` / `hvc1`) is rejected by AVPlayer on A9
        ///     and older chips, and even on newer devices its
        ///     software fallback for fMP4 HLS is unreliable.  If
        ///     the upstream only ships HEVC for the requested
        ///     quality, we return `nil` so `bestPlayback` can
        ///     try the `durl` MP4 fallback (which is AVC
        ///     muxed).
        ///   * Audio: only accept AAC (`mp4a.*`).  B站's
        ///     premium tracks ship EAC3 (`ec-3`) or Hi-Res
        ///     FLAC; AVPlayer will decode EAC3 from a
        ///     standalone `.m4a` but not from a fragmented
        ///     MP4 in an HLS segment, and refuses FLAC
        ///     outright.  Within the AAC pool we honour the
        ///     user's preferred audio quality id (30216/30232/
        ///     30250/30280) when present, then fall back to the
        ///     highest-bandwidth AAC track.  EAC3/FLAC/Opus
        ///     tracks are still dropped.
        func biliDashSource(
            duration: Double?,
            preferredAudioQuality: Int = BiliAudioQuality.defaultID
        ) -> BiliDashSource? {
            let avcVideo = video.first { v in
                v.codecs.localizedCaseInsensitiveContains("avc")
                    || v.codecs.localizedCaseInsensitiveContains("h264")
            }
            guard let v = avcVideo,
                  let videoInit = v.segmentBase?.effectiveInitializationByteRange else {
                return nil
            }
            // Filter to AAC tracks first so non-AAC tracks
            // never win regardless of the user's preference.
            let aacTracks = audio.filter { a in
                guard let c = a.codecs else { return false }
                return c.localizedCaseInsensitiveContains("mp4a")
                    || c.localizedCaseInsensitiveContains("aac")
            }
            // Preferred id wins when present in the AAC pool.
            // Falls back to the highest-bandwidth AAC track so
            // the user gets the best available audio even if
            // their pick is gated (typical when non-VIP tries
            // to play a 320 kbps video).
            let chosenAudio: DashMedia? = {
                if let match = aacTracks.first(where: { $0.id == preferredAudioQuality }) {
                    return match
                }
                return aacTracks.max(by: { ($0.bandwidth ?? 0) < ($1.bandwidth ?? 0) })
            }()
            // If a non-AAC audio is the *only* audio available,
            // we have to drop audio entirely — AVPlayer will
            // refuse the manifest otherwise.  Muxed MP4 would
            // not have this problem but we are on the DASH path.
            let audioTrack: (
                media: DashMedia,
                initRange: BiliDashSource.ByteRange
            )?
            if let chosenAudio,
               let audioInit = chosenAudio.segmentBase?.effectiveInitializationByteRange {
                audioTrack = (chosenAudio, audioInit)
            } else {
                audioTrack = nil
            }
            // `dash.duration` is published in *milliseconds* by
            // Bili (a legacy of the original MPD spec); the
            // playurl top-level `duration` (when present) is in
            // *seconds*.  Try the top-level first, fall back to
            // ms/1000, and ultimately to 0.
            let totalDuration: Double
            if let d = duration, d > 0 {
                totalDuration = d
            } else if let dashMs = self.duration, dashMs > 0 {
                totalDuration = dashMs / 1000.0
            } else {
                totalDuration = 0
            }

            return BiliDashSource(
                video: .init(
                    baseURL: v.baseURL,
                    backupURLs: v.backupURLs,
                    codecs: v.codecs,
                    bandwidth: v.bandwidth ?? 0,
                    mimeType: "video/mp4",
                    initializationRange: videoInit,
                    indexRange: v.segmentBase?.indexByteRange,
                    mediaStartOffset:
                        v.segmentBase?.mediaStartOffset(after: videoInit)
                            ?? videoInit.endOffset + 1,
                    totalDuration: totalDuration,
                    width: v.width,
                    height: v.height,
                    // The video `id` matches the `accept_quality`
                    // ladder (16/32/64/80/...) — used by
                    // `BiliPlayback.selectedVideoQn` so the
                    // quality menu can check the currently-
                    // playing row when the user re-opens it
                    // mid-playback. `nil` for legacy responses
                    // that omit the field.
                    qualityId: v.id
                ),
                audio: audioTrack.map { item in
                    let audio = item.media
                    let audioInit = item.initRange
                    return BiliDashSource.Track(
                        baseURL: audio.baseURL,
                        backupURLs: audio.backupURLs,
                        codecs: audio.codecs ?? "mp4a.40.2",
                        bandwidth: audio.bandwidth ?? 0,
                        mimeType: "audio/mp4",
                        initializationRange: audioInit,
                        indexRange: audio.segmentBase?.indexByteRange,
                        mediaStartOffset:
                            audio.segmentBase?.mediaStartOffset(after: audioInit)
                                ?? audioInit.endOffset + 1,
                        totalDuration: totalDuration,
                        width: nil,
                        height: nil,
                        // Audio `id` is the audio-quality ladder
                        // (30216 / 30232 / 30250 / 30280). The
                        // audio menu uses this to render the
                        // checkmark on the currently-playing
                        // row after the user dismisses and
                        // re-opens the menu.
                        qualityId: audio.id
                    )
                }
            )
        }
    }

    struct DashVideo: Decodable {
        let baseURL: URL
        /// CDN failover URLs.  B站 returns 1–3 backups per
        /// Representation (see `bilibili-API-collect` docs —
        /// `backup_url` / `backupUrl`).  Order is upstream's
        /// preference; the proxy walks them on failover.
        let backupURLs: [URL]
        let codecs: String
        /// Bandwidth in bits/second.  Bili writes the integer
        /// `bandwidth` per Representation.
        let bandwidth: Int?
        /// DASH byte-range metadata. Bili's playurl response
        /// exposes the init section and segment index here so
        /// the local HLS proxy can serve valid fMP4 playlists
        /// without fetching a separate MPD.
        let segmentBase: SegmentBase?
        let width: Int?
        let height: Int?
        /// Representation id matching the `accept_quality` ladder
        /// (16/32/64/80/112/116/120/125/126/127/128/129/130/131).
        /// `nil` for legacy responses that omit the field — the
        /// quality menu then falls back to the `BiliPlayback.
        /// preferredQn` published state.
        let id: Int?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)
            guard let rawURL = container.decodeString(keys: [
                "baseUrl", "base_url", "url"
            ]), let url = URL(string: rawURL) else {
                throw DecodingError.dataCorruptedError(
                    forKey: DynamicKey("baseUrl"),
                    in: container,
                    debugDescription: "DashVideo: missing base URL"
                )
            }
            baseURL = url
            // Both key casings per the bilibili-API-collect
            // spec.  Each entry must be a parseable URL — we
            // drop malformed ones rather than failing the
            // whole decode so a single typo from upstream
            // doesn't black-hole playback.
            let rawBackups = container.decodeStringArray(keys: [
                "backupUrl", "backup_url"
            ]) ?? []
            backupURLs = rawBackups.compactMap { URL(string: $0) }
            codecs = container.decodeString(keys: ["codecs"]) ?? ""
            bandwidth = container.decodeInt(keys: ["bandwidth"])
            width = container.decodeInt(keys: ["width"])
            height = container.decodeInt(keys: ["height"])
            // `id` is optional; some legacy / PGC responses
            // omit it. `decodeInt` already treats a missing
            // key as `nil`, so a sparse entry here is benign
            // (the menu's fallback path is the BiliPlayback's
            // own `preferredQn`).
            id = container.decodeInt(keys: ["id"])
            segmentBase =
                (try? container.decode(SegmentBase.self,
                                       forKey: DynamicKey("SegmentBase")))
                ?? (try? container.decode(SegmentBase.self,
                                          forKey: DynamicKey("segment_base")))
        }
    }

    struct DashMedia: Decodable {
        let baseURL: URL
        let backupURLs: [URL]
        let codecs: String?
        let bandwidth: Int?
        /// Representation id published by Bili's playurl. For
        /// audio tracks this is the audio-quality ladder id
        /// (30216 / 30232 / 30250 / 30280); for video tracks it
        /// matches `accept_quality` (16/32/64/80/...). `nil`
        /// when the upstream omits the field (legacy responses).
        let id: Int?
        let segmentBase: SegmentBase?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)
            guard let rawURL = container.decodeString(keys: [
                "baseUrl", "base_url", "url"
            ]), let url = URL(string: rawURL) else {
                throw DecodingError.dataCorruptedError(
                    forKey: DynamicKey("baseUrl"),
                    in: container,
                    debugDescription: "DashMedia: missing base URL"
                )
            }
            baseURL = url
            let rawBackups = container.decodeStringArray(keys: [
                "backupUrl", "backup_url"
            ]) ?? []
            backupURLs = rawBackups.compactMap { URL(string: $0) }
            codecs = container.decodeString(keys: ["codecs"])
            bandwidth = container.decodeInt(keys: ["bandwidth"])
            id = container.decodeInt(keys: ["id"])
            segmentBase =
                (try? container.decode(SegmentBase.self,
                                       forKey: DynamicKey("SegmentBase")))
                ?? (try? container.decode(SegmentBase.self,
                                          forKey: DynamicKey("segment_base")))
        }
    }

    struct SegmentBase: Decodable {
        /// Average segment duration in seconds.  Bilibili writes
        /// a single number here (e.g. 1.984) for fMP4 VOD.
        let duration: Double?
        /// `timescale` for `t`/`d` — the MPD spec writes integers
        /// in `timescale` units.  Bili uses 1000 or 1000000.
        let timescale: Int?
        /// Byte range for the fMP4 initialization section, usually
        /// written as `"0-821"`.
        let initialization: String?
        /// Byte range for the DASH segment index (`sidx`). The
        /// playable media data starts immediately after this range.
        let indexRange: String?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)
            duration = container.decodeDouble(keys: ["duration"])
            timescale = container.decodeInt(keys: ["timescale"])
            initialization = container.decodeString(keys: [
                "Initialization", "initialization"
            ])
            indexRange = container.decodeString(keys: [
                "indexRange", "index_range"
            ])
        }

        var initializationByteRange: BiliDashSource.ByteRange? {
            Self.byteRange(from: initialization)
        }

        var indexByteRange: BiliDashSource.ByteRange? {
            Self.byteRange(from: indexRange)
        }

        /// Byte range to serve in the fMP4 init response.
        /// B站's m4s layout is `ftyp` + `moov` + `sidx`
        /// + `styp` + `moof` + `mdat`, with the `sidx`
        /// (Segment Index Box) sitting between the init
        /// section and the playable data.  AVPlayer wants
        /// the `sidx` inside the init response (it is the
        /// HLS fMP4 convention — Apple's authoring spec
        /// requires `sidx` in the init segment).  Serving
        /// `sidx` at the start of the media response makes
        /// AVPlayer abort with `CoreMediaError -19602`,
        /// so we extend the init range through the
        /// `sidx` here.
        var effectiveInitializationByteRange: BiliDashSource.ByteRange? {
            guard let initR = initializationByteRange else { return nil }
            guard let idxR = indexByteRange,
                  idxR.endOffset > initR.endOffset else {
                return initR
            }
            return BiliDashSource.ByteRange(
                offset: initR.offset,
                length: idxR.endOffset - initR.offset + 1
            )
        }

        /// Byte offset where the playable media segment begins
        /// in the upstream m4s file.  With
        /// `effectiveInitializationByteRange` extending the
        /// init response through the `sidx`, this is just
        /// one past the end of the init range.
        func mediaStartOffset(
            after initRange: BiliDashSource.ByteRange
        ) -> Int64 {
            return initRange.endOffset + 1
        }

        private static func byteRange(
            from raw: String?
        ) -> BiliDashSource.ByteRange? {
            guard let raw else { return nil }
            let parts = raw.split(separator: "-", maxSplits: 1)
            guard parts.count == 2,
                  let start = Int64(parts[0]),
                  let end = Int64(parts[1]),
                  end >= start else {
                return nil
            }
            return BiliDashSource.ByteRange(
                offset: start,
                length: end - start + 1
            )
        }
    }
}
