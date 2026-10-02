import Combine
import Foundation

@MainActor
final class HomeViewModel: ObservableObject {
    @Published var category: HomeCategory = .recommend
    @Published var popularSubCategory: PopularSubCategory = .comprehensive
    @Published var searchQuery = ""
    @Published var videos: [BiliVideo] = []
    @Published var searchUsers: [BiliUserSearchResult] = []
    /// Keystroke-rate search suggestions. Surfaced by the
    /// home view via `.searchSuggestions(_:)` so the
    /// `.searchable` modifier can show them inline as the
    /// user types. Empty while the user isn't actively
    /// typing in the search field.
    ///
    /// `suggestionsInFlight` is bumped every time we kick
    /// off a suggest call so older in-flight requests can
    /// short-circuit when the user types another character
    /// before the previous response arrives — without it
    /// the user sees the suggestions for an older term
    /// flash in after a newer one is rendered.
    @Published var searchSuggestions: [BiliSearchSuggestion] = []
    /// True while a suggest call is pending. Lets the
    /// view render a subtle "loading" affordance without
    /// taking over the keyboard.
    @Published var suggestionsInFlight = false
    /// Set when a "全部" search (the merged five-slot
    /// `searchAll(...)` call) is pending or has finished.
    /// Used to render a top progress strip while the
    /// combined search result page populates.
    @Published var allSearchResults: BiliAllSearchResults?
    @Published var allSearchInFlight = false
    @Published var liveRooms: [BiliLiveRoom] = []
    /// Dynamic feed rendered on the 关注 tab. Lives in parallel to
    /// `videos` / `liveRooms` because the upstream envelope is a
    /// different shape (`offset` + `items[]`, not `page` + `videos[]`).
    /// `dynamicNeedsLogin` distinguishes the "signed-out, please log in"
    /// empty state from a legitimate empty page (a user with no
    /// follows yet).
    @Published var dynamicItems: [DynamicPost] = []
    @Published var dynamicHasMore = false
    @Published var dynamicNextOffset = ""
    @Published var dynamicNeedsLogin = false
    @Published var isLoading = false
    @Published var isLoadingMore = false
    @Published var hasMore = true
    @Published var errorMessage: String?
    /// True when the feed is showing the offline bundled sample set. We
    /// expose this so the home view can render an "离线样例" caption and
    /// so the pagination footer can offer a "重新加载" action.
    @Published var isShowingBundledFallback = false
    /// Flips `false → true` the first time the home feed paints
    /// with real videos, so the staggered fan-in animation in
    /// `HomeView` only runs once per session and only on the
    /// *initial* load (not on category switches or
    /// refreshes). The view reads this with `.animation(_,
    /// value:)` so re-flipping is a no-op once the cards are
    /// already on screen.
    @Published var firstPageAnimated = false
    /// PR-A Task 9: gates the .task bootstrap block. Set to true
    /// after the first seedFromCache(...) call (cache hit) OR
    /// after the surrounding .task block completes its load — see
    /// HomeView.task. Persists across tab switches via SwiftUI's
    /// @StateObject identity, so the seed runs at most once per
    /// view-model lifetime (re-appearance is a no-op; pull-to-refresh
    /// is the manual path).
    @Published private(set) var didBootstrap = false

    private var page = 1
    private var requestGeneration: UInt64 = 0
    private var recommendFreshIndex = 0

    /// PR-A Task 9: paint the first frame from the on-disk feed
    /// snapshot if one is present. Sets `didBootstrap = true` so
    /// the .task block does not attempt to re-seed on re-appearance.
    /// Caller is expected to gate this on `!didBootstrap`.
    func seedFromCache(_ cards: [BiliVideo]) {
        self.videos = cards
        self.didBootstrap = true
    }

    /// PR-A Task 9: separate from `seedFromCache(_:)` so the .task
    /// block can mark the bootstrap complete even when the cache
    /// missed (otherwise a cache miss would re-run the seed + load
    /// on every view re-appearance). The setter on `didBootstrap`
    /// stays private; this is the only legitimate outside path.
    func markBootstrapped() {
        didBootstrap = true
    }
    /// The maximum number of items the upstream endpoint will return in one
    /// request. Once we get fewer than this many results we know we are at
    /// the end of the feed.
    private let pageSize = 20

    func load(
        repository: PaladalaRepository,
        accountMid: Int64 = 0,
        preservingExistingContent: Bool = false
    ) async {
        let requestID = beginNewRequestGeneration()
        page = 1
        // A disk-seeded first frame should remain visible while the live
        // refresh runs. Clearing it here made the cache flash for one frame
        // and then replaced it with a full-screen spinner, negating the cold
        // start optimization. Category/search changes keep the old clearing
        // behavior by using the default `false` value.
        if !preservingExistingContent {
            videos = []
        }
        searchUsers = []
        liveRooms = []
        // Reset dynamic-feed state on every fresh load so switching
        // tabs or tapping the home indicator doesn't leave a stale
        // "登录后查看关注动态" message on screen after the user signs in.
        dynamicItems = []
        dynamicHasMore = false
        dynamicNextOffset = ""
        dynamicNeedsLogin = false
        isLoading = true
        isLoadingMore = false
        hasMore = true
        errorMessage = nil
        // Always clear the bundled-fallback flag on a fresh load. Otherwise
        // a previous tap on "查看离线样例" would keep `isShowingBundledFallback`
        // = true even after the live API returns, and the user would see
        // the bundled list for a beat before the new data overwrites it.
        isShowingBundledFallback = false
        await loadPage(repository: repository, accountMid: accountMid, replacing: true, requestID: requestID)
        guard isCurrentRequest(requestID) else { return }
        isLoading = false
        // Trigger the one-shot fan-in animation in `HomeView` only
        // when this is the first successful load of the session
        // (skip refreshes / category switches). The `!isShowingBundledFallback`
        // guard avoids animating a fan-in over the offline sample.
        if !firstPageAnimated, !videos.isEmpty, !isShowingBundledFallback {
            firstPageAnimated = true
        }
    }

    func loadMore(repository: PaladalaRepository, accountMid: Int64 = 0) async {
        guard !isLoading, !isLoadingMore else { return }
        // Follow tab uses the dynamic-feed pagination (`offset`), not
        // the page-based one. Route it through its own branch so the
        // `categorySupportsPagination` short-circuit below stays
        // accurate for the video feeds.
        if category == .follow {
            guard dynamicHasMore, !dynamicNextOffset.isEmpty else { return }
            isLoadingMore = true
            let requestID = requestGeneration
            await loadDynamicPage(repository: repository, accountMid: accountMid, replacing: false, requestID: requestID)
            guard isCurrentRequest(requestID) else { return }
            isLoadingMore = false
            return
        }
        guard hasMore, category != .live else { return }
        // Some feed flavours always return the full list in a single response
        // (e.g. weekly/precious). Skip pagination for them so we do not
        // request the same page twice in a row.
        guard categorySupportsPagination else { return }
        isLoadingMore = true
        page += 1
        let requestID = requestGeneration
        await loadPage(repository: repository, accountMid: accountMid, replacing: false, requestID: requestID)
        guard isCurrentRequest(requestID) else { return }
        isLoadingMore = false
    }

    /// "Next batch" action. The user has reached the bottom of the feed and
    /// tapped the footer button — we always increment the page and try
    /// again, even when the previous response was short. The Bilibili
    /// `popular` endpoint sometimes returns a 12-item page followed by
    /// another full 20-item page, so giving up on a short response is
    /// wrong. When even the retry returns nothing we drop into the
    /// bundled fallback so the user always has somewhere to scroll.
    func loadNextBatch(repository: PaladalaRepository, accountMid: Int64 = 0) async {
        guard !isLoading, !isLoadingMore else { return }
        guard category != .follow, category != .live else { return }
        isLoadingMore = true
        page += 1
        let requestID = requestGeneration
        await loadPage(repository: repository, accountMid: accountMid, replacing: false, requestID: requestID)
        guard isCurrentRequest(requestID) else { return }
        isLoadingMore = false
    }

