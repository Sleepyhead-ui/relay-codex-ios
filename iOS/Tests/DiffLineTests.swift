import XCTest
@testable import Relay

final class DiffLineTests: XCTestCase {
    func testClassifiesHeadersBeforeAddedAndRemovedLines() {
        let lines = DiffLine.parse("--- a/file.swift\n+++ b/file.swift\n@@ -1 +1 @@\n-old\n+new\n same")
        XCTAssertEqual(lines.map(\.kind), [.header, .header, .hunk, .removed, .added, .context])
    }

    func testCountsChangedLinesWithoutCountingHeaders() {
        let statistics = DiffStatistics.parse("--- a/file.swift\n+++ b/file.swift\n@@ -1,2 +1,3 @@\n-old\n+new\n+another\n same")

        XCTAssertEqual(statistics.added, 2)
        XCTAssertEqual(statistics.removed, 1)
        XCTAssertEqual(statistics.files, [
            DiffFileStatistics(path: "file.swift", added: 2, removed: 1)
        ])
    }

    func testUsesOldPathForDeletedFile() {
        let statistics = DiffStatistics.parse("--- a/Old.swift\n+++ /dev/null\n@@ -1 +0,0 @@\n-old")

        XCTAssertEqual(statistics.files, [
            DiffFileStatistics(path: "Old.swift", added: 0, removed: 1)
        ])
    }
}
