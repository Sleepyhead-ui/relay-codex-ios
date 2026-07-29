enum SelectedSessionSyncPolicy {
    static func shouldContinue(
        initialThreadId: String,
        selectedThreadId: String?,
        showingArchivedThreads: Bool,
        connected: Bool
    ) -> Bool {
        connected && !showingArchivedThreads && selectedThreadId == initialThreadId
    }
}
