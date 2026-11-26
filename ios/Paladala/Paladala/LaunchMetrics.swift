import Foundation
import os

/// Public milestones emitted during the cold-start path.
///
/// Each value is the raw event name (also used as the signpost suffix
/// and the diagnostic-log message key). Adding a new case here is the
/// only edit needed to wire a new milestone — `mark(_:)` handles the
/// rest (signpost emit, diagnostic log, in-memory buffer, dump).
/// Public milestones emitted during the cold-start path.
///
/// Each value's string form (used as the signpost suffix, the
/// diagnostic-log message key, and the gate / milestone key) is
/// produced by `LaunchMetrics.key(for:)` — we don't use a String
/// raw type because the `.firstTabInteractive(tag:)` case carries
/// an associated value, and Swift forbids combining `RawRepresentable`
/// with associated-value cases. The case names here are the source
/// of truth for the string form; see `key(for:)` for the exact
/// mapping.
enum LaunchEvent {
    case appInitStart
    case appInitComplete
    case appDelegateStart
    case appDelegateComplete
    case firstRootViewAppeared
    case firstFeedNetworkStart
    case firstFeedNetworkComplete
    // PR-A Task 6: per-tab and cache-seed milestones. The `tag` on
    // `firstTabInteractive` is appended to the event key by
    // `key(for:)` so each tag fires independently.
    case firstFeedCached
    case firstTabInteractive(tag: MainTab)
    case proxyListenerRequested
    case proxyListenerReady
    // Cold-launch CDN speed-test (auto-probe of the B站 media
    // edges via `CDNManager.ensureProbedOnLaunch()`). Bookends
    // the off-critical-path `Task.detached` in `PaladalaApp.init`
    // so the cold-start JSONL shows how long the network probe
    // took without polluting the launch-marker timeline.
    case cdnProbeRequested
    case cdnProbeReady

    /// The associated `tag` for cases that carry one. PR-A's plan
    /// called this out as a verify-before-saving step — the real
    /// type in this codebase is `MainTab`, not `RootTab`.
    var tag: MainTab? {
        if case let .firstTabInteractive(t) = self { return t }
        return nil
    }
}

/// One row in the cold-start JSONL dump. `elapsedMS` is measured from
/// the first `mark(_:)` call (anchored to `Mach_absolute_time()`) so
/// every milestone is a self-contained wall-clock value.
struct LaunchMilestone: Codable {
    let event: String
    let elapsedMS: Double
    let thread: String

    /// Test-facing alias for `event`. The PR-A plan's unit tests
    /// assert on `eventName`; existing `cold-start.jsonl` readers
    /// rely on the raw `event` field. Both point at the same
    /// underlying value.
    var eventName: String { event }
}

/// Singleton, allocation-light launcher for cold-start instrumentation.
///
/// Why one sink for everything?
/// -----------------------------
/// The launch path is the only time we cannot afford to add
/// dependencies or `await` calls. `LaunchMetrics` is a struct-free,
/// lock-protected singleton whose `mark(_:)` does at most one
/// `mach_absolute_time` read, one allocation (`LaunchMilestone`),
/// one `OSSignposter.event`, and one `DiagnosticLogger.log` —
/// all O(1) and safe to call from any thread.
///
/// Three sinks:
/// 1. `OSSignposter` (subsystem `app.paladala.ios`, category
///    `ColdStart`) — visible in Instruments → Time Profiler
///    (Signposts template) and `xcrun xctrace record`.
/// 2. `DiagnosticLogger.shared.log(.app, …)` — visible in the
///    in-app `LogViewerView` / `DeepDiagnosticReportView`, filter
///    by category `APP`.
/// 3. In-memory `[LaunchMilestone]` buffer + `dumpColdStartReport()`
///    — writes JSONL to `Application Support/Paladala/cold-start.jsonl`
///    when the `PALADALA_COLD_START_DUMP=1` env var is set, so the
///    diagnostic dump is opt-in and never grows on devices that
///    haven't asked for it.
///
/// Subsystem string
/// ----------------
/// We use the literal `app.paladala.ios` rather than the bundle
/// identifier so the signpost is filterable in Instruments even
/// before `Bundle.main` is fully resolved (the signposter is a
/// `static let` initialised lazily on first access). The subsystem
/// has to be a compile-time constant.
final class LaunchMetrics: @unchecked Sendable {
    // PR-C Task 5: `nonisolated` so callers from any
    // isolation domain (URLSession callback, BGTaskScheduler,
    // app delegate) can read the singleton's static without
    // first hopping to a specific actor.  The init is
    // private, the static is a `let`, and the only state
    // that needs to be guarded is `milestones` / `eventNames`
    // — both protected by an internal `NSLock`.
    nonisolated static let shared = LaunchMetrics()

