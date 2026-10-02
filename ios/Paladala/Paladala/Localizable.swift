import Foundation

/// Type-safe localizable strings.
///
/// Usage:
///   Text(L10n.common.cancel)
///   Label(L10n.player.play, systemImage: "play.fill")
///
/// All keys are declared as static properties of nested namespaces
/// (`common.*`, `player.*`, `comments.*`, `a11y.*`). The actual
/// translations live in the three `Localizable.strings` files
/// (zh-Hans, zh-Hant, en) and are resolved by Foundation's
/// `String(localized:)` machinery.
enum L10n {

    // MARK: - Common UI

    enum common {
        static let cancel = String(localized: "common.cancel", defaultValue: "取消")
        static let confirm = String(localized: "common.confirm", defaultValue: "確認")
        static let retry = String(localized: "common.retry", defaultValue: "重試")
        static let done = String(localized: "common.done", defaultValue: "完成")
        static let close = String(localized: "common.close", defaultValue: "關閉")
        static let share = String(localized: "common.share", defaultValue: "分享")
        static let openInBrowser = String(localized: "common.openInBrowser", defaultValue: "瀏覽器開啟")
        static let copyLink = String(localized: "common.copyLink", defaultValue: "複製連結")
        static let skip = String(localized: "common.skip", defaultValue: "跳過")
        static let `continue` = String(localized: "common.continue", defaultValue: "繼續")
    }

    // MARK: - Tabs / Navigation

    enum tabs {
        static let home = String(localized: "tabs.home", defaultValue: "首頁")
        static let dynamic = String(localized: "tabs.dynamic", defaultValue: "動態")
        static let live = String(localized: "tabs.live", defaultValue: "直播")
        static let profile = String(localized: "tabs.profile", defaultValue: "我的")
        static let music = String(localized: "tabs.music", defaultValue: "音樂")
    }

    // MARK: - Music

    enum music {
        /// Tab / list title.
        static let title = String(localized: "music.title", defaultValue: "音樂")
        /// Empty-state headline when the music region returns no
        /// videos for the current page.
        static let empty = String(localized: "music.empty", defaultValue: "暫無音樂")
        static let emptyHint = String(localized: "music.emptyHint", defaultValue: "稍後再來，下拉重新整理試試。")
        static let networkError = String(localized: "music.networkError", defaultValue: "音樂列表載入失敗")
        /// "未找到歌词" placeholder shown in the lyrics pane.
        static let noLyrics = String(localized: "music.noLyrics", defaultValue: "這首歌暫無歌詞")
        /// "纯享" badge on the music tab card / now-playing bar
        /// to signal "audio only — no video surface".
        static let audioOnly = String(localized: "music.audioOnly", defaultValue: "純享")
        /// "歌词" pane header.
        static let lyricsHeader = String(localized: "music.lyrics", defaultValue: "歌詞")
        static let artwork = String(localized: "music.artwork", defaultValue: "封面")
    }

    // MARK: - Home / categories

    enum home {
        static let recommended = String(localized: "home.recommended", defaultValue: "推薦")
        static let follow = String(localized: "home.follow", defaultValue: "關注")
        static let popular = String(localized: "home.popular", defaultValue: "熱門")
        static let live = String(localized: "home.live", defaultValue: "直播")
        static let bangumi = String(localized: "home.bangumi", defaultValue: "追番")
        static let gaming = String(localized: "home.gaming", defaultValue: "遊戲")
        static let knowledge = String(localized: "home.knowledge", defaultValue: "知識")
        static let tech = String(localized: "home.tech", defaultValue: "科技")
        static let refresh = String(localized: "home.refresh", defaultValue: "重新整理")
    }

    // MARK: - Live

    enum live {
        /// "N 人在看" — used as a label next to the viewer count.
        static func watching(_ count: Int) -> String {
            String(
                localized: "live.watching",
                defaultValue: "\(count.compactCount) 人在看"
            )
        }
        /// "正在直播" badge.
        static let badge = String(localized: "live.badge", defaultValue: "LIVE")
        static let resolutionFailed = String(localized: "live.resolutionFailed", defaultValue: "直播間地址解析失敗")
        static let streamOffline = String(localized: "live.streamOffline", defaultValue: "主播已下播")
        static let networkError = String(localized: "live.networkError", defaultValue: "網路異常，請檢查連線後重試")
    }

