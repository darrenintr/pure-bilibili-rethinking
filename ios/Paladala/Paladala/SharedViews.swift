import ImageIO
import SwiftUI
import DesignSystem

struct VideoCard: View {
    let video: BiliVideo
    let action: () -> Void
    /// Optional repository reference so the long-press context menu
    /// can call `addToWatchLater` / `removeFromWatchLater`. Call
    /// sites that don't have a repository (previews, tests) pass
    /// `nil` and the context menu's watch-later action is hidden.
    let repository: PaladalaRepository?
    /// Optional namespace used for the hero / zoom navigation
    /// transition. When the parent view provides a `Namespace.ID`,
    /// the cover image is registered as a `matchedTransitionSource`
    /// so the `VideoDetailView` destination can zoom out of the
    /// card on push and back into it on pop. Call sites that
    /// don't care about the transition (previews, in-account
    /// rows) pass `nil` and the cover renders as before.
    let heroNamespace: Namespace.ID?

    /// Convenience init for call sites that don't need the
    /// context menu or hero transition. Matches the original
    /// `init(video:action:)` signature so the existing call sites
    /// in `AccountContentViews.swift` and elsewhere don't have to
    /// change.
    init(video: BiliVideo, action: @escaping () -> Void) {
        self.video = video
        self.action = action
        self.repository = nil
        self.heroNamespace = nil
    }

    init(video: BiliVideo, repository: PaladalaRepository, heroNamespace: Namespace.ID? = nil, action: @escaping () -> Void) {
        self.video = video
        self.repository = repository
        self.heroNamespace = heroNamespace
        self.action = action
    }

    var body: some View {
        expressiveBody
            .frame(maxWidth: .infinity)
            .buttonStyle(PaladalaPressBounceButtonStyle())
            .modifier(VideoContextMenuIfAvailable(video: video, repository: repository))
            // Impression fires once per card every time it enters
            // the visible viewport. For long feeds this can be
            // noisy; if analytics volume becomes a concern later,
            // swap this for a debounced / sampled impression hook
            // (e.g. only fire on first appearance per session,
            // keyed by bvid in a Set).
            .onAppear {
                Analytics.log("card_impression", ["bvid": video.id])
            }
    }

    private var expressiveBody: some View {
        Button {
            Analytics.log("card_select", ["bvid": video.id, "duration": video.duration])
            Haptics.tap()
            action()
        } label: {
            DSVideoCard(
                title: video.title, author: video.ownerName,
                viewsText: "\(video.viewCount.compactCount) 次播放",
                durationText: video.duration.mmss, authorID: String(video.ownerMid)
            ) {
                CoverImage(url: video.coverURL)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .modifier(HeroSourceModifier(videoID: video.id, namespace: heroNamespace))
            }
        }
        .buttonStyle(.plain)
    }
}

/// Applies `.matchedTransitionSource` only when a namespace is
/// available AND the runtime OS is iOS 18+ (the API was
/// introduced in iOS 18). On iOS 17 the modifier is a no-op and
/// the destination `VideoDetailView` falls back to the system
/// cross-fade.
private struct HeroSourceModifier: ViewModifier {
    let videoID: String
    let namespace: Namespace.ID?

    func body(content: Content) -> some View {
        if let namespace, #available(iOS 18, *) {
            content.matchedTransitionSource(id: videoID, in: namespace)
        } else {
            content
        }
    }
}

/// Adds the long-press context menu only when a repository is
/// available. Falls back to a no-op modifier otherwise so the
/// `init(video:action:)` path stays free of a dependency.
private struct VideoContextMenuIfAvailable: ViewModifier {
    let video: BiliVideo
    let repository: PaladalaRepository?

    func body(content: Content) -> some View {
        if let repository {
            content.videoContextMenu(for: video, repository: repository)
        } else {
            content
        }
    }
}

struct LiveRoomCard: View {
    let room: BiliLiveRoom

