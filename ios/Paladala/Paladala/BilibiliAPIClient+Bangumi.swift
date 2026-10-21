import Foundation

// Bangumi / PGC: timeline, season detail, and PGC playurl.

extension BilibiliAPIClient {
    /// 番剧时间表.  Hits the public
    /// `/pgc/web/timeline` endpoint which returns seven
    /// "days" (周一 … 周日) with the season cards that
    /// update each day.  No WBI signing required — the
    /// endpoint is anonymous.
    ///
    /// Parameters
    ///  - `types`: 1 for 番剧 (default), 4 for 国创.
    ///  - `before` / `after`: how many days before/after
    ///    today to include; `6 / 6` covers a full week.
    ///
    /// Returns seven `BangumiDay`s, one per weekday, sorted
    /// ascending by `weekday` so the UI can start the row
    /// at Monday regardless of when the user opened the
    /// surface.  Days with no updates return an empty
    /// `cards` array (upstream still includes the day
    /// stub).
    func bangumiTimeline(types: Int = 1, before: Int = 6, after: Int = 6) async throws -> [BangumiDay] {
        // B 站 wraps the timeline payload in a `{code, message,
        // result}` envelope where `result` is the days array
        // (NOT a single keyed object).  The shared
        // `APIResponse<T>` envelope assumes `result: T` is
        // keyed-container-shaped, so we decode the raw
        // `BangumiTimelinePayload` envelope directly and do
        // the `code != 0` check ourselves.
        let payload: BangumiTimelinePayload = try await get(
            baseURL: baseURL,
            path: "/pgc/web/timeline",
            queryItems: [
                URLQueryItem(name: "types", value: "\(types)"),
                URLQueryItem(name: "before", value: "\(before)"),
                URLQueryItem(name: "after", value: "\(after)")
            ]
        )
        if let code = payload.code, code != 0 {
            throw BilibiliAPIError.api(payload.message ?? "PGC timeline returned code \(code)")
        }
        return payload.days.compactMap(Self.makeDay(from:))
    }

    /// Fetch the full PGC season detail + episode list
    /// for `seasonId`.  Used by `BangumiSeasonDetailView`
    /// when a timeline card is tapped.  Anonymous requests
    /// return `-404`; the upstream requires a signed-in
    /// cookie.  We don't authenticate-open the login sheet
    /// on a -404 because the user's path to this screen
    /// (a card tap on the timeline) usually means they
    /// were already in the app with a valid session; the
    /// sheet appears via the standard 401 → sessionExpired
    /// path in `get(...)` if the cookie really has died.
    func pgcSeason(seasonId: Int64) async throws -> BangumiSeasonDetail {
        let payload: APIResponse<PgcSeasonResult> = try await get(
            baseURL: baseURL,
            path: "/pgc/view/web/season",
            queryItems: [URLQueryItem(name: "season_id", value: "\(seasonId)")]
        )
        try payload.requireOK()
        guard let result = payload.value else {
            throw BilibiliAPIError.missingData
        }
        return Self.makeSeasonDetail(result)
    }

    /// Fetch the PGC season detail when the only thing
    /// the caller has is an `epId`.  The upstream returns
    /// the full season; we extract the resolved
    /// `season_id` so the route / state can navigate by
    /// season if a future revision needs that.
    func pgcSeason(epId: Int64) async throws -> BangumiSeasonDetail {
        let payload: APIResponse<PgcSeasonResult> = try await get(
            baseURL: baseURL,
            path: "/pgc/view/web/season",
            queryItems: [URLQueryItem(name: "ep_id", value: "\(epId)")]
        )
        try payload.requireOK()
        guard let result = payload.value else {
            throw BilibiliAPIError.missingData
        }
        return Self.makeSeasonDetail(result)
    }

