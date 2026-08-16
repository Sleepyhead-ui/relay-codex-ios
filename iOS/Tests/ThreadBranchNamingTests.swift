import XCTest
@testable import Relay

final class ThreadBranchNamingTests: XCTestCase {
    func testAddsSecondSuffixToTheFirstFork() {
        XCTAssertEqual(
            ThreadBranchNaming.nextTitle(sourceTitle: "Relay mobile", existingTitles: ["Relay mobile"]),
            "Relay mobile (2)"
        )
    }

    func testIncrementsAcrossExistingBranches() {
        XCTAssertEqual(
            ThreadBranchNaming.nextTitle(
                sourceTitle: "Relay mobile",
                existingTitles: ["Relay mobile", "Relay mobile (2)", "Relay mobile (4)"]
            ),
            "Relay mobile (5)"
        )
    }

    func testForkingANumberedBranchKeepsTheOriginalFamilyName() {
        XCTAssertEqual(
            ThreadBranchNaming.nextTitle(
                sourceTitle: "Relay mobile (2)",
                existingTitles: ["Relay mobile", "Relay mobile (2)", "Relay mobile (3)"]
            ),
            "Relay mobile (4)"
        )
    }

    func testPreservesAUserTitleThatMerelyEndsInAParenthesizedNumber() {
        XCTAssertEqual(
            ThreadBranchNaming.nextTitle(sourceTitle: "Release notes (2026)", existingTitles: ["Release notes (2026)"]),
            "Release notes (2026) (2)"
        )
    }
}
