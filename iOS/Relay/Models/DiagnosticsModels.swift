import Foundation

struct DiagnosticCheck: Identifiable, Equatable {
    let id: String
    let level: String
    let title: String
    let detail: String

    init?(json: JSONValue) {
        guard let id = json["id"]?.stringValue,
              let title = json["title"]?.stringValue else { return nil }
        self.id = id
        level = json["level"]?.stringValue ?? "warning"
        self.title = title
        detail = json["detail"]?.stringValue ?? ""
    }
}

struct DiagnosticEvent: Identifiable, Equatable {
    let id: String
    let date: Date
    let level: String
    let category: String
    let message: String

    init?(json: JSONValue) {
        guard let id = json["id"]?.stringValue ?? json["id"]?.intValue.map(String.init),
              let message = json["message"]?.stringValue else { return nil }
        self.id = id
        level = json["level"]?.stringValue ?? "info"
        category = json["category"]?.stringValue ?? "relay"
        self.message = message
        date = ISO8601DateFormatter().date(from: json["at"]?.stringValue ?? "") ?? Date()
    }
}

struct DiagnosticTimingMetrics: Equatable {
    let count: Int
    let averageMs: Double
    let p50Ms: Double
    let p95Ms: Double
    let maxMs: Double

    init(json: JSONValue?) {
        count = json?["count"]?.intValue ?? 0
        averageMs = json?["averageMs"]?.doubleValue ?? 0
        p50Ms = json?["p50Ms"]?.doubleValue ?? 0
        p95Ms = json?["p95Ms"]?.doubleValue ?? 0
        maxMs = json?["maxMs"]?.doubleValue ?? 0
    }
}

struct ClientDiagnosticPerformance: Equatable {
    let inboundMessages: Int
    let inboundBytes: Int
    let decodeFailures: Int
    let decodeLatency: DiagnosticTimingMetrics
    let snapshots: Int
    let patches: Int
    let revisionGaps: Int
    let recoveries: Int
    let snapshotApplyLatency: DiagnosticTimingMetrics
    let patchApplyLatency: DiagnosticTimingMetrics
    let queuedDeltas: Int
    let deltaFlushes: Int
    let updatedDeltaItems: Int
    let maxItemsPerFlush: Int
    let deltaFlushLatency: DiagnosticTimingMetrics

    init(json: JSONValue?) {
        inboundMessages = json?["network"]?["inboundMessages"]?.intValue ?? 0
        inboundBytes = json?["network"]?["inboundBytes"]?.intValue ?? 0
        decodeFailures = json?["network"]?["decodeFailures"]?.intValue ?? 0
        decodeLatency = DiagnosticTimingMetrics(json: json?["network"]?["decodeLatency"])
        snapshots = json?["sessions"]?["snapshots"]?.intValue ?? 0
        patches = json?["sessions"]?["patches"]?.intValue ?? 0
        revisionGaps = json?["sessions"]?["revisionGaps"]?.intValue ?? 0
        recoveries = json?["sessions"]?["recoveries"]?.intValue ?? 0
        snapshotApplyLatency = DiagnosticTimingMetrics(json: json?["sessions"]?["snapshotApplyLatency"])
        patchApplyLatency = DiagnosticTimingMetrics(json: json?["sessions"]?["patchApplyLatency"])
        queuedDeltas = json?["deltas"]?["queued"]?.intValue ?? 0
        deltaFlushes = json?["deltas"]?["flushes"]?.intValue ?? 0
        updatedDeltaItems = json?["deltas"]?["updatedItems"]?.intValue ?? 0
        maxItemsPerFlush = json?["deltas"]?["maxItemsPerFlush"]?.intValue ?? 0
        deltaFlushLatency = DiagnosticTimingMetrics(json: json?["deltas"]?["flushLatency"])
    }
}

struct BridgeDiagnosticPerformance: Equatable {
    let snapshots: Int
    let patches: Int
    let patchToSnapshotByteRatio: Double
    let rpcLatency: DiagnosticTimingMetrics

    init(json: JSONValue?) {
        snapshots = json?["sessions"]?["snapshots"]?.intValue ?? 0
        patches = json?["sessions"]?["patches"]?.intValue ?? 0
        patchToSnapshotByteRatio = json?["sessions"]?["patchToSnapshotByteRatio"]?.doubleValue ?? 0
        rpcLatency = DiagnosticTimingMetrics(json: json?["rpcLatency"])
    }
}

struct DiagnosticsReport {
    let generatedAt: Date
    let summary: String
    let checks: [DiagnosticCheck]
    let events: [DiagnosticEvent]
    let clientPerformance: ClientDiagnosticPerformance
    let bridgePerformance: BridgeDiagnosticPerformance
    let raw: JSONValue

    init(json: JSONValue) {
        generatedAt = ISO8601DateFormatter().date(from: json["generatedAt"]?.stringValue ?? "") ?? Date()
        summary = json["summary"]?.stringValue ?? "warning"
        checks = (json["checks"]?.arrayValue ?? []).compactMap(DiagnosticCheck.init(json:))
        events = (json["events"]?.arrayValue ?? []).compactMap(DiagnosticEvent.init(json:))
        clientPerformance = ClientDiagnosticPerformance(json: json["clientPerformance"])
        bridgePerformance = BridgeDiagnosticPerformance(json: json["performance"])
        raw = json
    }
}