    /// PGC playurl (DASH source for in-app player).  Hits
    /// `/pgc/player/web/v2/playurl` with `fnval=4048` to
    /// request DASH + HLS + MP4 + FLV.  The response shape
    /// differs from the UGC `/x/player/wbi/playurl` envelope
    /// in that the relevant DASH block lives at
    /// `result.video_info.dash` (PGC) rather than
    /// `result.dash` (UGC).  We fetch the raw response body
    /// with `JSONSerialization`, extract the
    /// `result.video_info` JSON object, and re-decode it as
    /// the UGC-shaped `PlayURLPayload` so the existing
    /// `bestPlayback(referer:)` projection does the
    /// best-quality selection.  The synthesised init on
    /// `PlayURLPayload` ignores the PGC-only `quality` /
    /// `format` / `from` extras so the round-trip is
    /// lossless for the four fields the player cares about
    /// (durl / dash / hls / duration).
    ///
    /// Upstream failure modes worth knowing:
    ///   * `-10403 抱歉您所在地区不可观看` — region gate;
    ///     surfaces as `BilibiliAPIError.api` and the call
    ///     site falls back to `InAppSafariView`.
    ///   * `-404 啥都木有` — anonymous viewer; the user's
    ///     `AccountSessionStore` cookie fixes this for any
    ///     B站 cookie-bearing account.
    func pgcPlayurl(
        epId: Int64,
        seasonId: Int64? = nil,
        preferredAudioQuality: Int = BiliAudioQuality.defaultID
    ) async throws -> BiliPlayback {
        var items: [URLQueryItem] = [
            URLQueryItem(name: "ep_id", value: "\(epId)"),
            URLQueryItem(name: "qn", value: "112"),
            URLQueryItem(name: "fnval", value: "4048"),
            URLQueryItem(name: "fnver", value: "0"),
            URLQueryItem(name: "fourk", value: "1"),
            URLQueryItem(name: "from_client", value: "BROWSER")
        ]
        if let seasonId {
            items.append(URLQueryItem(name: "season_id", value: "\(seasonId)"))
        }
        // Fetch the raw envelope bytes so we can round-trip
        // the `result.video_info` JSON object into the UGC
        // decoder without forcing `PlayURLPayload.Dash` (and
        // its sub-DTOs) to grow an `Encodable` contract they
        // don't otherwise need.  We still call `get<T>` with
        // the typed envelope first so the 412/429 retry and
        // 401 session-expired mapping fire correctly; the
        // second request below is only the path that gives
        // us the raw body.
        let envelope: PgcPlayURLPayload = try await get(
            baseURL: baseURL,
            path: "/pgc/player/web/v2/playurl",
            queryItems: items
        )
        if envelope.code != 0 {
            throw BilibiliAPIError.api(
                envelope.message ?? "PGC playurl code \(envelope.code)"
            )
        }
        guard envelope.result?.videoInfo != nil else {
            throw BilibiliAPIError.missingData
        }
        let rawData: Data = try await rawGet(
            baseURL: baseURL,
            path: "/pgc/player/web/v2/playurl",
            queryItems: items
        )
        guard let root = try? JSONSerialization.jsonObject(with: rawData) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let videoInfoJSON = result["video_info"] else {
            throw BilibiliAPIError.missingData
        }
        let playURLData = try JSONSerialization.data(
            withJSONObject: videoInfoJSON,
            options: []
        )
        let decoder = JSONDecoder()
        let playURL = try decoder.decode(PlayURLPayload.self, from: playURLData)
        let referer: URL = {
            if let seasonId,
               let url = URL(
                string: "https://www.bilibili.com/bangumi/play/ss\(seasonId)"
            ) {
                return url
            }
            return URL(string: "https://www.bilibili.com/bangumi/play/ep\(epId)")!
        }()
        guard let playback = playURL.bestPlayback(
            referer: referer.absoluteString,
            preferredAudioQuality: preferredAudioQuality
        ) else {
            throw BilibiliAPIError.noPlayableFormat
        }
        return playback
    }

    /// DTO → `BangumiSeasonDetail` conversion.  Builds the
    /// canonical B站 share URL for every episode and
    /// maps the optional `evaluate` (long description) to
    /// `desc`.  Episodes with no `cover` or `duration` are
    /// still surfaced (the cell renders placeholders
    /// downstream), and the share URL is computed even
    /// when the upstream `share_url` field is absent.
    private static func makeSeasonDetail(_ result: PgcSeasonResult) -> BangumiSeasonDetail {
        let resolvedSeasonId = result.seasonId ?? 0
        let episodes: [BangumiEpisode] = result.episodes.enumerated().map { idx, ep in
            let cover = ep.cover.flatMap(URL.init(string:))
            let shareURL = URL(string: "https://www.bilibili.com/bangumi/play/ep\(ep.epId)")
            let indexLabel: String
            if let copy = ep.shareCopy, !copy.isEmpty {
                indexLabel = copy
            } else {
                indexLabel = "\(idx + 1)"
            }
            return BangumiEpisode(
                epId: ep.epId,
                title: ep.title ?? indexLabel,
                longTitle: ep.longTitle,
                indexLabel: indexLabel,
                coverURL: cover,
                durationMs: ep.durationMs,
                shareURL: shareURL
            )
        }
        return BangumiSeasonDetail(
            seasonId: resolvedSeasonId,
            title: result.title,
            desc: result.evaluate,
            coverURL: result.cover.flatMap(URL.init(string:)),
            episodes: episodes
        )
    }

