import XCTest
@testable import Relay

final class QueuedFollowUpTests: XCTestCase {
    func testQueuedFollowUpsClearlyCommunicateTheirEditableWindow() {
        XCTAssertEqual(FollowUpBehavior.queue.title, "等待处理")
        XCTAssertTrue(FollowUpBehavior.queue.detail.contains("处理前可编辑"))
        XCTAssertEqual(FollowUpBehavior.steer.title, "立即引导")
        XCTAssertTrue(FollowUpBehavior.steer.detail.contains("不可编辑"))
    }

    func testPreservesOriginalInputsForSafeEditing() {
        let json = JSONValue.object([
            "id": .string("queue.1"),
            "threadId": .string("thread.1"),
            "text": .string("before"),
            "createdAt": .number(1_800_000_000),
            "input": .array([
                .object(["type": .string("text"), "text": .string("before")]),
                .object([
                    "type": .string("localImage"),
                    "path": .string("C:\\workspace\\preview.png")
                ]),
                .object([
                    "type": .string("mention"),
                    "name": .string("notes.txt"),
                    "path": .string("C:\\workspace\\notes.txt")
                ])
            ])
        ])

        let item = QueuedFollowUp(json: json)

        XCTAssertEqual(item?.text, "before")
        XCTAssertEqual(item?.attachmentNames, ["preview.png", "notes.txt"])
        XCTAssertEqual(item?.imagePaths, ["C:\\workspace\\preview.png"])
        XCTAssertEqual(item?.nonImageAttachmentNames, ["notes.txt"])
        XCTAssertEqual(item?.input.count, 3)
    }
}
