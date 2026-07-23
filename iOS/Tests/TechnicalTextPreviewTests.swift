import XCTest
@testable import Relay

final class TechnicalTextPreviewTests: XCTestCase {
    func testTenMegabyteCommandOutputStaysBoundedAndKeepsTheTail() {
        let source = String(repeating: "old output\n", count: 1_000_000) + "latest line"
        let preview = TechnicalTextPreview.make(source: source)

        XCTAssertGreaterThan(preview.omittedBytes, 9_000_000)
        XCTAssertLessThan(preview.text.utf8.count, 24_100)
        XCTAssertLessThanOrEqual(preview.lineCount, 13)
        XCTAssertTrue(preview.text.hasSuffix("latest line"))
    }

    func testShortOutputIsUnchanged() {
        let preview = TechnicalTextPreview.make(source: "first\nsecond")
        XCTAssertEqual(preview.text, "first\nsecond")
        XCTAssertEqual(preview.lineCount, 2)
        XCTAssertEqual(preview.omittedBytes, 0)
    }
}
