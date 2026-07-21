import XCTest
@testable import Relay

final class GoalStateTests: XCTestCase {
    func testDecodesPersistedGoalState() throws {
        let goal = try XCTUnwrap(GoalState(json: .object([
            "id": .string("goal-1"),
            "threadId": .string("thread-1"),
            "objective": .string("完成稳定性与发布"),
            "status": .string("active"),
            "tokenBudget": .null,
            "tokensUsed": .number(1200),
            "timeUsedSeconds": .number(4156),
            "createdAt": .number(1784636198),
            "updatedAt": .number(1784641901)
        ])))

        XCTAssertEqual(goal.id, "goal-1")
        XCTAssertEqual(goal.status, .active)
        XCTAssertEqual(goal.timeUsedSeconds, 4156)
        XCTAssertNil(goal.tokenBudget)
    }

    func testRejectsUnknownGoalStatus() {
        XCTAssertNil(GoalState(json: .object([
            "id": .string("goal-1"),
            "threadId": .string("thread-1"),
            "objective": .string("目标"),
            "status": .string("unknown")
        ])))
    }
}
