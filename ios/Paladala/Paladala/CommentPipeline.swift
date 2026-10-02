// CommentPipeline.swift
//
// Single place that owns the comments fetch flow.
//
// Why this exists:
//
// Before the refactor, `BilibiliAPIClient.commentsPage(...)` was a single
// 100+ line function that fanned out across three upstream endpoints
// (legacy pn, appkey+sign, WBI sign) with two cursor shapes (Int pn and
// opaque `pagination_str`) interleaved. The endpoint choice was wired
// into control flow, the silent-gate retry was a nested closure, and
// each path re-implemented the same dedup/merge logic.
//
// The new pipeline mirrors the layout used by the open-source Flutter
// Bilibili client `guozhigq/pilipala` (their `reply/index.dart` flow):
// a single typed cursor, a chain of swappable endpoints, and a single
// decode helper that all three endpoints share. The ViewModel /
// Repository no longer know which endpoint spoke back — they only see
// `CommentPage` + `CommentCursor`.
//
// File layout:
//   1. `CommentCursor`            — sum type for the page cursor
//   2. `CommentEndpoint` protocol — one method, one result, swappable
//   3. `LegacyPnEndpoint`         — `/x/v2/reply` (pn-based, anonymous-friendly)
//   4. `AppSignedEndpoint`        — `/x/v2/reply` (appkey+sign+access_key)
//   5. `WbiSignedEndpoint`        — `/x/v2/reply/wbi/main` (silent-gate aware)
//   6. `AnonymousMainEndpoint`    — `/x/v2/reply/main` (PiliNara anonymous shape)
//   7. `CommentRepository`        — orchestrator that walks the chain
//   8. DTO / decode helpers       — shared by all four endpoints

import Foundation

// MARK: - 1. CommentCursor
//
// Bilibili serves the comment list with two incompatible cursor shapes:
//
//   • Legacy `/x/v2/reply` accepts an integer `pn` page number and
//     returns a flat `page.{count, acount, num}` block. The cursor is
//     purely local — `pn + 1`.
//
//   • App / WBI endpoints require a JSON `pagination_str` blob
//     (`{"offset":"<opaque>"}`) and return the next cursor inside
//     `data.cursor.pagination_reply.next_offset`. The cursor is opaque —
//     the server decides what it means.
//
// Mixing the two was the root cause of the original bug: a `next` cursor
// produced by the WBI path (a base64-ish token) was fed back into the
// legacy path via `Int("...")`, which silently fell back to page 1.
// Encoding the cursor as a sum type makes that bug unrepresentable —
// an endpoint that does not accept a given cursor kind returns `nil`
// and the repository walks the chain to the next endpoint that does.

enum CommentCursor: Hashable, Sendable {
    /// Legacy `/x/v2/reply` integer page number. `pn = 1` is the first page.
    case pn(Int)
    /// Opaque `pagination_str` blob used by the app + WBI endpoints.
    /// The wrapped string is the value of `data.cursor.pagination_reply
    /// .next_offset` returned by the previous request, or empty for the
    /// first page.
    case offset(String)
    /// Sentinel for "no more pages". Set by the repository when the
    /// previous page reported `isEnd`, so the ViewModel can rely on a
    /// single `nextCommentCursor` field without a separate `hasMore` flag.
    case end

    /// Convenience start marker. The legacy pn path treats this as page 1;
    /// the app / WBI path treats it as `{"offset":""}`.
    static let start: CommentCursor = .pn(1)

    /// Compare two cursors for "feed me the next page" semantics. The
    /// repository walks the endpoints in order and stops at the first one
    /// that returns a non-empty page. The actual cursor kind the
    /// endpoint will receive depends on which endpoint it is.
    var isEnd: Bool {
        if case .end = self { return true }
        return false
    }
}

// MARK: - 2. CommentEndpoint
//
// Each endpoint owns its own request shape, sign algorithm, and decode
// path. The protocol surface is intentionally minimal so the
// `CommentRepository` orchestrator can treat them as a uniform list.
//
// `CommentCursor` is intentionally nullable: an endpoint that does not
// accept a given cursor kind (e.g. WBI receives a `.pn` cursor from a
// previous fallback fetch) returns `nil` so the repository knows to try
// the next endpoint. The orchestrator never has to inspect the cursor
// kind — it just keeps walking the chain until one returns a result.

protocol CommentEndpoint: Sendable {
    /// Fetch one page of replies.
    ///
    /// - Returns: `CommentPage` on success, `nil` when this endpoint is
    ///   not applicable to the current cursor / account state (e.g. the
    ///   app path has no `access_key`, or the cursor is from a different
    ///   endpoint family). `nil` is the orchestrator's "try the next one"
    ///   signal and is **not** an error.
    /// - Throws: real failures (network, decode, -403, etc.) so the
    ///   orchestrator can surface a typed error to the ViewModel.
    func fetchPage(aid: Int, sort: CommentSort, cursor: CommentCursor) async throws -> CommentPage?
}

// MARK: - 3. LegacyPnEndpoint
//
// The `/x/v2/reply` endpoint with bare query params (no appkey, no sign,
// no WBI). This is the only surface through which B站 currently returns
// real reply data to a third-party iOS URLSession client — the same
// path `guozhigq/pilipala` (open-source Flutter B站 client) uses.
// Verified 2026-08-02: returns the full reply list for `BV1paKb6iEny`
// (286 comments) without any appkey/sign/cookie, while the appkey+sign
// path returns `replies: null` and the WBI sign path returns `-403
// 访问权限不足`. SESSDATA is still auto-attached by `get(...)` when
// available; the path also works anonymously for first-page reads.
//
// Only accepts `.pn` cursors. If the caller passes a `.offset` cursor
// (from a previous WBI fetch), this endpoint returns `nil` so the
// repository walks the chain to the WBI endpoint that does accept it.

struct LegacyPnEndpoint: CommentEndpoint {
    let apiClient: BilibiliAPIClient
    let pageSize: Int

    init(apiClient: BilibiliAPIClient, pageSize: Int = 20) {
        self.apiClient = apiClient
        self.pageSize = pageSize
    }

