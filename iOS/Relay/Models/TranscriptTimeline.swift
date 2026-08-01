import Foundation

struct TranscriptInvariantViolation: Equatable {
    enum Kind: String, Hashable {
        case duplicateItemId
        case splitTurn
        case outputBeforeInitialPrompt
    }

    let kind: Kind
    let turnId: String?
    let itemId: String?
}

enum TranscriptTimelineAudit {
    static func violations(in messages: [TranscriptItem]) -> [TranscriptInvariantViolation] {
        var result: [TranscriptInvariantViolation] = []
        var seenItemIds = Set<String>()
        for item in messages where !seenItemIds.insert(item.id).inserted {
            result.append(.init(kind: .duplicateItemId, turnId: item.turnId, itemId: item.id))
        }

        var closedTurnIds = Set<String>()
        var currentTurnId: String?
        var reportedSplitTurnIds = Set<String>()
        for item in messages {
            guard let turnId = item.turnId else {
                if let currentTurnId { closedTurnIds.insert(currentTurnId) }
                currentTurnId = nil
                continue
            }
            guard turnId != currentTurnId else { continue }
            if let currentTurnId { closedTurnIds.insert(currentTurnId) }
            if closedTurnIds.contains(turnId), reportedSplitTurnIds.insert(turnId).inserted {
                result.append(.init(kind: .splitTurn, turnId: turnId, itemId: item.id))
            }
            currentTurnId = turnId
        }

        var itemsByTurnId: [String: [TranscriptItem]] = [:]
        var turnOrder: [String] = []
        for item in messages {
            guard let turnId = item.turnId else { continue }
            if itemsByTurnId[turnId] == nil { turnOrder.append(turnId) }
            itemsByTurnId[turnId, default: []].append(item)
        }
        for turnId in turnOrder {
            guard let items = itemsByTurnId[turnId],
                  let promptIndex = items.firstIndex(where: { $0.role == .user }),
                  let outputIndex = items.firstIndex(where: { $0.role != .user }),
                  outputIndex < promptIndex else { continue }
            result.append(.init(
                kind: .outputBeforeInitialPrompt,
                turnId: turnId,
                itemId: items[outputIndex].id
            ))
        }
        return result
    }
}

struct TranscriptReplayFrame: Decodable {
    let source: String
    let turnId: String?
    let items: [JSONValue]
    let removedItemIds: [String]
    let delta: TranscriptReplayDelta?

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        source = try values.decode(String.self, forKey: .source)
        turnId = try values.decodeIfPresent(String.self, forKey: .turnId)
        items = try values.decodeIfPresent([JSONValue].self, forKey: .items) ?? []
        removedItemIds = try values.decodeIfPresent([String].self, forKey: .removedItemIds) ?? []
        delta = try values.decodeIfPresent(TranscriptReplayDelta.self, forKey: .delta)
    }

    private enum CodingKeys: String, CodingKey {
        case source, turnId, items, removedItemIds, delta
    }
}

struct TranscriptReplayDelta: Decodable {
    let id: String
    let turnId: String?
    let role: String
    let kind: String
    let title: String?
    let text: String
    let detail: String
    let phase: String?
}

enum TranscriptReplayError: Error, Equatable {
    case missingTurnId(String)
    case missingDelta
    case unknownSource(String)
    case unknownRole(String)
    case unknownKind(String)
}

struct TranscriptReplay {
    private(set) var messages: [TranscriptItem] = []

