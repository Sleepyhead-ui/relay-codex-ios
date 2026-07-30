import XCTest
@testable import Relay

final class NotificationPreviewTests: XCTestCase {
    func testRemovesThinkingAndMarkdownDecoration() {
        let source = """
        <thinking>internal detail</thinking>
        **完成**，请查看 [`RelayStore.swift`](https://example.com/file)。
        """

        XCTAssertEqual(NotificationPreview.text(from: source), "完成，请查看 RelayStore.swift。")
    }

    func testTruncatesLongTextAtRequestedLimit() {
        let result = NotificationPreview.text(from: String(repeating: "中", count: 30), limit: 12)

        XCTAssertEqual(result.count, 12)
        XCTAssertTrue(result.hasSuffix("…"))
    }

    func testPendingReplyRoundTripsThroughCodable() throws {
        let reply = PendingNotificationReply(
            id: "reply-1",
            threadId: "thread-1",
            text: "继续处理",
            createdAt: Date(timeIntervalSince1970: 123)
        )

        let decoded = try JSONDecoder().decode(
            PendingNotificationReply.self,
            from: JSONEncoder().encode(reply)
        )

        XCTAssertEqual(decoded, reply)
    }

    func testNotificationActionsPreserveTheirThread() {
        XCTAssertEqual(
            RelayNotificationAction.openThread("thread-1"),
            .openThread("thread-1")
        )
        XCTAssertEqual(
            RelayNotificationAction.reply(threadId: "thread-2", text: "继续"),
            .reply(threadId: "thread-2", text: "继续")
        )
    }
}
