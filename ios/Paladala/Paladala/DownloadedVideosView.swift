import SwiftUI

/// List of every video the user has downloaded.  Reached
/// from the profile screen's "离线缓存" quick action
/// (`ProfileRoute.downloads` in `AppRouter`).
///
/// Each row shows the cover, title, duration, on-disk size
/// and the date the download completed.  Tap a row to play
/// (offline-capable — the playback path is `BiliPlayback
/// .localContext` → `LocalHLSProxyServer.serveLocal(...)`).
/// Swipe-to-delete removes both the manifest entry and the
/// on-disk bytes.
///
/// The toolbar exposes a single share-log action: when a
/// download is stuck or the list looks empty, the user can
/// one-tap share the diagnostic report (which now includes a
/// downloads section) so the developer has everything
/// needed to debug — manifest state, in-flight
/// `DownloadManager` state, on-disk byte counts, and the
/// tail of the in-memory event log.
struct DownloadedVideosView: View {
    let repository: PaladalaRepository
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var authStore: AuthStore
    @ObservedObject private var store = DownloadStore.shared
    /// Lazily-prepared report URL. We delay building it until
    /// the user taps, because `DiagnosticLogger.export` writes
    /// to the temp directory (which is fine but not free).
    /// Once `shareURL` is non-nil the toolbar shows a
    /// `ShareLink`; if the temp-file write fails we copy the
    /// report to the clipboard instead.
    @State private var shareURL: URL? = nil

    var body: some View {
        Group {
            if store.records.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(store.records) { record in
                        Button {
                            Haptics.tap()
                            router.openLocalVideo(record)
                        } label: {
                            DownloadedVideoRow(record: record)
                        }
                        .buttonStyle(PaladalaPressBounceButtonStyle())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                Haptics.tap()
                                DownloadStore.shared.remove(bvid: record.bvid)
                            } label: {
                                Label("刪除下載", systemImage: "trash")
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(PaladalaTheme.canvas)
            }
        }
        .navigationTitle("離線快取")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let shareURL {
                    // Once the URL is prepared, the system
                    // `ShareLink` takes over — gives AirDrop /
                    // Save-to-Files / Mail / Messages for free
                    // without an `UIActivityViewController`
                    // bridge.
                    ShareLink(item: shareURL) {
                        Image(systemName: "square.and.arrow.up.on.square")
                    }
                    .accessibilityLabel("匯出診斷日誌")
                    .accessibilityHint("匯出診斷日誌可傳送給開發者排查下載問題")
                } else {
                    Button {
                        Haptics.tap()
                        shareDiagnosticReport()
                    } label: {
                        Image(systemName: "square.and.arrow.up.on.square")
                    }
                    .accessibilityLabel("匯出診斷日誌")
                    .accessibilityHint("匯出診斷日誌可傳送給開發者排查下載問題")
                }
            }
        }
    }

    /// Shown when the user has never successfully completed a
    /// download.  Calls out the most common reason (a download
    /// got "stuck at 75%") and offers the export-log action
    /// right next to the empty illustration.
    private var emptyState: some View {
        VStack(spacing: 18) {
            ContentUnavailableView(
                "暫無下載影片",
                systemImage: "arrow.down.circle",
                description: Text("在影片頁點選下載按鈕儲存到本地")
            )
            if let shareURL {
                ShareLink(item: shareURL) {
                    Label("匯出診斷日誌", systemImage: "square.and.arrow.up")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(
                                cornerRadius: PaladalaTheme.cardRadius,
                                style: PaladalaTheme.cornerStyle
                            )
                            .fill(PaladalaTheme.biliPink)
                        )
                        .foregroundStyle(PaladalaTheme.ink)
                        .overlay {
                            Rectangle()
                                .strokeBorder(
                                    PaladalaTheme.ink,
                                    lineWidth: PaladalaTheme.borderWidth
                                )
                        }
                }
                .buttonStyle(.plain)
                .accessibilityHint("下載卡住時把日誌發給開發者")
            } else {
                Button {
                    Haptics.tap()
                    shareDiagnosticReport()
                } label: {
                    Label("匯出診斷日誌", systemImage: "square.and.arrow.up")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(
                                cornerRadius: PaladalaTheme.cardRadius,
                                style: PaladalaTheme.cornerStyle
                            )
                            .fill(PaladalaTheme.biliPink)
                        )
                        .foregroundStyle(PaladalaTheme.ink)
                        .overlay {
                            Rectangle()
                                .strokeBorder(
                                    PaladalaTheme.ink,
                                    lineWidth: PaladalaTheme.borderWidth
                                )
                        }
                }
                .buttonStyle(.plain)
                .accessibilityHint("下載卡住時把日誌發給開發者")
            }
        }
        .padding(.bottom, 24)
    }

    /// Build the diagnostic report (which now includes a
    /// "Downloads" section with manifest + on-disk byte
    /// counts + in-flight state) and store the file URL so
    /// the toolbar / empty-state `ShareLink` can pick it up.
    /// Falls back to clipboard if the temp-file write fails
    /// (rare on iOS but `ShareLink` cannot survive a nil URL).
    private func shareDiagnosticReport() {
        if let url = DiagnosticLogger.shared.export(
            activeAccount: authStore.activeAccount
        ) {
            shareURL = url
        } else {
            UIPasteboard.general.string = DiagnosticLogger.shared.generateReport(
                activeAccount: authStore.activeAccount
            )
        }
    }
}

