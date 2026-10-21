import Foundation

// Library: history, watch later, and favorite folders.

extension BilibiliAPIClient {
    func history(cursor: HistoryCursorState? = nil, pageSize: Int = 30) async throws -> HistoryPageResult {
        var queryItems = [URLQueryItem(name: "ps", value: "\(pageSize)")]
        if let cursor {
            if cursor.max > 0 {
                queryItems.append(URLQueryItem(name: "max", value: "\(cursor.max)"))
            }
            if cursor.viewAt > 0 {
                queryItems.append(URLQueryItem(name: "view_at", value: "\(cursor.viewAt)"))
            }
            if !cursor.business.isEmpty {
                queryItems.append(URLQueryItem(name: "business", value: cursor.business))
            }
        }
        let payload: APIResponse<HistoryPayload> = try await get(
            baseURL: baseURL,
            path: "/x/web-interface/history/cursor",
            queryItems: queryItems
        )
        try payload.requireOK()
        let data = payload.value
        return HistoryPageResult(
            items: data?.items.map { $0.entry } ?? [],
            nextCursor: data?.cursor?.cursorState
        )
    }

    func watchLaterVideos() async throws -> [BiliVideo] {
        let payload: APIResponse<WatchLaterPayload> = try await get(
            baseURL: baseURL,
            path: "/x/v2/history/toview",
            queryItems: []
        )
        try payload.requireOK()
        return payload.value?.list.map { $0.video } ?? []
    }

    func favoriteFolders(mid: Int64) async throws -> [FavoriteFolderSummary] {
        let payload: APIResponse<FavoriteFoldersPayload> = try await get(
            baseURL: baseURL,
            path: "/x/v3/fav/folder/created/list-all",
            queryItems: [
                URLQueryItem(name: "up_mid", value: "\(mid)")
            ]
        )
        try payload.requireOK()
        return payload.value?.list.map { $0.folder } ?? []
    }

    func favoriteVideos(mediaID: Int64, page: Int = 1) async throws -> FavoriteFolderVideosPage {
        let payload: APIResponse<FavoriteResourcesPayload> = try await get(
            baseURL: baseURL,
            path: "/x/v3/fav/resource/list",
            queryItems: [
                URLQueryItem(name: "media_id", value: "\(mediaID)"),
                URLQueryItem(name: "pn", value: "\(page)"),
                URLQueryItem(name: "ps", value: "20"),
                URLQueryItem(name: "platform", value: "web")
            ]
        )
        try payload.requireOK()
        let info = payload.value?.info
        let medias = payload.value?.medias.map { $0.video } ?? []
        return FavoriteFolderVideosPage(
            title: info?.title ?? "收藏夾",
            videos: medias,
            hasMore: payload.value?.hasMore ?? false
        )
    }

    /// Fetch a UP's *public* favorite folders. The endpoint
    /// `/x/v3/fav/folder/created/list-all` only returns folders
    /// the UP has marked `public`; private folders stay
    /// invisible to other clients. `up_mid > 0` is required —
    /// Bilibili rejects the call as -101 otherwise. Returns the
    /// raw folder summaries so the ViewModel can render the
    /// list directly (titles, cover thumbs, video counts).
    func userFavoriteFolders(upMid: Int64) async throws -> [FavoriteFolderSummary] {
        guard upMid > 0 else { return [] }
        let payload: APIResponse<UserFavoriteFoldersPayload> = try await get(
            baseURL: baseURL,
            path: "/x/v3/fav/folder/created/list-all",
            queryItems: [URLQueryItem(name: "up_mid", value: "\(upMid)")],
            // Same WBI requirement as `userDynamic`. The
            // endpoint exists for both anonymous and signed-in
            // callers but only the WBI-signed branch returns
            // public folders; the unsigned branch returns
            // an empty `list`.
            signWithWBI: true
        )
        try payload.requireOK()
        return payload.value?.folders.map(\.model) ?? []
    }
}