    @AppStorage("paladala.materialDesign") private var materialDesign: MaterialDesign = .liquidGlass
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        Button {
            Haptics.tap()
            router.openLive(room)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    // The explicit Rectangle() + .aspectRatio(16/10, .fit)
                    // container keeps a stable cover size. Without it,
                    // CoverImage's ZStack of Rectangle+Image can
                    // collapse to placeholder size on first paint
                    // (before the URL image lands) and the grid cell
                    // reports a tiny height to the parent, causing
                    // the LIVE badge to be painted on top of the
                    // next row's cover.
                    Rectangle()
                        .fill(.clear)
                        .aspectRatio(16 / 10, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .overlay(
                            CoverImage(url: room.coverURL)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        )
                        .clipped()
                    liveBadge
                        .padding(12)
                        // Apple's recommended "live" affordance —
                        // the SF Symbol pulses on a continuous loop
                        // so the user can spot a live card at a
                        // glance during a fast scroll. We apply the
                        // effect to a hidden SF Symbol inside the
                        // same container because `.symbolEffect(.pulse)`
                        // on `Text` itself is a no-op; the visible
                        // "LIVE" label keeps its typography, the
                        // pulse animates the dot to the right.
                        .overlay(alignment: .trailing) {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 6))
                                .foregroundStyle(.white)
                                // `.repeat(.continuous)` is iOS 18+
                                // (deployment target is 17.5). On
                                // iOS 17 the default `.symbolEffect
                                // (.pulse)` plays once and stops;
                                // the dot then sits static on a
                                // live card. That's still better
                                // than no badge at all.
                                .symbolEffect(.pulse)
                                .padding(.trailing, 3)
                                .accessibilityHidden(true)
                        }
                }
                .overlay(alignment: .bottom) {
                    // The Street hairline separator under the cover.
                    // iOS Native uses the theme's borderWidth (0.5pt)
                    // which on iOS Native is the system separator
                    // — already integrated into the rounded card via
                    // `paladalaCardSurface`, so we skip it there.
                    if PaladalaTheme.activeVariant != .iosNative {
                        Rectangle()
                            .fill(PaladalaTheme.ink)
                            .frame(height: PaladalaTheme.borderWidth)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(room.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .topLeading)
                    Text("\(room.hostName) - \(room.areaName)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        // Red dot for "live" — HIG convention; brand
                        // pink is reserved for action affordances.
                        Circle()
                            .fill(.red)
                            .frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                        Text("\(room.viewerCount.compactCount) watching")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .paladalaCardSurface(materialDesign)
            .contentShape(Rectangle())
        }
        .frame(maxWidth: .infinity)
        .buttonStyle(PaladalaPressBounceButtonStyle())
    }

    /// Street-styled "LIVE" badge: mono-cap label, pink fill, 1.5pt
    /// ink border, no rounding.  iOS Native swaps to a red capsule
    /// with white text (HIG convention for live indicators — see
    /// Twitch / Apple TV live rows).
    @ViewBuilder
    private var liveBadge: some View {
        if PaladalaTheme.usesNativeLayout {
            HStack(spacing: 4) {
                Text("LIVE")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.red, in: Capsule())
        } else {
            Text("LIVE")
                .font(PaladalaTheme.FontRole.labelMono)
                .foregroundStyle(PaladalaTheme.paper)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(PaladalaTheme.biliPink)
                .overlay {
                    Rectangle()
                        .stroke(PaladalaTheme.ink, lineWidth: PaladalaTheme.borderWidth)
                }
        }
    }
}

struct CoverImage: View {
    let url: URL?

    var body: some View {
        // We pull the image bytes through a small URLSession-backed loader
        // rather than the built-in `AsyncImage`. AsyncImage is notoriously
        // flaky on slow / flaky networks — once it lands in the failure
        // phase there is no way to retry, and the system image cache keeps
        // the broken placeholder around. The custom loader keeps trying
        // (with a short back-off) and refreshes when `url` changes.
        // Note: no `.clipped()` here — the caller owns the final crop.
        ResilientImage(url: url)
    }
}

struct ResilientImage: View {
    let url: URL?
    var maximumPixelSize: Int = 720