    func fetchPage(aid: Int, sort: CommentSort, cursor: CommentCursor) async throws -> CommentPage? {
        // Cursor kind guard. A .pn cursor is the only shape this endpoint
        // understands. Any other kind means the caller came from a
        // different endpoint family and we should not try to re-decode it
        // here — the orchestrator will pick the right endpoint.
        let pn: Int
        switch cursor {
        case .pn(let value):
            pn = value
        case .offset, .end:
            return nil
        }
        let queryItems: [URLQueryItem] = [
            URLQueryItem(name: "oid", value: "\(aid)"),
            URLQueryItem(name: "type", value: "1"),
            URLQueryItem(name: "pn", value: "\(pn)"),
            URLQueryItem(name: "ps", value: "\(pageSize)"),
            // `sort` is accepted at the API surface for parity with the
            // other endpoints but the upstream `sort` param is hard-coded
            // to `"2"` (newest first) — B站's binary `sort=2`/`sort=3`
            // mapping for legacy pn pagination does not line up cleanly
            // with the `mode` codes the newer `/x/v2/reply/main` endpoint
            // uses, and forcing a mode here would silently drop replies.
            URLQueryItem(name: "sort", value: "2"),
        ]
        bpLog("commentsPage(legacy): fetching aid=\(aid) pn=\(pn)")
        let payload: APIResponse<LegacyCommentPayload> = try await apiClient.get(
            baseURL: apiClient.baseURL,
            path: "/x/v2/reply",
            queryItems: queryItems,
            signWithWBI: false
        )
        try payload.requireOK()
        guard let value = payload.value else {
            return CommentPage(items: [], next: nil, isEnd: true, totalCount: 0)
        }
        let totalCount = value.page?.count ?? 0
        bpLog("commentsPage(legacy): HTTP success code=\(payload.code ?? -1) page.count=\(totalCount) replies=\(value.replies?.items.count ?? 0)")
        let merged = Self.mergeReplies(
            pinned: value.topReplies?.items ?? [],
            regular: value.replies?.items ?? []
        )
        // pn-based pagination: next page is pn+1; treat as end when
        // this page returned fewer than `ps` items, when the server
        // reports `acount <= pn * ps`, or when we already have
        // `acount` worth of replies rendered.
        let acount = value.page?.acount ?? totalCount
        let reachedTotal = acount > 0 && merged.count >= acount
        let shortPage = merged.count < pageSize
        let isEnd = shortPage || reachedTotal
        let nextCursor: CommentCursor? = isEnd ? nil : .pn(pn + 1)
        return CommentPage(
            items: merged,
            next: nextCursor,
            isEnd: isEnd,
            totalCount: totalCount
        )
    }

    /// Shared dedup helper. The legacy payload has only one pinned slot
    /// (`top_replies`), so the merge is simpler than the WBI payload —
    /// but the same `Set<Int>` dedup strategy is used so the result
    /// matches what the WBI path returns for the same upstream.
    static func mergeReplies(pinned: [CommentDTO], regular: [CommentDTO]) -> [BiliComment] {
        var seen = Set<Int>()
        var merged: [BiliComment] = []
        for dto in pinned + regular {
            let model = dto.model
            if seen.insert(model.id).inserted {
                merged.append(model)
            }
        }
        return merged
    }
}

// MARK: - 4. AppSignedEndpoint
//
// `/x/v2/reply` with `appkey + sign + access_key`. The same shape the
// official B站 iOS app uses. Requires a valid `access_key` issued by
// the app QR login flow.
//
// On the current B站 back-end the TV-paired appkey is classified as a
// TV client and the comments endpoint silently returns `replies: null`
// even on videos with thousands of comments. The endpoint is preserved
// for forward compatibility in case B站 reopens the surface for
// non-mobile-classified apps.

struct AppSignedEndpoint: CommentEndpoint {
    let apiClient: BilibiliAPIClient
    /// `access_key` from the active account. When `nil` this endpoint
    /// is a no-op — the repository walks the chain to the WBI endpoint.
    let accessKeyProvider: @Sendable () async -> String?

    init(apiClient: BilibiliAPIClient, accessKeyProvider: @escaping @Sendable () async -> String?) {
        self.apiClient = apiClient
        self.accessKeyProvider = accessKeyProvider
    }

    func fetchPage(aid: Int, sort: CommentSort, cursor: CommentCursor) async throws -> CommentPage? {
        let accessKey = await accessKeyProvider()
        guard let accessKey, !accessKey.isEmpty else { return nil }
        // App endpoints use the opaque `pagination_str` cursor. The
        // legacy .pn cursor is not understood here, so we skip the
        // endpoint and let the orchestrator fall back to the WBI path.
        let offset: String
        switch cursor {
        case .pn:
            return nil
        case .offset(let value):
            offset = value
        case .end:
            return nil
        }
        let paginationStr = "{\"offset\":\"\(offset)\"}"
        bpLog("commentsPage(app): fetching aid=\(aid) sort=\(sort) offset='\(offset)'")
        let appConfig = await apiClient.currentAppConfig() ?? BilibiliAPIClient.defaultConfig
        let effectiveBuvid = (appConfig.buvid3?.isEmpty == false) ? appConfig.buvid3! : apiClient.generateMobileBuvid()
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "oid", value: "\(aid)"),
            URLQueryItem(name: "type", value: "1"),
            URLQueryItem(name: "pagination_str", value: paginationStr),
            URLQueryItem(name: "plat", value: "1"),
            URLQueryItem(name: "seek_rpid", value: ""),
            URLQueryItem(name: "web_location", value: "1315875"),
            URLQueryItem(name: "mobi_app", value: "iphone"),
            URLQueryItem(name: "platform", value: "ios"),
            URLQueryItem(name: "build", value: appBuild),
            URLQueryItem(name: "appkey", value: appKey),
            URLQueryItem(name: "access_key", value: accessKey),
            URLQueryItem(name: "ts", value: "\(Int(Date().timeIntervalSince1970))"),
            URLQueryItem(name: "buvid", value: effectiveBuvid)
        ]
        if let mode = sort.apiValue {
            queryItems.append(URLQueryItem(name: "mode", value: "\(mode)"))
        }
        queryItems.append(URLQueryItem(name: "sign", value: apiClient.appSign(queryItems)))
        let payload: APIResponse<CommentPayload> = try await apiClient.get(
            baseURL: apiClient.baseURL,
            path: "/x/v2/reply",
            queryItems: queryItems,
            signWithWBI: false
        )
        try payload.requireOK()
        // Diagnostic so we can confirm the app path actually fires
        // and what shape B站 returns. Drop once the path is stable.
        bpLog("commentsPage(app): HTTP success code=\(payload.code ?? -1) message=\(payload.message ?? "?")")
        if let val = payload.value {
            let upperKeys = val.upperTop.map { "upperTop keys=\($0.values.count)" } ?? "nil"
            let topReplies = val.topReplies.map { "topReplies items=\($0.items.count)" } ?? "nil"
            let replies = val.replies.map { "replies items=\($0.items.count)" } ?? "nil"
            let cursor = val.cursor.map { c in
                "cursor allCount=\(c.allCount) isEnd=\(c.isEnd) paginationReply=\(c.paginationReply.map { "nextOffset=\($0.nextOffset)" } ?? "nil")"
            } ?? "nil"
            bpLog("commentsPage(app): payload | upper=\(upperKeys) \(topReplies) \(replies) \(cursor)")
        }
        return CommentPageDecoder.decode(payload: payload.value)
    }
}