    /// Explicit offline-mode toggle. The user has tapped the "查看离线样例"
    /// button on the error banner and wants to see the bundled sample set
    /// until the public endpoint comes back. Pull-to-refresh still goes
    /// through `load(...)` and re-tries the live API.
    func showBundledFallback(repository: PaladalaRepository) {
        errorMessage = nil
        videos = repository.bundledFeed(for: category)
        isShowingBundledFallback = true
        hasMore = true
    }

    private var categorySupportsPagination: Bool {
        switch category {
        case .recommend, .search:
            return true
        case .popular:
            return popularSubCategory == .comprehensive
        case .anime, .game, .knowledge, .tech:
            return true
        case .follow, .live:
            return false
        }
    }

    func applyIntentSearch(_ query: String, repository: PaladalaRepository, accountMid: Int64 = 0) async {
        guard !query.isEmpty else { return }
        category = .search
        searchQuery = query
        await load(repository: repository, accountMid: accountMid)
    }

    private func loadPage(
        repository: PaladalaRepository,
        accountMid: Int64,
        replacing: Bool,
        requestID: UInt64
    ) async {
        do {
            if category == .follow {
                await loadDynamicPage(repository: repository, accountMid: accountMid, replacing: replacing, requestID: requestID)
                return
            } else if category == .live {
                let rooms = try await repository.liveRooms()
                guard isCurrentRequest(requestID) else { return }
                liveRooms = rooms
                videos = []
                hasMore = false
                isShowingBundledFallback = false
            } else {
                if category == .search && replacing {
                    searchUsers = (try? await repository.searchUsers(keyword: searchQuery)) ?? []
                } else if category != .search {
                    searchUsers = []
                }
                let next = try await repository.feed(
                    category: category,
                    searchQuery: searchQuery,
                    popularSubCategory: popularSubCategory,
                    page: page,
                    recommendFreshIndex: category == .recommend ? recommendFreshIndex : 0,
                    isRefresh: replacing
                )
                guard isCurrentRequest(requestID) else { return }
                if category == .recommend {
                    recommendFreshIndex += 1
                }
                if replacing {
                    videos = next
                    // **Build 250 fix**: write the seed snapshot
                    // for the recommend feed so the *next* cold
                    // start can paint the first frame from disk
                    // instead of waiting on a full network round
                    // trip.  See `FeedCacheWarmer.write` for the
                    // atomic-rename guarantee.
                    if category == .recommend, !next.isEmpty {
                        FeedCacheWarmer.shared.write(cards: next, key: "home")
                    }
                } else {
                    // Dedupe appended items by `bvid` so a "load next batch"
                    // gesture on a wrapped-around feed does not double up
                    // the same video twice in a row.
                    let existing = Set(videos.map(\.bvid))
                    let fresh = next.filter { !existing.contains($0.bvid) }
                    videos.append(contentsOf: fresh)
                }
                liveRooms = []
                // The repository is responsible for telling us when the
                // response came from the bundled offline sample set. When
                // it has, we keep `hasMore = true` so the footer surfaces
                // the "重新加载" / "换一批" action instead of a phantom next
                // page. Otherwise `hasMore` follows the pageSize heuristic
                // so we know whether to keep paginating.
                let fromBundled = page == 1 && next.allSatisfy { video in
                    BundledFeedService.knownBVids.contains(video.bvid)
                }
                isShowingBundledFallback = fromBundled
                
                // App API usually returns ~10 items. Web API returns 20.
                let threshold = category == .recommend ? 8 : pageSize
                hasMore = fromBundled
                    ? true
                    : categorySupportsPagination && next.count >= threshold
            }
        } catch {
            guard isCurrentRequest(requestID) else { return }
            guard !AppErrorDescriptor.isCancellation(error) else { return }

            let fallback = replacing
                ? "內容載入失敗，下拉重試。"
                : "載入更多失敗，請重試。"
            let descriptor = AppErrorCenter.shared.record(
                error,
                context: "home.\(category.rawValue).\(replacing ? "refresh" : "pagination")",
                fallbackMessage: fallback
            )

            if replacing {
                // Keep a cache-seeded feed usable when its background refresh
                // fails. Empty-state loads still render the normal error UI.
                if videos.isEmpty {
                    liveRooms = []
                    isShowingBundledFallback = false
                    errorMessage = descriptor?.message ?? fallback
                }
            } else {
                // Roll back the page bump so the next pull-to-refresh does not
                // skip the page we failed to load.
                page = max(1, page - 1)
                errorMessage = descriptor?.message ?? fallback
            }
        }
    }

    private func beginNewRequestGeneration() -> UInt64 {
        requestGeneration &+= 1
        return requestGeneration
    }

    /// Fetch a page of the follow dynamic feed. The upstream
    /// pagination model is `offset`, not `page`, so this is its own
    /// branch rather than a parameter on `loadPage(...)`.
    ///
    /// On anonymous access the API client short-circuits and returns
    /// an empty page with `needsLogin: true`. We surface that as a
    /// typed state on the model so the view can render the existing
    /// "登录后查看关注动态" prompt without a try/catch in the view.
    private func loadDynamicPage(
        repository: PaladalaRepository,
        accountMid: Int64,
        replacing: Bool,
        requestID: UInt64
    ) async {
        let offset = replacing ? "" : dynamicNextOffset
        do {
            // `replacing == true` (i.e. a fresh load) invalidates the
            // cached followings so a pull-to-refresh always picks up
            // newly-followed UP masters. Pagination calls leave the
            // cache alone so we don't re-fetch the followings list
            // mid-scroll.
            let page = try await repository.attentionFeed(
                offset: offset,
                accountMid: accountMid,
                refreshFollowings: replacing
            )
            guard isCurrentRequest(requestID) else { return }
            if replacing {
                dynamicItems = page.items
            } else {
                // Dedupe by post id so a wrapped-around offset does
                // not double-up a card we have already rendered. Same
                // shape as the video-feed dedupe in `loadPage`.
                let existing = Set(dynamicItems.map(\.id))
                dynamicItems.append(contentsOf: page.items.filter { !existing.contains($0.id) })
            }
            dynamicNextOffset = page.nextOffset
            dynamicHasMore = page.hasMore && !dynamicNextOffset.isEmpty
            dynamicNeedsLogin = page.needsLogin
            errorMessage = nil
            hasMore = dynamicHasMore
        } catch {
            guard isCurrentRequest(requestID) else { return }
            guard !AppErrorDescriptor.isCancellation(error) else { return }
            let fallback = replacing
                ? "關注動態載入失敗，下拉重試。"
                : "載入更多關注動態失敗，請重試。"
            let descriptor = AppErrorCenter.shared.record(
                error,
                context: "home.follow.\(replacing ? "refresh" : "pagination")",
                fallbackMessage: fallback
            )
            if replacing {
                dynamicItems = []
                dynamicHasMore = false
                dynamicNextOffset = ""
                dynamicNeedsLogin = false
            }
            errorMessage = descriptor?.message ?? fallback
        }
    }

    private func isCurrentRequest(_ requestID: UInt64) -> Bool {
        requestID == requestGeneration
    }

    // MARK: instant search

    /// Generation counter for the keystroke-rate suggest
    /// pipeline. Bumped every time `searchQuery` flips so
    /// in-flight suggest calls for an older term can
    /// short-circuit when their response arrives (the user
    /// already moved on).
    private var suggestGeneration: UInt64 = 0
    /// Handle to the currently-running suggest debounce
    /// task. Cancelled on every new keystroke so only the
    /// most recent one ever fires the network call.
    private var suggestDebounceTask: Task<Void, Never>?

