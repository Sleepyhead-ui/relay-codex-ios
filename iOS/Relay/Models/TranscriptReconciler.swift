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
    let phase: String?

    init(
        id: String,
        turnId: String?,
        role: TranscriptRole,
        kind: TranscriptKind,
        title: String?,
        text: String,
        detail: String,
        phase: String? = nil
    ) {
        self.id = id
        self.turnId = turnId
        self.role = role
        self.kind = kind
        self.title = title
        self.text = text
        self.detail = detail
        self.phase = phase
    }
}

enum TranscriptReconciler {
    static func userMessagePlacementAnchor(turnId: String, in messages: [TranscriptItem]) -> String? {
        messages.last(where: { item in
            guard item.turnId == turnId else { return false }
            if item.role == .assistant, item.kind == .message {
                // item/started may create an invisible answer shell whose text arrives after the steer.
                return !item.text.isEmpty || item.detail?.isEmpty == false
            }
            return true
        })?.id
    }

    static func upsert(_ item: TranscriptItem, into messages: inout [TranscriptItem]) {
        if let index = messages.firstIndex(where: { $0.id == item.id }) {
            messages[index] = merge(existing: messages[index], incoming: item)
        } else if let index = messages.firstIndex(where: { semanticallyMatches($0, item) }) {
            messages[index] = merge(existing: messages[index], incoming: item)
        } else if item.role == .user,
                  let index = messages.firstIndex(where: { shouldMergeUserUpsert($0, item) }) {
            var combined = merge(existing: messages[index], incoming: item)
            combined.id = messages[index].id
            messages[index] = combined
        } else {
            messages.insert(item, at: insertionAfterTurn(item.turnId, in: messages))
        }
    }

    static func applyDeltaBatch(_ updates: [TranscriptDeltaUpdate], to messages: [TranscriptItem]) -> [TranscriptItem] {
        guard !updates.isEmpty else { return messages }
        var result = messages
        var indexes: [String: Int] = [:]
        for (index, item) in result.enumerated() { indexes[item.id] = index }
        for update in updates {
            if let index = indexes[update.id] {
                applyDelta(update, to: &result[index])
            } else {
                let item = item(for: update)
                let insertion = insertionAfterTurn(item.turnId, in: result)
                result.insert(item, at: insertion)
                indexes.removeAll(keepingCapacity: true)
                for (index, item) in result.enumerated() where indexes[item.id] == nil { indexes[item.id] = index }
            }
        }
        return result
    }

    static func applyDelta(_ update: TranscriptDeltaUpdate, to item: inout TranscriptItem) {
        if item.turnId == nil { item.turnId = update.turnId }
        if item.phase == nil { item.phase = update.phase }
        if update.role == .assistant, update.kind == .message {
            let raw = (item.rawAgentText ?? item.text) + update.text
            let content = AgentMessageContent.parse(raw)
            item.rawAgentText = raw
            item.text = content.visibleText
            item.detail = content.thinkingText
            if item.phase == nil, content.containsThinking { item.phase = "commentary" }
            return
        }
        item.text += update.text
        if !update.detail.isEmpty { item.detail = (item.detail ?? "") + update.detail }
    }

    static func item(for update: TranscriptDeltaUpdate) -> TranscriptItem {
        var item = TranscriptItem(
            id: update.id,
            turnId: update.turnId,
            role: update.role,
            kind: update.kind,
            title: update.title,
            text: "",
            status: update.kind == .command ? "inProgress" : nil,
            phase: update.phase
        )
        applyDelta(update, to: &item)
        return item
    }