// MARK: - 5. WbiSignedEndpoint
//
// `/x/v2/reply/wbi/main` with a WBI-signed query. The fallback used by
// every iOS client because it does not require an `access_key` — the
// WBI signature is derived from the public img/sub keys served by
// `/x/web-interface/nav`.
//
// B站's WBI gate has TWO failure modes (see the long comment on
// `attemptFetch`):
//   1. Explicit — `code = -403` ("访问权限不足"). Generic `get<T>`
//      already catches this and retries once with fresh WBI keys.
//   2. Silent   — `code = 0` + a valid `cursor` (so `requireOK()`
//      passes) + an empty `replies[]`. The upstream returns 200 OK as
//      if the request succeeded, but the comment list is withheld. This
//      happens when the WBI signature was computed against an
//      img_key / sub_key pair that has since rotated server-side. The
//      recovery is invalidate-the-cached-keys + retry once.
//
// The endpoint encapsulates the silent-gate recovery internally — the
// repository only sees two outcomes: a successful `CommentPage` or a
// thrown `BilibiliAPIError.missingIdentity` (signaling the second
// retry also returned empty — i.e. the keys refresh didn't help and
// the underlying issue is auth, not signature staleness).

struct WbiSignedEndpoint: CommentEndpoint {
    let apiClient: BilibiliAPIClient

