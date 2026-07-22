import XCTest
@testable import Relay

final class IncrementalMarkdownDocumentTests: XCTestCase {
    func testAppendedTailMatchesFullMarkdownParse() {
        var document = IncrementalMarkdownDocument(source: "第一段\n\n第二段")
        XCTAssertEqual(document.stableBlocks.count, 1)

        document.update(source: "第一段\n\n第二段继续\n\n- 项目一\n- 项目二")
        XCTAssertEqual(document.blocks, MarkdownParser.parseUncached(document.source))
        XCTAssertGreaterThanOrEqual(document.stableBlocks.count, 2)
    }

    func testBlankLinesInsideCodeFenceAreNotPromoted() {
        let source = "说明\n\n```swift\nlet value = 1\n\nprint(value)\n```\n\n完成"
        let prefix = IncrementalMarkdownDocument.safeStablePrefix(in: source)
        XCTAssertTrue(prefix.contains("```swift"))
        XCTAssertTrue(prefix.contains("```\n\n"))
        XCTAssertFalse(prefix.contains("完成"))

        let document = IncrementalMarkdownDocument(source: source)
        XCTAssertEqual(document.blocks, MarkdownParser.parseUncached(source))
    }

    func testReplacementResetsIncrementalState() {
        var document = IncrementalMarkdownDocument(source: "旧内容\n\n尾部")
        document.update(source: "完全不同的内容")
        XCTAssertEqual(document.source, "完全不同的内容")
        XCTAssertEqual(document.blocks, MarkdownParser.parseUncached("完全不同的内容"))
    }

    func testStreamingTailDoesNotRescanStableHistory() {
        let prefix = String(repeating: "稳定段落\n\n", count: 1_000)
        let document = IncrementalMarkdownDocument(source: "\(prefix)尾部")
        let before = document.processedCharacters

        for frame in 1...100 {
            document.update(source: "\(prefix)尾部\(String(repeating: ".", count: frame))")
        }

        XCTAssertLessThan(document.processedCharacters - before, 20_000)
        XCTAssertEqual(document.blocks, MarkdownParser.parseUncached(document.source))
    }
}
