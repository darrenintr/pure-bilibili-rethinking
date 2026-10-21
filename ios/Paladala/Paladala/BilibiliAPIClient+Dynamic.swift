import Foundation

// Dynamic (动态) feeds: following timeline and a UP's own posts.

extension BilibiliAPIClient {
    func dynamicFeed(type: String = "all", offset: String = "") async throws -> DynamicFeedPage {
        let payload: APIResponse<DynamicFeedPayload> = try await get(
            baseURL: baseURL,
            path: "/x/polymer/web-dynamic/v1/feed/all",
            queryItems: [
                URLQueryItem(name: "type", value: type),
                URLQueryItem(name: "offset", value: offset),
                URLQueryItem(name: "page", value: "1"),
                URLQueryItem(name: "features", value: "itemOpusStyle,listOnlyfans,opusBigCover,commentsNewVersion,onlyfansVote,onlyfansAssetsV2,decorationCard,forwardListHidden,ugcDelete"),
                URLQueryItem(name: "timezone_offset", value: "-480"),
                URLQueryItem(name: "platform", value: "web"),
                URLQueryItem(name: "web_location", value: "333.1365")
            ]
        )
        try payload.requireOK()
        let data = payload.value
        return DynamicFeedPage(
            items: data?.items.compactMap(\.post).filter { !$0.id.isEmpty } ?? [],
            nextOffset: data?.offset ?? "",
            hasMore: data?.hasMore ?? false
        )
    }

    /// Follow-feed variant of `dynamicFeed(...)`. Bilibili does NOT expose
    /// a follow-scoped dynamic endpoint that we can reach via REST —
    /// `/x/polymer/web-dynamic/v1/feed/attention` (used by the older
    /// documentation) returns 404, and `dynamic_svr` paths are gated
    /// behind the WebSocket channel the official client uses for live
    /// updates. The Android paladala client solves this by fetching
    /// `/feed/all` and filtering client-side against the user's
    /// followings set, and that is what we do here too.
    ///
    /// The caller is responsible for keeping a followings set (see
    /// `followingMids(...)`) and passing it in as `followingFilter`.
    /// Items whose author `mid` is not in the set are dropped before
    /// the page is returned. We deliberately do NOT filter by
    /// `type=` — the user wants every dynamic card shape (videos,
    /// 专栏, 番剧, 直播开播, 转发) to surface on the follow tab.
    ///
    /// Returns an empty page (with `needsLogin: true`) when no account
    /// is active so the home view can render the existing "登录后查看
    /// 关注动态" prompt without a try/catch dance.
    func attentionFeed(
        offset: String = "",
        followingFilter: Set<Int64>? = nil
    ) async throws -> DynamicFeedPage {
        diagLog(.recommendation, "Fetching attention feed", details: ["offset": offset, "hasFilter": followingFilter != nil])
        if await currentCookieHeader() == nil {
            diagLog(.recommendation, "Attention feed skipped: No cookie")
            return DynamicFeedPage(items: [], nextOffset: "", hasMore: false, needsLogin: true)
        }
        let payload: APIResponse<DynamicFeedPayload> = try await get(
            baseURL: baseURL,
            path: "/x/polymer/web-dynamic/v1/feed/all",
            queryItems: [
                URLQueryItem(name: "offset", value: offset),
                URLQueryItem(name: "page", value: "1"),
                URLQueryItem(name: "features", value: "itemOpusStyle,listOnlyfans,opusBigCover,commentsNewVersion,onlyfansVote,onlyfansAssetsV2,decorationCard,forwardListHidden,ugcDelete"),
                URLQueryItem(name: "timezone_offset", value: "-480"),
                URLQueryItem(name: "platform", value: "web"),
                URLQueryItem(name: "web_location", value: "333.1365")
            ]
        )
        try payload.requireOK()
        let data = payload.value
        var items = data?.items.compactMap(\.post).filter { !$0.id.isEmpty } ?? []
        diagLog(.recommendation, "Attention feed raw items", details: ["count": items.count])
        // When a followings filter is supplied, drop items whose author
        // is not in the user's follow set. We keep the original `mid`
        // (carried via the DynamicCardDTO) on `DynamicPost` so the
        // filter can run here. Without a filter (e.g. anonymous
        // fallback), pass through everything.
        if let followingFilter {
            // Items coming through `DynamicCardDTO.post` lose the raw
            // `mid` because `DynamicPost` only stores `author`. The
            // filter is therefore applied at the DTO level by
            // re-walking the original payload in `attentionFeedDTO`.
            items = attentionFeedDTO(payload: data, followingFilter: followingFilter)
            diagLog(.recommendation, "Attention feed filtered items", details: ["count": items.count, "filterSize": followingFilter.count])
        }
        return DynamicFeedPage(
            items: items,
            nextOffset: data?.offset ?? "",
            hasMore: data?.hasMore ?? false,
            needsLogin: false
        )
    }