    func fetchPage(aid: Int, sort: CommentSort, cursor: CommentCursor) async throws -> CommentPage? {
        // Only `.offset` cursors are understood here. A `.pn` cursor is
        // normally legacy and belongs to the legacy endpoint.
        //
        // Cross-endpoint silent-gate fallback: when the legacy endpoint
        // returns a non-nil page with `items: []` but `totalCount > 0`
        // (the URLSession TLS-fingerprint 風控 B站 applies to non-Safari
        // clients), the repository walks the chain to this endpoint
        // with the same `.pn(1)` start cursor. The WBI page-1 shape is
        // `pagination_str = {"offset":""}`, so accept `.pn(1)` here as
        // the empty-offset page-1 fallback. Deeper pages (`pn > 1`) still
        // fall through to the legacy endpoint because the pn→offset
        // mapping is not lossless — a `.pn(N)` cursor is meaningless to
        // B站's opaque offset token stream and silently re-issuing it
        // here would risk duplicate pages after a successful WBI read.
        let offset: String
        let isLegacyPn1Fallback: Bool
        switch cursor {
        case .pn(let value):
            guard value == 1 else { return nil }
            offset = ""
            isLegacyPn1Fallback = true
        case .offset(let value):
            offset = value
            isLegacyPn1Fallback = false
        case .end:
            return nil
        }
        let paginationStr = "{\"offset\":\"\(offset)\"}"
        if isLegacyPn1Fallback {
            bpLog("commentsPage: WBI accepting legacy .pn(1) as offset='' (silent-gate fallback)")
        }
        bpLog("commentsPage: fetching aid=\(aid) sort=\(sort) offset='\(offset)'")
        // Cross-reference: PiliNara's anonymous comment request
        // (`lib/http/reply.dart` `ReplyHttp.replyList`, the
        // anonymous branch) hits `/x/v2/reply/wbi/main` with
        // only `oid`, `type`, `pagination_str`, and `mode`. The
        // extra `plat=1`, `web_location=1315875`, `seek_rpid=`
        // params Paladala had been sending came from the legacy
        // web-client request shape; PiliNara's evidence says
        // B站 treats those params as a per-platform fingerprint
        // hint, and `1315875` (the iOS web client location) on
        // an Android-HD UA triggers explicit -403 "访问权限不足"
        // instead of the previous silent gate. Drop them to
        // match the working anonymous path.
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "type", value: "1"),
            URLQueryItem(name: "oid", value: "\(aid)"),
            URLQueryItem(name: "pagination_str", value: paginationStr)
        ]
        if let mode = sort.apiValue {
            queryItems.append(URLQueryItem(name: "mode", value: "\(mode)"))
        }
        // Local helper: signs the query items, fires the request, and
        // returns the merged comment list + cursor fields. Extracted so
        // the silent-gate retry path below can re-run the same pipeline
        // after a `wbiSigner.invalidate()` without duplicating the
        // parse/merge logic.
        func attemptFetch() async throws -> (merged: [BiliComment], reportedTotal: Int, nextCursor: CommentCursor, isEnd: Bool) {
            // CRITICAL: do NOT sign this request. The cross-reference
            // open-source client `Starfallan/PiliNara`
            // (`lib/http/reply.dart` `ReplyHttp.replyList`, the
            // anonymous branch) hits the exact same
            // `/x/v2/reply/wbi/main` path with a raw
            // `pagination_str` + `mode` query and no WBI signature
            // and gets the real reply list. With WBI signature
            // (the previous shape, pre-v0.5.21) the server returns
            // 200 OK with a valid cursor and an empty `replies[]` —
            // the canonical silent-gate. The signature tokens
            // `wts` and `w_rid` are being rejected as stale /
            // mismatched by the per-client fingerprint layer even
            // after `wbiSigner.invalidate()` because that layer
            // looks at the (User-Agent, app-key, x-bili-aurora-zone,
            // x-bili-trace-id) quartet, not the WBI keys. Dropping
            // the signature and matching PiliNara's anonymous
            // request shape is the only path that lands the
            // payload.
            let payload: APIResponse<CommentPayload> = try await apiClient.get(
                baseURL: apiClient.baseURL,
                path: "/x/v2/reply/wbi/main",
                queryItems: queryItems,
                signWithWBI: false
            )
            try payload.requireOK()
            // Diagnostic: log the decoded payload shape so we can see
            // exactly what B站 returned. Without this, "commentsPage:
            // returning" silently never firing (observed in v0.5.6
            // diagnostic) leaves us guessing whether decode produced
            // an empty list, allCount was 0, or the function threw
            // somewhere between requireOK and the return log.
            // Truncate the dump to keep the diagnostic file readable.
            if let val = payload.value {
                let upperKeys = val.upperTop.map { "upperTop keys=\($0.values.count)" } ?? "nil"
                let topReplies = val.topReplies.map { "topReplies items=\($0.items.count)" } ?? "nil"
                let replies = val.replies.map { "replies items=\($0.items.count)" } ?? "nil"
                let cursor = val.cursor.map { c in
                    "cursor next=\(c.next ?? -1) allCount=\(c.allCount) isEnd=\(c.isEnd) paginationReply=\(c.paginationReply.map { "nextOffset=\($0.nextOffset)" } ?? "nil")"
                } ?? "nil"
                bpLog("commentsPage: payload | upper=\(upperKeys) \(topReplies) \(replies) \(cursor)")
            } else {
                bpLog("commentsPage: payload | value=nil code=\(payload.code ?? -1) message=\(payload.message ?? "?")")
            }
            let result = CommentPageDecoder.decode(payload: payload.value)
            let reportedTotal = result.totalCount
            let merged = result.items
            // `CommentPageDecoder` already maps the upstream
            // `pagination_reply.next_offset` cursor into a `CommentCursor`
            // (the `.offset` case). The `next` field is `nil` when the
            // upstream did not return a cursor or reported the page as
            // the last one — both cases mean "no more pages" for the
            // caller.
            let nextCursor: CommentCursor? = result.next
            let isEnd = result.isEnd
            bpLog("commentsPage: merged count=\(merged.count) allCount=\(reportedTotal) isEnd=\(isEnd) nextCursor=\(nextCursor.map(String.init(describing:)) ?? "nil")")
            return (merged, reportedTotal, nextCursor ?? .end, isEnd)
        }
        var (merged, reportedTotal, nextCursor, isEnd) = try await attemptFetch()
        // Silent-gate recovery. See the long comment on the struct
        // above for why this is needed: B站's WBI validator refuses
        // to surface content when the signature's img_key/sub_key is
        // stale, but the response still looks successful (200 OK +
        // valid cursor + empty replies array), so the only signal we
        // get is `merged.isEmpty && reportedTotal > 0`. Invalidate
        // the cached keys (forcing `sign` to re-fetch from
        // `/x/web-interface/nav`) and retry once. If the second
        // attempt also returns empty, fall through to the
        // `missingIdentity` throw — at that point it's a real
        // auth/identity issue, not a stale-key issue.
        if merged.isEmpty && reportedTotal > 0 {
            bpLog("commentsPage: silent gate detected (allCount=\(reportedTotal) but 0 replies) — refreshing WBI keys + retry once")
            await apiClient.invalidateWBISigner()
            (merged, reportedTotal, nextCursor, isEnd) = try await attemptFetch()
            bpLog("commentsPage: silent gate retry result items=\(merged.count) allCount=\(reportedTotal)")
        }
        // Bilibili silently returns `replies: null` (and an empty
        // `upper.top`) for unauthenticated callers when the
        // thread has comments — `code == 0` passes `requireOK()`,
        // but the API refuses to hand over the actual reply
        // list.  `cursor.allCount` still reports the true count
        // (so the stats bar shows 12 next to the comments icon
        // even though the list is empty).  We surface that as
        // `missingIdentity` so the caller can show "请登录后查
        // 看评论" instead of the misleading "No public comments"
        // empty state. After the silent-gate retry above, the
        // only way to land here is if the second attempt also
        // returned empty — i.e. the keys refresh didn't help,
        // and the underlying issue is auth, not signature
        // staleness.
        if merged.isEmpty && reportedTotal > 0 {
            throw BilibiliAPIError.missingIdentity
        }
        // Diagnostic: log how the merged result looks on the way out
        // so we can tell the difference between "Bilibili gave us 0
        // comments for this video" and "Bilibili gave us N but the
        // decode dropped them".  Without this, an empty list at the
        // UI layer looks identical to a never-fired call.
        bpLog("commentsPage: returning \(merged.count) items, allCount=\(reportedTotal), nextCursor=\(nextCursor == .end ? "nil" : String(describing: nextCursor))")
        // Map the `.end` sentinel back to `nil` so the ViewModel's
        // simple `page.next != nil` guard behaves correctly. The
        // sentinel exists inside the pipeline so the orchestrator
        // can short-circuit with a single type check, but the
        // published `CommentPage` API stays `Optional`-shaped.
        let nextCursorOptional: CommentCursor? = (nextCursor == .end) ? nil : nextCursor
        return CommentPage(
            items: merged,
            next: nextCursorOptional,
            isEnd: isEnd,
            totalCount: reportedTotal == 0 ? merged.count : reportedTotal
        )
    }
}

