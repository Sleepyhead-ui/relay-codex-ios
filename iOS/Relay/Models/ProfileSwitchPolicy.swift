import Foundation

enum ProfileSwitchPolicy {
    static func canSwitch(
        taskStates: [String: TaskRunState],
        sendingThreadIds: Set<String>,
        pendingApprovalCount: Int,
        pendingDeliveryCount: Int
    ) -> Bool {
        !taskStates.values.contains(where: \.isRunning)
            && sendingThreadIds.isEmpty
            && pendingApprovalCount == 0
            && pendingDeliveryCount == 0
    }
}
