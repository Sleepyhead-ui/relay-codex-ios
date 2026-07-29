import XCTest
@testable import Relay

final class CollaborationModeTests: XCTestCase {
    func testDecodesListedModeAndBuildsTurnPayload() throws {
        let mode = try XCTUnwrap(CollaborationModeOption(json: .object([
            "name": .string("Plan"),
            "mode": .string("plan"),
            "model": .null,
            "reasoning_effort": .string("medium")
        ])))

        XCTAssertEqual(mode.name, "Plan")
        XCTAssertEqual(mode.mode, "plan")
        XCTAssertEqual(mode.payload(fallbackModel: "gpt-5.6-codex", fallbackEffort: "high"), .object([
            "mode": .string("plan"),
            "settings": .object([
                "model": .string("gpt-5.6-codex"),
                "reasoning_effort": .string("medium"),
                "developer_instructions": .null
            ])
        ]))
    }

    func testPayloadFallsBackToCurrentEffort() throws {
        let mode = try XCTUnwrap(CollaborationModeOption(json: .object([
            "name": .string("Default"),
            "mode": .string("default"),
            "model": .null,
            "reasoning_effort": .null
        ])))

        XCTAssertEqual(mode.payload(fallbackModel: "gpt-5.6-codex", fallbackEffort: "high"), .object([
            "mode": .string("default"),
            "settings": .object([
                "model": .string("gpt-5.6-codex"),
                "reasoning_effort": .string("high"),
                "developer_instructions": .null
            ])
        ]))
    }

    func testRejectsModeWithoutProtocolIdentifier() {
        XCTAssertNil(CollaborationModeOption(json: .object([
            "name": .string("Unavailable"),
            "mode": .null
        ])))
    }
}
