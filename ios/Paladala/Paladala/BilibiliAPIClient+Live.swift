import Foundation

// Live rooms and live playurl.

extension BilibiliAPIClient {
    func liveRooms() async throws -> [BiliLiveRoom] {
        let payload: APIResponse<LiveRoomPayload> = try await get(
            baseURL: liveBaseURL,
            path: "/room/v3/area/getRoomList",
            queryItems: [
                URLQueryItem(name: "parent_area_id", value: "0"),
                URLQueryItem(name: "area_id", value: "0"),
                URLQueryItem(name: "page_size", value: "30"),
                URLQueryItem(name: "sort_type", value: "online"),
                URLQueryItem(name: "page", value: "1")
            ]
        )
        try payload.requireOK()
        return payload.value?.list.map(\.model) ?? []
    }

    /// Fetch the playable stream URLs for a live room. The endpoint
    /// returns a tree of protocols (`stream[]`) → formats (`format[]`)
    /// → codecs (`codec[]`) → CDN hosts (`url_info[]`). We collect
    /// *every* CDN host per format (not just the first) so the
    /// HLS proxy / AVPlayer can fail over when one edge 403s —
    /// live CDN edges are much flakier than VOD.
    ///
    /// Within a format we prefer the AVPlayer-native path: HLS
    /// `ts` → HLS `fmp4` → any HLS codec → FLV as last resort. When
    /// the room exposes no HLS, the result has an empty
    /// `hlsCandidates` and the player surfaces a "FLV only" error.
    ///
    /// Throws when the room is offline (code != 0 or no playable
    /// streams) so the caller can show a specific "未开播" message
    /// instead of pretending playback failed.
    func livePlaybackURL(roomID: Int) async throws -> BiliLivePlayback {
        // `data` may be `nil` when the room is offline (code != 0).
        // `LivePlayInfoPayload` is the same either way; we just
        // re-check `code` after the optional chain.
        let payload: APIResponse<LivePlayInfoPayload> = try await get(
            baseURL: liveBaseURL,
            path: "/xlive/web-room/v2/index/getRoomPlayInfo",
            queryItems: [
                URLQueryItem(name: "room_id", value: "\(roomID)"),
                // protocol: 0=FLV, 1=HLS
                URLQueryItem(name: "protocol", value: "0,1"),
                // format: 0=FLV, 1=TS, 2=fMP4
                URLQueryItem(name: "format", value: "0,1,2"),
                // codec: 0=AVC, 1=HEVC
                URLQueryItem(name: "codec", value: "0,1"),
                // qn 10000 = "原画" (highest). The room usually
                // returns a single qn here; the player can step
                // down via the quality sheet if it wants.
                URLQueryItem(name: "qn", value: "10000"),
                URLQueryItem(name: "platform", value: "web"),
                URLQueryItem(name: "ptype", value: "8")
            ]
        )
        try payload.requireOK()
        guard let data = payload.value else {
            throw BilibiliAPIError.missingData
        }

        // Bucket all playable URLs by the player's view of them.
        // HLS slots are split by container (ts / fmp4) so the
        // proxy can prefer the AVPlayer-native ts path; we also
        // remember the codec order so the proxy can fall back to
        // HEVC if AVC's edge is down.
        var hlsTS: [URL] = []
        var hlsFMP4: [URL] = []
        var hlsOther: [URL] = []
        var flv: [URL] = []

        for stream in data.playurlInfo?.playurl.stream ?? [] {
            let isHLS = stream.protocolName == "http_hls"
                || stream.protocolName == "https_hls"
            let isFLV = stream.protocolName == "http_flv"
                || stream.protocolName == "https_flv"
                || stream.protocolName == "rtmp_flv"
                || stream.protocolName == "rtmp_flv_h265"
            guard isHLS || isFLV else { continue }
            for fmt in stream.format {
                for codec in fmt.codec {
                    let composed = codec.urlInfo.compactMap {
                        composeStreamURL(urlInfo: $0, codec: codec)
                    }
                    if isHLS {
                        switch fmt.formatName {
                        case "ts":
                            hlsTS.append(contentsOf: composed)
                        case "fmp4":
                            hlsFMP4.append(contentsOf: composed)
                        default:
                            hlsOther.append(contentsOf: composed)
                        }
                    } else if isFLV {
                        flv.append(contentsOf: composed)
                    }
                }
            }
        }

        // Prefer the AVPlayer-native TS path, then fMP4 (also
        // supported), then any other HLS variant. FLV is last
        // because AVPlayer can't decode it without a custom
        // resource loader — the caller can still surface the URL
        // for a future FLV-enabled player.
        let hls = hlsTS + hlsFMP4 + hlsOther

        let referer = URL(string: "https://live.bilibili.com/\(roomID)")!
        let info = data.roomInfo
        return BiliLivePlayback(
            roomID: roomID,
            title: info?.title ?? "",
            hostName: info?.areaName ?? "",
            hlsCandidates: hls,
            flvCandidates: flv,
            referer: referer
        )
    }

