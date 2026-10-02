import Foundation

enum HomeCategory: String, CaseIterable, Identifiable, Sendable {
    case recommend
    case follow
    case popular
    case live
    case anime
    case game
    case knowledge
    case tech
    case search

    var id: String { rawValue }

    static let androidTabs: [HomeCategory] = [
        .recommend,
        .follow,
        .popular,
        .live,
        .anime,
        .game,
        .knowledge,
        .tech
    ]

    var title: String {
        switch self {
        case .recommend: "推荐"
        case .follow: "关注"
        case .popular: "热门"
        case .live: "直播"
        case .anime: "追番"
        case .game: "游戏"
        case .knowledge: "知识"
        case .tech: "科技"
        case .search: "搜索"
        }
    }

    var regionTid: Int? {
        switch self {
        case .anime: 13
        case .game: 4
        case .knowledge: 36
        case .tech: 188
        default: nil
        }
    }
}

enum PopularSubCategory: String, CaseIterable, Identifiable, Sendable {
    case comprehensive
    case ranking
    case weekly
    case precious

    var id: String { rawValue }

    var title: String {
        switch self {
        case .comprehensive: "综合热门"
        case .ranking: "排行榜"
        case .weekly: "每周必看"
        case .precious: "入站必刷"
        }
    }
}

struct BiliVideo: Identifiable, Hashable, Codable, Sendable {
    var id: String { bvid.isEmpty ? "\(aid)" : bvid }

    let bvid: String
    let aid: Int
    let cid: Int
    var title: String
    let ownerName: String
    let coverURL: URL?
    let duration: Int
    var viewCount: Int
    var danmakuCount: Int
    var likeCount: Int
    /// Total reply / comment count.  Surfaced on `VideoCard`
    /// so the home feed shows 评论数 next to 弹幕数 — without
    /// this the upstream `/x/web-interface/view` `stat.reply`
    /// value is silently dropped (the DTO only decoded view,
    /// danmaku, and like). Defaults to `0` so feed entries
    /// from sources that don't surface `stat.reply` (search
    /// results, dynamic-feed archive rows) still render.
    var replyCount: Int = 0
    /// Publish date / time. Bilibili's `pubdate` field is a
    /// Unix timestamp in seconds; we decode it as `Date?` and
    /// render it on the card as a relative age
    /// ("3 天前" / "2 周前" / "2024-12-01") via
    /// `VideoCard.relativeDateLabel`. Defaults to `nil` so
    /// feed entries that don't surface `pubdate` still
    /// compile and render.
    var publishDate: Date? = nil
    let description: String
    /// Owner's Bilibili `mid` (64-bit user id). Populated by
    /// `VideoDTO` from the `/x/web-interface/view` response;
    /// left at `0` for feed-entry shapes (HomeRecommendCard,
    /// dynamic-feed archive, history rows) where the upstream
    /// payload does not surface the owner's mid. Used by
    /// `BilibiliAPIClient.aiSummary(...)` as the required
    /// `up_mid` query parameter — a mismatched or missing
    /// owner id causes Bilibili's WBI rate-limiter to reject
    /// the request with -403 风控. The repository guard at
    /// `aiSummary(for:)` short-circuits when this is `0`.
    let ownerMid: Int64

    /// Optional timestamp (in seconds) to resume playback from.
    /// Used when opening a video from history or a direct link
    /// that carries a progress marker.
    var resumeTime: Double? = nil
    /// Owner's 大会员 badge, populated from feed rows that
    /// include the upstream `owner.vip` block (the home
    /// recommend endpoint, dynamic-feed archive). `nil` for
    /// feed-entry shapes (search results, history rows) that
    /// don't publish the owner VIP info — those rows simply
    /// render the owner name without a badge.
    var ownerVIPBadge: BiliVIPBadge? = nil
}

extension BiliVideo {
    /// Canonical share URL for this video on bilibili.com.
    /// Centralised so the toolbar and fullscreen-player share
    /// buttons cannot drift. Returns `nil` for `bvid`-less
    /// rows (legacy `aid`-only entries); the share affordance
    /// silently hides in that case.
    var shareURL: URL? {
        guard !bvid.isEmpty else { return nil }
        return URL(string: "https://www.bilibili.com/video/\(bvid)")
    }
}

/// Public profile card for a Bilibili user. Returned by
/// `/x/space/wbi/acc/info` and surfaced on `UPProfileView` as
/// the header row. `sign` is the user's signature (a free-form
/// one-liner); `level` is the user-growth level (0-6); `vipType`
/// is the legacy VIP type code (0 = none).
///
/// `vipBadge` carries the rich 大会员 badge — text, colours, theme
/// — projected from the upstream `vip` block. Optional so a
/// partial upstream response (e.g. a banned or shadow-banned
/// user, or a future API drift that drops the field) still
/// renders without the badge rather than failing the whole card.
struct BiliUserCard: Codable, Hashable, Sendable {
    let mid: Int64
    let name: String
    let faceURL: URL?
    let sign: String
    let level: Int
    let vipType: Int
    let vipBadge: BiliVIPBadge?

    init(
        mid: Int64,
        name: String,
        faceURL: URL? = nil,
        sign: String = "",
        level: Int = 0,
        vipType: Int = 0,
        vipBadge: BiliVIPBadge? = nil
    ) {
        self.mid = mid
        self.name = name
        self.faceURL = faceURL
        self.sign = sign
        self.level = level
        self.vipType = vipType
        self.vipBadge = vipBadge
    }

    // MARK: - Codable

    /// Custom decoder so the new `vipBadge` field stays
    /// backwards-compatible with previously persisted JSON that
    /// does not have it. The upstream `vip` block on
    /// `/x/space/wbi/acc/info` is a nested object with `type`,
    /// `status`, and `label` — those are projected through
    /// `BilibiliNavVIPDTO` (defined in `BilibiliVIP.swift`) and
    /// then collapsed to a `BiliVIPBadge` via `.badge()`.
    /// We do not decode `BiliVIPBadge` directly because its
    /// fields use our internal hex / kind naming, not the
    /// upstream snake_case shape.
    private enum CodingKeys: String, CodingKey {
        case mid, name, sign, level, vipType
        case faceURL = "face"
        case vipBadge = "vip"
        case vipLabel
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mid = try c.decode(Int64.self, forKey: .mid)
        name = try c.decode(String.self, forKey: .name)
        sign = try c.decodeIfPresent(String.self, forKey: .sign) ?? ""
        level = try c.decodeIfPresent(Int.self, forKey: .level) ?? 0
        vipType = try c.decodeIfPresent(Int.self, forKey: .vipType) ?? 0
        if let url = try c.decodeIfPresent(String.self, forKey: .faceURL) {
            faceURL = URL(string: url.hasPrefix("//") ? "https:\(url)" : url)
        } else {
            faceURL = nil
        }
        // Decode the upstream vip block via the DTO and project
        // to our render-ready badge. `decodeIfPresent` returns
        // `nil` for a missing field (anonymous / banned user)
        // or a partial response, which collapses to "no badge".
        let vipDTO = try c.decodeIfPresent(
            BilibiliNavVIPDTO.self,
            forKey: .vipBadge
        )
        vipBadge = vipDTO?.badge()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(mid, forKey: .mid)
        try c.encode(name, forKey: .name)
        try c.encode(sign, forKey: .sign)
        try c.encode(level, forKey: .level)
        try c.encode(vipType, forKey: .vipType)
        try c.encodeIfPresent(faceURL, forKey: .faceURL)
        try c.encodeIfPresent(vipBadge, forKey: .vipBadge)
    }

