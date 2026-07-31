import XCTest
@testable import Relay

final class DeliveryFailurePolicyTests: XCTestCase {
    func testOnlyFailedNewTurnCanBeEdited() {
        XCTAssertTrue(DeliveryFailurePolicy.canEditFailedTurnStart(expectedTurnId: nil))
        XCTAssertFalse(DeliveryFailurePolicy.canEditFailedTurnStart(expectedTurnId: "active-turn"))
    }

    func testDefinitiveUpstreamRejectionRemainsEditableAfterBridgeAcceptance() {
        for message in [
            "HTTP 401 Unauthorized",
            "429 rate_limit_exceeded: quota exhausted",
            "The selected model is not supported"
        ] {
            XCTAssertEqual(
                DeliveryFailurePolicy.disposition(
                    remoteMessage: message,
                    bridgeAccepted: true,
                    transportConnected: true
                ),
                .failed
            )
        }
    }

    func testTransportTimeoutRemainsUncertainToAvoidDuplicateSubmission() {
        XCTAssertEqual(
            DeliveryFailurePolicy.disposition(
                remoteMessage: "Windows 长时间没有完成请求，但连接仍保持。",
                bridgeAccepted: true,
                transportConnected: true
            ),
            .uncertain
        )
        XCTAssertEqual(
            DeliveryFailurePolicy.disposition(
                remoteMessage: nil,
                bridgeAccepted: true,
                transportConnected: false
            ),
            .uncertain
        )
    }

    func testLocalFailureBeforeAcceptanceIsImmediatelyEditable() {
        XCTAssertEqual(
            DeliveryFailurePolicy.disposition(
                remoteMessage: nil,
                bridgeAccepted: false,
                transportConnected: true
            ),
            .failed
        )
    }
}