    /// Debounced keystroke handler for the home search field.
    /// Cancels any pending suggest debounce when called again,
    /// then schedules a new one 120 ms out.  The 120 ms value
    /// matches the probe-verified latency floor for the
    /// `s.search.bilibili.com/main/suggest` endpoint (~100 ms
    /// median) — long enough that a fast typist only fires
    /// once or twice, short enough that the suggestions feel
    /// instant.
    func searchQueryChanged(_ query: String, repository: PaladalaRepository) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // Empty query — clear suggestions immediately.
            suggestDebounceTask?.cancel()
            suggestDebounceTask = nil
            searchSuggestions = []
            suggestionsInFlight = false
            return
        }
        suggestDebounceTask?.cancel()
        let generation = suggestGeneration
        suggestDebounceTask = Task { [weak self] in
            // 120 ms debounce — picked against the ~100 ms
            // median round-trip the probe measured; the
            // debounce equals the round-trip so a fast typist
            // sees suggestions for the *previous* term, not
            // every intermediate one.
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            await self?.runSuggest(term: trimmed, generation: generation, repository: repository)
        }
    }

    /// Internal: actually fire the suggest call, but only
    /// commit the result if no newer keystroke bumped
    /// `suggestGeneration` in the meantime.
    private func runSuggest(term: String, generation: UInt64, repository: PaladalaRepository) async {
        suggestionsInFlight = true
        defer { suggestionsInFlight = false }
        do {
            let suggestions = try await repository.searchSuggestions(for: term)
            // Drop the result if a newer keystroke has fired.
            guard generation == suggestGeneration else { return }
            searchSuggestions = suggestions
        } catch {
            // Silent — failed suggest calls just leave the
            // suggestion strip empty so the keyboard flow is
            // never blocked by an upstream hiccup.
            guard generation == suggestGeneration else { return }
            searchSuggestions = []
        }
    }

    /// Cancel any in-flight suggest debounce and clear
    /// suggestions. Called from `.searchable` when the user
    /// dismisses the search field or submits the query.
    func clearSuggestions() {
        suggestDebounceTask?.cancel()
        suggestDebounceTask = nil
        searchSuggestions = []
        suggestionsInFlight = false
    }

    /// "全部" search — runs all five type slots in parallel
    /// via the repository's pass-through.  Populates
    /// `allSearchResults` so the search result view can
    /// render the merged "全部 / 视频 / UP 主 / 番剧 / 直播
    /// / 专栏" sections in a single scroll view.
    func runAllSearch(repository: PaladalaRepository) async {
        let keyword = searchQuery
        guard !keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            allSearchResults = nil
            return
        }
        allSearchInFlight = true
        defer { allSearchInFlight = false }
        do {
            allSearchResults = try await repository.searchAll(keyword: keyword, page: 1)
        } catch {
            allSearchResults = nil
        }
    }
}

@MainActor
final class VideoDetailViewModel: ObservableObject {
    @Published var detail: BiliVideo
    @Published var playback: BiliPlayback?
    @Published var isPlaying: Bool = true
    @Published var isLoading = false
    @Published var errorMessage: String?
    /// Set when the playurl refetch returns a 大会员
    /// business code (`-40103` expired, `-62002` / `-62004` /
    /// `-62012` not-VIP / paywall). The view observes this
    /// via `onChange` and raises the upgrade sheet so the user
    /// lands on the "去开通/续费" path with one tap. Cleared
    /// after the view presents the alert (so a subsequent
    /// quality pick that fails the same way re-presents).
    ///
    /// `nil` outside the alert window; the view never reads
    /// this from a normal `setPreferredQn` success path.
    @Published var vipUpgradeReason: VipUpgradeReason?
    @Published var comments: [BiliComment] = []
    @Published var commentsLoading = false
    @Published var commentsLoadingMore = false
    @Published var commentsErrorMessage: String?
    @Published var commentsHasMore = false
    @Published var commentsTotalCount = 0
    /// YouTube-style "next up" rail. Populated once per
    /// `bvid` from `/x/web-interface/archive/related`. Empty
    /// when the upstream returns nothing or the request
    /// fails — the view hides the rail in that case rather
    /// than surfacing an error.
    @Published var relatedVideos: [BiliVideo] = []
    /// The index in `relatedVideos` of the video the auto-play
    /// queue is currently advancing toward. `nil` when auto-
    /// play is off or the queue is empty. Increments as each
    /// next-up finishes; `consumeNextUp()` returns the entry
    /// and bumps the index.
    @Published var nextUpIndex: Int? = nil
    /// Current comment-list sort. Default `.hot` to match the previous
    /// behaviour (no `mode` parameter, the upstream default). The view
    /// writes through to this and to `@AppStorage` when the user
    /// toggles the segmented picker.
    @Published var commentSort: CommentSort = .hot
    @Published var danmakuEnabled = true
    @Published var subtitleEnabled = true
    @Published var playbackSpeed: Float = 1
    /// User's preferred playback quality. Maps to Bilibili's
    /// `accept_quality` ladder: 80 = 1080P high quality, 64 =
    /// 720P high quality, 32 = 480P clear, 16 = 360P smooth.
    /// Default 80 keeps the previous "ask for HD first"
    /// behaviour. The toolbar menu in `VideoDetailView` writes
    /// through to this on tap; `setPreferredQn(_:repository:)`
    /// refetches the playurl with the new ladder entry as the
    /// preferred slot.
    @Published var preferredQn: Int = 80
    /// User's preferred audio quality. Maps to Bilibili's
    /// `dash.audio[].id` ladder: 30216 = 64 kbps (low),
    /// 30232 = 128 kbps (standard), 30250 = 320 kbps (Hi-Res,
    /// gated behind 大会员), 30280 = 192 kbps Dolby (also
    /// gated). Default 30232 — universally available without
    /// VIP, matches the web player's fallback. The toolbar
    /// menu in `VideoDetailView` writes through to this on
    /// tap; `setPreferredAudioQuality(_:repository:)` refetches
    /// the playurl with the new audio track id preferred.
    @Published var preferredAudioQuality: Int = BiliAudioQuality.defaultID
    /// Current download state for this video.  Mirrors
    /// `DownloadStore.records` and `DownloadManager.stateByBvid`
    /// for `self.detail.bvid` — the view subscribes via
    /// `$downloadState` to redraw the control-panel button
    /// when the user starts, completes, or fails a download.
    @Published var downloadState: VideoDownloadState = .notDownloaded
    /// How many B-coins (硬币) the user has given this video.
    /// Bilibili allows 0 / 1 / 2 per video; we start at 0 (the
    /// upstream default is "not yet coined").  Used by the control
    /// bar's 投币 button to render the active state (filled
    /// glyph + count chip) and to short-circuit duplicate
    /// submissions (the upstream `coin/add` endpoint would
    /// otherwise return -11002 投币上限 for the second attempt).
    @Published var coinGiven: Int = 0
    /// `true` while a `coin/add` request is in flight so the
    /// 投币 button can show a brief spinner / dim the icon.
    @Published var coinInFlight = false
    /// Surface a transient toast-style banner under the action
    /// bar when a coin succeeds or fails.  Cleared by the view
    /// after ~1.6 s via `Task.sleep`.  Mirrors the same
    /// pattern `onDownloadTap` uses through `downloadState`
    /// but for a side-effect the upstream returns silently.
    @Published var coinToast: String?
    /// Bilibili's official "AI 视频总结" for this video, if one
    /// exists. `nil` means either (a) we haven't fetched yet,
    /// (b) the upstream returned no summary for this video, or
    /// (c) the request failed. The view collapses (b) and (c)
    /// into "no section" via `aiSummaryUnavailable` — we
    /// distinguish them so the view can show a one-frame
    /// shimmer during (a) without flickering on subsequent
    /// failures.
    @Published var aiSummary: BiliAISummary?
    @Published var aiSummaryLoading = false
    /// Timed subtitle track for the active video, loaded from
    /// `/x/player/v2` when the upstream publishes one.
    @Published var subtitleTrack: BiliLyricTrack?
    /// Historical danmaku loaded from `comment.bilibili.com/{cid}.xml`.
    /// Kept sorted by time so the overlay can cheaply scan the small window
    /// around the current playhead.
    @Published var danmakuItems: [BiliDanmakuItem] = []
    /// User-controlled expand/collapse state. Defaults to
    /// collapsed so the section does not steal vertical space
    /// from the comments on first open.
    @Published var aiSummaryExpanded = false
    /// `true` once we have determined there is no AI summary to
    /// show (upstream returned no `model_result`, anonymous user,
    /// 风控 rate-limit, or feed-entry shape with `ownerMid == 0`).
    /// The view treats this together with `aiSummary == nil` as
    /// "do not render the section at all" — no error banner, no
    /// "no summary" placeholder.
    @Published var aiSummaryUnavailable = false

