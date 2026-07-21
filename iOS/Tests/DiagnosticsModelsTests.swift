import XCTest
@testable import Relay

final class DiagnosticsModelsTests: XCTestCase {
    func testNumericBridgeEventIdIsAccepted() {
        let event = DiagnosticEvent(json: .object([
            "id": .number(7),
            "at": .string("2026-07-21T12:00:00.000Z"),
            "level": .string("warning"),
            "category": .string("socket"),
            "message": .string("Remote client disconnected.")
        ]))

        XCTAssertEqual(event?.id, "7")
        XCTAssertEqual(event?.level, "warning")
        XCTAssertEqual(event?.category, "socket")
    }
}