// MARK: - 6. AnonymousMainEndpoint
//
// `/x/v2/reply/main` (NOT `/wbi/main`) with the request shape the
// open-source B站 client `Starfallan/PiliNara` uses for its
// anonymous read path (`lib/http/reply.dart` `ReplyHttp.replyList`,
// the `!isLogin` branch, hitting `'${Api.replyList}/main'` where
// `Api.replyList = '/x/v2/reply'` — so the resolved URL is
// `/x/v2/reply/main`).
//
// PiliNara's anonymous options object is:
//
//   Options(
//     headers: {...Constants.baseHeaders, 'cookie': ''},
//     extra: {'account': const NoAccount()},
//   )
//
// where `Constants.baseHeaders = {env: prod, app-key: android64,
// x-bili-aurora-zone: sh001}` and the User-Agent is
// `BiliDroid/2.0.1 (bbcallen@gmail.com) os/android ...` plus the
// constant `x-bili-trace-id: 11111111...:11111111:0:0`. The query
// payload is just `oid`, `type`, `pagination_str` and `mode`
// (PiliNara always sends `mode: sort + 2` — `2` for time-sorted,
// `3` for hot-sorted). No `wts` / `w_rid`, no appkey/sign, no
// `access_key`, no SESSDATA.
//
// We already set the User-Agent / baseHeaders / traceId via
// `buildSignedRequest`; this endpoint's job is just to flip the
// `anonymousRequest` flag on `get<T>` (which drops `mobi_app=iphone`
// / `platform=ios` / web `Origin` and forces an empty `Cookie`
// header — see `BilibiliAPIClient.buildSignedRequest`) and to call
// the `/main` endpoint instead of the `/wbi/main` one.
//
// Why a separate endpoint and not just a flag on the WBI one?
// `WbiSignedEndpoint` was specifically designed to hit
// `/x/v2/reply/wbi/main` with WBI sign + silent-gate recovery; mixing
// the two would conflate "the `/wbi/main` validator accepts the
// request and returns a valid cursor" with "the `/main` validator
// returns the same shape but with content instead of an empty
// replies list". A separate struct keeps the diagnostic logs
// (`commentsPage(anon-main): ...` vs `commentsPage: ...`) easy to
// grep and the next time B站 drifts `/wbi/main` or `/main` we have
// only one site to fix in either direction.
//
// Why a new endpoint, period? `WbiSignedEndpoint` was hitting
// `/x/v2/reply/wbi/main` and the v0.5.21 build 321 diagnostic
// showed the server now returns explicit -403 "访问权限不足" with
// 53 bytes on that path. The previous round stripped the
// legacy-shape query params (`plat`, `web_location`, `seek_rpid`)
// and BiliDroid UA, which was a delta but not the right one. The
// `WbiSignedEndpoint` was effectively asking the server "treat this
// as a WBI validator call" and the server said "no". The new
// `/x/v2/reply/main` is the PiliNara-validated path; we expect
// 200 OK + cursor + a non-empty `replies[]` if the fingerprint
// shape is right. If it still returns -403 we'll know the
// remaining delta is something else (cookie, accept-encoding,
// brotli body, HTTP/2 fingerprint, etc.) because the
// request shape will now be byte-for-byte equivalent to PiliNara's.
//
// Cursor: only `.offset` is understood — this endpoint's anonymous
// shape is the same opaque-`pagination_str` cursor as the WBI path.
// A `.pn` cursor (the legacy endpoint's) returns nil so the
// repository walks the chain to LegacyPnEndpoint. This matches
// `WbiSignedEndpoint`'s cursor-kind guard exactly.

struct AnonymousMainEndpoint: CommentEndpoint {
    let apiClient: BilibiliAPIClient

