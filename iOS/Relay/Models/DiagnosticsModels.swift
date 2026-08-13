import Foundation

struct AppBuildIdentity: Equatable {
    let version: String
    let build: String
    let commit: String

    init(infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:]) {
        version = infoDictionary["CFBundleShortVersionString"] as? String ?? "未知"
        build = infoDictionary["CFBundleVersion"] as? String ?? "未知"
        let rawCommit = infoDictionary["RelayGitCommit"] as? String ?? "未知"
        commit = rawCommit.count > 12 ? String(rawCommit.prefix(12)) : rawCommit
    }

    var displayText: String {
        "v\(version) (\(build)) · \(commit)"
    }

    var json: JSONValue {
        .object([
            "version": .string(version),
            "build": .string(build),
            "commit": .string(commit)
        ])
    }
}

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

struct BridgeTurnLatencyDiagnostic: Identifiable, Equatable {
    let id: String
    let threadId: String
    let turnId: String?
    let model: String?
    let effort: String?
    let summary: String?
    let receivedAt: Date
    let receivedToForwardMs: Double?
    let forwardToAcceptedMs: Double?
    let acceptedToStartedMs: Double?
    let startedToFirstEventMs: Double?
    let startedToFirstVisibleMs: Double?
    let totalToFirstVisibleMs: Double?
    let totalDurationMs: Double
    let firstVisibleMethod: String?

    init?(json: JSONValue) {
        guard let clientUserMessageId = json["clientUserMessageId"]?.stringValue,
              let threadId = json["threadId"]?.stringValue else { return nil }
        id = json["turnId"]?.stringValue ?? clientUserMessageId
        self.threadId = threadId
        turnId = json["turnId"]?.stringValue
        model = json["model"]?.stringValue
        effort = json["effort"]?.stringValue
        summary = json["summary"]?.stringValue
        receivedAt = ISO8601DateFormatter().date(from: json["receivedAt"]?.stringValue ?? "") ?? Date()
        receivedToForwardMs = json["receivedToForwardMs"]?.doubleValue
        forwardToAcceptedMs = json["forwardToAcceptedMs"]?.doubleValue
        acceptedToStartedMs = json["acceptedToStartedMs"]?.doubleValue
        startedToFirstEventMs = json["startedToFirstEventMs"]?.doubleValue
        startedToFirstVisibleMs = json["startedToFirstVisibleMs"]?.doubleValue
        totalToFirstVisibleMs = json["totalToFirstVisibleMs"]?.doubleValue
        totalDurationMs = json["totalDurationMs"]?.doubleValue ?? 0
        firstVisibleMethod = json["firstVisibleMethod"]?.stringValue
    }
}

struct BridgeDiagnosticPerformance: Equatable {
    let snapshots: Int
    let patches: Int
    let patchToSnapshotByteRatio: Double
    let rpcLatency: DiagnosticTimingMetrics
    let firstVisibleLatency: DiagnosticTimingMetrics
    let recentTurnLatencies: [BridgeTurnLatencyDiagnostic]

    init(json: JSONValue?) {
        snapshots = json?["sessions"]?["snapshots"]?.intValue ?? 0
        patches = json?["sessions"]?["patches"]?.intValue ?? 0
        patchToSnapshotByteRatio = json?["sessions"]?["patchToSnapshotByteRatio"]?.doubleValue ?? 0
        rpcLatency = DiagnosticTimingMetrics(json: json?["rpcLatency"])
        firstVisibleLatency = DiagnosticTimingMetrics(json: json?["turnLatency"]?["firstVisible"])
        recentTurnLatencies = (json?["turnLatency"]?["recent"]?.arrayValue ?? [])
            .compactMap(BridgeTurnLatencyDiagnostic.init(json:))
    }
}

struct DiagnosticsReport {
    let generatedAt: Date
    let summary: String
    let checks: [DiagnosticCheck]
    let events: [DiagnosticEvent]
    let clientPerformance: ClientDiagnosticPerformance
    let bridgePerformance: BridgeDiagnosticPerformance
    let transcriptScrollMetrics: TranscriptScrollMetricsSnapshot?
    let transcriptScrollCommands: [TranscriptScrollCommand]
    let raw: JSONValue

    init(json: JSONValue) {
        generatedAt = ISO8601DateFormatter().date(from: json["generatedAt"]?.stringValue ?? "") ?? Date()
        summary = json["summary"]?.stringValue ?? "warning"
        checks = (json["checks"]?.arrayValue ?? []).compactMap(DiagnosticCheck.init(json:))
        events = (json["events"]?.arrayValue ?? []).compactMap(DiagnosticEvent.init(json:))
        clientPerformance = ClientDiagnosticPerformance(json: json["clientPerformance"])
        bridgePerformance = BridgeDiagnosticPerformance(json: json["performance"])
        transcriptScrollMetrics = TranscriptScrollMetricsSnapshot(json: json["transcriptScroll"]?["metrics"])
        transcriptScrollCommands = (json["transcriptScroll"]?["commands"]?.arrayValue ?? [])
            .compactMap(TranscriptScrollCommand.init(json:))
        raw = json
    }
}

private extension TranscriptScrollMetricsSnapshot {
    init?(json: JSONValue?) {
        guard let json,
              let scrollClass = json["scrollClass"]?.stringValue else { return nil }
        self.init(
            recordedAt: ISO8601DateFormatter().date(from: json["recordedAt"]?.stringValue ?? "") ?? Date(),
            scrollClass: scrollClass,
            offsetY: CGFloat(json["offsetY"]?.doubleValue ?? 0),
            contentHeight: CGFloat(json["contentHeight"]?.doubleValue ?? 0),
            viewportHeight: CGFloat(json["viewportHeight"]?.doubleValue ?? 0),
            insetTop: CGFloat(json["insetTop"]?.doubleValue ?? 0),
            insetBottom: CGFloat(json["insetBottom"]?.doubleValue ?? 0),
            distanceFromBottom: CGFloat(json["distanceFromBottom"]?.doubleValue ?? 0),
            isDragging: json["isDragging"]?.boolValue ?? false,
            isDecelerating: json["isDecelerating"]?.boolValue ?? false,
            isAtBottom: json["isAtBottom"]?.boolValue ?? false
        )
    }
}

private extension TranscriptScrollCommand {
    init?(json: JSONValue) {
        guard let id = json["id"]?.intValue,
              let reasonValue = json["reason"]?.stringValue,
              let reason = TranscriptScrollCommandReason(rawValue: reasonValue) else { return nil }
        self.init(
            id: id,
            recordedAt: ISO8601DateFormatter().date(from: json["recordedAt"]?.stringValue ?? "") ?? Date(),
            reason: reason,
            animated: json["animated"]?.boolValue ?? false,
            threadId: json["threadId"]?.stringValue,
            isAtBottom: json["isAtBottom"]?.boolValue ?? false,
            isUserScrolling: json["isUserScrolling"]?.boolValue ?? false
        )
    }
}
