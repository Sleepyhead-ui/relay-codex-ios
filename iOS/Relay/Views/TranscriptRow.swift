import SwiftUI

struct TurnGroupView: View {
    let group: TranscriptGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(group.userItems) { item in
                TranscriptRow(item: item)
            }

            if !group.activityItems.isEmpty || group.metadata.isRunning {
                RunActivityView(items: group.activityItems, metadata: group.metadata)
            }

            ForEach(group.answerItems) { item in
                TranscriptRow(item: item)
            }

            if group.answerItems.isEmpty, let error = group.metadata.errorMessage, !error.isEmpty {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TranscriptRow: View {
    let item: TranscriptItem
    @EnvironmentObject private var store: RelayStore

    var body: some View {
        switch item.role {
        case .user:
            HStack {
                Spacer(minLength: 46)
                MarkdownContentView(source: item.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(RelayTheme.softFill)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        case .assistant:
            if item.isCommentary {
                CommentaryRow(item: item)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if let title = item.title {
                        Text(title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    MarkdownContentView(source: item.text)
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
    @State private var expanded: Bool

    init(items: [TranscriptItem], metadata: TurnMetadata) {
        self.items = items
        self.metadata = metadata
        _expanded = State(initialValue: metadata.isRunning)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                guard !executionItems.isEmpty else { return }
                withAnimation(.easeOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    if metadata.isRunning {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(.secondary)
                            .padding(.top, 1)
                    } else {
                        Image(systemName: statusIcon)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(statusColor)
                            .padding(.top, 1)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        if metadata.isRunning, let latestProgressText {
                            Text(latestProgressText)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                                .id(latestProgressText)
                                .transition(.opacity)
                        } else {
                            TimelineView(.periodic(from: .now, by: 1)) { _ in
                                Text(activityLabel)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if metadata.isRunning, elapsedMilliseconds > 0 {
                            TimelineView(.periodic(from: .now, by: 1)) { _ in
                                Text(formatDuration(milliseconds: elapsedMilliseconds))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }

                    if !executionItems.isEmpty {
                        Text("· \(executionItems.count)")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 1)
                    }

                    Spacer()
                    if !executionItems.isEmpty {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                            .padding(.top, 3)
                    }
                }
                .contentShape(Rectangle())
                .padding(.vertical, 5)
            }
            .buttonStyle(.plain)

            if expanded, !executionItems.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(executionItems) { item in
                        HStack(alignment: .top, spacing: 8) {
                            VStack(spacing: 0) {
                                Circle()
                                    .fill(stepColor(item))
                                    .frame(width: 5, height: 5)
                                    .padding(.top, 13)
                                Rectangle()
                                    .fill(RelayTheme.hairline)
                                    .frame(width: 1)
                            }
                            .frame(width: 8)

                            TranscriptRow(item: item)
                                .padding(.bottom, 1)
                        }
                    }
                }
                .padding(.leading, 2)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeOut(duration: 0.16), value: latestProgressText)
        .onChange(of: metadata.isRunning) { running in
            if !running {
                withAnimation(.easeOut(duration: 0.2)) { expanded = false }
            }
        }
    }

    private var progressItems: [TranscriptItem] {
        items.filter { $0.kind == .reasoning || $0.isCommentary }
    }

    private var executionItems: [TranscriptItem] {
        items.filter { $0.kind != .reasoning && !$0.isCommentary && $0.kind != .plan }
    }

    private var latestProgressText: String? {
        guard let item = progressItems.last else { return nil }
        let source = item.text.nonEmpty ?? item.detail?.nonEmpty
        let lines = source?
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        return lines.last?.nonEmpty
    }

    private var elapsedMilliseconds: Int {
        if let duration = metadata.durationMs { return duration }
        guard let startedAt = metadata.startedAt else { return 0 }
        let end = metadata.completedAt ?? Date()
        return max(0, Int(end.timeIntervalSince(startedAt) * 1000))
    }

    private var activityLabel: String {
        let duration = formatDuration(milliseconds: elapsedMilliseconds)
        if metadata.isRunning { return elapsedMilliseconds > 0 ? "正在处理 · \(duration)" : "正在处理" }
        if metadata.status == "failed" { return "处理失败 · \(duration)" }
        if metadata.status == "interrupted" { return "已停止 · \(duration)" }
        return elapsedMilliseconds > 0 ? "已处理 · \(duration)" : "处理过程"
    }

    private var statusIcon: String {
        metadata.status == "failed" ? "xmark.circle.fill" : metadata.status == "interrupted" ? "stop.circle.fill" : "checkmark.circle.fill"
    }

    private var statusColor: Color {
        metadata.status == "failed" ? .red : metadata.status == "interrupted" ? .secondary : RelayTheme.accent
    }

    private func stepColor(_ item: TranscriptItem) -> Color {
        let status = item.status?.lowercased() ?? ""
        if status.contains("fail") { return .red }
        if status.contains("progress") || status.contains("running") { return .orange }
        return Color.secondary.opacity(0.55)
    }
}

private struct CommentaryRow: View {
    let item: TranscriptItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("进展")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
            MarkdownContentView(source: item.text)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
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
                withAnimation(.easeOut(duration: 0.18)) { expanded.toggle() }
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
                                    .textSelection(.enabled)
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
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    @ViewBuilder
    private func detailView(_ detail: String) -> some View {
        if item.kind == .reasoning {
            MarkdownContentView(source: detail)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.leading, 11)
                .overlay(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.25)).frame(width: 2)
                }
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(12)
            }
            .frame(maxHeight: 280)
            .background(RelayTheme.codeFill)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
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
