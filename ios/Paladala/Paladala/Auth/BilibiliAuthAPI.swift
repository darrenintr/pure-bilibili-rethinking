import CryptoKit
import Foundation

/// Login-only endpoints. Public and password / SMS flows both share
/// the same `/x/passport-login/web/*` surface. On success, the cookies
/// arrive as `Set-Cookie` headers *and* as query parameters on
/// `data.url` in the success body. We read them from the URL because
/// `URLSession` on iOS hides `Set-Cookie` by default — the URL body
/// path is reliable across iOS versions.
struct BilibiliAuthAPI {
    private let baseURL = URL(string: "https://passport.bilibili.com")!
    private let apiBaseURL = URL(string: "https://api.bilibili.com")!
    private let session: URLSession
    private let decoder: JSONDecoder

    init(session: URLSession = BilibiliAuthAPI.makeSession()) {
        self.session = session
        self.decoder = JSONDecoder()
    }

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 60
        config.waitsForConnectivity = true
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1",
            "Referer": "https://passport.bilibili.com/"
        ]
        return URLSession(configuration: config)
    }

    // MARK: - TV login appkey + sign helpers
    //
    // B站's "app-style" QR login (the path that issues `access_key`
    // + `refresh_token` alongside SESSDATA — same shape the official
    // B站 iOS app uses) does NOT live under `/x/passport-login/app/*`
    // (that path 404s, verified 2026-08-02). The documented public
    // endpoint is the TV flavor: `/x/passport-tv-login/qrcode/*`,
    // see pskdje/bilibili-API-collect `docs/login/login_action/QR.md`
    // and `docs/misc/sign/APPKey.md`.
    //
    // The credentials below are the `云视听小电视` (TV/OTT app)
    // appkey/appsec. The pink-app key the rest of Paladala uses
    // (`1d8b6e7d45233436`) is **rejected** by the TV endpoints with
    // `code=-403 访问权限不足` (verified 2026-08-02); the TV appkey
    // is the only public one on the permitted list. There is no
    // appkey negotiation in the response — the `access_token`
    // issued at the end of the flow is paired with whatever
    // appkey minted the QR. We accept that pairing here and let
    // `commentsPage` (the only current app-signed consumer) try
    // the token against the pink-app key; if B站 rejects the
    // `access_key` / appkey mismatch, the next step is to
    // migrate every app-signed call site to the TV key.
    private static let tvAppKey = "4409e2ce8ffd12b8"
    private static let tvAppSec = "59b43e04ad6965f34319062b478f83dd"

    /// MD5 used by the TV login appkey+sign path. Mirrors
    /// `BilibiliAPIClient.md5(_:)` but kept as a private static
    /// here so this file is self-contained (avoids widening
    /// `BilibiliAPIClient.appSign` visibility just to support
    /// login).
    private static func md5(_ string: String) -> String {
        Insecure.MD5.hash(data: Data(string.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// appkey+sign signature for the TV/QR endpoints. Algorithm
    /// per pskdje/bilibili-API-collect: sort form params by name,
    /// join as `key=value&key=value` (raw values, NOT
    /// percent-encoded — B站 re-decodes on the server side), then
    /// MD5 the resulting string with the appsec. Verified against
    /// the documented example (`appkey=4409e2ce8ffd12b8&local_id=0
    /// &ts=0` + `59b43e04ad6965f34319062b478f83dd` →
    /// `e134154ed6add881d28fbdf68653cd9c`).
    private static func tvSign(_ items: [URLQueryItem]) -> String {
        let sorted = items.sorted { $0.name < $1.name }
        let query = sorted.compactMap { item -> String? in
            guard let value = item.value else { return nil }
            return "\(item.name)=\(value)"
        }.joined(separator: "&")
        return md5(query + tvAppSec)
    }

    /// appkey+sign form body. Items are emitted in their existing
    /// order (the TV endpoint is field-order agnostic since the
    /// signature is computed from a name-sorted view). Each value
    /// is percent-encoded with the alphanumerics + `-._~`
    /// allow-list — matching `encodeURIComponent` semantics in
    /// JavaScript and the same encoder `BilibiliAPIClient.post(...)`
    /// uses for write APIs.
    private static func formBody(_ items: [URLQueryItem]) -> String {
        items.map { item in
            let key = Self.encodeURIComponent(item.name)
            let value = Self.encodeURIComponent(item.value ?? "")
            return "\(key)=\(value)"
        }.joined(separator: "&")
    }

    private static func encodeURIComponent(_ string: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }

    // MARK: - Web QR login (recommended path)

    /// Step 1: ask the server for a fresh QR token. The token drives
    /// the QR encoding and the polling.
    func webQrcodeGenerate() async throws -> WebQrcodeToken {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("/x/passport-login/web/qrcode/generate"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "source", value: "main-mini")]
        let url = components.url!
        let (data, _) = try await session.data(from: url)
        let payload = try decoder.decode(WebQrcodeGenerateResponse.self, from: data)
        return WebQrcodeToken(
            qrcodeKey: payload.data.qrcodeKey,
            url: payload.data.url
        )
    }

    /// Step 2: poll the QR status. On success, the cookies arrive in
    /// the `data.url` query string (and on `Set-Cookie` headers which
    /// iOS hides) — we extract them from the URL.
    func webQrcodePoll(qrcodeKey: String) async throws -> WebQrcodePollResult {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("/x/passport-login/web/qrcode/poll"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "qrcode_key", value: qrcodeKey)]
        let url = components.url!
        let (data, response) = try await session.data(from: url)
        let payload = try decoder.decode(WebQrcodePollResponse.self, from: data)
        // Prefer the body's `data.url` for cookies — iOS's URLSession
        // strips `Set-Cookie` from the response we can read. The
        // fallback (response header parsing) is preserved for the day
        // Apple exposes the cookies in a future SDK.
        let cookies = WebQrcodePollResult.cookies(
            fromPollURL: payload.data.url,
            response: response
        )
        return WebQrcodePollResult(
            code: payload.data.code,
            message: payload.data.message,
            url: payload.data.url,
            cookies: cookies
        )
    }

    // MARK: - App/TV QR login (returns access_key for appkey+sign auth)
    //
    // B站 does NOT expose a `/x/passport-login/app/qrcode/*` endpoint
    // — that path 404s. The "app-style" login flow that issues
    // `access_key` + `refresh_token` alongside SESSDATA (the same
    // shape the official B站 iOS / Android apps use) lives under
    // the **TV** namespace: `/x/passport-tv-login/qrcode/*`. Both
    // the iOS and Android official clients use the TV endpoint
    // under the hood; see pskdje/bilibili-API-collect
    // `docs/login/login_action/QR.md`.
    //
    // The QR code itself, however, is identical in form to what
    // every B站 client reads when scanning — the user opens the
    // official B站 iOS/Android app, points it at the QR, taps
    // confirm, and the server issues the bearer tokens paired with
    // the `tvAppKey` we minted the QR with. Those tokens unlock
    // `commentsPage`'s appkey+sign auth path (the WBI sign path
    // is silently gated by B站 风控 on URLSession clients; see
    // agent memory for the full diagnosis).

    /// Step 1: mint a fresh QR token via the TV-flavored
    /// `/x/passport-tv-login/qrcode/auth_code` endpoint. POST
    /// form-encoded with appkey+sign. Returns the QR URL
    /// (`https://passport.bilibili.com/x/passport-tv-login/h5/qrcode/auth?auth_code=...`,
    /// a redirect every B站 client reads as a login flow)
    /// and the polling key — the upstream calls it `auth_code`,
    /// but it has the same semantics as the web flow's
    /// `qrcode_key` (32-char opaque token the polling endpoint
    /// uses to identify the scanned QR).
    ///
    /// When the upstream returns `code != 0` (e.g. -403
    /// 「访问权限不足」 from a rejected appkey, or -400 from a
    /// malformed request) we surface a `BilibiliAuthError`
    /// carrying the upstream `message`, so
    /// `LoginViewModel` renders the upstream explanation
    /// rather than a generic decoding error.
    func appQrcodeGenerate() async throws -> WebQrcodeToken {
        let ts = Int(Date().timeIntervalSince1970)
        let items: [URLQueryItem] = [
            URLQueryItem(name: "appkey", value: Self.tvAppKey),
            URLQueryItem(name: "local_id", value: "0"),
            URLQueryItem(name: "ts", value: "\(ts)"),
        ]
        let signed = items + [URLQueryItem(name: "sign", value: Self.tvSign(items))]
        let body = Self.formBody(signed)
        let url = baseURL.appendingPathComponent("/x/passport-tv-login/qrcode/auth_code")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("https://www.bilibili.com", forHTTPHeaderField: "Referer")
        request.httpBody = body.data(using: .utf8)
        let (data, _) = try await session.data(for: request)
        let payload = try decoder.decode(TvQrcodeGenerateResponse.self, from: data)
        guard payload.code == 0, let inner = payload.data else {
            throw BilibiliAuthError(
                code: payload.code,
                message: payload.message,
                stage: .generate
            )
        }
        return WebQrcodeToken(qrcodeKey: inner.authCode, url: inner.url)
    }

    /// Step 2: poll the TV-flavored `/x/passport-tv-login/qrcode/poll`
    /// endpoint with the same appkey+sign pair. The TV endpoint
    /// state machine is:
    ///
    ///   - `0`: success — cookies (`SESSDATA`, `bili_jct`,
    ///     `DedeUserID`, `DedeUserID__ckMd5`, `buvid3`) are in
    ///     `data.cookie_info.cookies[]`, the bearer tokens
    ///     (`access_token`, `refresh_token`, `expires_in`, `mid`)
    ///     sit alongside. The `access_token` is what `commentsPage`
    ///     plumbs into `access_key=` to switch to the
    ///     appkey+sign auth path.
    ///   - `86039`: QR not yet confirmed. The TV flow's
    ///     catch-all "still pending" — covers both unscanned and
    ///     scanned-not-yet-confirmed because B站 does not
    ///     differentiate on this endpoint (the web flow uses
    ///     separate 86090 / 86101 codes; the TV flow does not).
    ///     We surface it as `.waiting` to keep the QR code on
    ///     screen and let the polling loop retry.
    ///   - `86090`: scanned-not-confirmed (matches the web code
    ///     if it ever surfaces here, kept for forward compat).
    ///   - `86038`: expired — the user must regenerate.
    ///   - any other code: surface the upstream `message` via
    ///     `BilibiliAuthError` so the sheet shows what B站
    ///     actually said.
    ///
    /// `data` is `null` for both the "still pending" codes
    /// (verified: `{"code":86039,"message":"二维码尚未确认",...,"data":null}`)
    /// and for several error codes; the DTO declares `data` as
    /// optional so the decoder doesn't blow up when the upstream
    /// leaves it absent.
    func appQrcodePoll(qrcodeKey: String) async throws -> AppQrcodePollResult {
        let ts = Int(Date().timeIntervalSince1970)
        let items: [URLQueryItem] = [
            URLQueryItem(name: "appkey", value: Self.tvAppKey),
            URLQueryItem(name: "auth_code", value: qrcodeKey),
            URLQueryItem(name: "local_id", value: "0"),
            URLQueryItem(name: "ts", value: "\(ts)"),
        ]
        let signed = items + [URLQueryItem(name: "sign", value: Self.tvSign(items))]
        let body = Self.formBody(signed)
        let url = baseURL.appendingPathComponent("/x/passport-tv-login/qrcode/poll")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("https://www.bilibili.com", forHTTPHeaderField: "Referer")
        request.httpBody = body.data(using: .utf8)
        let (data, response) = try await session.data(for: request)
        let payload = try decoder.decode(TvQrcodePollResponse.self, from: data)
        let cookies = AppQrcodePollResult.cookies(
            fromCookieInfo: payload.data?.cookieInfo?.cookies,
            fromPollURL: payload.data?.url,
            response: response
        )
        return AppQrcodePollResult(
            code: payload.code,
            message: payload.message,
            url: payload.data?.url ?? "",
            cookies: cookies,
            accessToken: payload.data?.accessToken,
            refreshToken: payload.data?.refreshToken,
            expiresIn: payload.data?.expiresIn ?? 0,
            mid: payload.data?.mid ?? 0
        )
    }

    /// Step 3: with the SESSDATA cookie in hand, hit `/x/web-interface/nav`
    /// to read the user `mid`, name, avatar, and 大会员 badge. The badge
    /// projection (`BiliVIPBadge`) is persisted onto the resulting
    /// `StoredAccount` so the profile header can render the colored
    /// chip on the very first paint after launch without a second
    /// round-trip.
    func navInfo(cookieHeader: String) async throws -> WebQrcodeNavInfo {
        let url = apiBaseURL.appendingPathComponent("/x/web-interface/nav")
        var request = URLRequest(url: url)
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("https://www.bilibili.com", forHTTPHeaderField: "Referer")
        let (data, _) = try await session.data(for: request)
        let payload = try decoder.decode(WebNavResponse.self, from: data)
        return WebQrcodeNavInfo(
            mid: payload.data.mid,
            name: payload.data.uname ?? "Bilibili 使用者",
            faceURL: payload.data.faceURL,
            vipBadge: payload.data.vip?.badge() ?? .none
        )
    }

    /// Fetches the device identifiers (buvid3/buvid4) from Bilibili's
    /// SPI endpoint. These are required for Wbi signing and tracking.
    func fetchDeviceID() async throws -> (buvid3: String, buvid4: String) {
        let url = apiBaseURL.appendingPathComponent("/x/frontend/finger/spi")
        var request = URLRequest(url: url)
        request.setValue("https://www.bilibili.com", forHTTPHeaderField: "Referer")
        let (data, _) = try await session.data(for: request)
        let payload = try decoder.decode(SpiResponse.self, from: data)
        return (buvid3: payload.data.b3, buvid4: payload.data.b4)
    }
}