    // MARK: - Video detail

    enum video {
        static let comments = String(localized: "video.comments", defaultValue: "評論")
        static let noComments = String(localized: "video.noComments", defaultValue: "暫無評論")
        static let noCommentsHint = String(localized: "video.noCommentsHint", defaultValue: "成為第一個評論的人")
        static let commentError = String(localized: "video.commentError", defaultValue: "評論載入失敗")
        static let subtitles = String(localized: "video.subtitles", defaultValue: "字幕")
        static let danmaku = String(localized: "video.danmaku", defaultValue: "彈幕")
        static let danmakuComingSoon = String(localized: "video.danmakuComingSoon", defaultValue: "彈幕 (即將推出)")
        static let noPlayableFormat = String(localized: "video.noPlayableFormat", defaultValue: "該影片的可用清晰度均不可播放（可能為地區限制或大會員專享）")
        static let addToWatchLater = String(localized: "video.addToWatchLater", defaultValue: "稍後再看")
        static let removeFromWatchLater = String(localized: "video.removeFromWatchLater", defaultValue: "從稍後再看中移除")
        static let removeFromHistory = String(localized: "video.removeFromHistory", defaultValue: "從歷史記錄中移除")
        /// "查看全部 N 条回复 >"
        static func viewAllReplies(_ count: Int) -> String {
            String(
                localized: "video.viewAllReplies",
                defaultValue: "檢視全部 \(count) 條回覆 >"
            )
        }
        /// Send-button label (发表).
        static let publish = String(localized: "video.publish", defaultValue: "釋出")
        static let fullscreen = String(localized: "video.fullscreen", defaultValue: "全屏")
        static let pip = String(localized: "video.pip", defaultValue: "畫中畫")
        static let airplay = String(localized: "video.airplay", defaultValue: "隔空播放")
        /// Sleep timer menu: "15 / 30 / 60 / 关闭" minutes.
        static let shareLANStream = String(localized: "video.shareLANStream", defaultValue: "LAN stream")
        static let shareLANStreamFailed = String(localized: "video.shareLANStreamFailed", defaultValue: "LAN sharing failed")
        enum sleepTimer {
            static let title = String(localized: "video.sleepTimer.title", defaultValue: "定時關閉")
            static let off = String(localized: "video.sleepTimer.off", defaultValue: "關閉")
            static let minutes15 = String(localized: "video.sleepTimer.15m", defaultValue: "15 分鐘")
            static let minutes30 = String(localized: "video.sleepTimer.30m", defaultValue: "30 分鐘")
            static let minutes60 = String(localized: "video.sleepTimer.60m", defaultValue: "60 分鐘")
        }
    }

    // MARK: - Comment threads (replies)

    enum replies {
        static let empty = String(localized: "replies.empty", defaultValue: "暫無回覆")
        static let emptyHint = String(localized: "replies.emptyHint", defaultValue: "成為第一個回覆的人")
    }

    // MARK: - Player (the VLC / AVPlayer surface)