    /// DTO → BangumiDay conversion.  Lifted to a private
    /// static so `bangumiTimeline(...)` can stay flat and so
    /// a future `BangumiIndex` / `BangumiDetail` can reuse
    /// the same projection if upstream ever unifies the
    /// payloads.
    ///
    /// The upstream `/pgc/web/timeline` response flattens
    /// everything onto the episode object — there is no
    /// `season` sub-object.  Fields we surface:
    ///
    ///   - `title`       → BangumiCard.title
    ///   - `cover`       → BangumiCard.coverURL
    ///   - `pub_index`   → BangumiCard.updateDescription
    ///                    ("第42话" — passed through verbatim
    ///                    because upstream already formats it;
    ///                    older endpoints that returned a raw
    ///                    integer were normalised here, but
    ///                    timeline always sends the full string)
    ///   - `pub_time`    → "MM-DD" of the upcoming slot if
    ///                    pub_index is empty
    ///   - `published`   → badge "未开播" when 0
    ///   - `season_id`   → BangumiCard.seasonId + share URL
    private static func makeDay(from dto: BangumiTimelineDay) -> BangumiDay? {
        let cards: [BangumiCard] = dto.episodes.compactMap { ep -> BangumiCard? in
            guard let seasonId = ep.seasonId else {
                return nil
            }
            let title = ep.title ?? "未知番劇"
            // Upstream always sends a cover URL but guard
            // against the unlikely missing-field case.
            let cover = (ep.cover ?? ep.squareCover ?? ep.epCover)
                .flatMap(URL.init(string:))
            let pubIndex = ep.pubIndex ?? ""
            let pubTime = ep.pubTime ?? ""
            let updateDescription: String
            if !pubIndex.isEmpty {
                // pub_index is already formatted ("第42话"
                // / "全12话" / etc.) so we pass it through.
                updateDescription = pubIndex
            } else if !pubTime.isEmpty {
                updateDescription = pubTime
            } else {
                updateDescription = "即將開播"
            }
            // `published` is `0` for not-yet-aired rows and
            // `1` for everything else.  Some rows may not
            // carry the field at all; treat absence as
            // "published" (the safe default).
            let badge: String?
            if let published = ep.published, published == 0 {
                badge = "未開播"
            } else {
                badge = nil
            }
            // Canonical share URL.  PGC plays live at
            // /bangumi/play/ss<season_id>; the upstream
            // also returns `share_url` for some rows but
            // not all, so we always build the canonical
            // form here for consistency.
            let shareURL = URL(string: "https://www.bilibili.com/bangumi/play/ss\(seasonId)")
            return BangumiCard(
                seasonId: seasonId,
                title: title,
                coverURL: cover,
                updateDescription: updateDescription,
                badgeText: badge,
                shareURL: shareURL
            )
        }
        return BangumiDay(
            weekday: dto.weekday,
            weekdayLabel: weekdayLabel(for: dto.weekday),
            date: dto.date,
            cards: cards
        )
    }

    private static func weekdayLabel(for weekday: Int) -> String {
        switch weekday {
        case 1: "週一"
        case 2: "週二"
        case 3: "週三"
        case 4: "週四"
        case 5: "週五"
        case 6: "週六"
        case 7: "週日"
        default: "周\(weekday)"
        }
    }
}

