import SwiftUI

struct TurnGroupView: View {
    let group: TranscriptGroup
    let isLive: Bool
    @State private var activityExpanded: Bool
    @State private var renderedActivitySectionCount = 0

    init(group: TranscriptGroup, isLive: Bool) {
        self.group = group
        self.isLive = isLive
        _activityExpanded = State(initialValue: isLive || group.turnId == nil)
        _renderedActivitySectionCount = State(initialValue: isLive || group.turnId == nil ? 8 : 0)
    }

    var body: some View {
        let timeline = timelineSegments
        let firstActivityIndex = timeline.firstIndex(where: \.isActivity)
        let totalActivitySectionCount = timeline.reduce(0) { $0 + $1.activitySectionCount }
        let activityOffsets = activityOffsets(for: timeline)

        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(timeline.enumerated()), id: \.element.id) { index, segment in
                switch segment {
                case .user(let item, let isFollowUp):
                    TranscriptRow(item: item, isFollowUp: isFollowUp)
                case .activity(let id, let items, let sectionCount):
                    let visibleCount = max(0, min(sectionCount, renderedActivitySectionCount - (activityOffsets[id] ?? 0)))
                    RunActivityView(
                        items: items,
                        metadata: group.metadata,
                        isLive: isLive,
                        showsHeader: group.turnId != nil && index == firstActivityIndex,
                        canExpand: totalActivitySectionCount > 0,
                        visibleSectionCount: visibleCount,
                        remainingSectionCount: index == firstActivityIndex ? max(0, totalActivitySectionCount - renderedActivitySectionCount) : 0,
                        expanded: $activityExpanded,
                        onShowMore: { renderedActivitySectionCount = min(renderedActivitySectionCount + 8, totalActivitySectionCount) }
                    )
                case .item(let item):
                    TranscriptRow(item: item)
                }
            }

            if group.answerItems.isEmpty, let error = group.metadata.errorMessage, !error.isEmpty {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: activityExpanded) { expanded in
            renderedActivitySectionCount = expanded ? min(max(renderedActivitySectionCount, 8), totalActivitySectionCount) : 0
        }
        .onChange(of: isLive) { running in
            if running {
                activityExpanded = true
                renderedActivitySectionCount = min(max(renderedActivitySectionCount, 8), totalActivitySectionCount)
            } else {
                activityExpanded = false
                renderedActivitySectionCount = 0
            }
        }
    }

    private var timelineSegments: [TurnTimelineSegment] {
        var result: [TurnTimelineSegment] = []
        var pendingActivity: [TranscriptItem] = []
        var hasSeenUserMessage = false

        func flushActivity() {
            guard let first = pendingActivity.first else { return }
            let sectionCount = makeActivitySectionPage(items: pendingActivity, limit: 0).totalCount
            result.append(.activity(id: "activity.\(first.id)", items: pendingActivity, sectionCount: sectionCount))
            pendingActivity = []
        }

        for item in group.items {
            if item.isActivity {
                pendingActivity.append(item)
                continue
            }
            flushActivity()
            if item.role == .user {
                result.append(.user(item, isFollowUp: hasSeenUserMessage))
                hasSeenUserMessage = true
            } else {
                result.append(.item(item))
            }
        }
        flushActivity()

        if isLive, !result.contains(where: \.isActivity) {
            result.append(.activity(id: "activity.pending.\(group.id)", items: [], sectionCount: 0))
        }
        return result
    }

    private func activityOffsets(for timeline: [TurnTimelineSegment]) -> [String: Int] {
        var result: [String: Int] = [:]
        var offset = 0
        for segment in timeline {
            guard case .activity(let id, _, let sectionCount) = segment else { continue }
            result[id] = offset
            offset += sectionCount
        }
        return result
    }
}

private enum TurnTimelineSegment: Identifiable {
    case user(TranscriptItem, isFollowUp: Bool)
    case activity(id: String, items: [TranscriptItem], sectionCount: Int)
    case item(TranscriptItem)

    var id: String {
        switch self {
        case .user(let item, _): return "user.\(item.id)"
        case .activity(let id, _, _): return id
        case .item(let item): return "item.\(item.id)"
        }
    }

    var isActivity: Bool {
        if case .activity = self { return true }
        return false
    }

    var activitySectionCount: Int {
        guard case .activity(_, _, let count) = self else { return 0 }
        return count
    }
}

struct TranscriptRow: View {
    let item: TranscriptItem
    let isFollowUp: Bool
    @EnvironmentObject private var store: RelayStore

