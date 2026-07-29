import SwiftUI

struct MobileActivityPresentation: Identifiable {
    let id: String
    let feed: MobileActivityFeed
    let metadata: TurnMetadata
    let isLive: Bool
    let plan: [ExecutionPlanStep]
}

struct MobileActivityBar: View {
    let presentation: MobileActivityPresentation
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                    .tint(RelayTheme.accent)
                    .frame(width: 20, height: 20)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text("正在处理 \(elapsedText(at: context.date))")
                        }
                        .font(.system(size: 12, weight: .semibold))

                        if !presentation.plan.isEmpty {
                            Text(planProgress)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Text(latestActivityText)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 13)
            .frame(height: 54)
            .background(RelayTheme.elevated)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(RelayTheme.hairline, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("查看当前任务活动")
    }

    private var latestActivityText: String {
        if let activeStep = presentation.plan.first(where: { !$0.isCompleted }) {
            return activeStep.text
        }
        return presentation.feed.latestText ?? "Codex 正在开始任务"
    }

    private var planProgress: String {
        let completed = presentation.plan.filter(\.isCompleted).count
        return "\(completed)/\(presentation.plan.count)"
    }

    private func elapsedText(at date: Date) -> String {
        let startedAt = presentation.metadata.startedAt ?? date
        let seconds = max(0, Int(date.timeIntervalSince(startedAt)))
        if seconds < 60 { return "\(seconds) 秒" }
        return "\(seconds / 60) 分 \(seconds % 60) 秒"
    }
}

struct MobileCompletedActivityRow: View {
    let id: String
    let items: [TranscriptItem]
    let metadata: TurnMetadata
    @State private var presentation: MobileActivityPresentation?

    var body: some View {
        let feed = MobileActivityFeed.make(items: items)
        if !feed.entries.isEmpty || metadata.durationMs != nil {
            Button {
                presentation = MobileActivityPresentation(
                    id: id,
                    feed: feed,
                    metadata: metadata,
                    isLive: false,
                    plan: []
                )
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: statusIcon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(statusColor)
                        .frame(width: 18, height: 18)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(activityTitle)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(feed.completedSummary)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .sheet(item: $presentation) { presentation in
                MobileActivitySheet(presentation: presentation)
            }
        }
    }

    private var activityTitle: String {
        if let duration = metadata.durationMs, duration > 0 {
            return "已处理 \(formatDuration(milliseconds: duration))"
        }
        return metadata.errorMessage == nil ? "任务活动" : "任务未完成"
    }

    private var statusIcon: String {
        metadata.errorMessage == nil ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
    }

    private var statusColor: Color {
        metadata.errorMessage == nil ? RelayTheme.accent : .red
    }
}

struct MobileActivitySheet: View {
    let presentation: MobileActivityPresentation
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: RelayStore
    @State private var visibleEntryCount = 18

    var body: some View {
        let current = resolvedPresentation
        NavigationView {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if hiddenEntryCount > 0 {
                        Button {
                            visibleEntryCount += 18
                        } label: {
                            Label("显示更早的 \(hiddenEntryCount) 项", systemImage: "clock.arrow.circlepath")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .frame(height: 42)
                        }
                        .buttonStyle(.plain)
                    }

                    ForEach(visibleEntries) { entry in
                        MobileActivityEntryRow(entry: entry, isLive: current.isLive)
                            .padding(.vertical, 9)
                        Divider().opacity(0.35)
                    }

                    if current.feed.entries.isEmpty {
                        Text("Codex 正在准备任务活动")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 42)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(RelayTheme.canvas)
            .navigationTitle(current.isLive ? "当前任务" : "任务活动")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var visibleEntries: ArraySlice<MobileActivityEntry> {
        resolvedPresentation.feed.entries.suffix(visibleEntryCount)
    }

    private var hiddenEntryCount: Int {
        max(0, resolvedPresentation.feed.entries.count - visibleEntryCount)
    }

    private var resolvedPresentation: MobileActivityPresentation {
        guard presentation.isLive,
              store.isRunning,
              let threadId = store.selectedThreadId else { return presentation }
        let turnId = store.activeTurnId
        let items = turnId.map { activeTurnId in
            store.messages.filter { $0.turnId == activeTurnId && $0.isActivity }
        } ?? []
        var metadata = turnId.flatMap { store.turnMetadata[$0] } ?? presentation.metadata
        if metadata.startedAt == nil {
            metadata.startedAt = store.taskRunStates[threadId]?.startedAt
        }
        return MobileActivityPresentation(
            id: turnId ?? presentation.id,
            feed: MobileActivityFeed.make(items: items),
            metadata: metadata,
            isLive: true,
            plan: store.activePlan
        )
    }
}

private struct MobileActivityEntryRow: View {
    let entry: MobileActivityEntry
    let isLive: Bool
    @State private var toolsExpanded = false

    var body: some View {
        switch entry {
        case .progress(_, let text):
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(RelayTheme.accent)
                    .frame(width: 18, height: 18)
                MarkdownContentView(source: text, baseFontSize: 13, blockSpacing: 5, lineSpacing: 2)
            }
        case .reasoning(_, let text):
            HStack(alignment: .top, spacing: 9) {
                if isLive {
                    ProgressView().controlSize(.mini).frame(width: 18, height: 18)
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .frame(width: 18, height: 18)
                }
                Text(text.replacingOccurrences(of: "**", with: ""))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .tools(_, let items):
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    toolsExpanded.toggle()
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "terminal")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        Text(MobileActivityFeed.toolSummary(items))
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(toolsExpanded ? 180 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if toolsExpanded {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(items) { item in
                            MobileToolDetailRow(item: item)
                        }
                    }
                    .padding(.leading, 27)
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.16), value: toolsExpanded)
        }
    }
}

private struct MobileToolDetailRow: View {
    let item: TranscriptItem
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button {
                guard hasDetails else { return }
                expanded.toggle()
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: item.kind == .fileChange ? "doc.badge.plus" : "wrench.and.screwdriver")
                        .font(.system(size: 10))
                        .foregroundStyle(item.isFailedStatus ? Color.red : Color.secondary)
                    Text(item.title?.nonEmpty ?? item.text.nonEmpty ?? "工具")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(item.isFailedStatus ? Color.red : Color.primary)
                        .lineLimit(1)
                    Spacer(minLength: 5)
                    if hasDetails {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    if let text = item.text.nonEmpty {
                        Text(text)
                            .font(.system(size: 10, design: item.kind == .command ? .monospaced : .default))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let detail = item.detail?.nonEmpty {
                        let preview = TechnicalTextPreview.make(source: detail)
                        ScrollView(.horizontal, showsIndicators: true) {
                            Text(preview.text)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .padding(9)
                        }
                        .frame(height: min(180, CGFloat(preview.lineCount) * 14 + 18))
                        .background(RelayTheme.codeFill)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            }
        }
    }

    private var hasDetails: Bool {
        item.text.nonEmpty != nil || item.detail?.nonEmpty != nil || item.errorMessage?.nonEmpty != nil
    }
}
