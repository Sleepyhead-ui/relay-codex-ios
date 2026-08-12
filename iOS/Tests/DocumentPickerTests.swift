import UniformTypeIdentifiers
import UIKit
import XCTest
@testable import Relay

@MainActor
final class DocumentPickerTests: XCTestCase {
    func testDocumentPickerDelegateReturnsSelectedURLs() {
        let expected = [URL(fileURLWithPath: "/tmp/relay.log")]
        var selected: [URL] = []
        let representable = RelayDocumentPicker(
            onPick: { selected = $0 },
            onCancel: {}
        )
        let coordinator = representable.makeCoordinator()
        let controller = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: true)

        coordinator.documentPicker(controller, didPickDocumentsAt: expected)

        XCTAssertEqual(selected, expected)
    }

    func testDocumentPickerDelegateReportsCancellation() {
        var cancelled = false
        let representable = RelayDocumentPicker(
            onPick: { _ in },
            onCancel: { cancelled = true }
        )
        let coordinator = representable.makeCoordinator()
        let controller = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: true)

        coordinator.documentPickerWasCancelled(controller)

        XCTAssertTrue(cancelled)
    }
}
