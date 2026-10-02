import Combine
import Network
import SwiftUI

/// Reachability monitor backed by `NWPathMonitor`. Exposes a single
/// `@Published var isOnline: Bool` that the rest of the app reads via
/// `@EnvironmentObject`.
///
/// The `pathUpdateHandler` is called on a background queue. We hop to
/// `@MainActor` and debounce updates by 400ms so a flapping connection
/// does not flicker the offline banner in the UI. The monitor is
/// started in `init` and cancelled in `deinit`, which is enough for
/// the lifetime of the app (`NetworkMonitor` is a `@StateObject` in
/// `PaladalaApp` and lives as long as the process does).
@MainActor
final class NetworkMonitor: ObservableObject {
    @Published private(set) var isOnline: Bool = true
    /// PR-8 (M8): the active interface type so the player can
    /// auto-cap quality on cellular.  Nil on the very first launch
    /// before the first `NWPath` update lands.  Use `path.usesInterfaceType(.cellular)`
    /// / `.wifi` downstream.
    @Published private(set) var interface: NWInterface.InterfaceType?

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.paladala.network-monitor", qos: .utility)
    private var debounceTask: Task<Void, Never>?
    private var didStart = false

    init() {
        // `NWPathMonitor.start(queue:)` is safe to call from any
        // thread; the path update handler runs on the queue we pass
        // in. We default `isOnline` to `true` because that's the
        // typical device state on first launch — a user with no
        // network on first launch will see the banner pop in after
        // the first path update.
        start()
    }

    deinit {
        monitor.cancel()
    }

    private func start() {
        guard !didStart else { return }
        didStart = true
        monitor.pathUpdateHandler = { [weak self] path in
            let online = (path.status == .satisfied)
            // Pick the dominant interface — `usesInterfaceType(.other)`
            // is a "no claim" state on iOS sim / freshly-booted
            // devices. Prefer Wi-Fi > cellular > wiredEthernet when
            // multiple interfaces are up; nil when none are claimed.
            let iface: NWInterface.InterfaceType? = {
                if path.usesInterfaceType(.wifi) { return .wifi }
                if path.usesInterfaceType(.cellular) { return .cellular }
                if path.usesInterfaceType(.wiredEthernet) { return .wiredEthernet }
                return nil
            }()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.debounceTask?.cancel()
                self.debounceTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    guard let self, !Task.isCancelled else { return }
                    if self.isOnline != online {
                        self.isOnline = online
                        diagLog(.network, "isOnline changed", details: ["online": online])
                    }
                    // PR-8: surface the interface type so the
                    // player / download views can auto-cap quality
                    // on cellular without polling the path itself.
                    if self.interface != iface {
                        self.interface = iface
                    }
                }
            }
        }
        monitor.start(queue: queue)
    }
}

/// Slim offline banner shown at the top of `RootView` when the
/// `NetworkMonitor` reports `isOnline == false`. The opaque signal-pink
/// strip remains readable above every screen without a blur pass. The
/// banner is for *display only* — tapping it is a no-op
/// for now; the user can pull-to-refresh on the feed tabs to retry.
struct OfflineBanner: View {
    @EnvironmentObject private var monitor: NetworkMonitor

    var body: some View {
        if !monitor.isOnline {
            HStack(spacing: 8) {
                Image(systemName: "wifi.slash")
                Text("當前離線 · 顯示快取內容")
                    .font(PaladalaTheme.FontRole.labelMono)
            }
            .foregroundStyle(PaladalaTheme.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(PaladalaTheme.biliPink)
            .overlay {
                Rectangle()
                    .strokeBorder(
                        PaladalaTheme.ink,
                        lineWidth: PaladalaTheme.borderWidth
                    )
            }
            .background {
                Rectangle()
                    .fill(PaladalaTheme.ink)
                    .offset(
                        x: PaladalaTheme.hardShadowOffset,
                        y: PaladalaTheme.hardShadowOffset
                    )
            }
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("當前離線,顯示快取內容")
        }
    }
}
