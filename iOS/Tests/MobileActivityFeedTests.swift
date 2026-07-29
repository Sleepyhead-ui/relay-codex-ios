import XCTest
@testable import Relay

final class MobileActivityFeedTests: XCTestCase {
    func testFiltersPassiveWaitTools() {
        let wait = TranscriptItem(
            id: "wait.1",
            turnId: "turn.1",
            role: .tool,
            kind: .other,
            title: "运行工具",
            text: "wait"
        )
        let feed = MobileActivityFeed.make(items: [wait])

        XCTAssertTrue(feed.entries.isEmpty)
        XCTAssertEqual(feed.hiddenPassiveEventCount, 1)
    }

    func testKeepsAllDistinctProgressAndOnlyLatestReasoning() {
        let first = TranscriptItem(
            id: "progress.1",
            turnId: "turn.1",
            role: .assistant,
            kind: .message,
            text: "正在检查布局",
            phase: "commentary"
        )
        let second = TranscriptItem(
            id: "progress.2",
            turnId: "turn.1",
            role: .assistant,
            kind: .message,
            text: "正在运行测试",
            phase: "commentary"
        )
        let oldReasoning = TranscriptItem(
            id: "reasoning.1",
            turnId: "turn.1",
            role: .tool,
            kind: .reasoning,
            text: "Planning"
        )
        let latestReasoning = TranscriptItem(
            id: "reasoning.2",
            turnId: "turn.1",
            role: .tool,
            kind: .reasoning,
            text: "Checking tests"
        )

        let feed = MobileActivityFeed.make(items: [first, oldReasoning, second, latestReasoning])

        XCTAssertEqual(feed.entries.count, 3)
        XCTAssertEqual(feed.latestText, "Checking tests")
        XCTAssertTrue(feed.entries.contains(.progress(id: "progress.progress.1", text: "正在检查布局")))
        XCTAssertTrue(feed.entries.contains(.progress(id: "progress.progress.2", text: "正在运行测试")))
    }

    func testMergesPrefixUpdatesWithoutDroppingLaterProgress() {
        let partial = progress(id: "one", text: "正在检查")
        let complete = progress(id: "two", text: "正在检查对话布局")
        let next = progress(id: "three", text: "正在构建应用")

        let feed = MobileActivityFeed.make(items: [partial, complete, next])

        XCTAssertEqual(feed.entries.count, 2)
        XCTAssertEqual(feed.latestText, "正在构建应用")
    }

    func testGroupsAdjacentToolsAndSummarizesKinds() throws {
        let command = TranscriptItem(
            id: "command.1",
            turnId: "turn.1",
            role: .tool,
            kind: .command,
            text: "npm test"
        )
        let file = TranscriptItem(
            id: "file.1",
            turnId: "turn.1",
            role: .tool,
            kind: .fileChange,
            text: "App.swift"
        )

        let feed = MobileActivityFeed.make(items: [command, file])
        guard case .tools(_, let items) = try XCTUnwrap(feed.entries.first) else {
            return XCTFail("Expected grouped tools")
        }
        XCTAssertEqual(items.map(\.id), ["command.1", "file.1"])
        XCTAssertEqual(feed.completedSummary, "1 条命令 · 1 个文件")
    }

    private func progress(id: String, text: String) -> TranscriptItem {
        TranscriptItem(
            id: id,
            turnId: "turn.1",
            role: .assistant,
            kind: .message,
            text: text,
            phase: "commentary"
        )
    }
}