    /// Cursor returned by the previous `commentsPage` call. The
    /// `CommentRepository` picks the right endpoint for the cursor
    /// kind — `.pn` goes to the legacy path, `.offset` goes to the
    /// app + WBI paths. `nil` is the implicit "first page" state
    /// (the helper defaults to `.start` for the empty case).
    /// See `CommentPipeline.swift` for the cursor kinds.
    private var nextCommentCursor: CommentCursor?

    init(video: BiliVideo, localRecord: DownloadRecord? = nil) {
        self.detail = video
        // If we are opening a downloaded video, construct
        // a `BiliPlayback` with a `localContext` so the
        // `LocalHLSProxyServer` reads the init / media
        // bytes from disk instead of the upstream CDN.
        // No network call is made for offline playback —
        // the user can be on airplane mode and the video
        // will still play.
        if let record = localRecord,
           Self.localPlaybackReady(for: record) {
            let directory = DownloadStore.shared.readyDirectory(
                for: record.bvid
            )
            // Look up the merged mp4 files the download
            // manager writes at completion time.  When both
            // are present we hand them to the player so it
            // can take the direct-file branch and skip the
            // local HLS proxy entirely.  When only the
            // legacy 4-file layout is on disk (an old
            // download made before the merge step landed),
            // both URLs come back nil and the proxy path
            // stays in effect.
            let merged = DownloadStore.shared.mergedFileURLs(
                for: record.bvid
            )
            self.playback = BiliPlayback(
                dash: record.dash,
                fallbackURL: nil,
                referer: record.referer,
                resumeTime: 0,
                localContext: LocalPlaybackContext(
                    directory: directory,
                    mergedVideo: merged.video,
                    mergedAudio: merged.audio
                )
            )
        } else if let record = localRecord {
            diagLog(.playback,
                    "local record opened but offline bytes incomplete",
                    details: ["bvid": record.bvid])
        }
        // Initial state — must come before the publisher
        // subscriptions below so the first emission does
        // not see a stale `downloadState`.
        refreshVideoDownloadState()
        // Subscribe to both the on-disk records (the source
        // of truth for "already downloaded") and the in-flight
        // download state (the source of truth for "currently
        // downloading").  We deliberately do NOT use
        // `objectWillChange` forwarding because SwiftUI views
        // observe `$downloadState` directly via
        // `model.$downloadState` (or via a `@Binding`).
        cancellables.append(
            DownloadStore.shared.$records
                .sink { [weak self] _ in
                    self?.refreshVideoDownloadState()
                }
        )
        cancellables.append(
            DownloadManager.shared.$stateByBvid
                .sink { [weak self] _ in
                    self?.refreshVideoDownloadState()
                }
        )
        cancellables.append(
            DownloadManager.shared.$progress
                .sink { [weak self] _ in
                    self?.refreshVideoDownloadState()
                }
        )
    }

    /// Combine the two sources of truth (on-disk records +
    /// in-flight download state) into the single
    /// `downloadState` enum the UI observes.
    private func refreshVideoDownloadState() {
        let bvid = detail.bvid
        if let record = DownloadStore.shared.record(for: bvid) {
            if downloadState != .downloaded(record: record) {
                downloadState = .downloaded(record: record)
            }
            return
        }
        if let mgrState = DownloadManager.shared.stateByBvid[bvid] {
            switch mgrState {
            case .downloading:
                let progress = DownloadManager.shared.progress[bvid] ?? 0
                let next: VideoDownloadState = .downloading(progress: progress)
                if downloadState != next { downloadState = next }
            case .failed(let message):
                if downloadState != .failed(message: message) {
                    downloadState = .failed(message: message)
                }
            case .downloaded:
                // The `DownloadStore` subscription will
                // resolve this to `.downloaded(record:)` as
                // soon as the store sees the new manifest.
                break
            case .notDownloaded:
                // `DownloadManager` clears the entry on
                // cancel, so we should drop back to the
                // "not downloaded" state — fall through.
                break
            }
            return
        }
        if downloadState != .notDownloaded {
            downloadState = .notDownloaded
        }
    }

    /// User tapped the download button.  Behaviour depends on
    /// the current state:
    ///   - `.notDownloaded` → start a download (no-op if
    ///     `playback` is not yet loaded, or if the user is
    ///     offline — the button is dimmed by the view).
    ///   - `.downloading`   → cancel the in-flight download
    ///     and drop the staging directory.
    ///   - `.downloaded`    → no-op (the user should swipe
    ///     the row in the downloads list to remove it).
    ///   - `.failed`        → start a fresh download attempt.
    func onDownloadTap() {
        let bvid = detail.bvid
        switch downloadState {
        case .notDownloaded, .failed:
            guard let playback else { return }
            DownloadManager.shared.start(video: detail, playback: playback)
        case .downloading:
            DownloadManager.shared.cancel(bvid: bvid)
        case .downloaded:
            break
        }
    }

    /// Tap handler for the action bar's 投币 (B-coin) button.
    /// Bilibili allows 0 / 1 / 2 coins per video; tapping once
    /// gives 1, the menu lets the user pick 2 (the rest of the
    /// "give 1 to a UP main you don't subscribe to" pattern).
    /// Increments `coinGiven` on success and surfaces a brief
    /// toast so the user gets feedback even though the upstream
    /// returns no payload.  Ignored when already at 2 (the
    /// upstream would reject the third coin with -11002).
    func giveCoins(multiply: Int, repository: PaladalaRepository) async {
        guard !coinInFlight else { return }
        guard multiply >= 1, multiply <= 2 else { return }
        guard coinGiven < 2 else {
            coinToast = "已經投過 2 枚硬幣啦"
            return
        }
        coinInFlight = true
        defer { coinInFlight = false }
        do {
            try await repository.giveCoins(
                to: detail, multiply: multiply, alsoLike: false
            )
            coinGiven = min(2, coinGiven + multiply)
            coinToast = "投了 \(coinGiven) 枚硬幣 · 感謝支援 UP 主"
        } catch {
            // The upstream returns a structured reason on rejection
            // (e.g. 硬币余额不足); surface it directly so the user
            // sees why the action didn't take.
            let message = error.localizedDescription
            coinToast = message.isEmpty ? "投幣失敗，請稍後再試" : message
        }
    }

    /// Clear the transient coin banner.  Called by the view
    /// after the toast's auto-dismiss timer fires so the same
    /// coin action can re-surface the banner next time.
    func clearCoinToast() {
        coinToast = nil
    }

    /// Fetch Bilibili's official AI 视频总结 for the current video.
    /// Three collapse-to-`nil` outcomes (no summary / anonymous /
    /// 风控 / feed-entry shape) all map to `aiSummaryUnavailable = true`
    /// so the view hides the section without an error banner.
    ///
    /// Called from `load(repository:)` after the detail + playback
    /// fetches complete, so `detail.ownerMid` and `detail.cid` are
    /// guaranteed to be populated when we hit the network.
    func loadAISummary(repository: PaladalaRepository) async {
        // Bail early when we know we'd get nothing back:
        //   - `ownerMid == 0` is the feed-entry shape (the view
        //     was opened from a card whose full detail has not been
        //     fetched yet — `load()` will replace `detail` before
        //     we run, so this guard is only hit on the legacy aid-only
        //     paths that never reach the view endpoint).
        //   - `cid == 0` means the view endpoint never returned a
        //     playable cid (rare).
        guard detail.ownerMid != 0, detail.cid != 0 else {
            aiSummaryUnavailable = true
            aiSummary = nil
            return
        }
        aiSummaryLoading = true
        defer { aiSummaryLoading = false }
        do {
            let summary = try await repository.aiSummary(for: detail)
            // Collapse empty payloads (no prose + no chapters)
            // to "no summary" — the view would otherwise render
            // an empty card with a header chip but no content.
            if let summary, !summary.isEmpty {
                aiSummary = summary
                aiSummaryUnavailable = false
            } else {
                aiSummary = nil
                aiSummaryUnavailable = true
            }
        } catch {
            // Network / decode failure. Log so the diagnostic
            // report can show what went wrong, but never
            // surface this to the user — the section just hides.
            bpLog("AI summary fetch failed: \(error)")
            aiSummary = nil
            aiSummaryUnavailable = true
        }
    }

