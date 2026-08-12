import XCTest
@testable import Relay

final class MobileActivityFeedTests: XCTestCase {
    func testElapsedTimeUsesANaturalStartupLabel() {
        XCTAssertEqual(MobileActivityElapsedFormatter.text(seconds: nil), "--:--")
        XCTAssertEqual(MobileActivityElapsedFormatter.text(seconds: 0), "刚刚")
        XCTAssertEqual(MobileActivityElapsedFormatter.text(seconds: 1), "刚刚")
        XCTAssertEqual(MobileActivityElapsedFormatter.text(seconds: 2), "2秒")
        XCTAssertEqual(MobileActivityElapsedFormatter.text(seconds: 69), "1分 09秒")
    }

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

    func testUsesEmbeddedThinkingAsLatestReasoningWithoutDroppingProgress() {
        let commentary = TranscriptItem(
            id: "commentary.1",
            turnId: "turn.1",
            role: .assistant,
            kind: .message,
            text: "正在核对实时事件",
            detail: "**Checking event phases**",
            phase: "commentary"
        )

        let feed = MobileActivityFeed.make(items: [commentary])

        XCTAssertEqual(feed.latestReasoningText, "Checking event phases")
        XCTAssertEqual(feed.progressItems.map(\.text), ["正在核对实时事件"])
    }

    func testExposesSeparateProgressAndToolCollections() {
        let progress = progress(id: "one", text: "正在构建界面")
        let command = TranscriptItem(
            id: "command.1",
            turnId: "turn.1",
            role: .tool,
            kind: .command,
            text: "xcodebuild test"
        )

        let feed = MobileActivityFeed.make(items: [progress, command])

        XCTAssertEqual(feed.progressItems.map(\.id), ["progress.one"])
        XCTAssertEqual(feed.toolItems.map(\.id), ["command.1"])
        XCTAssertNotEqual(feed.progressRevision, "progress.empty")
        XCTAssertNotEqual(feed.toolRevision, "tools.empty")
    }

    func testSeparatesCommandsAndCountsTheirStatuses() {
        let succeeded = TranscriptItem(
            id: "command.success",
            turnId: "turn.1",
            role: .tool,
            kind: .command,
            text: "npm test",
            status: "completed",
            exitCode: 0
        )
        let failed = TranscriptItem(
            id: "command.failed",
            turnId: "turn.1",
            role: .tool,
            kind: .command,
            text: "npm run build",
            status: "failed",
            exitCode: 1
        )
        let running = TranscriptItem(
            id: "command.running",
            turnId: "turn.1",
            role: .tool,
            kind: .command,
            text: "xcodebuild test",
            status: "inProgress"
        )
        let search = TranscriptItem(
            id: "search.1",
            turnId: "turn.1",
            role: .tool,
            kind: .webSearch,
            text: "Relay"
        )

        let feed = MobileActivityFeed.make(items: [succeeded, failed, running, search])

        XCTAssertEqual(feed.commandItems.map(\.id), ["command.success", "command.failed", "command.running"])
        XCTAssertEqual(feed.currentCommand?.id, "command.running")
        XCTAssertEqual(feed.successfulCommandCount, 1)
        XCTAssertEqual(feed.failedCommandCount, 1)
    }

    func testSummarizesFileChangesAndMapsHeaderPaths() {
        let fileChange = TranscriptItem(
            id: "file.1",
            turnId: "turn.1",
            role: .tool,
            kind: .fileChange,
            text: "Sources/App.swift\nSources/Store.swift",
            detail: "--- a/Sources/App.swift\n+++ b/Sources/App.swift\n@@ -1 +1 @@\n-old\n+new\n--- a/Sources/Store.swift\n+++ b/Sources/Store.swift\n@@ -0,0 +1,2 @@\n+one\n+two"
        )

        let summary = MobileActivityFeed.make(items: [fileChange]).fileChangeSummary

        XCTAssertEqual(summary.added, 3)
        XCTAssertEqual(summary.removed, 1)
        XCTAssertTrue(summary.hasLineCounts)
        XCTAssertEqual(summary.items, [
            MobileFileChangeItem(path: "Sources/App.swift", added: 1, removed: 1),
            MobileFileChangeItem(path: "Sources/Store.swift", added: 2, removed: 0)
        ])
    }