// MARK: - SPI DTOs

private struct SpiResponse: Decodable, Sendable {
    let code: Int
    let data: SpiData
    struct SpiData: Decodable, Sendable {
        let b3: String
        let b4: String
    }
}

// MARK: - Web QR DTOs

struct WebQrcodeToken: Hashable {
    let qrcodeKey: String
    let url: String
}

private struct WebQrcodeGenerateResponse: Decodable, Sendable {
    let data: WebQrcodeGenerateData
    struct WebQrcodeGenerateData: Decodable, Sendable {
        let qrcodeKey: String
        let url: String
        enum CodingKeys: String, CodingKey {
            case qrcodeKey = "qrcode_key"
            case url
        }
    }
}

struct WebQrcodePollResult {
    /// `0` = logged in, `86038` = expired, `86090` = scanned (not
    /// confirmed), `86101` = not scanned.
    let code: Int
    let message: String
    /// On success, the cross-domain SSO URL with the cookies embedded
    /// as query parameters. Empty on intermediate states.
    let url: String
    /// Cookies extracted from `data.url` (and the `Set-Cookie` headers
    /// as a fallback). Empty on intermediate states.
    let cookies: [String: String]

    var state: WebQrcodeState {
        switch code {
        case 0: return .success
        case 86038: return .expired
        case 86090: return .scanned
        case 86101: return .waiting
        default: return .error(message)
        }
    }

