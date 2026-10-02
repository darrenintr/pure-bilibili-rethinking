import AVFoundation
import SwiftUI
import DesignSystem
import UIKit

@main
struct PaladalaApp: App {
    @UIApplicationDelegateAdaptor(PaladalaAppDelegate.self) private var appDelegate
    @StateObject private var router = AppRouter()
    @StateObject private var authStore = AuthStore()
    @StateObject private var repository: PaladalaRepository
    @StateObject private var networkMonitor = NetworkMonitor()
    @StateObject private var miniPlayerStore = MiniPlayerStore()
    @StateObject private var errorCenter = AppErrorCenter.shared
    @AppStorage("paladala.themeMode") private var themeMode: ThemeMode = .system

    @AppStorage("paladala.expressiveSeed") private var expressiveSeed = "#FF6194"

    init() {
        let defaults = UserDefaults.standard
        // A single design is shipped. Replace every stored legacy choice before
        // SwiftUI reads preferences so upgrades open on the Expressive surface.
        defaults.set(DesignVariant.expressive.rawValue, forKey: "paladala.designVariant")
        PaladalaTheme.apply(.expressive)
        PaladalaTheme.expressiveTheme = DSTheme(seedHex: defaults.string(forKey: "paladala.expressiveSeed") ?? "#FF6194")
        Self.configureAppearance()
        // PR-fix-2026-07-10: register the BG task handler during
        // the launch window.  Previously this happened in
        // `body.onAppear`, but iOS 26 Beta aborts when
        // `BGTaskScheduler.register` runs after the launch window
        // closes, and also rejects `using: nil` outright.  Doing
        // it here — before any `@StateObject` initialisers fire —
        // keeps the call inside the window.  `wireRepository`
        // is still called from `onAppear` because the repository
        // is not yet constructed at this point.
        FollowNotificationService.shared.registerBackgroundHandler()
        LaunchMetrics.shared.mark(.appInitStart)
        // Audio session activation moved out of `init()` —
        // it now happens lazily inside `PlayerController.init`
        // (gated by a one-shot flag), so a cold start that
        // never opens a video never touches the audio HAL.
        let client = BilibiliAPIClient()
        // Pre-warm WbiSigner keys off the launch critical
        // path.  The first signed API request (typically the
        // home feed) used to pay a synchronous round-trip to
        // `/x/web-interface/nav`; with this fire-and-forget
        // task the keys are usually cached by the time the
        // feed view kicks off its network load.
        Task.detached(priority: .userInitiated) {
            await BilibiliAPIClient.prewarmWbiKeys()
        }
        // PR-A Task 10: pre-warm the HLS proxy listener off the
        // launch critical path. The first video tap would
        // otherwise pay the listener-startup cost synchronously
        // (audit item #8). The .proxyListenerReady mark is
        // emitted here, not inside prewarmProxyServer itself, so
        // the milestone measures the actual ready time as seen
        // by the app, not the time the call returned.
        LaunchMetrics.shared.mark(.proxyListenerRequested)
        Task.detached(priority: .userInitiated) {
            await LocalHLSProxyServer.prewarmProxyServer()
            LaunchMetrics.shared.mark(.proxyListenerReady)
        }
        // Cold-launch CDN speed test.  `CDNManager.ensureProbedOnLaunch()`
        // is idempotent (per-process flag + per-launch TTL
        // gate) and best-effort (any error is logged via
        // `diagLog` and swallowed), so it's safe to fire
        // unconditionally here.  When `autoPickEnabled` is on
        // and the probe finds a faster host, `selectedHost`
        // flips to the winner — the very first playback after
        // the probe finishes (typically a few hundred ms after
        // launch) goes to the new host without any UI flow.
        // The `.cdnProbeRequested` / `.cdnProbeReady` markers
        // show up in `PALADALA_COLD_START_DUMP=1` runs so we
        // can see how long the GitHub `cdn.json` fetch + 6-host
        // TLS probe took in the field.
        Task.detached(priority: .userInitiated) {
            await CDNManager.shared.ensureProbedOnLaunch()
        }
        let repo = PaladalaRepository(apiClient: client)
        // Do NOT clear `cookieProvider` here — the wired closure is
        // installed in `body.onAppear` below. Clearing it in `init`
        // opens a window where the first API request goes out
        // anonymously, which the user perceives as "logged out on
        // every fresh launch" until onAppear fires.
        _repository = StateObject(wrappedValue: repo)
        // Log the cold start so the diagnostic report has a
        // clear "the session started here" anchor.  Also start
        // the network monitor now so the first `.session` event
        // ("network.changed type=Wi-Fi") is captured even if the
        // user never opens the log viewer.
        diagLog(.app, "app.launch", details: [
            "marketingVersion":
                Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String ?? "?",
            "build":
                Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")
                as? String ?? "?"
        ])
        DeviceInfo.shared.startIfNeeded()
        // Boot the Paladala Portal reporter.  No-op when the
        // Settings toggle is off OR the xcconfig secret is
        // missing; `start()` self-guards on both.  Fire-and-
        // forget so the launch critical path is unaffected.
        Task.detached(priority: .utility) {
            await LogReporter.shared.start()
        }
        LaunchMetrics.shared.mark(.appInitComplete)
        // If the user opted in via the `PALADALA_COLD_START_DUMP=1`
        // env var (e.g. in the Xcode scheme for a perf run), write
        // the milestone log to `Application Support/Paladala/cold-start.jsonl`
        // on a background queue. The dump is opt-in so production
        // devices never accumulate the file.
        if ProcessInfo.processInfo.environment["PALADALA_COLD_START_DUMP"] == "1" {
            // PR-C Task 3: background JSONL dump via
            // Task.detached(priority: .utility). The dump is
            // fire-and-forget so we do not hold a handle;
            // it writes to Application Support and exits.
            Task.detached(priority: .utility) {
                LaunchMetrics.shared.dumpColdStartReport()
            }
        }
    }