    @State private var image: UIImage?
    @State private var attempts = 0
    @State private var loadedURL: URL?

    private let maxAttempts = 3

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color(uiColor: .tertiarySystemGroupedBackground))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipped()
            } else if attempts >= maxAttempts {
                // Permanent failure placeholder so the cell still has
                // visible affordance instead of looking like a still-
                // loading skeleton forever.
                Image(systemName: "photo")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .task(id: url) {
            await load()
        }
    }

    private func load() async {
        // We deliberately do NOT reset `image` here.  The
        // `.task(id: url)` modifier re-fires on every view
        // appearance — including `LazyVStack` recycles that
        // hand us back the same URL identity.  Resetting the
        // `@State` causes a visible placeholder flash on
        // fast scroll even when the pipeline's actor cache
        // would have served the image instantly.  Leave the
        // previous render in place; the in-flight task will
        // overwrite it if a fresher copy arrives.

        guard let url else {
            return
        }

        if loadedURL != url {
            loadedURL = url
            attempts = 0
        }

        while attempts < maxAttempts && !Task.isCancelled {
            attempts += 1

            do {
                image = try await CoverImagePipeline.shared.image(
                    for: url,
                    maximumPixelSize: maximumPixelSize
                )
                return
            } catch is CancellationError {
                return
            } catch {
                guard attempts < maxAttempts else { return }
                try? await Task.sleep(for: .milliseconds(250 * attempts))
            }
        }
    }
}

private actor CoverImagePipeline {
    static let shared = CoverImagePipeline()

    private struct RequestKey: Hashable {
        let url: URL
        let maximumPixelSize: Int

        var cacheKey: NSString {
            "\(url.absoluteString)#px=\(maximumPixelSize)" as NSString
        }
    }

    private let memoryCache = NSCache<NSString, UIImage>()
    private let session: URLSession
    private var inFlight: [RequestKey: Task<UIImage, Error>] = [:]

    private init() {
        // Street's single-column feed uses fewer simultaneous thumbnails.
        // A 96 MB decoded-image budget avoids the former 192 MB peak while
        // retaining roughly two to three screens of 720 px covers.
        memoryCache.countLimit = 240
        memoryCache.totalCostLimit = 96 * 1_024 * 1_024

        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(
            memoryCapacity: 32 * 1_024 * 1_024,
            diskCapacity: 256 * 1_024 * 1_024
        )
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        // Bumped from 6 to 12 — the feed lists fan out across
        // many distinct `i0/i1/...` Bilibili cover hosts, and
        // a single host rarely appears in more than 4–5 cells
        // at once.  The old limit stalled covers during fast
        // scroll on the Music grid where ~30 cells mount in a
        // single runloop tick.
        configuration.httpMaximumConnectionsPerHost = 12
        session = URLSession(configuration: configuration)
    }

    func image(
        for url: URL,
        maximumPixelSize requestedPixelSize: Int
    ) async throws -> UIImage {
        let maximumPixelSize = min(1_200, max(96, requestedPixelSize))
        let key = RequestKey(url: url, maximumPixelSize: maximumPixelSize)

        if let cached = memoryCache.object(forKey: key.cacheKey) {
            return cached
        }

        if let existing = inFlight[key] {
            return try await existing.value
        }

        let task = Task<UIImage, Error> {
            try await Self.fetchImage(
                url: url,
                maximumPixelSize: maximumPixelSize,
                session: session
            )
        }
        inFlight[key] = task

        do {
            let decoded = try await task.value
            inFlight[key] = nil
            let cost = decoded.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
            memoryCache.setObject(decoded, forKey: key.cacheKey, cost: cost)
            return decoded
        } catch {
            inFlight[key] = nil
            throw error
        }
    }

    nonisolated private static func fetchImage(
        url: URL,
        maximumPixelSize: Int,
        session: URLSession
    ) async throws -> UIImage {
        var request = URLRequest(url: url)
        request.setValue("https://www.bilibili.com", forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148",
            forHTTPHeaderField: "User-Agent"
        )

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }

        guard let decoded = Self.downsample(
            data: data,
            maximumPixelSize: maximumPixelSize
        ) else {
            throw URLError(.cannotDecodeContentData)
        }
        return decoded
    }

    nonisolated private static func downsample(
        data: Data,
        maximumPixelSize: Int
    ) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return nil
        }

        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
        ] as CFDictionary

        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            return nil
        }
        return UIImage(cgImage: image)
    }
}

