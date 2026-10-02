import XCTest
import SwiftUI
@testable import Paladala

/// Tests for `LazyTab` (PR-A Task 4, audit item #5).
///
/// These exercise only the first body evaluation — SwiftUI's
/// `onChange(of:initial:)` does not fire under unit test conditions
/// (the view never appears in a hierarchy), so we cannot assert
/// the eventual "armed" state here. The behaviour is instead covered
/// by the integration check in Task 8 (LazyTab wired into RootView).
@MainActor
final class LazyTabTests: XCTestCase {
    func test_body_notInvoked_untilArmed() {
        // Even with `activeTag == tag` at construction (so the
        // `onChange(of:initial:)` would arm the wrapper on a real
        // mount), the first `body` evaluation must NOT invoke the
        // content closure — `armed` is false at that point and the
        // ViewBuilder branch returns EmptyView.
        var invocations = 0
        let host = LazyTab(tag: "home", activeTag: "home") {
            invocations += 1
            return Text("home")
        }
        XCTAssertEqual(invocations, 0, "wrapper must not invoke content when first evaluated")
        _ = host.body  // exercise
        XCTAssertEqual(invocations, 0, "body evaluation must not invoke content before armed")
    }

    func test_body_staysEmpty_whenActiveTagMismatches() {
        // Sanity-check the inverse: if activeTag != tag at construction,
        // the onChange handler will never arm the wrapper, so content
        // stays uncalled for the lifetime of the view.
        var invocations = 0
        let host = LazyTab(tag: "home", activeTag: "dynamic") {
            invocations += 1
            return Text("home")
        }
        // First body evaluation — armed stays false because activeTag != tag.
        _ = host.body
        XCTAssertEqual(invocations, 0)
        // Second body evaluation — still false.
        _ = host.body
        XCTAssertEqual(invocations, 0)
    }
}