import Foundation

struct MobileActivityFeed: Equatable {
    let entries: [MobileActivityEntry]
    let hiddenPassiveEventCount: Int

    static func make(items: [TranscriptItem]) -> MobileActivityFeed {
        var normalized: [TranscriptItem] = []
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
            guard !text.isEmpty else { continue }
            if let index = normalized.firstIndex(where: { candidate in
                guard candidate.isCommentary else { return false }
                let candidateText = TranscriptReconciler.normalizedText(candidate.text)
                if candidateText == text { return true }
                let shorter = candidateText.count <= text.count ? candidateText : text
                let longer = candidateText.count <= text.count ? text : candidateText
                return shorter.count >= 4 && longer.hasPrefix(shorter)
            }) {
                if text.count > TranscriptReconciler.normalizedText(normalized[index].text).count {
                    var replacement = item
                    replacement.id = normalized[index].id
                    normalized[index] = replacement
                }
            } else {
                normalized.append(item)
            }
        }

        let latestReasoningId = normalized.last(where: { $0.kind == .reasoning })?.id
        var entries: [MobileActivityEntry] = []
        var pendingTools: [TranscriptItem] = []

        func flushTools() {
            guard let first = pendingTools.first else { return }
            entries.append(.tools(id: "tools.\(first.id)", items: pendingTools))
            pendingTools = []
        }

        for item in normalized {
            if item.kind == .reasoning {
                guard item.id == latestReasoningId,
                      let text = latestLine(item.text.nonEmpty ?? item.detail) else { continue }
                flushTools()
                entries.append(.reasoning(id: "reasoning.\(item.id)", text: text))
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

    var eventCount: Int {
        entries.reduce(0) { result, entry in
            switch entry {
            case .progress, .reasoning: return result + 1
            case .tools(_, let items): return result + items.count
            }
        }
    }

    var completedSummary: String {
        let toolItems = entries.flatMap { entry -> [TranscriptItem] in
            if case .tools(_, let items) = entry { return items }
            return []
        }
        let progressCount = entries.filter {
            if case .progress = $0 { return true }
            return false
        }.count
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
        source?.suffix(4_096).split(whereSeparator: \.isNewline).reversed().lazy
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }
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