    /// Tap-to-seek from an outline row in the AI 视频总结 section.
    /// The outline publishes `timestamp` in seconds; we convert
    /// to a relative offset from the current playhead so we can
    /// reuse `PlayerController.seek(by:)` (which already clamps
    /// to `[0, duration]` and uses approximate-tolerance seek
    /// to the nearest keyframe).
    func seekAIOutline(toSeconds seconds: Double, controller: PlayerController?) {
        guard let controller else { return }
        let duration = controller.duration
        let target: Double
        if duration > 0 {
            target = max(0, min(duration, seconds))
        } else {
            target = max(0, seconds)
        }
        let offset = target - controller.currentTime
        controller.seek(by: offset)
    }

    private var cancellables: [AnyCancellable] = []

    /// Verify that the bytes backing `record` are still on
    /// disk and the local proxy can serve them.  Returns
    /// `true` only when every track implied by the saved
    /// manifest is backed by both its `*.init` and
    /// `*.media` files in the ready directory.
    ///
    /// The `DownloadStore` manifest is the source of truth
    /// for "user has downloaded this" — but the bytes
    /// themselves live under `Caches/` and iOS may purge
    /// them under storage pressure.  Without this guard
    /// the local-fallback branch in `load()` would build a
    /// `BiliPlayback` pointing at a directory whose files
    /// are gone, and `LocalHLSProxyServer.proxyLocalSegment`
    /// would 404 every segment (`LocalHLSProxyServer.swift`
    /// "missing local file").
    private static func localPlaybackReady(
        for record: DownloadRecord
    ) -> Bool {
        // `record.dash` is non-optional on `DownloadRecord`
        // (contrast with `BiliPlayback.dash`, which is
        // `BiliDashSource?` — a download always captures
        // both tracks at download time).  `dash.video` and
        // `dash.audio` are likewise non-optional
        // `BiliDashSource.Track` — a video-only source still
        // carries a zero-bandwidth audio placeholder, so an
        // Optional binding there is meaningless.  The
        // on-disk file check is the authoritative "is this
        // track actually usable" answer — the proxy's
        // `proxyLocalSegment` would 404 on missing bytes
        // anyway.
        let directory = DownloadStore.shared.readyDirectory(for: record.bvid)
        let fm = FileManager.default
        func hasBothFiles(_ trackName: String) -> Bool {
            let initURL = directory.appendingPathComponent("\(trackName).init")
            let mediaURL = directory.appendingPathComponent("\(trackName).media")
            return fm.fileExists(atPath: initURL.path) &&
                   fm.fileExists(atPath: mediaURL.path)
        }
        guard hasBothFiles("video") else { return false }
        if record.dash.audio != nil, !hasBothFiles("audio") {
            return false
        }
        return true
    }

    func load(repository: PaladalaRepository) async {
        isLoading = true
        errorMessage = nil
        // Top-of-funnel signal — fires before the local-first /
        // offline-fallback early returns so we can later
        // distinguish "user opened a video we served from cache"
        // (high conversion, no network) from "user opened a
        // video that required a live playurl call" (where the
        // `video_play_error` rate matters).
        Analytics.log("video_open", ["bvid": detail.bvid])
        // For locally-downloaded videos the playback is
        // already populated from the `DownloadRecord` and
        // the detail block already has the metadata we
        // need.  Skip the network calls so the user can
        // open the video on airplane mode.
        if playback?.localContext != nil {
            isLoading = false
            return
        }
        // Offline-first fallback for non-Downloads entry
        // points.  The Downloads tab is the only navigation
        // route that constructs this VM with a
        // `localRecord:` argument — every other entry point
        // (home feed, search, dynamic feed, today card,
        // mini-player expand, history, watch later,
        // favorites, share-sheet intent, Siri intent)
        // passes only a `BiliVideo`, so `self.playback` is
        // still nil here and the early-return above does
        // not fire.  Without this branch the VM tries
        // `repository.playback(for:)` against Bilibili's
        // CDN, which fails immediately when the device is
        // offline even though the bytes are sitting in
        // `Caches/Paladala/Downloads/ready/{bvid}/`.
        //
        // Check the on-disk manifest and prefer the local
        // copy when it is present and complete.  We
        // intentionally do not try the online path "just
        // in case" — local-first is what the user wants
        // here, and going online would either succeed
        // slowly or fail with a network error that we'd
        // then have to recover from anyway.
        if let record = DownloadStore.shared.record(for: detail.bvid) {
            if Self.localPlaybackReady(for: record) {
                let directory = DownloadStore.shared.readyDirectory(for: record.bvid)
                // Same merged-file lookup as the `init` path
                // — when the merge has run, the player can
                // skip the proxy entirely.
                let merged = DownloadStore.shared.mergedFileURLs(
                    for: record.bvid
                )
                self.playback = BiliPlayback(
                    dash: record.dash,
                    fallbackURL: nil,
                    referer: record.referer,
                    resumeTime: 0,
                    localContext: LocalPlaybackContext(
                        directory: directory,
                        mergedVideo: merged.video,
                        mergedAudio: merged.audio
                    )
                )
                diagLog(.playback,
                        "VideoDetailViewModel.load used local fallback",
                        details: [
                            "bvid": detail.bvid,
                            "isDASH": self.playback?.isDASH ?? false
                        ])
                // No comments / AI summary / history fetch —
                // those all hit the network and would surface
                // "Could not load public comments." in the UI
                // without changing what plays.  The view
                // renders an empty comments section, which is
                // the right state for offline playback.
                isLoading = false
                return
            }
            // Manifest says "downloaded" but the on-disk
            // bytes are gone — most likely iOS evicted the
            // `Caches/` directory under storage pressure.
            // The user-visible outcome is the same as the
            // no-local-record path (online fetch fails
            // offline), but logging this case lets us
            // distinguish "user opened a video they never
            // downloaded" from "user's downloads got
            // silently wiped by the OS" in the diagnostic
            // report.  We do NOT log the inverse case
            // (`record(for:) == nil`) because it is the
            // common path for every video the user has not
            // downloaded and would spam the log.
            diagLog(.playback,
                    "manifest entry present but on-disk bytes missing",
                    details: [
                        "bvid": detail.bvid,
                        "readyDir": DownloadStore.shared
                            .readyDirectory(for: record.bvid).lastPathComponent
                    ])
        }
        do {
            detail = try await repository.detail(for: detail)
            self.playback = try await repository.playback(
                for: detail,
                qn: preferredQn,
                preferredAudioQuality: preferredAudioQuality
            )
            // Seed `resumeTime` from the local progress store
            // when present.  `repository.playback(...)` already
            // set the value from `BiliVideo.resumeTime` (the
            // server-side history hint), but the local store is
            // more accurate — it tracks every 0.5 s playhead
            // tick, while the server only sees the report
            // heartbeats (up to 30 s stale).  We prefer the
            // local value when it is newer.
            if let saved = PlayProgressStore.shared.lastProgress(for: detail.bvid),
               saved.currentTime > self.playback?.resumeTime ?? 0 {
                self.playback?.resumeTime = saved.currentTime
            }
            diagLog(.playback,
                    "VideoDetailViewModel.load succeeded",
                    details: [
                        "aid": detail.aid,
                        "cid": detail.cid,
                        "isDASH": self.playback?.isDASH ?? false,
                        "hasFallback": self.playback?.fallbackURL != nil
                    ])
            await loadTimedText(repository: repository)
            // Playback funnel success — emit only when we
            // actually have a usable `BiliPlayback`. The `qn`
            // param lets the console slice by quality tier
            // (e.g. "1080P funnel conversion" vs "480P fallback
            // funnel").
            Analytics.log("video_play_start", [
                "bvid": detail.bvid,
                "qn": preferredQn,
                "isDASH": self.playback?.isDASH ?? false,
                "hasFallback": self.playback?.fallbackURL != nil
            ])
            await loadComments(repository: repository)
            // Fetch the official AI 视频总结. Runs in parallel with
            // the comments fetch above via the `await` keyword; both
            // are dispatched as `Task`s by the surrounding `async
            // let`. Failures here are silent — the section simply
            // does not render.
            await loadAISummary(repository: repository)

            // YouTube-style "next up" rail. Power the
            // auto-play-next queue + the related-videos row at
            // the bottom of the page. Runs after the playback
            // block so the playerr can already start streaming
            // while the rail fetches. Failures are silent —
            // empty rail hides the section entirely.
            await loadRelatedVideos(repository: repository)

            // Start of playback: report progress=0 to mark it in the history list.
            // The periodic 30s heartbeat is handled by WatchSession in the View layer.
            Task {
                try? await repository.reportHistory(for: detail, cid: detail.cid, progress: 0)
            }
        } catch let error as BilibiliAPIError {
            // Funnel drop — record the failure to Crashlytics
            // before the per-case `errorMessage` assignment so
            // the breadcrumb still correlates against the
            // original error (not the localised copy).
            Analytics.recordError(error, context: "video_load")
            Analytics.log("video_play_error", [
                "bvid": detail.bvid,
                "kind": "api",
                "case": "\(error)"
            ])
            switch error {
            case .api(let message):
                errorMessage = message
            case .missingData:
                errorMessage = "該影片暫無可播放源。"
            case .missingIdentity:
                errorMessage = "無法識別該影片（缺少 aid/bvid）。"
            case .noPlayableFormat:
                errorMessage = "該影片的可用清晰度均不可播放（可能為地區限制或大會員專享）。"
            case .vipRequired:
                // Same shape as `.noPlayableFormat` from the
                // user's perspective — every reachable qn was
                // gated behind a 大会员 requirement. The
                // upgrade sheet is raised by the player
                // toolbar, not by the load path, so the
                // inline banner is intentionally short.
                errorMessage = L10n.vip.requiredHint
            case .vipExpired:
                errorMessage = L10n.vip.expiredHint
            case .invalidURL, .http:
                errorMessage = "網路異常，請檢查連線後重試。"
            case .sessionExpired:
                // The `onAuthFailure` latch on the API client has
                // already kicked the AppRouter to present the
                // login sheet — the ViewModel just needs to
                // surface a coherent inline error so the user
                // is not staring at a stale spinner while the
                // sheet slides in.
                errorMessage = "登入狀態已過期，請重新登入。"
            }
            diagLog(.playback,
                    "VideoDetailViewModel.load failed (BilibiliAPIError)",
                    details: [
                        "kind": "\(error)",
                        "message": errorMessage ?? "",
                        "aid": detail.aid,
                        "bvid": detail.bvid,
                        "cid": detail.cid
                    ])
            await loadComments(repository: repository)
        } catch {
            Analytics.recordError(error, context: "video_load")
            Analytics.log("video_play_error", [
                "bvid": detail.bvid,
                "kind": "unknown"
            ])
            errorMessage = "播放失敗：\(error.localizedDescription)"
            diagLog(.playback,
                    "VideoDetailViewModel.load failed (unknown)",
                    details: [
                        "error": error.localizedDescription,
                        "aid": detail.aid,
                        "bvid": detail.bvid,
                        "cid": detail.cid
                    ])
            await loadComments(repository: repository)
        }
        isLoading = false
    }