    /// Bilibili splits a stream URL into `host` + `base_url` + `extra`
    /// (each on its own CDN edge). We glue them back together and
    /// prefer HTTPS when the host scheme allows it. The `extra`
    /// segment carries the query-string parameters Bilibili's CDN
    /// requires to validate the request.
    ///
    /// NB: `baseURL` typically ends with `?` already (Bilibili's
    /// pre-signed pattern is `<path>?`). Naively appending `?<extra>`
    /// would produce `<path>??<extra>` — and the live CDN returns
    /// 403 Forbidden for the malformed query, killing playback before
    /// the first segment. Join with `&` whenever the base already
    /// has the trailing `?` so the assembled URL is well-formed.
    /// Surfaced by `scripts/probe_live_endpoints.py` against
    /// room 7734200 on 2026-07-06.
    private func composeStreamURL(urlInfo: LivePlayURLHost, codec: LivePlayCodec) -> URL? {
        let scheme = urlInfo.host.lowercased().hasPrefix("https://") ? "https" : "http"
        let hostPart = urlInfo.host.hasPrefix("\(scheme)://") ? String(urlInfo.host.dropFirst("\(scheme)://".count)) : urlInfo.host
        var raw = "\(scheme)://\(hostPart)\(codec.baseURL)"
        if !urlInfo.extra.isEmpty {
            let joiner = codec.baseURL.hasSuffix("?") ? "&" : "?"
            raw += joiner + urlInfo.extra
        }
        return URL(string: raw)
    }
}

private struct LiveRoomPayload: Decodable, Sendable {
    let list: [LiveRoomDTO]
}

private struct LivePlayInfoPayload: Decodable, Sendable {
    let roomInfo: LivePlayRoomInfo?
    let playurlInfo: LivePlayURLInfo?

    enum CodingKeys: String, CodingKey {
        case roomInfo = "room_info"
        case playurlInfo = "playurl_info"
    }
}

private struct LivePlayRoomInfo: Decodable, Sendable {
    let roomID: Int64
    let title: String?
    /// `area_name` is the live-room's section ("唱见", "游戏", etc.).
    /// We surface this as the host-name placeholder when the host
    /// field is missing on the play payload.
    let areaName: String?

    enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
        case title
        case areaName = "area_name"
    }
}

private struct LivePlayURLInfo: Decodable, Sendable {
    let playurl: LivePlayURLContainer
}

private struct LivePlayURLContainer: Decodable, Sendable {
    let stream: [LivePlayStream]
}

private struct LivePlayStream: Decodable, Sendable {
    let protocolName: String
    let format: [LivePlayFormat]

    enum CodingKeys: String, CodingKey {
        case protocolName = "protocol_name"
        case format
    }
}

private struct LivePlayFormat: Decodable, Sendable {
    let formatName: String
    let codec: [LivePlayCodec]

    enum CodingKeys: String, CodingKey {
        case formatName = "format_name"
        case codec
    }
}

private struct LivePlayCodec: Decodable, Sendable {
    let codecName: String
    let currentQPS: Int?
    let baseURL: String
    let urlInfo: [LivePlayURLHost]

    enum CodingKeys: String, CodingKey {
        case codecName = "codec_name"
        case currentQPS = "current_qn"
        case baseURL = "base_url"
        case urlInfo = "url_info"
    }
}

private struct LivePlayURLHost: Decodable, Sendable {
    let host: String
    let extra: String
    let streamTtl: Int?

    enum CodingKeys: String, CodingKey {
        case host
        case extra
        case streamTtl = "stream_ttl"
    }
}

private struct LiveRoomDTO: Decodable, Sendable {
    let roomid: Int
    let title: String
    let uname: String
    let areaName: String
    let coverURL: URL?
    let online: Int

    var model: BiliLiveRoom {
        BiliLiveRoom(
            id: roomid,
            title: title,
            hostName: uname,
            areaName: areaName,
            coverURL: coverURL,
            viewerCount: online
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        roomid = container.decodeInt(keys: ["roomid"]) ?? 0
        title = container.decodeString(keys: ["title"]) ?? "直播間"
        uname = container.decodeString(keys: ["uname"]) ?? "Unknown"
        areaName = container.decodeString(keys: ["area_name", "area_v2_name", "parent_name"]) ?? ""
        coverURL = container.decodeString(keys: ["cover", "user_cover", "system_cover", "show_cover"])?.httpsURL
        online = container.decodeInt(keys: ["online"]) ?? 0
    }
}
