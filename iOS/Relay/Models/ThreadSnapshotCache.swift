import Foundation

struct ThreadSnapshot: Equatable {
    let messages: [TranscriptItem]
    let turnMetadata: [String: TurnMetadata]
    let isRunning: Bool
    let activeTurnId: String?
    let activePlan: [ExecutionPlanStep]
    let activePlanTurnId: String?
    let modelId: String
    let effort: String
    let cachedAt: Date
}

struct ThreadSnapshotCache {
    private var snapshots: [String: ThreadSnapshot] = [:]
    private let limit: Int

    init(limit: Int = 8) {
        self.limit = max(1, limit)
    }

    subscript(threadId: String) -> ThreadSnapshot? {
        get { snapshots[threadId] }
        set { snapshots[threadId] = newValue }
    }

    mutating func store(_ snapshot: ThreadSnapshot, for threadId: String, preserving selectedThreadId: String?) {
        snapshots[threadId] = snapshot
        guard snapshots.count > limit,
              let oldest = snapshots
                .filter({ $0.key != selectedThreadId })
                .min(by: { $0.value.cachedAt < $1.value.cachedAt })?.key else { return }
        snapshots.removeValue(forKey: oldest)
    }

    mutating func removeAll() {
        snapshots.removeAll()
    }
}
