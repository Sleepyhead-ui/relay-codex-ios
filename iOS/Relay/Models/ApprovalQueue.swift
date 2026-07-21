import Foundation

enum ApprovalQueue {
    static func prioritized(_ approvals: [ApprovalRequest], selectedThreadId: String?) -> [ApprovalRequest] {
        guard let selectedThreadId else { return approvals }
        let matching = approvals.filter { $0.threadId == selectedThreadId || $0.threadId == nil }
        return matching.isEmpty ? approvals : matching
    }

    static func contains(_ approvals: [ApprovalRequest], threadId: String) -> Bool {
        approvals.contains { $0.threadId == threadId }
    }
}