    enum player {
        static let play = String(localized: "player.play", defaultValue: "播放")
        static let pause = String(localized: "player.pause", defaultValue: "暫停")
        static let buffering = String(localized: "player.buffering", defaultValue: "緩衝中…")
        static let speed = String(localized: "player.speed", defaultValue: "倍速")
        static let quality = String(localized: "player.quality", defaultValue: "清晰度")
        static let qualityAuto = String(localized: "player.qualityAuto", defaultValue: "自動")
        static let quality360 = String(localized: "player.quality360", defaultValue: "360P")
        static let quality480 = String(localized: "player.quality480", defaultValue: "480P")
        static let quality720 = String(localized: "player.quality720", defaultValue: "720P")
        static let quality1080 = String(localized: "player.quality1080", defaultValue: "1080P")
        /// 1080P 高码率 — the gated 1080P high-bitrate variant
        /// (qn=112) that B站 serves when VIP is active. Distinct
        /// from `quality1080` because the menu shows them side
        /// by side and the high-bitrate variant is the one
        /// typically required for HDR / Dolby Vision sources.
        static let quality1080Plus = String(localized: "player.quality1080Plus", defaultValue: "1080P 高位元速率")
        /// 1080P 60fps (qn=116). Requires 大会员.
        static let quality1080P60 = String(localized: "player.quality1080P60", defaultValue: "1080P 60幀")
        static let quality1080Hi = String(localized: "player.quality1080Hi", defaultValue: "1080P Hi-Res")
        static let quality4K = String(localized: "player.quality4K", defaultValue: "4K")
        static let quality4KHi = String(localized: "player.quality4KHi", defaultValue: "4K Hi-Res")
        static let quality4KHDR = String(localized: "player.quality4KHDR", defaultValue: "4K HDR")
        static let qualityHDR = String(localized: "player.qualityHDR", defaultValue: "HDR")
        static let qualityDolby = String(localized: "player.qualityDolby", defaultValue: "杜比視界")
        static let quality8K = String(localized: "player.quality8K", defaultValue: "8K")
        static let quality8KHDR = String(localized: "player.quality8KHDR", defaultValue: "8K HDR")
        /// Audio quality menu label. Mirrors `quality` for video
        /// but reads "音质" in zh-Hans; the toolbar icon
        /// already differentiates the two.
        static let audioQuality = String(localized: "player.audioQuality", defaultValue: "音質")
        /// 64 kbps AAC (low). Default for non-VIP users that
        /// picked nothing yet — universally available, AVPlayer
        /// consumes it natively.
        static let audioQuality64 = String(localized: "player.audioQuality64", defaultValue: "64K")
        /// 128 kbps AAC (standard). Default for first-launch
        /// users — matches the web player's fallback.
        static let audioQuality128 = String(localized: "player.audioQuality128", defaultValue: "128K")
        /// 192 kbps Dolby Atmos / 高码率 audio. Gated behind
        /// 大会员; the toolbar dims the row for non-VIP users.
        static let audioQuality192 = String(localized: "player.audioQuality192", defaultValue: "192K 杜比")
        /// 320 kbps Hi-Res AAC. Gated behind 大会员.
        static let audioQuality320 = String(localized: "player.audioQuality320", defaultValue: "320K Hi-Res")
        static let gestureHint = String(localized: "player.gestureHint", defaultValue: "雙擊左側後退 10s · 雙擊右側前進 10s · 雙擊中心點贊")
    }

    // MARK: - VIP / 大会员

    enum vip {
        /// Generic 大会员 chip text (used by the monthly tier).
        static let title = String(localized: "vip.title", defaultValue: "大會員")
        /// 年大会员 — annual membership badge.
        static let annualTitle = String(localized: "vip.annualTitle", defaultValue: "年度大會員")
        /// 十年大会员 — the 10-year commemorative membership.
        static let tenYearTitle = String(localized: "vip.tenYearTitle", defaultValue: "十年大會員")
        /// 超级大会员 (Super VIP) — B站's top tier.
        static let superTitle = String(localized: "vip.superTitle", defaultValue: "超級大會員")
        /// Tiny chip text appended to gated quality / audio menu
        /// rows so the user can see at a glance why the row is
        /// dimmed for non-VIP accounts. Rendered with the same
        /// pink as the regular VIP chip.
        static let lockedBadge = String(localized: "vip.lockedBadge", defaultValue: "大會員")
        /// "你还不是大会员，登录后可享受高清画质" style hint shown
        /// when the user taps a gated quality while signed out.
        static let upgradeHint = String(localized: "vip.upgradeHint", defaultValue: "登入大會員賬號後可解鎖此畫質")
        /// Title of the upgrade alert shown when a signed-in,
        /// non-VIP user picks a VIP-gated quality. Keeps the
        /// upgrade path a single tap away from the quality menu.
        static let requiredTitle = String(localized: "vip.requiredTitle", defaultValue: "需要大會員")
        /// Body of the upgrade alert shown when a signed-in,
        /// non-VIP user picks a VIP-gated quality. Mirrors the
        /// tone of the B站 web player's "请开通大会员后重试" prompt
        /// so the user knows the action unlocks the row they
        /// just tapped.
        static let requiredHint = String(localized: "vip.requiredHint", defaultValue: "該畫質/音質需要開通大會員")
        /// Title of the upgrade alert shown when a user *was* a
        /// 大会员 but the membership has lapsed (`vip.status == 0`
        /// or `-40103` from the playurl).
        static let expiredTitle = String(localized: "vip.expiredTitle", defaultValue: "大會員已到期")
        /// Body of the expired alert. Steers the user to the
        /// renewal page rather than the login sheet (they are
        /// already signed in; the cookie is fine).
        static let expiredHint = String(localized: "vip.expiredHint", defaultValue: "你的大會員已到期，續費後即可解鎖")
        /// Primary action label on the upgrade alert — opens
        /// B站's account management page where the user can
        /// purchase / renew the membership.
        static let actionUpgrade = String(localized: "vip.actionUpgrade", defaultValue: "去開通/續費")
        /// Secondary action label on the upgrade alert when the
        /// user is signed out. Opens the local login sheet so
        /// they can sign in with a VIP account that already
        /// has an active subscription.
        static let actionLogin = String(localized: "vip.actionLogin", defaultValue: "去登入")
        /// Status line on the profile header — `${kind} · 到期
        /// ${date}`. Falls back to `${kind} · 已过期` when the
        /// due date is in the past.
        static func status(_ kind: String, due: Date?) -> String {
            if let due {
                let f = DateFormatter()
                f.dateStyle = .medium
                f.timeStyle = .none
                f.locale = Locale(identifier: "zh_CN")
                return "\(kind) · 到期 \(f.string(from: due))"
            }
            return kind
        }
    }