    /// Extract cookies from the cross-domain URL query string.
    /// Supplements with cookies parsed from the `Set-Cookie`
    /// response header when the URL is missing one of the
    /// credentials we need (most commonly `SESSDATA` — B站
    /// has been observed to ship it via header instead of
    /// query params when the QR-confirm flow lands through
    /// the cross-domain SSO redirect).
    ///
    /// The previous implementation only consulted the
    /// `Set-Cookie` path when the URL was *entirely* empty
    /// (`out.isEmpty`); B站's `data.url` always carries
    /// non-cookie query items like `gourl=`, so that branch
    /// never fired even when SESSDATA was sitting in the
    /// response header. Now the Set-Cookie cookies are
    /// *merged* in — query items win on collision (so the
    /// upstream's intended values are not overwritten) and
    /// any credential that the URL omits falls through to
    /// the header parser.
    ///
    /// Set-Cookie parsing uses Foundation's
    /// `HTTPCookie.cookies(withResponseHeaderFields:for:)`
    /// (RFC 6265) rather than a hand-rolled `,` split, which
    /// broke the `Expires=Wed, 01 Jan 2026 00:00:00 GMT`
    /// attribute (a real cookie's expiry is one field, but
    /// naive `,` splitting tore it into two halves and
    /// truncated every cookie that followed the expiry).
    static func cookies(
        fromPollURL urlString: String,
        response: URLResponse
    ) -> [String: String] {
        var out: [String: String] = [:]
        if !urlString.isEmpty, let url = URLComponents(string: urlString),
           let items = url.queryItems {
            for item in items {
                out[item.name] = item.value
            }
        }
        // Supplement: Set-Cookie header. The poll endpoint
        // sometimes returns the auth cookies via the
        // `Set-Cookie` response header instead of
        // embedding them in the cross-domain `data.url`
        // (the upstream behaviour is a moving target).
        // iOS URLSession *does* surface Set-Cookie in
        // `allHeaderFields` when the session is configured
        // with `httpShouldSetCookies = false` (the existing
        // setup) — the helper just has to ask Foundation
        // for an RFC-6265 parse instead of slicing on `,`.
        if let http = response as? HTTPURLResponse {
            // `cookies(withResponseHeaderFields:for:)` only
            // reads the `Set-Cookie` keys, so a single dict
            // pull is enough. We pass a sentinel URL so the
            // parser accepts cookies without a `Domain=`
            // attribute (the cross-domain SSO redirect
            // legitimately omits the domain on some B站
            // responses); the parsed cookies' `.name` /
            // `.value` are the only fields we use downstream.
            let parsed = HTTPCookie.cookies(
                withResponseHeaderFields: http.allHeaderFields as! [String: String],
                for: URL(string: "https://passport.bilibili.com")!
            )
            for cookie in parsed {
                // Query items win on collision so a
                // B站-mandated URL-side override of any
                // cookie is preserved. Empty values are
                // dropped so a stray `Set-Cookie: foo=`
                // doesn't blank a real `foo=bar` the URL
                // already provided.
                if !cookie.value.isEmpty, out[cookie.name] == nil {
                    out[cookie.name] = cookie.value
                }
            }
        }
        return out
    }
}

