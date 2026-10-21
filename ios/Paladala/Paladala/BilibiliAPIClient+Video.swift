import Foundation

// Video detail, AI summary, related videos, subtitles/lyrics, and
// viewer actions (like, coin, watch later, history report).

extension BilibiliAPIClient {
    /// Report playback progress to Bilibili's history endpoint so the
    /// watch shows up under the user's "历史记录" list and feeds the
    /// "继续播放" recommendation algorithm. Without this call the
    /// video plays normally but Bilibili treats the user as a
    /// visitor — a behaviour the user explicitly flagged in
    /// `MINIMAX_INSTRUCTIONS.md` §2 ("History Reporting"). The
    /// `progress` field is the current playhead in seconds and is
    /// the same value Bilibili uses to compute "看完"/"看到一半" in
    /// the history list, so accuracy matters for the resume UX.
    ///
    /// `aid` and `cid` are both required. `csrf` is auto-extracted
    /// from the active account's `bili_jct` cookie by the underlying
    /// `post(...)` helper — no need to plumb it through. `platform`
    /// and `mobi_app` are pinned to the iOS app identity so the
    /// upstream records the report as coming from the official iOS
    /// client (the only client where the history is fully visible).
    func reportHistory(aid: Int, cid: Int, progress: Int) async throws {
        let params: [String: String] = [
            "aid": "\(aid)",
            "cid": "\(cid)",
            // `progress` is in seconds. Bilibili rounds down internally
            // and clamps to the media length, so passing 0 is the
            // canonical "video just started" signal.
            "progress": "\(max(0, progress))",
            "platform": "ios",
            "mobi_app": "iphone",
            // No `type` field — the official iOS client doesn't send
            // one and adding it triggers `code=-101` "参数错误" on
            // some accounts.
        ]
        let payload: APIResponse<EmptyPayload> = try await post(
            baseURL: baseURL,
            path: "/x/v2/history/report",
            parameters: params
        )
        try payload.requireOK()
    }

    /// Append a video to the user's "稍后再看" (Watch Later) list.
    /// Mirrors the official iOS client's `/x/v2/history/toview/add`
    /// call. Requires CSRF; the existing `post(...)` helper
    /// auto-extracts `bili_jct` from the cookie. Returns silently
    /// on success; throws on a typed API error so the caller can
    /// surface a toast.
    func addToWatchLater(aid: Int) async throws {
        let payload: APIResponse<EmptyPayload> = try await post(
            baseURL: baseURL,
            path: "/x/v2/history/toview/add",
            parameters: [
                "aid": "\(aid)",
                "platform": "ios",
                "mobi_app": "iphone"
            ]
        )
        try payload.requireOK()
    }

    /// Remove a video from the user's "稍后再看" list. Symmetric
    /// counterpart to `addToWatchLater`. Used by the destructive
    /// option in the long-press context menu.
    func removeFromWatchLater(aid: Int) async throws {
        let payload: APIResponse<EmptyPayload> = try await post(
            baseURL: baseURL,
            path: "/x/v2/history/toview/del",
            parameters: [
                "aid": "\(aid)",
                "platform": "ios",
                "mobi_app": "iphone"
            ]
        )
        try payload.requireOK()
    }

    /// Like (or unlike) a video. The Bilibili "thumbs up" endpoint is
    /// `/x/v2/view/like`; `action=1` likes, `action=2` clears the
    /// like. CSRF required (auto-extracted by `post`). The call
    /// returns the current like count via `data.like` on the
    /// response, but we don't surface that here — the UI just
    /// shows the heart animation and refreshes the stat on the
    /// next detail load.
    func likeVideo(aid: Int, action: Int) async throws {
        let payload: APIResponse<EmptyPayload> = try await post(
            baseURL: baseURL,
            path: "/x/v2/view/like",
            parameters: [
                "aid": "\(aid)",
                "like": "\(action)",
                "platform": "ios",
                "mobi_app": "iphone"
            ]
        )
        try payload.requireOK()
    }