    // MARK: - Mini-player

    enum miniPlayer {
        static let pause = String(localized: "miniPlayer.pause", defaultValue: "暫停")
        static let play = String(localized: "miniPlayer.play", defaultValue: "播放")
        static let expand = String(localized: "miniPlayer.expand", defaultValue: "展開播放器")
        static let close = String(localized: "miniPlayer.close", defaultValue: "關閉")
        static func label(for title: String) -> String {
            String(
                localized: "miniPlayer.label",
                defaultValue: "正在播放：\(title)"
            )
        }
    }

    // MARK: - Login / Auth

    enum login {
        static let title = String(localized: "login.title", defaultValue: "掃碼登入")
        static let statusWaiting = String(localized: "login.statusWaiting", defaultValue: "請使用手機 B 站 App 掃描二維碼")
        static let statusScanned = String(localized: "login.statusScanned", defaultValue: "已掃描，請在手機上確認登入")
        static let statusExpired = String(localized: "login.statusExpired", defaultValue: "二維碼已過期，請關閉後重試")
        static let statusError = String(localized: "login.statusError", defaultValue: "登入失敗，請稍後重試")
        static let statusSuccess = String(localized: "login.statusSuccess", defaultValue: "登入成功")
        static let ctaSignIn = String(localized: "login.ctaSignIn", defaultValue: "立即登入")
        static let ctaSignOut = String(localized: "login.ctaSignOut", defaultValue: "退出登入")
    }

    // MARK: - Errors

    enum errors {
        static let network = String(localized: "errors.network", defaultValue: "網路異常，請檢查連線後重試")
        static let rateLimit = String(localized: "errors.rateLimit", defaultValue: "操作太頻繁，請稍後再試")
        static let unauthorized = String(localized: "errors.unauthorized", defaultValue: "登入已過期，請重新登入")
        static let parse = String(localized: "errors.parse", defaultValue: "資料解析失敗")
        static let unknown = String(localized: "errors.unknown", defaultValue: "出錯了，請稍後重試")
        static let retry = String(localized: "errors.retry", defaultValue: "重試")
        static let empty = String(localized: "errors.empty", defaultValue: "暫無內容")
    }

    // MARK: - Settings