enum WebQrcodeState {
    case waiting
    case scanned
    case expired
    case success
    case error(String)
}

private struct WebQrcodePollResponse: Decodable, Sendable {
    let data: WebQrcodePollData
    struct WebQrcodePollData: Decodable, Sendable {
        let code: Int
        let message: String
        let url: String
        enum CodingKeys: String, CodingKey {
            case code, message, url
        }
    }
}

// MARK: - App/TV QR DTOs (returns access_key + refresh_token alongside cookies)

/// Result of polling the TV-flavored `/x/passport-tv-login/qrcode/poll`
/// endpoint. Adds two bearer tokens to the cookies the web flow
/// returns: `accessToken` is the long-lived bearer used for
/// appkey+sign requests, and `refreshToken` is the long-lived
/// refresher that the auth pipeline can later trade for a fresh
/// access_token without forcing the user to scan the QR code
/// again.
struct AppQrcodePollResult {
    /// `0` = logged in, `86038` = expired, `86039` = TV-flow
    /// catch-all "QR not yet confirmed" (covers unscanned +
    /// scanned-not-confirmed), `86090` = scanned-not-confirmed
    /// (kept for forward compat with the web flow codes if they
    /// ever surface here), `86101` is unused on the TV side but
    /// kept for parity with `WebQrcodeState`'s raw mapping.
    let code: Int
    let message: String
    /// On success, the cross-domain SSO URL — present in newer
    /// B站 TV-flow responses for parity with the web SSO cookie
    /// redirect, but the TV endpoint already ships the cookies
    /// via `data.cookie_info.cookies[]` so the `url` is mostly
    /// informational here. Empty on intermediate states.
    let url: String
    /// Cookies merged from `data.cookie_info.cookies[]` (TV
    /// endpoint's preferred cookie channel) and, as a fallback,
    /// the `data.url` query string + `Set-Cookie` response
    /// header. Empty on intermediate states.
    let cookies: [String: String]
    /// `access_token` — the bearer token used in the `access_key`
    /// query param for appkey+sign requests. `nil` on intermediate
    /// states and on web-only logins.
    let accessToken: String?
    /// `refresh_token` — long-lived (the TV endpoint default is
    /// 180 days). Captured for future silent-refresh; not used in
    /// the first iteration.
    let refreshToken: String?
    /// `expires_in` — seconds until `accessToken` expires. `0` on
    /// intermediate states.
    let expiresIn: Int
    /// `mid` — server-confirmed user mid, useful for sanity-checking
    /// the account being created. `0` on intermediate states.
    let mid: Int64

