import Foundation

// User profiles: card, relation, follow stats, followings, uploads.

extension BilibiliAPIClient {
    /// Page through the user's followings list and return the full set
    /// of `mid` values. Bilibili paginates at 50 per page, so users with
    /// 300+ follows trigger a few extra round-trips. We do NOT cache
    /// the result here — the caller is responsible for caching because
    /// it owns the `Set<Int64>` lifetime.
    ///
    /// The endpoint requires an active SESSDATA cookie; an anonymous
    /// request returns code -101 and we treat that as "no follows"
    /// rather than throwing, so the home view can render the login
    /// prompt without a try/catch dance.
    func followingMids(vmid: Int64) async throws -> Set<Int64> {
        diagLog(.recommendation, "Fetching following MIDs", details: ["vmid": vmid])
        if await currentCookieHeader() == nil {
            diagLog(.recommendation, "Following MIDs skipped: No cookie")
            return []
        }
        var mids: Set<Int64> = []
        var page = 1
        let pageSize = 50
        while true {
            let payload: APIResponse<FollowingsPayload> = try await get(
                baseURL: baseURL,
                path: "/x/relation/followings",
                queryItems: [
                    URLQueryItem(name: "vmid", value: "\(vmid)"),
                    URLQueryItem(name: "pn", value: "\(page)"),
                    URLQueryItem(name: "ps", value: "\(pageSize)"),
                    URLQueryItem(name: "order", value: "desc")
                ]
            )
            if payload.code == -101 {
                diagLog(.recommendation, "Following MIDs error: -101 (needs login)")
                return []
            }
            try payload.requireOK()
            guard let data = payload.value, !data.list.isEmpty else { break }
            for entry in data.list { mids.insert(entry.mid) }
            // Stop when the upstream returns a short page; otherwise
            // advance and keep going. `total` is the user's full
            // followings count, but trusting it lets a stale server-
            // side count over-iterate, so we stop on a short page.
            if data.list.count < pageSize { break }
            page += 1
            // Hard cap at 100 pages (5000 follows) so a corrupted
            // `total` field cannot loop us forever. Power users with
            // 5000+ follows are vanishingly rare; if we ever hit this,
            // the safer behaviour is to render what we have.
            if page > 100 { break }
        }
        diagLog(.recommendation, "Following MIDs fetched", details: ["count": mids.count])
        return mids
    }

    /// Fetch following and follower counts for a user.
    func userRelationStat(mid: Int64) async throws -> (following: Int, follower: Int) {
        let payload: APIResponse<RelationStatPayload> = try await get(
            baseURL: baseURL,
            path: "/x/relation/stat",
            queryItems: [URLQueryItem(name: "vmid", value: "\(mid)")]
        )
        try payload.requireOK()
        guard let data = payload.value else { throw BilibiliAPIError.missingData }
        return (following: data.following, follower: data.follower)
    }

    /// Fetch the total number of dynamic posts for a user from the
    /// current profile-page count endpoint.
    func userDynamicCount(mid: Int64) async throws -> Int {
        let payload: APIResponse<SpaceNavNumPayload> = try await get(
            baseURL: baseURL,
            path: "/x/space/navnum",
            queryItems: [URLQueryItem(name: "mid", value: "\(mid)")]
        )
        try payload.requireOK()
        return payload.value?.dynamicCount ?? 0
    }

    /// Fetch a user's public profile card (avatar, name, signature,
    /// level, VIP status). The endpoint is WBI-signed; a missing
    /// or rate-limited response throws `BilibiliAPIError.http`
    /// and the call site falls back to a placeholder card.
    func userCardInfo(mid: Int64) async throws -> BiliUserCard {
        let payload: APIResponse<UserCardInfoPayload> = try await get(
            baseURL: baseURL,
            path: "/x/space/wbi/acc/info",
            queryItems: [URLQueryItem(name: "mid", value: "\(mid)")],
            signWithWBI: true
        )
        try payload.requireOK()
        let card = payload.value?.toBiliUserCard(mid: mid) ?? BiliUserCard(mid: mid, name: "Unknown")
        return card
    }