    func teardown() {
        // All player-related teardown is now handled by the PlayerView itself
        // or through the playback object lifecycle.
    }

    /// Exposed so the COMMENTS error banner can wire its
    /// "重试" button to a fresh fetch.  The original call
    /// sites use the same code path internally.
    func loadComments(repository: PaladalaRepository) async {
        commentsLoading = true
        commentsErrorMessage = nil
        // Reset to the implicit start cursor. The endpoint chain
        // inside `CommentRepository` decides which endpoint accepts
        // this cursor kind — the legacy path takes `.pn` first and
        // every previous cursor is forgotten on a fresh load.
        nextCommentCursor = .start
        commentsHasMore = false
        commentsTotalCount = 0
        do {
            let page = try await repository.commentsPage(
                for: detail,
                sort: commentSort,
                cursor: .start
            )
            comments = page.items
            nextCommentCursor = page.next
            commentsHasMore = !page.isEnd && page.next != nil
            commentsTotalCount = page.totalCount
            // Diagnostic: surface the success path so we can
            // distinguish "function returned with N items" from
            // "function threw/cancelled before returning" (the
            // v0.5.6 diagnostic showed 9 GET sent 200 OKs but 0
            // commentsPage: returning logs, leaving the
            // client-side bug invisible).
            bpLog("loadComments: OK items=\(page.items.count) allCount=\(page.totalCount) isEnd=\(page.isEnd) hasMore=\(commentsHasMore)")
        } catch BilibiliAPIError.missingIdentity {
            // Bilibili silently returns `replies: null` (with
            // `cursor.allCount > 0`) for both unauthenticated
            // callers AND callers whose WBI signature is no
            // longer accepted (the cookie is in `authStore`
            // but the server still rejected the request). The
            // API client surfaces both as `missingIdentity`.
            // We deliberately do NOT tell the user "请登录" here
            // because they may already be logged in (per the
            // app) — a misleading "log in" CTA on a logged-in
            // account is worse than a generic retry prompt.
            bpLog("loadComments: caught BilibiliAPIError.missingIdentity")
            commentsErrorMessage = "評論載入失敗，請稍後重試"
            comments = []
        } catch is CancellationError {
            // The user navigated away mid-load (typical: rapidly
            // tapping a video, or scrolling out of a feed card).
            // Cancellation is NOT a failure — surface it in
            // the diagnostic so we can distinguish it from
            // "server returned 0 comments" or "decode failed".
            bpLog("loadComments: cancelled (user navigated away mid-fetch)")
            commentsErrorMessage = nil
            comments = []
        } catch {
            // Any other failure (decoding error, URLError,
            // BilibiliAPIError.http, etc.). Log the type and
            // message so the next diagnostic captures the
            // specific failure mode instead of the generic
            // banner shown in the UI.
            bpLog("loadComments: caught error type=\(type(of: error)) message=\(error)")
            commentsErrorMessage = "評論載入失敗，請稍後重試"
            comments = []
        }
        commentsLoading = false
    }

    /// Load timed text after the detail endpoint has populated the final
    /// `cid`. Both subtitle and danmaku failures are non-fatal: the player
    /// should keep streaming even when Bilibili has no subtitle track, the
    /// danmaku endpoint rate-limits, or XML parsing returns no entries.
    private func loadTimedText(repository: PaladalaRepository) async {
        subtitleTrack = nil
        danmakuItems = []
        async let subtitlesResult = loadSubtitleTrack(repository: repository)
        async let danmakuResult = loadDanmakuItems(repository: repository)

        switch await subtitlesResult {
        case .success(let track):
            subtitleTrack = track?.isEmpty == false ? track : nil
        case .failure(let error):
            bpLog("Subtitle fetch failed: \(error)")
            subtitleTrack = nil
        }

        switch await danmakuResult {
        case .success(let items):
            danmakuItems = PluginManager.shared.danmakuFilter(items: items)
        case .failure(let error):
            bpLog("Danmaku fetch failed: \(error)")
            danmakuItems = []
        }
    }

    private func loadSubtitleTrack(
        repository: PaladalaRepository
    ) async -> Result<BiliLyricTrack?, Error> {
        do {
            return .success(try await repository.videoSubtitles(for: detail))
        } catch {
            return .failure(error)
        }
    }

    private func loadDanmakuItems(
        repository: PaladalaRepository
    ) async -> Result<[BiliDanmakuItem], Error> {
        do {
            return .success(try await repository.videoDanmaku(for: detail))
        } catch {
            return .failure(error)
        }
    }

