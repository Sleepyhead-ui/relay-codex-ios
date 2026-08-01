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

    func testChecksIdleSelectedThreadForExternalTurnEverySecond() {
        XCTAssertEqual(
            SelectedSessionSyncPolicy.nextCheckDelay(
                hasActiveSubscription: true,
                isLocallyRunning: false
            ),
            1_000_000_000
        )
        XCTAssertTrue(SelectedSessionSyncPolicy.shouldProbeExternalRuntime(
            isLocallyRunning: false,
            connected: true
        ))
    }

    func testDoesNotProbeExternalRuntimeWhileLocalTurnIsRunningOrDisconnected() {
        XCTAssertEqual(
            SelectedSessionSyncPolicy.nextCheckDelay(
                hasActiveSubscription: true,
                isLocallyRunning: true
            ),
            5_000_000_000
        )
        XCTAssertFalse(SelectedSessionSyncPolicy.shouldProbeExternalRuntime(
            isLocallyRunning: true,
            connected: true
        ))
        XCTAssertFalse(SelectedSessionSyncPolicy.shouldProbeExternalRuntime(
            isLocallyRunning: false,
            connected: false
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