    func fetchPage(aid: Int, sort: CommentSort, cursor: CommentCursor) async throws -> CommentPage? {
        // Cursor kind guard. The /main endpoint uses
        // `pagination_str` (the opaque token) just like the
        // WBI path. We accept both `.offset` (the native
        // shape) and `.pn(1)` (the legacy endpoint's start
        // marker, treated as `offset = ""` — same
        // cross-endpoint silent-gate fallback that
        // `WbiSignedEndpoint` already uses).
        //
        // Why accept .pn(1)? The repository's chain is
        // walked in order: LegacyPn → AppSigned → **us** →
        // WbiSigned. When the legacy endpoint silently
        // gates (returns a valid `page` cursor with
        // `replies = 0` but `allCount > 0`) the
        // orchestrator falls through to the next endpoint
        // carrying the original `.pn(1)` cursor — it does
        // NOT translate the cursor between endpoints. If
        // `WbiSignedEndpoint` were the only /offset-shaped
        // endpoint, the chain would work, but `WbiSigned`
        // then hits `/wbi/main` (which the v0.5.21 build
        // 321 diagnostic showed returns explicit -403 with
        // the BiliDroid UA). Adding `AnonymousMainEndpoint`
        // between the app-signed and WBI paths means the
        // chain now has *two* /offset-shaped endpoints —
        // and only the first one (`us`) will see the
        // `.pn(1)` cursor. So we must accept it too, or the
        // orchestrator skips us entirely and the WBI -403
        // is the only outcome. Deeper pages (`pn > 1`)
        // still bail: the pn→offset mapping is not
        // lossless and a `.pn(N)` cursor has no meaning on
        // the opaque `pagination_str` token stream.
        let offset: String
        switch cursor {
        case .offset(let value):
            offset = value
        case .pn(let value):
            guard value == 1 else { return nil }
            offset = ""
        case .end:
            return nil
        }
        let paginationStr = "{\"offset\":\"\(offset)\"}"
        // PiliNara always sends `mode`; their default
        // `sort` parameter is `1` and the wire value is
        // `sort + 2`, so the default `mode` is `3` (hot).
        // We map the same: `.hot` → 3, `.newest` → 2.
        // There's no "no `mode`" option in PiliNara's
        // anonymous shape, so unlike WbiSignedEndpoint we
        // always append it.
        let mode: Int = (sort == .newest) ? 2 : 3
        bpLog("commentsPage(anon-main): fetching aid=\(aid) sort=\(sort) mode=\(mode) offset='\(offset)'")
        let payload: APIResponse<CommentPayload>
        do {
            payload = try await apiClient.get(
                baseURL: apiClient.baseURL,
                path: "/x/v2/reply/main",
                queryItems: [
                    URLQueryItem(name: "oid", value: "\(aid)"),
                    URLQueryItem(name: "type", value: "1"),
                    URLQueryItem(name: "pagination_str", value: paginationStr),
                    URLQueryItem(name: "mode", value: "\(mode)"),
                ],
                signWithWBI: false,
                // Dump the raw response body so we can
                // confirm the server is returning real
                // content (vs another -403 envelope in a
                // different shape). The dump goes to
                // `diagLog(.playback, ...)` under
                // `comments-raw-anon-main`; the byte count
                // alone is a strong signal — a populated
                // reply list is well over 4 KB. Must come
                // before `anonymousRequest` because Swift
                // requires labeled args to follow the
                // declaration order in `get<T>`.
                dumpRawBody: true,
                dumpTag: "comments-raw-anon-main",
                // Force the PiliNara anonymous request shape:
                // drop the iOS identity headers, send an
                // empty `Cookie` (so the SESSDATA in the
                // user's cookie jar doesn't auto-classify the
                // call as "logged-in third-party client" and
                // route us to the gated branch).
                anonymousRequest: true
            )
        } catch {
            // Diagnostic pair with the "fetching" log so
            // the failure mode is visible in the diagnostic
            // export. We deliberately let the throw
            // propagate so the repository walks the chain
            // to the WBI endpoint — if `/main` rejects us
            // with -403 the WBI path (or vice versa) is
            // still worth trying on the same fetch.
            bpLog("commentsPage(anon-main): fetch threw (\(error.localizedDescription))")
            throw error
        }
        // The /main endpoint uses the same
        // `CommentPayload` shape (replies / top_replies /
        // upper.top / cursor) as /wbi/main, so the
        // `CommentPageDecoder.decode(payload:)` from the
        // WBI path works here unchanged.
        if let val = payload.value {
            let upperKeys = val.upperTop.map { "upperTop keys=\($0.values.count)" } ?? "nil"
            let topReplies = val.topReplies.map { "topReplies items=\($0.items.count)" } ?? "nil"
            let replies = val.replies.map { "replies items=\($0.items.count)" } ?? "nil"
            let cursorDesc = val.cursor.map { c in
                "cursor next=\(c.next ?? -1) allCount=\(c.allCount) isEnd=\(c.isEnd) paginationReply=\(c.paginationReply.map { "nextOffset=\($0.nextOffset)" } ?? "nil")"
            } ?? "nil"
            bpLog("commentsPage(anon-main): payload | upper=\(upperKeys) \(topReplies) \(replies) \(cursorDesc)")
        } else {
            bpLog("commentsPage(anon-main): payload | value=nil code=\(payload.code ?? -1) message=\(payload.message ?? "?")")
        }
        let result = CommentPageDecoder.decode(payload: payload.value)
        let reportedTotal = result.totalCount
        let merged = result.items
        let nextCursor: CommentCursor? = result.next
        let isEnd = result.isEnd
        bpLog("commentsPage(anon-main): merged count=\(merged.count) allCount=\(reportedTotal) isEnd=\(isEnd) nextCursor=\(nextCursor.map(String.init(describing:)) ?? "nil")")
        // We intentionally do NOT raise `missingIdentity` on
        // the same `merged.isEmpty && reportedTotal > 0`
        // pattern that `WbiSignedEndpoint` uses. The
        // `missingIdentity` UX ("请登录后查看评论") is wrong
        // for this endpoint — by design it IS the
        // not-logged-in path. If the server returned
        // 200 OK + cursor but still withheld the
        // `replies[]`, fall through to the next endpoint
        // (WBI) by returning the page as-is. The
        // orchestrator will then walk to the WBI path and
        // either succeed or surface the proper error from
        // there. This keeps the per-endpoint error policy
        // local instead of letting one endpoint's UX
        // assumption leak into the next one's behavior.
        let nextCursorOptional: CommentCursor? = (nextCursor == .end) ? nil : nextCursor
        return CommentPage(
            items: merged,
            next: nextCursorOptional,
            isEnd: isEnd,
            totalCount: reportedTotal == 0 ? merged.count : reportedTotal
        )
    }
}

// MARK: - 7. CommentRepository
//
// Owns the ordered list of `CommentEndpoint` strategies and walks the
// chain on every fetch. The ordering is meaningful:
//
//   1. LegacyPnEndpoint — fastest path, works anonymously, only
//      requirement is the body responds with a real reply list. The
//      ship-from-cursor guard makes it skip if the previous cursor was
//      from the WBI path's `pagination_str` shape (so cursor kind
//      mismatch is caught at the protocol layer, not silently coerced).
//   2. AppSignedEndpoint — only kicks in when the user has an
//      `access_key`; silently returns `nil` otherwise. Currently
//      classified as a TV client by B站's server so it returns
//      `replies: null` even on comment-rich videos; kept for forward
//      compatibility in case B站 reopens the surface.
//   3. AnonymousMainEndpoint — the PiliNara-port anonymous read path
//      at `/x/v2/reply/main`. Sits between the app-signed path
//      (logged-in only) and the WBI path so a not-logged-in user
//      hits it before the WBI fallback. Sends BiliDroid UA +
//      empty cookie (no SESSDATA) so the server's per-client
//      fingerprint layer classifies the call as a BiliDroid
//      not-signed-in client. This is the path the v0.5.21 build
//      321 diagnostic surfaced the need for: the WBI path
//      (`/x/v2/reply/wbi/main`) now returns explicit -403
//      "访问权限不足" with the BiliDroid UA, but the
//      `/x/v2/reply/main` path is unsigned-friendly and (per
//      PiliNara) returns the real reply list.
//   4. WbiSignedEndpoint — the universal fallback. Includes the
//      silent-gate recovery internally.
//
// The repository is an `actor` so the endpoint list is safe to mutate
// from `init` (e.g. a future config page that lets the user re-order
// strategies) and so concurrent `fetchPage` calls do not race over the
// internal cursor state. Single-call serialization is intentional:
// ordering endpoint selection per-call is deterministic and matches
// the original waterfall's behavior.

