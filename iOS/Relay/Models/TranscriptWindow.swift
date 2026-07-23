struct TranscriptWindow: Equatable {
    let groups: [TranscriptGroup]
    let hasEarlierGroups: Bool

    static func build(
        messages: [TranscriptItem],
        metadata: [String: TurnMetadata],
        limit: Int
    ) -> TranscriptWindow {
        var index = TranscriptIndex()
        index.rebuild(messages: messages)
        return index.window(messages: messages, metadata: metadata, limit: limit)
    }
}

struct TranscriptIndex {
    private struct GroupRange: Equatable {
        let id: String
        let turnId: String?
        var range: Range<Int>
    }

    private var ranges: [GroupRange] = []
    private var itemIndexes: [String: Int] = [:]
    private(set) var fullRebuildCount = 0
    private(set) var incrementalUpdateCount = 0

    mutating func rebuild(messages: [TranscriptItem]) {
        ranges.removeAll(keepingCapacity: true)
        itemIndexes.removeAll(keepingCapacity: true)
        for (index, item) in messages.enumerated() {
            itemIndexes[item.id] = index
            appendRange(for: item, at: index)
        }
        fullRebuildCount += 1
    }

    mutating func applyDeltaBatch(_ updates: [TranscriptDeltaUpdate], to messages: inout [TranscriptItem]) -> Bool {
        guard !updates.isEmpty else { return false }
        var changed = false
        var needsRebuild = false
        for update in updates {
            if let index = itemIndexes[update.id] {
                let oldKey = Self.groupKey(messages[index])
                messages[index].text += update.text
                if !update.detail.isEmpty { messages[index].detail = (messages[index].detail ?? "") + update.detail }
                if messages[index].turnId == nil { messages[index].turnId = update.turnId }
                needsRebuild = needsRebuild || oldKey != Self.groupKey(messages[index])
                changed = true
            } else {
                let item = TranscriptItem(
                    id: update.id,
                    turnId: update.turnId,
                    role: update.role,
                    kind: update.kind,
                    title: update.title,
                    text: update.text,
                    detail: update.detail.nonEmpty,
                    status: update.kind == .command ? "inProgress" : nil
                )
                let index = messages.count
                messages.append(item)
                itemIndexes[item.id] = index
                appendRange(for: item, at: index)
                changed = true
            }
        }
        if needsRebuild { rebuild(messages: messages) }
        incrementalUpdateCount += 1
        return changed
    }

    mutating func adoptReconciledUpserts(
        _ nextMessages: [TranscriptItem],
        changedItemIds: Set<String>
    ) -> Bool {
        guard nextMessages.count >= itemIndexes.count else { return false }
        let previousCount = itemIndexes.count
        let appendedItems = nextMessages.dropFirst(previousCount)
        let appendedIds = Set(appendedItems.map(\.id))
        guard appendedIds.count == appendedItems.count,
              appendedIds.allSatisfy({ itemIndexes[$0] == nil }) else { return false }

        for id in changedItemIds.subtracting(appendedIds) {
            guard let index = itemIndexes[id], nextMessages.indices.contains(index),
                  nextMessages[index].id == id,
                  groupId(containing: index) == Self.groupKey(nextMessages[index]) else { return false }
        }

        for (offset, item) in appendedItems.enumerated() {
            let index = previousCount + offset
            itemIndexes[item.id] = index
            appendRange(for: item, at: index)
        }
        incrementalUpdateCount += 1
        return true
    }

    func window(
        messages: [TranscriptItem],
        metadata: [String: TurnMetadata],
        limit: Int
    ) -> TranscriptWindow {
        let visibleLimit = max(1, limit)
        let start = max(0, ranges.count - visibleLimit)
        let groups = ranges[start...].map { descriptor in
            TranscriptGroup(
                id: descriptor.id,
                turnId: descriptor.turnId,
                items: Array(messages[descriptor.range]),
                metadata: descriptor.turnId.flatMap { metadata[$0] } ?? TurnMetadata()
            )
        }
        return TranscriptWindow(groups: groups, hasEarlierGroups: start > 0)
    }

    private mutating func appendRange(for item: TranscriptItem, at index: Int) {
        let key = Self.groupKey(item)
        if let lastIndex = ranges.indices.last, ranges[lastIndex].id == key {
            ranges[lastIndex].range = ranges[lastIndex].range.lowerBound..<(index + 1)
        } else {
            ranges.append(GroupRange(id: key, turnId: item.turnId, range: index..<(index + 1)))
        }
    }

    private func groupId(containing itemIndex: Int) -> String? {
        ranges.first(where: { $0.range.contains(itemIndex) })?.id
    }

    private static func groupKey(_ item: TranscriptItem) -> String {
        item.turnId.map { "turn.\($0)" } ?? "item.\(item.id)"
    }
}
