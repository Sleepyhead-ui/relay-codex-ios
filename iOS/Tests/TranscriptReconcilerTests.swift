import XCTest
@testable import Relay

final class TranscriptReconcilerTests: XCTestCase {
    func testSessionPatchUpdatesAddsAndRemovesOnlyTheCurrentTurn() {
        let existing = [
            TranscriptItem(id: "older", turnId: "turn.0", role: .assistant, kind: .message, text: "older"),
            TranscriptItem(id: "one", turnId: "turn.1", role: .assistant, kind: .message, text: "first"),
            TranscriptItem(id: "two", turnId: "turn.1", role: .tool, kind: .command, text: "old command"),
        ]
        let patch = [
            TranscriptItem(id: "one", turnId: "turn.1", role: .assistant, kind: .message, text: "first expanded"),
            TranscriptItem(id: "three", turnId: "turn.1", role: .tool, kind: .reasoning, text: "next"),
        ]

        let result = TranscriptReconciler.mergeSessionPatchItems(
            patch,
            removedItemIds: ["two"],
            turnId: "turn.1",
            into: existing
        )

        XCTAssertEqual(result.map(\.id), ["older", "one", "three"])
        XCTAssertEqual(result[1].text, "first expanded")
    }

    func testRemovesInternalCompactionSummary() {
        let messages = [
            item(id: "user.1", turnId: "turn.1", role: .user, text: "Continue"),
            TranscriptItem(id: "summary.1", turnId: "turn.1", role: .assistant, kind: .message, text: "## Current State\nInternal details", phase: "final_answer")
        ]

        let result = TranscriptReconciler.removeCompactionSummary(turnId: "turn.1", from: messages)

        XCTAssertEqual(result.map(\.id), ["user.1"])
    }

    func testIgnoresInternalEnvironmentContextAndImageClosingTag() throws {
        let internalContext = JSONValue.object([
            "id": .string("internal.env"),
            "type": .string("userMessage"),
            "content": .array([
                .object(["type": .string("text"), "text": .string("<environment_context><current_date>2026-07-22</current_date></environment_context>")])
            ])
        ])
        XCTAssertNil(TranscriptItem.from(json: internalContext, turnId: "turn.1"))

        let imageMessage = JSONValue.object([
            "id": .string("image.1"),
            "type": .string("userMessage"),
            "content": .array([
                .object(["type": .string("text"), "text": .string("查看截图\n<image name=[Image #1] path=\"C:\\Temp\\screen.png\">\n</image>")])
            ])
        ])
        let parsed = try XCTUnwrap(TranscriptItem.from(json: imageMessage, turnId: "turn.1"))
        XCTAssertEqual(parsed.text, "查看截图")
        XCTAssertEqual(parsed.imagePaths, ["C:\\Temp\\screen.png"])
    }

    func testLaggingSnapshotCannotShortenLiveOutput() throws {
        let progress = item(id: "progress.1", turnId: "turn.1", role: .assistant, text: "正在检查完整进展", phase: "commentary")
        var command = TranscriptItem(id: "command.1", turnId: "turn.1", role: .tool, kind: .command, text: "npm test", detail: "line 1\nline 2")
        command.status = "inProgress"
        let shortProgress = item(id: "progress.1", turnId: "turn.1", role: .assistant, text: "正在检查", phase: "commentary")
        let shortCommand = TranscriptItem(id: "command.1", turnId: "turn.1", role: .tool, kind: .command, text: "npm test", detail: "line 1")

        let result = TranscriptReconciler.mergeSessionItems([shortProgress, shortCommand], turnId: "turn.1", into: [progress, command])

        XCTAssertEqual(result[0].text, "正在检查完整进展")
        XCTAssertEqual(result[1].detail, "line 1\nline 2")
    }

    func testHistoryReconciliationPreservesLiveCommandsMissingFromEarlyHistory() {
        let prompt = item(id: "user.1", turnId: "turn.1", role: .user, text: "运行测试")
        let command = TranscriptItem(id: "command.1", turnId: "turn.1", role: .tool, kind: .command, text: "npm test", detail: "passed")
        let answer = item(id: "answer.1", turnId: "turn.1", role: .assistant, text: "完成")

        let result = TranscriptReconciler.mergeHistoryItems([prompt, answer], into: [prompt, command])

        XCTAssertEqual(result.map(\.id), ["user.1", "command.1", "answer.1"])
    }

