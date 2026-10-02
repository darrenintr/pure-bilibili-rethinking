import SwiftUI
import UIKit
import SafariServices
import AVKit

// MARK: - 追番 home
//
// First-pass surface for the 追番 feature.  Renders the
// weekly PGC timeline (七天: 周一 … 周日) with one strip
// per day and a horizontal scroll of season cards inside
// the selected day.  Tapping a card opens the season's
// canonical share URL in the system handler so the user
// lands on Bilibili's official web surface (or the official
// app via Universal Links) — we don't ship an in-app
// detail or player for PGC content in this first pass.
//
// Wired via the existing `RootView.navigationDestination(for:)`
// machinery: the profile screen's "追番追剧" quick action
// pushes a `BangumiRoute.timeline` onto the root nav stack
// and the destination resolves to this view.
//
// See `BilibiliAPIClient.bangumiTimeline(...)` for the
// network half and `Models.swift` for the `BangumiCard` /
// `BangumiDay` shapes.

struct BangumiHomeView: View {
    let repository: PaladalaRepository
    /// Optional namespace for any future hero / matched-
    /// transition animation. Currently unused but kept on
    /// the signature so the destination can be added
    /// without churning every call site.
    let heroNamespace: Namespace.ID?

    @State private var days: [BangumiDay] = []
    @State private var selectedWeekday: Int = Calendar.current.component(.weekday, from: Date())
    @State private var isLoading: Bool = false
    @State private var loadError: String? = nil
    /// Pushed onto the root nav stack when a timeline card
    /// is tapped.  The destination renders the in-app
    /// `BangumiSeasonDetailView`.  Kept here (rather than
    /// hoisted into `AppRouter`) so the weekly timeline
    /// and the per-season surface share the same view
    /// instance — both are reachable from the
    /// `MainTab.bangumi` tab and via the profile quick
    /// action.
    @State private var presentedSeasonId: Int64?
    @AppStorage("paladala.materialDesign") private var materialDesign: MaterialDesign = .liquidGlass

