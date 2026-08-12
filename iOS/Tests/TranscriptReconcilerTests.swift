import XCTest
@testable import Relay

final class TranscriptReconcilerTests: XCTestCase {
    func testUnknownAssistantDeltaDoesNotBecomeCommentary() throws {
        let update = TranscriptDeltaUpdate(
            id: "answer.1",
            turnId: "turn.1",
            role: .assistant,
            kind: .message,
            title: nil,
            text: "正在流式显示正式回复",
            detail: "",
            phase: nil
        )

        let item = try XCTUnwrap(TranscriptReconciler.applyDeltaBatch([update], to: []).first)

        XCTAssertNil(item.phase)
        XCTAssertTrue(item.isFinalAnswer)
        XCTAssertFalse(item.isCommentary)
    }

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

    func testRemovesOldAndNewDesktopAttachmentWrappersWithoutLosingImages() throws {
        for (index, marker) in ["## My request for Codex:", "## My request:"].enumerated() {
            let message = JSONValue.object([
                "id": .string("wrapped.\(index)"),
                "type": .string("userMessage"),
                "content": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string("# Files mentioned by the user:\n\nimage.png: C:\\Temp\\image.png\n\n\(marker)\n\n检查这张图\n\n<image name=[Image #1] path=\"C:\\Temp\\image.png\">\n</image>")
                    ])
                ])
            ])

            let parsed = try XCTUnwrap(TranscriptItem.from(json: message, turnId: "turn.1"))
            XCTAssertEqual(parsed.text, "检查这张图")
            XCTAssertEqual(parsed.imagePaths, ["C:\\Temp\\image.png"])
        }
    }

    func testRecoversUserMessageTimeFromCodexUUIDv7() throws {
        let message = JSONValue.object([
            "id": .string("msg_019fb832-5405-7561-a0f1-c8d22a20bff0"),
            "type": .string("userMessage"),
            "content": .array([.object(["type": .string("text"), "text": .string("hello")])])
        ])

        let parsed = try XCTUnwrap(TranscriptItem.from(json: message, turnId: "turn.1"))
        let milliseconds = try XCTUnwrap(UInt64("019fb8325405", radix: 16))
        let createdAt = try XCTUnwrap(parsed.createdAt)
        XCTAssertEqual(createdAt.timeIntervalSince1970, Double(milliseconds) / 1_000, accuracy: 0.001)
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

    func testRepeatedHistoryLoadWithDuplicateItemIdsIsIdempotent() {
        let prompt = item(id: "user.1", turnId: "turn.1", role: .user, text: "run tests")
        let command = TranscriptItem(
            id: "command.1",
            turnId: "turn.1",
            role: .tool,
            kind: .command,
            text: "npm test",
            detail: "passed"
        )
        let duplicatedPage = [prompt, command, command, command]

        let first = TranscriptReconciler.mergeHistoryItems(duplicatedPage, into: [])
        let second = TranscriptReconciler.mergeHistoryItems(duplicatedPage, into: first)

        XCTAssertEqual(first.map(\.id), ["user.1", "command.1"])
        XCTAssertEqual(second, first)
    }

    func testSnapshotRemovesPreviouslyAccumulatedDuplicateIds() {
        let prompt = item(id: "user.1", turnId: "turn.1", role: .user, text: "continue")
        let command = TranscriptItem(id: "command.1", turnId: "turn.1", role: .tool, kind: .command, text: "git status")

        let result = TranscriptReconciler.mergeSessionItems(
            [prompt, command, command],
            turnId: "turn.1",
            into: [prompt, command, command, command]
        )

        XCTAssertEqual(result.map(\.id), ["user.1", "command.1"])
    }

    func testLargeSnapshotWithStableIdsRemainsIdempotent() {
        let snapshot = (0..<1_500).map { index in
            TranscriptItem(
                id: "command.\(index)",
                turnId: "turn.large",
                role: .tool,
                kind: .command,
                text: "command \(index)",
                detail: "output \(index)"
            )
        }

        measure {
            let result = TranscriptReconciler.mergeSessionItems(
                snapshot,
                turnId: "turn.large",
                into: snapshot
            )
            XCTAssertEqual(result.count, 1_500)
        }
    }

    func testLateOlderHistoryTurnIsPlacedBeforeTheCurrentTurn() {
        let olderPrompt = item(id: "user.old", turnId: "turn.old", role: .user, text: "older prompt")
        let olderAnswer = item(id: "answer.old", turnId: "turn.old", role: .assistant, text: "older answer")
        let currentPrompt = item(id: "user.current", turnId: "turn.current", role: .user, text: "current prompt")
        let currentProgress = item(id: "progress.current", turnId: "turn.current", role: .assistant, text: "working", phase: "commentary")

        let result = TranscriptReconciler.mergeHistoryItems(
            [olderPrompt, olderAnswer, currentPrompt],
            into: [currentPrompt, currentProgress]
        )

        XCTAssertEqual(result.map(\.id), ["user.old", "answer.old", "user.current", "progress.current"])
    }

    func testSnapshotReplacesEquivalentLiveItemWithoutChangingItsIdentity() {
        let live = item(id: "live.1", turnId: "turn.1", role: .assistant, text: "正在检查  项目", phase: "commentary")
        let snapshot = item(id: "rollout.9", turnId: "turn.1", role: .assistant, text: "正在检查 项目", phase: "commentary")

        let result = TranscriptReconciler.mergeSessionItems([snapshot], turnId: "turn.1", into: [live])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.id, "live.1")
        XCTAssertEqual(result.first?.text, "正在检查 项目")
    }

    func testSnapshotMatchesCodexUserMessageAcrossHistoryAndRolloutIds() {
        let historyPrompt = item(id: "item-5432", turnId: "turn.1", role: .user, text: "继续")
        let progress = item(id: "progress.1", turnId: "turn.1", role: .assistant, text: "处理中", phase: "commentary")
        let answer = item(id: "answer.1", turnId: "turn.1", role: .assistant, text: "完成")
        let rolloutPrompt = TranscriptItem(
            id: "msg_019fbbb4-b230-7052-bdc3-0adcb08086d1",
            turnId: "turn.1",
            role: .user,
            kind: .message,
            text: "继续",
            createdAt: Date(timeIntervalSince1970: 1_000)
        )

        let result = TranscriptReconciler.mergeSessionItems(
            [rolloutPrompt, progress, answer],
            turnId: "turn.1",
            into: [progress, answer, historyPrompt]
        )

        XCTAssertEqual(result.map(\.id), ["item-5432", "progress.1", "answer.1"])
        XCTAssertEqual(result.filter { $0.role == .user }.count, 1)
    }

    func testHistoryMovesMatchedInitialPromptAheadOfExistingTurnOutput() {
        let rolloutPrompt = item(id: "msg_1", turnId: "turn.1", role: .user, text: "继续")
        let progress = item(id: "progress.1", turnId: "turn.1", role: .assistant, text: "处理中", phase: "commentary")
        let answer = item(id: "answer.1", turnId: "turn.1", role: .assistant, text: "完成")
        let historyPrompt = item(id: "item-1", turnId: "turn.1", role: .user, text: "继续")

        let result = TranscriptReconciler.mergeHistoryItems(
            [historyPrompt, answer],
            into: [progress, answer, rolloutPrompt]
        )

        XCTAssertEqual(result.map(\.id), ["msg_1", "progress.1", "answer.1"])
    }

    func testSnapshotPreservesTwoGenuineIdenticalPromptsByOccurrence() {
        let firstHistory = item(id: "item-1", turnId: "turn.1", role: .user, text: "继续")
        let secondHistory = item(id: "item-2", turnId: "turn.1", role: .user, text: "继续")
        let firstRollout = item(id: "msg_1", turnId: "turn.1", role: .user, text: "继续")
        let secondRollout = item(id: "msg_2", turnId: "turn.1", role: .user, text: "继续")

        let result = TranscriptReconciler.mergeSessionItems(
            [firstRollout, secondRollout],
            turnId: "turn.1",
            into: [firstHistory, secondHistory]
        )

        XCTAssertEqual(result.map(\.id), ["item-1", "item-2"])
    }

    func testUpsertPreservesRepeatedSameSourcePromptInOneTurn() {
        var messages = [item(id: "msg_1", turnId: "turn.1", role: .user, text: "继续")]
        TranscriptReconciler.upsert(
            item(id: "msg_2", turnId: "turn.1", role: .user, text: "继续"),
            into: &messages
        )
        XCTAssertEqual(messages.map(\.id), ["msg_1", "msg_2"])
    }

    func testUpsertPreservesSamePromptAcrossDifferentTurns() {
        var messages = [item(id: "item-1", turnId: "turn.1", role: .user, text: "继续")]
        TranscriptReconciler.upsert(
            item(id: "msg_2", turnId: "turn.2", role: .user, text: "继续"),
            into: &messages
        )
        XCTAssertEqual(messages.map(\.id), ["item-1", "msg_2"])
    }

    func testUpsertMergesOneCodexPromptReportedByHistoryAndRollout() {
        var messages = [item(id: "msg_1", turnId: "turn.1", role: .user, text: "继续")]
        TranscriptReconciler.upsert(
            item(id: "item-1", turnId: "turn.1", role: .user, text: "继续"),
            into: &messages
        )
        XCTAssertEqual(messages.map(\.id), ["msg_1"])
    }

    func testSessionPatchKeepsExistingIdentityForEquivalentCodexPrompt() {
        let result = TranscriptReconciler.mergeSessionPatchItems(
            [item(id: "msg_1", turnId: "turn.1", role: .user, text: "继续")],
            removedItemIds: [],
            turnId: "turn.1",
            into: [item(id: "item-1", turnId: "turn.1", role: .user, text: "继续")]
        )
        XCTAssertEqual(result.map(\.id), ["item-1"])
    }

    func testDelayedOlderTurnEventIsInsertedBeforeCurrentTurn() {
        var messages = [
            item(id: "old.user", turnId: "turn.old", role: .user, text: "旧任务"),
            item(id: "live.user", turnId: "turn.live", role: .user, text: "当前任务"),
            item(id: "live.progress", turnId: "turn.live", role: .assistant, text: "处理中", phase: "commentary"),
        ]
        TranscriptReconciler.upsert(
            TranscriptItem(id: "old.command", turnId: "turn.old", role: .tool, kind: .command, text: "npm test"),
            into: &messages
        )
        XCTAssertEqual(messages.map(\.id), ["old.user", "old.command", "live.user", "live.progress"])
    }

    func testAgentMessageSeparatesThinkingMarkupFromVisibleProgress() throws {
        let content = AgentMessageContent.parse(
            "<thinking>**Planning**\n**Checking layout**</thinking>\n正在检查对话布局。"
        )

        XCTAssertTrue(content.containsThinking)
        XCTAssertEqual(content.thinkingText, "**Planning**\n**Checking layout**")
        XCTAssertEqual(content.visibleText, "正在检查对话布局。")

        let parsed = try XCTUnwrap(TranscriptItem.from(json: .object([
            "id": .string("message.1"),
            "type": .string("agentMessage"),
            "text": .string("<thinking>**Planning**</thinking>\n正在检查。")
        ]), turnId: "turn.1"))
        XCTAssertEqual(parsed.phase, "commentary")
        XCTAssertEqual(parsed.detail, "**Planning**")
        XCTAssertEqual(parsed.text, "正在检查。")
    }

    func testSplitThinkingTagAcrossDeltaFlushesDoesNotLeakMarkup() {
        let first = TranscriptDeltaUpdate(
            id: "message.live",
            turnId: "turn.1",
            role: .assistant,
            kind: .message,
            title: nil,
            text: "<think",
            detail: "",
            phase: "commentary"
        )
        let second = TranscriptDeltaUpdate(
            id: "message.live",
            turnId: "turn.1",
            role: .assistant,
            kind: .message,
            title: nil,
            text: "ing>**Checking**</thinking>\n进展内容",
            detail: "",
            phase: "commentary"
        )

        let partial = TranscriptReconciler.applyDeltaBatch([first], to: [])
        let result = TranscriptReconciler.applyDeltaBatch([second], to: partial)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].detail, "**Checking**")
        XCTAssertEqual(result[0].text, "进展内容")
        XCTAssertFalse(result[0].text.contains("<thinking>"))
    }

    func testSnapshotMergesLongerCommentaryPrefixAndUsesSnapshotOrder() {
        let liveProgress = item(id: "live.progress", turnId: "turn.1", role: .assistant, text: "正在检查对话", phase: "commentary")
        var streamedProgress = liveProgress
        streamedProgress.rawAgentText = liveProgress.text
        let prompt = item(id: "prompt.1", turnId: "turn.1", role: .user, text: "修复界面")
        let snapshotProgress = item(id: "snapshot.progress", turnId: "turn.1", role: .assistant, text: "正在检查对话布局和滚动状态", phase: "commentary")

        let result = TranscriptReconciler.mergeSessionItems(
            [prompt, snapshotProgress],
            turnId: "turn.1",
            into: [streamedProgress, prompt]
        )

        XCTAssertEqual(result.map(\.id), ["prompt.1", "live.progress"])
        XCTAssertEqual(result.last?.text, "正在检查对话布局和滚动状态")
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

    func testPlacementsKeepSendOrderWhenFollowUpsShareAStaleAnchor() {
        let initial = item(id: "prompt.1", turnId: "turn.1", role: .user, text: "开始")
        let progress = item(id: "progress.1", turnId: "turn.1", role: .assistant, text: "检查中", phase: "commentary")
        let firstFollowUp = item(id: "prompt.2", turnId: "turn.1", role: .user, text: "第一条引导")
        let secondFollowUp = item(id: "prompt.3", turnId: "turn.1", role: .user, text: "第二条引导")
        let placements = [
            "prompt.1": UserMessagePlacement(threadId: "thread.1", turnId: "turn.1", afterItemId: nil, sequence: 1),
            "prompt.2": UserMessagePlacement(threadId: "thread.1", turnId: "turn.1", afterItemId: "progress.1", sequence: 2),
            "prompt.3": UserMessagePlacement(threadId: "thread.1", turnId: "turn.1", afterItemId: "progress.1", sequence: 3),
        ]

        let result = TranscriptReconciler.applyUserMessagePlacements(
            placements,
            turnId: "turn.1",
            threadId: "thread.1",
            to: [secondFollowUp, progress, initial, firstFollowUp]
        )

        XCTAssertEqual(result.map(\.id), ["prompt.1", "progress.1", "prompt.2", "prompt.3"])
    }

    func testUpsertDoesNotDuplicateUserMessageFromHistory() {
        var messages = [item(id: "client.1", turnId: nil, role: .user, text: "执行测试")]
        TranscriptReconciler.upsert(item(id: "client.1", turnId: "turn.1", role: .user, text: "执行测试"), into: &messages)
        XCTAssertEqual(messages.count, 1)
    }

    func testOlderHistoryDoesNotStealAnUnboundRepeatedPrompt() {
        let pending = TranscriptItem(
            id: "relay.pending",
            role: .user,
            kind: .message,
            text: "继续",
            createdAt: Date(timeIntervalSince1970: 2_000)
        )
        let older = TranscriptItem(
            id: "item-old",
            turnId: "turn.old",
            role: .user,
            kind: .message,
            text: "继续",
            createdAt: Date(timeIntervalSince1970: 1_000)
        )

        let result = TranscriptReconciler.mergeHistoryItems([older], into: [pending])

        XCTAssertEqual(result.map(\.id), ["item-old", "relay.pending"])
        XCTAssertEqual(result.last?.turnId, nil)
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

    func testHighLoadDeltaBatchPreservesHistoryOrderAndTenMegabyteOutput() {
        let history = (0..<1_000).map { index in
            item(id: "history.\(index)", turnId: "turn.\(index / 10)", role: .assistant, text: "message \(index)")
        }
        let chunks = (0..<100).map { _ in String(repeating: "x", count: 100_000) }
        let update = TranscriptDeltaUpdate(
            id: "command.live",
            turnId: "turn.live",
            role: .tool,
            kind: .command,
            title: "运行命令",
            text: "",
            detail: chunks.joined()
        )

        let result = TranscriptReconciler.applyDeltaBatch([update], to: history)
        XCTAssertEqual(result.count, 1_001)
        XCTAssertEqual(result.prefix(1_000).map(\.id), history.map(\.id))
        XCTAssertEqual(result.filter { $0.id == "command.live" }.count, 1)
        XCTAssertEqual(result.last?.detail?.count, 10_000_000)
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
