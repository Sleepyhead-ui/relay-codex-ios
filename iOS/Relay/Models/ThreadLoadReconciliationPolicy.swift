import Foundation

enum ThreadLoadReconciliationPolicy {
    static func receivedLiveSessionUpdate(
        lastSessionUpdateAt: Date?,
        historyLoadStartedAt: Date
    ) -> Bool {
        guard let lastSessionUpdateAt else { return false }
        return lastSessionUpdateAt >= historyLoadStartedAt
    }
}
