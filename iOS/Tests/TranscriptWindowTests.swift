import XCTest
@testable import Relay

final class TranscriptWindowTests: XCTestCase {
    func testKeepsOnlyTheNewestGroupsInStableOrder() {
        let messages = (0..<1_000).map { index in
            TranscriptItem(
                id: "message.\(index)",
                turnId: "turn.\(index)",
                role: .assistant,
                kind: .message,
                text: "message \(index)"
            )
        }
        let window = TranscriptWindow.build(messages: messages, metadata: [:], limit: 24)

        XCTAssertTrue(window.hasEarlierGroups)
        XCTAssertEqual(window.groups.count, 24)
        XCTAssertEqual(window.groups.first?.turnId, "turn.976")
        XCTAssertEqual(window.groups.last?.turnId, "turn.999")
    }

    func testExpandingWindowPreservesExistingGroupIdentity() {
        let messages = (0..<40).map { index in
            TranscriptItem(id: "message.\(index)", turnId: "turn.\(index)", role: .assistant, kind: .message, text: "\(index)")
        }
        let smaller = TranscriptWindow.build(messages: messages, metadata: [:], limit: 12)
        let larger = TranscriptWindow.build(messages: messages, metadata: [:], limit: 24)

        XCTAssertEqual(Array(larger.groups.suffix(12).map(\.id)), smaller.groups.map(\.id))
    }

    func testAppliesOneHundredStreamingFramesWithoutRebuildingGroups() {
        var messages = (0..<1_000).map { index in
            TranscriptItem(id: "message.\(index)", turnId: "turn.\(index)", role: .assistant, kind: .message, text: "\(index)")
        }
        var index = TranscriptIndex()
        index.rebuild(messages: messages)

        for _ in 0..<100 {
            let update = TranscriptDeltaUpdate(
                id: "message.999",
                turnId: "turn.999",
                role: .assistant,
                kind: .message,
                title: nil,
                text: ".",
                detail: ""
            )
            XCTAssertTrue(index.applyDeltaBatch([update], to: &messages))
        }

        let window = index.window(messages: messages, metadata: [:], limit: 24)
        XCTAssertEqual(index.fullRebuildCount, 1)
        XCTAssertEqual(index.incrementalUpdateCount, 100)
        XCTAssertEqual(window.groups.count, 24)
        XCTAssertTrue(window.groups.last?.items.first?.text.hasSuffix(String(repeating: ".", count: 100)) == true)
    }

    func testStreamingOnlyChangesTheAffectedGroupRevision() throws {
        var messages = [
            TranscriptItem(id: "old", turnId: "turn.old", role: .assistant, kind: .message, text: "old"),
            TranscriptItem(id: "live", turnId: "turn.live", role: .assistant, kind: .message, text: "live"),
        ]
        var index = TranscriptIndex()
        index.rebuild(messages: messages)
        let before = index.window(messages: messages, metadata: [:], limit: 10)

        XCTAssertTrue(index.applyDeltaBatch([
            TranscriptDeltaUpdate(
                id: "live",
                turnId: "turn.live",
                role: .assistant,
                kind: .message,
                title: nil,
                text: ".",
                detail: ""
            )
        ], to: &messages))

        let after = index.window(messages: messages, metadata: [:], limit: 10)
        XCTAssertEqual(try XCTUnwrap(before.groups.first).revision, try XCTUnwrap(after.groups.first).revision)
        XCTAssertNotEqual(try XCTUnwrap(before.groups.last).revision, try XCTUnwrap(after.groups.last).revision)
    }

    func testReturnsOnlyItemsForTheRequestedTurn() {
        let messages = [
            TranscriptItem(id: "old", turnId: "turn.old", role: .assistant, kind: .message, text: "old"),
            TranscriptItem(id: "live.progress", turnId: "turn.live", role: .assistant, kind: .message, text: "working", phase: "commentary"),
            TranscriptItem(id: "live.command", turnId: "turn.live", role: .tool, kind: .command, text: "npm test"),
        ]
        var index = TranscriptIndex()
        index.rebuild(messages: messages)

        XCTAssertEqual(index.items(forTurnId: "turn.live", messages: messages).map(\.id), ["live.progress", "live.command"])
        XCTAssertTrue(index.items(forTurnId: "missing", messages: messages).isEmpty)
    }