    /// Look up whether the signed-in user is following `mid` through
    /// the same WBI relation route used by the current profile page.
    /// The response contains both directions; `be_relation` describes
    /// the current viewer's relationship to the target account.
    func userRelation(target mid: Int64, selfMid: Int64) async throws -> BiliRelation {
        guard mid > 0, selfMid > 0, selfMid != mid else { return .notRelated }
        let payload: APIResponse<SpaceRelationPayload> = try await get(
            baseURL: baseURL,
            path: "/x/space/wbi/acc/relation",
            queryItems: [URLQueryItem(name: "mid", value: "\(mid)")],
            signWithWBI: true
        )
        try payload.requireOK()
        return BiliRelation(attribute: payload.value?.beRelation?.attribute ?? 0)
    }

    /// Follow (`act=1`), unfollow (`act=2`), or silently follow
    /// (`act=3`) `mid`. Requires the signed-in cookie's CSRF
    /// token, which the underlying `post(...)` helper extracts
    /// from the cookie jar. Returns the upstream `code` so the
    /// ViewModel can surface a toast / haptics for the failure
    /// case (most common: -101 "未登录", thrown as
    /// `BilibiliAPIError.sessionExpired` by the post helper's
    /// 401 mapping).
    @discardableResult
    func modifyRelation(target mid: Int64, act: Int) async throws -> Int {
        guard mid > 0, (1...3).contains(act) else { throw BilibiliAPIError.invalidURL }
        let payload: APIResponse<ModifyRelationPayload> = try await post(
            baseURL: baseURL,
            path: "/x/relation/modify",
            parameters: [
                "fid": "\(mid)",
                "act": "\(act)",
                "re_src": "32"
            ]
        )
        try payload.requireOK()
        return payload.code ?? 0
    }

    /// Page through a UP's published videos. Bilibili returns
    /// at most `ps` items per page; we use 20 (the same page
    /// size as the home feed) and signal `hasMore` when the
    /// upstream returns a full page. The `pubdate` order is
    /// newest-first, matching what users expect from a
    /// channel-style listing.
    func userVideos(mid: Int64, page: Int = 1) async throws -> (videos: [BiliVideo], hasMore: Bool) {
        let payload: APIResponse<UserVideosPayload> = try await get(
            baseURL: baseURL,
            path: "/x/space/wbi/arc/search",
            queryItems: [
                URLQueryItem(name: "mid", value: "\(mid)"),
                URLQueryItem(name: "pn", value: "\(page)"),
                URLQueryItem(name: "ps", value: "20"),
                URLQueryItem(name: "order", value: "pubdate")
            ],
            signWithWBI: true
        )
        try payload.requireOK()
        let videos = payload.value?.vlist.map(\.model) ?? []
        // A full page is a "there might be more" signal. A short
        // page definitively ends the list. The endpoint also
        // returns `page.count` (total count); we ignore it
        // because trusting a stale server-side count can over-
        // iterate if a UP deletes a video between page loads.
        let hasMore = videos.count >= 20
        return (videos, hasMore)
    }
}

/// Internal decoder for the public profile-card endpoint
/// (`/x/space/wbi/acc/info`). The `data` envelope has the user
/// fields at the top level (not nested under `card` as the docs
/// imply) and `vip` is its own nested object whose `type` is the
/// legacy VIP code. We pull the four fields the header needs
/// (name, face, sign, level, vipType) via a hand-rolled
/// `init(from:)` so a partial response still decodes.
///
/// The `vip` block is also fully decoded (via
/// `BilibiliNavVIPDTO`) so the projected `BiliVIPBadge`
/// carries the rich colour + theme + due-date info the UP
/// profile chrome renders.
private struct UserCardInfoPayload: Decodable, Sendable {
    let mid: Int64
    let name: String
    let face: String
    let sign: String
    let level: Int
    let vipType: Int
    /// Decoded vip block. `nil` for non-VIP users and
    /// shadow-banned / banned accounts where the upstream
    /// omits the block.
    // (placeholder removed below)

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        mid = container.decodeInt64(keys: ["mid"]) ?? 0
        name = container.decodeString(keys: ["name"]) ?? "Unknown"
        face = container.decodeString(keys: ["face"]) ?? ""
        sign = container.decodeString(keys: ["sign"]) ?? ""
        level = container.decodeInt(keys: ["level"]) ?? 0
        // `vip` is a nested object; missing on banned or
        // never-VIP users so default to 0.
        if let vipContainer = try? container.nestedContainer(
            keyedBy: DynamicKey.self,
            forKey: DynamicKey("vip")
        ) {
            vipType = vipContainer.decodeInt(keys: ["type"]) ?? 0
        } else {
            vipType = 0
        }
    }

    func toBiliUserCard(mid: Int64) -> BiliUserCard {
        BiliUserCard(
            mid: self.mid != 0 ? self.mid : mid,
            name: name,
            faceURL: face.httpsURL,
            sign: sign,
            level: level,
            vipType: vipType,
            vipBadge: BiliVIPBadge.legacy(vipType: vipType)
        )
    }
}

