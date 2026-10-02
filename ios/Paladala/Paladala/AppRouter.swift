import Foundation
import SwiftUI

enum MainTab: String, CaseIterable, Identifiable, Codable {
    case home
    case dynamic
    case live
    case profile

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home:
            return "首頁"
        case .dynamic:
            return "動態"
        case .live:
            return "直播"
        case .profile:
            return "我的"
        }
    }

    /// SF Symbols used in the iPad sidebar (`PadRootView`). The
    /// phone tab bar still uses `tabBarItem-symbol` via
    /// `Label(... systemImage:)` so we keep `rectangle.stack` /
    /// `play.tv` for `PhoneRootView` and only customise the
    /// sidebar render through `sidebarSymbolName`.
    var symbolName: String {
        switch self {
        case .home:
            return "house"
        case .dynamic:
            return "rectangle.stack"
        case .live:
            return "play.tv"
        case .profile:
            return "person.crop.circle"
        }
    }

    /// Filled/high-contrast variants that match the new sidebar
    /// design: a solid pink house for the active 首頁 pill, a
    /// compass/scope for 動態, a radiating-wave glyph for 直播,
    /// a music-note glyph for 音樂, a stacked-rectangle glyph
    /// for 追番, and a circle-person badge for the 我的 card.
    var sidebarSymbolName: String {
        switch self {
        case .home:
            return "house.fill"
        case .dynamic:
            return "safari"
        case .live:
            return "dot.radiowaves.left.and.right"
        case .profile:
            return "person.crop.circle"
        }
    }
}

enum ProfileRoute: Hashable {
    case history
    case favorites(mid: Int64)
    /// Open a *specific* favorite folder (used by the UP
    /// profile's "收藏" tab, which lists public folders
    /// belonging to a third-party UP and jumps straight
    /// into the folder's videos). Distinct from
    /// `.favorites(mid:)` which lists the *signed-in user's*
    /// own folder collection.
    case favoriteFolder(FavoriteFolderSummary)
    case watchLater
    /// Offline downloads list. Pushed when the user taps
    /// the "离线缓存" quick action on the profile screen.
    /// No associated value — the destination view reads
    /// `DownloadStore.shared.records` directly.
    case downloads
    /// 追番 weekly timeline. Reachable from the "追番追剧"
    /// quick action on the profile screen and from any
    /// other deep-link route (a search result whose
    /// `card_goto` is `bangumi` can land here too).  The
    /// main `MainTab.bangumi` tab is a separate entry
    /// point and doesn't route through here.
    case bangumiTimeline
}

/// Local (downloaded) video playback.  The associated
/// `DownloadRecord` carries the full DASH source the proxy
/// needs to serve the on-disk bytes — no upstream network
/// call is made for this kind of playback, so the player
/// path has to know it is opening a local file before it
/// even asks the proxy to start.
enum LocalVideoRoute: Hashable {
    case local(DownloadRecord)
}

/// Live playback navigation. The associated `BiliLiveRoom` carries the
/// room identity (id/title) that `LivePlayerView` needs while it
/// resolves the playable stream URLs. We push the room — not a
/// pre-resolved `BiliLivePlayback` — because resolving the playback
/// requires a network call and the route value type should be a
/// small, cheap-to-`Hashable` snapshot.
enum LiveRoute: Hashable {
    case room(BiliLiveRoom)
}

@MainActor
final class AppRouter: ObservableObject {
    /// PR-7 (M6) used to hydrate `selectedTab` from `UserDefaults`
    /// so a force-quit + cold launch returned the user to where
    /// they were.  In practice the user-reported "app opens to
    /// the profile tab" behaviour was confusing — a fresh launch
    /// should land on the home feed, not the last tab the user
    /// happened to be on (especially since several deep-link
    /// surfaces — `paladala://music`, the profile "追番" quick
    /// action, etc. — temporarily flip `selectedTab` as part of
    /// their routing flow, so a saved `profile` value would
    /// override the intended entry point on next cold launch).
    /// The default is now always `.home`; the `didSet` is kept
    /// in case a future revision wants to read the saved tab
    /// (and to preserve forward compatibility for any in-flight
    /// save code).
    @Published var selectedTab: MainTab = .home {
        didSet {
            UserDefaults.standard.set(selectedTab.rawValue, forKey: "paladala.selectedTab")
        }
    }
    @Published var path = NavigationPath()
    @Published var pendingSearchQuery = ""
    /// Set to `true` to present the login sheet. The sheet sets it back
    /// to `false` when it dismisses itself.
    @Published var isLoginSheetPresented = false

