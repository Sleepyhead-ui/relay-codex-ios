import XCTest
@testable import Relay

final class ClientPerformanceMetricsTests: XCTestCase {
    func testTimingSamplesStayBoundedAndReportPercentiles() {
        var timing = BoundedTimingMonitor(limit: 256)
        for value in 1...300 { timing.record(Double(value)) }

        let snapshot = timing.snapshot()
        XCTAssertEqual(snapshot.count, 256)
        XCTAssertGreaterThanOrEqual(snapshot.p95Ms, 280)
        XCTAssertEqual(snapshot.maxMs, 300)
    }

    func testClientReportIncludesSessionAndDeltaRecoveryMetrics() {
        let metrics = ClientPerformanceMetrics()
        metrics.recordInboundMessage(bytes: 1_024)
        metrics.recordDecode(milliseconds: 4)
        metrics.recordSessionSnapshot(milliseconds: 8)
        metrics.recordSessionPatch(milliseconds: 2)
        metrics.recordRevisionGap()
        metrics.recordSessionRecovery()
        metrics.recordQueuedDelta()
        metrics.recordDeltaFlush(items: 3, milliseconds: 5)

        let report = metrics.report()
        XCTAssertEqual(report["network"]?["inboundBytes"]?.intValue, 1_024)
        XCTAssertEqual(report["sessions"]?["patches"]?.intValue, 1)
        XCTAssertEqual(report["sessions"]?["revisionGaps"]?.intValue, 1)
        XCTAssertEqual(report["deltas"]?["maxItemsPerFlush"]?.intValue, 3)
        XCTAssertEqual(report["deltas"]?["flushLatency"]?["p95Ms"]?.doubleValue, 5)
    }
}