    /// Fetch the signed-in user's 硬币 (coin) balance. Hits the
    /// account service's `/site/getCoin`, which returns the balance
    /// under `data.money`. Requires a SESSDATA cookie; anonymously
    /// the upstream answers code -101 which `requireOK()` surfaces
    /// as a typed error the caller collapses to "please sign in".
    func coinBalance() async throws -> Double {
        let payload: APIResponse<CoinWalletPayload> = try await get(
            baseURL: accountBaseURL,
            path: "/site/getCoin",
            queryItems: []
        )
        try payload.requireOK()
        return payload.value?.money ?? 0
    }

    /// Give (投币) `multiply` coins to a video. `multiply` is 1 or 2
    /// (Bilibili caps a single video at 2 coins per user). When
    /// `alsoLike` is true the same call also likes the video, matching
    /// the official client's "投币并点赞". CSRF is auto-extracted by
    /// `post`. On failure the upstream message (e.g. 硬币余额不足,
    /// 超过投币上限) is thrown via `BilibiliAPIError.api` so the caller
    /// can show exactly why the coin was rejected.
    func addCoins(aid: Int, multiply: Int = 1, alsoLike: Bool = false) async throws {
        let payload: APIResponse<EmptyPayload> = try await post(
            baseURL: baseURL,
            path: "/x/web-interface/coin/add",
            parameters: [
                "aid": "\(aid)",
                "multiply": "\(max(1, min(2, multiply)))",
                "select_like": alsoLike ? "1" : "0",
                "platform": "ios",
                "mobi_app": "iphone"
            ]
        )
        try payload.requireOK()
    }

    /// Fetch all AI-generated / human-submitted subtitle tracks for a video.
    /// Hits the public `/x/player/wbi/v2` endpoint and returns the
    /// `subtitle.subtitles[]` metadata. The caller chooses the preferred
    /// language and then fetches `subtitle_url`.
    ///
    /// The shape of `subtitle_url` is `//aisubtitle.hdslb.com/...`
    /// — a protocol-relative JSON document that the caller
    /// (`videoSubtitleText(info:)`) fetches and parses.
    func videoSubtitleInfos(bvid: String = "", aid: Int = 0, cid: Int) async throws -> [BiliLyricInfo] {
        guard cid > 0 else { return [] }
        var queryItems = [
            URLQueryItem(name: "cid", value: "\(cid)")
        ]
        if !bvid.isEmpty {
            queryItems.append(URLQueryItem(name: "bvid", value: bvid))
        }
        if aid > 0 {
            queryItems.append(URLQueryItem(name: "aid", value: "\(aid)"))
        }
        let payload: APIResponse<LyricInfoPayload> = try await get(
            baseURL: baseURL,
            path: "/x/player/wbi/v2",
            queryItems: queryItems,
            signWithWBI: true
        )
        try payload.requireOK()
        guard let subtitles = payload.value?.subtitle?.subtitles else {
            return []
        }
        return subtitles.map(\.model).filter { !$0.subtitleURL.isEmpty }
    }

    /// Pick the best subtitle track for app playback. Prefer
    /// Simplified Chinese, fall back to any Chinese variant, then the
    /// first available language.
    func videoSubtitleInfo(bvid: String = "", aid: Int = 0, cid: Int) async throws -> BiliLyricInfo? {
        let subtitles = try await videoSubtitleInfos(bvid: bvid, aid: aid, cid: cid)
        // Prefer Simplified Chinese — the rest of the app surfaces
        // Simplified-Chinese copy as the default. Fall back to
        // any Chinese variant, then the first available track.
        if let sc = subtitles.first(where: { $0.lan == "zh-CN" || $0.lan == "zh-Hans" || $0.lan == "ai-zh" }) {
            return sc
        }
        if let tc = subtitles.first(where: { $0.lan.hasPrefix("zh") }) {
            return tc
        }
        return subtitles.first
    }

    /// Backwards-compatible Music API wrapper. Music still names this
    /// "lyric" because the view renders the same timed text as scrolling
    /// lyrics.
    func videoLyricInfo(bvid: String = "", aid: Int = 0, cid: Int) async throws -> BiliLyricInfo? {
        try await videoSubtitleInfo(bvid: bvid, aid: aid, cid: cid)
    }

