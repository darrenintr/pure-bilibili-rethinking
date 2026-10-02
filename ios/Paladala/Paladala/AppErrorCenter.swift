import Combine
import Foundation
import SwiftUI

/// Stable, user-facing categories used by the app-wide error pipeline.
/// Views and view models should report the underlying `Error` instead of
/// branching on transport-specific details at every call site.
enum AppErrorKind: String, Sendable {
    case network
    case authentication
    case rateLimited
    case server
    case data
    case playback
    case storage
    case unknown
}

/// A normalized error safe to show to the user and useful in diagnostics.
struct AppErrorDescriptor: Equatable, Sendable {
    let kind: AppErrorKind
    let title: String
    let message: String
    let isRetryable: Bool

    static func describe(
        _ error: Error,
        fallbackMessage: String? = nil
    ) -> AppErrorDescriptor? {
        guard !isCancellation(error) else { return nil }

        if let apiError = error as? BilibiliAPIError {
            switch apiError {
            case .sessionExpired:
                return AppErrorDescriptor(
                    kind: .authentication,
                    title: "登入已過期",
                    message: fallbackMessage ?? "請重新登入後繼續。",
                    isRetryable: false
                )
            case .http:
                return AppErrorDescriptor(
                    kind: .network,
                    title: "網路請求失敗",
                    message: fallbackMessage ?? "請檢查網路連線後重試。",
                    isRetryable: true
                )
            case .api(let message):
                return AppErrorDescriptor(
                    kind: .server,
                    title: "服務暫時不可用",
                    message: fallbackMessage ?? message,
                    isRetryable: true
                )
            case .noPlayableFormat:
                return AppErrorDescriptor(
                    kind: .playback,
                    title: "影片暫時無法播放",
                    message: fallbackMessage ?? "當前影片沒有可用的播放源。",
                    isRetryable: true
                )
            case .vipRequired, .vipExpired:
                // Both land in `.playback` because the
                // user-visible symptom is the same — the
                // upstream refused to hand us a stream
                // for the requested quality. The toolbar
                // also raises a dedicated upgrade sheet
                // (see `VipUpgradeSheetModifier`); this
                // descriptor is the inline banner fallback
                // when the sheet has been dismissed but
                // the error is still on the model.
                return AppErrorDescriptor(
                    kind: .playback,
                    title: "需要大會員",
                    message: fallbackMessage ?? "該清晰度/音質需要大會員，開通後即可解鎖。",
                    isRetryable: false
                )
            case .invalidURL, .missingData, .missingIdentity:
                return AppErrorDescriptor(
                    kind: .data,
                    title: "內容處理失敗",
                    message: fallbackMessage ?? "收到的內容不完整，請稍後重試。",
                    isRetryable: true
                )
            }
        }

        if let playbackError = error as? PlayerPlaybackError {
            return AppErrorDescriptor(
                kind: .playback,
                title: playbackError.title,
                message: fallbackMessage ?? playbackError.message,
                isRetryable: true
            )
        }

        if let urlError = error as? URLError {
            let rateLimited = urlError.code == .resourceUnavailable
            return AppErrorDescriptor(
                kind: rateLimited ? .rateLimited : .network,
                title: rateLimited ? "請求過於頻繁" : "網路連線異常",
                message: fallbackMessage ?? networkMessage(for: urlError),
                isRetryable: true
            )
        }

        if error is DecodingError {
            return AppErrorDescriptor(
                kind: .data,
                title: "內容解析失敗",
                message: fallbackMessage ?? "收到的內容格式異常，請稍後重試。",
                isRetryable: true
            )
        }

        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            return AppErrorDescriptor(
                kind: .storage,
                title: "本地資料操作失敗",
                message: fallbackMessage ?? "無法讀取或儲存本地資料，請稍後重試。",
                isRetryable: true
            )
        }

        return AppErrorDescriptor(
            kind: .unknown,
            title: "操作未完成",
            message: fallbackMessage ?? "發生了意外錯誤，請稍後重試。",
            isRetryable: true
        )
    }

    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    private static func networkMessage(for error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet:
            return "當前沒有網路連線，請聯網後重試。"
        case .timedOut:
            return "請求超時，請稍後重試。"
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return "暫時無法連線伺服器，請稍後重試。"
        case .networkConnectionLost:
            return "網路連線已中斷，請重試。"
        default:
            return "請檢查網路連線後重試。"
        }
    }
}

