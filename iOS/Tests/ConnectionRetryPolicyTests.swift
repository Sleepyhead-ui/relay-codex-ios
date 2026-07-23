import XCTest
@testable import Relay

final class ConnectionRetryPolicyTests: XCTestCase {
    func testRepeatedFailuresBackOffAndCapAtEightSeconds() {
        let delays = (1...12).map { ConnectionRetryPolicy.delaySeconds(attempt: $0) }

        XCTAssertEqual(delays[0], 1)
        XCTAssertEqual(delays[1], 1.7, accuracy: 0.001)
        XCTAssertEqual(delays.last, 8)
        XCTAssertTrue(zip(delays, delays.dropFirst()).allSatisfy { $0.0 <= $0.1 })
    }

    func testImmediateRetryAndStableResetWindowAreExplicit() {
        XCTAssertEqual(ConnectionRetryPolicy.delaySeconds(attempt: 8, immediate: true), 0)
        XCTAssertEqual(ConnectionRetryPolicy.stableResetSeconds, 10)
    }
}
