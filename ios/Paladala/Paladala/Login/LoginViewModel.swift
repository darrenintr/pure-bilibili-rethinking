import SwiftUI
import CoreImage.CIFilterBuiltins

/// Drives the Web QR login sheet. Owns the QR generation, the polling
/// loop, and the SESSDATA capture. Mirrors the Android `LoginViewModel`
/// state machine in spirit: generating → waiting → scanned → success
/// (or expired / error).
@MainActor
final class LoginViewModel: ObservableObject {
    enum State: Equatable {
        case generating
        case waiting(image: UIImage, key: String)
        case scanned(image: UIImage, key: String)
        case expired
        case success(StoredAccount)
        case error(String)
    }

    @Published private(set) var state: State = .generating
    @Published private(set) var statusText: String = "正在生成二維碼…"

    private let authAPI: BilibiliAuthAPI
    private var authStore: AuthStore
    private var pollTask: Task<Void, Never>?

    init(authAPI: BilibiliAuthAPI = BilibiliAuthAPI(), authStore: AuthStore) {
        self.authAPI = authAPI
        self.authStore = authStore
    }

    /// Re-bind to the live environment-provided `AuthStore`. The sheet
    /// uses this to swap in the real store after `@StateObject` is set
    /// up, since the init doesn't have access to the environment.
    func setAuthStore(_ store: AuthStore) {
        self.authStore = store
    }

    deinit {
        pollTask?.cancel()
    }

    /// Generate a fresh QR code, render it, and start the polling loop.
    /// Uses the **web** QR endpoint (`/x/passport-login/web/qrcode/...`).
    ///
    /// History: the TV-flavored endpoint
    /// (`/x/passport-tv-login/qrcode/...`) was tried because its
    /// `access_token` unlocks the appkey+sign auth path for the
    /// comments endpoint. Verified 2026-08-02 that this is a dead
    /// end: B站 classifies the TV-paired token *and* the TV login's
    /// SESSDATA as "TV client", and the comments endpoint silently
    /// returns `replies: null` for TV-classified callers even with
    /// a valid signature. Meanwhile the plain `/x/v2/reply` legacy
    /// endpoint returns real reply lists for **web**-classified
    /// SESSDATA cookies (the shape guozhigq/pilipala uses), so the
    /// web QR flow is the correct login surface. The appkey+sign
    /// paths stay in the API client as forward-compat fallbacks.
    func start() {
        pollTask?.cancel()
        statusText = "正在生成二維碼…"
        state = .generating
        pollTask = Task { [weak self] in
            guard let self else { return }
            do {
                let token = try await authAPI.webQrcodeGenerate()
                guard let image = Self.renderQR(token.url) else {
                    state = .error("二維碼生成失敗，請重試")
                    statusText = "二維碼生成失敗"
                    return
                }
                state = .waiting(image: image, key: token.qrcodeKey)
                statusText = "請使用 Bilibili App 掃碼登入"
                await self.pollLoop(key: token.qrcodeKey, image: image)
            } catch {
                state = .error(error.localizedDescription)
                statusText = "生成失敗：\(error.localizedDescription)"
            }
        }
    }

    /// Cancel the in-flight polling task and ask the server for a
    /// fresh token. Called when the user taps "刷新二维码".
    func regenerate() {
        start()
    }

    func cancel() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func pollLoop(key: String, image: UIImage) async {
        // Bilibili recommends a 3 s poll interval. We back off slightly
        // on errors and bail out on `.expired` / `.success`.
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: 3_000_000_000)
                if Task.isCancelled { return }
                let result = try await authAPI.webQrcodePoll(qrcodeKey: key)
                switch result.state {
                case .waiting:
                    statusText = "請使用 Bilibili App 掃碼登入"
                case .scanned:
                    state = .scanned(image: image, key: key)
                    statusText = "請在手機上確認登入"
                case .expired:
                    state = .expired
                    statusText = "二維碼已過期，請重新整理"
                    return
                case .success:
                    // Web flow carries no `access_key` — the
                    // appkey+sign path is a forward-compat fallback
                    // (see `start()` for the full history).
                    await completeLogin(cookies: result.cookies, accessKey: nil)
                    return
                case .error(let message):
                    statusText = "登入失敗：\(message)"
                    return
                }
            } catch is CancellationError {
                return
            } catch {
                statusText = "網路異常，正在重試…"
                // Continue the loop on transient failures.
            }
        }
    }

    private func completeLogin(cookies: [String: String], accessKey: String?) async {
        guard let sessData = cookies["SESSDATA"], !sessData.isEmpty,
              let csrf = cookies["bili_jct"], !csrf.isEmpty else {
            state = .error("登入成功但未返回 SESSDATA 憑證")
            statusText = "登入成功但未返回憑證"
            return
        }
        var buvid3 = cookies["buvid3"]
        let dede = cookies["DedeUserID"]

        // If buvid3 is missing from the login callback (common), fetch it
        // from the SPI endpoint so Wbi signing works on first launch.
        if buvid3 == nil || buvid3!.isEmpty {
            do {
                let spi = try await authAPI.fetchDeviceID()
                buvid3 = spi.buvid3
            } catch {
                bpLog("Failed to fetch device ID during login: \(error)")
            }
        }

        // Diagnostic so we can verify the access_key actually arrived
        // on first capture — the field is the long-lived bearer token
        // used by the appkey+sign auth path; logging just its length
        // (never the value) keeps the diagnostic useful without
        // shipping a credential into the log file. The web QR flow
        // never returns one (nil here is the norm, not an error).
        if let accessKey, !accessKey.isEmpty {
            bpLog("QR login: access_key captured, length=\(accessKey.count)")
        } else {
            bpLog("QR login: web flow — no access_key (comments use the legacy /x/v2/reply path)")
        }

        let cookieHeader = StoredAccount(
            mid: 0,
            name: "",
            sessData: sessData,
            csrf: csrf,
            buvid3: buvid3,
            dedeUserID: dede,
            accessKey: accessKey
        ).cookieHeader
        do {
            let info = try await authAPI.navInfo(cookieHeader: cookieHeader)
            let account = StoredAccount(
                mid: info.mid,
                name: info.name,
                faceURL: info.faceURL,
                sessData: sessData,
                csrf: csrf,
                buvid3: buvid3,
                dedeUserID: dede,
                accessKey: accessKey,
                vipBadge: info.vipBadge.isActive ? info.vipBadge : nil
            )
            authStore.completeLogin(account)
            state = .success(account)
            statusText = "登入成功：\(info.name)"
        } catch {
            state = .error("讀取賬號資訊失敗：\(error.localizedDescription)")
            statusText = "登入成功但讀取賬號資訊失敗"
        }
    }

    private static func renderQR(_ string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale: CGFloat = 8
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else {
            return nil
        }
        return UIImage(cgImage: cg)
    }
}
