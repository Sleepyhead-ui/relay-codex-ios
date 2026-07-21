import XCTest
@testable import Relay

final class DiffLineTests: XCTestCase {
    func testClassifiesHeadersBeforeAddedAndRemovedLines() {
        let lines = DiffLine.parse("--- a/file.swift\n+++ b/file.swift\n@@ -1 +1 @@\n-old\n+new\n same")
        XCTAssertEqual(lines.map(\.kind), [.header, .header, .hunk, .removed, .added, .context])
    }
}
