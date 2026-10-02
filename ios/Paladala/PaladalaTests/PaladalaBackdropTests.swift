import XCTest
import SwiftUI
@testable import Paladala

/// Tests for `PaladalaBackdrop` (PR-A Task 5, audit item #10).
///
/// `PaladalaBackdrop` reads `\.colorScheme` from `@Environment`. Under
/// unit-test conditions that environment is not injected, so
/// `PaladalaBackdrop()` defaults to `.light`. The `scheme(_:)` static
/// is a test seam that injects an explicit scheme, used to verify the
/// Equatable comparison picks up scheme changes.
@MainActor
final class PaladalaBackdropTests: XCTestCase {
    func test_equatable_returnsTrue_whenColorSchemeMatches() {
        // Two default-constructed backdrops both resolve to .light
        // (no environment injection under unit test).
        let a = PaladalaBackdrop()
        let b = PaladalaBackdrop()
        XCTAssertEqual(a, b)
    }

    func test_equatable_returnsFalse_whenColorSchemeDiffers() {
        let light = PaladalaBackdrop.scheme(.light)
        let dark  = PaladalaBackdrop.scheme(.dark)
        XCTAssertNotEqual(light, dark)
    }
}