    /// Re-walk a decoded `DynamicFeedPayload` and apply the followings
    /// filter at the DTO level (where `module_author.mid` is still
    /// available). Returns the `[DynamicPost]` items whose author mid
    /// is in `followingFilter`. Items without a `module_author.mid`
    /// are kept by default — the DTO fallback names them "Bilibili"
    /// which is a synthetic value, and we do not want to drop the
    /// upstream's official-account posts.
    private func attentionFeedDTO(
        payload: DynamicFeedPayload?,
        followingFilter: Set<Int64>
    ) -> [DynamicPost] {
        guard let payload else { return [] }
        return payload.items.compactMap { dto -> DynamicPost? in
            guard dto.visible, !dto.id.isEmpty else { return nil }
            guard let post = dto.post else { return nil }
            // The DTO exposes author mid only via the decoder path; if
            // the author mid is unknown we keep the item (defensive
            // default — official-account posts would otherwise vanish).
            if let mid = dto.authorMid {
                return followingFilter.contains(mid) ? post : nil
            }
            return post
        }
    }

    /// Fetch a UP's own dynamic posts (the same shape the follow
    /// feed uses, but pinned to a single author). The endpoint
    /// `/x/polymer/web-dynamic/v1/space/space_brief` accepts an
    /// `offset` cursor — the upstream returns the next cursor in
    /// `data.items[].id_str`, or `has_more = false` to signal end.
    /// The decoder reuses `DynamicFeedDTO` so the model already
    /// powers the follow tab.
    func userDynamic(hostMid: Int64, offset: String = "") async throws -> DynamicFeedPage {
        guard hostMid > 0 else {
            return DynamicFeedPage(items: [], nextOffset: "", hasMore: false)
        }
        var items = [
            URLQueryItem(name: "host_mid", value: "\(hostMid)"),
            URLQueryItem(name: "features", value: "itemOpusStyle,listOnlyfans,opusBigCover,commentsNewVersion,onlyfansVote,onlyfansAssetsV2,decorationCard,forwardListHidden,ugcDelete"),
            URLQueryItem(name: "timezone_offset", value: "-480"),
            URLQueryItem(name: "platform", value: "web"),
            URLQueryItem(name: "web_location", value: "333.999")
        ]
        if !offset.isEmpty {
            items.append(URLQueryItem(name: "offset", value: offset))
        }
        let payload: APIResponse<DynamicFeedPayload> = try await get(
            baseURL: baseURL,
            path: "/x/polymer/web-dynamic/v1/space/space_brief",
            queryItems: items,
            // The dynamic endpoints are WBI-signed; without
            // `signWithWBI: true` the upstream silently returns
            // an empty `items[]` (and `code = 0` so the
            // `requireOK()` check passes) — the UP's dynamic
            // tab would always render the empty-state.
            signWithWBI: true
        )
        try payload.requireOK()
        // Apply no followings filter — every post here is
        // authored by `hostMid` already. `.post` is `Optional`
        // because invisible / "您已设置不可见" cards decode to
        // `nil`; we compactMap so the rendered list matches
        // what the upstream intended to show.
        let posts = payload.value?.items.compactMap(\.post) ?? []
        // `DynamicCardDTO.id` is decoded from the JSON key
        // `id_str` (see the DTO's `init(from:)`) but the
        // stored Swift property is plain `id`. Using `.id_str`
        // here was a hold-over from when we followed the JSON
        // key name verbatim; the compiler catches it now.
        return DynamicFeedPage(
            items: posts,
            nextOffset: (payload.value?.offset.isEmpty == false)
                ? (payload.value?.offset ?? "")
                : (payload.value?.items.last?.id ?? ""),
            hasMore: payload.value?.hasMore ?? false
        )
    }
}

private struct DynamicFeedPayload: Decodable, Sendable {
    let items: [DynamicCardDTO]
    let offset: String
    let hasMore: Bool

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        items = (try? container.decode([DynamicCardDTO].self, forKey: DynamicKey("items"))) ?? []
        offset = container.decodeString(keys: ["offset"]) ?? ""
        hasMore = container.decodeBool(keys: ["has_more"]) ?? false
    }
}

