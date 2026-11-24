#if !targetEnvironment(macCatalyst)
@preconcurrency import ActivityKit
#endif
import Foundation

#if targetEnvironment(macCatalyst)
/// Placeholder so `end(reason:)` keeps the same signature on
/// platforms without ActivityKit (Mac Catalyst has no Live
/// Activities; the coordinator's methods become no-ops).
enum ActivityUIDismissalPolicy: Sendable {
    case `default`
    case immediate
}
#endif

/// Thin lifecycle manager for the live-room Live Activity.
///
/// ActivityKit requires that `Activity.request(...)` be
/// called on the main actor and that the system has at
/// least one `ActivityConfiguration<LiveRoomActivityAttributes>`
/// declared in a WidgetKit extension. This coordinator
/// centralises the request / update / end flow so the view
/// layer (`LivePlayerView`) doesn't have to know about
/// ActivityKit's threading rules.
@MainActor
final class LiveActivityCoordinator {
    static let shared = LiveActivityCoordinator()

    #if !targetEnvironment(macCatalyst)
    private var currentActivity: Activity<LiveRoomActivityAttributes>?
    #endif

    private init() {}

    /// Returns `true` if Live Activities are usable on this
    /// device / iOS version. ActivityKit ships with iOS
    /// 16.1 but frequent updates and the system-level
    /// setting both have to be honoured, so the check is
    /// two-step.
    static var isSupported: Bool {
        #if !targetEnvironment(macCatalyst)
        if #available(iOS 16.1, *) {
            return ActivityAuthorizationInfo().areActivitiesEnabled
        }
        #endif
        return false
    }

    /// Start a Live Activity for the given live room.
    /// If a previous activity is still on screen, the
    /// stale one is ended first so the user only ever
    /// sees one LIVE pill at a time.
    func start(for room: BiliLiveRoom) {
        guard Self.isSupported else { return }
        #if !targetEnvironment(macCatalyst)
        end(reason: .immediate)
        let attributes = LiveRoomActivityAttributes(
            roomId: String(room.id),
            title: room.title,
            hostName: room.hostName,
            areaName: room.areaName
        )
        let state = LiveRoomActivityState(
            viewerCount: room.viewerCount,
            isLive: true
        )
        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
            currentActivity = activity
        } catch {
            // ActivityKit throws if the system rejects
            // the request (e.g. user disabled Live
            // Activities, low-priority device, no widget
            // extension). The diagnostic log is enough;
            // the user already has the in-app live view
            // so the feature is not degraded — the
            // banner is the only thing missing.
            bpLog("Live Activity request failed: \(error)")
        }
        #endif
    }

    /// Update the viewer count in the existing activity.
    /// A no-op when no activity is on screen so a stale
    /// `viewerCount` is never sent after `.onDisappear`.
    func update(viewerCount: Int) {
        #if !targetEnvironment(macCatalyst)
        guard #available(iOS 16.1, *), let activity = currentActivity else { return }
        let state = LiveRoomActivityState(viewerCount: viewerCount, isLive: true)
        Task {
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
        #endif
    }

    /// End the live activity. Called from the view's
    /// `.onDisappear` so the banner is dismissed the
    /// moment the user leaves the live room.
    func end(reason: ActivityUIDismissalPolicy = .default) {
        #if !targetEnvironment(macCatalyst)
        guard #available(iOS 16.1, *), let activity = currentActivity else { return }
        currentActivity = nil
        Task {
            await activity.end(activity.content, dismissalPolicy: reason)
        }
        #endif
    }
}
