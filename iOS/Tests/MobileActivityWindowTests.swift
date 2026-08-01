import XCTest
@testable import Relay

final class MobileActivityWindowTests: XCTestCase {
    func testAppendingEntriesKeepsTheOldestVisibleEntryStable() {
        var entries = (0..<30).map(entry)
        var window = MobileActivityWindow(entries: entries, pageSize: 10)

        XCTAssertEqual(window.visibleEntries(in: entries).first?.id, "progress.20")

        entries.append(entry(30))
        window.synchronize(with: entries)

        XCTAssertEqual(window.visibleEntries(in: entries).first?.id, "progress.20")
        XCTAssertEqual(window.visibleEntries(in: entries).last?.id, "progress.30")
        XCTAssertEqual(window.hiddenEntryCount(in: entries), 20)
    }

    func testShowEarlierMovesTheStableAnchorBackByOnePage() {
        let entries = (0..<30).map(entry)
        var window = MobileActivityWindow(entries: entries, pageSize: 10)

        window.showEarlier(in: entries)

        XCTAssertEqual(window.visibleEntries(in: entries).first?.id, "progress.10")
        XCTAssertEqual(window.hiddenEntryCount(in: entries), 10)
    }

    func testFirstLiveEntryBecomesTheAnchorAfterStartingEmpty() {
        var window = MobileActivityWindow(entries: [], pageSize: 10)
        let entries = [entry(0), entry(1)]

        window.synchronize(with: entries)

        XCTAssertEqual(window.visibleEntries(in: entries).map(\.id), ["progress.0", "progress.1"])
    }

    private func entry(_ index: Int) -> MobileActivityEntry {
        .progress(id: "progress.\(index)", text: "step \(index)")
    }
}
