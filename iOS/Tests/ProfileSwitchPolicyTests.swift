import XCTest
@testable import Relay

final class ProfileSwitchPolicyTests: XCTestCase {
    func testBlocksSwitchWhenABackgroundTaskIsRunning() {
        var background = TaskRunState(threadId: "thread.background")
        background.apply(.started(turnId: "turn.background", startedAt: nil))

        XCTAssertFalse(ProfileSwitchPolicy.canSwitch(
            taskStates: [background.threadId: background],
            sendingThreadIds: [],
            pendingApprovalCount: 0,
            pendingDeliveryCount: 0
        ))
    }

    func testBlocksSwitchForSendingDeliveryOrApproval() {
        XCTAssertFalse(ProfileSwitchPolicy.canSwitch(
            taskStates: [:],
            sendingThreadIds: ["thread.sending"],
            pendingApprovalCount: 0,
            pendingDeliveryCount: 0
        ))
        XCTAssertFalse(ProfileSwitchPolicy.canSwitch(
            taskStates: [:],
            sendingThreadIds: [],
            pendingApprovalCount: 1,
            pendingDeliveryCount: 0
        ))
        XCTAssertFalse(ProfileSwitchPolicy.canSwitch(
            taskStates: [:],
            sendingThreadIds: [],
            pendingApprovalCount: 0,
            pendingDeliveryCount: 1
        ))
    }

    func testAllowsSwitchOnlyWhenAllWorkIsSettled() {
        var completed = TaskRunState(threadId: "thread.completed")
        completed.apply(.started(turnId: "turn.completed", startedAt: nil))
        completed.apply(.terminal(turnId: "turn.completed", phase: .completed, completedAt: nil))

        XCTAssertTrue(ProfileSwitchPolicy.canSwitch(
            taskStates: [completed.threadId: completed],
            sendingThreadIds: [],
            pendingApprovalCount: 0,
            pendingDeliveryCount: 0
        ))
    }
}
