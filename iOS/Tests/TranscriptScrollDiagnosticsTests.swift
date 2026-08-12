import XCTest
import UIKit
@testable import Relay

@MainActor
final class TranscriptScrollDiagnosticsTests: XCTestCase {
    func testInitialScrollRunsOnceForTheSameThread() {
        var state = TranscriptInitialScrollState()

        XCTAssertTrue(state.consume(threadId: "thread.1"))
        XCTAssertFalse(state.consume(threadId: "thread.1"))
        XCTAssertEqual(state.initializedThreadId, "thread.1")
    }

    func testInitialScrollRunsWhenSwitchingThreads() {
        var state = TranscriptInitialScrollState()

        XCTAssertTrue(state.consume(threadId: "thread.1"))
        XCTAssertTrue(state.consume(threadId: "thread.2"))
        XCTAssertFalse(state.consume(threadId: nil))
    }

    func testInitialScrollStateKeepsThreadIdentityStableDuringLayoutRetries() {
        var state = TranscriptInitialScrollState()

        XCTAssertTrue(state.consume(threadId: "thread.1"))
        XCTAssertFalse(state.consume(threadId: "thread.1"))
        XCTAssertTrue(state.consume(threadId: "thread.2"))
        XCTAssertEqual(state.initializedThreadId, "thread.2")
    }

    func testNativeMetricsUseContentSizeViewportAndInsets() {
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 600))
        scrollView.contentSize = CGSize(width: 320, height: 2_000)
        scrollView.contentInset = UIEdgeInsets(top: 10, left: 0, bottom: 40, right: 0)

        XCTAssertEqual(ConversationScrollTracker.maxOffsetY(in: scrollView), 1_440, accuracy: 0.01)
    }

    func testHistoryPrependRestoresTheVisibleOffsetByHeightDelta() {
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 600))
        scrollView.contentSize = CGSize(width: 320, height: 2_000)
        scrollView.contentOffset = CGPoint(x: 0, y: 500)
        let tracker = ConversationScrollTracker()
        tracker.attach(to: scrollView)

        XCTAssertTrue(tracker.beginHistoryPreservation())
        scrollView.contentSize = CGSize(width: 320, height: 2_800)
        tracker.update(from: scrollView)

        XCTAssertEqual(scrollView.contentOffset.y, 1_300, accuracy: 0.01)
        tracker.cancelHistoryPreservation()
    }
}
