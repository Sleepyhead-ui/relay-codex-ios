import XCTest
@testable import Relay

final class SidebarPreferencesSelectionTests: XCTestCase {
    func testMergesNestedBridgePreferences() {
        let selection = SidebarPreferencesSelection().merging(json: .object([
            "sidebar": .object([
                "organization": .string("singleList"),
                "sort": .string("recent")
            ])
        ]))

        XCTAssertEqual(selection.organization, .singleList)
        XCTAssertEqual(selection.sort, .recent)
    }

    func testUnknownValuesPreserveCurrentSelection() {
        let current = SidebarPreferencesSelection(organization: .singleList, sort: .recent)
        let selection = current.merging(json: .object([
            "organization": .string("unknown"),
            "sort": .string("unknown")
        ]))

        XCTAssertEqual(selection, current)
    }
}
