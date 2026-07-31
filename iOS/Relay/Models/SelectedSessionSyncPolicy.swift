import Foundation

enum SelectedSessionSyncPolicy {
    static let subscribedRetryDelayNanoseconds: UInt64 = 5_000_000_000
    static let disconnectedRetryDelayNanoseconds: UInt64 = 2_000_000_000
    static let subscribedSilenceThreshold: TimeInterval = 4

    static func retryDelay(hasActiveSubscription: Bool) -> UInt64 {
        hasActiveSubscription ? subscribedRetryDelayNanoseconds : disconnectedRetryDelayNanoseconds
    }

    static func shouldRefreshSubscription(
        hasActiveSubscription: Bool,
        lastUpdateAt: Date?,
        now: Date = Date()
    ) -> Bool {
        !hasActiveSubscription
            || now.timeIntervalSince(lastUpdateAt ?? .distantPast) >= subscribedSilenceThreshold
    }

    static func shouldContinue(
        initialThreadId: String,
        selectedThreadId: String?,
        showingArchivedThreads: Bool,
        connected: Bool
    ) -> Bool {
        connected && !showingArchivedThreads && selectedThreadId == initialThreadId
    }
}