    var body: some View {
        Group {
            if isLoading && days.isEmpty {
                BangumiLoadingView()
            } else if let loadError, days.isEmpty {
                BangumiErrorView(message: loadError) {
                    Task { await load(force: true) }
                }
            } else if days.isEmpty {
                emptyView
            } else {
                contentView
            }
        }
        .navigationTitle("追番")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(PaladalaTheme.paper, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .task {
            await load()
        }
        .refreshable {
            await load(force: true)
        }
        .navigationDestination(item: $presentedSeasonId) { seasonId in
            BangumiSeasonDetailView(
                repository: repository,
                seasonId: seasonId
            )
        }
    }

    private var contentView: some View {
        VStack(spacing: 0) {
            weekdayStrip
                .padding(.horizontal, PaladalaTheme.Spacing.l)
                .padding(.vertical, PaladalaTheme.Spacing.s)
                .background(PaladalaTheme.paper)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .strokeBorder(
                            PaladalaTheme.ink,
                            lineWidth: PaladalaTheme.hairlineWidth
                        )
                }
            ScrollView {
                if let day = days.first(where: { $0.weekday == selectedWeekday }) {
                    if day.cards.isEmpty {
                        emptyDayView(for: day)
                            .padding(.top, 48)
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(day.cards) { card in
                                BangumiCardRow(card: card) { tapped in
                                    onCardTap(tapped)
                                }
                                if card.id != day.cards.last?.id {
                                    Rectangle()
                                        .fill(PaladalaTheme.ink.opacity(0.12))
                                        .frame(height: PaladalaTheme.hairlineWidth)
                                }
                            }
                        }
                    }
                } else {
                    Text("該日無更新")
                        .font(PaladalaTheme.FontRole.body)
                        .foregroundStyle(PaladalaTheme.mutedInk)
                        .padding(.top, 48)
                }
            }
            .background(PaladalaTheme.canvas)
        }
    }

    private var weekdayStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(days) { day in
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) {
                            selectedWeekday = day.weekday
                        }
                        Haptics.tap()
                    } label: {
                        weekdayTab(day: day)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func weekdayTab(day: BangumiDay) -> some View {
        let isSelected = day.weekday == selectedWeekday
        return VStack(spacing: 2) {
            // `weekdayLabel` (e.g. "周一") is sufficient on
            // its own — the upstream's MM-DD `date` field was
            // just a redundant second date indicator under
            // the weekday name, and on a 7-day strip the
            // weekday + the visible card list already tell
            // the user which day they're on.  We keep
            // `BangumiDay.date` in the model for any future
            // detail / hero surface, but the strip stops
            // rendering it.
            Text(day.weekdayLabel)
                .font(PaladalaTheme.FontRole.labelMono)
                .foregroundStyle(isSelected ? PaladalaTheme.ink : PaladalaTheme.mutedInk)
            Rectangle()
                .fill(isSelected ? PaladalaTheme.ink : Color.clear)
                .frame(height: 2)
                .padding(.top, 2)
        }
        .padding(.horizontal, PaladalaTheme.Spacing.m)
        .padding(.vertical, PaladalaTheme.Spacing.s)
    }

    private func emptyDayView(for day: BangumiDay) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "calendar")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(PaladalaTheme.mutedInk)
            Text("\(day.weekdayLabel)暫無番劇更新")
                .font(PaladalaTheme.FontRole.body)
                .foregroundStyle(PaladalaTheme.mutedInk)
        }
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "play.rectangle")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(PaladalaTheme.mutedInk)
            Text("暫無番劇時間表")
                .font(PaladalaTheme.FontRole.sectionHeader)
                .foregroundStyle(PaladalaTheme.ink)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PaladalaTheme.canvas)
    }

    private func load(force: Bool = false) async {
        if !force && !days.isEmpty {
            diagLog(.bangumi, "BangumiHomeView load skipped (cached)",
                    details: ["days": days.count])
            return
        }
        diagLog(.bangumi, "BangumiHomeView load started",
                details: ["force": force, "cachedDays": days.count])
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let fetched = try await repository.bangumiTimeline()
            // If today is a weekday the upstream has data for,
            // keep the user's selection; otherwise default to
            // the first day the upstream actually returned.
            if !days.contains(where: { $0.weekday == selectedWeekday }) {
                selectedWeekday = fetched.first?.weekday ?? selectedWeekday
            }
            days = fetched
            diagLog(.bangumi, "BangumiHomeView load succeeded",
                    details: [
                        "days": fetched.count,
                        "firstDate": fetched.first?.date ?? "nil",
                        "selectedWeekday": selectedWeekday,
                        "weekdayWithCards": fetched
                            .map { "\($0.weekday)=\($0.cards.count)" }
                            .joined(separator: ",")
                    ])
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            diagLog(.bangumi, "BangumiHomeView load failed",
                    details: [
                        "errorType": String(describing: type(of: error)),
                        "errorMessage": "\(error)"
                    ])
        }
    }

    /// Card row tap.  Sets `presentedSeasonId` so the
    /// `.navigationDestination(item:)` binding pushes the
    /// in-app `BangumiSeasonDetailView`.  Long-form
    /// episode + play selection lives there; the timeline
    /// itself stays a browse surface.
    private func onCardTap(_ card: BangumiCard) {
        diagLog(.bangumi, "BangumiHomeView card tapped",
                details: [
                    "seasonId": card.seasonId,
                    "title": card.title
                ])
        presentedSeasonId = card.seasonId
    }
}

// MARK: - In-app PGC season detail
//
// Shows the cover, title, long description, and the full
// episode list for a single PGC season.  Tapping an
// episode attempts an in-app PGC play (the build-243
// PGC playurl integration lives in the same file under
// the B-marker section so this surface stays the single
// entry point for the in-app PGC flow).
//
// This view is reachable from:
//   1. `BangumiHomeView` timeline card tap, via
//      `navigationDestination(item: $presentedSeasonId)`.
//   2. The dedicated in-app PGC route once the user
//      opens a PGC share URL inside Paladala (handled by
//      the same destination).
struct BangumiSeasonDetailView: View {
    let repository: PaladalaRepository
    let seasonId: Int64