    /// Maps the upstream `code` to `WebQrcodeState` so the
    /// `LoginViewModel.pollLoop` switch keeps handling the
    /// app/TV endpoint without a separate branch.
    ///
    /// The state codes used by B站's TV endpoint (per
    /// pskdje/bilibili-API-collect `QR.md` §"扫码登录(TV端)"):
    ///
    ///   - `0`     → `.success`
    ///   - `86039` → `.waiting` — TV flow's catch-all "still
    ///     pending" code. The web flow uses two separate codes
    ///     (`86090` scanned, `86101` unscanned); the TV flow
    ///     collapses them into `86039` (verified 2026-08-02:
    ///     an un-scanned fresh auth_code returned
    ///     `{"code":86039,"message":"二维码尚未确认"}`). We map
    ///     `86090` to `.scanned` too so a future drift back to
    ///     the web-style split keeps the UX consistent.
    ///   - `86038` → `.expired` — user must regenerate.
    var state: WebQrcodeState {
        switch code {
        case 0: return .success
        case 86038: return .expired
        case 86090: return .scanned
        case 86039, 86101: return .waiting
        default: return .error(message)
        }
    }

    /// Cookie extraction for the TV-flavored poll response.
    /// Reads from three sources, in this order (first-write
    /// wins per cookie name):
    ///
    ///   1. `data.cookie_info.cookies[]` — the TV endpoint's
    ///      primary cookie channel on success
    ///      (`[{"name": "SESSDATA", "value": "..."}, ...]`,
    ///      see pskdje/bilibili-API-collect `QR.md`).
    ///   2. `data.url` query string — newer B站 TV responses
    ///      also include a cross-domain SSO URL on success
    ///      (parity with the web flow); handled here so a
    ///      future "url-only" success body still yields
    ///      cookies.
    ///   3. `Set-Cookie` response header — defense in
    ///      depth, parsed via Foundation's
    ///      `HTTPCookie.cookies(withResponseHeaderFields:for:)`
    ///      (RFC 6265, same parser the web flow uses).
    static fileprivate func cookies(
        fromCookieInfo cookieInfo: [TvQrcodePollResponse.TvData.Cookie]?,
        fromPollURL urlString: String?,
        response: URLResponse
    ) -> [String: String] {
        var out: [String: String] = [:]
        // 1. cookie_info channel — preferred for the TV flow.
        if let arr = cookieInfo {
            for c in arr where !c.value.isEmpty {
                out[c.name] = c.value
            }
        }
        // 2. data.url query items — only fills in names not
        //    already populated by cookie_info (preserves the
        //    upstream-provided values when both paths deliver
        //    the same cookie).
        if let s = urlString, !s.isEmpty,
           let url = URLComponents(string: s),
           let items = url.queryItems {
            for item in items where item.value?.isEmpty == false {
                if out[item.name] == nil {
                    out[item.name] = item.value
                }
            }
        }
        // 3. Set-Cookie header — last resort.
        if let http = response as? HTTPURLResponse {
            let parsed = HTTPCookie.cookies(
                withResponseHeaderFields: http.allHeaderFields as! [String: String],
                for: URL(string: "https://passport.bilibili.com")!
            )
            for cookie in parsed {
                if !cookie.value.isEmpty, out[cookie.name] == nil {
                    out[cookie.name] = cookie.value
                }
            }
        }
        return out
    }
}

