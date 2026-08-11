import XCTest
@testable import Relay

final class ThreadLoadReconciliationPolicyTests: XCTestCase {
    func testPreservesSessionStateThatArrivedWhileHistoryWasLoading() {
        let startedAt = Date(timeIntervalSince1970: 100)
        XCTAssertTrue(ThreadLoadReconciliationPolicy.receivedLiveSessionUpdate(
            lastSessionUpdateAt: Date(timeIntervalSince1970: 101),
            historyLoadStartedAt: startedAt
        ))
    }

    func testAllowsHistoryHydrationWithoutAFreshSessionUpdate() {
        let startedAt = Date(timeIntervalSince1970: 100)
        XCTAssertFalse(ThreadLoadReconciliationPolicy.receivedLiveSessionUpdate(
            lastSessionUpdateAt: Date(timeIntervalSince1970: 99),
            historyLoadStartedAt: startedAt
        ))
        XCTAssertFalse(ThreadLoadReconciliationPolicy.receivedLiveSessionUpdate(
            lastSessionUpdateAt: nil,
            historyLoadStartedAt: startedAt
        ))
    }
}
