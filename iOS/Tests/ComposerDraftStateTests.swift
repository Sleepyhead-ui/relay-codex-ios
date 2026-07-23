import Combine
import XCTest
@testable import Relay

@MainActor
final class ComposerDraftStateTests: XCTestCase {
    func testEditingDraftDoesNotPublishGlobalStoreChange() {
        let store = RelayStore()
        var storeChangeCount = 0
        var draftValues: [String] = []
        let storeSubscription = store.objectWillChange.sink {
            storeChangeCount += 1
        }
        let draftSubscription = store.composerDraft.$text
            .dropFirst()
            .sink { draftValues.append($0) }

        store.composerText = "hello"
        store.composerText += " world"

        XCTAssertEqual(store.composerText, "hello world")
        XCTAssertEqual(draftValues, ["hello", "hello world"])
        XCTAssertEqual(storeChangeCount, 0)
        withExtendedLifetime((storeSubscription, draftSubscription)) {}
    }
}
