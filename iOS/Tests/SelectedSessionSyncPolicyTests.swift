import XCTest
@testable import Relay

final class SelectedSessionSyncPolicyTests: XCTestCase {
    func testRetriesOnlyAfterARealHealthTimeout() {
        XCTAssertEqual(
            SelectedSessionSyncPolicy.retryDelay(hasActiveSubscription: true),
            15_000_000_000
        )
        XCTAssertTrue(SelectedSessionSyncPolicy.shouldRefreshSubscription(
            hasActiveSubscription: true,
            lastUpdateAt: Date(timeIntervalSince1970: 10),
            now: Date(timeIntervalSince1970: 55)
        ))
        XCTAssertFalse(SelectedSessionSyncPolicy.shouldRefreshSubscription(
            hasActiveSubscription: true,
            lastUpdateAt: Date(timeIntervalSince1970: 11),
            now: Date(timeIntervalSince1970: 55)
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

    func testChecksIdleSelectedThreadWithoutOneSecondPolling() {
        XCTAssertEqual(
            SelectedSessionSyncPolicy.nextCheckDelay(
                hasActiveSubscription: true,
                isLocallyRunning: false
            ),
            15_000_000_000
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
            15_000_000_000
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

    func testForegroundSkipsHistoryRestorationWhenConnectionGenerationIsUnchanged() {
        let generation = UUID()
        XCTAssertFalse(SelectedSessionSyncPolicy.shouldRestoreOnForeground(
            connected: true,
            backgroundConnectionIdentifier: generation,
            currentConnectionIdentifier: generation
        ))
        XCTAssertTrue(SelectedSessionSyncPolicy.shouldRestoreOnForeground(
            connected: true,
            backgroundConnectionIdentifier: UUID(),
            currentConnectionIdentifier: generation
        ))
        XCTAssertTrue(SelectedSessionSyncPolicy.shouldRestoreOnForeground(
            connected: false,
            backgroundConnectionIdentifier: generation,
            currentConnectionIdentifier: generation
        ))
    }
}
