import Foundation

struct UserMessagePlacement: Equatable {
    let threadId: String
    var turnId: String?
    let afterItemId: String?
    let sequence: Int
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

    static func mergeSessionItems(
        _ snapshotItems: [TranscriptItem],
        turnId: String,
        into messages: [TranscriptItem]
    ) -> [TranscriptItem] {
        let firstIndex = messages.firstIndex(where: { $0.turnId == turnId }) ?? messages.endIndex
        let existing = messages.filter { $0.turnId == turnId }
        let existingById = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        var consumedExistingIds = Set<String>()
        var merged = snapshotItems.map { item in
            if let previous = existingById[item.id] {
                consumedExistingIds.insert(previous.id)
                return merge(existing: previous, incoming: item)
            }
            if let previous = existing.first(where: {
                !consumedExistingIds.contains($0.id) && semanticallyMatches($0, item)
            }) {
                consumedExistingIds.insert(previous.id)
                var combined = merge(existing: previous, incoming: item)
                combined.id = previous.id
                return combined
            }
            return item
        }
        merged.append(contentsOf: existing.filter { !consumedExistingIds.contains($0.id) })

        guard merged != existing else { return messages }
        var result = messages.filter { $0.turnId != turnId }
        result.insert(contentsOf: merged, at: min(firstIndex, result.endIndex))
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

    static func merge(existing: TranscriptItem, incoming: TranscriptItem) -> TranscriptItem {
        var merged = incoming
        if merged.turnId == nil { merged.turnId = existing.turnId }
        if merged.title == nil { merged.title = existing.title }
        if merged.phase == nil { merged.phase = existing.phase }
        if merged.status == nil { merged.status = existing.status }
        if merged.text.isEmpty { merged.text = existing.text }
        if merged.detail?.isEmpty != false, let detail = existing.detail, !detail.isEmpty { merged.detail = detail }
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
}
