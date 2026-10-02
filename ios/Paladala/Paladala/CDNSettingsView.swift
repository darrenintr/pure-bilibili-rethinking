import SwiftUI

struct CDNSettingsView: View {
    @StateObject private var manager = CDNManager.shared
    @ObservedObject private var pluginManager = PluginManager.shared
    @State private var nodes: [CDNManager.Node] = []
    @State private var selectedRegion = "全部"
    @AppStorage(CDNManager.enabledKey) private var enabled = false
    /// "Auto-pick the lowest-latency host after a speed test
    /// finishes" — the user-facing half of the
    /// "强制使用延迟最低 + 速度最大的端点" mode. Off by
    /// default so the first install still behaves as a
    /// manual picker; users opt in once they trust the
    /// test. Backed by `paladala.cdn.autoPickEnabled` in
    /// `UserDefaults` via the `autoPickEnabled` computed
    /// property on `CDNManager`.
    @AppStorage(CDNManager.autoPickEnabledKey) private var autoPickEnabled = false

    private var regions: [String] { ["全部"] + Array(Set(nodes.map(\.region))).sorted() }
    private var visibleNodes: [CDNManager.Node] {
        selectedRegion == "全部" ? nodes : nodes.filter { $0.region == selectedRegion }
    }

    /// The first enabled plugin's CDN pin, or `nil` if no
    /// plugin is overriding the host. Read on every render so
    /// toggling a plugin in the "插件中心" screen flips this
    /// row without a manual refresh.
    private var activePluginPin: String? {
        for plugin in pluginManager.plugins where plugin.enabled {
            if let host = plugin.rules?.cdn?.pinHost, !host.isEmpty {
                return host
            }
        }
        return nil
    }