    @State private var detail: BangumiSeasonDetail?
    @State private var isLoading: Bool = false
    @State private var loadError: String? = nil
    /// The episode the user has currently selected for
    /// playback.  Drives the in-app player panel; nil
    /// means "nothing queued".
    @State private var selectedEpisode: BangumiEpisode?
    /// Sheet for the in-app Safari fallback when the
    /// in-app player is unavailable.
    @State private var fallbackURL: IdentifiableURL?
    /// PGC in-app player surface.  Initialised lazily when
    /// the user first picks an episode.  The `PlayerController`
    /// is owned by SwiftUI via `@State` so its lifetime
    /// matches the view; we tear it down explicitly when
    /// `selectedEpisode` flips back to nil (close button)
    /// so the next episode gets a fresh AVPlayer + a fresh
    /// `LocalHLSProxyServer` reservation.
    @State private var pgcController: PlayerController?
    /// `true` while the in-app PGC playurl fetch is in
    /// flight, false once `pgcController` is set or the
    /// fetch fails.  Drives the in-view spinner before the
    /// AVPlayer surface takes over.
    @State private var isFetchingPgcPlayback: Bool = false
    /// Last error from the in-app PGC playurl fetch.  When
    /// non-nil, the inline surface shows an error block
    /// with "在 Safari 中打开" as the only escape hatch.
    @State private var pgcPlaybackError: String?