    /// YouTube-style "next up" rail. Populates
    /// `relatedVideos` with up to ~40 entries from
    /// `/x/web-interface/archive/related`. Empty array on
    /// failure — the view hides the rail entirely in that
    /// case rather than surfacing an error.
    ///
    /// Re-fetched every time the user navigates to a fresh
    /// `bvid` (the VM is recreated per push), so we don't
    /// cache across videos.
    func loadRelatedVideos(repository: PaladalaRepository) async {
        guard !detail.bvid.isEmpty else { return }
        do {
            let related = try await repository.relatedVideos(bvid: detail.bvid)
            // Drop the current video if Bilibili included it in
            // the recommendation (it happens — the upstream
            // sometimes returns the same bvid as row 0).
            relatedVideos = related.filter { $0.bvid != detail.bvid }
        } catch {
            // Silent — the view hides the rail when the array
            // is empty. Logging every recommendation failure
            // would spam the diagnostic log during normal
            // flaky-network sessions.
        }
    }

    /// Returns the next "next up" video and bumps the index.
    /// Returns `nil` when the auto-play queue is empty (the
    /// caller should fall through to the player-ended UI
    /// state). Called from `VideoDetailView` when the player
    /// reports it has reached the end AND the user has
    /// enabled `autoPlayNext` in `ProfileSettingsView`.
    func consumeNextUp() -> BiliVideo? {
        guard let next = nextUpIndex,
              next < relatedVideos.count else {
            nextUpIndex = nil
            return nil
        }
        let video = relatedVideos[next]
        // Advance; nil out when we exhaust the queue so the
        // next ended-event starts the manual-pick UI.
        if next + 1 < relatedVideos.count {
            nextUpIndex = next + 1
        } else {
            nextUpIndex = nil
        }
        return video
    }

    /// Reset the auto-play cursor to the head of the queue.
    /// Called when the view first appears so a fresh
    /// VideoDetailView starts from the top recommendation.
    func resetNextUpCursor() {
        nextUpIndex = relatedVideos.isEmpty ? nil : 0
    }

    /// Pick a non-VIP-gated `qn` from the same canonical chain
    /// the playurl refetch uses. Used by the VIP-gate error
    /// paths to roll a bad pick back to something the user can
    /// actually play, without leaving them stranded on the
    /// gated qn (which would re-fail on the next refetch).
    ///
    /// Returns `nil` when `current` is the chain's bottom
    /// (360P) — in that case we leave the pick alone and let
    /// the inline error banner carry the message.
    private func fallbackQnForVipGate(current: Int) -> Int? {
        // Mirror the canonical chain in `BilibiliAPIClient.
        // playurl(...)` — keep them in sync so a "fallback
        // here" promise is the same set of ladder entries
        // the refetch would have tried.
        let chain: [Int] = [
            131, 130, 129, 128, 127, 126, 125, 120,
            116, 112, 80, 64, 32, 16
        ]
        guard let idx = chain.firstIndex(of: current), idx < chain.count - 1 else {
            return nil
        }
        // Walk *down* the chain to the first entry the
        // user could legally pick (BiliVideoQuality's
        // `requiresVIP` flag is the gate). Returning the
        // first non-gated entry is intentional: the user
        // asked for the highest quality and we silently
        // drop them to the best non-gated qn. A fancier
        // "step down by one" is tempting but leaves the
        // user one click away from another alert when
        // they are still non-VIP.
        for qn in chain[(idx + 1)...] {
            if let quality = BiliVideoQuality(rawValue: qn), !quality.requiresVIP {
                return qn
            }
        }
        return nil
    }

    func loadMoreComments(repository: PaladalaRepository) async {
        guard !commentsLoading, !commentsLoadingMore, commentsHasMore, let nextCommentCursor else { return }
        commentsLoadingMore = true
        defer { commentsLoadingMore = false }
        do {
            let page = try await repository.commentsPage(
                for: detail,
                sort: commentSort,
                cursor: nextCommentCursor
            )
            let seen = Set(comments.map(\.id))
            comments.append(contentsOf: page.items.filter { !seen.contains($0.id) })
            self.nextCommentCursor = page.next
            commentsHasMore = !page.isEnd && page.next != nil
            commentsTotalCount = max(commentsTotalCount, page.totalCount)
        } catch {
            // Prefer the typed error message for `missingIdentity`
            // (the silent WBI gate) so the user sees the same
            // generic retry prompt the first-load catch produces;
            // any other failure gets the English fallback that has
            // been on the screen for the previous builds.
            commentsErrorMessage = (error is BilibiliAPIError)
                ? "評論載入失敗，請稍後重試"
                : "Could not load more comments."
        }
    }

    /// Re-fetch the first page of comments in the new sort. Called by
    /// the picker in `VideoDetailView.commentPreview` when the user
    /// toggles between 最热 / 最新. Mirrors the manual `Retry` button
    /// in that it resets the cursor and forces a full reload.
    func setCommentSort(_ sort: CommentSort, repository: PaladalaRepository) async {
        guard commentSort != sort else { return }
        commentSort = sort
        Haptics.selection()
        await loadComments(repository: repository)
    }

    /// Switch the user's preferred playback quality and refetch
    /// the playurl with the new ladder entry as the preferred
    /// slot. The `BilibiliAPIClient` reorders its qn retry chain
    /// around the new value so the request immediately tries the
    /// new quality first; if it is gated (region lock, VIP
    /// paywall), the chain falls through to the next entry.
    /// The existing `playback` is left untouched until the new
    /// one returns — that way the AVPlayer does not get yanked
    /// mid-segment by a quality swap.
    func setPreferredQn(_ qn: Int, repository: PaladalaRepository) async {
        guard preferredQn != qn else { return }
        preferredQn = qn
        Haptics.selection()
        do {
            let newPlayback = try await repository.playback(
                for: detail,
                qn: qn,
                preferredAudioQuality: preferredAudioQuality
            )
            self.playback = newPlayback
        } catch let error as BilibiliAPIError {
            // The user picked a quality they cannot play;
            // surface a brief inline error without yanking
            // the previous playback out from under the
            // AVPlayer.
            switch error {
            case .noPlayableFormat:
                errorMessage = "該清晰度不可用，已切換回原畫質。"
            case .vipRequired, .vipExpired:
                // 大会员 business code returned. Roll the
                // pick back to whatever the qnChain landed
                // on (a non-gated fallback) — the helper
                // returns the highest non-gated qn it could
                // reach, so a user who picked 4K and got
                // -62004 ends up on 1080P rather than 80's
                // 1080P high or worse. The view also flips
                // the upgrade alert via the published
                // `vipUpgradeReason`; the inline error
                // banner is intentionally short so the
                // alert (which is the real CTA) does not
                // have to share screen real estate with a
                // paragraph.
                if let fallback = fallbackQnForVipGate(current: qn) {
                    preferredQn = fallback
                }
                errorMessage = (error.errorDescription ?? "")
                // Convert the typed error into the same
                // `VipUpgradeReason` the menu uses so the
                // sheet copy + actions line up regardless
                // of whether the trigger was a menu tap or
                // a playurl refetch.
                vipUpgradeReason = (error.isVipExpiredError ? .expired : .notVIP)
            case .api(let message):
                errorMessage = message
            case .missingData:
                errorMessage = "該影片暫無可播放源。"
            case .missingIdentity:
                errorMessage = "無法識別該影片（缺少 aid/bvid）。"
            case .invalidURL, .http:
                errorMessage = "網路異常，請檢查連線後重試。"
            case .sessionExpired:
                // Same latch contract as `load()` above: the
                // app router already has the login sheet on
                // screen, the inline error just keeps the UI
                // honest while the quality pick resets to the
                // previous value on the next playback call.
                errorMessage = "登入狀態已過期，請重新登入。"
            }
        } catch {
            errorMessage = "切換清晰度失敗：\(error.localizedDescription)"
        }
    }

