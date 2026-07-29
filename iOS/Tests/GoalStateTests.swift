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

    func testDecodesOfficialCamelCaseLimitedStatuses() throws {
        let usageLimited = try XCTUnwrap(goal(status: "usageLimited"))
        let budgetLimited = try XCTUnwrap(goal(status: "budgetLimited"))

        XCTAssertEqual(usageLimited.status, .usageLimited)
        XCTAssertEqual(budgetLimited.status, .budgetLimited)
        XCTAssertEqual(usageLimited.status.protocolValue, "usageLimited")
        XCTAssertEqual(budgetLimited.status.protocolValue, "budgetLimited")
    }

    func testDecodesLegacySnakeCaseLimitedStatuses() throws {
        XCTAssertEqual(try XCTUnwrap(goal(status: "usage_limited")).status, .usageLimited)
        XCTAssertEqual(try XCTUnwrap(goal(status: "budget_limited")).status, .budgetLimited)
    }

    func testConvertsMillisecondTimestampsAndProvidesStableFallbackId() throws {
        let decoded = try XCTUnwrap(GoalState(json: .object([
            "threadId": .string("thread-without-goal-id"),
            "objective": .string("完成移动端控制台"),
            "status": .string("active"),
            "createdAt": .number(1_784_636_198_000),
            "updatedAt": .number(1_784_641_901_000)
        ])))

        XCTAssertEqual(decoded.id, "goal.thread-without-goal-id")
        XCTAssertEqual(decoded.createdAt.timeIntervalSince1970, 1_784_636_198, accuracy: 0.001)
        XCTAssertEqual(decoded.updatedAt.timeIntervalSince1970, 1_784_641_901, accuracy: 0.001)
    }

    private func goal(status: String) -> GoalState? {
        GoalState(json: .object([
            "threadId": .string("thread-1"),
            "objective": .string("目标"),
            "status": .string(status)
        ]))
    }
}