    func testReturnsOnlyTheNewestActivityItemsForARequestedTurn() {
        let messages = (0..<500).map { index in
            TranscriptItem(
                id: "item.\(index)",
                turnId: "turn.live",
                role: index.isMultiple(of: 2) ? .tool : .assistant,
                kind: index.isMultiple(of: 2) ? .command : .message,
                text: "item \(index)"
            )
        }
        var index = TranscriptIndex()
        index.rebuild(messages: messages)

        let activity = index.activityItems(forTurnId: "turn.live", messages: messages, limit: 3)
        XCTAssertEqual(activity.map(\.id), ["item.494", "item.496", "item.498"])
    }

    func testAdoptsOneHundredSessionPatchesWithoutRebuildingGroups() {
        var messages = (0..<1_000).map { index in
            TranscriptItem(id: "message.\(index)", turnId: "turn.\(index)", role: .assistant, kind: .message, text: "\(index)")
        }
        var index = TranscriptIndex()
        index.rebuild(messages: messages)

        for frame in 0..<100 {
            let next = TranscriptReconciler.mergeSessionPatchItems(
                [TranscriptItem(id: "message.999", turnId: "turn.999", role: .assistant, kind: .message, text: "999.\(frame)")],
                removedItemIds: [],
                turnId: "turn.999",
                into: messages
            )
            XCTAssertTrue(index.adoptReconciledUpserts(next, changedItemIds: ["message.999"]))
            messages = next
        }

        let window = index.window(messages: messages, metadata: [:], limit: 24)
        XCTAssertEqual(index.fullRebuildCount, 1)
        XCTAssertEqual(index.incrementalUpdateCount, 100)
        XCTAssertEqual(window.groups.last?.items.first?.text, "999.99")
    }

    func testRejectsMiddleInsertionSoCallerCanRebuildSafely() {
        let messages = [
            TranscriptItem(id: "one", turnId: "turn.1", role: .assistant, kind: .message, text: "one"),
            TranscriptItem(id: "two", turnId: "turn.2", role: .assistant, kind: .message, text: "two"),
        ]
        var index = TranscriptIndex()
        index.rebuild(messages: messages)
        let next = [
            messages[0],
            TranscriptItem(id: "middle", turnId: "turn.1", role: .tool, kind: .command, text: "command"),
            messages[1],
        ]

        XCTAssertFalse(index.adoptReconciledUpserts(next, changedItemIds: ["middle"]))
    }

    func testSessionPatchStaysIncrementalAfterDeltaAppendsAnItem() {
        var messages = [
            TranscriptItem(id: "one", turnId: "turn.1", role: .assistant, kind: .message, text: "one")
        ]
        var index = TranscriptIndex()
        index.rebuild(messages: messages)
        let delta = TranscriptDeltaUpdate(
            id: "command.1",
            turnId: "turn.1",
            role: .tool,
            kind: .command,
            title: "Run command",
            text: "npm test",
            detail: "running"
        )
        XCTAssertTrue(index.applyDeltaBatch([delta], to: &messages))

        let next = TranscriptReconciler.mergeSessionPatchItems(
            [TranscriptItem(id: "command.1", turnId: "turn.1", role: .tool, kind: .command, text: "npm test", detail: "passed")],
            removedItemIds: [],
            turnId: "turn.1",
            into: messages
        )
        XCTAssertTrue(index.adoptReconciledUpserts(next, changedItemIds: ["command.1"]))
        XCTAssertEqual(index.fullRebuildCount, 1)
        XCTAssertEqual(index.incrementalUpdateCount, 2)
    }

    func testDelayedDeltaIsInsertedIntoItsTurnAndRebuildsTheIndex() {
        var messages = [
            TranscriptItem(id: "old.user", turnId: "turn.old", role: .user, kind: .message, text: "old"),
            TranscriptItem(id: "live.user", turnId: "turn.live", role: .user, kind: .message, text: "live"),
            TranscriptItem(id: "live.progress", turnId: "turn.live", role: .assistant, kind: .message, text: "working", phase: "commentary"),
        ]
        var index = TranscriptIndex()
        index.rebuild(messages: messages)
        let delta = TranscriptDeltaUpdate(
            id: "old.command",
            turnId: "turn.old",
            role: .tool,
            kind: .command,
            title: "Run command",
            text: "npm test",
            detail: "passed"
        )

        XCTAssertTrue(index.applyDeltaBatch([delta], to: &messages))
        XCTAssertEqual(messages.map(\.id), ["old.user", "old.command", "live.user", "live.progress"])
        XCTAssertEqual(index.fullRebuildCount, 2)
        XCTAssertEqual(index.window(messages: messages, metadata: [:], limit: 10).groups.map(\.turnId), ["turn.old", "turn.live"])
    }
}
