import Foundation

struct MobileActivityFeed: Equatable {
    let entries: [MobileActivityEntry]
    let hiddenPassiveEventCount: Int

    static func make(items: [TranscriptItem]) -> MobileActivityFeed {
        var normalized: [TranscriptItem] = []
        var normalizedCommentaryText: [Int: String] = [:]
        let commentaryIndex = CommentaryPrefixIndex()
        var hiddenPassiveEventCount = 0

        for item in items where item.kind != .plan {
            if item.isPassiveWaitEvent {
                hiddenPassiveEventCount += 1
                continue
            }
            guard item.isCommentary else {
                normalized.append(item)
                continue
            }

            let text = TranscriptReconciler.normalizedText(item.text)
            guard !text.isEmpty else {
                if item.detail?.nonEmpty != nil { normalized.append(item) }
                continue
            }
            let matchingIndex = commentaryIndex.candidates(for: text)
                .sorted()
                .first { index in
                    guard let candidateText = normalizedCommentaryText[index] else { return false }
                    if candidateText == text { return true }
                    let shorter = candidateText.count <= text.count ? candidateText : text
                    let longer = candidateText.count <= text.count ? text : candidateText
                    return shorter.count >= 4 && longer.hasPrefix(shorter)
                }
            if let index = matchingIndex {
                if text.count > (normalizedCommentaryText[index]?.count ?? 0) {
                    var replacement = item
                    replacement.id = normalized[index].id
                    normalized[index] = replacement
                    normalizedCommentaryText[index] = text
                    commentaryIndex.insert(text, at: index)
                }
            } else {
                let index = normalized.count
                normalized.append(item)
                normalizedCommentaryText[index] = text
                commentaryIndex.insert(text, at: index)
            }
        }

        let latestReasoningId = normalized.last(where: {
            $0.kind == .reasoning || ($0.isCommentary && $0.detail?.nonEmpty != nil)
        })?.id
        var entries: [MobileActivityEntry] = []
        var pendingTools: [TranscriptItem] = []

        func flushTools() {
            guard let first = pendingTools.first else { return }
            entries.append(.tools(id: "tools.\(first.id)", items: pendingTools))
            pendingTools = []
        }

        for item in normalized {
            if item.kind == .reasoning || (item.isCommentary && item.detail?.nonEmpty != nil) {
                guard item.id == latestReasoningId,
                      let text = latestLine(item.detail?.nonEmpty ?? item.text.nonEmpty) else {
                    if item.isCommentary, let text = item.text.nonEmpty {
                        flushTools()
                        entries.append(.progress(id: "progress.\(item.id)", text: text))
                    }
                    continue
                }
                flushTools()
                entries.append(.reasoning(id: "reasoning.latest", text: text))
                if item.isCommentary, let progress = item.text.nonEmpty {
                    entries.append(.progress(id: "progress.\(item.id)", text: progress))
                }
            } else if item.isCommentary {
                flushTools()
                if let text = item.text.nonEmpty {
                    entries.append(.progress(id: "progress.\(item.id)", text: text))
                }
            } else if item.role == .tool {
                pendingTools.append(item)
            }
        }
        flushTools()

        return MobileActivityFeed(entries: entries, hiddenPassiveEventCount: hiddenPassiveEventCount)
    }

    var latestText: String? {
        for entry in entries.reversed() {
            switch entry {
            case .progress(_, let text), .reasoning(_, let text): return text
            case .tools(_, let items): return MobileActivityFeed.toolSummary(items)
            }
        }
        return nil
    }

    var latestReasoningText: String? {
        entries.reversed().lazy.compactMap { entry -> String? in
            if case .reasoning(_, let text) = entry { return text }
            return nil
        }.first
    }

    var progressItems: [MobileProgressItem] {
        entries.compactMap { entry in
            guard case .progress(let id, let text) = entry else { return nil }
            return MobileProgressItem(id: id, text: text)
        }
    }

    var toolItems: [TranscriptItem] {
        entries.flatMap { entry -> [TranscriptItem] in
            if case .tools(_, let items) = entry { return items }
            return []
        }
    }

    var progressRevision: String {
        guard let latest = progressItems.last else { return "progress.empty" }
        return "\(progressItems.count).\(latest.id).\(latest.text)"
    }