    /// Convenience boolean consumed by the avatar / name row.
    /// `true` when the badge represents an active paid
    /// membership; false for `.none`, expired badges, and the
    /// no-badge case.
    var hasActiveVIP: Bool {
        vipBadge?.isActive == true && vipBadge?.isExpired == false
    }
}

/// Compact UP search result returned by Bilibili's
/// `/x/web-interface/wbi/search/type?search_type=bili_user`.
/// It is intentionally smaller than `BiliUserCard`: search rows need
/// avatar, name, follower count, and video count, while the full profile
/// screen still fetches the richer card once the user opens it.
struct BiliUserSearchResult: Identifiable, Hashable, Codable, Sendable {
    var id: Int64 { mid }

    let mid: Int64
    let name: String
    let faceURL: URL?
    let sign: String
    let fans: Int
    let videos: Int
}

/// One entry returned by the keystroke-rate suggest endpoint
/// `s.search.bilibili.com/main/suggest`.  The upstream wraps
/// the matched substring in `<em class="suggest_high_light">…</em>`
/// so the view can render the highlight as part of the row.
/// `displayName` strips those tags for plain-text contexts.
struct BiliSearchSuggestion: Identifiable, Hashable, Decodable, Sendable {
    var id: String { name }

    /// Raw upstream value — keeps the `<em>` highlight spans
    /// so the row renderer can render them.
    let name: String
    /// Optional bvid when the term resolves to a known video.
    /// Lets the iOS app jump straight to `VideoDetailView`
    /// without a second search-type round-trip.
    let bvid: String?
    /// Optional aid (article id) when the term resolves to a
    /// known 专栏 / 番剧 / 直播 entry.  Decoded as `Int` because
    /// the upstream sometimes sends it as a numeric string.
    let aid: String?
    /// Term type — 1 = tag, 2 = hot-word, 3 = history, etc.
    let termType: Int?

    enum CodingKeys: String, CodingKey {
        case name
        case bvid
        case aid
        case termType = "term_type"
    }

    /// Plain-text name with the `<em>…</em>` highlight tags
    /// stripped.  Useful for accessibility labels and the
    /// on-submit echo.
    var displayName: String {
        name.replacingOccurrences(
            of: #"<[^>]+>"#,
            with: "",
            options: .regularExpression
        )
    }
}

/// Aggregated "全部" search results across the five type slots.
/// `searchAll(keyword:page:)` on `BilibiliAPIClient` returns
/// this so the iOS app can render a merged result page in one
/// shot instead of running five separate `search-type` calls.
struct BiliAllSearchResults: Sendable {
    var videos: [BiliVideo] = []
    var users: [BiliUserSearchResult] = []
    var bangumi: [VideoDTO] = []    // raw DTOs; the UI can re-decode via BangumiCard
    var liveRooms: [VideoDTO] = []  // ditto
    var articles: [VideoDTO] = []   // ditto

    var isEmpty: Bool {
        videos.isEmpty && users.isEmpty && bangumi.isEmpty
            && liveRooms.isEmpty && articles.isEmpty
    }
}

// MARK: - 番剧 (Bangumi / PGC season)
//
// Minimal data shapes for the bangumi timeline surface.  The
// upstream `/pgc/web/timeline` endpoint returns a list of
// "days" (周一 through 周日) and each day carries the season
// cards that update that day.  We don't reproduce the full
// upstream schema — just the fields the home timeline UI
// surfaces (cover, title, latest-episode index, share URL).
// Detailed season / episode metadata is loaded on demand via
// the `seasonId` if/when we add a detail view; out of scope
// for this first pass.

/// One season card in the bangumi timeline.  The cell renders
/// `cover`, `title`, and `updateDescription` ("更新至第 12 话"
/// / "已完结" / "即将开播" / etc.) and on tap opens
/// `shareURL` in the system handler (SFSafariViewController
/// or the official app via Universal Links).  We don't
/// navigate to an in-app detail screen — the web surface
/// already carries episodes, comments, and the official
/// player.
struct BangumiCard: Identifiable, Hashable, Sendable {
    let seasonId: Int64
    let title: String
    let coverURL: URL?
    let updateDescription: String
    let badgeText: String?
    let shareURL: URL?
    var id: Int64 { seasonId }
}

/// One day in the weekly timeline.  Sorted ascending by
/// `weekday` (1 = Monday, 7 = Sunday) so the timeline always
/// starts on the same weekday in the UI regardless of when
/// the user opens the screen.  Cards inside a day are in
/// upstream order (typically: most-viewed first).
struct BangumiDay: Identifiable, Hashable, Sendable {
    let weekday: Int          // 1 = Mon … 7 = Sun
    let weekdayLabel: String  // localized "周一" … "周日"
    let date: String?         // upstream-supplied "MM-DD" for the upcoming slot
    let cards: [BangumiCard]
    var id: Int { weekday }
}

extension BangumiDay {
    /// Localised "周一" … "周日" for the upstream
    /// `day_of_week` (1 = Monday … 7 = Sunday).  Used by
    /// the timeline section header; mirrors what
    /// `BilibiliAPIClient.bangumiTimeline(...)` already
    /// attaches via `weekdayLabel`, but kept here for
    /// unit tests and any test-only fixtures that build a
    /// `BangumiDay` by hand.
    static func weekdayLabel(for weekday: Int) -> String {
        switch weekday {
        case 1: "周一"
        case 2: "周二"
        case 3: "周三"
        case 4: "周四"
        case 5: "周五"
        case 6: "周六"
        case 7: "周日"
        default: "周\(weekday)"
        }
    }
}

/// Relation between the signed-in user and another UP. Mirrors
/// Bilibili's `/x/relation` `attribute` field — `1` is followed,
/// `2` is the special "悄悄关注" (silent follow) state, `6` is
/// blocked. Anything else (including the unsigned-in case, where
/// the endpoint refuses to answer) collapses to `.notRelated`
/// so the ViewModel can decide whether to show a "Follow" CTA
/// or skip the button entirely.
enum BiliRelation: Int, Codable, Hashable, Sendable {
    case notRelated = 0
    case followed = 1
    case silentFollow = 2
    case blocked = 6

    init(attribute: Int) {
        self = BiliRelation(rawValue: attribute) ?? .notRelated
    }

    /// `true` when the user is already following this UP in any
    /// capacity. The follow button shows the inverse action
    /// ("已关注" / "取消关注") and a different icon based on this.
    var isFollowing: Bool {
        self == .followed || self == .silentFollow
    }
}