    /// The `OSLog` handle for the cold-start signpost category.
    /// Shared across all milestones so Instruments shows them
    /// on one timeline. We use the C `os_signpost` API
    /// directly (not the Swift `OSSignposter` class) because
    /// the Swift overlay's `event(_:)` method is not exposed
    /// on the iOS 18.5 SDK the CI runner uses — the C function
    /// has been stable since iOS 12 and works on every SDK.
    private static let coldStartLog = OSLog(
        subsystem: "app.paladala.ios",
        category: "ColdStart"
    )
    private var startMachTime: UInt64 = 0
    private let lock = NSLock()
    /// Internal so PR-A unit tests can read the buffer (`@testable
    /// import` does not grant access to `private`). Production code
    /// does not need to read this — `dumpColdStartReport()` snapshots
    /// it under the lock.
    var milestones: [LaunchMilestone] = []
    /// Set of event names already recorded in this process.  We
    /// gate `mark(_:)` to fire at most once per event per
    /// process — `RootView.onAppear` and the per-tab `.task`
    /// modifiers re-fire on every background → foreground
    /// transition, and without this gate the "first appearance"
    /// milestones would log bogus elapsedMS values of tens of
    /// thousands of ms after a long background.  The cold-start
    /// events themselves (`appInit*`, `appDelegate*`) only
    /// fire once per process by construction, so the gate is
    /// a no-op for them.
    private var firedEvents: Set<String> = []

    // Internal (not private) so tests can build an isolated
    // instance — the shared singleton races the app's own
    // startup milestone emissions and makes assertions on
    // `milestones` non-deterministic.
    init() {}

    /// Record a milestone. Safe to call from any thread. The first
    /// call anchors `startMachTime` to "now"; every subsequent
    /// call within the same process is a delta from that anchor
    /// in milliseconds.  If the same event has already been
    /// recorded in this process, the call is a no-op — see
    /// `firedEvents` above.
    func mark(_ event: LaunchEvent) {
        let now = mach_absolute_time()
        let elapsedMS: Double
        let thread: String
        let milestone: LaunchMilestone

        lock.lock()
        // Gate: skip events that have already fired in this
        // process.  This is the fix for the diagnostic-log bug
        // where `mark(.firstRootViewAppeared)` and
        // `mark(.firstFeedNetwork*)` were logging
        // elapsedMS in the 80–99 second range after a long
        // background, because `RootView.onAppear` and the
        // per-tab `.task` modifiers re-fire on every
        // foreground transition.
        //
        // PR-A Task 6: use the full key (event + tag for
        // firstTabInteractive) so each tab fires independently
        // — using the case name alone would silently drop the
        // second tab's milestone.
        let key = Self.key(for: event)
        if firedEvents.contains(key) {
            lock.unlock()
            return
        }
        firedEvents.insert(key)
        if startMachTime == 0 { startMachTime = now }
        elapsedMS = Self.machTimeToMS(now - startMachTime)
        thread = Thread.isMainThread ? "main" : "bg"
        milestone = LaunchMilestone(
            event: key,
            elapsedMS: elapsedMS,
            thread: thread
        )
        milestones.append(milestone)
        lock.unlock()

        // Sink 1: Instruments signpost.
        // We use the C `os_signpost(.event, …)` macro directly
        // rather than the Swift `OSSignposter.event(_:)` method
        // because the Swift overlay is incomplete on the SDK
        // the CI runner uses (Xcode 16.4 / iOS 18.5). The C
        // function has been stable since iOS 12 and is
        // available on every SDK we'd realistically build
        // against.
        //
        // Filter in Instruments by subsystem
        // `app.paladala.ios`, category `ColdStart`. Each
        // `os_signpost(.event, …)` appears as a labelled point
        // in the timeline; the suffix is human-readable so the
        // seven milestones are easy to tell apart.
        switch event {
        case .appInitStart:
            os_signpost(.event, log: Self.coldStartLog, name: "ColdStart.app_init_start")
        case .appInitComplete:
            os_signpost(.event, log: Self.coldStartLog, name: "ColdStart.app_init_complete")
        case .appDelegateStart:
            os_signpost(.event, log: Self.coldStartLog, name: "ColdStart.app_delegate_start")
        case .appDelegateComplete:
            os_signpost(.event, log: Self.coldStartLog, name: "ColdStart.app_delegate_complete")
        case .firstRootViewAppeared:
            os_signpost(.event, log: Self.coldStartLog, name: "ColdStart.first_root_view_appeared")
        case .firstFeedNetworkStart:
            os_signpost(.event, log: Self.coldStartLog, name: "ColdStart.first_feed_network_start")
        case .firstFeedNetworkComplete:
            os_signpost(.event, log: Self.coldStartLog, name: "ColdStart.first_feed_network_complete")
        case .firstFeedCached:
            os_signpost(.event, log: Self.coldStartLog, name: "ColdStart.firstFeedCached")
        case .firstTabInteractive:
            // The tag is not in the signpost name (StaticString);
            // it's in the diagnostic-log details below.
            os_signpost(.event, log: Self.coldStartLog, name: "ColdStart.firstTabInteractive")
        case .proxyListenerRequested:
            os_signpost(.event, log: Self.coldStartLog, name: "ColdStart.proxyListenerRequested")
        case .proxyListenerReady:
            os_signpost(.event, log: Self.coldStartLog, name: "ColdStart.proxyListenerReady")
        case .cdnProbeRequested:
            os_signpost(.event, log: Self.coldStartLog, name: "ColdStart.cdnProbeRequested")
        case .cdnProbeReady:
            os_signpost(.event, log: Self.coldStartLog, name: "ColdStart.cdnProbeReady")
        }

        // Sink 2: in-app log viewer. The `.app` category is
        // already documented as "launch / cold start" — no new
        // category needed. `elapsedMS` is the first detail so
        // it's easy to filter / sort. The message key uses the
        // full `key(for:)` (event + tag) so different tabs log
        // independently.
        var details: [String: Any] = [
            "elapsedMS": String(format: "%.1f", elapsedMS),
            "thread": thread
        ]
        if let tag = event.tag {
            details["tag"] = tag.rawValue
        }
        diagLog(.app, "launch.\(key)", details: details)
    }

