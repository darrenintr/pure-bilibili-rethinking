import BackgroundTasks
import Foundation
import UIKit
import UserNotifications

extension BGAppRefreshTask: @unchecked Sendable {}

/// Background-driven "follow" notification pipeline.
///
/// Bilibili doesn't push notifications to *us* — the official
/// client uses a long-poll WebSocket that the iOS background
/// restrictions kill within ~30 s.  Instead we run a small
/// periodic poll via `BGAppRefreshTask` and surface a local
/// notification for each new dynamic from a followed UP.
///
/// ## Why BGAppRefreshTask (not APNs)
///
/// Apple's APNs requires a *server* that holds a device token
/// and pushes to it; B 站 will never register us as a push
/// target, so APNs is the wrong tool here.  BGAppRefreshTask
/// is the iOS-equivalent of Google Cloud Messaging's "data
/// sync" path: the OS wakes the app on a coarse schedule
/// (typically every 30-60 min when on Wi-Fi + power) and
/// gives us ~30 s to fetch + diff + post a local notification.
///
/// ## Why "feed/all + client-side filter"
///
/// `/x/polymer/web-dynamic/v1/feed/attention` (followed
/// feed) is a 404 on the upstream — the iOS code already
/// relies on `/feed/all` filtered against the user's
/// `relation/followings` set.  We reuse the same
/// `attentionFeed(...)` + `followingMids(...)` plumbing here
/// so the notification surface is consistent with the 关注
/// tab in the app.
///
/// ## Cost control
///
/// `BGAppRefreshTask` is rate-limited by the OS; we *also*
/// short-circuit when:
/// - the user is signed out (cookie missing)
/// - the user opted out via `paladala.followNotificationEnabled`
/// - the previous tick was < `minPollInterval` seconds ago
///   (defends against an OS that fires back-to-back ticks)
///
/// Plus the actual fetch is at most one HTTP round-trip —
/// no extra threads, no timers, no scroll observers.
final class FollowNotificationService: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    // PR-C Task 5: `nonisolated` so the singleton is
    // reachable from any isolation domain.  The init is
    // `nonisolated` too — `super.init()` is fine from any
    // thread, and `UNUserNotificationCenter.current()` is
    // itself thread-safe.
    nonisolated static let shared = FollowNotificationService()

    /// Background task identifier. Must match the
    /// `BGTaskSchedulerPermittedIdentifiers` entry in
    /// Info.plist or the scheduler will refuse to register it.
    static let backgroundTaskIdentifier = "com.paladala.follow-poll"

    /// Earliest re-arm interval. The OS may decide not to
    /// fire us for hours; we *also* don't want a hot-loop
    /// (the OS will throttle our background budget if we do).
    /// 30 minutes matches the BGAppRefreshTaskRequest
    /// minimumInterval recommendation.
    static let minPollInterval: TimeInterval = 30 * 60

    /// UserDefaults key for the cursor (the `id_str` of the
    /// newest dynamic we've already surfaced as a notification).
    /// Persisted across launches so the next tick after a
    /// fresh install starts at the top of the feed.
    private static let lastSeenIDKey = "paladala.followNotification.lastSeenID"

    /// UserDefaults key for the enable / disable toggle.
    private static let enabledKey = "paladala.followNotificationEnabled"

    /// UserDefaults key for the "last successful poll" timestamp.
    /// Drives the settings-page status row ("上次拉取: 2 分钟前").
    private static let lastPollAtKey = "paladala.followNotification.lastPollAt"

    /// Cached repository handle. Injected from the app on
    /// bootstrap — the service itself doesn't own the
    /// `BilibiliAPIClient` to avoid a retain cycle through
    /// `PaladalaApp`.
    private weak var repository: PaladalaRepository?
    /// Active account mid most recently supplied by the app. The
    /// poll uses this for the `attentionFeed` call's `accountMid:`
    /// parameter. `PaladalaApp` rewires it on login, account switch,
    /// and sign-out so the next background tick uses current auth.
    private var activeAccountMid: Int64 = 0
    /// Set to `true` while a `BGAppRefreshTask` is in flight
    /// so we can ignore a second OS wake that arrives before
    /// the first completes (rare but observed when the OS
    /// re-fires after a crash mid-tick).
    private var pollInFlight = false
    /// One-shot guard for the OS-level `register` call.
    /// Re-registering the same identifier aborts, so we
    /// gate the call behind this flag and let late callers
    /// (`wireRepository` from `onAppear`) skip it.
    private var didRegisterBackgroundHandler = false

    nonisolated private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    /// Register the BG task handler with the OS.  Must be
    /// called **before** `application(_:didFinishLaunching…)`
    /// returns — calling it later (e.g. from a SwiftUI
    /// `onAppear`) puts the registration outside the launch
    /// window and the scheduler aborts on iOS 26 Beta.  Also:
    /// `using:` must be a real queue, not `nil`.
    ///
    /// Idempotent: subsequent calls are no-ops. The OS
    /// refuses duplicate registrations of the same identifier
    /// with `NSInternalInconsistencyException`, so we guard
    /// the call here rather than relying on the app to call
    /// it exactly once.
    func registerBackgroundHandler() {
        guard !didRegisterBackgroundHandler else { return }
        didRegisterBackgroundHandler = true
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.backgroundTaskIdentifier,
            using: DispatchQueue.global(qos: .utility)
        ) { [weak self] task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self?.handle(refreshTask: refresh)
        }
    }

    /// Wire the repository + active account.  Called from the
    /// app's `onAppear` (or whenever the active account
    /// changes).  The BG task handler resolves the repository
    /// lazily on every wake, so it's safe to call this after
    /// `registerBackgroundHandler` and to call it again later
    /// with a different account.
    func wireRepository(_ repository: PaladalaRepository, accountMid: Int64) {
        self.repository = repository
        self.activeAccountMid = accountMid
    }

    // MARK: permission + scheduling

    /// Request permission for the `alert` + `sound` + `badge`
    /// notifications. Idempotent — calling it again after the
    /// user has already decided is a no-op.
    func requestAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            _ = try? await center.requestAuthorization(
                options: [.alert, .sound, .badge]
            )
        default:
            break  // already decided
        }
    }

    /// Re-arm the background task. Called from:
    ///  - bootstrap (so a future wake fires the task)
    ///  - the completion handler of the previous tick
    ///
    /// Always schedules `minPollInterval` out — the OS may
    /// choose not to fire us at all when the device is in
    /// low-power mode or on cellular data.
    func scheduleNextPoll() {
        let request = BGAppRefreshTaskRequest(
            identifier: Self.backgroundTaskIdentifier
        )
        request.earliestBeginDate = Date(
            timeIntervalSinceNow: Self.minPollInterval
        )
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Submission failure usually means the user
            // disabled Background App Refresh in Settings.
            // Surface to the diagnostic log so the next
            // diagnostic report makes the failure mode
            // obvious; don't crash — the feature is opt-in.
            diagLog(.notification,
                    "BGAppRefresh submit failed",
                    details: ["error": error.localizedDescription])
        }
    }

    // MARK: BGAppRefreshTask handler

    private func handle(refreshTask: BGAppRefreshTask) {
        // The OS only gives us ~30 s; expire the task
        // explicitly so a slow network call doesn't burn
        // the entire budget. 30 s is the documented
        // BGAppRefreshTask limit.
        //
        // PR-C Task 3: the original implementation used a
        // `DispatchWorkItem` scheduled via
        // `DispatchQueue.main.asyncAfter`. Task.sleep is
        // cancellable, so we hold a handle to the Task and
        // cancel it from `expirationHandler` and from the
        // `runPoll` defer block — preserving the same
        // cancellation contract the work item had.
        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            if Task.isCancelled { return }
            refreshTask.setTaskCompleted(success: false)
        }

        refreshTask.expirationHandler = { [weak self] in
            timeoutTask.cancel()
            self?.pollInFlight = false
            refreshTask.setTaskCompleted(success: false)
        }

        Task { [weak self] in
            await self?.runPoll(refreshTask: refreshTask, timeoutTask: timeoutTask)
        }
    }

    @MainActor
    private func runPoll(
        refreshTask: BGAppRefreshTask,
        // PR-C Task 3: timeout is now a cancellable `Task`
        // (see `handle(refreshTask:)`) so the type changed
        // from `DispatchWorkItem` to `Task<Void, Never>`. The
        // cancellation contract is identical — `.cancel()`
        // stops the body before it touches `refreshTask`.
        timeoutTask: Task<Void, Never>
    ) async {
        defer {
            timeoutTask.cancel()
            pollInFlight = false
            scheduleNextPoll()
        }
        pollInFlight = true

        guard isEnabled else {
            diagLog(.notification, "follow poll skipped: disabled by user")
            refreshTask.setTaskCompleted(success: true)
            return
        }
        guard let repository else {
            diagLog(.notification, "follow poll skipped: no repository")
            refreshTask.setTaskCompleted(success: false)
            return
        }
        guard await repository.apiClient.hasAuthenticatedSession() else {
            diagLog(.notification, "follow poll skipped: anonymous")
            refreshTask.setTaskCompleted(success: true)
            return
        }

        do {
            try await poll(repository: repository)
            refreshTask.setTaskCompleted(success: true)
        } catch {
            diagLog(.notification, "follow poll failed",
                    details: ["error": error.localizedDescription])
            refreshTask.setTaskCompleted(success: false)
        }
    }

    // MARK: the actual fetch + diff

    /// Run the follow-feed poll. Visible to the rest of the
    /// app so the settings-page "拉取一次" button can call
    /// it directly without waiting for the OS scheduler.
    @discardableResult
    func poll(repository: PaladalaRepository) async throws -> Int {
        // Fetch the first page of the attention (follow-filtered)
        // dynamic feed. The repository caches the followings set
        // internally on first call and refreshes it when the
        // account changes — we don't need to manage that here.
        let defaults = UserDefaults.standard
        let lastSeen = defaults.string(forKey: Self.lastSeenIDKey) ?? ""
        guard activeAccountMid > 0 else {
            diagLog(.notification, "follow poll skipped: no active account mid")
            return 0
        }

        let page = try await repository.attentionFeed(
            offset: "",
            accountMid: activeAccountMid,
            refreshFollowings: true
        )
        // Drop items that don't carry a fresh ID we can use as
        // a cursor (legacy cards the upstream didn't fill) and
        // take just the top of the list — even though B 站's
        // dynamic id is monotonic, we don't want to fan out a
        // hundred notifications on the first poll after install.
        let fresh = page.items.compactMap { item -> (String, String, String)? in
            guard !item.id.isEmpty else { return nil }
            // `DynamicPost` has no top-level `title` — the visible
            // headline is the `text` body, or the attached video's
            // title when the post is a video card. Use whichever
            // the upstream populated; fall back to "新动态".
            let raw = item.attachedVideo?.title ?? item.text
            let title = raw.isEmpty ? "新動態" : raw
            return (item.id, title, item.author)
        }.prefix(5)

        var newestID = lastSeen
        var delivered = 0
        for (id, title, author) in fresh {
            // Skip items the user has already seen — the
            // `lastSeenID` is the *newest* we've delivered,
            // so any older id can be short-circuited.
            if !lastSeen.isEmpty && id <= lastSeen { continue }
            await postLocalNotification(id: id, title: title, author: author)
            delivered += 1
            if id > newestID { newestID = id }
        }
        if !newestID.isEmpty, newestID != lastSeen {
            defaults.set(newestID, forKey: Self.lastSeenIDKey)
        }
        defaults.set(Date(), forKey: Self.lastPollAtKey)
        diagLog(.notification, "follow poll complete",
                details: [
                    "followings": page.items.count,
                    "fresh": fresh.count,
                    "delivered": delivered,
                    "newCursor": newestID.isEmpty ? "<none>" : newestID
                ])
        return delivered
    }

    /// Post a single local notification. Bypasses the
    /// foreground presentation (`.banner` + `.list`) so the
    /// notification shows while the device is locked and
    /// while the app is backgrounded; tapping it deep-links
    /// to the dynamic feed via the `userInfo` payload.
    private func postLocalNotification(
        id: String, title: String, author: String
    ) async {
        let content = UNMutableNotificationContent()
        content.title = author.isEmpty ? "關注的 UP 主有新動態" : "\(author) 釋出了新內容"
        content.body = title
        content.sound = .default
        content.threadIdentifier = "paladala.follow"
        content.userInfo = [
            "kind": "follow_dynamic",
            "dynamicID": id
        ]
        // 1-second trigger — we want it now, not in the future.
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: 1, repeats: false
        )
        let request = UNNotificationRequest(
            identifier: "paladala.follow.\(id)",
            content: content,
            trigger: trigger
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    // MARK: public API for the settings toggle

    /// True when the user has opted into follow notifications.
    /// Defaults to `false` — the user has to explicitly flip
    /// the settings toggle before the BG task fires.
    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    func setEnabled(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: Self.enabledKey)
        if value {
            // Re-arm immediately so the user doesn't have to
            // wait `minPollInterval` for the next wake.
            scheduleNextPoll()
            Task { await requestAuthorizationIfNeeded() }
        } else {
            BGTaskScheduler.shared.cancel(
                taskRequestWithIdentifier: Self.backgroundTaskIdentifier
            )
            // Also drop any already-pending local notifications
            // so disabling the feature clears the notification
            // center immediately.
            UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        }
    }

    /// Resets the cursor to "0" so the next poll re-delivers
    /// the latest dynamic. Useful for the "重新拉取" button
    /// in the settings page.
    func resetCursor() {
        UserDefaults.standard.removeObject(forKey: Self.lastSeenIDKey)
    }

    /// Timestamp of the last successful poll (or `nil` if we
    /// haven't run yet). Drives the settings-page status row.
    var lastPollAt: Date? {
        UserDefaults.standard.object(forKey: Self.lastPollAtKey) as? Date
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Show notifications even when the app is in the
    /// foreground — otherwise the user gets no in-app
    /// banner and wonders why nothing happened.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound, .badge])
    }

    /// Tap on a follow-notification — hand the deep-link
    /// off to the router so the user lands on the dynamic
    /// feed for the originating UP.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        if let dynamicID = info["dynamicID"] as? String {
            diagLog(.notification, "follow notification tapped",
                    details: ["dynamicID": dynamicID])
            // Routing to the dynamic tab is handled by the
            // existing `AppRouter.openDynamic(...)`; we just
            // post a notification so the SwiftUI side can
            // react without coupling `UNUserNotificationCenter`
            // to `AppRouter` directly.
            NotificationCenter.default.post(
                name: .followNotificationTapped,
                object: nil,
                userInfo: ["dynamicID": dynamicID]
            )
        }
        completionHandler()
    }
}

extension Notification.Name {
    /// Posted when the user taps a follow-notification.
    /// `userInfo["dynamicID"]` carries the upstream
    /// `DynamicPost.id`. The home view listens and
    /// switches the home tab to the 关注 sub-tab.
    static let followNotificationTapped = Notification.Name(
        "paladala.followNotification.tapped"
    )
}
