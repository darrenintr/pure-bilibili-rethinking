//
//  DeviceInfo.swift
//  Paladala
//
//  Snapshots system + network state for the diagnostic report and
//  the in-app log viewer.  Lives next to `DiagnosticLogger` so the
//  two share a "system context" story without one reaching into
//  the other's @MainActor isolation.
//
//  Two things live here:
//   1. A `NWPathMonitor` that publishes the current network type
//      (Wi-Fi / Cellular / Ethernet / Offline) and emits a
//      `.session` diagLog event whenever it changes.
//   2. A `snapshot(activeAccount:)` that returns the system info
//      header consumed by `DiagnosticLogger.generateReport()`.
//
//  Everything that touches UIKit (`UIDevice.current.model` etc.)
//  must be on the main actor — that's why this class is
//  `@MainActor`.  The path monitor itself delivers updates on a
//  private dispatch queue; we hop to main before mutating
//  `networkType`.
//

import Foundation
import Network
import Combine
import Synchronization
import UIKit

@MainActor
final class DeviceInfo: ObservableObject {
    // PR-C Task 5: mark the singleton `nonisolated` so
    // non-MainActor call sites (`BilibiliAPIClient.init`,
    // `WbiSigner.prewarm`, etc.) can read `userAgent`
    // without first hopping to the main actor.  The init is
    // private and the static is a `let`, so this is safe —
    // there is no other place that can write to the
    // reference.
    nonisolated static let shared = DeviceInfo()

    @Published private(set) var networkType: String = "Unknown"

    /// B 站 device-fingerprint cookie (`buvid3`). Persisted in
    /// `UserDefaults` because the value must survive across
    /// reinstalls on iOS 26 (whose Keychain retains unsigned-IPA
    /// entries across uninstall — a behavior change from iOS 18
    /// and earlier). `UserDefaults` is wiped with the app bundle,
    /// so the first launch after a reinstall will refresh the
    /// value via `BilibiliAuthAPI.fetchDeviceID()`.
    ///
    /// The previous implementation in `BilibiliAPIClient
    /// .generateMobileBuvid()` used a hard-coded
    /// `"Paladala-iOS-Device-Seed"` shared by every install; B
    /// 站 server fingerprints that seed and silently gates
    /// comment content for anonymous users. The Mac browser,
    /// iPhone official app, and iPad Safari all use a unique
    /// per-install buvid3 fetched from
    /// `/x/frontend/finger/spi` on first launch; Paladala
    /// needs to do the same to escape the silent-gate.
    nonisolated static let buvid3DefaultsKey = "paladala.device.buvid3"
    nonisolated static let buvid4DefaultsKey = "paladala.device.buvid4"

    /// Thread-safe read of the persisted buvid3. Callers in
    /// non-MainActor contexts (e.g. `BilibiliAPIClient.get`)
    /// can use this without hopping to the main actor. Returns
    /// `nil` on first launch / after a fresh install.
    nonisolated var persistedBuvid3: String? {
        UserDefaults.standard.string(forKey: Self.buvid3DefaultsKey)
    }

    /// Thread-safe read of the persisted buvid4, paired with
    /// `persistedBuvid3`.
    nonisolated var persistedBuvid4: String? {
        UserDefaults.standard.string(forKey: Self.buvid4DefaultsKey)
    }

    /// In-flight SPI fetch, guarded by a `Mutex` so a burst of
    /// callers (launch tasks + the 412 retry path) shares one network
    /// hop instead of stampeding `/x/frontend/finger/spi`.
    /// `Mutex` (not `NSLock`) because `lock()`/`unlock()` are banned
    /// from async contexts under Swift 6 concurrency checking.
    nonisolated let buvidFetchTask = Mutex<Task<Void, Never>?>(nil)

    /// Ensure a device-fingerprint pair is persisted, fetching it from
    /// `/x/frontend/finger/spi` when missing. Safe to call from any
    /// context; concurrent callers await the same fetch. B 站's
    /// `/x/web-interface/*` endpoints 412 fingerprint-less requests,
    /// so `BilibiliAPIClient.get` calls this on the 412 retry path.
    nonisolated func ensureBuvids() async {
        if persistedBuvid3 != nil { return }
        let task: Task<Void, Never> = buvidFetchTask.withLock { slot in
            if let existing = slot { return existing }
            let created = Task<Void, Never> {
                do {
                    let ids = try await BilibiliAuthAPI().fetchDeviceID()
                    await MainActor.run {
                        DeviceInfo.shared.setBuvids(buvid3: ids.buvid3, buvid4: ids.buvid4)
                    }
                } catch {
                    bpLog("DeviceInfo: buvid3 fetch failed: \(error.localizedDescription)")
                }
                DeviceInfo.shared.buvidFetchTask.withLock { $0 = nil }
            }
            slot = created
            return created
        }
        await task.value
    }

