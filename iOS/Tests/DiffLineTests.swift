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

    func testCountsBinaryAndRenameOnlyFilesFromGitHeaders() {
        let statistics = DiffStatistics.parse("""
        diff --git a/Assets/Icon.png b/Assets/Icon.png
        Binary files a/Assets/Icon.png and b/Assets/Icon.png differ
        diff --git a/Sources/Old Name.swift b/Sources/New Name.swift
        similarity index 100%
        rename from Sources/Old Name.swift
        rename to Sources/New Name.swift
        """)

        XCTAssertEqual(statistics.files, [
            DiffFileStatistics(path: "Assets/Icon.png", added: 0, removed: 0),
            DiffFileStatistics(path: "Sources/New Name.swift", added: 0, removed: 0)
        ])
    }
}
