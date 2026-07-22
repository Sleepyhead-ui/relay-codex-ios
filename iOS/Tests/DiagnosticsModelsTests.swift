import XCTest
@testable import Relay

final class DiagnosticsModelsTests: XCTestCase {
    func testNumericBridgeEventIdIsAccepted() {
        let event = DiagnosticEvent(json: .object([
            "id": .number(7),
            "at": .string("2026-07-21T12:00:00.000Z"),
            "level": .string("warning"),
            "category": .string("socket"),
            "message": .string("Remote client disconnected.")
        ]))

        XCTAssertEqual(event?.id, "7")
        XCTAssertEqual(event?.level, "warning")
        XCTAssertEqual(event?.category, "socket")
    }

    func testParsesBridgeAndClientPerformanceReports() {
        let report = DiagnosticsReport(json: .object([
            "performance": .object([
                "sessions": .object(["snapshots": .number(4), "patches": .number(12), "patchToSnapshotByteRatio": .number(0.08)]),
                "rpcLatency": timing(p95: 42)
            ]),
            "clientPerformance": .object([
                "network": .object(["inboundMessages": .number(30), "inboundBytes": .number(2_048), "decodeLatency": timing(p95: 7)]),
                "sessions": .object(["snapshots": .number(2), "patches": .number(9), "revisionGaps": .number(1), "patchApplyLatency": timing(p95: 3)]),
                "deltas": .object(["flushes": .number(6), "maxItemsPerFlush": .number(4), "flushLatency": timing(p95: 5)])
            ])
        ]))

        XCTAssertEqual(report.bridgePerformance.patches, 12)
        XCTAssertEqual(report.bridgePerformance.rpcLatency.p95Ms, 42)
        XCTAssertEqual(report.clientPerformance.inboundBytes, 2_048)
        XCTAssertEqual(report.clientPerformance.revisionGaps, 1)
        XCTAssertEqual(report.clientPerformance.deltaFlushLatency.p95Ms, 5)
    }

    private func timing(p95: Double) -> JSONValue {
        .object(["count": .number(1), "averageMs": .number(p95), "p50Ms": .number(p95), "p95Ms": .number(p95), "maxMs": .number(p95)])
    }
}