    func testSnapshotReplacesEquivalentLiveItemWithoutChangingItsIdentity() {
        let live = item(id: "live.1", turnId: "turn.1", role: .assistant, text: "正在检查  项目", phase: "commentary")
        let snapshot = item(id: "rollout.9", turnId: "turn.1", role: .assistant, text: "正在检查 项目", phase: "commentary")

        let result = TranscriptReconciler.mergeSessionItems([snapshot], turnId: "turn.1", into: [live])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.id, "live.1")
        XCTAssertEqual(result.first?.text, "正在检查 项目")
    }

    func testPlacementKeepsInitialPromptBeforeOutputAndSteerAfterItsAnchor() {
        let initial = item(id: "prompt.1", turnId: nil, role: .user, text: "开始")
        let progress = item(id: "progress.1", turnId: "turn.1", role: .assistant, text: "第一阶段", phase: "commentary")
        let steer = item(id: "prompt.2", turnId: nil, role: .user, text: "先修测试")
        let final = item(id: "answer.1", turnId: "turn.1", role: .assistant, text: "完成")
        let placements = [
            "prompt.1": UserMessagePlacement(threadId: "thread.1", turnId: "turn.1", afterItemId: nil, sequence: 1),
            "prompt.2": UserMessagePlacement(threadId: "thread.1", turnId: "turn.1", afterItemId: "progress.1", sequence: 2),
        ]

        let result = TranscriptReconciler.applyUserMessagePlacements(
            placements,
            turnId: "turn.1",
            threadId: "thread.1",
            to: [progress, initial, final, steer]
        )

        XCTAssertEqual(result.map(\.id), ["prompt.1", "progress.1", "prompt.2", "answer.1"])
        XCTAssertTrue(result.filter { $0.role == .user }.allSatisfy { $0.turnId == "turn.1" })
    }

    func testUpsertDoesNotDuplicateUserMessageFromHistory() {
        var messages = [item(id: "client.1", turnId: nil, role: .user, text: "执行测试")]
        TranscriptReconciler.upsert(item(id: "history.1", turnId: "turn.1", role: .user, text: "执行测试"), into: &messages)
        XCTAssertEqual(messages.count, 1)
    }

    func testSnapshotCacheEvictsOldestUnselectedThread() {
        var cache = ThreadSnapshotCache(limit: 2)
        cache.store(snapshot(at: 1), for: "one", preserving: "one")
        cache.store(snapshot(at: 2), for: "two", preserving: "two")
        cache.store(snapshot(at: 3), for: "three", preserving: "three")

        XCTAssertNil(cache["one"])
        XCTAssertNotNil(cache["two"])
        XCTAssertNotNil(cache["three"])
    }

    func testApprovalQueuePrioritizesSelectedTaskWithoutDroppingOthers() throws {
        let first = try XCTUnwrap(ApprovalRequest(message: approval(id: 1, threadId: "thread.1")))
        let second = try XCTUnwrap(ApprovalRequest(message: approval(id: 2, threadId: "thread.2")))
        let prioritized = ApprovalQueue.prioritized([first, second], selectedThreadId: "thread.2")
        XCTAssertEqual(prioritized.map(\.id), ["2"])
        XCTAssertTrue(ApprovalQueue.contains([first, second], threadId: "thread.1"))
    }

    private func item(
        id: String,
        turnId: String?,
        role: TranscriptRole,
        text: String,
        phase: String? = nil
    ) -> TranscriptItem {
        TranscriptItem(id: id, turnId: turnId, role: role, kind: .message, text: text, phase: phase)
    }

    private func snapshot(at seconds: TimeInterval) -> ThreadSnapshot {
        ThreadSnapshot(
            messages: [],
            turnMetadata: [:],
            isRunning: false,
            activeTurnId: nil,
            activePlan: [],
            activePlanTurnId: nil,
            modelId: "",
            effort: "",
            cachedAt: Date(timeIntervalSince1970: seconds)
        )
    }

    private func approval(id: Int, threadId: String) -> JSONValue {
        .object([
            "id": .number(Double(id)),
            "method": .string("item/commandExecution/requestApproval"),
            "params": .object([
                "threadId": .string(threadId),
                "command": .string("npm test")
            ])
        ])
    }
}