    var toolRevision: String {
        guard let latest = toolItems.last else { return "tools.empty" }
        // The compact tool window does not render command output. Streaming
        // output must not keep forcing this nested scroll view back to bottom.
        return "\(toolItems.count).\(latest.id).\(latest.status ?? "").\(latest.title ?? "").\(latest.text)"
    }

    var eventCount: Int {
        entries.reduce(0) { result, entry in
            switch entry {
            case .progress, .reasoning: return result + 1
            case .tools(_, let items): return result + items.count
            }
        }
    }

    var completedSummary: String {
        let progressCount = progressItems.count
        var parts: [String] = []
        if progressCount > 0 { parts.append("\(progressCount) 条进展") }
        if !toolItems.isEmpty { parts.append(MobileActivityFeed.toolSummary(toolItems)) }
        return parts.isEmpty ? "查看任务活动" : parts.joined(separator: " · ")
    }

    static func toolSummary(_ items: [TranscriptItem]) -> String {
        let commands = items.filter { $0.kind == .command }.count
        let files = items.filter { $0.kind == .fileChange }.count
        let other = max(0, items.count - commands - files)
        var parts: [String] = []
        if commands > 0 { parts.append("\(commands) 条命令") }
        if files > 0 { parts.append("\(files) 个文件") }
        if other > 0 { parts.append("\(other) 个工具") }
        return parts.isEmpty ? "正在执行操作" : parts.joined(separator: " · ")
    }

    private static func latestLine(_ source: String?) -> String? {
        source?
            .replacingOccurrences(of: #"</?thinking\b[^>]*>"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "**", with: "")
            .suffix(4_096).split(whereSeparator: \.isNewline).reversed().lazy
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }
}

struct MobileActivityFeedCache {
    private var key: Key?
    private var value: MobileActivityFeed?

    mutating func feed(
        threadId: String,
        turnId: String?,
        transcriptRevision: Int,
        items: @autoclosure () -> [TranscriptItem]
    ) -> MobileActivityFeed {
        let nextKey = Key(threadId: threadId, turnId: turnId, transcriptRevision: transcriptRevision)
        if key == nextKey, let value { return value }
        let next = MobileActivityFeed.make(items: items())
        key = nextKey
        value = next
        return next
    }

    mutating func reset() {
        key = nil
        value = nil
    }

    private struct Key: Equatable {
        let threadId: String
        let turnId: String?
        let transcriptRevision: Int
    }
}

private final class CommentaryPrefixIndex {
    private final class Node {
        var children: [UInt8: Node] = [:]
        var terminalIndices: [Int] = []
        var descendantIndices: [Int] = []

        func appendDescendant(_ index: Int) {
            if descendantIndices.last != index { descendantIndices.append(index) }
        }

        func appendTerminal(_ index: Int) {
            if terminalIndices.last != index { terminalIndices.append(index) }
        }
    }

    private let root = Node()

    func insert(_ text: String, at index: Int) {
        var node = root
        node.appendDescendant(index)
        for byte in text.utf8 {
            if node.children[byte] == nil { node.children[byte] = Node() }
            node = node.children[byte]!
            node.appendDescendant(index)
        }
        node.appendTerminal(index)
    }

    func candidates(for text: String) -> Set<Int> {
        var node = root
        var result = Set<Int>()
        for byte in text.utf8 {
            guard let child = node.children[byte] else { return result }
            node = child
            result.formUnion(node.terminalIndices)
        }
        result.formUnion(node.descendantIndices)
        return result
    }
}

struct MobileProgressItem: Identifiable, Equatable {
    let id: String
    let text: String
}

enum MobileActivityEntry: Identifiable, Equatable {
    case progress(id: String, text: String)
    case reasoning(id: String, text: String)
    case tools(id: String, items: [TranscriptItem])

    var id: String {
        switch self {
        case .progress(let id, _), .reasoning(let id, _), .tools(let id, _): return id
        }
    }
}

extension TranscriptItem {
    var isPassiveWaitEvent: Bool {
        guard role == .tool else { return false }
        let values = [title, text]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        return values.contains("wait")
            || values.contains("functions.wait")
            || values.contains("wait_agent")
    }
}