    init(item: TranscriptItem, isFollowUp: Bool = false) {
        self.item = item
        self.isFollowUp = isFollowUp
    }

    var body: some View {
        switch item.role {
        case .user:
            HStack {
                Spacer(minLength: 46)
                VStack(alignment: .trailing, spacing: 4) {
                    if isFollowUp {
                        Text("引导")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .padding(.trailing, 3)
                    }
                    if !item.imagePaths.isEmpty {
                        InlineImageGrid(paths: item.imagePaths)
                    }
                    if !item.text.isEmpty {
                        MarkdownContentView(source: item.text)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 11)
                            .background(RelayTheme.softFill)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    if let deliveryState = item.deliveryState {
                        deliveryStatus(deliveryState)
                    }
                }
            }
        case .assistant:
            if item.isCommentary {
                MarkdownContentView(source: item.text, baseFontSize: 13, blockSpacing: 6, lineSpacing: 2)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if let title = item.title {
                        Text(title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    MarkdownContentView(source: item.textWithoutDownloadLinks)
                    if !item.downloadablePaths.isEmpty {
                        DownloadFileLinks(paths: item.downloadablePaths)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .tool:
            ToolEventRow(item: item)
        case .system:
            Text(item.text)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func deliveryStatus(_ state: MessageDeliveryState) -> some View {
        HStack(spacing: 5) {
            switch state {
            case .sending:
                ProgressView().controlSize(.mini)
                Text("发送中")
            case .accepted:
                Image(systemName: "checkmark")
                Text("Bridge 已接收")
            case .uncertain(_):
                Image(systemName: "questionmark.circle")
                Text("待确认")
                Button("检查") { Task { await store.confirmMessageDelivery(item.id) } }
                    .fontWeight(.semibold)
            case .failed(_):
                Image(systemName: "exclamationmark.circle.fill")
                Text("未发送")
                Button("恢复") { store.restoreMessageToComposer(item.id) }
                    .fontWeight(.semibold)
            }
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(deliveryColor(state))
        .padding(.trailing, 3)
    }

    private func deliveryColor(_ state: MessageDeliveryState) -> Color {
        switch state {
        case .failed(_): return .red
        case .uncertain(_): return .orange
        case .sending, .accepted: return .secondary
        }
    }
}

private struct InlineImageGrid: View {
    let paths: [String]

    private var columns: [GridItem] {
        paths.count == 1
            ? [GridItem(.flexible(), spacing: 5)]
            : [GridItem(.flexible(), spacing: 5), GridItem(.flexible(), spacing: 5)]
    }

    var body: some View {
        LazyVGrid(columns: columns, alignment: .trailing, spacing: 5) {
            ForEach(paths, id: \.self) { path in
                InlineMessageImage(path: path)
            }
        }
        .frame(width: paths.count == 1 ? 190 : 250)
        .transaction { $0.animation = nil }
    }
}

private struct InlineMessageImage: View {
    let path: String
    @EnvironmentObject private var store: RelayStore

    var body: some View {
        Button {
            Task { await store.shareImagePreview(path: path) }
        } label: {
            ZStack {
                RelayTheme.softFill
                if let url = store.imagePreviewURLs[path], let image = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else if store.loadingImagePaths.contains(path) {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(4 / 3, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .task(id: path) { await store.loadImagePreview(path: path) }
    }
}

private struct DownloadFileLinks: View {
    let paths: [String]
    @EnvironmentObject private var store: RelayStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(paths, id: \.self) { path in
                Button {
                    Task { await store.downloadFile(path: path) }
                } label: {
                    HStack(spacing: 6) {
                        if store.downloadingPath == path { ProgressView().controlSize(.mini) }
                        else { Image(systemName: "arrow.down.circle") }
                        Text("下载 \(path.lastPathComponentForDisplay)").lineLimit(1)
                    }
                    .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .disabled(store.downloadingPath != nil)
            }
        }
    }
}

private struct RunActivityView: View {
    let items: [TranscriptItem]
    let metadata: TurnMetadata
    let isLive: Bool
    let showsHeader: Bool
    let canExpand: Bool
    let visibleSectionCount: Int
    let remainingSectionCount: Int
    @Binding var expanded: Bool
    let onShowMore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if showsHeader {
                Button {
                    guard canExpand else { return }
                    expanded.toggle()
                } label: {
                    HStack(alignment: .center, spacing: 7) {
                        Group {
                            if isLive {
                                ProgressView()
                                    .controlSize(.mini)
                                    .tint(.secondary)
                            } else {
                                Image(systemName: statusIcon)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(statusColor)
                            }
                        }
                        .frame(width: 14, height: 16, alignment: .center)

                        Group {
                            if isLive {
                                TimelineView(.periodic(from: .now, by: 1)) { _ in
                                    Text(activityLabel)
                                }
                            } else {
                                Text(activityLabel)
                            }
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)

                        Spacer(minLength: 6)
                        if canExpand {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.tertiary)
                                .rotationEffect(.degrees(expanded ? 180 : 0))
                                .frame(height: 16, alignment: .center)
                        }
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }

            if expanded {
                if visibleSectionCount > 0 {
                    RunActivityDetails(items: items, visibleSectionCount: visibleSectionCount)
                }
                if remainingSectionCount > 0 {
                    Button(action: onShowMore) {
                        HStack(spacing: 6) {
                            Image(systemName: "ellipsis.circle")
                            Text("显示更多进展（剩余 \(remainingSectionCount) 条）")
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 5)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var elapsedMilliseconds: Int {
        if let duration = metadata.durationMs, duration > 0 { return duration }
        guard let startedAt = metadata.startedAt else { return 0 }
        guard isLive || metadata.completedAt != nil else { return 0 }
        let end = isLive ? Date() : (metadata.completedAt ?? startedAt)
        return max(0, Int(end.timeIntervalSince(startedAt) * 1000))
    }

    private var activityLabel: String {
        let label: String
        if isLive { label = "正在处理" }
        else if metadata.status == "failed" { label = "处理失败" }
        else if metadata.status == "interrupted" { label = "已停止" }
        else { label = "已处理" }
        guard hasElapsedTiming else { return label }
        return "\(label) · \(formatDuration(milliseconds: elapsedMilliseconds))"
    }

    private var hasElapsedTiming: Bool {
        if let duration = metadata.durationMs, duration > 0 { return true }
        return metadata.startedAt != nil && (isLive || metadata.completedAt != nil)
    }

    private var statusIcon: String {
        metadata.status == "failed" ? "xmark.circle.fill" : metadata.status == "interrupted" ? "stop.circle.fill" : "checkmark.circle.fill"
    }

    private var statusColor: Color {
        metadata.status == "failed" ? .red : metadata.status == "interrupted" ? .secondary : RelayTheme.accent
    }
}

private struct RunActivityDetails: View {
    let items: [TranscriptItem]
    let visibleSectionCount: Int

    var body: some View {
        let sections = makeActivitySectionPage(items: items, limit: visibleSectionCount).sections
        LazyVStack(alignment: .leading, spacing: 7) {
            ForEach(sections) { section in
                switch section {
                case .commentary(let item):
                    MarkdownContentView(source: item.text, baseFontSize: 13, blockSpacing: 6, lineSpacing: 2)
                        .foregroundStyle(Color.primary.opacity(0.9))
                case .reasoning(let id, let text):
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .frame(width: 14, height: 16)
                        CompactMarkdownText(source: text, size: 12)
                            .foregroundStyle(.secondary)
                            .id(id)
                    }
                case .execution(_, let executionItems):
                    ExecutionGroupView(items: executionItems)
                }
            }
        }
    }
}

private struct ActivitySectionPage {
    let sections: [ActivitySection]
    let totalCount: Int
}

private func makeActivitySectionPage(items: [TranscriptItem], limit: Int) -> ActivitySectionPage {
    var sections: [ActivitySection] = []
    var pendingExecution: [TranscriptItem] = []
    var hasPendingExecution = false
    var totalCount = 0
    let latestReasoningId = items.last(where: { $0.kind == .reasoning })?.id

    func append(_ section: ActivitySection) {
        totalCount += 1
        if sections.count < limit { sections.append(section) }
    }

    func flushExecution() {
        guard hasPendingExecution else { return }
        let id = pendingExecution.first?.id ?? "hidden.\(totalCount)"
        append(.execution(id: "execution.\(id)", items: pendingExecution))
        pendingExecution = []
        hasPendingExecution = false
    }

    for item in items where item.kind != .plan {
        if item.kind == .reasoning {
            guard item.id == latestReasoningId else { continue }
            flushExecution()
            guard let source = item.text.nonEmpty ?? item.detail?.nonEmpty else { continue }
            totalCount += 1
            if sections.count < limit, let text = lastNonemptyLine(source) {
                sections.append(.reasoning(id: item.id, text: text))
            }
        } else if item.isCommentary {
            flushExecution()
            append(.commentary(item))
        } else {
            hasPendingExecution = true
            if totalCount < limit { pendingExecution.append(item) }
        }
    }
    flushExecution()
    return ActivitySectionPage(sections: sections, totalCount: totalCount)
}

private func lastNonemptyLine(_ source: String?) -> String? {
    guard let source else { return nil }
    return source.split(whereSeparator: \.isNewline).reversed().lazy
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        .first(where: { !$0.isEmpty })
}

private enum ActivitySection: Identifiable {
    case commentary(TranscriptItem)
    case reasoning(id: String, text: String)
    case execution(id: String, items: [TranscriptItem])

    var id: String {
        switch self {
        case .commentary(let item): return "commentary.\(item.id)"
        case .reasoning(let id, _): return "reasoning.\(id)"
        case .execution(let id, _): return id
        }
    }
}

private struct CompactMarkdownText: View {
    let source: String
    let size: CGFloat
    var weight: Font.Weight = .regular

    var body: some View {
        if let attributed = try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            Text(attributed)
                .font(.system(size: size, weight: weight))
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(source.replacingOccurrences(of: "**", with: ""))
                .font(.system(size: size, weight: weight))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ExecutionGroupView: View {
    let items: [TranscriptItem]
    @State private var expanded = false

    var body: some View {
        if items.count == 1, let item = items.first {
            ToolEventRow(item: item)
        } else {
            groupedBody
        }
    }

    private var groupedBody: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "terminal")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    Text(summary)
                        .font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 6)
                    groupStatus
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .contentShape(Rectangle())
                .padding(.vertical, 5)
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(items) { item in
                        if item.kind == .command {
                            CompactCommandRow(item: item)
                        } else {
                            ToolEventRow(item: item)
                        }
                    }
                }
                .padding(.leading, 18)
            }
        }
    }

    @ViewBuilder
    private var groupStatus: some View {
        if items.contains(where: { $0.isRunningStatus }) {
            ProgressView().controlSize(.mini)
        } else if items.contains(where: { $0.isFailedStatus }) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.red)
        } else {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(RelayTheme.accent)
        }
    }

    private var summary: String {
        let commandCount = items.filter { $0.kind == .command }.count
        let fileCount = items.filter { $0.kind == .fileChange }.count
        let otherCount = items.count - commandCount - fileCount
        var parts: [String] = []
        if fileCount > 0 { parts.append(fileCount == 1 ? "编辑了文件" : "编辑了多个文件") }
        if commandCount > 0 { parts.append(commandCount == 1 ? "运行了命令" : "运行了多个命令") }
        if otherCount > 0 { parts.append(otherCount == 1 ? "使用了工具" : "使用了多个工具") }
        return parts.isEmpty ? "执行了操作" : parts.joined(separator: "并")
    }
}

private struct CompactCommandRow: View {
    let item: TranscriptItem
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button {
                guard hasDetails else { return }
                expanded.toggle()
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: "terminal")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                    Text(commandSummary)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(item.isFailedStatus ? Color.red : Color.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 5)
                    if let exitCode = item.exitCode, exitCode != 0 {
                        Text("exit \(exitCode)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.red)
                    }
                    if item.isRunningStatus {
                        ProgressView().controlSize(.mini)
                    }
                    if hasDetails {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                    }
                }
                .contentShape(Rectangle())
                .padding(.vertical, 3)
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 3) {
                    if let error = item.errorMessage?.nonEmpty {
                        Text(error)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let cwd = item.cwd?.nonEmpty {
                        Text(cwd)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    if let detail = item.detail?.nonEmpty {
                        CompactTechnicalDetail(detail: detail)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var commandSummary: String {
        item.text.components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty ?? "命令"
    }
    private var hasDetails: Bool {
        item.detail?.nonEmpty != nil || item.errorMessage?.nonEmpty != nil || item.cwd?.nonEmpty != nil
    }
}

private struct CompactTechnicalDetail: View {
    let detail: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Text(preview.detail)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(9)
        }
        .frame(height: CGFloat(preview.lineCount) * 14 + 18)
        .background(RelayTheme.codeFill)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var preview: (detail: String, lineCount: Int) {
        let byteLimit = 24_000
        let bytes = detail.utf8
        let tail = bytes.count > byteLimit
            ? String(decoding: bytes.suffix(byteLimit), as: UTF8.self)
            : detail
        let lines = tail.components(separatedBy: .newlines)
        let visible = Array(lines.suffix(12))
        let omitted = bytes.count > byteLimit || lines.count > visible.count
        let text = (omitted ? ["... earlier output omitted ..."] : []) + visible
        return (text.joined(separator: "\n"), max(1, text.count))
    }
}

private struct ToolEventRow: View {
    let item: TranscriptItem
    @EnvironmentObject private var store: RelayStore
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                guard hasExpandableContent else { return }
                expanded.toggle()
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(iconColor)
                        .frame(width: 19, height: 20)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(item.title ?? title)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.primary)
                            if let durationMs = item.durationMs, durationMs > 0 {
                                Text(formatDuration(milliseconds: durationMs))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                            }
                            if let exitCode = item.exitCode, item.kind == .command {
                                Text("exit \(exitCode)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(exitCode == 0 ? Color.secondary.opacity(0.65) : Color.red)
                            }
                        }

                        if !item.text.isEmpty {
                            if item.kind == .reasoning || item.kind == .plan || item.isCommentary {
                                MarkdownContentView(source: item.text)
                                    .foregroundStyle(item.kind == .reasoning ? .secondary : .primary)
                            } else {
                                Text(item.text)
                                    .font(.system(size: 12, design: item.kind == .command ? .monospaced : .default))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(expanded ? 12 : 1)
                            }
                        }

                        if isFailed {
                            Text("操作失败：\(item.errorMessage?.nonEmpty ?? "Codex 未返回更多原因")")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.red)
                                .lineLimit(expanded ? 5 : 2)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if let cwd = item.cwd, !cwd.isEmpty, item.kind == .command {
                            Text(cwd)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 6)
                    if let status = item.status { StatusGlyph(status: status) }
                    if hasExpandableContent {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 4)
                    }
                }
                .contentShape(Rectangle())
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)

            if !item.downloadablePaths.isEmpty, expanded || item.kind == .image {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(item.downloadablePaths, id: \.self) { path in
                        Button {
                            Task { await store.downloadFile(path: path) }
                        } label: {
                            HStack(spacing: 6) {
                                if store.downloadingPath == path {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Image(systemName: "arrow.down.circle")
                                }
                                Text("下载 \(path.lastPathComponentForDisplay)")
                                    .lineLimit(1)
                            }
                            .font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .disabled(store.downloadingPath != nil)
                    }
                }
                .padding(.leading, 29)
                .padding(.bottom, 8)
            }

            if expanded, let detail = item.detail, !detail.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("技术详情")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    detailView(detail)
                }
                .padding(.leading, 29)
                .padding(.bottom, 10)
            }
        }
    }

    @ViewBuilder
    private func detailView(_ detail: String) -> some View {
        if item.kind == .fileChange {
            DiffContentView(source: detail)
        } else if item.kind == .reasoning {
            MarkdownContentView(source: detail)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.leading, 11)
                .overlay(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.25)).frame(width: 2)
                }
        } else {
            CompactTechnicalDetail(detail: detail)
        }
    }

    private var hasExpandableContent: Bool { item.detail?.isEmpty == false }
    private var isFailed: Bool {
        let status = item.status?.lowercased() ?? ""
        return status.contains("fail") || (item.exitCode.map { $0 != 0 } ?? false)
    }

    private var icon: String {
        switch item.kind {
        case .command: return "terminal"
        case .fileChange: return "doc.badge.gearshape"
        case .reasoning: return "sparkles"
        case .webSearch: return "globe"
        case .plan: return "list.bullet.clipboard"
        case .contextCompaction: return "arrow.triangle.2.circlepath"
        case .image: return "photo"
        case .subagent: return "person.2"
        case .message, .other: return "wrench.and.screwdriver"
        }
    }

    private var iconColor: Color {
        item.kind == .contextCompaction ? RelayTheme.accent : .secondary
    }

    private var title: String {
        switch item.kind {
        case .command: return "运行命令"
        case .fileChange: return "修改文件"
        case .reasoning: return "思考"
        case .webSearch: return "搜索网页"
        case .plan: return "执行计划"
        case .contextCompaction: return "已压缩上下文"
        case .image: return "图片"
        case .subagent: return "协作代理"
        case .message, .other: return "工具"
        }
    }
}

private struct StatusGlyph: View {
    let status: String

    var body: some View {
        let normalized = status.lowercased()
        if normalized.contains("progress") || normalized.contains("running") {
            ProgressView().controlSize(.mini)
        } else {
            Image(systemName: normalized.contains("fail") ? "xmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(normalized.contains("fail") ? Color.red : RelayTheme.accent)
        }
    }
}
