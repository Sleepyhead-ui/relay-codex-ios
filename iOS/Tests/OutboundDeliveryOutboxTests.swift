import XCTest
@testable import Relay

final class OutboundDeliveryOutboxTests: XCTestCase {
    func testScopesPendingDeliveriesByHostAndProfile() {
        let now = Date()
        let first = envelope(id: "one", hostId: "host-a", profileId: "profile-a", sequence: 2, createdAt: now)
        let second = envelope(id: "two", hostId: "host-a", profileId: "profile-a", sequence: 1, createdAt: now)
        let otherHost = envelope(id: "three", hostId: "host-b", profileId: "profile-a", sequence: 0, createdAt: now)
        let records = [first.id: first, second.id: second, otherHost.id: otherHost]

        XCTAssertEqual(
            OutboundDeliveryOutbox.scoped(records, hostId: "host-a", profileId: "profile-a").map(\.id),
            ["two", "one"]
        )
    }

    func testPrunesExpiredAndExcessDeliveries() {
        let now = Date()
        let records = Dictionary(uniqueKeysWithValues: [
            envelope(id: "old", hostId: "host", profileId: "profile", sequence: 0, createdAt: now.addingTimeInterval(-100)),
            envelope(id: "new", hostId: "host", profileId: "profile", sequence: 1, createdAt: now),
            envelope(id: "newer", hostId: "host", profileId: "profile", sequence: 2, createdAt: now.addingTimeInterval(1)),
        ].map { ($0.id, $0) })

        let pruned = OutboundDeliveryOutbox.pruned(records, now: now, maximumAge: 10, limit: 1)
        XCTAssertEqual(Set(pruned.keys), ["newer"])
    }

    private func envelope(
        id: String,
        hostId: String,
        profileId: String,
        sequence: Int,
        createdAt: Date
    ) -> OutboundDeliveryEnvelope {
        OutboundDeliveryEnvelope(
            id: id,
            hostId: hostId,
            profileId: profileId,
            draft: OutboundDraft(threadId: "thread", text: id, attachments: []),
            sequence: sequence,
            createdAt: createdAt
        )
    }
}
