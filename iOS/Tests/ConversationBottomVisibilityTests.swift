import XCTest
@testable import Relay

final class ConversationBottomVisibilityTests: XCTestCase {
    func testBottomMarkerInsideViewportIsAtBottom() {
        XCTAssertTrue(ConversationBottomVisibility.isAtBottom(bottomY: 790, viewportHeight: 800))
    }

    func testSmallLayoutRoundingGapStillCountsAsBottom() {
        XCTAssertTrue(ConversationBottomVisibility.isAtBottom(bottomY: 811, viewportHeight: 800))
    }

    func testMarkerBelowViewportShowsJumpControl() {
        XCTAssertFalse(ConversationBottomVisibility.isAtBottom(bottomY: 840, viewportHeight: 800))
    }

    func testUnmeasuredPreferenceDoesNotHideJumpControl() {
        XCTAssertTrue(ConversationBottomVisibility.isAtBottom(
            bottomY: .greatestFiniteMagnitude,
            viewportHeight: 800
        ))
    }
}