    var body: some View {
        Group {
            if isLoading && detail == nil {
                BangumiLoadingView()
            } else if let loadError, detail == nil {
                BangumiErrorView(message: loadError) {
                    Task { await load() }
                }
            } else if let detail {
                contentView(detail: detail)
            } else {
                Color.clear
            }
        }
        .navigationTitle(detail?.title ?? "番劇詳情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(PaladalaTheme.paper, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .task(id: seasonId) { await load() }
        .sheet(item: $fallbackURL) { wrapped in
            InAppSafariView(url: wrapped.url).ignoresSafeArea()
        }
    }

    @ViewBuilder
    private func contentView(detail: BangumiSeasonDetail) -> some View {
        VStack(spacing: 0) {
            heroView(detail: detail)
            Divider()
                .background(PaladalaTheme.ink)
            episodeList(detail: detail)
            if let ep = selectedEpisode {
                pgcPlayerPanel(ep: ep)
            }
        }
        .background(PaladalaTheme.canvas)
    }

    /// In-app PGC player panel.  Three states:
    ///   1. `pgcController == nil && isFetchingPgcPlayback` —
    ///      the playurl fetch is in flight; show a spinner
    ///      plus the current `selectedEpisode` metadata.
    ///   2. `pgcController != nil` — the AVPlayer is bound;
    ///      embed a SwiftUI `VideoPlayer` so the system
    ///      chrome (play / pause / scrub / AirPlay / PiP)
    ///      shows up automatically.
    ///   3. `pgcPlaybackError != nil` — upstream returned
    ///      a real failure (most commonly -10403 "区域限制
    ///      不可观看"); surface a compact error with a
    ///      "在 Safari 中打开" affordance.
    @ViewBuilder
    private func pgcPlayerPanel(ep: BangumiEpisode) -> some View {
        VStack(spacing: 0) {
            pgcPlayerHeader(ep: ep)
            if isFetchingPgcPlayback {
                pgcPlayerLoading
            } else if let err = pgcPlaybackError {
                pgcPlayerError(ep: ep, message: err)
            } else if let c = pgcController {
                pgcPlayerSurface(controller: c)
            }
        }
        .background(PaladalaTheme.paper)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PaladalaTheme.ink, style: FillStyle())
                .frame(height: PaladalaTheme.hairlineWidth)
        }
    }

    private func pgcPlayerHeader(ep: BangumiEpisode) -> some View {
        HStack(spacing: PaladalaTheme.Spacing.m) {
            Image(systemName: "play.circle.fill")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(PaladalaTheme.biliPink)
            VStack(alignment: .leading, spacing: 2) {
                Text(ep.indexLabel)
                    .font(PaladalaTheme.FontRole.labelMono)
                    .foregroundStyle(PaladalaTheme.mutedInk)
                Text(ep.longTitle ?? ep.title)
                    .font(PaladalaTheme.FontRole.cardTitle)
                    .foregroundStyle(PaladalaTheme.ink)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button {
                closePgcPlayer()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(PaladalaTheme.mutedInk)
                    .padding(8)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("關閉播放器")
        }
        .padding(.horizontal, PaladalaTheme.Spacing.l)
        .padding(.vertical, PaladalaTheme.Spacing.s)
    }

    private var pgcPlayerLoading: some View {
        HStack(spacing: PaladalaTheme.Spacing.m) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(PaladalaTheme.ink)
            Text("準備播放器…")
                .font(PaladalaTheme.FontRole.bodySmall)
                .foregroundStyle(PaladalaTheme.mutedInk)
            Spacer()
        }
        .padding(.horizontal, PaladalaTheme.Spacing.l)
        .padding(.vertical, PaladalaTheme.Spacing.m)
    }

    private func pgcPlayerError(ep: BangumiEpisode, message: String) -> some View {
        HStack(spacing: PaladalaTheme.Spacing.m) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(PaladalaTheme.biliPink)
            VStack(alignment: .leading, spacing: 2) {
                Text("無法在此裝置播放")
                    .font(PaladalaTheme.FontRole.bodySmall)
                    .foregroundStyle(PaladalaTheme.ink)
                Text(message)
                    .font(PaladalaTheme.FontRole.bodySmall)
                    .foregroundStyle(PaladalaTheme.mutedInk)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Button {
                if let url = ep.shareURL {
                    fallbackURL = IdentifiableURL(url: url)
                }
            } label: {
                Text("在 Safari 開啟")
                    .font(PaladalaTheme.FontRole.labelMono)
                    .foregroundStyle(PaladalaTheme.ink)
                    .padding(.horizontal, PaladalaTheme.Spacing.m)
                    .padding(.vertical, PaladalaTheme.Spacing.s)
                    .background(PaladalaTheme.paper)
                    .overlay {
                        Rectangle()
                            .strokeBorder(PaladalaTheme.ink, lineWidth: PaladalaTheme.borderWidth)
                    }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, PaladalaTheme.Spacing.l)
        .padding(.vertical, PaladalaTheme.Spacing.m)
    }

    @ViewBuilder
    private func pgcPlayerSurface(controller: PlayerController) -> some View {
        VideoPlayer(player: controller.player)
            .frame(height: 220)
            .background(Color.black)
    }

    /// Bottom action bar that appears once the user has
    /// picked an episode.  Replaced by the full `pgcPlayerPanel`
    /// (loading / inline AVPlayer / error / close) — kept
    /// here as a comment marker so the file-level diff
    /// against the build-243 baseline stays readable.
    /// The body previously housed the "在 Paladala 打开"
    /// button (an `InAppSafariView` fallback) and is
    /// superseded by `pgcPlayerPanel` once the user has
    /// selected an episode.

    private func heroView(detail: BangumiSeasonDetail) -> some View {
        HStack(alignment: .top, spacing: PaladalaTheme.Spacing.m) {
            coverThumb(detail: detail)
            VStack(alignment: .leading, spacing: 6) {
                Text(detail.title)
                    .font(PaladalaTheme.FontRole.sectionHeader)
                    .foregroundStyle(PaladalaTheme.ink)
                    .lineLimit(2)
                if let desc = detail.desc, !desc.isEmpty {
                    Text(desc)
                        .font(PaladalaTheme.FontRole.bodySmall)
                        .foregroundStyle(PaladalaTheme.mutedInk)
                        .lineLimit(4)
                }
                Text("共 \(detail.episodes.count) 話")
                    .font(PaladalaTheme.FontRole.labelMono)
                    .foregroundStyle(PaladalaTheme.mutedInk)
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(PaladalaTheme.Spacing.l)
        .background(PaladalaTheme.paper)
    }

    @ViewBuilder
    private func coverThumb(detail: BangumiSeasonDetail) -> some View {
        if let url = detail.coverURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .empty:
                    Rectangle().fill(PaladalaTheme.coolGray)
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                case .failure:
                    Rectangle().fill(PaladalaTheme.coolGray)
                @unknown default:
                    Rectangle().fill(PaladalaTheme.coolGray)
                }
            }
            .frame(width: 96, height: 128)
            .clipped()
            .overlay {
                Rectangle()
                    .strokeBorder(PaladalaTheme.ink, lineWidth: PaladalaTheme.hairlineWidth)
            }
        } else {
            Rectangle()
                .fill(PaladalaTheme.coolGray)
                .frame(width: 96, height: 128)
                .overlay {
                    Rectangle()
                        .strokeBorder(PaladalaTheme.ink, lineWidth: PaladalaTheme.hairlineWidth)
                }
        }
    }

    private func episodeList(detail: BangumiSeasonDetail) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(detail.episodes) { ep in
                    Button {
                        Haptics.tap()
                        onEpisodeTap(ep)
                    } label: {
                        episodeRow(ep: ep,
                                   isSelected: ep.id == selectedEpisode?.id)
                    }
                    .buttonStyle(.plain)
                    if ep.id != detail.episodes.last?.id {
                        Rectangle()
                            .fill(PaladalaTheme.ink.opacity(0.12))
                            .frame(height: PaladalaTheme.hairlineWidth)
                            .padding(.leading, PaladalaTheme.Spacing.l)
                    }
                }
            }
        }
    }

    private func episodeRow(ep: BangumiEpisode, isSelected: Bool) -> some View {
        HStack(alignment: .center, spacing: PaladalaTheme.Spacing.m) {
            Text(ep.indexLabel)
                .font(PaladalaTheme.FontRole.labelMono)
                .foregroundStyle(PaladalaTheme.ink)
                .frame(width: 56, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(ep.longTitle ?? ep.title)
                    .font(PaladalaTheme.FontRole.cardTitle)
                    .foregroundStyle(PaladalaTheme.ink)
                    .lineLimit(2)
                if let ms = ep.durationMs, ms > 0 {
                    Text(formatDuration(ms))
                        .font(PaladalaTheme.FontRole.bodySmall)
                        .foregroundStyle(PaladalaTheme.mutedInk)
                }
            }
            Spacer(minLength: 0)
            if isSelected {
                Image(systemName: "play.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(PaladalaTheme.biliPink)
            } else {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(PaladalaTheme.mutedInk)
            }
        }
        .padding(.horizontal, PaladalaTheme.Spacing.l)
        .padding(.vertical, PaladalaTheme.Spacing.m)
        .background(isSelected ? PaladalaTheme.biliPink.opacity(0.06) : PaladalaTheme.paper)
        .contentShape(Rectangle())
    }

    private func load() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let fetched = try await repository.pgcSeason(seasonId: seasonId)
            detail = fetched
            diagLog(.bangumi, "BangumiSeasonDetail load succeeded",
                    details: [
                        "seasonId": seasonId,
                        "title": fetched.title,
                        "episodes": fetched.episodes.count
                    ])
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            diagLog(.bangumi, "BangumiSeasonDetail load failed",
                    details: [
                        "seasonId": seasonId,
                        "errorType": String(describing: type(of: error)),
                        "errorMessage": "\(error)"
                    ])
        }
    }

    /// Episode tap.  Real in-app PGC playback path:
    ///   1. Set `selectedEpisode` so the player panel
    ///      re-renders into existence.
    ///   2. Tear down any previous in-flight
    ///      `PlayerController` (a different season's
    ///      playurl would otherwise leak in).
    ///   3. Fetch the PGC playurl via the repository
    ///      pass-through to `BilibiliAPIClient.pgcPlayurl`.
    ///      The upstream may answer -10403 ("区域限制")
    ///      which surfaces as `BilibiliAPIError.api` and
    ///      ends up in `pgcPlaybackError`; the panel
    ///      falls back to a "在 Safari 打开" affordance.
    ///   4. On success, instantiate a `PlayerController`
    ///      (no `BiliVideo` is available for PGC content,
    ///      so `video: nil` — the `WatchSession` /
    ///      history-reporter path is skipped).
    ///   5. Store the controller in `@State`.  SwiftUI
    ///      keeps it alive for the lifetime of the view.
    private func onEpisodeTap(_ ep: BangumiEpisode) {
        diagLog(.bangumi, "BangumiSeasonDetail episode tapped",
                details: [
                    "seasonId": seasonId,
                    "epId": ep.epId,
                    "title": ep.title
                ])
        selectedEpisode = ep
        pgcPlaybackError = nil
        if let old = pgcController {
            // Tear down the previous controller so the next
            // episode gets a fresh AVPlayer / LocalHLSProxyServer
            // reservation.  `PlayerController.loadPlayback` already
            // calls cancel on the previous loadTask, but we want
            // a clean teardown of the AVPlayer's nowPlayingInfo
            // so the system control center doesn't keep showing
            // the old track.
            _ = old
        }
        pgcController = nil
        isFetchingPgcPlayback = true
        Task { await fetchAndStartPgcPlayback(ep: ep) }
    }

    /// Close the in-app PGC player panel.  Releases the
    /// `PlayerController` so the AVPlayer's
    /// `MPNowPlayingInfoCenter` entry clears and the local
    /// HLS proxy reservation frees up.
    private func closePgcPlayer() {
        diagLog(.bangumi, "BangumiSeasonDetail close pgc player",
                details: ["epId": selectedEpisode?.epId ?? -1])
        pgcController = nil
        pgcPlaybackError = nil
        isFetchingPgcPlayback = false
        selectedEpisode = nil
    }

    @MainActor
    private func fetchAndStartPgcPlayback(ep: BangumiEpisode) async {
        do {
            let playback = try await repository.pgcPlayback(
                epId: ep.epId,
                seasonId: seasonId
            )
            diagLog(.bangumi, "BangumiSeasonDetail pgc playback fetched",
                    details: [
                        "epId": ep.epId,
                        "isDASH": playback.isDASH
                    ])
            // `PlayerController(playback:video:)` already calls
            // `loadPlayback` from inside `init` (it owns the
            // loadTask lifecycle).  The `video: nil` overload
            // skips the `WatchSession` history reporter (PGC
            // episodes don't expose a usable `BiliVideo` /
            // `B站 v2 aid+cid`).
            let controller = PlayerController(
                playback: playback,
                video: nil
            )
            // Hand the new controller to the view; SwiftUI
            // keeps it alive until we set it back to nil in
            // `closePgcPlayer` or the user opens a different
            // episode.
            pgcController = controller
            isFetchingPgcPlayback = false
        } catch {
            diagLog(.bangumi, "BangumiSeasonDetail pgc playback failed",
                    details: [
                        "epId": ep.epId,
                        "errorType": String(describing: type(of: error)),
                        "errorMessage": "\(error)"
                    ])
            pgcPlaybackError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            isFetchingPgcPlayback = false
        }
    }

    private func formatDuration(_ ms: Int64) -> String {
        let total = ms / 1000
        let minutes = total / 60
        let seconds = total % 60
        if minutes >= 60 {
            let hours = minutes / 60
            let m = minutes % 60
            return String(format: "%d:%02d:%02d", hours, m, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

/// One row in the bangumi day's card list.  Street Minimal
/// chrome: cover thumbnail, title, update description, and
/// a hairline divider between rows.  Tapping the row pushes
/// an in-app `BangumiSeasonDetailView` onto the root nav
/// stack so the user gets the full season + episode list
/// without leaving Paladala.  Tapping a row is the
/// canonical entry to a per-season surface; falling back
/// to `shareURL` (via `InAppSafariView`) is reserved for
/// the in-detail "open in browser" affordance.
private struct BangumiCardRow: View {
    let card: BangumiCard
    let onTap: (BangumiCard) -> Void

    var body: some View {
        Button {
            Haptics.tap()
            onTap(card)
        } label: {
            HStack(alignment: .top, spacing: PaladalaTheme.Spacing.m) {
                cover
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(card.title)
                            .font(PaladalaTheme.FontRole.cardTitle)
                            .foregroundStyle(PaladalaTheme.ink)
                            .lineLimit(2)
                        Spacer(minLength: 0)
                        if let badge = card.badgeText {
                            Text(badge)
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(PaladalaTheme.biliPink)
                        }
                    }
                    Text(card.updateDescription)
                        .font(PaladalaTheme.FontRole.bodySmall)
                        .foregroundStyle(PaladalaTheme.mutedInk)
                    Spacer(minLength: 0)
                }
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(PaladalaTheme.mutedInk)
                    .padding(.top, 4)
            }
            .padding(.horizontal, PaladalaTheme.Spacing.l)
            .padding(.vertical, PaladalaTheme.Spacing.m)
            .background(PaladalaTheme.paper)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var cover: some View {
        if let url = card.coverURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .empty:
                    Rectangle()
                        .fill(PaladalaTheme.coolGray)
                case .success(let image):
                    image.resizable()
                        .aspectRatio(contentMode: .fill)
                case .failure:
                    Rectangle()
                        .fill(PaladalaTheme.coolGray)
                @unknown default:
                    Rectangle()
                        .fill(PaladalaTheme.coolGray)
                }
            }
            .frame(width: 88, height: 60)
            .clipped()
            .overlay {
                Rectangle()
                    .strokeBorder(PaladalaTheme.ink, lineWidth: PaladalaTheme.hairlineWidth)
            }
        } else {
            Rectangle()
                .fill(PaladalaTheme.coolGray)
                .frame(width: 88, height: 60)
                .overlay {
                    Rectangle()
                        .strokeBorder(PaladalaTheme.ink, lineWidth: PaladalaTheme.hairlineWidth)
                }
        }
    }
}

