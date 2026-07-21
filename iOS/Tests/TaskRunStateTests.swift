import XCTest
@testable import Relay

final class TaskRunStateTests: XCTestCase {
    private struct RecordedEvent: Decodable {
        let method: String
        let params: JSONValue
    }

    func testRecordedJSONFixtureReplaysToTerminalState() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "task-events", withExtension: "json"))
        let events = try JSONDecoder().decode([RecordedEvent].self, from: Data(contentsOf: url))
        var replay = TaskEventReplay()
        for event in events { replay.apply(method: event.method, params: event.params) }

        let state = try XCTUnwrap(replay.states["fixture.thread"])
        XCTAssertEqual(state.phase, .completed)
        XCTAssertNil(state.turnId)
        XCTAssertTrue(state.plan.isEmpty)
    }

    func testReconnectHydrationPreservesRunningTaskAcrossBackgroundCycle() {
        var replay = TaskEventReplay()
        replay.apply(method: "turn/started", params: eventParams(threadId: "thread.1", turnId: "turn.1"))

        // Backgrounding does not manufacture a terminal event. The reconnect
        // snapshot remains authoritative when the socket comes back.
        replay.hydrate(threadId: "thread.1", running: true, turnId: "turn.1")
        XCTAssertEqual(replay.states["thread.1"]?.phase, .running)
        XCTAssertEqual(replay.states["thread.1"]?.turnId, "turn.1")

        replay.hydrate(threadId: "thread.1", running: false, turnId: "turn.1")
        XCTAssertEqual(replay.states["thread.1"]?.phase, .idle)
        XCTAssertNil(replay.states["thread.1"]?.turnId)
    }

    func testRecordedEventsReplayDeterministicallyAcrossThreads() {
        var replay = TaskEventReplay()
        replay.apply(method: "turn/started", params: eventParams(threadId: "thread.1", turnId: "turn.1"))
        replay.apply(method: "turn/started", params: eventParams(threadId: "thread.2", turnId: "turn.2"))
        replay.apply(method: "item/agentMessage/delta", params: eventParams(threadId: "thread.1", turnId: "turn.1"))
        replay.apply(method: "turn/completed", params: eventParams(threadId: "thread.1", turnId: "turn.1"))

        XCTAssertEqual(replay.states["thread.1"]?.phase, .completed)
        XCTAssertEqual(replay.states["thread.2"]?.phase, .running)
        XCTAssertEqual(replay.states["thread.2"]?.turnId, "turn.2")
    }

    func testRecordedStaleEventsDoNotReplaceCurrentTurnOrPlan() {
        var replay = TaskEventReplay()
        replay.apply(method: "turn/started", params: eventParams(threadId: "thread.1", turnId: "turn.new"))
        replay.apply(method: "turn/plan/updated", params: planParams(threadId: "thread.1", turnId: "turn.new", step: "新计划"))
        replay.apply(method: "turn/plan/updated", params: planParams(threadId: "thread.1", turnId: "turn.old", step: "旧计划"))
        replay.apply(method: "turn/completed", params: eventParams(threadId: "thread.1", turnId: "turn.old"))

        XCTAssertEqual(replay.states["thread.1"]?.phase, .running)
        XCTAssertEqual(replay.states["thread.1"]?.turnId, "turn.new")
        XCTAssertEqual(replay.states["thread.1"]?.plan.map(\.text), ["新计划"])
    }

    func testRecordedRetryAndRecoveryPreserveActiveTurn() {
        var replay = TaskEventReplay()
        replay.apply(method: "turn/started", params: eventParams(threadId: "thread.1", turnId: "turn.1"))
        replay.apply(method: "error", params: .object([
            "threadId": .string("thread.1"),
            "turnId": .string("turn.1"),
            "willRetry": .bool(true),
            "message": .string("upstream disconnected")
        ]))
        XCTAssertEqual(replay.states["thread.1"]?.phase, .retrying)

        replay.apply(method: "item/reasoning/summaryTextDelta", params: eventParams(threadId: "thread.1", turnId: "turn.1"))
        XCTAssertEqual(replay.states["thread.1"]?.phase, .running)
        XCTAssertEqual(replay.states["thread.1"]?.turnId, "turn.1")
    }

    func testRecordedDuplicateStartCannotReviveCompletedTurn() {
        var replay = TaskEventReplay()
        let params = eventParams(threadId: "thread.1", turnId: "turn.1")
        replay.apply(method: "turn/started", params: params)
        replay.apply(method: "turn/completed", params: params)
        replay.apply(method: "turn/started", params: params)
        replay.apply(method: "item/agentMessage/delta", params: params)

        XCTAssertEqual(replay.states["thread.1"]?.phase, .completed)
        XCTAssertNil(replay.states["thread.1"]?.turnId)
    }

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

    private func eventParams(threadId: String, turnId: String) -> JSONValue {
        .object([
            "threadId": .string(threadId),
            "turnId": .string(turnId),
            "turn": .object(["id": .string(turnId)])
        ])
    }

    private func planParams(threadId: String, turnId: String, step: String) -> JSONValue {
        .object([
            "threadId": .string(threadId),
            "turnId": .string(turnId),
            "plan": .array([.object(["step": .string(step), "status": .string("inProgress")])])
        ])
    }
}
