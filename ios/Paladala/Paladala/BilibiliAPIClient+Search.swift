import Foundation

// Search: videos, users, typed slots, and suggestions.

extension BilibiliAPIClient {
    func searchVideos(keyword: String, page: Int = 1) async throws -> [BiliVideo] {
        guard !keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let payload: APIResponse<VideoListPayload> = try await get(
            baseURL: baseURL,
            path: "/x/web-interface/wbi/search/type",
            queryItems: [
                URLQueryItem(name: "search_type", value: "video"),
                URLQueryItem(name: "keyword", value: keyword),
                URLQueryItem(name: "page", value: "\(page)"),
                URLQueryItem(name: "page_size", value: "20"),
                URLQueryItem(name: "platform", value: "pc"),
                URLQueryItem(name: "web_location", value: "1430654")
            ],
            signWithWBI: true
        )
        try payload.requireOK()
        return payload.value?.videos.map(\.model) ?? []
    }

    /// As-you-type search suggestions. Hits the dedicated
    /// suggest endpoint at `s.search.bilibili.com` (NOT
    /// `api.bilibili.com`) — that endpoint is anonymous,
    /// doesn't need WBI signing, and is designed for the
    /// keystroke-rate path: median ~100 ms per
    /// `scripts/probe_search_endpoints.py` on 2026-07-06.
    ///
    /// Returns up to 10 ranked tag suggestions; each carries a
    /// `name` (with HTML highlight spans from the upstream —
    /// strip those before surfacing to the UI), an optional
    /// `bvid` / `aid` when the term resolves to a known video,
    /// and a `tagId` / `type` for analytics.
    ///
    /// Caller is responsible for debouncing (we recommend 120 ms
    /// in `HomeViewModel`) so we don't flood the upstream on
    /// every keystroke.  The endpoint is rate-limit gated; a
    /// sustained keystroke loop will return HTTP 429 within
    /// ~3 s on a hot loop.
    func suggestSearch(term: String) async throws -> [BiliSearchSuggestion] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let payload: SuggestPayload = try await get(
            baseURL: suggestBaseURL,
            path: "/main/suggest",
            queryItems: [
                URLQueryItem(name: "term", value: trimmed)
            ],
            referer: "https://search.bilibili.com"
        )
        return payload.result?.tag ?? []
    }

    /// "全部" (all-types) search. Runs the five type slots
    /// in parallel via `async let` so the merged response
    /// arrives as fast as the slowest slot. Median wall-clock
    /// is ~400 ms (the `live` slot dominates) per the probe.
    /// Errors on individual slots are swallowed so a single
    /// gated slot (e.g. live requiring login) doesn't block
    /// the others — the corresponding array on the result is
    /// left empty.
    func searchAll(keyword: String, page: Int = 1) async throws -> BiliAllSearchResults {
        guard !keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return BiliAllSearchResults()
        }
        async let videos = (try? await searchVideos(keyword: keyword, page: page)) ?? []
        async let users = (try? await searchUsers(keyword: keyword, page: page)) ?? []
        // The three below are WBI-signed too; reuse the existing
        // video / user methods by adding the missing slot queries.
        async let bangumi = (try? await _searchOne(
            keyword: keyword, searchType: "media_bangumi", page: page
        )) ?? []
        async let live = (try? await _searchOne(
            keyword: keyword, searchType: "live", page: page
        )) ?? []
        async let article = (try? await _searchOne(
            keyword: keyword, searchType: "article", page: page
        )) ?? []
        return BiliAllSearchResults(
            videos: await videos,
            users: await users,
            bangumi: await bangumi,
            liveRooms: await live,
            articles: await article
        )
    }

    /// Internal helper for one-off search-type slots used by
    /// `searchAll(...)`. Returns the raw `result` array so
    /// the caller can decide how to decode — keeps the
    /// strongly-typed `searchVideos` / `searchUsers` paths
    /// unchanged for the existing search-as-you-type code.
    private func _searchOne(keyword: String, searchType: String, page: Int) async throws -> [VideoDTO] {
        let payload: APIResponse<SearchSlotPayload> = try await get(
            baseURL: baseURL,
            path: "/x/web-interface/wbi/search/type",
            queryItems: [
                URLQueryItem(name: "search_type", value: searchType),
                URLQueryItem(name: "keyword", value: keyword),
                URLQueryItem(name: "page", value: "\(page)"),
                URLQueryItem(name: "page_size", value: "10"),
                URLQueryItem(name: "platform", value: "pc"),
                URLQueryItem(name: "web_location", value: "1430654")
            ],
            signWithWBI: true
        )
        try payload.requireOK()
        return payload.value?.result ?? []
    }

    func searchUsers(keyword: String, page: Int = 1) async throws -> [BiliUserSearchResult] {
        guard !keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let payload: APIResponse<UserSearchPayload> = try await get(
            baseURL: baseURL,
            path: "/x/web-interface/wbi/search/type",
            queryItems: [
                URLQueryItem(name: "search_type", value: "bili_user"),
                URLQueryItem(name: "keyword", value: keyword),
                URLQueryItem(name: "page", value: "\(page)"),
                URLQueryItem(name: "page_size", value: "10"),
                URLQueryItem(name: "platform", value: "pc"),
                URLQueryItem(name: "web_location", value: "1430654")
            ],
            signWithWBI: true
        )
        try payload.requireOK()
        return (payload.value?.users ?? []).map(\.model).filter { $0.mid > 0 }
    }
}

/// Decoder for `s.search.bilibili.com/main/suggest`. The
/// response shape is `{ "code": 0, "result": { "tag": [...] } }`
/// — note the `tag` key is inside `result`, not at the top
/// level, and the upstream omits `result` entirely when no
/// matches exist.  Both shapes decode cleanly because
/// `SuggestResult` makes `tag` optional.
private struct SuggestPayload: Decodable, Sendable {
    let result: SuggestResult?
}

private struct SuggestResult: Decodable, Sendable {
    let tag: [BiliSearchSuggestion]?
}

/// Decoder for the typed search slots used by `_searchOne(...)`.
/// The `result` array shape varies per slot (bangumi returns
/// season cards, live returns room cards, etc.) — we keep the
/// raw array and let the view layer decode per-slot.
private struct SearchSlotPayload: Decodable, Sendable {
    let result: [VideoDTO]?
}

private struct UserSearchPayload: Decodable, Sendable {
    let users: [UserSearchDTO]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        users = (try? container.decode([UserSearchDTO].self, forKey: DynamicKey("result"))) ?? []
    }
}

private struct UserSearchDTO: Decodable, Sendable {
    let mid: Int64
    let name: String
    let faceURL: URL?
    let sign: String
    let fans: Int
    let videos: Int

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        mid = container.decodeInt64(keys: ["mid"]) ?? 0
        name = (container.decodeString(keys: ["uname", "name"]) ?? "Unknown").strippingHTML
        faceURL = container.decodeString(keys: ["upic", "face"])?.httpsURL
        sign = container.decodeString(keys: ["usign", "sign"])?.strippingHTML ?? ""
        fans = container.decodeInt(keys: ["fans"]) ?? 0
        videos = container.decodeInt(keys: ["videos", "video_count"]) ?? 0
    }

    var model: BiliUserSearchResult {
        BiliUserSearchResult(
            mid: mid,
            name: name,
            faceURL: faceURL,
            sign: sign,
            fans: fans,
            videos: videos
        )
    }
}