/// Bilibili's official "AI 视频总结" payload returned by
/// `/x/web-interface/view/conclusion/get`. The summary text is
/// Markdown-formatted prose from B站's NLP pipeline; the
/// outline is a chapter list with second-precision timestamps
/// that the player can seek to. We render `summary` via
/// `Text(.init(...))` so the native `LocalizedStringKey`
/// formatter handles `**bold**`, `_italic_`, and
/// `[link](url)` without pulling in a Markdown parser.
///
/// The endpoint returns this struct's `summary` and `outline`
/// populated for videos that have an AI summary yet. Videos
/// without one return `code != 0` and the repository layer
/// maps that to `nil` — the ViewModel treats `nil` as
/// "no section to render" rather than an error state.
///
/// Field provenance — every field below is documented in the
/// upstream `bilibili-API-collect` repo at
/// `docs/video/summary.md` (B站's official API spec).  Do not
/// invent fields: this endpoint is not backwards-compatible and
/// B站 has previously broken downstream clients when they
/// relied on undocumented shapes.
struct BiliAISummary: Codable, Hashable, Sendable {
    /// One-paragraph summary of the whole video. Markdown
    /// formatted by B站's NLP pipeline. May be empty when
    /// `resultType == 0`.
    let summary: String
    /// Chapter outline. Empty when `resultType` is `0` or `1`;
    /// always populated when `resultType == 2`.
    let outline: [BiliAISummaryChapter]
    /// AI-generated subtitle cards. The upstream doc shows
    /// `subtitle[]` with one element containing `part_subtitle`
    /// bullets. Not surfaced in the detail view today but
    /// decoded so future builds can fall back to it for
    /// transcripts when the AI summary is missing.
    let subtitle: [BiliAISummarySubtitle]
    /// `0` = no summary (B站 rejected the video — sensitive
    /// content, gated region, etc.); `1` = summary text only;
    /// `2` = summary + outline. Mirrors `data.code` from the
    /// upstream envelope.
    let resultType: Int
    /// Upstream-supplied like counter for the AI summary. The
    /// POST `/x/web-interface/view/conclusion/set` endpoint
    /// (SESSDATA + bili_jct required) updates this value.
    let likeNum: Int
    /// Upstream-supplied dislike counter for the AI summary.
    let dislikeNum: Int
    /// Upstream summary id, required by the
    /// `/x/web-interface/view/conclusion/set` like/dislike
    /// endpoint. Persisted so a future "like the summary"
    /// button can fire the POST without re-fetching.
    let stid: String

    var isEmpty: Bool {
        summary.isEmpty && outline.isEmpty && subtitle.isEmpty
    }

    /// Wire → Swift field map. B站 ships snake_case; Swift
    /// convention here is camelCase. Hand-rolled rather than
    /// `JSONDecoder.keyDecodingStrategy` because the rest of
    /// this file uses synthesized Codable for fields that
    /// already match the wire format.
    private enum CodingKeys: String, CodingKey {
        case summary, outline, subtitle, stid
        case resultType = "result_type"
        case likeNum = "like_num"
        case dislikeNum = "dislike_num"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        outline = try c.decodeIfPresent([BiliAISummaryChapter].self, forKey: .outline) ?? []
        subtitle = try c.decodeIfPresent([BiliAISummarySubtitle].self, forKey: .subtitle) ?? []
        resultType = try c.decodeIfPresent(Int.self, forKey: .resultType) ?? 0
        likeNum = try c.decodeIfPresent(Int.self, forKey: .likeNum) ?? 0
        dislikeNum = try c.decodeIfPresent(Int.self, forKey: .dislikeNum) ?? 0
        stid = try c.decodeIfPresent(String.self, forKey: .stid) ?? ""
    }

    init(summary: String,
         outline: [BiliAISummaryChapter],
         subtitle: [BiliAISummarySubtitle] = [],
         resultType: Int = 2,
         likeNum: Int = 0,
         dislikeNum: Int = 0,
         stid: String = "") {
        self.summary = summary
        self.outline = outline
        self.subtitle = subtitle
        self.resultType = resultType
        self.likeNum = likeNum
        self.dislikeNum = dislikeNum
        self.stid = stid
    }
}

/// One chapter in the AI summary outline. Bilibili publishes
/// `timestamp` as raw seconds (an Int); the ViewModel renders
/// it as `HH:MM:SS` / `MM:SS` via `timestampLabel`.
///
/// The wire shape (per `bilibili-API-collect`) is
/// `{title, part_outline: [{timestamp, content}, ...], timestamp}` —
/// each chapter has its own bullet list. Tapping a chapter
/// title seeks to the chapter's start; tapping a bullet seeks
/// to that bullet's start. Earlier Paladala builds decoded
/// `outline[i].content` directly, which is null on the wire —
/// the chapter body was rendering empty as a result.
struct BiliAISummaryChapter: Codable, Hashable, Identifiable, Sendable {
    let title: String
    /// Bullet points elaborating this chapter. Each bullet has
    /// its own seek-to timestamp; tapping one seeks the player
    /// to that exact moment. Empty for `resultType == 1`.
    let partOutline: [BiliAISummaryBullet]
    /// Chapter start timestamp in seconds.
    let timestamp: Int

    var id: Int { timestamp }

    var timestampLabel: String {
        Self.formatTimestamp(seconds: timestamp)
    }

