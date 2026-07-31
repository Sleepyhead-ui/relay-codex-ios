import Foundation

enum DeliveryFailureDisposition: Equatable {
    case failed
    case uncertain
}

enum StartedTurnDisposition: Equatable {
    case awaitingOutput
    case failed
    case resolved
}

enum DeliveryFailurePolicy {
    static func canEditFailedTurnStart(expectedTurnId: String?) -> Bool {
        expectedTurnId == nil
    }

    static func isRelayClientMessageId(_ id: String) -> Bool {
        UUID(uuidString: id) != nil
    }

    static func startedTurnDisposition(
        status: String?,
        errorMessage: String?,
        hasOutput: Bool
    ) -> StartedTurnDisposition {
        if hasOutput { return .resolved }
        let normalized = status?
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        if errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || normalized.map { ["failed", "error", "cancelled", "canceled"].contains($0) } == true {
            return .failed
        }
        if normalized.map { ["completed", "complete", "succeeded", "success", "interrupted", "aborted"].contains($0) } == true {
            return .resolved
        }
        return .awaitingOutput
    }

    static func disposition(
        remoteMessage: String?,
        bridgeAccepted: Bool,
        transportConnected: Bool
    ) -> DeliveryFailureDisposition {
        if let remoteMessage {
            let normalized = remoteMessage.lowercased()
            if uncertainTransportMarkers.contains(where: normalized.contains) {
                return .uncertain
            }
            // A normal RPC error is a definitive upstream rejection even when
            // Bridge acknowledged receipt before forwarding it to Codex.
            return .failed
        }
        return bridgeAccepted || !transportConnected ? .uncertain : .failed
    }

    private static let uncertainTransportMarkers = [
        "timed out",
        "timeout",
        "disconnected",
        "connection was lost",
        "network connection was lost",
        "fetch failed",
        "没有完成请求",
        "没有确认请求",
        "没有确认收到消息",
        "连接已断开",
        "连接中断"
    ]
}