    static func mergeSessionItems(
        _ snapshotItems: [TranscriptItem],
        turnId: String,
        into messages: [TranscriptItem]
    ) -> [TranscriptItem] {
        let snapshotItems = coalescingDuplicateIds(snapshotItems)
        let snapshotIds = Set(snapshotItems.map(\.id))
        let normalizedMessages = coalescingDuplicateIds(messages)
        let firstIndex = normalizedMessages.firstIndex(where: { $0.turnId == turnId }) ?? normalizedMessages.endIndex
        let existing = normalizedMessages.filter { $0.turnId == turnId }
        let existingIndexById = Dictionary(uniqueKeysWithValues: existing.enumerated().map { ($0.element.id, $0.offset) })
        var existingIndexesBySemanticKey: [ExactSemanticKey: [Int]] = [:]
        var streamingExistingIndexes: [Int] = []
        var userExistingIndexes: [Int] = []
        for (index, item) in existing.enumerated() {
            if let key = exactSemanticKey(item) { existingIndexesBySemanticKey[key, default: []].append(index) }
            if item.kind == .message || item.kind == .reasoning { streamingExistingIndexes.append(index) }
            if item.role == .user { userExistingIndexes.append(index) }
        }
        var consumedExistingIds = Set<String>()
        var merged: [TranscriptItem] = []
        for item in snapshotItems {
            let exactIndex = existingIndexById[item.id]
            let reservedSemanticMatch = exactIndex == nil && existing.contains {
                snapshotIds.contains($0.id)
                    && (semanticallyMatches($0, item) || equivalentUserMessage($0, item))
            }
            if reservedSemanticMatch { continue }
            let semanticIndex = exactSemanticKey(item).flatMap { key in
                existingIndexesBySemanticKey[key]?.first(where: {
                    !consumedExistingIds.contains(existing[$0].id)
                        && !snapshotIds.contains(existing[$0].id)
                        && semanticallyMatches(existing[$0], item)
                })
            }
            let streamedPrefixIndex = (item.kind == .message || item.kind == .reasoning)
                ? streamingExistingIndexes.first(where: {
                    !consumedExistingIds.contains(existing[$0].id)
                        && !snapshotIds.contains(existing[$0].id)
                        && semanticallyMatches(existing[$0], item)
                })
                : nil
            let userIndex = item.role == .user
                ? userExistingIndexes.first(where: {
                    !consumedExistingIds.contains(existing[$0].id)
                        && !snapshotIds.contains(existing[$0].id)
                        && equivalentUserMessage(existing[$0], item)
                })
                : nil
            if let index = exactIndex ?? semanticIndex ?? streamedPrefixIndex ?? userIndex {
                consumedExistingIds.insert(existing[index].id)
                var combined = merge(existing: existing[index], incoming: item)
                combined.id = existing[index].id
                merged.append(combined)
            } else {
                merged.append(item)
            }
        }
        for item in existing where !consumedExistingIds.contains(item.id) {
            if item.role == .user && snapshotItems.contains(where: { equivalentUserMessage($0, item) }) {
                continue
            }
            if let index = merged.firstIndex(where: { semanticallyMatches($0, item) }) {
                merged[index] = merge(existing: merged[index], incoming: item)
            } else {
                merged.append(item)
            }
        }
        merged = deduplicated(merged)

        guard merged != existing || normalizedMessages != messages else { return messages }
        var result = normalizedMessages.filter { $0.turnId != turnId }
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
            if item.role == .user,
               let index = result.firstIndex(where: { equivalentUserMessage($0, item) }) {
                var combined = merge(existing: result[index], incoming: item)
                combined.id = result[index].id
                result[index] = combined
                continue
            }
            let insertion = (result.lastIndex(where: { $0.turnId == turnId }).map { $0 + 1 }) ?? result.endIndex
            result.insert(item, at: insertion)
            indexes.removeAll(keepingCapacity: true)
            for (index, item) in result.enumerated() where indexes[item.id] == nil { indexes[item.id] = index }
        }
        return result == messages ? messages : result
    }

    private static func deduplicated(_ items: [TranscriptItem]) -> [TranscriptItem] {
        var result: [TranscriptItem] = []
        var exactSemanticIndexes: [ExactSemanticKey: Int] = [:]
        for item in items {
            let key = exactSemanticKey(item)
            let match = key.flatMap { exactSemanticIndexes[$0] }
                ?? (key == nil ? result.firstIndex(where: { semanticallyMatches($0, item) }) : nil)
            if let index = match {
                var combined = merge(existing: result[index], incoming: item)
                combined.id = result[index].id
                result[index] = combined
            } else {
                if let key { exactSemanticIndexes[key] = result.count }
                result.append(item)
            }
        }
        return result
    }

    static func mergeHistoryItems(_ historyItems: [TranscriptItem], into messages: [TranscriptItem]) -> [TranscriptItem] {
        let historyItems = coalescingDuplicateIds(historyItems.filter { !isInternalEnvironmentContext($0) })
        let historyIds = Set(historyItems.map(\.id))
        var result = coalescingDuplicateIds(messages.filter { !isInternalEnvironmentContext($0) })
        var indexById = Dictionary(uniqueKeysWithValues: result.enumerated().map { ($0.element.id, $0.offset) })
        var consumedIds = Set<String>()
        for item in historyItems {
            let exactIndex = indexById[item.id]
            let reservedSemanticMatch = exactIndex == nil && result.contains {
                historyIds.contains($0.id)
                    && (semanticallyMatches($0, item) || equivalentUserMessage($0, item))
            }
            if reservedSemanticMatch { continue }
            if let index = exactIndex ?? result.firstIndex(where: {
                !consumedIds.contains($0.id)
                    && !historyIds.contains($0.id)
                    && (semanticallyMatches($0, item) || equivalentUserMessage($0, item))
            }) {
                consumedIds.insert(result[index].id)
                var combined = merge(existing: result[index], incoming: item)
                combined.id = result[index].id
                result[index] = combined
            } else if let turnId = item.turnId,
                      let lastTurnIndex = result.lastIndex(where: { $0.turnId == turnId }) {
                result.insert(item, at: lastTurnIndex + 1)
                indexById = Dictionary(uniqueKeysWithValues: result.enumerated().map { ($0.element.id, $0.offset) })
            } else if item.turnId != nil,
                      let firstUnboundIndex = result.firstIndex(where: { $0.turnId == nil }) {
                result.insert(item, at: firstUnboundIndex)
                indexById = Dictionary(uniqueKeysWithValues: result.enumerated().map { ($0.element.id, $0.offset) })
            } else {
                indexById[item.id] = result.count
                result.append(item)
            }
        }
        let ordered = reorderKnownHistoryTurns(result, historyItems: historyItems)
        return moveInitialHistoryPromptsToTurnStart(ordered, historyItems: historyItems)
    }

    static func coalescingDuplicateIds(_ items: [TranscriptItem]) -> [TranscriptItem] {
        guard items.count > 1 else { return items }
        var result: [TranscriptItem] = []
        result.reserveCapacity(items.count)
        var indexById: [String: Int] = [:]
        indexById.reserveCapacity(items.count)
        for item in items {
            if let index = indexById[item.id] {
                var combined = merge(existing: result[index], incoming: item)
                combined.id = result[index].id
                result[index] = combined
            } else {
                indexById[item.id] = result.count
                result.append(item)
            }
        }
        return result
    }

    private struct ExactSemanticKey: Hashable {
        let turnId: String?
        let role: Int
        let kind: Int
        let text: String
    }

    private static func exactSemanticKey(_ item: TranscriptItem) -> ExactSemanticKey? {
        let kind: Int
        switch item.kind {
        case .command: kind = 1
        case .fileChange: kind = 2
        case .webSearch: kind = 3
        case .plan: kind = 4
        case .contextCompaction: kind = 5
        case .image: kind = 6
        case .message, .reasoning, .subagent, .other: return nil
        }
        let role: Int
        switch item.role {
        case .user: role = 1
        case .assistant: role = 2
        case .tool: role = 3
        case .system: role = 4
        }
        let text = normalizedText(item.text)
        guard !text.isEmpty else { return nil }
        return ExactSemanticKey(turnId: item.turnId, role: role, kind: kind, text: text)
    }

    private static func moveInitialHistoryPromptsToTurnStart(
        _ messages: [TranscriptItem],
        historyItems: [TranscriptItem]
    ) -> [TranscriptItem] {
        var result = messages
        var handledTurnIds = Set<String>()
        for historyItem in historyItems {
            guard historyItem.role == .user,
                  let turnId = historyItem.turnId,
                  handledTurnIds.insert(turnId).inserted,
                  let currentIndex = result.firstIndex(where: { equivalentUserMessage($0, historyItem) }),
                  let firstTurnIndex = result.firstIndex(where: { $0.turnId == turnId }),
                  currentIndex != firstTurnIndex else { continue }
            let prompt = result.remove(at: currentIndex)
            let insertion = result.firstIndex(where: { $0.turnId == turnId }) ?? result.endIndex
            result.insert(prompt, at: insertion)
        }
        return result
    }

    private static func reorderKnownHistoryTurns(
        _ messages: [TranscriptItem],
        historyItems: [TranscriptItem]
    ) -> [TranscriptItem] {
        var orderedTurnIds: [String] = []
        var orderByTurnId: [String: Int] = [:]
        for item in historyItems {
            guard let turnId = item.turnId, orderByTurnId[turnId] == nil else { continue }
            orderByTurnId[turnId] = orderedTurnIds.count
            orderedTurnIds.append(turnId)
        }
        guard orderedTurnIds.count > 1 else { return messages }

        var blocks: [[TranscriptItem]] = []
        for item in messages {
            if let last = blocks.indices.last, blocks[last].first?.turnId == item.turnId {
                blocks[last].append(item)
            } else {
                blocks.append([item])
            }
        }
        let orderedBlocks: [(position: Int, order: Int, block: [TranscriptItem])] = blocks.enumerated().compactMap { position, block in
            guard let turnId = block.first?.turnId, let order = orderByTurnId[turnId] else { return nil }
            return (position, order, block)
        }.sorted { lhs, rhs in
            lhs.order == rhs.order ? lhs.position < rhs.position : lhs.order < rhs.order
        }
        var nextOrderedBlock = orderedBlocks.makeIterator()
        for index in blocks.indices where blocks[index].first?.turnId.flatMap({ orderByTurnId[$0] }) != nil {
            guard let next = nextOrderedBlock.next() else { break }
            blocks[index] = next.block
        }
        return blocks.flatMap { $0 }
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
            .sorted { $0.value.sequence > $1.value.sequence }

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
                // A streamed snapshot may replace the original anchor id. Keep
                // the end of the turn, after the final output. Multiple
                // unresolved anchors are inserted before that output while
                // processing placements in descending sequence order.
                insertion = result.indices.first(where: { candidateIndex in
                    let candidate = result[candidateIndex]
                    return candidate.role == .user
                        && candidate.turnId == turnId
                        && (placements[candidate.id]?.sequence ?? Int.min) > placement.sequence
                })
                    ?? result.firstIndex(where: { $0.turnId == turnId && $0.isFinalAnswer })
                    ?? min(index, result.endIndex)
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
        if merged.rawAgentText == nil { merged.rawAgentText = existing.rawAgentText }
        if merged.createdAt == nil { merged.createdAt = existing.createdAt }
        return merged
    }

    static func semanticallyMatches(_ lhs: TranscriptItem, _ rhs: TranscriptItem) -> Bool {
        guard lhs.turnId == rhs.turnId, lhs.role == rhs.role, lhs.kind == rhs.kind else { return false }
        let lhsText: String
        let rhsText: String
        switch lhs.kind {
        case .message:
            guard lhs.role == .assistant else { return false }
            if lhs.phase != rhs.phase,
               lhs.phase != nil,
               rhs.phase != nil,
               lhs.rawAgentText == nil,
               rhs.rawAgentText == nil { return false }
            lhsText = normalizedText(lhs.text.nonEmpty ?? lhs.detail ?? "")
            rhsText = normalizedText(rhs.text.nonEmpty ?? rhs.detail ?? "")
        case .command, .fileChange, .webSearch, .plan, .contextCompaction, .image:
            lhsText = normalizedText(lhs.text)
            rhsText = normalizedText(rhs.text)
        case .reasoning:
            lhsText = normalizedText(lhs.text.nonEmpty ?? lhs.detail ?? "")
            rhsText = normalizedText(rhs.text.nonEmpty ?? rhs.detail ?? "")
        case .subagent, .other:
            return false
        }
        return streamTextMatches(lhsText, rhsText, allowsPrefix: lhs.kind == .message || lhs.kind == .reasoning)
    }

    private static func streamTextMatches(_ lhs: String, _ rhs: String, allowsPrefix: Bool) -> Bool {
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        if lhs == rhs { return true }
        guard allowsPrefix else { return false }
        let shorter = lhs.count <= rhs.count ? lhs : rhs
        let longer = lhs.count <= rhs.count ? rhs : lhs
        return shorter.count >= 6 && longer.hasPrefix(shorter)
    }

    static func normalizedText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func insertionAfterTurn(_ turnId: String?, in messages: [TranscriptItem]) -> Int {
        guard let turnId,
              let lastIndex = messages.lastIndex(where: { $0.turnId == turnId }) else {
            return messages.endIndex
        }
        return lastIndex + 1
    }

    private static func equivalentUserMessage(_ lhs: TranscriptItem, _ rhs: TranscriptItem) -> Bool {
        guard lhs.role == .user, rhs.role == .user,
              let lhsTurnId = lhs.turnId,
              lhsTurnId == rhs.turnId else { return false }
        return sameUserContent(lhs, rhs)
    }

    private static func sameUserContent(_ lhs: TranscriptItem, _ rhs: TranscriptItem) -> Bool {
        normalizedText(lhs.text) == normalizedText(rhs.text)
            && lhs.imagePaths == rhs.imagePaths
            && lhs.goal == rhs.goal
    }

    private static func shouldMergeUserUpsert(_ lhs: TranscriptItem, _ rhs: TranscriptItem) -> Bool {
        guard lhs.role == .user, rhs.role == .user, sameUserContent(lhs, rhs) else { return false }
        if lhs.turnId == nil || rhs.turnId == nil {
            guard let left = lhs.createdAt, let right = rhs.createdAt else { return false }
            return abs(left.timeIntervalSince(right)) <= 2
        }
        guard lhs.turnId == rhs.turnId else { return false }
        let lhsIsHistory = lhs.id.hasPrefix("item-")
        let rhsIsHistory = rhs.id.hasPrefix("item-")
        let lhsIsRollout = lhs.id.hasPrefix("msg_")
        let rhsIsRollout = rhs.id.hasPrefix("msg_")
        return (lhsIsHistory && rhsIsRollout) || (lhsIsRollout && rhsIsHistory)
    }

    private static func isInternalEnvironmentContext(_ item: TranscriptItem) -> Bool {
        guard item.role == .user, item.imagePaths.isEmpty else { return false }
        let pattern = #"^\s*<environment_context\b[^>]*>[\s\S]*</environment_context>\s*$"#
        return item.text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
