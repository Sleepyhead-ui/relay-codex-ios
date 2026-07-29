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

    func testAutomaticRecoveryExcludesExplicitFailuresAndKeepsSequenceOrder() {
        let now = Date()
        let later = envelope(id: "later", hostId: "host", profileId: "profile", sequence: 2, createdAt: now)
        let failed = envelope(
            id: "failed",
            hostId: "host",
            profileId: "profile",
            sequence: 1,
            createdAt: now,
            automaticallyRecoverable: false
        )
        let earlier = envelope(id: "earlier", hostId: "host", profileId: "profile", sequence: 0, createdAt: now)
        let records = [later.id: later, failed.id: failed, earlier.id: earlier]

        XCTAssertEqual(
            OutboundDeliveryOutbox.automaticallyRecoverableScoped(
                records,
                hostId: "host",
                profileId: "profile"
            ).map(\.id),
            ["earlier", "later"]
        )
    }

    func testLegacyEnvelopeDecodingDefaultsToAutomaticRecovery() throws {
        let original = envelope(
            id: "legacy",
            hostId: "host",
            profileId: "profile",
            sequence: 3,
            createdAt: Date()
        )
        let encoded = try JSONEncoder().encode(original)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "automaticallyRecoverable")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(OutboundDeliveryEnvelope.self, from: legacyData)
        XCTAssertTrue(decoded.automaticallyRecoverable)
    }

    func testDraftRoundTripPreservesCollaborationMode() throws {
        let collaborationMode: JSONValue = .object([
            "mode": .string("plan"),
            "settings": .object([
                "model": .string("gpt-5.6-codex"),
                "reasoning_effort": .string("medium"),
                "developer_instructions": .null
            ])
        ])
        let original = OutboundDraft(
            threadId: "thread",
            text: "先制定计划",
            attachments: [],
            collaborationMode: collaborationMode
        )

        let decoded = try JSONDecoder().decode(
            OutboundDraft.self,
            from: JSONEncoder().encode(original)
        )

        XCTAssertEqual(decoded.collaborationMode, collaborationMode)
    }

    func testLegacyDraftWithoutCollaborationModeStillDecodes() throws {
        let original = OutboundDraft(threadId: "thread", text: "legacy", attachments: [])
        let encoded = try JSONEncoder().encode(original)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "collaborationMode")

        let decoded = try JSONDecoder().decode(
            OutboundDraft.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertNil(decoded.collaborationMode)
    }

    func testMergeUnresolvedPreservesSequenceBeforeNewerTurn() {
        let failedAt = Date(timeIntervalSince1970: 100)
        var laterMetadata = TurnMetadata()
        laterMetadata.startedAt = Date(timeIntervalSince1970: 200)
        let history = [item(id: "answer", turnId: "later", text: "newer answer")]
        let unresolved = [
            UnresolvedOutboundMessage(item: item(id: "first", text: "first"), sequence: 1, createdAt: failedAt),
            UnresolvedOutboundMessage(item: item(id: "second", text: "second"), sequence: 2, createdAt: failedAt),
        ]

        let merged = OutboundDeliveryOutbox.mergeUnresolved(
            unresolved,
            into: history,
            metadata: ["later": laterMetadata],
            placementSequences: [:]
        )

        XCTAssertEqual(merged.map(\.id), ["first", "second", "answer"])
    }

    func testMergeUnresolvedReusesExistingBubbleInsteadOfDuplicatingIt() {
        let existing = item(id: "same-id", text: "failed prompt")
        let retry = UnresolvedOutboundMessage(item: existing, sequence: 1, createdAt: Date())

        let merged = OutboundDeliveryOutbox.mergeUnresolved(
            [retry],
            into: [existing],
            metadata: [:],
            placementSequences: ["same-id": 1]
        )

        XCTAssertEqual(merged.map(\.id), ["same-id"])
    }

    private func envelope(
        id: String,
        hostId: String,
        profileId: String,
        sequence: Int,
        createdAt: Date,
        automaticallyRecoverable: Bool = true
    ) -> OutboundDeliveryEnvelope {
        OutboundDeliveryEnvelope(
            id: id,
            hostId: hostId,
            profileId: profileId,
            draft: OutboundDraft(threadId: "thread", text: id, attachments: []),
            sequence: sequence,
            createdAt: createdAt,
            automaticallyRecoverable: automaticallyRecoverable
        )
    }

    private func item(id: String, turnId: String? = nil, text: String) -> TranscriptItem {
        TranscriptItem(id: id, turnId: turnId, role: .user, kind: .message, text: text)
    }
}