actor CommentRepository {
    private let endpoints: [CommentEndpoint]

    init(endpoints: [CommentEndpoint]) {
        self.endpoints = endpoints
    }

    /// Convenience factory that wires the four endpoints in the
    /// canonical order against the given `BilibiliAPIClient`.
    static func defaultChain(apiClient: BilibiliAPIClient) -> CommentRepository {
        let chain: [CommentEndpoint] = [
            LegacyPnEndpoint(apiClient: apiClient),
            AppSignedEndpoint(apiClient: apiClient) { [weak apiClient] in
                guard let apiClient else { return nil }
                return await apiClient.currentAppConfig()?.accessKey
            },
            // AnonymousMainEndpoint sits between the
            // app-signed path (which only fires for
            // logged-in users with an `access_key`) and
            // the WBI path so a not-logged-in user hits
            // it before the WBI fallback. The /main
            // endpoint accepts unsigned requests and is
            // the one PiliNara's anonymous path uses; it
            // works anonymously, no SESSDATA required.
            AnonymousMainEndpoint(apiClient: apiClient),
            WbiSignedEndpoint(apiClient: apiClient),
        ]
        return CommentRepository(endpoints: chain)
    }

    /// Fetch one page. Walks the endpoint chain. Returns the first
    /// non-empty result. Returns an empty `CommentPage` (with
    /// `isEnd = true`) when every endpoint declined or returned empty
    /// for a video that genuinely has zero comments — the caller
    /// distinguishes the "0 comments" vs "all endpoints failed" case
    /// by the thrown error.
    func fetchPage(aid: Int, sort: CommentSort, cursor: CommentCursor) async throws -> CommentPage {
        guard !cursor.isEnd else {
            return CommentPage(items: [], next: nil, isEnd: true, totalCount: 0)
        }
        // Reset the `FailableDecodableDiag` failure
        // counter so the per-item diagnostic log
        // surfaces the first 3 wire-shape mismatches of
        // *this* fetch only. Without this, the cap is
        // consumed by earlier fetches and a fresh
        // comment-page decode drift (the v0.5.23 build
        // 323 case — see `BilibiliCommentVIPDTO`) ships
        // silently. The counter is process-global so the
        // reset must be called explicitly at the boundary
        // of every fetch.
        FailableDecodableDiag.failureCount = 0
        var lastError: Error?
        for endpoint in endpoints {
            do {
                if let page = try await endpoint.fetchPage(aid: aid, sort: sort, cursor: cursor),
                   !page.items.isEmpty {
                    return page
                }
                // nil = endpoint declined (wrong cursor kind, no
                // access_key, …). Empty array = endpoint accepted
                // but the video has no comments yet — return it
                // verbatim so the caller does not waste cycles on
                // the next endpoint.
            } catch {
                lastError = error
                bpLog("commentsPage: endpoint \(type(of: endpoint)) threw (\(error.localizedDescription)) — continuing")
            }
        }
        // All endpoints returned nil or empty. If one of them threw,
        // propagate the failure so the caller can distinguish from
        // "this video has 0 comments really".
        if let lastError {
            throw lastError
        }
        // No endpoint threw and no endpoint returned a page. Treat
        // as a no-content result.
        bpLog("commentsPage: all endpoints declined/empty — returning empty page")
        return CommentPage(items: [], next: nil, isEnd: true, totalCount: 0)
    }
}

// MARK: - 8. DTO / decode helpers
//
// Shared by all four endpoints. Living next to the endpoints means
// a cursor-shape drift in B站's response only needs to be fixed in
// one place — every endpoint already calls `CommentPageDecoder
// .decode(...)` for the WBI/App/AnonMain payload shape, and
// `LegacyPnEndpoint.mergeReplies(...)` for the legacy payload shape.

/// Mirrors `BilibiliAPIClient`'s `CommentPayload` (the WBI / app
/// shape). New WBI responses deliver pinned comments under
/// `upper.top` (a dict keyed by rpid); the legacy `top_replies` array
/// is kept for older cache hits.
struct CommentPayload: Decodable, Sendable {
    let replies: LenientCommentArray?
    let topReplies: LenientCommentArray?
    let upperTop: PinnedCommentDict?
    let cursor: CommentCursorDTO?

    enum CodingKeys: String, CodingKey {
        case replies
        case topReplies = "top_replies"
        case upper
        case cursor
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        replies = try container.decodeIfPresent(LenientCommentArray.self, forKey: .replies)
        topReplies = try container.decodeIfPresent(LenientCommentArray.self, forKey: .topReplies)
        cursor = try? container.decode(CommentCursorDTO.self, forKey: .cursor)
        if let upper = try? container.nestedContainer(keyedBy: DynamicKey.self, forKey: .upper) {
            upperTop = try? upper.decode(PinnedCommentDict.self, forKey: DynamicKey("top"))
        } else {
            upperTop = nil
        }
    }
}

/// Mirrors `BilibiliAPIClient`'s `LegacyCommentPayload`. Plain
/// `/x/v2/reply` (no appkey/sign/WBI) only — this is the only shape
/// B站 currently returns real reply data through, when the request
/// lands from an iOS URLSession client. Same path
/// `guozhigq/pilipala` (open-source Flutter B站 client) uses.
struct LegacyCommentPayload: Decodable, Sendable {
    let replies: LenientCommentArray?
    let page: LegacyCommentPage?
    let topReplies: LenientCommentArray?

    enum CodingKeys: String, CodingKey {
        case replies, page
        case topReplies = "top_replies"
    }
}

struct LegacyCommentPage: Decodable, Sendable {
    let num: Int
    let size: Int
    let count: Int
    let acount: Int

    enum CodingKeys: String, CodingKey {
        case num, size, count, acount
    }
}

struct CommentCursorDTO: Decodable, Sendable {
    let next: Int?
    let isEnd: Bool
    let allCount: Int
    let paginationReply: PaginationReplyDTO?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        next = container.decodeInt(keys: ["next"])
        isEnd = container.decodeBool(keys: ["is_end"]) ?? true
        allCount = container.decodeInt(keys: ["all_count"]) ?? 0
        paginationReply = try? container.decode(PaginationReplyDTO.self, forKey: DynamicKey("pagination_reply"))
    }
}

struct PaginationReplyDTO: Decodable, Sendable {
    let nextOffset: String

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        nextOffset = container.decodeString(keys: ["next_offset"]) ?? ""
    }
}

struct PinnedCommentDict: Decodable, Sendable {
    let values: [CommentDTO]

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode([String: FailableDecodable<CommentDTO>].self)
        values = raw.values.compactMap(\.value)
    }
}

struct LenientCommentArray: Decodable, Sendable {
    let items: [CommentDTO]

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode([FailableDecodable<CommentDTO>].self)
        self.items = raw.compactMap(\.value)
    }
}

