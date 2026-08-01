import XCTest
@testable import Relay

@MainActor
final class TranscriptScrollRequestTests: XCTestCase {
    func testOutgoingMessagesAlwaysCreateANewRevealRequest() {
        let store = RelayStore()

        store.revealOutgoingMessage("message.1")
        let first = store.transcriptScrollRequest
        store.revealOutgoingMessage("message.1")
        let second = store.transcriptScrollRequest

        XCTAssertEqual(first?.targetId, "message.1")
        XCTAssertEqual(first?.reason, .outgoingMessage)
        XCTAssertNotEqual(first?.sequence, second?.sequence)
    }
}