    var body: some View {
        List {
            // Plugin-status banner. Surfaces the *effective*
            // host the player is using, including plugin pins
            // that the user would otherwise have to dig into
            // 插件中心 to discover. The banner is informational
            // (not actionable) so a non-VIP user who enabled
            // the bundled `cdn-bj-pin` plugin years ago
            // understands why their host is not the one they
            // picked in the manual picker below.
            Section {
                HStack(spacing: 10) {
                    Image(systemName: activePluginPin != nil ? "puzzlepiece.extension.fill" : "antenna.radiowaves.left.and.right")
                        .foregroundStyle(activePluginPin != nil ? PaladalaTheme.biliPink : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        if let pin = activePluginPin {
                            Text("外掛已強制切換節點")
                                .font(PaladalaTheme.FontRole.labelMono)
                            Text(pin)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        } else if enabled, !manager.selectedHost.isEmpty {
                            Text("手動節點生效中")
                                .font(PaladalaTheme.FontRole.labelMono)
                            Text(manager.selectedHost)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        } else {
                            Text("使用 B 站預設節點")
                                .font(PaladalaTheme.FontRole.labelMono)
                            Text("無外掛 / 未啟用手動切換")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
            } header: {
                Text("當前生效")
            } footer: {
                Text("優先順序：外掛強制 > 手動選擇 > B 站預設。外掛 pin 在「外掛中心」管理。")
            }
            Section {
                Toggle("啟用手動 CDN", isOn: $enabled)
                Text("按照 CCB 的思路，僅替換播放地址中的媒體節點，保留 B 站簽名引數。切換後重新開啟影片或點選重試即可生效。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("當前節點") {
                HStack {
                    Text(manager.selectedHost).font(.subheadline.monospaced())
                    Spacer()
                    if enabled { Text("已啟用").foregroundStyle(.green).font(.caption) }
                }
                Picker("地區", selection: $selectedRegion) {
                    ForEach(regions, id: \.self) { Text($0).tag($0) }
                }
            }
            Section {
                Toggle(isOn: $autoPickEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("自動測速切換")
                        Text("每次測速後自動把節點切到延遲最低的端點。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                // The "current lowest" status row is the
                // visible feedback that the auto-pick pathway
                // fired. The data comes from the most recent
                // `test(nodes:)` run, which is also what
                // `writeAkamTesterFile` writes to
                // `Library/Caches/paladala/akamTester.txt`
                // for cross-checking against an external
                // `miyouzi/akamTester` Python run.
                if let best = manager.lowestDelayHost {
                    HStack(spacing: 8) {
                        Image(systemName: "bolt.fill")
                            .foregroundStyle(.yellow)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("已切換到 \(best)")
                                .font(.subheadline.monospaced())
                            if let ms = manager.results.first(where: { $0.node.host == best })?.latencyMs {
                                Text("TLS 握手延遲 \(ms) ms")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                }
            } header: { Text("自動選優") } footer: {
                // The probe uses a real TCP + TLS handshake
                // (Network.framework + explicit SNI) — see
                // `CDNAkamProbe.swift`. It is *not* a Range /
                // HEAD probe of a media URL, so the latency
                // number is closer to "what my first
                // `AVPlayer` segment fetch will feel like"
                // than a typical HTTP probe. Akamai anycast
                // still routes by system DNS — the iOS app
                // doesn't pin a specific IP (URLSession
                // can't override SNI), so the host-keyed
                // auto-pick is the strongest signal we can
                // hand to the player today.
                Text("測速使用 Network.framework 真實 TCP + TLS 握手（含 SNI），與 miyouzi/akamTester 思路一致；延遲最低的端點會被自動設為下一段播放的預設節點。")
            }
            Section {
                Button {
                    Task { await manager.test(nodes: Array(visibleNodes.prefix(40))) }
                } label: {
                    Label(manager.isTesting ? "測速中…" : "測試當前列表", systemImage: "speedometer")
                }
                .disabled(manager.isTesting || visibleNodes.isEmpty)
                // Node rows. The list always renders the
                // current `visibleNodes` (CCB feed when
                // reachable, `fallbackNodes` otherwise) so the
                // picker is never empty after a fetch failure —
                // a previous version of this section gated the
                // rows on `!manager.results.isEmpty`, which
                // meant the fallback list had no UI surface
                // (nothing to select, no way to recover without
                // an external speed test). Probing the network
                // is now an *enhancement* of the row's status
                // chip, not a prerequisite for showing the row.
                ForEach(visibleNodes) { node in
                    Button {
                        manager.selectedHost = node.host
                    } label: {
                        NodeRow(
                            node: node,
                            isSelected: manager.selectedHost == node.host,
                            probe: manager.results.first { $0.node.id == node.id }
                        )
                    }
                    .buttonStyle(.plain)
                }
            } header: { Text("測速與選擇") } footer: {
                Text("每行顯示對應節點的最新 TLS 握手延遲。綠色 < 150ms，橙色 < 400ms，紅色 ≥ 400ms 或不可達。")
            }
        }
        .navigationTitle("CDN 播放源")
        .task { nodes = await manager.nodes() }
    }
}

/// One CDN host row in `CDNSettingsView`. Renders the host
/// name + region and a status chip on the trailing side —
/// either a latency probe (when the user has run
/// `CDNManager.test`) or a "未测速" placeholder. Kept private
/// to this file because the row is purely a presentation
/// concern; `CDNManager` does not need to know about it.
private struct NodeRow: View {
    let node: CDNManager.Node
    let isSelected: Bool
    /// Latest probe result for this host, if any. The
    /// `CDNManager.SpeedResult.id` is the `Node.id` so the
    /// `first { ... }` lookup is O(n) but `n` is small
    /// (≤ 40 hosts in the typical speed-test slice).
    let probe: CDNManager.SpeedResult?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(node.host).font(.caption.monospaced())
                Text(node.region).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            statusChip
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(PaladalaTheme.biliPink)
            }
        }
    }

    @ViewBuilder
    private var statusChip: some View {
        if let probe {
            if let ms = probe.latencyMs {
                Text("\(ms) ms")
                    .font(.caption2.monospaced())
                    .foregroundStyle(ms < 150 ? .green : ms < 400 ? .orange : .red)
            } else {
                Text("不可達")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        } else {
            Text("未測速")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