/// In-app SFSafariViewController wrapper.  The previous
/// flow used `UIApplication.shared.open(...)` which
/// triggered a Universal Link into the official B站 app and
/// effectively took the user out of Paladala — bad for
/// retention, bad for a "stay in our chrome" tab.  This
/// wrapper presents the same B站 PGC page inside a sheet
/// instead, so the user can dismiss it and be back on the
/// 追番 tab without losing context.
private struct InAppSafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let config = SFSafariViewController.Configuration()
        config.entersReaderIfAvailable = false
        config.barCollapsingEnabled = true
        let vc = SFSafariViewController(url: url, configuration: config)
        // PaladalaTheme.biliPink is a SwiftUI Color; UIKit's
        // SFSafariViewController.preferredControlTintColor
        // wants a UIColor.  Hard-code the matching RGBA here
        // (#FF6194) so we don't pay a Color → UIColor
        // bridge at sheet-present time and we don't risk
        // the iOS 14/15 `UIColor(_:)` initializer on
        // `Color` being unavailable on whichever OS this
        // build ends up running on.
        vc.preferredControlTintColor = UIColor(
            red: 1.0, green: 0.38, blue: 0.58, alpha: 1.0
        )
        vc.dismissButtonStyle = .close
        return vc
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

/// `URL` itself isn't `Identifiable`, so the `.sheet(item:)`
/// binding needs a wrapper.  Using the URL as its own id is
/// safe here because `presentedURL` is only ever set to one
/// URL at a time — a re-tap with the same URL would
/// re-present the same sheet, but the user would have had
/// to dismiss the previous one first.
private struct IdentifiableURL: Identifiable {
    let url: URL
    var id: URL { url }
}
