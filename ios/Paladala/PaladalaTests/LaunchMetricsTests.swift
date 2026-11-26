import XCTest
@testable import Paladala

/// Tests for `LaunchMetrics` (PR-A Task 6).
///
/// The new event cases (firstFeedCached, firstTabInteractive,
/// proxyListenerRequested, proxyListenerReady) need to be recorded
/// in order, with the full key (event + tag) on the milestone so
/// each tab fires independently.
final class LaunchMetricsTests: XCTestCase {
    func test_mark_appendsMilestoneInOrder() {
        // Isolated instance — the shared singleton is mutated
        // concurrently by the host app's own launch milestones,
        // which makes position-based assertions non-deterministic
        // (and can crash with an index-out-of-range when the app
        // emits between two test marks).
        let m = LaunchMetrics()
        m.mark(.firstFeedCached)
        m.mark(.firstTabInteractive(tag: .home))
        XCTAssertEqual(m.milestones.count, 2)
        XCTAssertEqual(m.milestones[0].eventName, "firstFeedCached")
        XCTAssertEqual(m.milestones[1].eventName, "firstTabInteractive.home")
    }

    func test_mark_firesOncePerEvent() {
        let m = LaunchMetrics()
        m.mark(.firstFeedCached)
        m.mark(.firstFeedCached)
        XCTAssertEqual(m.milestones.count, 1)
    }

    func test_mark_firstTabInteractive_firesOncePerTag() {
        let m = LaunchMetrics()
        m.mark(.firstTabInteractive(tag: .home))
        m.mark(.firstTabInteractive(tag: .home))
        m.mark(.firstTabInteractive(tag: .dynamic))
        XCTAssertEqual(
            m.milestones.map(\.eventName),
            ["firstTabInteractive.home", "firstTabInteractive.dynamic"]
        )
    }
}
