import XCTest
@testable import Relay

final class DeliveryFailurePolicyTests: XCTestCase {
    func testOnlyFailedNewTurnCanBeEdited() {
        XCTAssertTrue(DeliveryFailurePolicy.canEditFailedTurnStart(expectedTurnId: nil))
        XCTAssertFalse(DeliveryFailurePolicy.canEditFailedTurnStart(expectedTurnId: "active-turn"))
    }

    func testRecognizesRelayClientMessageIdsInFailedHistory() {
        XCTAssertTrue(DeliveryFailurePolicy.isRelayClientMessageId("48D8A3B7-DF48-49E4-B1B9-8269A5CE1422"))
        XCTAssertFalse(DeliveryFailurePolicy.isRelayClientMessageId("msg_019fb951-a35c-74b3-8ba6-511328bad4e4"))
    }

    func testStartedTurnFailureIsEditableOnlyBeforeAnyOutput() {
        XCTAssertEqual(
            DeliveryFailurePolicy.startedTurnDisposition(
                status: "failed",
                errorMessage: "503 Service Unavailable",
                hasOutput: false
            ),
            .failed
        )
        XCTAssertEqual(
            DeliveryFailurePolicy.startedTurnDisposition(
                status: "failed",
                errorMessage: "503 Service Unavailable",
                hasOutput: true
            ),
            .resolved
        )
    }

    func testStartedTurnWaitsForOutputAndResolvesNormalCompletion() {
        XCTAssertEqual(
            DeliveryFailurePolicy.startedTurnDisposition(
                status: "inProgress",
                errorMessage: nil,
                hasOutput: true
            ),
            .awaitingOutput
        )
        XCTAssertEqual(
            DeliveryFailurePolicy.startedTurnDisposition(
                status: "completed",
                errorMessage: nil,
                hasOutput: false
            ),
            .resolved
        )
    }

    func testInterruptedTurnRemainsEditableEvenAfterPartialOutput() {
        XCTAssertEqual(
            DeliveryFailurePolicy.startedTurnDisposition(
                status: "interrupted",
                errorMessage: nil,
                hasOutput: true
            ),
            .failed
        )
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
