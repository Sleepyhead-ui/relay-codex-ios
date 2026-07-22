import XCTest
@testable import Relay

final class ProfileSwitchSelectionTests: XCTestCase {
    func testKeepsPreviousThreadWhenItBelongsToTheActiveProfile() {
        XCTAssertEqual(
            ProfileSwitchSelection.restoredThreadId(
                previous: "thread.current",
                availableThreadIds: ["thread.newest", "thread.current"]
            ),
            "thread.current"
        )
    }

    func testFallsBackToNewestThreadAfterChangingProfiles() {
        XCTAssertEqual(
            ProfileSwitchSelection.restoredThreadId(
                previous: "thread.from-old-profile",
                availableThreadIds: ["thread.newest", "thread.older"]
            ),
            "thread.newest"
        )
    }

    func testClearsSelectionWhenTheActiveProfileHasNoThreads() {
        XCTAssertNil(
            ProfileSwitchSelection.restoredThreadId(
                previous: "thread.from-old-profile",
                availableThreadIds: []
            )
        )
    }
}