// MARK: - TV QR response DTOs

private struct TvQrcodeGenerateResponse: Decodable, Sendable {
    let code: Int
    let message: String
    /// `data` is `null` on error responses (e.g. `code=-403`
    /// from a rejected appkey, `code=-400` from a malformed
    /// request). Decoded as optional so the decoder doesn't
    /// throw on those paths — the caller checks `code`
    /// explicitly and surfaces `message` instead.
    let data: TvData?
    struct TvData: Decodable, Sendable {
        let url: String
        /// The polling key for `/x/passport-tv-login/qrcode/poll`.
        /// Same shape as the web flow's `qrcode_key` (32-char
        /// random string) but named differently upstream.
        let authCode: String
        enum CodingKeys: String, CodingKey {
            case url
            case authCode = "auth_code"
        }
    }
}

private struct TvQrcodePollResponse: Decodable, Sendable {
    let code: Int
    let message: String
    /// `data` is `null` on intermediate states (verified 2026-08-02:
    /// `{"code":86039, ... "data":null}` for an un-scanned fresh
    /// auth_code) and may also be null on certain error codes.
    /// Optional so the decoder survives those.
    let data: TvData?
    struct TvData: Decodable, Sendable {
        /// Cross-domain SSO URL — present in newer B站 TV
        /// responses for parity with the web flow, but is the
        /// informational one (cookies arrive via `cookie_info`).
        let url: String?
        let accessToken: String?
        let refreshToken: String?
        let expiresIn: Int?
        let mid: Int64?
        let cookieInfo: CookieInfo?
        enum CodingKeys: String, CodingKey {
            case url
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case mid
            case cookieInfo = "cookie_info"
        }

