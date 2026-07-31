import XCTest
@testable import Relay

final class SelectedSessionSyncPolicyTests: XCTestCase {
    func testRetriesSilentSubscriptionWithinFiveSeconds() {
        XCTAssertEqual(
            SelectedSessionSyncPolicy.retryDelay(hasActiveSubscription: true),
            5_000_000_000
        )
        XCTAssertTrue(SelectedSessionSyncPolicy.shouldRefreshSubscription(
            hasActiveSubscription: true,
            lastUpdateAt: Date(timeIntervalSince1970: 10),
            now: Date(timeIntervalSince1970: 14)
        ))
        XCTAssertFalse(SelectedSessionSyncPolicy.shouldRefreshSubscription(
            hasActiveSubscription: true,
            lastUpdateAt: Date(timeIntervalSince1970: 11),
            now: Date(timeIntervalSince1970: 14)
        ))
    }

    func testImmediatelyRefreshesMissingSubscription() {
        XCTAssertEqual(
            SelectedSessionSyncPolicy.retryDelay(hasActiveSubscription: false),
            2_000_000_000
        )
        XCTAssertTrue(SelectedSessionSyncPolicy.shouldRefreshSubscription(
            hasActiveSubscription: false,
            lastUpdateAt: Date()
        ))
    }

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