    static func formatTimestamp(seconds: Int) -> String {
        let total = max(0, seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    private enum CodingKeys: String, CodingKey {
        case title, timestamp
        case partOutline = "part_outline"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        partOutline = try c.decodeIfPresent([BiliAISummaryBullet].self, forKey: .partOutline) ?? []
        timestamp = try c.decodeIfPresent(Int.self, forKey: .timestamp) ?? 0
    }

    init(title: String,
         partOutline: [BiliAISummaryBullet],
         timestamp: Int) {
        self.title = title
        self.partOutline = partOutline
        self.timestamp = timestamp
    }
}

/// One bullet inside an AI summary chapter. Each bullet has
/// its own timestamp the player can seek to; `content` is a
/// one-line description of the bullet.
struct BiliAISummaryBullet: Codable, Hashable, Identifiable, Sendable {
    let content: String
    let timestamp: Int

    var id: Int { timestamp }

    var timestampLabel: String {
        BiliAISummaryChapter.formatTimestamp(seconds: timestamp)
    }

    private enum CodingKeys: String, CodingKey {
        case content, timestamp
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        timestamp = try c.decodeIfPresent(Int.self, forKey: .timestamp) ?? 0
    }

    init(content: String, timestamp: Int) {
        self.content = content
        self.timestamp = timestamp
    }
}

/// AI subtitle card. The upstream serves at most one entry
/// here (the array always has length 0 or 1); the actual
/// subtitle line list lives inside `partSubtitle`. Decoded
/// today so the data is on hand when we want to surface an
/// auto-generated transcript.
struct BiliAISummarySubtitle: Codable, Hashable, Identifiable, Sendable {
    let partSubtitle: [BiliAISummarySubtitleLine]
    let timestamp: Int
    let title: String

    var id: Int { timestamp }

    private enum CodingKeys: String, CodingKey {
        case timestamp, title
        case partSubtitle = "part_subtitle"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        partSubtitle = try c.decodeIfPresent([BiliAISummarySubtitleLine].self, forKey: .partSubtitle) ?? []
        timestamp = try c.decodeIfPresent(Int.self, forKey: .timestamp) ?? 0
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
    }

    init(partSubtitle: [BiliAISummarySubtitleLine], timestamp: Int, title: String) {
        self.partSubtitle = partSubtitle
        self.timestamp = timestamp
        self.title = title
    }
}

struct BiliAISummarySubtitleLine: Codable, Hashable, Identifiable, Sendable {
    let content: String
    let startTimestamp: Double
    let endTimestamp: Double

    var id: Double { startTimestamp }

    private enum CodingKeys: String, CodingKey {
        case content
        case startTimestamp = "start_timestamp"
        case endTimestamp = "end_timestamp"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        // Wire uses ints (seconds); decoder accepts both via
        // the type system falling through to `Double`.
        startTimestamp = try c.decodeIfPresent(Double.self, forKey: .startTimestamp)
            ?? Double(try c.decodeIfPresent(Int.self, forKey: .startTimestamp) ?? 0)
        endTimestamp = try c.decodeIfPresent(Double.self, forKey: .endTimestamp)
            ?? Double(try c.decodeIfPresent(Int.self, forKey: .endTimestamp) ?? 0)
    }

    init(content: String, startTimestamp: Double, endTimestamp: Double) {
        self.content = content
        self.startTimestamp = startTimestamp
        self.endTimestamp = endTimestamp
    }
}

/// One playable Bilibili source.  The local HLS proxy turns
/// this into an HLS manifest on a 127.0.0.1 loopback HTTP
/// server (`LocalHLSProxyServer`), so a single `BiliPlayback`
/// is enough to start a video.
struct BiliPlayback: Hashable, Sendable {
    /// `nil` for the rare legacy `durl` MP4 case; populated for
    /// the much-more-common DASH case (the case the proxy exists
    /// for).
    let dash: BiliDashSource?
    /// Legacy `durl` MP4 URL — used as a fallback when the
    /// upstream returns no `dash` field.  Also the slot for
    /// live HLS URLs (the proxy is unnecessary for those —
    /// AVPlayer consumes HLS natively and we just inject the
    /// `Referer` header on the AVURLAsset).
    let fallbackURL: URL?
    let referer: URL

    /// Optional timestamp (in seconds) to resume playback from.
    /// When set, the player seeks to this position before starting.
    var resumeTime: Double = 0

    /// When set, the bytes for `dash` live on disk in `directory`
    /// (an already-downloaded video).  `LocalHLSProxyServer` reads
    /// the init/media segments from the local files instead of the
    /// upstream CDN.  `referer` is preserved for any defensive
    /// header checks, but no upstream network calls are made.
    var localContext: LocalPlaybackContext?

    /// Video qn ladder the upstream is willing to serve for
    /// this video + this account, sourced from
    /// `data.accept_quality` on the playurl response. The
    /// quality menu reads this to *only* render rows the
    /// server actually returned — without it the menu
    /// hard-codes the full ladder and tapping 4K on a
    /// 1080P-only video wastes a playurl round-trip. `nil`
    /// when the upstream omits the field; the menu falls
    /// back to `BiliVideoQuality.allCases` in that case so
    /// a missing field is non-fatal.
    ///
    /// Defaulted to `nil` so call sites that build a
    /// `BiliPlayback` outside the playurl path
    /// (live-playback, downloaded-video, local-only) do not
    /// have to be updated as the field grows — they
    /// transparently fall through to the full ladder.
    var acceptQuality: [Int]? = nil

    /// Per-qn display strings from `data.accept_description`.
    /// Used as a fallback label for qn values the
    /// `BiliVideoQuality` enum does not yet model (B站
    /// occasionally rolls a test ladder that the menu
    /// surfaces as a raw integer until a future build grows
    /// the enum). Keyed by qn for O(1) lookup at render
    /// time. `nil` for legacy / PGC responses that omit the
    /// field.
    var acceptDescription: [Int: String]? = nil
    /// Audio ladder the upstream is willing to serve, sourced
    /// from `data.accept_audio_quality` on the playurl
    /// response. The audio menu reads this to *only* render
    /// rows the server actually returned; without it the
    /// menu hard-codes the full 4-step ladder and tapping
    /// 320 kbps on a video that only has 128 kbps AAC forces
    /// a no-track playurl round-trip. `nil` for legacy / PGC
    /// responses that omit the field; the menu falls back to
    /// `BiliAudioQuality.allCases` in that case so a missing
    /// field is non-fatal.
    var acceptAudioQuality: [Int]? = nil

    /// True if this playback can be served by the local HLS
    /// proxy.
    var isDASH: Bool { dash != nil || localContext != nil }

    /// The qn value B站 returned for the *selected* video
    /// track (`BiliDashSource.video`). The quality menu
    /// uses this when the user re-opens the menu and the
    /// currently-playing row is no longer in the cached
    /// `acceptQuality` set (e.g. a session-extension
    /// response). `nil` for the legacy `durl` path and
    /// for downloaded videos where the qn is unknown.
    var selectedVideoQn: Int? {
        dash?.video.qualityId
    }

    /// The audio id B站 returned for the *selected* audio
    /// track. Same rationale as `selectedVideoQn` for the
    /// audio menu. `nil` for video-only downloads.
    var selectedAudioQn: Int? {
        dash?.audio?.qualityId
    }

    /// **PR-X (Issue 1 — fullscreen↔PiP "video ended" regression)**:
    /// stable content-level identity hash. Two `BiliPlayback`
    /// values are content-equivalent when they represent the same
    /// playable content for the same video — same track
    /// selection, same codec, same byte ranges, same ladders.
    ///
    /// **Intentionally EXCLUDES** the session-specific fields
    /// inside `dash.video.baseURL` / `backupURLs` / audio URLs.
    /// Those URLs carry `upsig` / `uipk` / `deadline` / `mid` /
    /// `trid` and rotate on every B站 playurl fetch — so the
    /// default `Hashable` conformance (which compares full URL
    /// strings) sees two fetches of the same video as different
    /// values. Before PR-X, `MiniPlayerStore.bind` would treat
    /// that as "playback changed" and tear down the active
    /// controller + build a new one, surfacing as a visible
    /// "video restart" when the user toggled fullscreen / PiP
    /// and SwiftUI re-fired `.task` → `model.load` → new
    /// playurl. The bug was masked by the fact that Bilibili
    /// returns the same host ladder and same byte ranges, only
    /// the query string changes.
    ///
    /// `MiniPlayerStore.bind` now compares this identity instead
    /// of the full Hashable equality, so a re-fetch for the same
    /// video is treated as a no-op re-bind and the existing
    /// `AVPlayerController` keeps running.
    ///
    /// Two playbacks that differ in `qualityId` / `codecs` /
    /// `width` / `height` / `initRange` / `indexRange` /
    /// `mediaStartOffset` / `totalDuration` / `acceptQuality` /
    /// `acceptAudioQuality` / `acceptDescription` / `fallbackURL`
    /// host / `localContext` directory DO produce different
    /// identities — quality switches, fallback swaps, and
    /// download re-opens still trigger a clean teardown + rebuild.
    var contentIdentity: String {
        var parts: [String] = []
        if let dash {
            parts.append("v:" + Self.trackContentIdentity(dash.video))
            if let audio = dash.audio {
                parts.append("a:" + Self.trackContentIdentity(audio))
            }
        }
        if let fallback = fallbackURL {
            parts.append("fb:" + Self.urlContentIdentity(fallback))
        }
        if let local = localContext {
            // Local download paths vary on a per-bvid basis
            // but NOT per-fetch — a stable identity.
            parts.append("loc:" + local.directory.standardizedFileURL.path)
        }
        if let accept = acceptQuality {
            parts.append("aq:" + accept.map(String.init).joined(separator: ","))
        }
        if let acceptAudio = acceptAudioQuality {
            parts.append("aa:" + acceptAudio.map(String.init).joined(separator: ","))
        }
        if let desc = acceptDescription {
            // Sort the dict so the same ladder in different
            // iteration order still hashes to the same string.
            let sorted = desc.sorted { $0.key < $1.key }
            parts.append(
                "ad:" + sorted.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
            )
        }
        return parts.isEmpty ? "empty" : parts.joined(separator: "|")
    }

    /// `Track` content identity — what makes one video track
    /// "the same content" as another. Excludes the full
    /// `baseURL` / `backupURLs` query string (session tokens)
    /// but keeps the host + path (which DOES change with CDN
    /// failover, and a host change means the proxy needs to
    /// re-resolve through DNS).
    private static func trackContentIdentity(_ t: BiliDashSource.Track) -> String {
        let url = Self.urlContentIdentity(t.baseURL)
        let backups = t.backupURLs
            .map(Self.urlContentIdentity)
            .joined(separator: ",")
        let initRange = "\(t.initializationRange.offset):\(t.initializationRange.length)"
        let indexRange = t.indexRange.map { "\($0.offset):\($0.length)" } ?? "nil"
        let dims = "\(t.width ?? 0)x\(t.height ?? 0)"
        // `%.3f` keeps the duration string stable across runs
        // (Double toString can drift on binary boundaries).
        return [
            t.qualityId.map(String.init) ?? "nil",
            t.codecs,
            String(t.bandwidth),
            t.mimeType,
            dims,
            initRange,
            indexRange,
            String(t.mediaStartOffset),
            String(format: "%.3f", t.totalDuration),
            url,
            backups
        ].joined(separator: ";")
    }

    /// `host + path` of the URL, deliberately dropping the
    /// query string and fragment. The query carries
    /// `upsig` / `uipk` / `deadline` / `mid` / `trid` which
    /// rotate on every fetch and would otherwise break the
    /// content-identity comparison.
    private static func urlContentIdentity(_ url: URL) -> String {
        let host = url.host ?? ""
        let path = url.path
        return host.isEmpty ? path : host + path
    }
}

/// Pointer to an on-disk download that the local HLS proxy
/// should serve instead of fetching from the B 站 CDN.  Set on
/// `BiliPlayback.localContext` when `VideoDetailView` opens a
/// `DownloadRecord`; the proxy then re-routes the init / media
/// file handlers to `directory` instead of `currentPlayback`.
///
/// The struct is intentionally tiny — the heavy data
/// (`BiliDashSource` tracks, byte ranges, etc.) already lives
/// on `BiliPlayback.dash`.  The only thing the proxy needs to
/// know is *where on disk* to read the bytes from.
///
/// `mergedVideo` / `mergedAudio` carry the canonical single-file
/// path the new merge step writes at download-complete time.
/// When present, `AVPlayerController` short-circuits the proxy
/// entirely and plays the merged mp4 via
/// `AVMutableComposition` — eliminating the upstream-offset
/// byte-range math the previous layout depended on (and that
/// silently broke on every offset shift, see the recent
/// `Fix downloaded video local ranges` commit).  `nil` for
/// either field means the merged file is missing (legacy
/// download before the merge step landed, or Caches purge) —
/// callers should fall back to the proxy path with the 4-file
/// layout under `directory`.
struct LocalPlaybackContext: Hashable, Sendable {
    /// `Caches/Paladala/Downloads/ready/{bvid}/`.  The init and
    /// media m4s files for the video and audio tracks live
    /// directly under this directory.
    let directory: URL
    /// `directory/video.mp4` — the post-merge single-file video
    /// track.  `nil` when the merge step has not yet run for
    /// this download.
    let mergedVideo: URL?
    /// `directory/audio.mp4` — the post-merge single-file audio
    /// track.  `nil` when the download is video-only or the
    /// merge step has not yet run.
    let mergedAudio: URL?
}

/// One row in `DownloadStore.records`.  Persisted as part of
/// `manifest.json`.
///
/// Path-storage note
/// -----------------
/// This struct deliberately holds **no** `URL` or string
/// path field.  The on-disk location
/// (`Caches/Paladala/Downloads/ready/{bvid}/`) is recomputed
/// on every read from the `bvid` via
/// `DownloadStore.readyDirectory(for:)`.  iOS may rotate the
/// sandbox container UUID between launches (Build 126's
/// `443D6288-…` became Build 127's `579E46FD-…` in one
/// observed run), so persisting any absolute path would
/// silently rot on the next build and the player would 404
/// on every segment.  Only `bvid` is treated as a stable
/// identity; the directory URL is always derived at runtime.
struct DownloadRecord: Codable, Identifiable, Hashable, Sendable {
    /// `bvid` doubles as the primary key (`BiliVideo.id` is
    /// `bvid ?? "\(aid)"`), and the on-disk directory name.
    var id: String { bvid }
    let bvid: String
    let aid: Int
    let cid: Int
    let title: String
    let ownerName: String
    let coverURL: URL?
    let duration: Int
    /// `BiliDashSource` as it existed at download time.  Needed
    /// by `LocalHLSProxyServer.serveLocal(...)` so the synthesised
    /// `playlist.m3u8` matches the on-disk bytes (byte ranges,
    /// codecs, bandwidth, …).  We keep the full source rather
    /// than a slim summary because the struct is tiny and the
    /// alternative — re-fetching the playurl API offline —
    /// is impossible.
    let dash: BiliDashSource
    let referer: URL
    let downloadedAt: Date
    let sizeBytes: Int64

    /// Re-hydrate the `BiliVideo` shape the rest of the app
    /// already speaks.  Used by `DownloadedVideosView` so the
    /// row does not have to know about the `DownloadRecord`
    /// shape itself.
    var video: BiliVideo {
        BiliVideo(
            bvid: bvid,
            aid: aid,
            cid: cid,
            title: title,
            ownerName: ownerName,
            coverURL: coverURL,
            duration: duration,
            viewCount: 0,
            danmakuCount: 0,
            likeCount: 0,
            description: "",
            ownerMid: 0
        )
    }
}

/// `BiliDashSource` is the DASH description we extract from
/// B站's playurl response and feed to `LocalHLSProxyServer`.
/// The proxy synthesises an HLS master playlist from these
/// tracks, so AVPlayer consumes a format it already understands
/// natively.
///
/// Important: B站's `dash.video[].baseUrl` and
/// `dash.audio[].baseUrl` are each *one whole m4s file* (B站
/// does not publish a per-segment `SegmentTemplate` here). The
/// m3u8 generator therefore emits a media playlist with a
/// single `EXTINF` entry whose duration is the track's
/// `totalDuration`, and lets AVPlayer stream the file via HTTP
/// `Range` requests through the proxy.
struct BiliDashSource: Hashable, Codable, Sendable {
    struct ByteRange: Hashable, Codable, Sendable {
        let offset: Int64
        let length: Int64

        var endOffset: Int64 {
            offset + length - 1
        }
    }

    /// A single AdaptationSet, plus its Representation.
    /// We flatten audio + video variants into this struct
    /// because B站's DASH responses are simple enough that we
    /// can skip the full MPD Period/AdaptationSet tree.
    struct Track: Hashable, Codable, Sendable {
        let baseURL: URL
        /// CDN failover URLs B站 ships alongside `baseUrl` in
        /// the playurl response (per
        /// `bilibili-API-collect/docs/video/videostream_url.md`,
        /// both `backup_url` and `backupUrl` keys surface). The
        /// `LocalHLSProxyServer` cycles through these when the
        /// primary host returns 5xx, times out, or stalls
        /// mid-segment. Order is upstream's preference —
        /// `backup_url[0]` is B站's own first-choice failover,
        /// `[1]` is the secondary, etc.
        ///
        /// Empty in the rare cases B站 only publishes a single
        /// host (mostly old or region-locked videos). The
        /// proxy treats `backupURLs.isEmpty` as "no failover
        /// available; surface the upstream error to the user".
        let backupURLs: [URL]
        /// ISO BMFF `codecs` box string (e.g. `avc1.640028`,
        /// `mp4a.40.2`). Embedded into HLS via `CODECS`.
        let codecs: String
        /// Bandwidth in bits per second (B站's `bandwidth`
        /// field). Used in the master playlist's
        /// `EXT-X-STREAM-INF` `BANDWIDTH` attribute.
        let bandwidth: Int
        /// `mimeType` from the Representation, e.g.
        /// `video/mp4` / `audio/mp4`.
        let mimeType: String
        /// Byte range containing the fMP4 init section
        /// (`ftyp`/`moov`). HLS fMP4 playlists must expose this
        /// through `#EXT-X-MAP`; without it AVPlayer stalls while
        /// parsing the media playlist.
        let initializationRange: ByteRange
        /// Byte range of the DASH segment index (`sidx`) box.
        /// The proxy fetches this via Range request at serve
        /// time, parses the real `moof+mdat` fragments, and uses
        /// those as the source of truth for the generated HLS
        /// playlist. Required for spec-conformant fMP4 HLS — see
        /// `MP4Fragment.swift` for the parser and the rationale
        /// for why equal-byte splitting was wrong.
        ///
        /// Optional: some older B 站 responses omit the sidx
        /// range (a `SegmentBase` is published but lacks
        /// `index_range`). In that case the proxy falls back to
        /// a single direct-MP4 segment instead of fabricating
        /// equal-byte media segments.
        let indexRange: ByteRange?
        /// Absolute byte offset where the playable media data
        /// starts in the upstream Bili m4s file.  This is the
        /// first byte **after** the init section, so the
        /// `sidx` (Segment Index Box) that B站 puts between
        /// init and media is served as the first bytes of the
        /// media response.  Dropping the `sidx` makes AVPlayer
        /// abort the download mid-stream.
        let mediaStartOffset: Int64
        /// Total presentation duration in seconds — B站's
        /// `dash.duration` divided by 1000 (B站 publishes
        /// milliseconds here).
        let totalDuration: Double
        /// Optional dimensions for video tracks. Audio tracks
        /// leave these nil.
        let width: Int?
        let height: Int?
        /// Representation id from the upstream MPD.
        ///  * For video tracks: matches the `accept_quality`
        ///    qn ladder (16/32/64/80/...).
        ///  * For audio tracks: matches the audio quality
        ///    ladder (30216 / 30232 / 30250 / 30280).
        /// The quality / audio menu reads this so the
        /// "currently selected" row can be checked in
        /// `BiliPlayback.selectedVideoQn` /
        /// `selectedAudioQn` without a network round-trip
        /// (e.g. after the user dismisses and re-opens the
        /// menu mid-playback). `nil` for legacy responses
        /// that omit the field.
        let qualityId: Int?

        /// All host candidates for this track — primary first,
        /// then backups in upstream's preferred order. Mirrors
        /// `LocalHLSProxyServer`'s failover cursor so the
        /// proxy and the player can reason about "where we
        /// are" without touching `currentPlayback`.
        var allHosts: [URL] {
            [baseURL] + backupURLs
        }
    }

    let video: Track
    let audio: Track?
}

struct BiliLiveRoom: Identifiable, Hashable, Sendable {
    let id: Int
    let title: String
    let hostName: String
    let areaName: String
    let coverURL: URL?
    let viewerCount: Int
}

/// Per-account overrides the App API needs to return a personalised
/// recommend list. Populated by `PaladalaApp.body.onAppear` from
/// the live `AuthStore` so that switching accounts in
/// `ProfileSettingsView` immediately takes effect on the next refresh.
///
/// `buvid3` is the device fingerprint the upstream uses to recognise
/// the client. When empty the App API gates the personalised response
/// and falls back to anonymous trending, which is why the iOS app
/// looked like 热门 when signed in.
///
/// `mid` is the active user's Bilibili ID. Sending it triggers the
/// personalised re-ranking; omitting it keeps the request valid but
/// downgrades the response to the anonymous flavour.
struct BiliAppConfig: Hashable, Sendable {
    let buvid3: String?
    let mid: Int64
    let csrf: String?
    /// `access_key` — the long-lived bearer token issued alongside
    /// SESSDATA by the app QR login flow. When set, commentsPage
    /// (and any future app-auth endpoint) can switch from the WBI
    /// sign path (which is silently gated on URLSession clients
    /// by the B站 风控 layer) to the appkey+sign path, which the
    /// official B站 iOS app uses and therefore bypasses the gate.
    let accessKey: String?

    var isPersonalised: Bool {
        mid > 0 && (buvid3?.isEmpty == false)
    }
}

/// `BiliLiveStreamFormat` describes the streaming protocol a live
/// room exposes. Bilibili rooms typically offer both an FLV stream
/// (lowest latency) and an HLS stream (works with stock players).
/// The player toggle in `LivePlayerView` flips between them.
enum BiliLiveStreamFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case hls
    case flv

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .hls: return "HLS"
        case .flv: return "FLV"
        }
    }
}