    mutating func apply(_ frame: TranscriptReplayFrame) throws {
        let items = frame.items.compactMap {
            TranscriptItem.from(json: $0, turnId: $0["turnId"]?.stringValue ?? frame.turnId)
        }
        switch frame.source {
        case "history":
            messages = TranscriptReconciler.mergeHistoryItems(items, into: messages)
        case "snapshot":
            guard let turnId = frame.turnId else { throw TranscriptReplayError.missingTurnId(frame.source) }
            messages = TranscriptReconciler.mergeSessionItems(items, turnId: turnId, into: messages)
        case "patch":
            guard let turnId = frame.turnId else { throw TranscriptReplayError.missingTurnId(frame.source) }
            messages = TranscriptReconciler.mergeSessionPatchItems(
                items,
                removedItemIds: Set(frame.removedItemIds),
                turnId: turnId,
                into: messages
            )
        case "upsert":
            for item in items { TranscriptReconciler.upsert(item, into: &messages) }
        case "delta":
            guard let delta = frame.delta else { throw TranscriptReplayError.missingDelta }
            messages = TranscriptReconciler.applyDeltaBatch([try delta.update()], to: messages)
        default:
            throw TranscriptReplayError.unknownSource(frame.source)
        }
    }
}

private extension TranscriptReplayDelta {
    func update() throws -> TranscriptDeltaUpdate {
        TranscriptDeltaUpdate(
            id: id,
            turnId: turnId,
            role: try transcriptRole(),
            kind: try transcriptKind(),
            title: title,
            text: text,
            detail: detail,
            phase: phase
        )
    }

    func transcriptRole() throws -> TranscriptRole {
        switch role {
        case "user": return .user
        case "assistant": return .assistant
        case "tool": return .tool
        case "system": return .system
        default: throw TranscriptReplayError.unknownRole(role)
        }
    }

    func transcriptKind() throws -> TranscriptKind {
        switch kind {
        case "message": return .message
        case "command": return .command
        case "fileChange": return .fileChange
        case "reasoning": return .reasoning
        case "webSearch": return .webSearch
        case "plan": return .plan
        case "contextCompaction": return .contextCompaction
        case "image": return .image
        case "subagent": return .subagent
        case "other": return .other
        default: throw TranscriptReplayError.unknownKind(kind)
        }
    }
}

final class TranscriptTraceRecorder {
    private struct TraceItem {
        let id: String
        let turnId: String?
        let role: String
        let kind: String
        let origin: String
        let content: String

        var json: JSONValue {
            var value: [String: JSONValue] = [
                "id": .string(id),
                "role": .string(role),
                "kind": .string(kind),
                "origin": .string(origin),
                "content": .string(content)
            ]
            if let turnId { value["turnId"] = .string(turnId) }
            return .object(value)
        }
    }

    private struct TraceEntry {
        let sequence: Int
        let at: Date
        let source: String
        let threadId: String?
        let turnId: String?
        let revision: Int
        let messageCount: Int
        let items: [TraceItem]
        let violations: [TranscriptInvariantViolation]

        var json: JSONValue {
            var value: [String: JSONValue] = [
                "sequence": .number(Double(sequence)),
                "at": .string(ISO8601DateFormatter().string(from: at)),
                "source": .string(source),
                "revision": .number(Double(revision)),
                "messageCount": .number(Double(messageCount)),
                "items": .array(items.map(\.json)),
                "violations": .array(violations.map { violation in
                    var detail: [String: JSONValue] = ["kind": .string(violation.kind.rawValue)]
                    if let turnId = violation.turnId { detail["turnId"] = .string(turnId) }
                    if let itemId = violation.itemId { detail["itemId"] = .string(itemId) }
                    return .object(detail)
                })
            ]
            if let threadId { value["threadId"] = .string(threadId) }
            if let turnId { value["turnId"] = .string(turnId) }
            return .object(value)
        }
    }

    private let limit: Int
    private let itemLimit: Int
    private var entries: [TraceEntry] = []
    private var itemAliases: [String: String] = [:]
    private var turnAliases: [String: String] = [:]
    private var threadAliases: [String: String] = [:]
    private var contentAliases: [String: String] = [:]
    private var sequence = 0
    private var lastSignature = ""

    init(limit: Int = 160, itemLimit: Int = 64) {
        self.limit = max(1, limit)
        self.itemLimit = max(1, itemLimit)
    }