struct MetricPill: View {
    let systemImage: String
    let text: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(PaladalaTheme.FontRole.labelMono)
            .foregroundStyle(PaladalaTheme.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(PaladalaTheme.paper)
            .overlay {
                Rectangle()
                    .stroke(PaladalaTheme.ink, lineWidth: PaladalaTheme.borderWidth)
            }
    }
}

/// Standard error / status banner.  The previous shape was
/// text-only — consumers dropped `ErrorBanner(message:)` into the
/// view tree and the user got a dead-end string.  Premium apps
/// always pair the error with an actionable row so the user has
/// somewhere to go from the failure state.  The two optional
/// closures defer to the caller: history / favorites pass
/// `retry: { Task { await model.load(...) } }`; auth-gated
/// surfaces pass `primary: ("登录", { router.openLogin() })`.
struct ErrorBanner: View {
    let message: String
    /// Optional retry button rendered to the right of the message.
    /// When nil and no `primary` action is supplied, the banner
    /// keeps the original text-only layout.
    let retry: (() -> Void)?
    /// Optional primary CTA (label + action). Rendered as a tinted
    /// button when present so it visually outranks the retry
    /// secondary action.
    let primary: PrimaryAction?

    /// Plain value type — the banner renders it as a `Button`
    /// inline rather than instantiating the type as a view.
    /// Not `Hashable` because `(() -> Void)` doesn't have a
    /// meaningful synthesis (would require Equatable on closures,
    /// which Swift forbids).  The `id` is unused — kept for
    /// forward-compat if the API grows to need it.
    struct PrimaryAction {
        let id = UUID()
        let label: String
        let action: () -> Void
    }

    init(message: String,
         retry: (() -> Void)? = nil,
         primary: ErrorBanner.PrimaryAction? = nil) {
        self.message = message
        self.retry = retry
        self.primary = primary
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(PaladalaTheme.FontRole.bodySmall)
                .foregroundStyle(PaladalaTheme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let primary {
                Button {
                    Haptics.tap()
                    primary.action()
                } label: {
                    Text(primary.label)
                        .font(PaladalaTheme.FontRole.labelMono)
                        .foregroundStyle(PaladalaTheme.ink)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 36)
                        .background(PaladalaTheme.biliPink)
                        .overlay {
                            Rectangle()
                                .stroke(PaladalaTheme.ink, lineWidth: PaladalaTheme.borderWidth)
                        }
                }
                .buttonStyle(PaladalaPressBounceButtonStyle())
            }
            if retry != nil {
                Button {
                    Haptics.tap()
                    retry?()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(PaladalaTheme.ink)
                        .frame(width: 36, height: 36)
                        .background(PaladalaTheme.paper)
                        .overlay {
                            Rectangle()
                                .stroke(PaladalaTheme.ink, lineWidth: PaladalaTheme.borderWidth)
                        }
                }
                .buttonStyle(PaladalaPressBounceButtonStyle())
                .accessibilityLabel("重試")
            }
        }
        .padding(12)
        .background(PaladalaTheme.paper)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(PaladalaTheme.biliPink)
                .frame(width: 6)
        }
        .overlay {
            Rectangle()
                .stroke(PaladalaTheme.ink, lineWidth: PaladalaTheme.borderWidth)
        }
        .background {
            Rectangle()
                .fill(PaladalaTheme.ink)
                .offset(
                    x: PaladalaTheme.hardShadowOffset,
                    y: PaladalaTheme.hardShadowOffset
                )
        }
    }
}

// MARK: - Video context menu