    /// Per-event key used for both the in-memory gate and the
    /// milestone `event` field. `firstTabInteractive` includes the
    /// tag so each tab fires and is recorded independently. All
    /// other cases use a stable snake_case string to match the
    /// pre-PR-A convention.
    private static func key(for event: LaunchEvent) -> String {
        switch event {
        case .appInitStart:               return "app_init_start"
        case .appInitComplete:            return "app_init_complete"
        case .appDelegateStart:           return "app_delegate_start"
        case .appDelegateComplete:        return "app_delegate_complete"
        case .firstRootViewAppeared:      return "first_root_view_appeared"
        case .firstFeedNetworkStart:      return "first_feed_network_start"
        case .firstFeedNetworkComplete:   return "first_feed_network_complete"
        case .firstFeedCached:            return "firstFeedCached"
        case .firstTabInteractive(let tag): return "firstTabInteractive.\(tag.rawValue)"
        case .proxyListenerRequested:     return "proxyListenerRequested"
        case .proxyListenerReady:         return "proxyListenerReady"
        case .cdnProbeRequested:          return "cdnProbeRequested"
        case .cdnProbeReady:              return "cdnProbeReady"
        }
    }

    /// Write the milestone log to
    /// `Application Support/Paladala/cold-start.jsonl`.
    ///
    /// Called from `PaladalaApp.init` at the very end of the cold
    /// path, but only if the `PALADALA_COLD_START_DUMP=1` env var
    /// is set — so the file does not accumulate on devices that
    /// don't need it. The function is idempotent and safe to call
    /// from any thread.
    func dumpColdStartReport() {
        lock.lock()
        let snapshot = milestones
        lock.unlock()
        guard !snapshot.isEmpty else { return }

        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        let dir = support.appendingPathComponent("Paladala", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        let url = dir.appendingPathComponent("cold-start.jsonl")

        // Pretty keys so a `cat` of the file is human-readable.
        // The file is small (<1 KB even with all 7 milestones) so
        // the byte overhead is irrelevant.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var lines: [String] = []
        for m in snapshot {
            guard let data = try? encoder.encode(m),
                  let s = String(data: data, encoding: .utf8) else { continue }
            lines.append(s)
        }
        let body = lines.joined(separator: "\n") + "\n"
        try? body.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    // MARK: - mach time → milliseconds

    /// Standard iOS pattern. `mach_timebase_info` returns the
    /// numerator/denominator pair that converts mach ticks to
    /// nanoseconds; dividing by 1_000_000 yields milliseconds.
    /// Computed once on first access and cached.
    private static let machTimeToMSFactor: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000
    }()

    private static func machTimeToMS(_ mach: UInt64) -> Double {
        Double(mach) * machTimeToMSFactor
    }
}
