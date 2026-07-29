import XCTest
@testable import Relay

final class ApprovalQueueTests: XCTestCase {
    func testKeepsConcurrentApprovalsIsolatedByTask() throws {
        let first = try XCTUnwrap(approval(id: "approval.1", threadId: "thread.1"))
        let second = try XCTUnwrap(approval(id: "approval.2", threadId: "thread.2"))
        let approvals = [first, second]

        XCTAssertEqual(
            ApprovalQueue.prioritized(approvals, selectedThreadId: "thread.1").map(\.id),
            ["approval.1"]
        )
        XCTAssertEqual(
            ApprovalQueue.prioritized(approvals, selectedThreadId: "thread.2").map(\.id),
            ["approval.2"]
        )
        XCTAssertTrue(ApprovalQueue.contains(approvals, threadId: "thread.1"))
        XCTAssertTrue(ApprovalQueue.contains(approvals, threadId: "thread.2"))
    }

    func testFallsBackToTheOldestPendingApprovalWhenSelectedTaskHasNone() throws {
        let first = try XCTUnwrap(approval(id: "approval.1", threadId: "thread.1"))
        let second = try XCTUnwrap(approval(id: "approval.2", threadId: "thread.2"))

        XCTAssertEqual(
            ApprovalQueue.prioritized([first, second], selectedThreadId: "thread.3").map(\.id),
            ["approval.1", "approval.2"]
        )
    }

    func testPresentedApprovalKeepsItsIdentityWhenTaskPriorityChanges() throws {
        let first = try XCTUnwrap(approval(id: "approval.1", threadId: "thread.1"))
        let second = try XCTUnwrap(approval(id: "approval.2", threadId: "thread.2"))
        let approvals = [first, second]

        XCTAssertEqual(
            ApprovalQueue.prioritized(approvals, selectedThreadId: "thread.2").first?.id,
            "approval.2"
        )
        XCTAssertEqual(ApprovalQueue.request(approvals, id: first.id)?.id, "approval.1")
    }

    private func approval(id: String, threadId: String) -> ApprovalRequest? {
        ApprovalRequest(message: .object([
            "id": .string(id),
            "method": .string("item/commandExecution/requestApproval"),
            "params": .object([
                "threadId": .string(threadId),
                "turnId": .string("turn.\(threadId)"),
                "command": .string("echo test")
            ])
        ]))
    }
}