/// Stream URLs for a single live room, keyed by format. The HLS slot
/// may be absent on rooms whose CDN only exposes FLV, in which case
/// the player disables the toggle for that format.
struct BiliLivePlayback: Hashable, Sendable {
    let roomID: Int
    let title: String
    let hostName: String
    /// CDN candidates for the HLS playlist, in the order the
    /// upstream returned them. The HLS proxy (or AVPlayer on the
    /// direct path) walks the list when the current host errors.
    /// Empty when the room only exposes FLV.
    let hlsCandidates: [URL]
    /// CDN candidates for the FLV stream, same ordering rules.
    /// Empty when the room only exposes HLS.
    let flvCandidates: [URL]
    let referer: URL

    /// First HLS candidate, or `nil` when the room is FLV-only.
    var hlsURL: URL? { hlsCandidates.first }
    /// First FLV candidate, or `nil` when the room is HLS-only.
    var flvURL: URL? { flvCandidates.first }
}

/// Kinds of dynamic card the follow feed surfaces. The HTTP payload is
/// the same for all of them — they differ only by which `major.*`
/// module the upstream populates. The UI uses this enum to pick the
/// right card chrome (video card vs. 专栏 text vs. live-started banner
/// vs.转发 reposting the original post).
enum DynamicPostKind: String, Codable, Hashable, Sendable {
    case video
    case article
    case bangumi
    case liveStarted = "live_started"
    case forward

