import Foundation

enum SelectedSessionSyncPolicy {
    static let subscribedRetryDelayNanoseconds: UInt64 = 15_000_000_000
    static let disconnectedRetryDelayNanoseconds: UInt64 = 2_000_000_000
    static let idleRuntimeProbeDelayNanoseconds: UInt64 = 3_000_000_000
    static let subscribedSilenceThreshold: TimeInterval = 45

    static func retryDelay(hasActiveSubscription: Bool) -> UInt64 {
        hasActiveSubscription ? subscribedRetryDelayNanoseconds : disconnectedRetryDelayNanoseconds
    }

    static func nextCheckDelay(hasActiveSubscription: Bool, isLocallyRunning: Bool) -> UInt64 {
        guard !isLocallyRunning else { return retryDelay(hasActiveSubscription: hasActiveSubscription) }
        return min(idleRuntimeProbeDelayNanoseconds, retryDelay(hasActiveSubscription: hasActiveSubscription))
    }

    static func shouldProbeExternalRuntime(isLocallyRunning: Bool, connected: Bool) -> Bool {
        connected && !isLocallyRunning
    }

    static func sessionIsRunning(reportedRunning: Bool, isStale: Bool) -> Bool {
        reportedRunning && !isStale
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

    static func shouldRestoreOnForeground(
        connected: Bool,
        backgroundConnectionIdentifier: UUID?,
        currentConnectionIdentifier: UUID
    ) -> Bool {
        !connected || backgroundConnectionIdentifier != currentConnectionIdentifier
    }
}
