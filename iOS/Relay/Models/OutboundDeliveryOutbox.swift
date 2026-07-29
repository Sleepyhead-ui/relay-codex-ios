import Foundation

struct OutboundDraft: Codable {
    let threadId: String
    let text: String
    let attachments: [PendingAttachment]
    var expectedTurnId: String? = nil
    var sandboxPolicy: JSONValue? = nil
    var model: String? = nil
    var effort: String? = nil

    private enum CodingKeys: String, CodingKey {
        case threadId, text, attachments, expectedTurnId, sandboxPolicy, model, effort
    }

    init(
        threadId: String,
        text: String,
        attachments: [PendingAttachment],
        expectedTurnId: String? = nil,
        sandboxPolicy: JSONValue? = nil,
        model: String? = nil,
        effort: String? = nil
    ) {
        self.threadId = threadId
        self.text = text
        self.attachments = attachments
        self.expectedTurnId = expectedTurnId
        self.sandboxPolicy = sandboxPolicy
        self.model = model
        self.effort = effort
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        threadId = try values.decode(String.self, forKey: .threadId)
        text = try values.decode(String.self, forKey: .text)
        attachments = try values.decode([StoredOutboundAttachment].self, forKey: .attachments).map(\.pendingAttachment)
        expectedTurnId = try values.decodeIfPresent(String.self, forKey: .expectedTurnId)
        sandboxPolicy = try values.decodeIfPresent(JSONValue.self, forKey: .sandboxPolicy)
        model = try values.decodeIfPresent(String.self, forKey: .model)
        effort = try values.decodeIfPresent(String.self, forKey: .effort)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(threadId, forKey: .threadId)
        try values.encode(text, forKey: .text)
        try values.encode(attachments.compactMap { StoredOutboundAttachment($0) }, forKey: .attachments)
        try values.encodeIfPresent(expectedTurnId, forKey: .expectedTurnId)
        try values.encodeIfPresent(sandboxPolicy, forKey: .sandboxPolicy)
        try values.encodeIfPresent(model, forKey: .model)
        try values.encodeIfPresent(effort, forKey: .effort)
    }
}

struct OutboundDeliveryEnvelope: Codable, Identifiable {
    let id: String
    let hostId: String
    let profileId: String
    let draft: OutboundDraft
    let sequence: Int
    let createdAt: Date
    var automaticallyRecoverable: Bool

    private enum CodingKeys: String, CodingKey {
        case id, hostId, profileId, draft, sequence, createdAt, automaticallyRecoverable
    }

    init(
        id: String,
        hostId: String,
        profileId: String,
        draft: OutboundDraft,
        sequence: Int,
        createdAt: Date,
        automaticallyRecoverable: Bool = true
    ) {
        self.id = id
        self.hostId = hostId
        self.profileId = profileId
        self.draft = draft
        self.sequence = sequence
        self.createdAt = createdAt
        self.automaticallyRecoverable = automaticallyRecoverable
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        hostId = try values.decode(String.self, forKey: .hostId)
        profileId = try values.decode(String.self, forKey: .profileId)
        draft = try values.decode(OutboundDraft.self, forKey: .draft)
        sequence = try values.decode(Int.self, forKey: .sequence)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        automaticallyRecoverable = try values.decodeIfPresent(Bool.self, forKey: .automaticallyRecoverable) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(hostId, forKey: .hostId)
        try values.encode(profileId, forKey: .profileId)
        try values.encode(draft, forKey: .draft)
        try values.encode(sequence, forKey: .sequence)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(automaticallyRecoverable, forKey: .automaticallyRecoverable)
    }
}

struct UnresolvedOutboundMessage {
    let item: TranscriptItem
    let sequence: Int
    let createdAt: Date?
}

enum OutboundDeliveryOutbox {
    static func scoped(
        _ records: [String: OutboundDeliveryEnvelope],
        hostId: String,
        profileId: String
    ) -> [OutboundDeliveryEnvelope] {
        records.values
            .filter { $0.hostId == hostId && $0.profileId == profileId }
            .sorted { left, right in
                left.sequence == right.sequence ? left.createdAt < right.createdAt : left.sequence < right.sequence
            }
    }

    static func automaticallyRecoverableScoped(
        _ records: [String: OutboundDeliveryEnvelope],
        hostId: String,
        profileId: String
    ) -> [OutboundDeliveryEnvelope] {
        scoped(records, hostId: hostId, profileId: profileId)
            .filter(\.automaticallyRecoverable)
    }

    static func pruned(
        _ records: [String: OutboundDeliveryEnvelope],
        now: Date = Date(),
        maximumAge: TimeInterval = 7 * 24 * 60 * 60,
        limit: Int = 200
    ) -> [String: OutboundDeliveryEnvelope] {
        let oldest = now.addingTimeInterval(-maximumAge)
        let retained = records.values
            .filter { $0.createdAt >= oldest }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(max(1, limit))
        return Dictionary(uniqueKeysWithValues: retained.map { ($0.id, $0) })
    }

    static func mergeUnresolved(
        _ unresolved: [UnresolvedOutboundMessage],
        into history: [TranscriptItem],
        metadata: [String: TurnMetadata],
        placementSequences: [String: Int]
    ) -> [TranscriptItem] {
        var result = history
        let sorted = unresolved.sorted { left, right in
            if left.sequence != right.sequence { return left.sequence < right.sequence }
            return (left.createdAt ?? .distantFuture) < (right.createdAt ?? .distantFuture)
        }

        for message in sorted where !result.contains(where: { $0.id == message.item.id }) {
            let insertion = result.firstIndex { candidate in
                if let candidateSequence = placementSequences[candidate.id], candidateSequence > message.sequence {
                    return true
                }
                guard let createdAt = message.createdAt,
                      let turnId = candidate.turnId,
                      let startedAt = metadata[turnId]?.startedAt else { return false }
                return startedAt >= createdAt
            } ?? result.endIndex
            result.insert(message.item, at: insertion)
        }
        return result
    }
}

private struct StoredOutboundAttachment: Codable {
    let id: UUID
    let name: String
    let remotePath: String
    let size: Int64
    let isImage: Bool

    init?(_ attachment: PendingAttachment) {
        guard let remotePath = attachment.remotePath else { return nil }
        id = attachment.id
        name = attachment.name
        self.remotePath = remotePath
        size = attachment.size
        isImage = attachment.isImage
    }

    var pendingAttachment: PendingAttachment {
        PendingAttachment(
            id: id,
            name: name,
            localURL: URL(fileURLWithPath: remotePath),
            remotePath: remotePath,
            size: size,
            progress: 1,
            state: .ready,
            isImage: isImage
        )
    }
}