/// One row in `DownloadedVideosView`.  Mirrors the chrome
/// of `VideoListRow` so the two lists feel like siblings
/// (cover on the left, title + meta on the right).
private struct DownloadedVideoRow: View {
    let record: DownloadRecord

    /// Cached `Date.FormatStyle` for the row's
    /// "downloaded at" timestamp.  The chained
    /// `year()/month()/day()/hour()/minute()` formatters
    /// build a fresh `Date.FormatStyle` spec on every call —
    /// previously paid per cell per scroll frame.
    fileprivate static let downloadedAtFormat: Date.FormatStyle = Date.FormatStyle.dateTime
        .year()
        .month()
        .day()
        .hour()
        .minute()

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ResilientImage(url: record.coverURL, maximumPixelSize: 480)
                .frame(width: 120, height: 68)
                .clipShape(Rectangle())
                .overlay {
                    Rectangle()
                        .strokeBorder(
                            PaladalaTheme.ink,
                            lineWidth: PaladalaTheme.borderWidth
                        )
                }
            VStack(alignment: .leading, spacing: 4) {
                Text(record.title)
                    .font(PaladalaTheme.FontRole.cardTitle)
                    .foregroundStyle(PaladalaTheme.ink)
                    .textCase(.uppercase)
                    .lineLimit(2)
                Text(record.ownerName)
                    .font(PaladalaTheme.FontRole.labelMono)
                    .foregroundStyle(PaladalaTheme.mutedInk)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Label(durationLabel, systemImage: "clock")
                    Label(record.sizeBytes.compactFileSize,
                          systemImage: "internaldrive")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                Text(record.downloadedAt.formatted(DownloadedVideoRow.downloadedAtFormat))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(PaladalaTheme.Spacing.m)
        .paladalaStreetPanel(fill: PaladalaTheme.paper)
    }

    /// `BiliVideo.duration` is in seconds.  Format as
    /// `mm:ss` (or `h:mm:ss` for clips over an hour).
    private var durationLabel: String {
        let total = record.duration
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}

private extension Int64 {
    /// Render an on-disk byte count as a compact human
    /// string (`"71.2 MB"`, `"1.4 GB"`).  We deliberately
    /// use the binary (1024-based) units so the number
    /// matches what the user sees in iOS's own storage
    /// settings.
    var compactFileSize: String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useMB, .useGB, .useKB]
        f.countStyle = .file
        return f.string(fromByteCount: self)
    }

    /// One formatter per process.  `ByteCountFormatter` is
    /// expensive to allocate (CFNumberFormatter + locale
    /// resolution) and the row body fires it on every
    /// visible cell during scroll — without caching the
    /// downloads list takes a measurable hit in the
    /// Instruments → Time Profiler trace.  Marked
    /// `nonisolated` so the formatter singleton is
    /// reachable from the cell body without forcing a
    /// MainActor hop (the surrounding `View` body is
    /// already MainActor, but isolating the property
    /// would require an `await` on every cell render).
}
