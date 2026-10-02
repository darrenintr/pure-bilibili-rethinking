import ActivityKit
import SwiftUI
import WidgetKit

/// Live Activity widget for an in-progress live room.
///
/// `ActivityConfiguration<LiveRoomActivityAttributes>` is
/// the standard pattern for a Live Activity: the lock-screen
/// / Dynamic Island views are declared here in the widget
/// extension process so the host app can stay in the
/// background while the activity is updating.
struct LiveActivityWidget: Widget {
    private let signalPink = Color(red: 1, green: 0.38, blue: 0.58)

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LiveRoomActivityAttributes.self) { context in
            // Lock-screen / banner UI. Kept deliberately
            // small so the activity budget isn't blown on
            // the first render — every visible element is
            // either static metadata from the attributes
            // or one piece of mutable state from the
            // ContentState.
            LockScreenLiveActivityView(
                attributes: context.attributes,
                state: context.state
            )
            .padding(12)
            .activityBackgroundTint(Color.black)
            .activitySystemActionForegroundColor(Color.white)
        } dynamicIsland: { context in
            // Dynamic Island — leading + trailing + centre
            // compact presentations, plus a single expanded
            // layout. Apple recommends presenting at most
            // one widget per region so a live counter next
            // to a static title stays glanceable.
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .foregroundStyle(signalPink)
                        .font(.title3)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(context.state.viewerCount)")
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(.white)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.title)
                        .font(.headline)
                        .lineLimit(1)
                        .foregroundStyle(.white)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 4) {
                        Text(context.attributes.hostName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(context.attributes.areaName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Link(destination: liveDeepLink(roomId: context.attributes.roomId)) {
                            Image(systemName: "play.fill")
                                .font(.title3)
                                .foregroundStyle(.white)
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .foregroundStyle(signalPink)
            } compactTrailing: {
                Text(context.state.viewerCount.compactCount)
                    .font(.caption.monospacedDigit())
            } minimal: {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .foregroundStyle(signalPink)
            }
        }
    }

    private func liveDeepLink(roomId: String) -> URL {
        // The host app's URL scheme is `paladala://` (see
        // Info.plist CFBundleURLTypes). Tapping the widget
        // icon routes through `AppRouter` which already
        // understands `paladala://live?roomId=...`.
        URL(string: "paladala://live?roomId=\(roomId)") ?? URL(string: "paladala://live")!
    }
}

private struct LockScreenLiveActivityView: View {
    let attributes: LiveRoomActivityAttributes
    let state: LiveRoomActivityState
    private let signalPink = Color(red: 1, green: 0.38, blue: 0.58)

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            // LIVE pill — the only chrome element so the
            // user can tell at a glance that the activity
            // is a live broadcast, not a regular playback
            // notification.
            HStack(spacing: 4) {
                Rectangle()
                    .fill(Color.black)
                    .frame(width: 6, height: 6)
                Text("LIVE")
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(signalPink)
            .overlay {
                Rectangle().strokeBorder(.white, lineWidth: 1)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(attributes.title)
                    .font(.headline)
                    .lineLimit(1)
                    .foregroundStyle(.white)
                Text(attributes.hostName)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
            Spacer()
            Text(state.viewerCount.compactCount)
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white)
            Link(destination: URL(string: "paladala://live?roomId=\(attributes.roomId)")!) {
                Image(systemName: "play.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
            }
        }
    }
}

private extension Int {
    /// Mirrors the count formatter used by the in-app
    /// live-room metadata panel so the widget and the
    /// app surface the same "1.2 万" / "3.4 万" style.
    var compactCount: String {
        let absValue = abs(self)
        if absValue >= 10_000 {
            let wan = Double(self) / 10_000.0
            return String(format: "%.1f 萬", wan)
        }
        return String(self)
    }
}
