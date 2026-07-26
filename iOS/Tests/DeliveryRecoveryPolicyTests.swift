import XCTest
@testable import Relay

final class DeliveryRecoveryPolicyTests: XCTestCase {
    func testRetriesAnInitialPromptOnlyWhenNoTurnIsRunning() {
        XCTAssertEqual(
            DeliveryRecoveryPolicy.action(expectedTurnId: nil, runtimeRunning: false, activeTurnId: nil),
            .retry
        )
        XCTAssertEqual(
            DeliveryRecoveryPolicy.action(expectedTurnId: nil, runtimeRunning: true, activeTurnId: "turn.1"),
            .waitForHistory
        )
    }

    func testRetriesOnlyAgainstTheSameActiveSteerTurn() {
        XCTAssertEqual(
            DeliveryRecoveryPolicy.action(expectedTurnId: "turn.1", runtimeRunning: true, activeTurnId: "turn.1"),
            .retry
        )
        XCTAssertEqual(
            DeliveryRecoveryPolicy.action(expectedTurnId: "turn.1", runtimeRunning: false, activeTurnId: nil),
            .rejectStaleSteer
        )
        XCTAssertEqual(
            DeliveryRecoveryPolicy.action(expectedTurnId: "turn.1", runtimeRunning: true, activeTurnId: "turn.2"),
            .rejectStaleSteer
        )
    }
}
