#if !targetEnvironment(macCatalyst)
import ActivityKit
#endif
import Foundation

/// ActivityKit attributes for the live-room Live Activity.
///
/// This struct is intentionally minimal — every property is
/// a `String` or `Int` so `ActivityKit` can serialise it
/// across the process boundary into the widget extension
/// without a custom encoder. Any new attribute the widget
/// needs to render must be added here, and then surfaced in
/// `LiveActivityWidget` (PaladalaWidget extension).
///
/// The `ContentState` is the only field that changes during
/// the lifetime of the activity; the static fields are set
/// once at `Activity.request(_:)` time.
#if !targetEnvironment(macCatalyst)
public struct LiveRoomActivityAttributes: ActivityAttributes, Sendable {
    public typealias ContentState = LiveRoomActivityState

    /// Stable metadata captured when the live room first
    /// becomes active. The `roomId` doubles as the deep-link
    /// payload so the widget's tap action can route back
    /// into the host app and resume the same stream.
    public let roomId: String
    public let title: String
    public let hostName: String
    public let areaName: String

    public init(roomId: String, title: String, hostName: String, areaName: String) {
        self.roomId = roomId
        self.title = title
        self.hostName = hostName
        self.areaName = areaName
    }
}
#endif

/// Mutable payload pushed by the host app while the live
/// room is open. The widget extension renders `viewerCount`
/// + `isLive` from this struct; the static metadata comes
/// from `LiveRoomActivityAttributes` itself.
public struct LiveRoomActivityState: Codable, Hashable, Sendable {
    public var viewerCount: Int
    public var isLive: Bool

    public init(viewerCount: Int, isLive: Bool) {
        self.viewerCount = viewerCount
        self.isLive = isLive
    }
}
