import XCTest
@testable import Relay

final class ConversationBottomVisibilityTests: XCTestCase {
    func testBottomMarkerInsideViewportIsAtBottom() {
        XCTAssertEqual(ConversationBottomVisibility.isAtBottom(bottomY: 790, viewportHeight: 800), true)
    }

    func testSmallLayoutRoundingGapStillCountsAsBottom() {
        XCTAssertEqual(ConversationBottomVisibility.isAtBottom(bottomY: 811, viewportHeight: 800), true)
    }

    func testMarkerBelowViewportShowsJumpControl() {
        XCTAssertEqual(ConversationBottomVisibility.isAtBottom(bottomY: 840, viewportHeight: 800), false)
    }

    func testUnmeasuredPreferenceDoesNotHideJumpControl() {
        XCTAssertNil(ConversationBottomVisibility.isAtBottom(
            bottomY: .greatestFiniteMagnitude,
            viewportHeight: 800
        ))
    }
}
