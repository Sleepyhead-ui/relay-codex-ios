import XCTest
@testable import Relay

final class PairingPayloadTests: XCTestCase {
    func testParsesRelayPairingURL() throws {
        let url = try XCTUnwrap(URL(string: "relay://connect?url=ws%3A%2F%2F100.80.115.15%3A8765&token=secret-token&name=Studio%20PC"))
        let payload = try XCTUnwrap(PairingPayload(url: url))

        XCTAssertEqual(payload.endpoint, "ws://100.80.115.15:8765")
        XCTAssertEqual(payload.token, "secret-token")
        XCTAssertEqual(payload.computerName, "Studio PC")
    }

    func testRejectsNonRelayAndIncompleteURLs() {
        XCTAssertNil(PairingPayload(url: URL(string: "https://example.com/?token=secret")!))
        XCTAssertNil(PairingPayload(url: URL(string: "relay://connect?url=ws%3A%2F%2Fhost%3A8765")!))
        XCTAssertNil(PairingPayload(url: URL(string: "relay://connect?url=https%3A%2F%2Fhost&token=secret")!))
    }
}
