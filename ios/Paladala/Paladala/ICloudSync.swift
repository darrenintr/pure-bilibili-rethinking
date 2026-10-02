import Foundation
import SwiftUI

/// Thin wrapper around `NSUbiquitousKeyValueStore` so the
/// rest of the app reads / writes iCloud-synced preferences
/// through a single, easy-to-grep surface.
///
/// The store is intentionally minimal: only the
/// `@AppStorage` values that the user would expect to land
/// on a fresh install (theme, danmaku toggle, material
/// design) are mirrored. Account sessions, watch-later,
/// and history continue to live on the server so this
/// class does not double-write secrets anywhere.
///
/// `ICloudSync` is a fire-and-forget layer. The system
/// `NSUbiquitousKeyValueStore` does not surface success
/// or failure of a remote write, so there is no promise
/// in the API — the user just sees a "开启 iCloud 同步"
/// toggle that, when on, asks iCloud to keep these four
/// keys consistent across their devices. When off, no
/// remote calls are made.
@MainActor
final class ICloudSync: ObservableObject {
    static let shared = ICloudSync()

    /// User-facing key for the iCloud switch in settings.
    static let enableKey = "paladala.iCloudSync"

    /// Keys we mirror to iCloud. Centralised so a future
    /// "sync more" feature only has to extend this list —
    /// the rest of the call sites stay declarative.
    static let mirroredKeys: [String] = [
        "paladala.themeMode",
        "paladala.materialDesign",
        "paladala.danmakuEnabled",
        "paladala.backgroundAudio"
    ]

    /// Set to `true` when the system confirms a real
    /// iCloud account is signed in. The settings toggle
    /// in `ProfileSettingsView` reads this to decide
    /// whether to render the "Open iCloud Settings"
    /// hint vs. just sit disabled.
    ///
    /// Source of truth: `FileManager.default.ubiquityIdentityToken`.
    /// That's the canonical "user is signed in to iCloud" signal
    /// and is updated by iOS the moment the user signs in or out
    /// from system Settings (we observe the
    /// `NSUbiquityIdentityDidChange` notification). The previous
    /// implementation used `NSUbiquitousKeyValueStore.synchronize()`
    /// as the gate, which is unreliable: it can return `false`
    /// in unsigned builds, on first launch, or while the store
    /// is still warming up — even when the user is signed in.
    /// That left the iCloud toggle greyed out for users who
    /// had a working Apple ID.
    @Published private(set) var isAvailable: Bool = false

    private let store = NSUbiquitousKeyValueStore.default

    private init() {}

    /// Wire up the observers + initial sync. Call once
    /// from the app entry point (`PaladalaApp`).
    /// Idempotent — calling twice is a no-op.
    func bootstrap() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleExternalChange(_:)),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store
        )
        // Observe iCloud account changes (sign-in / sign-out from
        // system Settings). The notification is delivered on the
        // posting thread, and `ICloudSync` is `@MainActor`, so we
        // hop inside the handler.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleIdentityChange(_:)),
            name: NSNotification.Name.NSUbiquityIdentityDidChange,
            object: nil
        )
        refreshAvailability()
        // `synchronize()` is fire-and-forget; the first
        // `didChangeExternally` may arrive a few hundred ms later
        // on a real device.
        store.synchronize()
    }

    /// Recompute `isAvailable` from the current
    /// `ubiquityIdentityToken`. Safe to call repeatedly —
    /// idempotent and cheap.
    private func refreshAvailability() {
        let signedIn = FileManager.default.ubiquityIdentityToken != nil
        // Only flip the flag if it actually changed — avoids
        // spurious SwiftUI re-renders on every notification.
        if signedIn != isAvailable {
            isAvailable = signedIn
        }
    }

    @objc private func handleIdentityChange(_ note: Notification) {
        // `@objc` handlers can be invoked from arbitrary threads.
        // The `Task` body inherits this class's @MainActor isolation
        // (line 22), so the explicit `@MainActor` annotation is not
        // required; we keep it for symmetry with the brief. `[weak
        // self]` is retain discipline, not Sendable conformance.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.refreshAvailability()
            // Re-sync the store on identity change so a freshly
            // signed-in user gets the latest values from their
            // other devices ASAP.
            self.store.synchronize()
        }
    }

    /// Mirror a single key to iCloud. `value` matches
    /// the shape of `UserDefaults.object(forKey:)` so the
    /// caller can pass the result directly.
    func mirror(key: String, value: Any?) {
        guard UserDefaults.standard.bool(forKey: Self.enableKey) else { return }
        guard Self.mirroredKeys.contains(key) else { return }
        if let value {
            store.set(value, forKey: key)
        } else {
            store.removeObject(forKey: key)
        }
        // `synchronize` is fire-and-forget; the system
        // coalesces rapid writes.
        store.synchronize()
    }

    /// Read a single mirrored value, or `nil` if the
    /// user has not opted in (or the value is not
    /// present remotely).
    func read(key: String) -> Any? {
        guard UserDefaults.standard.bool(forKey: Self.enableKey) else { return nil }
        guard Self.mirroredKeys.contains(key) else { return nil }
        return store.object(forKey: key)
    }

    @objc private func handleExternalChange(_ note: Notification) {
        // The system tells us exactly which keys changed
        // remotely; map them back into standard
        // UserDefaults so the `@AppStorage` views pick
        // them up via the existing change notification.
        // We deliberately use the standard suite (not
        // the App Group suite) because these are
        // per-device preferences, not library state.
        let changedKeys = (note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]) ?? []
        for key in changedKeys where Self.mirroredKeys.contains(key) {
            if let value = store.object(forKey: key) {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }
}