/// Long-press actions shared by every video card surface. The
/// watch-later / share / open-in-browser actions all run in
/// fire-and-forget `Task`s; on failure the user gets a
/// `Haptics.error()` and the action silently no-ops (so a network
/// blip doesn't ruin the long-press experience). The
/// `isWatchLaterRow` / `isHistoryRow` flags surface destructive
/// removal actions on the corresponding list.
extension View {
    @ViewBuilder
    func videoContextMenu(
        for video: BiliVideo,
        repository: PaladalaRepository,
        isWatchLaterRow: Bool = false,
        isHistoryRow: Bool = false
    ) -> some View {
        // We need `isLoggedIn` to gate the watch-later action — but
        // `videoContextMenu(for:repository:)` is a free `View`
        // extension, not a view body, so we can't use
        // `@EnvironmentObject` here. Thread the boolean in via a
        // hidden helper view that reads the environment for us.
        // This avoids adding a `static let shared` to `AuthStore`
        // (which would conflict with the existing `@StateObject` in
        // `PaladalaApp`).
        self.modifier(VideoContextMenuModifier(
            video: video,
            repository: repository,
            isWatchLaterRow: isWatchLaterRow,
            isHistoryRow: isHistoryRow
        ))
    }
}

private struct VideoContextMenuModifier: ViewModifier {
    let video: BiliVideo
    let repository: PaladalaRepository
    let isWatchLaterRow: Bool
    let isHistoryRow: Bool

    @EnvironmentObject private var authStore: AuthStore
    @EnvironmentObject private var router: AppRouter

    /// Build the bv / av URL on demand.  `URL(string:)` is a
    /// cheap constructor (string interpolation + Unicode
    /// normalisation; no I/O), so the per-body rebuild cost
    /// is dominated by SwiftUI's diff machinery itself — a
    /// `lazy var` here would force a mutating getter on the
    /// struct (Swift rejects it because the modifier value
    /// is immutable at the call site), so we keep the
    /// straightforward `let` in `body`.
    private var videoURL: URL {
        URL(string: "https://www.bilibili.com/video/\(video.bvid.isEmpty ? "av\(video.aid)" : video.bvid)")!
    }

    func body(content: Content) -> some View {
        let url = videoURL
        let isLoggedIn = authStore.isLoggedIn
        content.contextMenu {
            // "查看 UP 主主页" appears whenever the row carries
            // a non-zero `ownerMid`. Search results now
            // populate `ownerMid` correctly (Bilibili's web
            // search endpoint exposes flat `mid` + `author`,
            // not `owner.mid` — see `VideoDTO.init(from:)`),
            // so this entry is reachable from every row.
            if video.ownerMid > 0 {
                Button {
                    Haptics.selection()
                    router.openUP(mid: video.ownerMid)
                } label: {
                    Label("檢視 UP 主主頁", systemImage: "person.crop.circle")
                }
                Divider()
            }
            if isLoggedIn {
                if !isWatchLaterRow {
                    Button {
                        Haptics.tap()
                        Task {
                            do {
                                try await repository.addToWatchLater(video: video)
                                Haptics.success()
                            } catch {
                                Haptics.error()
                            }
                        }
                    } label: {
                        Label("稍後再看", systemImage: "clock.badge.checkmark")
                    }
                } else {
                    Button(role: .destructive) {
                        Haptics.tap()
                        Task {
                            do {
                                try await repository.removeFromWatchLater(video: video)
                                Haptics.success()
                                NotificationCenter.default.post(
                                    name: .watchLaterDidChange,
                                    object: video
                                )
                            } catch {
                                Haptics.error()
                            }
                        }
                    } label: {
                        Label("從稍後再看中移除", systemImage: "clock.badge.xmark")
                    }
                }
                Menu {
                    Button {
                        Haptics.tap()
                        Task {
                            do {
                                try await repository.giveCoins(to: video, multiply: 1)
                                Haptics.success()
                            } catch {
                                Haptics.error()
                            }
                        }
                    } label: {
                        Label("投 1 枚硬幣", systemImage: "bitcoinsign.circle")
                    }
                    Button {
                        Haptics.tap()
                        Task {
                            do {
                                try await repository.giveCoins(to: video, multiply: 2)
                                Haptics.success()
                            } catch {
                                Haptics.error()
                            }
                        }
                    } label: {
                        Label("投 2 枚硬幣", systemImage: "bitcoinsign.circle.fill")
                    }
                } label: {
                    Label("投幣支援 UP 主", systemImage: "bitcoinsign.circle")
                }
            }
            Button {
                Haptics.tap()
                UIPasteboard.general.url = url
            } label: {
                Label("複製連結", systemImage: "doc.on.doc")
            }
            Button {
                Haptics.tap()
                UIApplication.shared.open(url)
            } label: {
                Label("瀏覽器開啟", systemImage: "safari")
            }
            ShareLink(item: url) {
                Label("分享", systemImage: "square.and.arrow.up")
            }
            if isHistoryRow {
                Divider()
                Button(role: .destructive) {
                    Haptics.tap()
                    // Local-only removal from the history list —
                    // the upstream "delete history" endpoint
                    // (`/x/v2/history/delete`) requires CSRF and is
                    // not currently exposed. Refresh the history
                    // list to clear it from the UI.
                    NotificationCenter.default.post(
                        name: .historyDidRemove,
                        object: video
                    )
                } label: {
                    Label("從歷史記錄中移除", systemImage: "trash")
                }
            }
        } preview: {
            VideoContextMenuPreview(video: video)
        }
    }
}

