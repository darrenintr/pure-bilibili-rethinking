import Foundation

// Home feeds: web/app recommendations, popular, ranking, region, shorts.

extension BilibiliAPIClient {
    func recommendedVideos(freshIndex: Int = 0) async throws -> [BiliVideo] {
        let hasCookie = await currentCookieHeader() != nil
        diagLog(.recommendation, "Fetching recommended videos", details: ["hasCookie": hasCookie, "freshIndex": freshIndex])
        
        // [FIX] Always use the Web Recommendation API even when logged in.
        // The App API requires an access_token which the native iOS version
        // (currently Web QR login only) does not capture. The Web API
        // correctly uses cookies to provide personalized results.
        diagLog(.recommendation, "Using Web RCMD API (personalized via cookies if present)")
        let payload: APIResponse<VideoListPayload> = try await get(
            baseURL: baseURL,
            path: "/x/web-interface/wbi/index/top/feed/rcmd",
            queryItems: [
                URLQueryItem(name: "ps", value: "20"),
                URLQueryItem(name: "fresh_type", value: "4"),
                URLQueryItem(name: "fresh_idx", value: "\(freshIndex)"),
                URLQueryItem(name: "feed_version", value: "V8"),
                URLQueryItem(name: "web_location", value: "1430650"),
                URLQueryItem(name: "y_num", value: "\(freshIndex)")
            ],
            signWithWBI: true
        )
        try payload.requireOK()
        let videos = payload.value?.videos.compactMap(\.validModel) ?? []
        diagLog(.recommendation, "Web RCMD API success", details: ["count": videos.count])
        return videos
    }

    func appRecommendedVideos(freshIndex: Int = 0, isRefresh: Bool = true) async throws -> [BiliVideo] {
        diagLog(.recommendation, "Starting App Recommended fetch", details: ["freshIndex": freshIndex, "isRefresh": isRefresh])
        bpLog("Fetching app recommendations (idx: \(freshIndex), refresh: \(isRefresh))")

        let finalIdx = Int(Date().timeIntervalSince1970) + freshIndex

        // The personalised App API path needs two values the anonymous
        // path does not have: a mobile device fingerprint (BUVID) so
        // the upstream can recognise the device, and the account `mid`
        // so the response can be re-ranked against that user's history.
        // If the user is logged in, we prefer their account-derived
        // BUVID if available, otherwise we generate a stable one.
        let config = await currentAppConfig() ?? BilibiliAPIClient.defaultConfig
        
        // Mobile BUVID starts with XY (MAC) or XX (ID). Official iOS app
        // typically uses XY + MD5 hash.
        let effectiveBuvid: String
        if let stored = config.buvid3, stored.hasPrefix("XY"), stored.count > 30 {
            effectiveBuvid = stored
        } else if let deviceBuvid = DeviceInfo.shared.persistedBuvid3,
                  deviceBuvid.hasPrefix("XY"), deviceBuvid.count > 30 {
            // Anonymous fallback path. The legacy
            // `generateMobileBuvid()` used a hard-coded
            // "Paladala-iOS-Device-Seed" shared by every
            // install — B 站 server fingerprints that seed
            // and silently gates comment content. Once
            // `DeviceInfo.setBuvids(buvid3:buvid4:)` has
            // captured a real SPI-fetched fingerprint on
            // launch, prefer it. Falls through to
            // `generateMobileBuvid()` only when the launch
            // fetch is still in flight (a few hundred ms on
            // cold start) or has failed — strictly better
            // than returning a wrong buvid3 that the
            // server's per-SPI-fingerprint gate keys on.
            effectiveBuvid = deviceBuvid
        } else {
            effectiveBuvid = generateMobileBuvid()
        }
        let personalMid = config.mid > 0 ? "\(config.mid)" : nil

        var queryItems = [
            URLQueryItem(name: "mobi_app", value: "iphone"),
            URLQueryItem(name: "platform", value: "ios"),
            URLQueryItem(name: "build", value: appBuild),
            URLQueryItem(name: "idx", value: "\(finalIdx)"),
            URLQueryItem(name: "pull", value: isRefresh ? "true" : "false"),
            URLQueryItem(name: "login_event", value: personalMid == nil ? "0" : "1"),
            URLQueryItem(name: "appkey", value: appKey),
            URLQueryItem(name: "ts", value: "\(Int(Date().timeIntervalSince1970))"),
            URLQueryItem(name: "buvid", value: effectiveBuvid),
            URLQueryItem(name: "device", value: "phone"),
            URLQueryItem(name: "network", value: "wifi")
        ]
        if let personalMid {
            queryItems.append(URLQueryItem(name: "mid", value: personalMid))
        }
        
        queryItems.append(URLQueryItem(name: "sign", value: appSign(queryItems)))
        
        let payload: APIResponse<AppFeedPayload> = try await get(
            baseURL: appBaseURL,
            path: "/x/v2/feed/index",
            queryItems: queryItems
        )
        
        do {
            try payload.requireOK()
        } catch {
            diagLog(.recommendation, "App Recommended API error", details: ["code": payload.code ?? 0, "message": payload.message ?? "unknown"])
            throw error
        }

        let items = payload.value?.items ?? []
        let videos = items.compactMap { item -> BiliVideo? in
            // Handle multiple card types that contain video data
            let validGotos = ["av", "bangumi", "live"] 
            guard validGotos.contains(item.cardGoto) else { return nil }
            return item.model
        }
        diagLog(.recommendation, "App Recommended API success", details: ["itemCount": items.count, "videoCount": videos.count])
        bpLog("Received \(items.count) items, \(videos.count) mapped to videos")
        return videos
    }

