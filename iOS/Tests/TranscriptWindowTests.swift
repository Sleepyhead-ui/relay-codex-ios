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
}