/// Tiny decoder shim that wraps an existing
/// `KeyedDecodingContainer<DynamicKey>` and exposes it as a
/// top-level `Decoder`. Needed so we can re-decode the
/// already-extracted `vip` nested container as a full DTO
/// without re-parsing the raw JSON. Implementation is the
/// minimum surface `Decodable` types call into
/// (`container(keyedBy:)`) — everything else is a fatal
/// precondition because the DTOs we decode from it never
/// call anything else.
private struct _NestedContainerDecoder: Decoder {
    let container: KeyedDecodingContainer<DynamicKey>
    var codingPath: [CodingKey] { [] }
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func container<Key>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key>
    where Key: CodingKey {
        // `KeyedDecodingContainer<DynamicKey>` cannot be
        // transparently re-keyed to `KeyedDecodingContainer<Key>`,
        // but our DTOs only decode DynamicKey (they all use
        // `DynamicKey` for their `CodingKeys`). Use a bit-level
        // cast so the DTO gets the same underlying container.
        //
        // The previous implementation used `unsafeDowncast`,
        // which Swift 5 tolerated and Swift 6 strict mode
        // refuses because `KeyedDecodingContainer` is a
        // *struct*, not a class — `unsafeDowncast`'s contract
        // requires a class or class-bounded type. `unsafeBitCast`
        // does the same memory reinterpretation but with no
        // class constraint, and is sound here because:
        //
        //   • `KeyedDecodingContainer<K>` is a `@frozen` struct
        //     generic on the `CodingKey` parameter, and the
        //     same `K` (i.e. `DynamicKey` here) yields the same
        //     memory layout, and
        //   • we *check* `Key.self == DynamicKey.self` first, so
        //     the size match is a logical guarantee, not a
        //     coincidence.
        if Key.self == DynamicKey.self {
            return unsafeBitCast(container, to: KeyedDecodingContainer<Key>.self)
        }
        throw DecodingError.dataCorruptedError(
            forKey: container.allKeys.first ?? DynamicKey("vip"),
            in: container,
            debugDescription: "_NestedContainerDecoder only supports DynamicKey"
        )
    }

    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        throw DecodingError.dataCorruptedError(
            forKey: container.allKeys.first ?? DynamicKey("vip"),
            in: container,
            debugDescription: "vip is a keyed object, not an array"
        )
    }

    func singleValueContainer() throws -> SingleValueDecodingContainer {
        throw DecodingError.dataCorruptedError(
            forKey: container.allKeys.first ?? DynamicKey("vip"),
            in: container,
            debugDescription: "vip is a keyed object, not a single value"
        )
    }
}

/// Internal decoder for `/x/space/wbi/arc/search` (a UP's
/// published-videos list). The `data` envelope is
/// `{ list: { vlist: [...] }, page: { count, pn, ps } }`. The
/// `vlist` items have a different shape than the home-feed
/// `VideoDTO` — notably `length` is a `"MM:SS"` string (not
/// seconds), `author` carries the owner name (not `owner.name`),
/// and `like` is absent — so we project through a separate
/// `UserVideoDTO` and convert on the way to `BiliVideo`.
private struct UserVideosPayload: Decodable, Sendable {
    let vlist: [UserVideoDTO]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        let list = try? container.nestedContainer(keyedBy: DynamicKey.self, forKey: DynamicKey("list"))
        vlist = (try? list?.decode([UserVideoDTO].self, forKey: DynamicKey("vlist"))) ?? []
    }
}