    /// Open the 追番 weekly timeline. Switches to the
    /// 追番 tab and pushes a `BangumiRoute.timeline` onto
    /// the path so the destination renders inside the
    /// current navigation stack rather than a fresh one.
    /// No-op (besides the log) when the bangumi tab is
    /// already the selected tab.
    func openBangumiTimeline() {
        diagLog(.recommendation, "AppRouter.openBangumiTimeline")
        selectedTab = .profile
        path.append(ProfileRoute.bangumiTimeline)
    }

    func open(_ tab: MainTab) {
        // Drive the transition through `ScreenSwitchTransition.animation`
        // so the iPad `PadRootView.selectedView` and the phone
        // `TabView` crossfade / scale at the same speed and with the
        // same curve.  Setting `selectedTab` inside `withAnimation` is
        // what tells SwiftUI to interpolate the view identity change
        // rather than just swapping it.  Clearing the path keeps a
        // tap on a sidebar / tab item from re-pushing the previous
        // destination — the user lands at the root of the new tab.
        withAnimation(ScreenSwitchTransition.animation) {
            selectedTab = tab
            path.removeLast(path.count)
        }
        Haptics.selection()
    }

    func openVideo(_ video: BiliVideo) {
        IntentRecentVideoStore.record(video)
        path.append(video)
    }

    func openReplies(video: BiliVideo, root: BiliComment) {
        path.append(ReplyRoute(video: video, rootComment: root))
    }

    func open(_ route: ProfileRoute) {
        path.append(route)
    }

    /// Open the live player for `room`. Switches to the 直播 tab and
    /// pushes `LiveRoute.room(room)` onto the navigation stack so the
    /// existing `LiveRoomsView` `.navigationDestination(for:)` resolves
    /// and presents the new `LivePlayerView`.
    func openLive(_ room: BiliLiveRoom) {
        selectedTab = .live
        path.append(LiveRoute.room(room))
    }

    func openSearch(_ query: String) {
        pendingSearchQuery = query
        selectedTab = .home
        path.removeLast(path.count)
    }

    func openLogin() {
        selectedTab = .profile
        isLoginSheetPresented = true
    }

    /// Open a downloaded video for offline playback.  Switches
    /// to the home tab (so the user lands inside the same
    /// `NavigationStack` as regular videos) and pushes a
    /// `LocalVideoRoute.local(record)` onto the path.  The
    /// `RootView` resolves the route into a `VideoDetailView`
    /// whose `BiliPlayback.localContext` is set from the
    /// record.
    func openLocalVideo(_ record: DownloadRecord) {
        selectedTab = .home
        path.append(LocalVideoRoute.local(record))
    }

    /// Open a UP (content creator) public profile.  Pushes
    /// `UPProfileRoute.up(mid:)` onto the current navigation
    /// stack.  The `RootView` `navigationDestination(for:)`
    /// resolves it into `UPProfileView`, which renders the
    /// UP's card, stats, and published-videos list.  Tapping
    /// a row in that list pushes another `VideoDetailView`
    /// via the existing `BiliVideo` destination.
    func openUP(mid: Int64) {
        guard mid > 0 else { return }
        diagLog(.recommendation, "AppRouter.openUP", details: ["mid": mid])
        path.append(UPProfileRoute.up(mid: mid))
    }

    func consumePendingIntentRoute() {
        guard let route = IntentRouteStore.consumeRoute() else { return }
        switch route {
        case .tab(let tab):
            open(tab)
        case .search(let query):
            openSearch(query)
        case .video(let entity):
            selectedTab = .home
            path.removeLast(path.count)
            path.append(BiliVideo(
                bvid: entity.id,
                aid: 0,
                cid: 0,
                title: entity.title,
                ownerName: entity.ownerName,
                coverURL: nil,
                duration: 0,
                viewCount: 0,
                danmakuCount: 0,
                likeCount: 0,
                description: "",
                ownerMid: 0
            ))
        case .login:
            openLogin()
        }
    }
}