/// File-scope rate-limit state for `FailableDecodable`'s
/// per-item diagnostic log. Lives in a non-generic enum
/// because Swift does not allow `static var` (a stored
/// property) inside a generic struct — only computed
/// properties are allowed there. Keeping the counter
/// at file scope (instead of on the generic type) also
/// makes the "one counter for the whole process" model
/// obvious to the next reader. See the long comment on
/// the call sites (`FailableDecodable.init` and
/// `CommentRepository.fetchPage`) for the rate-limit
/// contract.
fileprivate enum FailableDecodableDiag {
    /// Mutable counter (file-scope so a `static var` is
    /// legal). Only touched on the caller of
    /// `FailableDecodable.init` (decode thread) and
    /// `FailableDecodable.resetFailureCount` (also
    /// decode thread / main actor for the comment
    /// repository) so no atomicity is needed — Swift
    /// global `var` with single-thread access is fine.
    nonisolated(unsafe) static var failureCount: Int = 0
}

struct FailableDecodable<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        do {
            self.value = try container.decode(T.self)
        } catch {
            // Drop this element and keep going.
            // Diagnostic: log the per-item decode failure
            // so a future wire-shape drift (the v0.5.23
            // diagnostic hit this when B站's `/main`
            // endpoint started returning `vip.label` as
            // an object instead of a string, dropping
            // every comment into `value=nil` silently)
            // doesn't have to be re-debugged from
            // scratch. The log line is rate-limited to
            // 3 per decoder run via the file-scope
            // counter in `FailableDecodableDiag` — a
            // 20-comment page with all-failed items
            // would otherwise spam the diagnostic with
            // 20 identical lines. The first 3 are always
            // enough to see the underlying error; the
            // cap just stops the log file from blowing
            // up.
            FailableDecodableDiag.failureCount += 1
            if FailableDecodableDiag.failureCount <= 3 {
                bpLog("FailableDecodable<\(String(describing: T.self))> dropped an element: \(error)")
            }
            self.value = nil
        }
    }
}

extension FailableDecodable: Sendable where T: Sendable {}

struct CommentDTO: Decodable, Sendable {
    let rpid: Int
    let member: Member
    let content: Content
    let like: Int
    let rcount: Int?
    let replies: LenientCommentArray?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rpid = try container.decode(Int.self, forKey: .rpid)
        member = try container.decode(Member.self, forKey: .member)
        content = try container.decode(Content.self, forKey: .content)
        like = try container.decodeIfPresent(Int.self, forKey: .like) ?? 0
        rcount = try container.decodeIfPresent(Int.self, forKey: .rcount)
        replies = try container.decodeIfPresent(LenientCommentArray.self, forKey: .replies)
    }

    enum CodingKeys: String, CodingKey {
        case rpid
        case member
        case content
        case like
        case rcount
        case replies
    }

    var model: BiliComment {
        BiliComment(
            id: rpid,
            authorName: member.uname,
            avatarURL: member.avatarURL,
            message: content.message,
            likeCount: like,
            replyCount: rcount ?? 0,
            replies: replies?.items.map(\.model) ?? [],
            vipBadge: member.vip?.badge()
        )
    }

    struct Member: Decodable {
        let uname: String
        let avatarURL: URL?
        let vip: BilibiliCommentVIPDTO?

        enum CodingKeys: String, CodingKey {
            case uname
            case avatarURL = "avatar"
            case vip
        }
    }

    /// Bilibili reply `content` shapes are not uniform. Text replies have
    /// `message`; image replies have `pictures`; at-mentions have
    /// `at_name_to_mid`; emotes have `emote`; vote replies have `vote`.
    /// We accept whichever field is present and synthesise a label for
    /// the non-text cases so the row still renders instead of failing
    /// the whole thread.
    struct Content: Decodable {
        let message: String

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)
            if let raw = try? container.decode(String.self, forKey: DynamicKey("message")) {
                message = raw.strippingHTML
            } else if container.contains(DynamicKey("pictures")) {
                message = "[圖片評論]"
            } else if container.contains(DynamicKey("vote")) {
                message = "[投票]"
            } else if container.contains(DynamicKey("emote")) {
                message = "[表情]"
            } else if container.contains(DynamicKey("at_name_to_mid")) {
                message = "[at 訊息]"
            } else {
                message = ""
            }
        }
    }
}

/// Decodes the WBI / app payload shape into a `CommentPage`. The
/// pinned-comment merge logic (legacy `top_replies` + newer
/// `upper.top`) is shared between the WBI and app endpoints — both
/// call this helper so a future pinned-comment render change only
/// needs to be fixed in one place.
enum CommentPageDecoder {
    static func decode(payload: CommentPayload?) -> CommentPage {
        guard let payload else {
            return CommentPage(items: [], next: nil, isEnd: true, totalCount: 0)
        }
        // Pinned comments arrive under `top_replies` (legacy) or
        // `upper.top` (newer). Bilibili sometimes sends a thread where
        // every visible comment is pinned — without merging we'd show
        // an empty list. The latest WBI shape drops the nested
        // `data.upper.top` dict (only `data.upper.mid` remains) and
        // uses `data.top_replies` exclusively; reading either path
        // keeps the merge defensive against older cache hits.
        let pinned = payload.upperTop?.values.map(\.model) ?? []
        let legacyPinned = payload.topReplies?.items.map(\.model) ?? []
        let regular = payload.replies?.items.map(\.model) ?? []
        var seen = Set<Int>()
        var merged: [BiliComment] = []
        for model in pinned + legacyPinned + regular {
            if seen.insert(model.id).inserted {
                merged.append(model)
            }
        }
        let reportedTotal = payload.cursor?.allCount ?? 0
        let nextCursor: CommentCursor? = {
            guard let off = payload.cursor?.paginationReply?.nextOffset,
                  !off.isEmpty else { return nil }
            return .offset(off)
        }()
        let isEnd = payload.cursor?.isEnd ?? true
        return CommentPage(
            items: merged,
            next: nextCursor,
            isEnd: isEnd,
            totalCount: reportedTotal == 0 ? merged.count : reportedTotal
        )
    }
}