private struct DynamicCardDTO: Decodable, Sendable {
    let id: String
    let visible: Bool
    let authorName: String
    /// Raw author `mid` from `modules.module_author.mid`. Exposed so
    /// the follow-feed path can filter against the user's followings
    /// set without re-decoding the JSON. `nil` when the upstream
    /// omitted the field (rare — only on synthetic / official-account
    /// posts in our observed payloads).
    let authorMid: Int64?
    let authorAvatarURL: URL?
    let text: String
    let attachedVideo: BiliVideo?
    let timeLabel: String

    var post: DynamicPost? {
        guard visible else { return nil }
        return DynamicPost(
            id: id,
            author: authorName,
            authorAvatarURL: authorAvatarURL,
            text: text,
            timeLabel: timeLabel,
            attachedVideo: attachedVideo
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        id = container.decodeString(keys: ["id_str"]) ?? UUID().uuidString
        visible = container.decodeBool(keys: ["visible"]) ?? true

        let modules = try? container.nestedContainer(keyedBy: DynamicKey.self, forKey: DynamicKey("modules"))
        let author = try? modules?.nestedContainer(keyedBy: DynamicKey.self, forKey: DynamicKey("module_author"))
        authorName = author?.decodeString(keys: ["name"]) ?? "Bilibili"
        authorMid = author?.decodeInt64(keys: ["mid"])
        authorAvatarURL = author?.decodeString(keys: ["face"])?.httpsURL
        let pubTs = author?.decodeInt64(keys: ["pub_ts"]) ?? 0
        timeLabel = pubTs > 0 ? Self.relativeTimeLabel(from: pubTs) : "剛剛"

        let moduleDynamic = try? modules?.nestedContainer(keyedBy: DynamicKey.self, forKey: DynamicKey("module_dynamic"))
        let desc = try? moduleDynamic?.nestedContainer(keyedBy: DynamicKey.self, forKey: DynamicKey("desc"))
        let major = try? moduleDynamic?.nestedContainer(keyedBy: DynamicKey.self, forKey: DynamicKey("major"))
        let archive = try? major?.nestedContainer(keyedBy: DynamicKey.self, forKey: DynamicKey("archive"))
        let opus = try? major?.nestedContainer(keyedBy: DynamicKey.self, forKey: DynamicKey("opus"))

        let descText = desc?.decodeString(keys: ["text"])?.strippingHTML ?? ""
        let archiveTitle = archive?.decodeString(keys: ["title"])?.strippingHTML ?? ""
        let opusSummary = opus?.decodeString(keys: ["summary", "title"])?.strippingHTML ?? ""
        text = [descText, opusSummary, archiveTitle].first(where: { !$0.isEmpty }) ?? ""

        if let archive {
            let bvid = archive.decodeString(keys: ["bvid"]) ?? ""
            let aid = archive.decodeInt(keys: ["aid", "id"]) ?? 0
            let cid = archive.decodeInt(keys: ["cid"]) ?? 0
            let coverURL = archive.decodeString(keys: ["cover"])?.httpsURL
            let duration = archive.decodeInt(keys: ["duration"]) ?? 0
            let stat = try? archive.nestedContainer(keyedBy: DynamicKey.self, forKey: DynamicKey("stat"))
            attachedVideo = BiliVideo(
                bvid: bvid,
                aid: aid,
                cid: cid,
                title: archiveTitle.isEmpty ? "影片動態" : archiveTitle,
                ownerName: authorName,
                coverURL: coverURL,
                duration: duration,
                viewCount: stat?.decodeInt(keys: ["play", "view"]) ?? 0,
                danmakuCount: stat?.decodeInt(keys: ["danmaku"]) ?? 0,
                likeCount: stat?.decodeInt(keys: ["like"]) ?? 0,
                replyCount: stat?.decodeInt(keys: ["reply", "video_review"]) ?? 0,
                favoriteCount: stat?.decodeInt(keys: ["favorite", "collect"]),
                coinCount: stat?.decodeInt(keys: ["coin"]),
                shareCount: stat?.decodeInt(keys: ["share"]),
                description: descText,
                ownerMid: 0
            )
        } else {
            attachedVideo = nil
        }
    }

    private static func relativeTimeLabel(from timestamp: Int64) -> String {
        let delta = max(0, Int(Date().timeIntervalSince1970) - Int(timestamp))
        switch delta {
        case ..<60:
            return "剛剛"
        case ..<3600:
            return "\(max(1, delta / 60)) 分鐘前"
        case ..<86_400:
            return "\(max(1, delta / 3600)) 小時前"
        default:
            return "\(max(1, delta / 86_400)) 天前"
        }
    }
}
