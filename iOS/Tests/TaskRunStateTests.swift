import XCTest
@testable import Relay

final class TaskRunStateTests: XCTestCase {
    func testStalePlanCannotReplaceCurrentTurnPlan() {
        var state = TaskRunState(threadId: "thread.1")
        state.apply(.started(turnId: "turn.2", startedAt: nil))
        state.apply(.plan(turnId: "turn.1", steps: [ExecutionPlanStep(id: "old", text: "旧步骤", status: "inProgress")]))
        XCTAssertTrue(state.plan.isEmpty)
        state.apply(.plan(turnId: "turn.2", steps: [ExecutionPlanStep(id: "new", text: "当前步骤", status: "inProgress")]))
        XCTAssertEqual(state.plan.map(\.text), ["当前步骤"])
        XCTAssertEqual(state.planTurnId, "turn.2")
    }

    func testLateTerminalEventCannotStopNewerTurn() {
        var state = TaskRunState(threadId: "thread.1")
        state.apply(.started(turnId: "turn.2", startedAt: nil))
        state.apply(.terminal(turnId: "turn.1", phase: .completed, completedAt: nil))
        XCTAssertTrue(state.isRunning)
        XCTAssertEqual(state.turnId, "turn.2")
    }

    func testStartingNewTurnClearsPreviousPlan() {
        var state = TaskRunState(threadId: "thread.1")
        state.apply(.started(turnId: "turn.1", startedAt: nil))
        state.apply(.plan(turnId: "turn.1", steps: [ExecutionPlanStep(id: "one", text: "步骤", status: "pending")]))
        state.apply(.started(turnId: "turn.2", startedAt: nil))
        XCTAssertTrue(state.plan.isEmpty)
        XCTAssertEqual(state.turnId, "turn.2")
    }
}