private struct HistoryPayload: Decodable, Sendable {
    let items: [HistoryItemDTO]
    let cursor: HistoryCursorDTO?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        items = (try? container.decode([HistoryItemDTO].self, forKey: DynamicKey("list"))) ?? []
        cursor = try? container.decode(HistoryCursorDTO.self, forKey: DynamicKey("cursor"))
    }
}

private struct HistoryCursorDTO: Decodable, Sendable {
    let max: Int64
    let viewAt: Int64
    let business: String

    enum CodingKeys: String, CodingKey {
        case max
        case viewAt = "view_at"
        case business
    }

    var cursorState: HistoryCursorState? {
        guard max > 0 || viewAt > 0 || !business.isEmpty else { return nil }
        return HistoryCursorState(max: max, viewAt: viewAt, business: business)
    }
}

private struct HistoryItemDTO: Decodable, Sendable {
    let title: String
    let coverURL: URL?
    let ownerName: String
    let ownerFaceURL: URL?
    let ownerMID: Int64
    let duration: Int
    let progress: Int
    let viewedAt: Int64
    let stat: VideoStatsDTO?
    let historyBVID: String
    let historyCID: Int
    let historyOID: Int64

    var entry: HistoryEntry {
        let video = BiliVideo(
            bvid: historyBVID,
            aid: Int(historyOID),
            cid: historyCID,
            title: title,
            ownerName: ownerName,
            coverURL: coverURL,
            duration: duration,
            viewCount: stat?.view ?? 0,
            danmakuCount: stat?.danmaku ?? 0,
            likeCount: stat?.like ?? 0,
            replyCount: stat?.reply ?? 0,
            favoriteCount: stat?.favorite,
            coinCount: stat?.coin,
            shareCount: stat?.share,
            description: "",
            ownerMid: 0
        )
        return HistoryEntry(
            id: historyBVID.isEmpty ? "\(historyOID):\(viewedAt)" : historyBVID,
            video: video,
            viewedAt: viewedAt,
            progress: progress
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        title = container.decodeString(keys: ["title"]) ?? "Untitled"
        coverURL = (container.decodeString(keys: ["cover", "pic"]) ?? "").httpsURL
        ownerName = container.decodeString(keys: ["author_name"]) ?? "Unknown"
        ownerFaceURL = (container.decodeString(keys: ["author_face"]) ?? "").httpsURL
        ownerMID = container.decodeInt64(keys: ["author_mid"]) ?? 0
        duration = container.decodeInt(keys: ["duration"]) ?? 0
        progress = container.decodeInt(keys: ["progress"]) ?? -1
        viewedAt = container.decodeInt64(keys: ["view_at"]) ?? 0
        stat = try? container.decode(VideoStatsDTO.self, forKey: DynamicKey("stat"))
        let history = try? container.nestedContainer(keyedBy: DynamicKey.self, forKey: DynamicKey("history"))
        historyBVID = history?.decodeString(keys: ["bvid"]) ?? ""
        historyCID = history?.decodeInt(keys: ["cid"]) ?? 0
        historyOID = history?.decodeInt64(keys: ["oid"]) ?? 0
    }
}

private struct FavoriteFoldersPayload: Decodable, Sendable {
    let list: [FavoriteFolderDTO]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        list = (try? container.decode([FavoriteFolderDTO].self, forKey: DynamicKey("list"))) ?? []
    }
}

private struct FavoriteFolderDTO: Decodable, Sendable {
    let id: Int64
    let title: String
    let coverURL: URL?
    let mediaCount: Int
    let ownerName: String

    enum CodingKeys: String, CodingKey {
        case id
        case fid
        case title
        case cover
        case mediaCount = "media_count"
        case upper
    }

