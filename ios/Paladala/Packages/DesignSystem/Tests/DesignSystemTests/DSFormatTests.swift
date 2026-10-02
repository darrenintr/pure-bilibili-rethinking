import XCTest
@testable import DesignSystem

final class DSFormatTests: XCTestCase {
    func test_countBelowTenThousandIsPlain() {
        XCTAssertEqual(DSFormat.count(0), "0")
        XCTAssertEqual(DSFormat.count(9_999), "9999")
    }

    func test_countUsesWanAndYi() {
        XCTAssertEqual(DSFormat.count(10_000), "1萬")
        XCTAssertEqual(DSFormat.count(12_345), "1.2萬")
        XCTAssertEqual(DSFormat.count(99_999), "9.9萬")
        XCTAssertEqual(DSFormat.count(123_456_789), "1.2億")
    }

    func test_negativeCountClampsToZero() {
        XCTAssertEqual(DSFormat.count(-5), "0")
    }

    func test_duration() {
        XCTAssertEqual(DSFormat.duration(seconds: 0), "0:00")
        XCTAssertEqual(DSFormat.duration(seconds: 65), "1:05")
        XCTAssertEqual(DSFormat.duration(seconds: 3_725), "1:02:05")
        XCTAssertEqual(DSFormat.duration(seconds: -3), "0:00")
    }
}
