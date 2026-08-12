import XCTest
@testable import Relay

final class ActivityWindowScrollMetricsTests: XCTestCase {
    func testLongTextCanScrollEvenWithFewProgressItems() {
        XCTAssertTrue(ActivityWindowScrollMetrics.isScrollable(contentHeight: 180, viewportHeight: 104))
    }

    func testShortContentDoesNotCaptureScrolling() {
        XCTAssertFalse(ActivityWindowScrollMetrics.isScrollable(contentHeight: 86, viewportHeight: 104))
    }

    func testSmallBottomMovementKeepsLatestButtonHidden() {
        XCTAssertEqual(ActivityWindowScrollMetrics.isAtBottom(bottomY: 116, viewportHeight: 104), true)
    }

    func testLeavingBottomShowsLatestButton() {
        XCTAssertEqual(ActivityWindowScrollMetrics.isAtBottom(bottomY: 140, viewportHeight: 104), false)
    }

    func testUnmeasuredPreferenceIsIgnoredAsAtBottom() {
        XCTAssertNil(ActivityWindowScrollMetrics.isAtBottom(
            bottomY: .greatestFiniteMagnitude,
            viewportHeight: 104
        ))
    }
}