/// Main-actor error router used across the app. It provides one mapping,
/// logging, deduplication, and presentation path while allowing screens to
/// retain inline error states for recoverable list-loading failures.
@MainActor
final class AppErrorCenter: ObservableObject {
    struct Presentation: Identifiable {
        let id = UUID()
        let descriptor: AppErrorDescriptor
        let context: String
        let recoveryLabel: String?
        let recovery: (@MainActor () -> Void)?
    }

    static let shared = AppErrorCenter()

    @Published private(set) var current: Presentation?

    private var pending: [Presentation] = []
    private var recentlyPresented: [String: Date] = [:]
    private let deduplicationInterval: TimeInterval
    private let now: () -> Date
    private let maximumPendingCount: Int

    init(
        deduplicationInterval: TimeInterval = 2,
        maximumPendingCount: Int = 3,
        now: @escaping () -> Date = Date.init
    ) {
        self.deduplicationInterval = deduplicationInterval
        self.maximumPendingCount = max(1, maximumPendingCount)
        self.now = now
    }

    /// Normalize and log an error without interrupting the user. This is the
    /// default for list and pagination failures that already have inline UI.
    @discardableResult
    func record(
        _ error: Error,
        context: String,
        fallbackMessage: String? = nil
    ) -> AppErrorDescriptor? {
        guard let descriptor = AppErrorDescriptor.describe(
            error,
            fallbackMessage: fallbackMessage
        ) else { return nil }
        log(descriptor, source: error, context: context, presented: false)
        return descriptor
    }

    /// Normalize, log, and enqueue a global alert. Identical failures from
    /// SwiftUI re-appearance or concurrent requests are coalesced briefly.
    func present(
        _ error: Error,
        context: String,
        fallbackMessage: String? = nil,
        recoveryLabel: String? = nil,
        recovery: (@MainActor () -> Void)? = nil
    ) {
        guard let descriptor = AppErrorDescriptor.describe(
            error,
            fallbackMessage: fallbackMessage
        ) else { return }

        log(descriptor, source: error, context: context, presented: true)
        let fingerprint = "\(descriptor.kind.rawValue)|\(context)|\(descriptor.message)"
        let timestamp = now()
        recentlyPresented = recentlyPresented.filter {
            timestamp.timeIntervalSince($0.value) < deduplicationInterval
        }
        guard recentlyPresented[fingerprint] == nil else { return }
        recentlyPresented[fingerprint] = timestamp

        let presentation = Presentation(
            descriptor: descriptor,
            context: context,
            recoveryLabel: descriptor.isRetryable ? recoveryLabel : nil,
            recovery: descriptor.isRetryable ? recovery : nil
        )
        if current == nil {
            current = presentation
        } else if pending.count < maximumPendingCount {
            pending.append(presentation)
        }
    }

    func dismiss() {
        current = pending.isEmpty ? nil : pending.removeFirst()
    }

    func recover() {
        let action = current?.recovery
        dismiss()
        action?()
    }

    private func log(
        _ descriptor: AppErrorDescriptor,
        source: Error,
        context: String,
        presented: Bool
    ) {
        diagLog(.app, "app.error", details: [
            "kind": descriptor.kind.rawValue,
            "context": context,
            "presented": presented,
            "retryable": descriptor.isRetryable,
            "error": String(describing: source)
        ])
        // Phase 2 fan-out to the Paladala Portal.  Fire-and-
        // forget; the reporter batches + signs + retries on
        // its own actor.  No-op when the toggle is off or the
        // xcconfig secret is empty (gated inside `maybeReport`).
        ErrorSink.maybeReport(descriptor: descriptor, context: context, source: source)
    }
}

private struct AppErrorAlertModifier: ViewModifier {
    @ObservedObject var center: AppErrorCenter

    private var presentation: Binding<AppErrorCenter.Presentation?> {
        Binding(
            get: { center.current },
            set: { newValue in
                if newValue == nil { center.dismiss() }
            }
        )
    }

    func body(content: Content) -> some View {
        content.alert(item: presentation) { item in
            if let recoveryLabel = item.recoveryLabel, item.recovery != nil {
                return Alert(
                    title: Text(item.descriptor.title),
                    message: Text(item.descriptor.message),
                    primaryButton: .default(Text(recoveryLabel)) {
                        center.recover()
                    },
                    secondaryButton: .cancel(Text("關閉")) {
                        center.dismiss()
                    }
                )
            }
            return Alert(
                title: Text(item.descriptor.title),
                message: Text(item.descriptor.message),
                dismissButton: .default(Text("知道了")) {
                    center.dismiss()
                }
            )
        }
    }
}

extension View {
    func appErrorAlerts(_ center: AppErrorCenter) -> some View {
        modifier(AppErrorAlertModifier(center: center))
    }
}