    /// Fetch the raw subtitle JSON for a `subtitle_url` returned by
    /// `videoSubtitleInfo(cid:)`. B站 serves two distinct timed-text
    /// encodings on the same endpoint:
    ///   * `application/json` — `{ "body": [{from, to, content}, …] }`
    ///   * `text/plain`        — LRC text (`[mm:ss.xx]lyric`)
    /// We sniff the first non-whitespace byte to pick a parser.
    func videoSubtitleText(info: BiliLyricInfo) async throws -> String {
        guard let url = info.absoluteURL else {
            throw BilibiliAPIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("https://www.bilibili.com", forHTTPHeaderField: "Referer")
        request.setValue(DeviceInfo.shared.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            bpLog("Lyric fetch failed with HTTP \(status): \(url.absoluteString)")
            throw BilibiliAPIError.http
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw BilibiliAPIError.missingData
        }
        return text
    }

    /// Backwards-compatible Music API wrapper.
    func videoLyricText(info: BiliLyricInfo) async throws -> String {
        try await videoSubtitleText(info: info)
    }

    func videoDetail(bvid: String, aid: Int = 0) async throws -> BiliVideo {
        var queryItems: [URLQueryItem] = []
        if !bvid.isEmpty {
            queryItems.append(URLQueryItem(name: "bvid", value: bvid))
        } else if aid > 0 {
            queryItems.append(URLQueryItem(name: "aid", value: "\(aid)"))
        } else {
            throw BilibiliAPIError.missingIdentity
        }

        let payload: APIResponse<VideoDTO> = try await get(
            baseURL: baseURL,
            path: "/x/web-interface/view",
            queryItems: queryItems
        )
        try payload.requireOK()
        guard let detail = payload.value?.model else {
            throw BilibiliAPIError.missingData
        }
        return detail
    }

    /// Fetch Bilibili's official "AI 视频总结" (AI 小助手) for a video.
    /// Hits `/x/web-interface/view/conclusion/get` with WBI signing.
    ///
    /// The endpoint returns `data.model_result.{summary, outline}` for
    /// videos that have an AI summary yet, and one of several
    /// non-zero codes otherwise:
    ///   - -101   : user is not logged in (anonymous)
    ///   - -352   : 风控 (rate-limit / wind-control)
    ///   - -403   : `up_mid` does not match the owner of `bvid`
    ///   - other  : eligibility / content gating
    ///
    /// We deliberately do NOT throw on non-zero codes — the
    /// upstream returns a fully-formed error envelope (code +
    /// message + `ttl`), not a real HTTP error, and the ViewModel
    /// treats every non-success as "no summary to show". We throw
    /// only on actual network / decode failures (which the ViewModel
    /// also collapses to "no summary" via its catch path).
    ///
    /// Required query parameters:
    ///   - `bvid` (preferred) or `aid` — the video identity
    ///   - `cid`                       — the active page cid
    ///   - `up_mid`                    — the owner's Bilibili mid
    ///
    /// `up_mid` is required by Bilibili's WBI rate-limiter; sending
    /// it mismatched causes -403, omitting it is more aggressively
    /// rate-limited. The repository wrapper short-circuits when
    /// `ownerMid == 0` (the feed-entry shape), so this method is
    /// never called with an unknown owner mid in practice.
    func aiSummary(bvid: String, aid: Int = 0, cid: Int, upMid: Int64) async throws -> BiliAISummary? {
        var queryItems: [URLQueryItem] = []
        if !bvid.isEmpty {
            queryItems.append(URLQueryItem(name: "bvid", value: bvid))
        } else if aid > 0 {
            queryItems.append(URLQueryItem(name: "aid", value: "\(aid)"))
        } else {
            throw BilibiliAPIError.missingIdentity
        }
        if cid > 0 {
            queryItems.append(URLQueryItem(name: "cid", value: "\(cid)"))
        }
        if upMid > 0 {
            queryItems.append(URLQueryItem(name: "up_mid", value: "\(upMid)"))
        }

        let payload: APIResponse<BiliAISummaryPayload> = try await get(
            baseURL: baseURL,
            path: "/x/web-interface/view/conclusion/get",
            queryItems: queryItems,
            signWithWBI: true
        )

        // Non-zero code → "no summary". Log so the diagnostic
        // report shows which video failed and why (very useful
        // when a user's device keeps returning -352 because
        // they are behind a captive portal or similar).
        if let code = payload.code, code != 0 {
            diagLog(.playback, "AI summary endpoint returned non-zero code",
                    details: [
                        "bvid": bvid,
                        "code": code,
                        "message": payload.message ?? ""
                    ])
            return nil
        }
        return payload.value?.modelResult
    }

    /// Fetch the videos Bilibili recommends for `bvid`. The
    /// upstream endpoint `/x/web-interface/archive/related` powers
    /// the "相关推荐" rail at the bottom of every Bilibili video
    /// page on the web. Returns up to ~40 items; we don't
    /// paginate — the rail is short and the upstream doesn't
    /// expose a cursor.
    ///
    /// `bvid.isEmpty` callers short-circuit to an empty list so
    /// the recommendation surface degrades gracefully on aid-only
    /// `BiliVideo` rows (e.g. URL-scheme intents that didn't
    /// resolve a bvid).
    func relatedVideos(bvid: String) async throws -> [BiliVideo] {
        guard !bvid.isEmpty else { return [] }
        let payload: APIResponse<VideoListPayload> = try await get(
            baseURL: baseURL,
            path: "/x/web-interface/archive/related",
            queryItems: [URLQueryItem(name: "bvid", value: bvid)]
        )
        try payload.requireOK()
        return payload.value?.videos.map(\.model) ?? []
    }
}

/// `data.money` from `/site/getCoin` — the signed-in user's coin balance.
private struct CoinWalletPayload: Decodable, Sendable {
    let money: Double
}

/// Internal decoder for the AI 视频总结 endpoint. Mirrors the
/// `data.model_result.{summary, outline}` envelope. `model_result`
/// is sometimes `null` on the wire (videos with no AI summary yet)
/// and the shape is also absent on older endpoint versions, so
/// every field is optional via a hand-rolled `init(from:)`.
///
/// The encoder on the Bili side has been observed to omit the
/// `part_outline` key when the video only has prose (no outline
/// chapters) and to omit the `subtitle` key on older sessions
/// entirely. Both decode paths default to an empty array so
/// downstream consumers can rely on `outline` / `subtitle` never
/// being `nil`.
private struct BiliAISummaryPayload: Decodable, Sendable {
    let modelResult: BiliAISummary?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        modelResult = try? container.decode(BiliAISummary.self, forKey: DynamicKey("model_result"))
    }
}