    var folder: FavoriteFolderSummary {
        FavoriteFolderSummary(
            id: id,
            title: title,
            coverURL: coverURL,
            mediaCount: mediaCount,
            ownerName: ownerName
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        id = Int64(container.decodeInt(keys: ["id", "fid"]) ?? 0)
        title = container.decodeString(keys: ["title"]) ?? "收藏夾"
        coverURL = (container.decodeString(keys: ["cover"]) ?? "").httpsURL
        mediaCount = container.decodeInt(keys: ["media_count"]) ?? 0
        let upper = try? container.nestedContainer(keyedBy: DynamicKey.self, forKey: DynamicKey("upper"))
        ownerName = upper?.decodeString(keys: ["name"]) ?? ""
    }
}

private struct FavoriteResourcesPayload: Decodable, Sendable {
    let info: FavoriteInfoDTO?
    let medias: [FavoriteMediaDTO]
    let hasMore: Bool

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        info = try? container.decode(FavoriteInfoDTO.self, forKey: DynamicKey("info"))
        medias = (try? container.decode([FavoriteMediaDTO].self, forKey: DynamicKey("medias"))) ?? []
        hasMore = container.decodeBool(keys: ["has_more"]) ?? false
    }
}

/// Payload of `/x/v3/fav/folder/created/list-all`. Returns
/// the public folders the UP has marked as `attr == 0`
/// (public). Private folders are filtered out by the
/// upstream. The `count` field on each folder is the live
/// number of videos in it; the UI uses it for the row
/// subtitle.
private struct UserFavoriteFoldersPayload: Decodable, Sendable {
    let folders: [UserFavoriteFolderDTO]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        // The endpoint shape is `{ list: [...] }` rather than
        // a bare array; some Bilibili variants omit the
        // `count` wrapper and put the array at the top level.
        // We try the wrapper first and fall back to the
        // top-level decode so both shapes work.
        if let wrapped = try? container.nestedContainer(keyedBy: DynamicKey.self, forKey: DynamicKey("list")) {
            folders = (try? wrapped.decode([UserFavoriteFolderDTO].self, forKey: DynamicKey("list"))) ?? []
        } else {
            folders = (try? container.decode([UserFavoriteFolderDTO].self, forKey: DynamicKey("list"))) ?? []
        }
    }
}

private struct UserFavoriteFolderDTO: Decodable, Sendable {
    let id: Int64
    let title: String
    let cover: String
    let mediaCount: Int
    let upperName: String

    var model: FavoriteFolderSummary {
        FavoriteFolderSummary(
            id: id,
            title: title,
            coverURL: cover.httpsURL,
            mediaCount: mediaCount,
            ownerName: upperName
        )
    }

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case cover
        case mediaCount = "media_count"
        case upperName = "upper"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        id = container.decodeInt64(keys: ["id"]) ?? 0
        title = container.decodeString(keys: ["title"]) ?? ""
        cover = container.decodeString(keys: ["cover"]) ?? ""
        mediaCount = container.decodeInt(keys: ["media_count", "cnt_info", "play"]) ?? 0
        // `upper` is sometimes a flat `{ name, mid }` object,
        // sometimes a bare string with just the name. Both
        // shapes happen; decode defensively.
        if let upperObj = try? container.nestedContainer(keyedBy: DynamicKey.self, forKey: DynamicKey("upper")) {
            upperName = upperObj.decodeString(keys: ["name"]) ?? ""
        } else {
            upperName = container.decodeString(keys: ["upper"]) ?? ""
        }
    }
}

private struct FavoriteInfoDTO: Decodable, Sendable {
    let title: String
}

private struct FavoriteMediaDTO: Decodable, Sendable {
    let id: Int64
    let bvid: String
    let title: String
    let coverURL: URL?
    let duration: Int
    let progress: Int
    let viewedAt: Int64
    let ownerName: String
    let stat: VideoStatsDTO?
    let cid: Int