        struct CookieInfo: Decodable, Sendable {
            let cookies: [Cookie]?
        }

        /// The shape of `data.cookie_info.cookies[]` per
        /// pskdje/bilibili-API-collect `QR.md`. We only decode
        /// `name` and `value`; `expires`/`http_only`/`secure`
        /// are dropped (we're synthesizing a cookie header
        /// for `navInfo`, not building a real
        /// `HTTPCookieStorage`).
        struct Cookie: Decodable, Sendable {
            let name: String
            let value: String
        }
    }
}

// MARK: - Errors

/// Errors that surface from `BilibiliAuthAPI` to the login
/// sheet. The `code` + `message` map straight to the upstream
/// B站 response (so the sheet can render 「访问权限不足」 /
/// 「二维码尚未确认」 verbatim) and the `stage` distinguishes
/// generate vs poll for the diagnostic log.
struct BilibiliAuthError: LocalizedError {
    enum Stage: String {
        case generate
        case poll
    }

    let code: Int
    let message: String
    let stage: Stage

    var errorDescription: String? {
        switch stage {
        case .generate:
            return "B站 二維碼生成失敗 (\(code)): \(message)"
        case .poll:
            return "B站 二維碼輪詢失敗 (\(code)): \(message)"
        }
    }
}

struct WebQrcodeNavInfo {
    let mid: Int64
    let name: String
    let faceURL: URL?
    /// Decoded 大会员 badge. `.none` for accounts without a paid
    /// membership. The login flow plumbs this into
    /// `StoredAccount.vipBadge` so the profile chrome can
    /// render the badge without a fresh fetch.
    let vipBadge: BiliVIPBadge
}

private struct WebNavResponse: Decodable, Sendable {
    let data: WebNavData
    struct WebNavData: Decodable, Sendable {
        let mid: Int64
        let uname: String?
        let face: String?
        /// 大会员 block. `nil` for non-VIP accounts (or when the
        /// upstream omits the field, e.g. a future API drift).
        let vip: BilibiliNavVIPDTO?
        var faceURL: URL? {
            guard let face else { return nil }
            return URL(string: face.hasPrefix("//") ? "https:\(face)" : face)
        }
    }
}
