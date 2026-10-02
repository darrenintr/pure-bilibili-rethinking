import SwiftUI

struct SponsorBlockSettingsView: View {
    @ObservedObject private var manager = SponsorBlockManager.shared
    @State private var showSubmitReport = false
    @State private var reportStartTime = ""
    @State private var reportEndTime = ""
    @State private var reportCategory: SponsorCategory = .sponsor
    @State private var isSubmitting = false
    @State private var submitMessage: String?
    @State private var editingServerURL = ""

    var body: some View {
        List {
            masterToggleSection
            if manager.config.isEnabled {
                categorySection
                actionSection
                statsSection
                advancedSection
            }
        }
        .scrollContentBackground(.hidden)
        .listStyle(.plain)
        .background(PaladalaTheme.canvas)
        .navigationTitle("攔截恰飯")
        .sheet(isPresented: $showSubmitReport) { submitReportSheet }
    }

    // MARK: - Master toggle

    private var masterToggleSection: some View {
        Section {
            Toggle(isOn: $manager.config.isEnabled) {
                Label("啟用攔截恰飯", systemImage: "shield.lefthalf.filled")
                    .tint(PaladalaTheme.SemanticColor.accent)
                    .font(.subheadline.weight(.medium))
            }
            .tint(PaladalaTheme.SemanticColor.accent)

            if manager.config.isEnabled {
                Toggle(isOn: $manager.config.autoSkip) {
                    Label("自動跳過", systemImage: "forward.fill")
                        .font(.subheadline.weight(.medium))
                }
                .tint(PaladalaTheme.SemanticColor.accent)
            }
        } footer: {
            Text("播放影片時自動查詢社群標註的贊助/恰飯片段，並跳過或標記。")
        }
    }

    // MARK: - Categories