// MARK: - Music / Lyric payload shapes
//
// `/x/player/v2` returns a deeply-nested `data.subtitle.subtitles[]`
// envelope. We accept it via a hand-rolled `init(from:)` rather than
// a `Codable` struct because the upstream occasionally omits the
// `author` block (older video, no AI subtitle yet) and the Swift
// decoder will reject the whole payload if any nested key is
// missing. The shape of interest is just the per-track metadata
// (lan / lan_doc / subtitle_url / id) — we discard the rest.

private struct LyricInfoPayload: Decodable, Sendable {
    let subtitle: LyricSubtitleEnvelope?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        subtitle = try? container.decode(LyricSubtitleEnvelope.self, forKey: DynamicKey("subtitle"))
    }
}

private struct LyricSubtitleEnvelope: Decodable, Sendable {
    let subtitles: [LyricTrackDTO]
}

private struct LyricTrackDTO: Decodable, Sendable {
    let id: Int64
    let lan: String
    let lanDoc: String
    let subtitleURL: String
    let author: LyricAuthorDTO?

    enum CodingKeys: String, CodingKey {
        case id
        case lan
        case lanDoc = "lan_doc"
        case subtitleURL = "subtitle_url"
        case author
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        id = container.decodeInt64(keys: ["id"]) ?? 0
        lan = container.decodeString(keys: ["lan"]) ?? ""
        lanDoc = container.decodeString(keys: ["lan_doc", "lanDoc"]) ?? ""
        subtitleURL = container.decodeString(keys: ["subtitle_url", "subtitleUrl"]) ?? ""
        author = try? container.decode(LyricAuthorDTO.self, forKey: DynamicKey("author"))
    }

    var model: BiliLyricInfo {
        BiliLyricInfo(
            id: id,
            lan: lan,
            lanDoc: lanDoc,
            subtitleURL: subtitleURL,
            author: author?.name
        )
    }
}

private struct LyricAuthorDTO: Decodable, Sendable {
    let name: String?
}