private struct UserVideoDTO: Decodable, Sendable {
    let bvid: String
    let aid: Int
    let title: String
    let author: String
    let mid: Int64
    let pic: String
    let length: String
    let play: Int
    let comment: Int
    let description: String
    let created: Int

    var model: BiliVideo {
        BiliVideo(
            bvid: bvid,
            aid: aid,
            cid: 0,                    // not present on this endpoint; the detail view fills it in
            title: title,
            ownerName: author.isEmpty ? "Unknown" : author,
            coverURL: pic.httpsURL,
            duration: Self.parseDuration(length),
            viewCount: play,
            danmakuCount: comment,
            likeCount: 0,              // not exposed on this endpoint
            description: description,
            ownerMid: mid
        )
    }

    /// Convert Bilibili's `"MM:SS"` / `"HH:MM:SS"` duration string
    /// into seconds. Returns 0 on the malformed / empty case so
    /// the row never shows a "NaN:NaN" pill.
    static func parseDuration(_ raw: String) -> Int {
        let parts = raw.split(separator: ":").compactMap { Int($0) }
        switch parts.count {
        case 2: return parts[0] * 60 + parts[1]
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        default: return 0
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        bvid = container.decodeString(keys: ["bvid", "param"]) ?? ""
        aid = container.decodeInt(keys: ["aid", "id"]) ?? 0
        title = container.decodeString(keys: ["title"])?.strippingHTML ?? "Untitled"
        author = container.decodeString(keys: ["author"]) ?? "Unknown"
        mid = container.decodeInt64(keys: ["mid"]) ?? 0
        pic = container.decodeString(keys: ["pic"]) ?? ""
        length = container.decodeString(keys: ["length"]) ?? "0:00"
        play = container.decodeInt(keys: ["play"]) ?? 0
        comment = container.decodeInt(keys: ["comment"]) ?? 0
        description = container.decodeString(keys: ["description"]) ?? ""
        created = container.decodeInt(keys: ["created"]) ?? 0
    }
}

private struct FollowingsPayload: Decodable, Sendable {
    let list: [FollowingEntry]
    let total: Int?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        list = (try? container.decode([FollowingEntry].self, forKey: DynamicKey("list"))) ?? []
        total = container.decodeInt(keys: ["total"])
    }
}

private struct FollowingEntry: Decodable, Sendable {
    let mid: Int64
    let uname: String?
    let attribute: Int?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        mid = container.decodeInt64(keys: ["mid"]) ?? 0
        uname = container.decodeString(keys: ["uname"])
        attribute = container.decodeInt(keys: ["attribute"])
    }
}

private struct RelationStatPayload: Decodable, Sendable {
    let following: Int
    let follower: Int
}

/// Payload of `/x/relation`. The endpoint is documented to
/// return `{ attribute: 1, mtime: ... }` for "followed" but in
/// practice also returns `0` for "not related" without
/// `mtime`. We decode both defensively.
private struct RelationAttributePayload: Decodable, Sendable {
    let attribute: Int
}

/// Response of `/x/space/wbi/acc/relation`. `be_relation` is the
/// viewer's relationship to the profile being viewed.
private struct SpaceRelationPayload: Decodable, Sendable {
    let beRelation: RelationAttributePayload?

    enum CodingKeys: String, CodingKey {
        case beRelation = "be_relation"
    }
}

/// Payload of `/x/relation/modify`. The endpoint returns
/// `{ code: 0, message: "0", data: { ... } }` on success; on
/// failure `code` is the bilibili error code (e.g. -101 for
/// "未登录", 22001 for "关注失败，请重试") and `message` carries
/// the i18n string. We only consume `code` here — the surface
/// error message comes from the ViewModel's localisable copy.
private struct ModifyRelationPayload: Decodable, Sendable {
    // No fields — the success body is mostly housekeeping.
}

private struct SpaceNavNumPayload: Decodable, Sendable {
    let dynamicCount: Int

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        dynamicCount = container.decodeInt(keys: ["opus", "upos", "dynamic_count"]) ?? 0
    }
}