    func testDoesNotInventFileLineCountsWhenDiffIsMissing() {
        let fileChange = TranscriptItem(
            id: "file.1",
            turnId: "turn.1",
            role: .tool,
            kind: .fileChange,
            text: "App.swift"
        )

        let summary = MobileActivityFeed.make(items: [fileChange]).fileChangeSummary

        XCTAssertFalse(summary.hasLineCounts)
        XCTAssertEqual(summary.items, [
            MobileFileChangeItem(path: "App.swift", added: nil, removed: nil)
        ])
    }

    func testToolRevisionIgnoresInvisibleStreamingDetail() {
        let first = TranscriptItem(
            id: "command.1",
            turnId: "turn.1",
            role: .tool,
            kind: .command,
            text: "xcodebuild test",
            detail: "first frame",
            status: "inProgress"
        )
        var second = first
        second.detail = "first frame\nsecond frame"

        XCTAssertEqual(
            MobileActivityFeed.make(items: [first]).toolRevision,
            MobileActivityFeed.make(items: [second]).toolRevision
        )
    }

    func testLatestReasoningKeepsStableIdentityAcrossStreamingUpdates() throws {
        let first = TranscriptItem(
            id: "reasoning.1",
            turnId: "turn.1",
            role: .tool,
            kind: .reasoning,
            text: "Planning"
        )
        let second = TranscriptItem(
            id: "reasoning.2",
            turnId: "turn.1",
            role: .tool,
            kind: .reasoning,
            text: "Checking tests"
        )

        let firstEntry = try XCTUnwrap(MobileActivityFeed.make(items: [first]).entries.first)
        let secondEntry = try XCTUnwrap(MobileActivityFeed.make(items: [first, second]).entries.first)

        XCTAssertEqual(firstEntry.id, secondEntry.id)
        XCTAssertEqual(secondEntry.id, "reasoning.latest")
    }

    func testKeepsDistinctProgressWithACommonPrefix() {
        let items = (0..<200).map { index in
            progress(id: "progress.\(index)", text: "正在检查第 \(index) 个独立步骤")
        }

        let feed = MobileActivityFeed.make(items: items)

        XCTAssertEqual(feed.progressItems.count, 200)
    }

    func testCollapsesALongSequenceOfPrefixStreamingFrames() {
        let text = "正在系统检查这段持续增长的任务进展输出"
        let items = (4...text.count).map { length in
            progress(id: "frame.\(length)", text: String(text.prefix(length)))
        }

        let feed = MobileActivityFeed.make(items: items)

        XCTAssertEqual(feed.progressItems.count, 1)
        XCTAssertEqual(feed.progressItems.first?.text, text)
        XCTAssertEqual(feed.progressItems.first?.id, "progress.frame.4")
    }

    func testCachesAFeedUntilTheTranscriptRevisionChanges() {
        var cache = MobileActivityFeedCache()
        var evaluations = 0
        func items() -> [TranscriptItem] {
            evaluations += 1
            return [progress(id: "progress.1", text: "Working")]
        }

        _ = cache.feed(threadId: "thread.1", turnId: "turn.1", transcriptRevision: 10, items: items())
        _ = cache.feed(threadId: "thread.1", turnId: "turn.1", transcriptRevision: 10, items: items())
        XCTAssertEqual(evaluations, 1)

        _ = cache.feed(threadId: "thread.1", turnId: "turn.1", transcriptRevision: 11, items: items())
        XCTAssertEqual(evaluations, 2)
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
