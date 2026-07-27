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