    enum settings {
        static let appearance = String(localized: "settings.appearance", defaultValue: "外觀")
        static let playback = String(localized: "settings.playback", defaultValue: "播放設定")
        static let plugins = String(localized: "settings.plugins", defaultValue: "外掛中心")
        static let diagnostics = String(localized: "settings.diagnostics", defaultValue: "系統與診斷")
        static let theme = String(localized: "settings.theme", defaultValue: "主題")
        static let material = String(localized: "settings.material", defaultValue: "設計風格")
        static let defaultTab = String(localized: "settings.defaultTab", defaultValue: "啟動時開啟")
        static let defaultSpeed = String(localized: "settings.defaultSpeed", defaultValue: "預設播放倍速")
        static let backgroundAudio = String(localized: "settings.backgroundAudio", defaultValue: "後臺播放音訊")
        static let clearCache = String(localized: "settings.clearCache", defaultValue: "清除快取")
        static let iCloudSync = String(localized: "settings.iCloudSync", defaultValue: "iCloud 同步")
        static let iCloudSyncHint = String(localized: "settings.iCloudSyncHint", defaultValue: "在登入了同一 Apple ID 的裝置間同步稍後再看、歷史記錄和偏好")
        static let accountSwitcher = String(localized: "settings.accountSwitcher", defaultValue: "切換賬號")
        static let reOnboarding = String(localized: "settings.reOnboarding", defaultValue: "重新檢視新手引導")
        static let logViewer = String(localized: "settings.logViewer", defaultValue: "執行日誌")
        static let diagnosticReport = String(localized: "settings.diagnosticReport", defaultValue: "深度診斷報告")
        /// Watch-later quick action — currently a placeholder.
        static let watchLaterComingSoon = String(localized: "settings.watchLaterComingSoon", defaultValue: "稍後再看 (即將推出)")
        /// Toggle title for the developer-options section that
        /// lets the user opt in to uploading diagnostic events
        /// to the Cloudflare-backed Paladala Portal.
        static let opspadToggleTitle = String(localized: "settings.opspadToggleTitle", defaultValue: "上報診斷日誌到 Paladala Portal")
        /// Toggle subtitle explaining what gets uploaded.
        static let opspadToggleHint = String(localized: "settings.opspadToggleHint", defaultValue: "批次上傳 .NETW/.AUTH/.PLAY 類別日誌到你專屬的 Cloudflare Worker")
        /// Section header for the developer-only settings.
        static let developerSectionTitle = String(localized: "settings.developerSectionTitle", defaultValue: "開發者選項")
        /// Footer note clarifying the toggle's default-off state
        /// and the local retention guarantee.
        static let opspadSectionFooter = String(localized: "settings.opspadSectionFooter", defaultValue: "預設關閉。開啟後，應用會把網路/認證/播放等診斷日誌批次加密簽名後上傳到你專屬的 Cloudflare Worker。本地依然保留完整的執行日誌。")
    }

    // MARK: - About page

