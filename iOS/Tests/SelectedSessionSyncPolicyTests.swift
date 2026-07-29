import XCTest
@testable import Relay

final class SelectedSessionSyncPolicyTests: XCTestCase {
    func testKeepsWatchingAnIdleSelectedThreadForExternalTurns() {
        XCTAssertTrue(SelectedSessionSyncPolicy.shouldContinue(
            initialThreadId: "thread.1",
            selectedThreadId: "thread.1",
            showingArchivedThreads: false,
            connected: true
        ))
    }

    func testStopsWhenSelectionConnectionOrArchiveScopeChanges() {
        XCTAssertFalse(SelectedSessionSyncPolicy.shouldContinue(
            initialThreadId: "thread.1",
            selectedThreadId: "thread.2",
            showingArchivedThreads: false,
            connected: true
        ))
        XCTAssertFalse(SelectedSessionSyncPolicy.shouldContinue(
            initialThreadId: "thread.1",
            selectedThreadId: "thread.1",
            showingArchivedThreads: false,
            connected: false
        ))
        XCTAssertFalse(SelectedSessionSyncPolicy.shouldContinue(
            initialThreadId: "thread.1",
            selectedThreadId: "thread.1",
            showingArchivedThreads: true,
            connected: true
        ))
    }
}