    /// Persist a freshly-fetched SPI device-fingerprint pair.
    /// `MainActor` because the underlying `UserDefaults` write
    /// should be serialised with the rest of the @MainActor
    /// state mutations during the launch sequence.
    @MainActor
    func setBuvids(buvid3: String, buvid4: String) {
        UserDefaults.standard.set(buvid3, forKey: Self.buvid3DefaultsKey)
        UserDefaults.standard.set(buvid4, forKey: Self.buvid4DefaultsKey)
        bpLog("DeviceInfo: buvid3 captured, length=\(buvid3.count)")
    }

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "Paladala.deviceInfo.net")
    private var started = false

    // `nonisolated` lets the singleton's `static let shared`
    // initialiser run from any context.  Body is empty so
    // there is no MainActor state touched.
    nonisolated private init() {}

    /// User-Agent string for outbound HTTP requests. Final
    /// shape picked on 2026-08-03 after diffing two
    /// working cross-reference clients (pilipala iOS-Safari
    /// Mobile, PiliNara BiliDroid/2.0.1) and reading
    /// `Starfallan/PiliNara/lib/common/constants.dart`. PiliNara's
    /// `Mozilla/5.0 BiliDroid/2.0.1 (bbcallen@gmail.com) os/android
    /// model/android_hd mobi_app/android_hd build/2001100 ...
    /// network/2` shape is the official B站 Android HD app's
    /// UA — it carries the `mobi_app/android_hd` and `osVer/15`
    /// tokens that B站's per-client fingerprint logic appears
    /// to whitelist. The previous iOS-Safari Mobile shape
    /// (still set on pilipala) also works, but the Android HD
    /// shape is what reaches the same `bili-universal/iphone`
    /// path the official iOS client uses once the appkey,
    /// `traceId`, and the `wbi/main` direct-`pagination_str`
    /// non-signed request shape (also taken from PiliNara) are
    /// lined up together. The `osVer` is hard-coded to 15 to
    /// keep the per-install UA stable across iOS upgrades —
    /// a fresh `osVer` for every install would defeat the
    /// whole point of using a fixed fingerprint.
    nonisolated var userAgent: String {
        return "Mozilla/5.0 BiliDroid/2.0.1 (bbcallen@gmail.com) os/android model/android_hd mobi_app/android_hd build/2001100 channel/master innerVer/2001100 osVer/15 network/2"
    }

    /// Start the path monitor.  Idempotent.  We call this from
    /// `PaladalaApp.init()` so the very first `.session`
    /// event ("network.changed") is captured even if the user
    /// never opens the log viewer.
    func startIfNeeded() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            let type: String
            switch path.status {
            case .satisfied:
                if path.usesInterfaceType(.wifi) {
                    type = "Wi-Fi"
                } else if path.usesInterfaceType(.cellular) {
                    type = "Cellular"
                } else if path.usesInterfaceType(.wiredEthernet) {
                    type = "Ethernet"
                } else {
                    type = "Other"
                }
            default:
                type = "Offline"
            }
            // PR-C Task 3: hop to the main actor with structured
            // concurrency instead of DispatchQueue.main.async. The
            // class is @MainActor so the mutation must run on the
            // main actor; the path monitor delivers callbacks on
            // its private dispatch queue. [weak self] keeps the
            // Task from retaining the singleton past deinit (a
            // no-op today since DeviceInfo is a singleton, but
            // cheap insurance for any future refactor that makes
            // the lifecycle shorter).
            Task { @MainActor [weak self] in
                guard let self, self.networkType != type else { return }
                self.networkType = type
                diagLog(.session, "network.changed", details: ["type": type])
            }
        }
        monitor.start(queue: queue)
    }

    /// System info snapshot, formatted as the report's "System
    /// Info" section.  The active account is passed in by the
    /// caller so this method (which is on the main actor) does
    /// not have to reach into the @MainActor `AuthStore`.
    func snapshot(activeAccount: StoredAccount? = nil) -> [(String, String)] {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "?"
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "?"
        let ios = ProcessInfo.processInfo.operatingSystemVersionString
        let device = UIDevice.current.model
        let systemName = UIDevice.current.systemName
        let locale = Locale.current.identifier
        let tz = TimeZone.current.identifier
        let net = networkType
        let account: String
        if let a = activeAccount {
            account = "\(a.name) (mid=\(a.mid))"
        } else {
            account = "(not signed in)"
        }
        return [
            ("App version", "\(version) (\(build))"),
            ("iOS", ios),
            ("Device", "\(device) (\(systemName))"),
            ("Locale", locale),
            ("Network", net),
            ("Timezone", tz),
            ("Active account", account)
        ]
    }
}
