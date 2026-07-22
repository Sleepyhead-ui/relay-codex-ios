import Foundation

struct UserMessagePlacement: Equatable {
    let threadId: String
    var turnId: String?
    let afterItemId: String?
    let sequence: Int
}

struct TranscriptDeltaUpdate {
    let id: String
    let turnId: String?
    let role: TranscriptRole
    let kind: TranscriptKind
    let title: String?
    let text: String
    let detail: String
}

enum TranscriptReconciler {
    static func upsert(_ item: TranscriptItem, into messages: inout [TranscriptItem]) {
        if let index = messages.firstIndex(where: { $0.id == item.id }) {
            messages[index] = merge(existing: messages[index], incoming: item)
        } else if let index = messages.firstIndex(where: { semanticallyMatches($0, item) }) {
            messages[index] = merge(existing: messages[index], incoming: item)
        } else if item.role != .user || !messages.contains(where: {
            $0.role == .user && $0.text == item.text && $0.imagePaths == item.imagePaths && $0.goal == item.goal
        }) {
            messages.append(item)
        }
    }

    static func applyDeltaBatch(_ updates: [TranscriptDeltaUpdate], to messages: [TranscriptItem]) -> [TranscriptItem] {
        guard !updates.isEmpty else { return messages }
        var result = messages
        var indexes: [String: Int] = [:]
        for (index, item) in result.enumerated() { indexes[item.id] = index }
        for update in updates {
            if let index = indexes[update.id] {
                result[index].text += update.text
                if !update.detail.isEmpty { result[index].detail = (result[index].detail ?? "") + update.detail }
                if result[index].turnId == nil { result[index].turnId = update.turnId }
            } else {
                indexes[update.id] = result.count
                result.append(TranscriptItem(
                    id: update.id,
                    turnId: update.turnId,
                    role: update.role,
                    kind: update.kind,
                    title: update.title,
                    text: update.text,
                    detail: update.detail.nonEmpty,
                    status: update.kind == .command ? "inProgress" : nil
                ))
            }
        }
        return result
    }

    static func mergeSessionItems(
        _ snapshotItems: [TranscriptItem],
        turnId: String,
        into messages: [TranscriptItem]
    ) -> [TranscriptItem] {
        let firstIndex = messages.firstIndex(where: { $0.turnId == turnId }) ?? messages.endIndex
        let existing = messages.filter { $0.turnId == turnId }
        var consumedExistingIds = Set<String>()
        var merged = existing
        for item in snapshotItems {
            if let index = merged.firstIndex(where: {
                !consumedExistingIds.contains($0.id) && ($0.id == item.id || semanticallyMatches($0, item))
            }) {
                consumedExistingIds.insert(merged[index].id)
                var combined = merge(existing: merged[index], incoming: item)
                combined.id = merged[index].id
                merged[index] = combined
            } else {
                merged.append(item)
            }
        }

        guard merged != existing else { return messages }
        var result = messages.filter { $0.turnId != turnId }
        result.insert(contentsOf: merged, at: min(firstIndex, result.endIndex))
        return result
    }

    static func mergeSessionPatchItems(
        _ upserts: [TranscriptItem],
        removedItemIds: Set<String>,
        turnId: String,
        into messages: [TranscriptItem]
    ) -> [TranscriptItem] {
        guard !upserts.isEmpty || !removedItemIds.isEmpty else { return messages }
        var result = removedItemIds.isEmpty
            ? messages
            : messages.filter { $0.turnId != turnId || !removedItemIds.contains($0.id) }
        var indexes: [String: Int] = [:]
        for (index, item) in result.enumerated() where indexes[item.id] == nil { indexes[item.id] = index }

        for item in upserts {
            if let index = indexes[item.id] {
                result[index] = merge(existing: result[index], incoming: item)
                continue
            }
            if let index = result.firstIndex(where: { $0.turnId == turnId && semanticallyMatches($0, item) }) {
                result[index] = merge(existing: result[index], incoming: item)
                continue
            }
            let insertion = (result.lastIndex(where: { $0.turnId == turnId }).map { $0 + 1 }) ?? result.endIndex
            result.insert(item, at: insertion)
            indexes.removeAll(keepingCapacity: true)
            for (index, item) in result.enumerated() where indexes[item.id] == nil { indexes[item.id] = index }
        }
        return result == messages ? messages : result
    }