    enum about {
        /// Navigation title for the 关于 screen.
        static let title = String(localized: "about.title", defaultValue: "關於")
        /// Row label: the human-readable marketing version
        /// (e.g. "0.5.1"). The build number is on a separate
        /// row right below.
        static let version = String(localized: "about.version", defaultValue: "版本")
        /// Row label: the monotonically increasing build
        /// number that the CI workflow bumps on every run
        /// (e.g. "195").
        static let build = String(localized: "about.build", defaultValue: "構建號")
        /// Row label: the per-build "特别辨识号" (special
        /// identifier), formatted as `PD-XXXX-XXXX-XXXX`.
        /// Tapping the row copies the identifier to the
        /// clipboard.
        static let identifier = String(localized: "about.identifier", defaultValue: "唯一辨識號")
        /// Short message that appears at the bottom of the
        /// screen for ~1.4 s after the user taps the
        /// identifier row, confirming the copy.
        static let identifierCopied = String(localized: "about.identifierCopied", defaultValue: "已複製到剪貼簿")
        /// Row label: how the running binary is distributed
        /// (debug / TestFlight / App Store / etc.).  Renders
        /// the localisable `debug` / `testflight` / etc.
        /// value below it.
        static let releaseType = String(localized: "about.releaseType", defaultValue: "釋出型別")
        /// Row label: free-form channel tag set by the build
        /// (e.g. "ci", "local", "appstore").  Renders the
        /// raw value as a monospaced string.
        static let channel = String(localized: "about.channel", defaultValue: "渠道")
        /// Row label: the short git commit SHA baked into
        /// the build.  Hidden entirely when the build is
        /// local (no commit recorded).
        static let commit = String(localized: "about.commit", defaultValue: "提交")
        /// Row label: the ISO-8601 timestamp the CI workflow
        /// captured at build time.  Renders as
        /// `yyyy-MM-dd HH:mm zzz`.
        static let buildDate = String(localized: "about.buildDate", defaultValue: "構建時間")
        /// Row label: the bundle identifier (e.g.
        /// `com.dt.paladala`).
        static let bundleId = String(localized: "about.bundleId", defaultValue: "Bundle ID")
        /// Button label that triggers the GitHub Releases
        /// lookup.
        static let checkForUpdates = String(localized: "about.checkForUpdates", defaultValue: "檢查更新")
        /// Inline status shown under the button while the
        /// network call is in flight.
        static let checking = String(localized: "about.checking", defaultValue: "正在檢查…")
        /// Status shown when the remote tag is older than
        /// or equal to the local build.  The remote tag is
        /// appended after the `·` so the user can see which
        /// version we compared against.
        static let upToDate = String(localized: "about.upToDate", defaultValue: "已是最新版本")
        /// Status shown when the remote tag is newer than
        /// the local build.  The remote tag follows after
        /// the `·`.
        static let updateAvailable = String(localized: "about.updateAvailable", defaultValue: "發現新版本")
        /// Status shown when the network call fails or the
        /// API returns a non-2xx response.  Appended after
        /// an `exclamationmark.triangle` glyph.
        static let updateFailed = String(localized: "about.updateFailed", defaultValue: "檢查更新失敗，請稍後重試")
        /// Button label on the update-available row that
        /// opens the GitHub release page for the new tag.
        static let viewRelease = String(localized: "about.viewRelease", defaultValue: "檢視釋出")
        /// Button label on the dev-build row that opens the
        /// repository's releases tab so the tester can grab
        /// the latest unsigned IPA manually.
        static let openOnGitHub = String(localized: "about.openOnGitHub", defaultValue: "在 GitHub 上開啟")
        /// Status shown when the running build is a
        /// development / sideloaded binary; the update
        /// checker always recommends grabbing the latest
        /// release instead of trying to compare versions.
        static let devBuild = String(localized: "about.devBuild", defaultValue: "當前為開發構建，不參與版本比較")
        /// Button label on the update-available row that
        /// hands the install to AltStore via its URL scheme.
        /// Rendered when AltStore is detected on the device.
        static let openInAltStore = String(localized: "about.openInAltStore", defaultValue: "用 AltStore 安裝")
        /// Button label on the update-available row that
        /// hands the install to SideStore via its URL scheme.
        /// Rendered when AltStore is not installed but
        /// SideStore is.
        static let openInSideStore = String(localized: "about.openInSideStore", defaultValue: "用 SideStore 安裝")
        /// Inline status shown while the URL-scheme jump is
        /// being dispatched. The actual install dialog
        /// appears in the store app, not in Paladala.
        static let opening = String(localized: "about.opening", defaultValue: "正在開啟安裝頁…")
        /// Status shown when neither AltStore nor SideStore
        /// is installed on the device; the user is directed
        /// to open the AltSource page in Safari and refresh
        /// it from there.
        static let noStoreDetected = String(localized: "about.noStoreDetected", defaultValue: "未檢測到 AltStore / SideStore")
        /// Button label that opens the project's GitHub
        /// Releases tab in Safari. Shown as a secondary
        /// action so a user without a sideload store can
        /// still grab the IPA + changelog manually.
        static let viewOnGitHub = String(localized: "about.viewOnGitHub", defaultValue: "在 GitHub Releases 檢視")
        /// Footer note under the update card. Updated from
        /// the old GitHub-API wording to reflect the new
        /// AltSource-based check.
        static let checkSourceHint = String(localized: "about.checkSourceHint", defaultValue: "對比當前版本與 AltSource 列表的最新條目")
        // Release-type display names.  Each value pairs with
        // `ReleaseType.displayName` in AppVersion.swift.
        static let debug = String(localized: "about.releaseType.debug", defaultValue: "除錯")
        static let appStore = String(localized: "about.releaseType.appStore", defaultValue: "App Store")
        static let testflight = String(localized: "about.releaseType.testflight", defaultValue: "TestFlight")
        static let enterprise = String(localized: "about.releaseType.enterprise", defaultValue: "企業分發")
        static let sideload = String(localized: "about.releaseType.sideload", defaultValue: "側載")
        static let unknown = String(localized: "about.releaseType.unknown", defaultValue: "未知")
    }