    /// Best-effort guess based on whether the upstream payload
    /// populated an attached video. Forwarded posts keep the
    /// original attached video, so the follow tab can still render
    /// the attached content inline.
    static func infer(attachedVideo: BiliVideo?) -> DynamicPostKind {
        guard attachedVideo != nil else { return .forward }
        return .video
    }
}

struct BiliComment: Identifiable, Hashable, Sendable {
    let id: Int
    let authorName: String
    let avatarURL: URL?
    let message: String
    let likeCount: Int
    let replyCount: Int
    let replies: [BiliComment]
    /// 大会员 badge projection from the upstream `member.vip`
    /// block. `nil` for non-VIP authors (most replies). The
    /// comment-row renderer reads this to display the colored
    /// chip next to the author name.
    let vipBadge: BiliVIPBadge?

    init(
        id: Int,
        authorName: String,
        avatarURL: URL? = nil,
        message: String,
        likeCount: Int = 0,
        replyCount: Int = 0,
        replies: [BiliComment] = [],
        vipBadge: BiliVIPBadge? = nil
    ) {
        self.id = id
        self.authorName = authorName
        self.avatarURL = avatarURL
        self.message = message
        self.likeCount = likeCount
        self.replyCount = replyCount
        self.replies = replies
        self.vipBadge = vipBadge
    }