/// Compact preview shown when the user long-presses a card. Reuses
/// the cover image, the title, and a brief metadata row so the user
/// can confirm they're acting on the right video without committing
/// to a navigation. Width is pinned to 320pt to match the iOS
/// system context-menu preview size.
private struct VideoContextMenuPreview: View {
    let video: BiliVideo

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CoverImage(url: video.coverURL)
                .aspectRatio(16 / 10, contentMode: .fill)
                .frame(height: 180)
                .clipped()
            Text(video.title)
                .font(PaladalaTheme.FontRole.headline)
                .foregroundStyle(PaladalaTheme.ink)
                .lineLimit(2)
            Text(video.ownerName)
                .font(PaladalaTheme.FontRole.labelMono)
                .foregroundStyle(PaladalaTheme.mutedInk)
        }
        .padding(12)
        .background(PaladalaTheme.paper)
        .frame(width: 320)
    }
}

extension Notification.Name {
    /// Posted by the long-press "从稍后再看中移除" action. The
    /// Watch Later list view subscribes and reloads.
    static let watchLaterDidChange = Notification.Name("paladala.watchLater.didChange")
    /// Posted by the long-press "从历史记录中移除" action. The
    /// History list view subscribes and removes the entry locally.
    static let historyDidRemove = Notification.Name("paladala.history.didRemove")
}

// MARK: - Skeletons

/// Grid of skeleton placeholders shown while the first feed page is
/// loading. Street Minimal uses static solid blocks rather than a
/// perpetual gradient shimmer. This removes an always-animating layer
/// while keeping the placeholder geometry identical to the real card.
struct SkeletonGrid: View {
    var columns: Int = 2
    var cardCount: Int = 6
    var columnSpacing: CGFloat = 12
    var rowSpacing: CGFloat = 12

    @AppStorage("paladala.materialDesign") private var materialDesign: MaterialDesign = .liquidGlass

    var body: some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: columnSpacing),
                count: columns
            ),
            spacing: rowSpacing
        ) {
            ForEach(0..<cardCount, id: \.self) { _ in
                SkeletonCard()
                    .paladalaCardSurface(materialDesign)
            }
        }
    }
}

// MARK: - Bangumi loading / error surfaces
//
// `BangumiHomeView` (timeline) and `BangumiSeasonDetailView`
// (per-season detail) both render a "load → error → empty"
// state machine against `repository.bangumiTimeline(...)` and
// `repository.pgcSeason(...)`.  The three surfaces were
// duplicated wholesale — `loadingView` was identical, the
// `errorView`s differed only by an optional Safari fallback
// button.  Extracting them here collapses ~80 lines per view
// into a single source of truth so a styling change in one
// place can't drift from the other.