    // MARK: - Accessibility

    enum a11y {
        static let homeCategory = String(localized: "a11y.homeCategory", defaultValue: "首頁分類")
        static let subCategory = String(localized: "a11y.subCategory", defaultValue: "二級分類")
        static let commentLike = String(localized: "a11y.commentLike", defaultValue: "點贊評論")
        static let replyLike = String(localized: "a11y.replyLike", defaultValue: "點贊回覆")
        static let quickAction = String(localized: "a11y.quickAction", defaultValue: "快捷入口")
        static let sidebarTab = String(localized: "a11y.sidebarTab", defaultValue: "側邊欄標籤")
        static let collapseSidebar = String(localized: "a11y.collapseSidebar", defaultValue: "收起側邊欄")
    }

    // MARK: - Onboarding

    enum onboarding {
        static let page1Title = String(localized: "onboarding.page1.title", defaultValue: "為 B 站而生")
        static let page1Subtitle = String(localized: "onboarding.page1.subtitle", defaultValue: "首頁、動態、直播、追番，一個應用就夠了")
        static let page2Title = String(localized: "onboarding.page2.title", defaultValue: "順手就走的播放")
        static let page2Subtitle = String(localized: "onboarding.page2.subtitle", defaultValue: "小窗播放、畫中畫、後臺音訊 — 切換應用也不中斷")
        static let page3Title = String(localized: "onboarding.page3.title", defaultValue: "登入後更強")
        static let page3Subtitle = String(localized: "onboarding.page3.subtitle", defaultValue: "登入後同步歷史記錄、收藏夾和稍後再看")
        static let ctaStart = String(localized: "onboarding.ctaStart", defaultValue: "開始")
        static let ctaSkip = String(localized: "onboarding.ctaSkip", defaultValue: "跳過")
    }

    // MARK: - AI 视频总结

    enum aiSummary {
        /// "AI 视频总结" — chip header for the AI summary section.
        /// Mirrors the upstream "AI 小助手" label for users who
        /// are familiar with the web player.
        static let title = String(localized: "aiSummary.title", defaultValue: "AI 影片總結")
        /// "章节" — small heading above the chapter outline list.
        static let chapters = String(localized: "aiSummary.chapters", defaultValue: "章節")
        /// "跳转到此位置" — VoiceOver hint on each outline chapter
        /// and bullet row. Both rows are tap-to-seek, so the
        /// hint is identical for both.
        static let seekHint = String(localized: "aiSummary.seekHint", defaultValue: "跳轉到此位置")
    }

    // MARK: - SponsorBlock 拦截恰饭

    enum sponsorBlock {
        static let title = String(localized: "sponsorBlock.title", defaultValue: "攔截恰飯")
        static let enable = String(localized: "sponsorBlock.enable", defaultValue: "啟用攔截恰飯")
        static let autoSkip = String(localized: "sponsorBlock.autoSkip", defaultValue: "自動跳過")
        static let minVotes = String(localized: "sponsorBlock.minVotes", defaultValue: "最低投票數")
        static let categories = String(localized: "sponsorBlock.categories", defaultValue: "攔截類別")
        static let report = String(localized: "sponsorBlock.report", defaultValue: "上報恰飯片段")
        static let viewSegments = String(localized: "sponsorBlock.viewSegments", defaultValue: "檢視已載入的片段")
        static let timeSaved = String(localized: "sponsorBlock.timeSaved", defaultValue: "已節省時間")
        static let submit = String(localized: "sponsorBlock.submit", defaultValue: "提交")
        static let submitSuccess = String(localized: "sponsorBlock.submitSuccess", defaultValue: "提交成功！感謝您的貢獻。")
        static let enabled = String(localized: "sponsorBlock.enabled", defaultValue: "已開啟")
    }
}

// MARK: - Bundle resolution helper
//
// `String(localized:)` already picks the right .strings file based
// on the current locale. This file is here as a stable namespace
// for future helpers (e.g. plural-aware formatting, table lookup).
