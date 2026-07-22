import XCTest
@testable import Relay

final class SessionRevisionTrackerTests: XCTestCase {
    func testRejectsOutOfOrderPatchWithoutAdvancingRevision() {
        var tracker = SessionRevisionTracker()
        tracker.reset(threadId: "thread.1", revision: 0)
        XCTAssertTrue(tracker.acceptPatch(threadId: "thread.1", baseRevision: 0, revision: 1))
        XCTAssertFalse(tracker.acceptPatch(threadId: "thread.1", baseRevision: 0, revision: 2))
        XCTAssertEqual(tracker.revision(threadId: "thread.1"), 1)
        tracker.reset(threadId: "thread.1", revision: 5)
        XCTAssertTrue(tracker.acceptPatch(threadId: "thread.1", baseRevision: 5, revision: 6))
    }
}