    var body: some Scene {
        let _ = { PaladalaTheme.expressiveTheme = DSTheme(seedHex: expressiveSeed) }()
        WindowGroup {
            RootView(repository: repository)
                .environmentObject(router)
                .environmentObject(authStore)
                .environmentObject(repository)
                .environmentObject(networkMonitor)
                .environmentObject(miniPlayerStore)
                .environmentObject(errorCenter)
                .appErrorAlerts(errorCenter)
                .font(PaladalaTheme.FontRole.body)
                .tint(PaladalaTheme.biliPink)
                .dsTheme(DSTheme(seedHex: expressiveSeed))
                .onChange(of: expressiveSeed) { _, seed in
                    PaladalaTheme.expressiveTheme = DSTheme(seedHex: seed)
                }
                .preferredColorScheme(themeMode.colorScheme)
                .onAppear {
                    // Defensive re-hydration: in case the first render
                    // happened before `@StateObject` had a chance to
                    // run `AuthStore.bootstrap()` (e.g. when the
                    // SwiftUI view is mounted in the same runloop
                    // tick as the App init), re-read the persisted
                    // account list from the Keychain here. This is
                    // a single, cheap read and guarantees
                    // `activeAccount` is populated before the
                    // cookieProvider closure captures it.
                    authStore.bootstrap()

                    // Anonymous buvid3 capture. `BilibiliAPIClient
                    // .generateMobileBuvid()` falls back to a
                    // hard-coded "Paladala-iOS-Device-Seed" shared
                    // by every install — B 站 server fingerprints
                    // that seed and silently gates comment content
                    // for anonymous users. The official iOS app and
                    // every working third-party client (e.g.
                    // guozhigq/pilipala) fetch a real
                    // `/x/frontend/finger/spi` device fingerprint
                    // on first launch and reuse it across requests.
                    // Do the same here so anonymous reads stop
                    // triggering the per-fingerprint silent gate.
                    // Fire-and-forget so the first render does not
                    // pay the network hop; the next comment fetch
                    // (typically within a few hundred ms) sees the
                    // persisted value via `DeviceInfo
                    // .persistedBuvid3`. Errors are logged so a
                    // regression is diagnosable from the in-app
                    // log export.
                    if DeviceInfo.shared.persistedBuvid3 == nil {
                        let api = BilibiliAuthAPI()
                        Task {
                            do {
                                let ids = try await api.fetchDeviceID()
                                await MainActor.run {
                                    DeviceInfo.shared.setBuvids(
                                        buvid3: ids.buvid3,
                                        buvid4: ids.buvid4
                                    )
                                }
                            } catch {
                                bpLog("PaladalaApp: anonymous buvid3 fetch failed: \(error.localizedDescription)")
                            }
                        }
                    }

                    // VIP-status silent refresh on launch. The
                    // login flow captures a one-shot snapshot of
                    // `data.vip` at the time of sign-in; if the
                    // user bought / renewed a 大会员 in the
                    // web client afterwards, the persisted badge
                    // would stay stale until the next login. Hit
                    // `/x/web-interface/nav` once on launch and
                    // overwrite the Keychain copy. The call is
                    // best-effort — `refreshActiveAccountVip()`
                    // swallows network errors and leaves the
                    // cached badge alone. Off the SwiftUI render
                    // path: the explicit `Task { … }` keeps the
                    // `.onAppear` body non-blocking and stops a
                    // slow nav endpoint from holding up the
                    // first-paint sequence.
                    Task { await authStore.refreshActiveAccountVip() }

                    repository.apiClient.cookieProvider = { [weak authStore] in
                        authStore?.activeAccount?.cookieHeader
                    }
                    // The App API uses `buvid3` + `mid` to return a
                    // personalised feed. The closure is re-evaluated on
                    // every recommend call, so switching accounts in
                    // `ProfileSettingsView` immediately takes effect.
                    // `accessKey` is also plumbed through here so the
                    // appkey+sign auth path on the comments endpoint
                    // can pick it up without re-querying the account
                    // store on every request.
                    repository.apiClient.appConfigProvider = { [weak authStore] in
                        guard let account = authStore?.activeAccount else { return nil }
                        return BiliAppConfig(
                            buvid3: account.buvid3,
                            mid: account.mid,
                            csrf: account.csrf,
                            accessKey: account.accessKey
                        )
                    }
                    // Hook the follow-notification BG-task handler.
                    // The OS-level register was already done in
                    // `init()` (it must run inside the launch
                    // window); here we only wire the repository
                    // and account mid.  Safe to call again on
                    // account switch — `wireRepository` just
                    // updates the stored handles.
                    FollowNotificationService.shared.wireRepository(
                        repository,
                        accountMid: authStore.activeAccount?.mid ?? 0
                    )
                    // When the upstream API returns 401 the user is
                    // effectively logged out (B站 rotates SESSDATA
                    // every ~30 days). Pop the login sheet on the
                    // first 401 of a burst — the API client latches
                    // the failure so we only show the sheet once,
                    // and `AuthStore.completeLogin` resets the latch
                    // so the *next* session-expiry can re-fire.
                    repository.onSessionExpired { [weak router, weak errorCenter] in
                        _ = errorCenter?.record(
                            BilibiliAPIError.sessionExpired,
                            context: "authentication.sessionExpired"
                        )
                        router?.openLogin()
                    }

                    // iCloud preference mirror: idempotent bootstrap
                    // that subscribes to remote-change notifications
                    // and asks the system for an initial sync. The
                    // store itself decides whether a real iCloud
                    // account is signed in and exposes
                    // `isAvailable` so the settings toggle can
                    // render a hint when the user is not signed in.
                    ICloudSync.shared.bootstrap()
                }
                // Keep every account-scoped subsystem in sync on login,
                // account switch, and sign-out. The API providers above
                // read `activeAccount` dynamically, but the follow cache and
                // background poller store snapshots that must be refreshed.
                .onReceive(authStore.$activeAccount) { newAccount in
                    repository.invalidateFollowingsCache()
                    FollowNotificationService.shared.wireRepository(
                        repository,
                        accountMid: newAccount?.mid ?? 0
                    )
                }
                // Forward cross-view login requests (posted by
                // `PlayerView` when a live 403 surfaces the
                // "重新登录" recovery button) to the AppRouter.
                // Posting through NotificationCenter is the only
                // way to bubble an action out of an `AVPlayer`
                // overlay that doesn't hold the AppRouter
                // EnvironmentObject.
                .onReceive(NotificationCenter.default.publisher(
                    for: .paladalaRequestOpenLogin
                )) { _ in
                    router.openLogin()
                }
        }
    }

