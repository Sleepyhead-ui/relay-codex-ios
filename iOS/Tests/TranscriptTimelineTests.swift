import XCTest
@testable import Relay

final class TranscriptTimelineTests: XCTestCase {
    func testMixedCodexAndRelayFixtureReplaysWithoutTimelineViolations() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "mixed-transcript-events",
            withExtension: "json"
        ))
        let frames = try JSONDecoder().decode([TranscriptReplayFrame].self, from: Data(contentsOf: url))
        var replay = TranscriptReplay()

        for frame in frames { try replay.apply(frame) }

        XCTAssertEqual(
            replay.messages.map(\.id),
            [
                "item-5432",
                "progress.old",
                "answer.old",
                "command.old",
                "msg_019fbbb4-b230-7052-bdc3-0adcb08086d2",
                "progress.current",
                "answer.current"
            ]
        )
        XCTAssertEqual(replay.messages.filter { $0.role == .user && $0.text == "继续" }.count, 1)
        XCTAssertTrue(TranscriptTimelineAudit.violations(in: replay.messages).isEmpty)
    }

    func testAuditFindsDuplicateIdsSplitTurnsAndOutputBeforePrompt() {
        let messages = [
            item(id: "duplicate", turnId: "turn.1", role: .assistant, text: "output"),
            item(id: "prompt.2", turnId: "turn.2", role: .user, text: "new"),
            item(id: "duplicate", turnId: "turn.1", role: .user, text: "old")
        ]

        let violations = TranscriptTimelineAudit.violations(in: messages)

        XCTAssertEqual(Set(violations.map(\.kind)), [
            .duplicateItemId,
            .splitTurn,
            .outputBeforeInitialPrompt
        ])
    }

    func testAuditAllowsAUserSteerAfterProgressInTheSameTurn() {
        let messages = [
            item(id: "prompt", turnId: "turn.1", role: .user, text: "start"),
            item(id: "progress", turnId: "turn.1", role: .assistant, text: "working"),
            item(id: "steer", turnId: "turn.1", role: .user, text: "continue")
        ]

        XCTAssertTrue(TranscriptTimelineAudit.violations(in: messages).isEmpty)
    }

    func testTraceUsesStableAliasesWithoutLeakingContent() throws {
        let recorder = TranscriptTraceRecorder(limit: 2, itemLimit: 4)
        let messages = [
            item(id: "item-secret", turnId: "turn-secret", role: .user, text: "private prompt"),
            item(id: "answer-secret", turnId: "turn-secret", role: .assistant, text: "private answer")
        ]
        recorder.record(
            source: "history.merge",
            threadId: "thread-secret",
            turnId: "turn-secret",
            revision: 7,
            messages: messages
        )

        let data = try JSONEncoder().encode(recorder.report(currentMessages: messages))
        let exported = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(exported.contains("private prompt"))
        XCTAssertFalse(exported.contains("private answer"))
        XCTAssertFalse(exported.contains("thread-secret"))
        XCTAssertFalse(exported.contains("turn-secret"))
        XCTAssertTrue(exported.contains("thread.1"))
        XCTAssertTrue(exported.contains("content.1"))
    }

    func testTraceIgnoresTextOnlyStreamingChangesAndKeepsBoundedStructuralEvents() {
        let recorder = TranscriptTraceRecorder(limit: 2, itemLimit: 4)
        var messages = [item(id: "answer", turnId: "turn.1", role: .assistant, text: "a")]
        recorder.record(source: "delta.insert", threadId: "thread.1", turnId: "turn.1", revision: 1, messages: messages)
        messages[0].text = "a much longer streamed answer"
        recorder.record(source: "delta.batch", threadId: "thread.1", turnId: "turn.1", revision: 2, messages: messages)
        messages.append(item(id: "command", turnId: "turn.1", role: .tool, text: "command"))
        recorder.record(source: "event.item/completed", threadId: "thread.1", turnId: "turn.1", revision: 3, messages: messages)
        messages.append(item(id: "next", turnId: "turn.2", role: .user, text: "next"))
        recorder.record(source: "history.merge", threadId: "thread.1", turnId: "turn.2", revision: 4, messages: messages)

        let report = recorder.report(currentMessages: messages)
        XCTAssertEqual(report["eventCount"]?.intValue, 2)
        XCTAssertEqual(report["events"]?.arrayValue?.map { $0["sequence"]?.intValue }, [2, 3])
    }

    private func item(
        id: String,
        turnId: String,
        role: TranscriptRole,
        text: String
    ) -> TranscriptItem {
        TranscriptItem(id: id, turnId: turnId, role: role, kind: .message, text: text)
    }
}