    /// Convenience boolean used by the row chrome (subtitle /
    /// nickname color) so a non-VIP comment doesn't have to
    /// special-case the absent badge.
    var hasActiveVIP: Bool {
        vipBadge?.isActive == true && vipBadge?.isExpired == false
    }
}

struct CommentPage: Hashable, Sendable {
    let items: [BiliComment]
    /// Cursor for the next page, or `nil` when the page is the last.
    /// The cursor is a `CommentCursor` sum type so the endpoint
    /// family is part of the type system — a `.pn` cursor cannot be
    /// fed into a WBI endpoint by mistake. The sub-reply endpoint
    /// (`/x/v2/reply/reply`) does not round-trip this field —
    /// `ReplyListViewModel.loadMore` tracks its own `pn` page
    /// number, so the sub-reply path leaves `next` nil.
    let next: CommentCursor?
    let isEnd: Bool
    let totalCount: Int
}

struct DynamicPost: Identifiable, Hashable, Sendable {
    let id: String
    let author: String
    let authorAvatarURL: URL?
    let text: String
    let timeLabel: String
    let attachedVideo: BiliVideo?
    /// Best-effort classification of the card shape. The follow-feed
    /// DTO exposes the same `items[]` envelope for videos, 专栏, 番剧,
    /// 直播开播 and 转发, so the decoder does not always know which
    /// one the upstream populated. We infer the kind from which
    /// `major.*` module the payload carries and fall back to `.video`
    /// when an attached video is present. The UI uses this to pick the
    /// right card chrome — a 专栏 post has no thumbnail and should
    /// render as a long text block, a 直播开播 card should flash a
    /// "LIVE" badge, etc.
    var kind: DynamicPostKind {
        DynamicPostKind.infer(attachedVideo: attachedVideo)
    }
}

struct DynamicFeedPage: Hashable, Sendable {
    let items: [DynamicPost]
    let nextOffset: String
    let hasMore: Bool
    /// True when the request could not be served because the user is
    /// signed out. Used by `HomeView` to render the existing "登录后
    /// 查看关注动态" prompt without distinguishing empty-state from
    /// signed-out-state in the view layer.
    let needsLogin: Bool

    init(items: [DynamicPost], nextOffset: String, hasMore: Bool, needsLogin: Bool = false) {
        self.items = items
        self.nextOffset = nextOffset
        self.hasMore = hasMore
        self.needsLogin = needsLogin
    }
}

struct HistoryCursorState: Hashable, Sendable {
    let max: Int64
    let viewAt: Int64
    let business: String
}

struct HistoryEntry: Identifiable, Hashable, Sendable {
    let id: String
    let video: BiliVideo
    let viewedAt: Int64
    let progress: Int
}

struct HistoryPageResult: Hashable, Sendable {
    let items: [HistoryEntry]
    let nextCursor: HistoryCursorState?
}

struct FavoriteFolderSummary: Identifiable, Hashable, Sendable {
    let id: Int64
    let title: String
    let coverURL: URL?
    let mediaCount: Int
    let ownerName: String
}

struct FavoriteFolderVideosPage: Hashable, Sendable {
    let title: String
    let videos: [BiliVideo]
    let hasMore: Bool
}

struct ReplyRoute: Hashable, Sendable {
    let video: BiliVideo
    let rootComment: BiliComment
}

/// Navigation route to a UP (content creator) public profile.
/// Pushed onto the router's `path` by `AppRouter.openUP(mid:)`
/// and resolved by `RootView`'s `navigationDestination(for:)`
/// into `UPProfileView`. Lives here (not in `AppRouter.swift`)
/// so it can be `Hashable` alongside the other route values
/// without a circular import.
enum UPProfileRoute: Hashable, Sendable {
    case up(mid: Int64)
}

/// Sort order for the comment list. Persisted in `@AppStorage` so the
/// user's choice survives relaunch. `apiValue` matches Bilibili's
/// `/x/v2/reply/wbi/main` `mode` parameter: `3` is the default
/// ("热门"), `2` is chronological ("最新"). The reply-detail endpoint
/// (`/x/v2/reply/reply`) does not accept a `mode` parameter, so the
/// picker is gated to the main comment list.
enum CommentSort: String, CaseIterable, Identifiable, Codable, Sendable {
    case hot
    case newest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hot: "最热"
        case .newest: "最新"
        }
    }

    /// Bilibili's `mode` query value. `nil` means "do not send a mode
    /// parameter" — Bilibili then uses its default (hot).
    var apiValue: Int? {
        switch self {
        case .hot: nil
        case .newest: 2
        }
    }
}

// MARK: - Music / Lyrics
//
// Bilibili exposes per-video lyric tracks through `/x/player/v2`'s
// `subtitle.subtitles[]` array. The tracks arrive as either
// protocol-relative JSON (the AI-generated / "AI 字幕" case) or LRC
// plain text (the human-uploaded case). The Music view unifies both
// into a `BiliLyricTrack` so the playback view never has to think
// about the underlying encoding.

/// One lyric track published by the player endpoint. The
/// `subtitle_url` is a protocol-relative URL — callers must
/// resolve it against `https:` before fetching.
struct BiliLyricInfo: Hashable, Codable, Sendable {
    let id: Int64
    let lan: String
    let lanDoc: String
    /// Protocol-relative URL — prepended with `https:` to form a
    /// fetchable absolute URL. We keep the original so the model
    /// remains `Codable` round-trip-safe (the original may also
    /// already be absolute on rare tracks).
    let subtitleURL: String
    let author: String?

    enum CodingKeys: String, CodingKey {
        case id
        case lan
        case lanDoc = "lan_doc"
        case subtitleURL = "subtitle_url"
        case author
    }

    /// Compose a fetchable absolute URL by prepending `https:` if
    /// the upstream is protocol-relative. Returns `nil` when the
    /// URL string itself fails to parse — we treat that as "no
    /// lyric" so the UI shows the existing placeholder instead of
    /// a generic network error.
    var absoluteURL: URL? {
        let raw = subtitleURL.hasPrefix("//") ? "https:\(subtitleURL)" : subtitleURL
        return URL(string: raw)
    }
}