    func popularVideos(page: Int = 1) async throws -> [BiliVideo] {
        let payload: APIResponse<VideoListPayload> = try await get(
            baseURL: baseURL,
            path: "/x/web-interface/popular",
            queryItems: [
                URLQueryItem(name: "ps", value: "20"),
                URLQueryItem(name: "pn", value: "\(page)")
            ]
        )
        try payload.requireOK()
        return payload.value?.videos.map(\.model) ?? []
    }

    func rankingVideos() async throws -> [BiliVideo] {
        let payload: APIResponse<VideoListPayload> = try await get(
            baseURL: baseURL,
            path: "/x/web-interface/ranking/v2",
            queryItems: [
                URLQueryItem(name: "rid", value: "0"),
                URLQueryItem(name: "type", value: "all")
            ]
        )
        try payload.requireOK()
        return payload.value?.videos.map(\.model) ?? []
    }

    func preciousVideos() async throws -> [BiliVideo] {
        let payload: APIResponse<VideoListPayload> = try await get(
            baseURL: baseURL,
            path: "/x/web-interface/popular/precious",
            queryItems: []
        )
        try payload.requireOK()
        return payload.value?.videos.map(\.model) ?? []
    }

    func weeklyMustWatchVideos() async throws -> [BiliVideo] {
        let listPayload: APIResponse<WeeklySeriesListPayload> = try await get(
            baseURL: baseURL,
            path: "/x/web-interface/popular/series/list",
            queryItems: []
        )
        try listPayload.requireOK()
        let latestNumber = listPayload.value?.list.map(\.number).max() ?? 1
        let payload: APIResponse<VideoListPayload> = try await get(
            baseURL: baseURL,
            path: "/x/web-interface/popular/series/one",
            queryItems: [URLQueryItem(name: "number", value: "\(latestNumber)")]
        )
        try payload.requireOK()
        return payload.value?.videos.map(\.model) ?? []
    }

    func regionVideos(tid: Int, page: Int = 1) async throws -> [BiliVideo] {
        let payload: APIResponse<VideoListPayload> = try await get(
            baseURL: baseURL,
            path: "/x/web-interface/dynamic/region",
            queryItems: [
                URLQueryItem(name: "rid", value: "\(tid)"),
                URLQueryItem(name: "pn", value: "\(page)"),
                URLQueryItem(name: "ps", value: "30")
            ]
        )
        try payload.requireOK()
        return payload.value?.videos.map(\.model) ?? []
    }

    /// Fetch a page of the 音乐 (music) region feed. The region's
    /// `rid` is `3` on Bilibili's taxonomy — the same partition the
    /// Android paladala client uses for its Music tab. `/dynamic/region`
    /// now returns business code `-404` for this partition, while the
    /// current `/newlist` endpoint returns the same `archives` payload
    /// shape with valid `bvid` / `cid` values.
    func musicVideos(page: Int = 1) async throws -> [BiliVideo] {
        let payload: APIResponse<VideoListPayload> = try await get(
            baseURL: baseURL,
            path: "/x/web-interface/newlist",
            queryItems: [
                URLQueryItem(name: "rid", value: "3"),
                URLQueryItem(name: "pn", value: "\(page)"),
                URLQueryItem(name: "ps", value: "30")
            ]
        )
        try payload.requireOK()
        return payload.value?.videos.compactMap(\.validModel) ?? []
    }

    func shortVideoFeed(freshIndex: Int = 0) async throws -> [BiliVideo] {
        let idx = Int(Date().timeIntervalSince1970) + freshIndex
        var queryItems = [
            URLQueryItem(name: "mobi_app", value: "iphone"),
            URLQueryItem(name: "platform", value: "ios"),
            URLQueryItem(name: "build", value: appBuild),
            URLQueryItem(name: "idx", value: "\(idx)"),
            URLQueryItem(name: "pull", value: "1"),
            URLQueryItem(name: "column", value: "1"),
            URLQueryItem(name: "device", value: "phone"),
            URLQueryItem(name: "flush", value: "4"),
            URLQueryItem(name: "fnval", value: "4048"),
            URLQueryItem(name: "qn", value: "64"),
            URLQueryItem(name: "fourk", value: "1"),
            URLQueryItem(name: "feed_style", value: "story"),
            URLQueryItem(name: "appkey", value: appKey),
            URLQueryItem(name: "ts", value: "\(Int(Date().timeIntervalSince1970))")
        ]
        queryItems.append(URLQueryItem(name: "sign", value: appSign(queryItems)))

        let payload: APIResponse<AppFeedPayload> = try await get(
            baseURL: appBaseURL,
            path: "/x/v2/feed/index",
            queryItems: queryItems
        )
        try payload.requireOK()
        return (payload.value?.items ?? []).compactMap(\.model)
    }
}