// MARK: - 番剧时间表 (PGC /pgc/web/timeline) DTO
//
// Private response shapes for the bangumi timeline endpoint.
// Kept private to this file so the public API only surfaces
// the hand-built `BangumiDay` / `BangumiCard` types from
// `Models.swift`.  Field names follow the upstream PGC
// payload (verified against a live `curl` of the endpoint
// on 2026-07-11 — see `scripts/probe_pgc_endpoints.py`):
//
//   {
//     "code": 0,
//     "result": [
//       {
//         "date": "7-5",
//         "date_ts": 1783180800,
//         "day_of_week": 7,
//         "is_today": true,
//         "episodes": [
//           {
//             "title": "假面骑士ZZZ",
//             "cover": "https://i0.hdslb.com/.../88406f07...jpg",
//             "square_cover": "...",
//             "ep_cover": "...",
//             "pub_index": "第42话",
//             "pub_time": "10:00",
//             "pub_ts": 1783216800,
//             "published": 1,
//             "season_id": 109700,
//             "episode_id": 3781142,
//             "follows": "-",
//             "plays": "-",
//             ...
//           }
//         ]
//       }
//     ]
//   }
//
// Note: the `season` sub-object I assumed in the previous
// revision does NOT exist — every field is flattened onto
// the episode itself.  `published` is `0/1` (not
// `is_published`).  This DTO is the corrected shape.

/// Top-level envelope for `/pgc/web/timeline`.  Decoded
/// directly (NOT through the shared `APIResponse<T>` wrapper)
/// because the upstream's `result` field is a JSON array of
/// day objects, while `APIResponse<T>`'s synthesized init
/// tries to decode `result: T` as a keyed container — that
/// mismatch was the source of the v0.5.1.239 cascade of
/// `Expected to decode Dictionary<String, Any> but found an
/// array instead` failures in the diagnostic log.
///
/// The `code` / `message` / `days` triple mirrors the
/// upstream shape so a future addition (e.g. cursor-based
/// pagination) lands in the obvious place.
private struct BangumiTimelinePayload: Decodable, Sendable {
    let code: Int?
    let message: String?
    let days: [BangumiTimelineDay]
    enum CodingKeys: String, CodingKey {
        case code
        case message
        case days = "result"
    }
}

private struct BangumiTimelineDay: Decodable, Sendable {
    let date: String?
    let dateTs: Int64?
    let weekday: Int
    let isToday: Bool?
    let episodes: [BangumiTimelineEpisode]
    enum CodingKeys: String, CodingKey {
        case date
        case dateTs = "date_ts"
        case weekday = "day_of_week"
        case isToday = "is_today"
        case episodes
    }

    /// B 站 sends `is_today` as a JSON number (0/1), not a
    /// Bool.  Synthesized Decodable would typeMismatch on
    /// that, so we coerce 0/1 to Bool here and keep
    /// `isToday: Bool?` for the call site.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decodeIfPresent(String.self, forKey: .date)
        dateTs = try c.decodeIfPresent(Int64.self, forKey: .dateTs)
        weekday = try c.decode(Int.self, forKey: .weekday)
        if let n = try c.decodeIfPresent(Int.self, forKey: .isToday) {
            isToday = n != 0
        } else {
            isToday = nil
        }
        episodes = try c.decode([BangumiTimelineEpisode].self, forKey: .episodes)
    }
}

private struct BangumiTimelineEpisode: Decodable, Sendable {
    let title: String?
    let cover: String?
    let squareCover: String?
    let epCover: String?
    let pubIndex: String?
    let pubTime: String?
    let published: Int?
    let seasonId: Int64?
    let episodeId: Int64?
    enum CodingKeys: String, CodingKey {
        case title
        case cover
        case squareCover = "square_cover"
        case epCover = "ep_cover"
        case pubIndex = "pub_index"
        case pubTime = "pub_time"
        case published
        case seasonId = "season_id"
        case episodeId = "episode_id"
    }
}

// MARK: - PGC season detail (per-season / per-episode)
//
// Hits `/pgc/view/web/season` to fetch the full season
// metadata + episode list for a tapped PGC card.  The
// upstream returns a `{code, message, result}` envelope
// where `result` is a single keyed object (not an array,
// unlike `/pgc/web/timeline`), so we keep this on the
// shared `APIResponse` envelope.
//
// Two entry points:
//   - `pgcSeason(seasonId:)` — by season id (most common
//     from the timeline card row, which already carries
//     `season_id`).
//   - `pgcSeason(epId:)` — by ep id (used when the only
//     thing we have is an episode id, e.g. a deep-link
//     `bangumi/play/ep<id>` URL).  The season is resolved
//     from the upstream `result.season_id` field.
//
// Both require a signed-in cookie: an anonymous request
// returns `code: -404` ("啥都木有").  The Bangumi card
// timeline itself is anonymous, so the transition from
// "browse" to "open" is the first time we hit a
// cookie-gated endpoint in the PGC surface.