/// Loading placeholder for any Bangumi surface.  Renders the
/// paper-canvas spinner + "加载中…" caption used by both
/// `BangumiHomeView` and `BangumiSeasonDetailView`.
struct BangumiLoadingView: View {
    var body: some View {
        VStack {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(PaladalaTheme.ink)
            Text("載入中…")
                .font(PaladalaTheme.FontRole.bodySmall)
                .foregroundStyle(PaladalaTheme.mutedInk)
                .padding(.top, PaladalaTheme.Spacing.s)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PaladalaTheme.canvas)
    }
}

/// Error surface for any Bangumi surface.  Mandatory `message`
/// is rendered below the warning glyph; `retry` is wired to a
/// plain bordered "重试" button.  Pass `fallback` to render the
/// secondary "在 Safari 打开" affordance used by
/// `BangumiSeasonDetailView` when the in-app PGC player
/// upstream gates the request (-10403 区域限制 etc.).
struct BangumiErrorView: View {
    let message: String
    let retry: () -> Void
    /// Optional secondary action label + closure.  When
    /// non-nil, a "在 Safari 打开" button is rendered next
    /// to "重试" so the user has a fallback path even when
    /// the in-app player can't bind.
    let fallback: (label: String, action: () -> Void)?

    init(
        message: String,
        retry: @escaping () -> Void,
        fallback: (label: String, action: () -> Void)? = nil
    ) {
        self.message = message
        self.retry = retry
        self.fallback = fallback
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(PaladalaTheme.biliPink)
            Text("載入失敗")
                .font(PaladalaTheme.FontRole.sectionHeader)
                .foregroundStyle(PaladalaTheme.ink)
            Text(message)
                .font(PaladalaTheme.FontRole.bodySmall)
                .foregroundStyle(PaladalaTheme.mutedInk)
                .multilineTextAlignment(.center)
            HStack(spacing: PaladalaTheme.Spacing.m) {
                retryButton
                if let fallback {
                    fallbackButton(label: fallback.label, action: fallback.action)
                }
            }
        }
        .padding(PaladalaTheme.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PaladalaTheme.canvas)
    }

    private var retryButton: some View {
        Button {
            retry()
        } label: {
            Text("重試")
                .font(PaladalaTheme.FontRole.labelMono)
                .foregroundStyle(PaladalaTheme.ink)
                .padding(.horizontal, PaladalaTheme.Spacing.l)
                .padding(.vertical, PaladalaTheme.Spacing.s)
                .background(PaladalaTheme.paper)
                .overlay {
                    Rectangle()
                        .strokeBorder(PaladalaTheme.ink, lineWidth: PaladalaTheme.borderWidth)
                }
        }
        .buttonStyle(.plain)
    }

    private func fallbackButton(label: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            Text(label)
                .font(PaladalaTheme.FontRole.labelMono)
                .foregroundStyle(PaladalaTheme.mutedInk)
                .padding(.horizontal, PaladalaTheme.Spacing.l)
                .padding(.vertical, PaladalaTheme.Spacing.s)
                .background(PaladalaTheme.paper)
                .overlay {
                    Rectangle()
                        .strokeBorder(PaladalaTheme.mutedInk, lineWidth: PaladalaTheme.borderWidth)
                }
        }
        .buttonStyle(.plain)
    }
}

/// Single skeleton card. Its square blocks mirror the cover and text
/// regions without material, blur, gradient, or infinite animation.
struct SkeletonCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(PaladalaTheme.coolGray)
                .aspectRatio(16 / 10, contentMode: .fit)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(PaladalaTheme.ink)
                        .frame(height: PaladalaTheme.borderWidth)
                }
            VStack(alignment: .leading, spacing: 10) {
                Rectangle()
                    .fill(PaladalaTheme.coolGray)
                    .frame(height: 14)
                Rectangle()
                    .fill(PaladalaTheme.coolGray)
                    .frame(width: 112, height: 12)
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