struct VideoListPayload: Decodable, Sendable {
    let item: [VideoDTO]?
    let list: [VideoDTO]?
    let result: [VideoDTO]?
    let archives: [VideoDTO]?
    let bareList: [VideoDTO]?

    /// Tolerant decoder: walks the response looking for a known list
    /// key (`item` / `list` / `result` / `archives`) and decodes each
    /// video *individually*. Any single malformed item is dropped
    /// instead of failing the whole page — a strict `try decoder.decode`
    /// of `[VideoDTO]` would crash the entire feed on one bad row.
    init(from decoder: Decoder) throws {
        if let videos = Self.decodeTolerantArray(from: decoder) {
            self.item = nil
            self.list = nil
            self.result = nil
            self.archives = nil
            self.bareList = videos
            return
        }
        let container = try decoder.container(keyedBy: DynamicKey.self)
        self.item = Self.decodeTolerant(in: container, key: "item")
        self.list = Self.decodeTolerant(in: container, key: "list")
        self.result = Self.decodeTolerant(in: container, key: "result")
        self.archives = Self.decodeTolerant(in: container, key: "archives")
        self.bareList = nil
    }

    private static func decodeTolerantArray(from decoder: Decoder) -> [VideoDTO]? {
        let container = try? decoder.singleValueContainer()
        if let strict = try? container?.decode([VideoDTO].self) {
            return strict
        }
        if let lenient = try? container?.decode([FailableDecodable<VideoDTO>].self) {
            return lenient.compactMap(\.value)
        }
        return nil
    }

    /// Decodes an array of `VideoDTO` by falling back to a per-item
    /// pass when the strict decode throws. Returns `nil` when the
    /// key is absent (mirrors the previous `[VideoDTO]?` behaviour).
    private static func decodeTolerant(
        in container: KeyedDecodingContainer<DynamicKey>,
        key: String
    ) -> [VideoDTO]? {
        guard container.contains(DynamicKey(key)) else { return nil }
        if let strict = try? container.decode([VideoDTO].self, forKey: DynamicKey(key)) {
            return strict
        }
        // Per-item fallback: decode each element independently. Bad
        // entries are silently dropped — losing a single row is much
        // better than losing the whole page.
        if let lenient = try? container.decode([FailableDecodable<VideoDTO>].self, forKey: DynamicKey(key)) {
            return lenient.compactMap(\.value)
        }
        return nil
    }

    var videos: [VideoDTO] {
        item ?? list ?? result ?? archives ?? bareList ?? []
    }
}

private struct WeeklySeriesListPayload: Decodable, Sendable {
    let list: [WeeklySeriesPeriod]
}

private struct WeeklySeriesPeriod: Decodable, Sendable {
    let number: Int
}

private struct AppFeedPayload: Decodable, Sendable {
    let items: [AppFeedItemDTO]
}

private struct AppFeedItemDTO: Decodable, Sendable {
    let cardType: String
    let cardGoto: String
    let param: String
    let cover: String?
    let pic: String?
    let title: String
    let uri: String
    let playerArgs: AppPlayerArgs?
    let descButton: AppDescButton?

    enum CodingKeys: String, CodingKey {
        case cardType = "card_type"
        case cardGoto = "card_goto"
        case param
        case cover
        case pic
        case title
        case uri
        case playerArgs = "player_args"
        case descButton = "desc_button"
    }

    struct AppPlayerArgs: Decodable {
        let aid: Int
        let cid: Int
        let duration: Int
    }

    struct AppDescButton: Decodable {
        let text: String
    }

    var model: BiliVideo? {
        // App API returns various card types. 'av' is the standard video.
        // We also allow 'bangumi' if we can map it.
        guard cardGoto == "av" || cardGoto == "bangumi" else { return nil }
        
        // Use 'cover' or 'pic' whichever is available.
        let rawCover = cover ?? pic
        let coverHTTPS = rawCover?.replacingOccurrences(of: "http://", with: "https://")
        let finalCover = coverHTTPS != nil ? URL(string: coverHTTPS!) : nil
        
        let aidValue = playerArgs?.aid ?? Int(param) ?? 0
        
        return BiliVideo(
            bvid: "", // Will be fetched on demand in detail(for:) if needed
            aid: aidValue,
            cid: playerArgs?.cid ?? 0,
            title: title,
            ownerName: descButton?.text ?? "Bilibili",
            coverURL: finalCover,
            duration: playerArgs?.duration ?? 0,
            viewCount: 0,
            danmakuCount: 0,
            likeCount: 0,
            description: "",
            ownerMid: 0
        )
    }
}