    /// Keep native navigation and tab bars consistent with Expressive surfaces.
    private static func configureAppearance() {
        let navigation = UINavigationBarAppearance()
        navigation.configureWithDefaultBackground()
        UINavigationBar.appearance().standardAppearance = navigation
        UINavigationBar.appearance().compactAppearance = navigation
        UINavigationBar.appearance().scrollEdgeAppearance = navigation
        let tabs = UITabBarAppearance()
        tabs.configureWithDefaultBackground()
        UITabBar.appearance().standardAppearance = tabs
        UITabBar.appearance().scrollEdgeAppearance = tabs
    }
}

// MARK: - Logger

@MainActor
final class Logger: ObservableObject {
    static let shared = Logger()

    @Published private(set) var logs: [String] = []
    private let maxLogs = 1000

    private init() {}

    /// `ISO8601DateFormatter` is expensive to instantiate
    /// (CFDateFormatter + locale resolution under the hood)
    /// and `Logger.log(...)` is on the launch hot path via
    /// `bpLog`.  `ISO8601DateFormatter` is **not**
    /// `Sendable` under Swift 6 (the underlying
    /// `NSISO8601DateFormatter` carries an `NSDateFormatter`
    /// sub-formatter that can be mutated), so we cannot
    /// cache a single instance in a `static let` reachable
    /// from any isolation domain.  Instead, build a fresh
    /// formatter on every call from a stored
    /// `formatOptions` bitmask.  The cost of constructing
    /// an `ISO8601DateFormatter` (one CFDateFormatter + a
    /// locale lookup) is dwarfed by the cost of the
    /// surrounding `@Published` mutation in the launch
    /// hot path, so this is not a regression.
    private static let timestampFormatOptions: ISO8601DateFormatter.Options = [.withInternetDateTime]
    private static func formatTimestamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = Self.timestampFormatOptions
        return f.string(from: date)
    }

    func log(_ message: String, file: String = #file, line: Int = #line) {
        let fileName = (file as NSString).lastPathComponent
        let timestamp = Self.formatTimestamp(Date())
        let logEntry = "[\(timestamp)] [\(fileName):\(line)] \(message)"

        // `Logger` is @MainActor; the @Published mutation
        // runs on main.  `bpLog(...)` (the callsite deferred
        // to PR-D) is called from every thread on the planet,
        // including URLSession and AVPlayer background
        // callbacks, so `bpLog` re-enters the main actor via
        // `Task { @MainActor in Logger.shared.log(...) }`.
        // Here inside `log(...)` we are already on the main
        // actor, so the mutation is a direct write.
        if self.logs.isEmpty {
            self.logs.append("[Paladala Session Start]")
        }
        self.logs.append(logEntry)
        if self.logs.count > self.maxLogs {
            self.logs.removeFirst()
        }
        // PR-B D10: previously this `print(logEntry)`
        // fired once per diagLog line — every chunk
        // arrival, every seek, every generation bump,
        // every state transition.  During a long video
        // that's tens of thousands of lines per session
        // and the OSLog buffer rolls them in seconds.
        // Replaced with a no-op (the entry is already in
        // the in-memory `logs` ring buffer for the
        // in-app viewer) so production builds don't
        // pay the per-line stdout cost.  DEBUG builds
        // still emit so the Xcode console shows the
        // live stream during development.
        #if DEBUG
        print(logEntry)
        #endif
    }

    func export() -> URL? {
        let allLogs = logs.joined(separator: "\n")
        if allLogs.isEmpty { return nil }

        let fileName = "Paladala_Logs_\(Int(Date().timeIntervalSince1970)).txt"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

        do {
            try allLogs.write(to: tempURL, atomically: true, encoding: .utf8)
            return tempURL
        } catch {
            // PR-B D10: route the export failure through
            // bpLog so it appears in the in-app log viewer
            // and survives into the next diagnostic dump.
            bpLog("Failed to export logs: \(error.localizedDescription)")
            return nil
        }
    }

    func copyToClipboard() {
        let allLogs = logs.joined(separator: "\n")
        UIPasteboard.general.string = allLogs
    }

    func clear() {
        // `Logger` is @MainActor; `bpLog` already hopped
        // us onto the main actor before calling this.
        self.logs.removeAll()
    }
}

func bpLog(_ message: String, file: String = #file, line: Int = #line) {
    // PR-C Task 5: `Logger` is now @MainActor. `bpLog` is
    // called from every thread (URLSession, AVPlayer, GCD
    // timers, BGTaskScheduler) so we hop to the main actor
    // via a structured-concurrency `Task`. The hop is
    // fire-and-forget; the `bpLog` caller does not await
    // the append, which is the same semantics the previous
    // `Task { @MainActor in ... }` inside `log(...)` had.
    Task { @MainActor in
        Logger.shared.log(message, file: file, line: line)
    }
}

// MARK: - Audio Session

enum PlayerAudioSession {
    /// Configure the shared audio session for video playback. Must be called once
    /// at app launch so the system allocates an appropriate route and so the
    /// player can keep rendering audio after the screen locks or the app moves
    /// to the background (when background-audio capability is added).
    static func activate() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback, options: [])
            try session.setActive(true, options: [])
        } catch {
            // Audio session failures are non-fatal for the UI shell — log and
            // continue. The player will still attempt playback, it just may
            // not produce sound on first run.
            bpLog("failed to activate audio session: \(error)")
        }
    }
}