    private var categorySection: some View {
        Section {
            ForEach(SponsorCategory.allCases) { category in
                Toggle(isOn: Binding(
                    get: { manager.config.categories.contains(category) },
                    set: { isOn in
                        if isOn {
                            manager.config.categories.append(category)
                        } else {
                            manager.config.categories.removeAll { $0 == category }
                        }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(category.displayName)
                            .font(.subheadline)
                        Text(categoryHint(category))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(PaladalaTheme.SemanticColor.accent)
            }
        } header: {
            Label("攔截類別", systemImage: "line.3.horizontal.decrease.circle")
        }
    }

    // MARK: - Actions

    private var actionSection: some View {
        Section {
            Button {
                showSubmitReport = true
            } label: {
                Label("上報恰飯片段", systemImage: "exclamationmark.bubble.fill")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(!manager.isEnabled)

            if !manager.segments.isEmpty {
                NavigationLink {
                    SegmentListView(segments: manager.segments)
                } label: {
                    Label("已載入 \(manager.segments.count) 個片段", systemImage: "list.bullet")
                }
            }
        } header: {
            Label("資料操作", systemImage: "square.and.pencil")
        }
    }

    // MARK: - Stats

    private var statsSection: some View {
        Group {
            if manager.totalTimeSaved > 0 || manager.segments.isEmpty == false {
                Section {
                    HStack {
                        Label("已跳過", systemImage: "clock.badge.checkmark")
                        Spacer()
                        Text("\(manager.skippedCount) 個片段")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Label("累積節省", systemImage: "hourglass")
                        Spacer()
                        Text(formatTime(manager.totalTimeSaved))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                } header: {
                    Label("統計", systemImage: "chart.bar.fill")
                }
            }
        }
    }

    // MARK: - Advanced

    private var advancedSection: some View {
        Section {
            Picker("最低票數", selection: $manager.config.minVotes) {
                Text("不限").tag(-1)
                Text("≥ 1 票").tag(1)
                Text("≥ 3 票").tag(3)
                Text("≥ 5 票").tag(5)
            }

            HStack {
                Label("伺服器", systemImage: "server.rack")
                    .font(.subheadline)
                Spacer()
                TextField("伺服器地址", text: $manager.config.serverURL)
                    .font(PaladalaTheme.FontRole.labelMono)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 8)
                    .frame(minHeight: 36)
                    .overlay {
                        Rectangle()
                            .strokeBorder(
                                PaladalaTheme.ink,
                                lineWidth: PaladalaTheme.hairlineWidth
                            )
                    }
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(.secondary)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
            }
        } header: {
            Label("高階設定", systemImage: "gearshape.2")
        } footer: {
            Text("預設伺服器為 BiliSponsorBlock 映象站 (bsbsb.top)，支援 SponsorBlock 官方 API 相容的任意伺服器。")
        }
    }

    // MARK: - Report sheet

    private var submitReportSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("開始時間（秒）", text: $reportStartTime)
                        .keyboardType(.decimalPad)
                        .textFieldStyle(.plain)
                        .padding(10)
                        .overlay {
                            Rectangle()
                                .strokeBorder(
                                    PaladalaTheme.ink,
                                    lineWidth: PaladalaTheme.borderWidth
                                )
                        }
                    TextField("結束時間（秒）", text: $reportEndTime)
                        .keyboardType(.decimalPad)
                        .textFieldStyle(.plain)
                        .padding(10)
                        .overlay {
                            Rectangle()
                                .strokeBorder(
                                    PaladalaTheme.ink,
                                    lineWidth: PaladalaTheme.borderWidth
                                )
                        }
                } header: {
                    Label("時間範圍", systemImage: "timer")
                } footer: {
                    Text("填寫恰飯片段的起止時間點（秒），例如從 30.5 秒到 45.2 秒。")
                }

                Section {
                    Picker("類別", selection: $reportCategory) {
                        ForEach(SponsorCategory.allCases) { category in
                            Label(category.displayName, systemImage: categoryIcon(category)).tag(category)
                        }
                    }
                } header: {
                    Label("片段類別", systemImage: "tag")
                }

                Section {
                    Button(action: submitReport) {
                        HStack {
                            Spacer()
                            if isSubmitting {
                                ProgressView()
                            } else {
                                Text("提交到伺服器")
                                    .fontWeight(.semibold)
                            }
                            Spacer()
                        }
                    }
                    .listRowBackground(PaladalaTheme.biliPink)
                    .disabled(isSubmitting || !reportValid)
                }

                if let msg = submitMessage {
                    Section {
                        Label(msg, systemImage: msg.contains("成功") ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(
                                msg.contains("成功")
                                    ? PaladalaTheme.ink
                                    : PaladalaTheme.biliPink
                            )
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(PaladalaTheme.canvas)
            .navigationTitle("上報恰飯片段")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showSubmitReport = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .paladalaSheetGlass()
    }

    private var reportValid: Bool {
        guard let start = Double(reportStartTime), let end = Double(reportEndTime) else { return false }
        return start >= 0 && end > start
    }

    private func submitReport() {
        guard let start = Double(reportStartTime), let end = Double(reportEndTime), end > start else {
            submitMessage = "請填寫有效的時間範圍"
            return
        }

        isSubmitting = true
        submitMessage = nil

        Task {
            defer { isSubmitting = false }
            do {
                try await manager.submitSegment(
                    videoID: manager.lastVideoID ?? "",
                    cid: nil,
                    category: reportCategory.rawValue,
                    startTime: start,
                    endTime: end,
                    videoDuration: 0
                )
                submitMessage = "提交成功！感謝您的貢獻。"
                reportStartTime = ""
                reportEndTime = ""
            } catch {
                submitMessage = "提交失敗：\(error.localizedDescription)"
            }
        }
    }

    // MARK: - Helpers

    private func categoryIcon(_ category: SponsorCategory) -> String {
        switch category {
        case .sponsor: return "dollarsign.circle"
        case .intro: return "play.circle"
        case .outro: return "stop.circle"
        case .interaction: return "hand.thumbsup"
        case .selfpromo: return "person.crop.circle"
        case .musicOfftopic: return "music.note"
        case .preview: return "forward.end"
        case .filler: return "tray.full"
        }
    }

    private func categoryHint(_ category: SponsorCategory) -> String {
        switch category {
        case .sponsor: return "贊助商廣告、貼片廣告、口播廣告"
        case .intro: return "影片開場的動畫或片頭"
        case .outro: return "影片結尾的鳴謝或片尾"
        case .interaction: return "求贊、求三連、關注提醒"
        case .selfpromo: return "UP 主推薦自己的其他內容"
        case .musicOfftopic: return "音樂影片中的非音樂部分"
        case .preview: return "下集預告或內容回顧"
        case .filler: return "湊數或填充內容"
        }
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = Int(seconds) / 60 % 60
        let secs = Int(seconds) % 60
        if hours > 0 { return "\(hours) 小時 \(minutes) 分鐘" }
        if minutes > 0 { return "\(minutes) 分鐘 \(secs) 秒" }
        return "\(secs) 秒"
    }
}

// MARK: - Segment list

private struct SegmentListView: View {
    let segments: [SponsorSegment]

    var body: some View {
        List(segments) { segment in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label(
                        SponsorCategory(rawValue: segment.category)?.displayName ?? segment.category,
                        systemImage: categoryIcon(SponsorCategory(rawValue: segment.category))
                    )
                    .font(.subheadline.weight(.semibold))
                    Spacer()
                    if let votes = segment.votes {
                        Text("\(votes) 票")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(formatTimeRange(segment.startTime, segment.endTime))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
        .navigationTitle("片段列表")
    }

    private func categoryIcon(_ category: SponsorCategory?) -> String {
        guard let category else { return "questionmark.circle" }
        switch category {
        case .sponsor: return "dollarsign.circle"
        case .intro: return "play.circle"
        case .outro: return "stop.circle"
        case .interaction: return "hand.thumbsup"
        case .selfpromo: return "person.crop.circle"
        case .musicOfftopic: return "music.note"
        case .preview: return "forward.end"
        case .filler: return "tray.full"
        }
    }

    private func formatTimeRange(_ start: Double, _ end: Double) -> String {
        let s = Int(start)
        let e = Int(end)
        return "\(s / 60):\(String(format: "%02d", s % 60)) → \(e / 60):\(String(format: "%02d", e % 60))"
    }
}
