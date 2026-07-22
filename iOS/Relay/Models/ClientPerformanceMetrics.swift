import Foundation

struct TimingMetricsSnapshot: Equatable {
    let count: Int
    let averageMs: Double
    let p50Ms: Double
    let p95Ms: Double
    let maxMs: Double

    var json: JSONValue {
        .object([
            "count": .number(Double(count)),
            "averageMs": .number(averageMs),
            "p50Ms": .number(p50Ms),
            "p95Ms": .number(p95Ms),
            "maxMs": .number(maxMs)
        ])
    }
}

struct BoundedTimingMonitor {
    private(set) var samples: [Double] = []
    private var total = 0.0
    private var maximum = 0.0
    let limit: Int

    init(limit: Int = 256) {
        self.limit = max(1, limit)
    }

    mutating func record(_ milliseconds: Double) {
        guard milliseconds.isFinite, milliseconds >= 0 else { return }
        samples.append(milliseconds)
        total += milliseconds
        maximum = max(maximum, milliseconds)
        if samples.count > limit {
            total -= samples.removeFirst()
            maximum = samples.max() ?? 0
        }
    }

    func snapshot() -> TimingMetricsSnapshot {
        let sorted = samples.sorted()
        return TimingMetricsSnapshot(
            count: sorted.count,
            averageMs: rounded(sorted.isEmpty ? 0 : total / Double(sorted.count)),
            p50Ms: rounded(percentile(sorted, fraction: 0.5)),
            p95Ms: rounded(percentile(sorted, fraction: 0.95)),
            maxMs: rounded(maximum)
        )
    }

    private func percentile(_ sorted: [Double], fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = min(sorted.count - 1, Int(floor(Double(sorted.count - 1) * fraction)))
        return sorted[index]
    }

    private func rounded(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }
}

final class ClientPerformanceMetrics: @unchecked Sendable {
    private let lock = NSLock()
    private var inboundMessages = 0
    private var inboundBytes = 0
    private var decodeFailures = 0
    private var sessionSnapshots = 0
    private var sessionPatches = 0
    private var revisionGaps = 0
    private var sessionRecoveries = 0
    private var queuedDeltas = 0
    private var deltaFlushes = 0
    private var updatedDeltaItems = 0
    private var maxItemsPerFlush = 0
    private var decodeLatency = BoundedTimingMonitor()
    private var snapshotApplyLatency = BoundedTimingMonitor()
    private var patchApplyLatency = BoundedTimingMonitor()
    private var deltaFlushLatency = BoundedTimingMonitor()

    func recordInboundMessage(bytes: Int) {
        withLock {
            inboundMessages += 1
            inboundBytes += max(0, bytes)
        }
    }

    func recordDecode(milliseconds: Double) {
        withLock { decodeLatency.record(milliseconds) }
    }

    func recordDecodeFailure() {
        withLock { decodeFailures += 1 }
    }

    func recordSessionSnapshot(milliseconds: Double) {
        withLock {
            sessionSnapshots += 1
            snapshotApplyLatency.record(milliseconds)
        }
    }

    func recordSessionPatch(milliseconds: Double) {
        withLock {
            sessionPatches += 1
            patchApplyLatency.record(milliseconds)
        }
    }

    func recordRevisionGap() {
        withLock { revisionGaps += 1 }
    }

    func recordSessionRecovery() {
        withLock { sessionRecoveries += 1 }
    }

    func recordQueuedDelta() {
        withLock { queuedDeltas += 1 }
    }

    func recordDeltaFlush(items: Int, milliseconds: Double) {
        withLock {
            deltaFlushes += 1
            updatedDeltaItems += max(0, items)
            maxItemsPerFlush = max(maxItemsPerFlush, items)
            deltaFlushLatency.record(milliseconds)
        }
    }

    func report() -> JSONValue {
        withLock {
            .object([
                "network": .object([
                    "inboundMessages": .number(Double(inboundMessages)),
                    "inboundBytes": .number(Double(inboundBytes)),
                    "decodeFailures": .number(Double(decodeFailures)),
                    "decodeLatency": decodeLatency.snapshot().json
                ]),
                "sessions": .object([
                    "snapshots": .number(Double(sessionSnapshots)),
                    "patches": .number(Double(sessionPatches)),
                    "revisionGaps": .number(Double(revisionGaps)),
                    "recoveries": .number(Double(sessionRecoveries)),
                    "snapshotApplyLatency": snapshotApplyLatency.snapshot().json,
                    "patchApplyLatency": patchApplyLatency.snapshot().json
                ]),
                "deltas": .object([
                    "queued": .number(Double(queuedDeltas)),
                    "flushes": .number(Double(deltaFlushes)),
                    "updatedItems": .number(Double(updatedDeltaItems)),
                    "maxItemsPerFlush": .number(Double(maxItemsPerFlush)),
                    "flushLatency": deltaFlushLatency.snapshot().json
                ])
            ])
        }
    }

    private func withLock<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}

enum ClientPerformanceClock {
    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    static func milliseconds(since startedAt: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
    }
}