    func record(
        source: String,
        threadId: String?,
        turnId: String?,
        revision: Int,
        messages: [TranscriptItem]
    ) {
        let signature = messages.map {
            "\($0.id)|\($0.turnId ?? "-")|\(roleName($0.role))|\(kindName($0.kind))"
        }.joined(separator: "\n")
        let violations = TranscriptTimelineAudit.violations(in: messages)
        guard signature != lastSignature || !violations.isEmpty else { return }
        lastSignature = signature
        sequence += 1
        var visibleItems: [TraceItem] = []
        for item in messages.suffix(itemLimit) {
            let itemId = Self.alias(item.id, prefix: "item", in: &itemAliases)
            let itemTurnId = item.turnId.map { Self.alias($0, prefix: "turn", in: &turnAliases) }
            let content = Self.alias(semanticContent(item), prefix: "content", in: &contentAliases)
            visibleItems.append(TraceItem(
                id: itemId,
                turnId: itemTurnId,
                role: roleName(item.role),
                kind: kindName(item.kind),
                origin: originName(item.id),
                content: content
            ))
        }
        var aliasedViolations: [TranscriptInvariantViolation] = []
        for violation in violations {
            let violationTurnId = violation.turnId.map { Self.alias($0, prefix: "turn", in: &turnAliases) }
            let violationItemId = violation.itemId.map { Self.alias($0, prefix: "item", in: &itemAliases) }
            aliasedViolations.append(.init(
                kind: violation.kind,
                turnId: violationTurnId,
                itemId: violationItemId
            ))
        }
        let aliasedThreadId = threadId.map { Self.alias($0, prefix: "thread", in: &threadAliases) }
        let aliasedTurnId = turnId.map { Self.alias($0, prefix: "turn", in: &turnAliases) }
        entries.append(TraceEntry(
            sequence: sequence,
            at: Date(),
            source: source,
            threadId: aliasedThreadId,
            turnId: aliasedTurnId,
            revision: revision,
            messageCount: messages.count,
            items: visibleItems,
            violations: aliasedViolations
        ))
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
    }

    func report(currentMessages: [TranscriptItem]) -> JSONValue {
        .object([
            "schemaVersion": .number(1),
            "privacy": .string("Message text, commands, paths and raw identifiers are replaced by session-local aliases."),
            "eventCount": .number(Double(entries.count)),
            "currentViolationCount": .number(Double(TranscriptTimelineAudit.violations(in: currentMessages).count)),
            "events": .array(entries.map(\.json))
        ])
    }

    func reset() {
        entries.removeAll()
        itemAliases.removeAll()
        turnAliases.removeAll()
        threadAliases.removeAll()
        contentAliases.removeAll()
        sequence = 0
        lastSignature = ""
    }

    private static func alias(_ value: String, prefix: String, in aliases: inout [String: String]) -> String {
        if let existing = aliases[value] { return existing }
        let next = "\(prefix).\(aliases.count + 1)"
        aliases[value] = next
        return next
    }

    private func semanticContent(_ item: TranscriptItem) -> String {
        [
            roleName(item.role),
            kindName(item.kind),
            TranscriptReconciler.normalizedText(item.text),
            TranscriptReconciler.normalizedText(item.detail ?? ""),
            item.goal ?? "",
            String(item.imagePaths.count)
        ].joined(separator: "|")
    }

    private func originName(_ id: String) -> String {
        if id.hasPrefix("item-") { return "history" }
        if id.hasPrefix("msg_") { return "rollout" }
        if UUID(uuidString: id) != nil { return "relay" }
        return "event"
    }

    private func roleName(_ role: TranscriptRole) -> String {
        switch role {
        case .user: return "user"
        case .assistant: return "assistant"
        case .tool: return "tool"
        case .system: return "system"
        }
    }

    private func kindName(_ kind: TranscriptKind) -> String {
        switch kind {
        case .message: return "message"
        case .command: return "command"
        case .fileChange: return "fileChange"
        case .reasoning: return "reasoning"
        case .webSearch: return "webSearch"
        case .plan: return "plan"
        case .contextCompaction: return "contextCompaction"
        case .image: return "image"
        case .subagent: return "subagent"
        case .other: return "other"
        }
    }
}
