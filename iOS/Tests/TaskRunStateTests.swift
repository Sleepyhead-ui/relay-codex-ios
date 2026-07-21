import XCTest
@testable import Relay

final class TaskRunStateTests: XCTestCase {
    func testStartingStateIsRunningBeforeTurnIdArrives() {
        var state = TaskRunState(threadId: "thread.1")
        state.apply(.starting(startedAt: nil))
        XCTAssertTrue(state.isRunning)
        XCTAssertNil(state.turnId)
        state.apply(.progress(turnId: "turn.1", startedAt: nil))
        XCTAssertEqual(state.phase, .running)
        XCTAssertEqual(state.turnId, "turn.1")
    }

    func testRetryBeforeTurnConfirmationReturnsToStarting() {
        var state = TaskRunState(threadId: "thread.1")
        state.apply(.starting(startedAt: nil))
        state.apply(.retrying(turnId: nil, message: "upstream unavailable"))
        XCTAssertEqual(state.phase, .retrying)
        XCTAssertTrue(state.isRunning)

        state.apply(.clearRetry)
        XCTAssertEqual(state.phase, .starting)
        XCTAssertNil(state.turnId)
    }

    func testLateProgressCannotReviveCompletedTurn() {
        var state = TaskRunState(threadId: "thread.1")
        state.apply(.started(turnId: "turn.1", startedAt: nil))
        state.apply(.terminal(turnId: "turn.1", phase: .completed, completedAt: nil))
        state.apply(.progress(turnId: "turn.1", startedAt: nil))

        XCTAssertEqual(state.phase, .completed)
        XCTAssertNil(state.turnId)
        XCTAssertFalse(state.isRunning)
    }

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