    static func mergeHistoryItems(_ historyItems: [TranscriptItem], into messages: [TranscriptItem]) -> [TranscriptItem] {
        var result = messages.filter { !isInternalEnvironmentContext($0) }
        var consumedIds = Set<String>()
        for item in historyItems {
            if let index = result.firstIndex(where: {
                !consumedIds.contains($0.id) && ($0.id == item.id || semanticallyMatches($0, item))
            }) {
                consumedIds.insert(result[index].id)
                var combined = merge(existing: result[index], incoming: item)
                combined.id = result[index].id
                result[index] = combined
            } else if let turnId = item.turnId,
                      let lastTurnIndex = result.lastIndex(where: { $0.turnId == turnId }) {
                result.insert(item, at: lastTurnIndex + 1)
            } else {
                result.append(item)
            }
        }
        return result
    }

    static func applyUserMessagePlacements(
        _ placements: [String: UserMessagePlacement],
        turnId: String,
        threadId: String,
        to messages: [TranscriptItem]
    ) -> [TranscriptItem] {
        var result = messages
        let ordered = placements
            .filter { $0.value.threadId == threadId && $0.value.turnId == turnId }
            .sorted { $0.value.sequence < $1.value.sequence }

        for (messageId, placement) in ordered {
            guard let index = result.firstIndex(where: { $0.id == messageId && $0.role == .user }) else { continue }
            var prompt = result.remove(at: index)
            prompt.turnId = turnId
            let insertion: Int
            if let afterItemId = placement.afterItemId,
               let anchorIndex = result.firstIndex(where: { $0.id == afterItemId }) {
                insertion = anchorIndex + 1
            } else if placement.afterItemId == nil {
                insertion = result.firstIndex(where: { $0.turnId == turnId }) ?? min(index, result.endIndex)
            } else {
                insertion = min(index, result.endIndex)
            }
            result.insert(prompt, at: insertion)
        }
        return result
    }

    static func removeCompactionSummary(turnId: String, from messages: [TranscriptItem]) -> [TranscriptItem] {
        var result = messages
        if let index = result.lastIndex(where: {
            $0.turnId == turnId && $0.role == .assistant && $0.phase == "final_answer"
        }) {
            result.remove(at: index)
        }
        return result
    }

    static func merge(existing: TranscriptItem, incoming: TranscriptItem) -> TranscriptItem {
        var merged = incoming
        if merged.turnId == nil { merged.turnId = existing.turnId }
        if merged.title == nil { merged.title = existing.title }
        if merged.phase == nil { merged.phase = existing.phase }
        if merged.status == nil { merged.status = existing.status }
        let textStreamsIncrementally = existing.role == .assistant || existing.kind == .reasoning
        if merged.text.isEmpty || (textStreamsIncrementally && !existing.text.isEmpty && existing.text.hasPrefix(merged.text)) {
            merged.text = existing.text
        }
        if let existingDetail = existing.detail, !existingDetail.isEmpty {
            let detailStreamsIncrementally = existing.kind == .command || existing.kind == .reasoning
            if merged.detail?.isEmpty != false || (detailStreamsIncrementally && existingDetail.hasPrefix(merged.detail ?? "")) {
                merged.detail = existingDetail
            }
        }
        if merged.durationMs == nil { merged.durationMs = existing.durationMs }
        if merged.exitCode == nil { merged.exitCode = existing.exitCode }
        if merged.cwd == nil { merged.cwd = existing.cwd }
        if merged.errorMessage == nil { merged.errorMessage = existing.errorMessage }
        if merged.deliveryState == nil { merged.deliveryState = existing.deliveryState }
        if merged.imagePaths.isEmpty { merged.imagePaths = existing.imagePaths }
        if merged.goal == nil { merged.goal = existing.goal }
        return merged
    }

    static func semanticallyMatches(_ lhs: TranscriptItem, _ rhs: TranscriptItem) -> Bool {
        guard lhs.turnId == rhs.turnId, lhs.role == rhs.role, lhs.kind == rhs.kind else { return false }
        let lhsText: String
        let rhsText: String
        switch lhs.kind {
        case .message:
            guard lhs.role == .assistant, lhs.phase == rhs.phase else { return false }
            lhsText = normalizedText(lhs.text)
            rhsText = normalizedText(rhs.text)
        case .command, .fileChange, .webSearch, .plan, .contextCompaction, .image:
            lhsText = normalizedText(lhs.text)
            rhsText = normalizedText(rhs.text)
        case .reasoning:
            lhsText = normalizedText(lhs.text.nonEmpty ?? lhs.detail ?? "")
            rhsText = normalizedText(rhs.text.nonEmpty ?? rhs.detail ?? "")
        case .subagent, .other:
            return false
        }
        return !lhsText.isEmpty && lhsText == rhsText
    }

    static func normalizedText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isInternalEnvironmentContext(_ item: TranscriptItem) -> Bool {
        guard item.role == .user, item.imagePaths.isEmpty else { return false }
        let pattern = #"^\s*<environment_context\b[^>]*>[\s\S]*</environment_context>\s*$"#
        return item.text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