struct PgcSeasonResult: Decodable, Sendable {
    let seasonId: Int64?
    let title: String
    let cover: String?
    let evaluate: String?
    let episodes: [PgcSeasonEpisode]

    enum CodingKeys: String, CodingKey {
        case seasonId = "season_id"
        case title
        case cover
        case evaluate
        case episodes
    }
}

struct PgcSeasonEpisode: Decodable, Sendable {
    let epId: Int64
    let title: String?
    let longTitle: String?
    let shareCopy: String?
    let cover: String?
    let durationMs: Int64?
    let aid: Int64?
    let cid: Int64?

    enum CodingKeys: String, CodingKey {
        case epId = "id"
        case title
        case longTitle = "long_title"
        case shareCopy = "share_copy"
        case cover
        case durationMs = "duration"
        case aid
        case cid
    }
}

// MARK: - PGC playurl (DASH source for in-app player)
//
// Hits `/pgc/player/web/v2/playurl` with `fnval=4048` to
// ask for DASH + HLS + MP4 + FLV; the response shape
// differs from the UGC `/x/player/wbi/playurl` envelope:
// the relevant DASH block lives at
// `result.video_info.dash` rather than `result.dash`, and
// the `result` field carries a `from` / `quality` /
// `format` summary that we ignore for the playback path.
//
// We mirror the UGC `bestPlayback(referer:)` projection:
// pick the highest-qn video + lowest-qn audio that
// together survive, build a `BiliPlayback` that the
// existing `AVPlayerController.loadPlayback(...)` path
// can consume (no player-side changes needed — the DASH
// half is fanned out into the same `LocalHLSProxyServer`
// that UGC uses).
//
// The upstream returns -10403 (`抱歉您所在地区不可观看`)
// for region-gated episodes regardless of cookie state.
// When the user has configured a custom PGC playurl
// endpoint (see `AppRouter.pgcCustomEndpoint`) the request
// is rerouted there first so the user can self-host a
// reverse proxy in front of the official B站 API.
fileprivate struct PgcPlayURLPayload: Decodable, Sendable {
    let code: Int
    let message: String?
    let result: PgcPlayURLResult?
}

fileprivate struct PgcPlayURLResult: Decodable, Sendable {
    let videoInfo: PgcVideoInfo?
    let quality: Int?
    let format: String?
    let from: String?
    let timelength: Double?

    enum CodingKeys: String, CodingKey {
        case videoInfo = "video_info"
        case quality
        case format
        case from
        case timelength
    }
}

/// `Decodable` only — the playback path does not need
/// to re-encode the upstream `video_info` block; the
/// `pgcPlayurl` method does the round-trip via
/// `JSONSerialization` on the raw response bytes, which
/// keeps `PlayURLPayload.Dash` (and its sub-types
/// `DashVideo` / `DashMedia` / `SegmentBase`) free of
/// a parallel `Encodable` contract they would never
/// otherwise need.
fileprivate struct PgcVideoInfo: Decodable, Sendable {
    let dash: PlayURLPayload.Dash?
    let duration: Double?
    let quality: Int?
}

/// PGC playurl (DASH source for in-app player).  Hits
/// `/pgc/player/web/v2/playurl` with `fnval=4048` to ask
/// for DASH + HLS + MP4 + FLV; the response shape differs
/// from the UGC `/x/player/wbi/playurl` envelope in that
/// the DASH block lives at `result.video_info.dash`
/// (PGC) rather than `result.dash` (UGC).  The cleanest
/// way to share the existing `bestPlayback(referer:)`
/// projection is to re-encode the upstream `video_info`
/// block as JSON and re-decode it as the UGC-shaped
/// `PlayURLPayload` (the PGC `video_info` block is a
/// superset of the UGC `data` fields; the synthesized
/// init on `PlayURLPayload` ignores the PGC-only
/// `quality` / `format` / `from` extras so the round-trip
/// is lossless for the four fields the player cares
/// about — durl / dash / hls / duration).
///
/// The upstream returns -10403 (`抱歉您所在地区不可观看`)
/// for region-gated episodes regardless of cookie state.
/// The 404 path for anonymous viewers returns -404.  Both
/// surface as `BilibiliAPIError.api` / `.missingData`
/// and the call site falls back to the
/// `InAppSafariView` share-URL sheet that the build-243
/// in-app season detail already ships.