// `BiliLyricTrack` and `BiliLyricLine` were moved to
// `Music/Models/LyricTypes.swift` as part of the music section
// reintroduction (Phase 0b — directory regrouping). They remain
// visible to every file in the Paladala module by virtue of being
// declared at the top level in a target source file; no
// typealias is required.

// MARK: - Video Danmaku

/// One timed danmaku entry from `https://comment.bilibili.com/{cid}.xml`.
/// The first field in `p` is the start time in seconds; the second is
/// Bilibili's display mode (`1` scrolling, `4` bottom, `5` top, etc.).
struct BiliDanmakuItem: Hashable, Codable, Identifiable, Sendable {
    let id: Int
    let time: Double
    let mode: Int
    let fontSize: Int
    let color: Int
    let text: String
}

/// Navigation routes for the 追番 surface.
enum BangumiRoute: Hashable, Sendable {
    /// Open the weekly timeline. Same view as the
    /// `MainTab.bangumi` tab content; pushed onto the
    /// stack when the user enters via the profile
    /// "追番追剧" quick action.
    case timeline
    /// Open the in-app PGC season detail page.  Pushed
    /// when the user taps a season card on the timeline
    /// or the dedicated in-app PGC player button.
    case seasonDetail(seasonId: Int64)
}

/// One PGC season's worth of metadata + episode list,
/// surfaced by `BangumiSeasonDetailView`.  The upstream
/// `/pgc/view/web/season?ep_id=...` response is decoded
/// into a small DTO; the card / title / desc render in
/// the season hero and each row in `episodes` becomes a
/// tappable episode cell.
struct BangumiSeasonDetail: Hashable, Sendable {
    let seasonId: Int64
    let title: String
    let desc: String?
    let coverURL: URL?
    let episodes: [BangumiEpisode]
    var id: Int64 { seasonId }
}

/// One episode inside a `BangumiSeasonDetail`.  We carry
/// the upstream `ep_id` (B站's stable per-episode id),
/// the long + short titles, the cover, the duration in
/// milliseconds, and the resolved `shareURL`.  When
/// in-app playback is unavailable the share URL is the
/// fallback (SFSafariViewController sheet).
struct BangumiEpisode: Hashable, Identifiable, Sendable {
    let epId: Int64
    let title: String
    let longTitle: String?
    let indexLabel: String
    let coverURL: URL?
    let durationMs: Int64?
    let shareURL: URL?
    var id: Int64 { epId }
}

// MARK: - Audio quality

/// Bilibili DASH audio track ids. Each representation in
/// `dash.audio[]` carries an integer `id` we use to pick the
/// preferred audio quality at playurl time. The mapping comes
/// straight from `bilibili-API-collect/docs/video/videostream_url.md`
/// and B站's own web player ladder:
///
/// | id     | label                       | VIP gate |
/// | ------ | --------------------------- | -------- |
/// | 30216  | 64 kbps AAC (low)           | no       |
/// | 30232  | 128 kbps AAC (standard)     | no       |
/// | 30250  | 320 kbps AAC (Hi-Res / 高码率) | yes   |
/// | 30280  | 192 kbps Dolby / 高码率     | yes      |
///
/// The Hi-Res / Dolby ids often require a 大会员 subscription;
/// the playurl endpoint either omits the audio track entirely
/// or returns it gated behind `dash.audio[].id` so the audio
/// quality menu must hide them for non-VIP users. The proxy
/// falls back to the highest available AAC track when the
/// requested id is absent.
enum BiliAudioQuality: Int, CaseIterable, Identifiable, Codable, Sendable {
    case low64 = 30216
    case standard128 = 30232
    case hiRes320 = 30250
    case dolby192 = 30280

    var id: Int { rawValue }

    /// Label rendered in the audio-quality menu.
    var title: String {
        switch self {
        case .low64: return L10n.player.audioQuality64
        case .standard128: return L10n.player.audioQuality128
        case .hiRes320: return L10n.player.audioQuality320
        case .dolby192: return L10n.player.audioQuality192
        }
    }

    /// True when this quality requires a paid 大会员 membership
    /// to unlock. The toolbar menu uses this to grey out the
    /// row for non-VIP users (and the playurl fetch uses it as
    /// a hint when no audio track is returned).
    var requiresVIP: Bool {
        switch self {
        case .low64, .standard128: return false
        case .hiRes320, .dolby192: return true
        }
    }

    /// Default for first-launch users who have not picked an
    /// audio quality yet. 128 kbps is universally available
    /// without VIP and matches what most web players fall
    /// back to.
    static let defaultID: Int = BiliAudioQuality.standard128.rawValue
}

// MARK: - Video quality

/// Bilibili DASH video qn ladder. Mirrors `accept_quality` in
/// the playurl response. Each entry knows whether it requires
/// a 大会员 membership to unlock so the quality menu can grey
/// the gated rows out for non-VIP users.
///
/// We intentionally model only the ladder entries the upstream
/// actually returns today; unknown qns the upstream occasionally
/// inserts (e.g. test ladders B站 rolls out then rolls back)
/// fall back to the bare integer label so the menu never
/// silently drops an entry.
enum BiliVideoQuality: Int, CaseIterable, Identifiable, Codable, Sendable {
    case p360 = 16
    case p480 = 32
    case p720 = 64
    case p1080 = 80
    case p1080Plus = 112
    case p1080P60 = 116
    case k4K = 120
    case hdr = 125
    case dolbyVision = 126
    case k8K = 127
    case p1080HiBitrate = 128
    case k4KHiBitrate = 129
    case k4KHDR = 130
    case k8KHDR = 131

    var id: Int { rawValue }

    /// Label rendered in the quality menu. Gated qualities
    /// automatically get a "大会员" suffix so the user can see
    /// why a row is dimmed when they are non-VIP.
    func title(isVIP: Bool) -> String {
        let base: String
        switch self {
        case .p360: base = L10n.player.quality360
        case .p480: base = L10n.player.quality480
        case .p720: base = L10n.player.quality720
        case .p1080: base = L10n.player.quality1080
        case .p1080Plus: base = L10n.player.quality1080Plus
        case .p1080P60: base = L10n.player.quality1080P60
        case .k4K: base = L10n.player.quality4K
        case .hdr: base = L10n.player.qualityHDR
        case .dolbyVision: base = L10n.player.qualityDolby
        case .k8K: base = L10n.player.quality8K
        case .p1080HiBitrate: base = L10n.player.quality1080Hi
        case .k4KHiBitrate: base = L10n.player.quality4KHi
        case .k4KHDR: base = L10n.player.quality4KHDR
        case .k8KHDR: base = L10n.player.quality8KHDR
        }
        if requiresVIP && !isVIP {
            return base + " · " + L10n.vip.lockedBadge
        }
        return base
    }

    /// True when this ladder entry is gated behind a paid
    /// 大会员 membership. Mirrors B站's `accept_description`
    /// matrix — anything 1080P and above (with rare 720P
    /// exceptions for legacy content) is VIP-gated.
    var requiresVIP: Bool {
        switch self {
        case .p360, .p480, .p720: return false
        case .p1080: return false
        case .p1080Plus, .p1080P60, .k4K, .hdr, .dolbyVision,
             .k8K, .p1080HiBitrate, .k4KHiBitrate, .k4KHDR, .k8KHDR:
            return true
        }
    }
}