    /// Switch the user's preferred audio quality and refetch
    /// the playurl with the new audio track id. Mirrors
    /// `setPreferredQn(_:repository:)` for the audio dimension.
    /// Non-VIP picks (320 kbps / 192 kbps Dolby) are
    /// silently downgraded to the highest available AAC
    /// track the upstream returned — the playurl response
    /// simply does not carry the gated audio ids for
    /// non-VIP accounts.
    func setPreferredAudioQuality(
        _ audioQuality: Int,
        repository: PaladalaRepository
    ) async {
        guard preferredAudioQuality != audioQuality else { return }
        preferredAudioQuality = audioQuality
        Haptics.selection()
        do {
            let newPlayback = try await repository.playback(
                for: detail,
                qn: preferredQn,
                preferredAudioQuality: audioQuality
            )
            self.playback = newPlayback
        } catch let error as BilibiliAPIError {
            switch error {
            case .noPlayableFormat:
                errorMessage = "該音質不可用，已切換回原音質。"
            case .vipRequired, .vipExpired:
                // Mirror the video path: drop the pick
                // back to the highest non-gated audio id
                // (128 kbps AAC by default), surface the
                // same upgrade sheet the menu uses, and
                // keep the inline banner short.
                if let fallback = fallbackAudioQualityForVipGate(current: audioQuality) {
                    preferredAudioQuality = fallback
                }
                errorMessage = (error.errorDescription ?? "")
                vipUpgradeReason = (error.isVipExpiredError ? .expired : .notVIP)
            case .api(let message):
                errorMessage = message
            case .missingData:
                errorMessage = "該影片暫無可播放源。"
            case .missingIdentity:
                errorMessage = "無法識別該影片（缺少 aid/bvid）。"
            case .invalidURL, .http:
                errorMessage = "網路異常，請檢查連線後重試。"
            case .sessionExpired:
                errorMessage = "登入狀態已過期，請重新登入。"
            }
        } catch {
            errorMessage = "切換音質失敗：\(error.localizedDescription)"
        }
    }

    /// Sibling of `fallbackQnForVipGate` for the audio
    /// dimension. Audio has only two non-gated ids (64 kbps
    /// + 128 kbps) so the walk is short, but the helper
    /// exists for symmetry with the video path and to keep
    /// the inline comment from getting long.
    private func fallbackAudioQualityForVipGate(current: Int) -> Int? {
        // The original `current` Int is a ladder id we may
        // not have a `BiliAudioQuality` case for (the
        // upstream occasionally inserts test ladders). If
        // it doesn't map, fall back to the highest
        // non-gated case directly.
        guard let mapped = BiliAudioQuality(rawValue: current) else {
            return BiliAudioQuality.allCases.first(where: { !$0.requiresVIP })?.rawValue
        }
        // If the pick itself is non-gated, return it as-is
        // — the caller is already on a legal ladder entry
        // and the inline error banner is the only thing
        // that needs to change.
        if !mapped.requiresVIP {
            return mapped.rawValue
        }
        // Otherwise walk the ladder for the first
        // non-gated entry (always 128 kbps AAC today;
        // using `first(where:)` rather than a hard-coded
        // id keeps the helper ladder-driven).
        return BiliAudioQuality.allCases.first(where: { !$0.requiresVIP })?.rawValue
    }

    func submitComment(repository: PaladalaRepository, message: String) async -> Bool {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        do {
            try await repository.postComment(for: detail, message: message)
            // The post endpoint currently returns an empty payload —
            // building a fully-typed `BiliComment` from the user's
            // input would require fabricating a member block, which
            // is fragile. Refreshing the first page is the safer
            // path: we re-fetch via the start cursor so the new
            // comment (now at the top under "最新" / head of the
            // pinned list under "热门") appears without merging
            // glitches. The refresh is also wired to the same
            // pagination reset `loadComments` already does on a
            // sort change, so the user sees the new reply and a
            // refreshed total count.
            await loadComments(repository: repository)
            return true
        } catch {
            errorMessage = "評論失敗：\(error.localizedDescription)"
            return false
        }
    }

    func performCommentAction(repository: PaladalaRepository, rpid: Int, actionType: String) async {
        do {
            switch actionType {
            case "like":
                try await repository.likeComment(for: detail, rpid: rpid, action: 1)
                // Local optimistic update. The previous build left this
                // as a comment — "In a real app we'd update ..." —
                // which meant tapping the thumbs-up flashed no
                // feedback at all until the next page reload. The
                // server response does not include the authoritative
                // count, so we +1 locally and let the next
                // `loadComments` reconcile if the user reloads.
                updateCommentLikeCount(rpid: rpid, delta: 1)
            case "unlike":
                try await repository.likeComment(for: detail, rpid: rpid, action: 0)
                updateCommentLikeCount(rpid: rpid, delta: -1)
            case "hate":
                try await repository.hateComment(for: detail, rpid: rpid, action: 1)
            default:
                break
            }
        } catch {
            bpLog("Comment action \(actionType) failed: \(error)")
        }
    }

    /// Mutate the local like count of the comment with the given
    /// `rpid`. Walks the main list and the embedded `replies[]`
    /// (sub-replies rendered under each comment) so the thumbs-up
    /// feedback reaches every row that displays the count.
    private func updateCommentLikeCount(rpid: Int, delta: Int) {
        guard let index = comments.firstIndex(where: { $0.id == rpid }) else { return }
        let target = comments[index]
        let newCount = max(0, target.likeCount + delta)
        comments[index] = BiliComment(
            id: target.id,
            authorName: target.authorName,
            avatarURL: target.avatarURL,
            message: target.message,
            likeCount: newCount,
            replyCount: target.replyCount,
            replies: target.replies,
            vipBadge: target.vipBadge
        )
    }
}

@MainActor
final class LiveViewModel: ObservableObject {
    @Published var rooms: [BiliLiveRoom] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    func load(repository: PaladalaRepository) async {
        isLoading = true
        errorMessage = nil
        do {
            rooms = try await repository.liveRooms()
        } catch {
            errorMessage = "Could not load live rooms."
        }
        isLoading = false
    }
}

@MainActor
final class ReplyListViewModel: ObservableObject {
    @Published var replies: [BiliComment] = []
    @Published var isLoading = false
    @Published var isLoadingMore = false
    @Published var hasMore = false
    @Published var errorMessage: String?
    @Published var totalCount = 0

    private var page = 1
    private let video: BiliVideo
    private let rootComment: BiliComment

    init(video: BiliVideo, rootComment: BiliComment) {
        self.video = video
        self.rootComment = rootComment
    }

    func load(repository: PaladalaRepository) async {
        page = 1
        isLoading = true
        errorMessage = nil
        do {
            let pageResult = try await repository.repliesPage(for: video, root: rootComment.id, page: page)
            replies = pageResult.items
            hasMore = !pageResult.isEnd
            totalCount = pageResult.totalCount
        } catch {
            errorMessage = "無法載入回覆。"
        }
        isLoading = false
    }

    func loadMore(repository: PaladalaRepository) async {
        guard !isLoading, !isLoadingMore, hasMore else { return }
        isLoadingMore = true
        page += 1
        do {
            let pageResult = try await repository.repliesPage(for: video, root: rootComment.id, page: page)
            let seen = Set(replies.map(\.id))
            replies.append(contentsOf: pageResult.items.filter { !seen.contains($0.id) })
            hasMore = !pageResult.isEnd
            totalCount = max(totalCount, pageResult.totalCount)
        } catch {
            page -= 1
        }
        isLoadingMore = false
    }

    func submitReply(repository: PaladalaRepository, message: String) async -> Bool {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        do {
            try await repository.postComment(for: video, message: message, root: rootComment.id, parent: rootComment.id)
            await load(repository: repository)
            return true
        } catch {
            errorMessage = "回覆失敗：\(error.localizedDescription)"
            return false
        }
    }

    func performCommentAction(repository: PaladalaRepository, rpid: Int, actionType: String) async {
        do {
            switch actionType {
            case "like":
                try await repository.likeComment(for: video, rpid: rpid, action: 1)
            case "unlike":
                try await repository.likeComment(for: video, rpid: rpid, action: 0)
            case "hate":
                try await repository.hateComment(for: video, rpid: rpid, action: 1)
            default:
                break
            }
        } catch {
            bpLog("Reply action \(actionType) failed: \(error)")
        }
    }
}
