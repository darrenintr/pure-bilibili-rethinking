//
//  DeepDiagnosticReportView.swift
//  Paladala
//
//  Dedicated screen for the "深度诊断报告" row in
//  `ProfileSettingsView`.  The row was a placeholder for a
//  long time — the actual report generation has always
//  lived in `DiagnosticLogger.generateReport(...)`, but the
//  user-facing entry point was disabled.
//
//  This view is intentionally different from `LogViewerView`:
//  * No scrolling event list — the goal is to produce and
//    share the report, not to read it in-app.
//  * One big primary action: generate + share. The report
//    contains everything an engineer needs to debug (system
//    info, lifecycle, network/session, all diagnostic
//    events, last 60 download events, DownloadStore
//    manifest snapshot, in-flight DownloadManager state,
//    manifest existence + on-disk byte counts, and the tail
//    of the in-memory bpLog buffer).
//  * Summary cards make the "what's in the report" promise
//    visible before the user commits to sharing.
//  * Falls back to UIPasteboard if the temp-file write
//    fails — the same fallback the LogViewer export uses.
//
//

import SwiftUI
import UIKit

struct DeepDiagnosticReportView: View {
    @EnvironmentObject private var authStore: AuthStore

    /// Lazily-prepared report URL.  We delay building it
    /// until the user taps "导出深度诊断报告", because
    /// `DiagnosticLogger.export` writes to the temp directory
    /// (which is fine but not free).  Once `shareURL` is
    /// non-nil the primary action flips to a `ShareLink`;
    /// if the temp-file write fails we copy the report to
    /// the clipboard instead.
    @State private var shareURL: URL? = nil
    @State private var generating = false
    @State private var copyToast: String? = nil

    var body: some View {
        List {
            Section {
                summaryCards
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
            }

            Section {
                if let shareURL {
                    // Once the URL is prepared, the system
                    // `ShareLink` takes over — gives AirDrop /
                    // Save-to-Files / Mail / Messages for free
                    // without an `UIActivityViewController`
                    // bridge.
                    ShareLink(item: shareURL) {
                        HStack {
                            Image(systemName: "square.and.arrow.up.on.square")
                            Text("匯出深度診斷報告")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                } else {
                    Button {
                        Haptics.tap()
                        generateAndShare()
                    } label: {
                        HStack {
                            if generating {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "square.and.arrow.up.on.square")
                            }
                            Text("匯出深度診斷報告")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                    .disabled(generating)
                }
            } header: {
                Text("操作")
            } footer: {
                Text("報告包含系統資訊、生命週期事件、最近 60 條下載日誌、DownloadStore 清單快照、下載中狀態、磁碟位元組數與最近 100 行 bpLog。分享給開發者可直接定位下載卡頓 / 播放失敗 / 推薦異常等問題。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button {
                    Haptics.tap()
                    copyReportToClipboard()
                } label: {
                    Label("複製完整報告到剪貼簿", systemImage: "doc.on.clipboard")
                }
                .disabled(generating)
            } header: {
                Text("備用方案")
            } footer: {
                Text("如果分享面板無法使用，可直接複製完整報告文字並貼上到對話中傳送。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .scrollContentBackground(.hidden)
        .listStyle(.plain)
        .background(PaladalaTheme.canvas)
        .navigationTitle("深度診斷報告")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) {
            if let copyToast {
                Text(copyToast)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(
                            cornerRadius: PaladalaTheme.cardRadius,
                            style: PaladalaTheme.cornerStyle
                        )
                        .fill(Color.black.opacity(0.78))
                    )
                    .overlay {
                        Rectangle().strokeBorder(.white, lineWidth: 1)
                    }
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: copyToast)
        .task {
            // Rehydrate the disk-resident log so the summary
            // counts match the data the user actually wants
            // to share — without this, opening the screen
            // immediately after a launch would show zero
            // events because the in-memory ring hasn't been
            // populated yet.
            DeviceInfo.shared.startIfNeeded()
        }
    }

    // MARK: - summary cards

    /// Three small cards that summarise what the report will
    /// contain.  Counts are read live from the shared stores
    /// so they reflect the current app state, not a stale
    /// snapshot.
    private var summaryCards: some View {
        let diagCount = DiagnosticLogger.shared.events.count
        let dlRecords = DownloadStore.shared.records.count
        let inFlight = DownloadManager.shared.stateByBvid
            .filter { $0.value.isDownloading }
            .count
        return VStack(spacing: 8) {
            summaryRow(
                icon: "doc.text.magnifyingglass",
                title: "診斷事件",
                value: "\(diagCount) 條"
            )
            summaryRow(
                icon: "arrow.down.circle",
                title: "已下載影片",
                value: "\(dlRecords) 個"
            )
            summaryRow(
                icon: "arrow.triangle.2.circlepath",
                title: "下載中",
                value: "\(inFlight) 個"
            )
        }
    }

    private func summaryRow(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3.weight(.black))
                .foregroundStyle(PaladalaTheme.ink)
                .frame(width: 28)
            Text(title)
                .font(PaladalaTheme.FontRole.cardTitle)
                .foregroundStyle(PaladalaTheme.ink)
            Spacer()
            Text(value)
                .font(PaladalaTheme.FontRole.labelMono)
                .foregroundStyle(PaladalaTheme.mutedInk)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .paladalaStreetPanel(fill: PaladalaTheme.paper)
    }

    // MARK: - actions

    /// Build the deep report, write it to the temp dir, and
    /// pop the iOS share sheet.  Falls back to clipboard if
    /// the temp-file write fails (the same fallback the
    /// in-app log viewer uses).
    private func generateAndShare() {
        generating = true
        defer { generating = false }
        if let url = DiagnosticLogger.shared.export(
            activeAccount: authStore.activeAccount
        ) {
            shareURL = url
        } else {
            copyReportToClipboard()
        }
    }

    /// Copy the report text to the clipboard and flash a
    /// toast.  Used as the primary export fallback when the
    /// temp-file write fails AND as the secondary action
    /// behind the "备用方案" button.
    private func copyReportToClipboard() {
        let report = DiagnosticLogger.shared.generateReport(
            activeAccount: authStore.activeAccount
        )
        UIPasteboard.general.string = report
        flashToast("已複製 (\(report.count) 字元)")
    }

    private func flashToast(_ message: String) {
        copyToast = message
        Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            await MainActor.run {
                if copyToast == message { copyToast = nil }
            }
        }
    }
}
