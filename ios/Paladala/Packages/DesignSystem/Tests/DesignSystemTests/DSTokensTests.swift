import XCTest
@testable import DesignSystem

final class DSTokensTests: XCTestCase {
    func test_spacingScaleIsStrictlyIncreasing() {
        let scale = [DSSpacing.xxs, DSSpacing.xs, DSSpacing.s, DSSpacing.m,
                     DSSpacing.l, DSSpacing.xl, DSSpacing.xxl]
        XCTAssertEqual(scale, scale.sorted())
        XCTAssertEqual(Set(scale).count, scale.count)
    }

    func test_radiiAreOrdered() {
        XCTAssertLessThan(DSRadius.chip, DSRadius.card)
        XCTAssertLessThan(DSRadius.card, DSRadius.sheet)
    }
}
