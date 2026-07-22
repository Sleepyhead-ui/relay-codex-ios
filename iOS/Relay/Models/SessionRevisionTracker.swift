struct SessionRevisionTracker {
    private var revisions: [String: Int] = [:]

    mutating func reset(threadId: String, revision: Int) {
        revisions[threadId] = max(0, revision)
    }

    mutating func acceptPatch(threadId: String, baseRevision: Int, revision: Int) -> Bool {
        guard revisions[threadId] == max(0, baseRevision) else { return false }
        revisions[threadId] = max(0, revision)
        return true
    }

    func revision(threadId: String) -> Int? { revisions[threadId] }
    mutating func remove(threadId: String) { revisions.removeValue(forKey: threadId) }
    mutating func removeAll() { revisions.removeAll() }
}
