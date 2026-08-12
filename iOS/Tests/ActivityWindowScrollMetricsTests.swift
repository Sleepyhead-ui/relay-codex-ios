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
        XCTAssertTrue(ActivityWindowScrollMetrics.isAtBottom(bottomY: 116, viewportHeight: 104))
    }

    func testLeavingBottomShowsLatestButton() {
        XCTAssertFalse(ActivityWindowScrollMetrics.isAtBottom(bottomY: 140, viewportHeight: 104))
    }
}