    var video: BiliVideo {
        BiliVideo(
            bvid: bvid,
            aid: Int(id),
            cid: cid,
            title: title,
            ownerName: ownerName,
            coverURL: coverURL,
            duration: duration,
            viewCount: stat?.view ?? 0,
            danmakuCount: stat?.danmaku ?? 0,
            likeCount: stat?.like ?? 0,
            replyCount: stat?.reply ?? 0,
            favoriteCount: stat?.favorite,
            coinCount: stat?.coin,
            shareCount: stat?.share,
            description: "",
            ownerMid: 0
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        id = Int64(container.decodeInt(keys: ["id"]) ?? 0)
        bvid = container.decodeString(keys: ["bvid", "bv_id"]) ?? ""
        title = container.decodeString(keys: ["title"])?.strippingHTML ?? "Untitled"
        coverURL = (container.decodeString(keys: ["cover"]) ?? "").httpsURL
        duration = container.decodeInt(keys: ["duration"]) ?? 0
        progress = container.decodeInt(keys: ["progress"]) ?? 0
        viewedAt = container.decodeInt64(keys: ["view_at"]) ?? 0
        let upper = try? container.nestedContainer(keyedBy: DynamicKey.self, forKey: DynamicKey("upper"))
        ownerName = upper?.decodeString(keys: ["name"]) ?? "Unknown"
        let cntInfo = try? container.nestedContainer(keyedBy: DynamicKey.self, forKey: DynamicKey("cnt_info"))
        stat = cntInfo.map { nested in
            VideoStatsDTO(
                view: nested.decodeInt(keys: ["play"]) ?? 0,
                danmaku: nested.decodeInt(keys: ["danmaku"]) ?? 0,
                like: nested.decodeInt(keys: ["like"]) ?? 0,
                favorite: nested.decodeInt(keys: ["collect", "favorite"]),
                coin: nested.decodeInt(keys: ["coin"]),
                share: nested.decodeInt(keys: ["share"]),
                reply: nested.decodeInt(keys: ["reply", "video_review"]) ?? 0
            )
        }
        let ugc = try? container.nestedContainer(keyedBy: DynamicKey.self, forKey: DynamicKey("ugc"))
        cid = ugc?.decodeInt(keys: ["first_cid"]) ?? 0
    }
}

private struct WatchLaterPayload: Decodable, Sendable {
    let list: [WatchLaterItemDTO]
}

private struct WatchLaterItemDTO: Decodable, Sendable {
    let aid: Int64
    let bvid: String
    let cid: Int
    let title: String
    let coverURL: URL?
    let duration: Int
    let ownerName: String
    let stat: VideoStatsDTO?

    var video: BiliVideo {
        BiliVideo(
            bvid: bvid,
            aid: Int(aid),
            cid: cid,
            title: title,
            ownerName: ownerName,
            coverURL: coverURL,
            duration: duration,
            viewCount: stat?.view ?? 0,
            danmakuCount: stat?.danmaku ?? 0,
            likeCount: stat?.like ?? 0,
            replyCount: stat?.reply ?? 0,
            favoriteCount: stat?.favorite,
            coinCount: stat?.coin,
            shareCount: stat?.share,
            description: "",
            ownerMid: 0
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        aid = Int64(container.decodeInt(keys: ["aid"]) ?? 0)
        bvid = container.decodeString(keys: ["bvid"]) ?? ""
        cid = container.decodeInt(keys: ["cid"]) ?? 0
        title = container.decodeString(keys: ["title"]) ?? "Untitled"
        coverURL = (container.decodeString(keys: ["pic"]) ?? "").httpsURL
        duration = container.decodeInt(keys: ["duration"]) ?? 0
        let owner = try? container.nestedContainer(keyedBy: DynamicKey.self, forKey: DynamicKey("owner"))
        ownerName = owner?.decodeString(keys: ["name"]) ?? "Unknown"
        stat = try? container.decode(VideoStatsDTO.self, forKey: DynamicKey("stat"))
    }
}
