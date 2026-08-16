import SwiftUI

struct MobileActivityPresentation: Identifiable {
    let id: String
    let feed: MobileActivityFeed
    let metadata: TurnMetadata
    let outputStartedAt: Date?
    let isLive: Bool
    let plan: [ExecutionPlanStep]
    let diffStatistics: DiffStatistics?
}

struct MobileLiveActivityConsole: View {
    let presentation: MobileActivityPresentation
    let compact: Bool
    let showTimeline: () -> Void
    @State private var manuallyCollapsed = false

    var body: some View {
        let feed = presentation.feed
        let fileChangeSummary = MobileFileChangeSummary.make(
            aggregatedStatistics: presentation.diffStatistics,
            fallback: feed.fileChangeSummary
        )
        let hasReasoning = feed.latestReasoningText?.nonEmpty != nil
        let hasProgress = !feed.progressItems.isEmpty
        let hasPlan = !presentation.plan.isEmpty
        let hasCommands = !feed.commandItems.isEmpty
        let hasFileChanges = !fileChangeSummary.items.isEmpty

        VStack(spacing: 0) {
            HStack(spacing: 9) {
                ProgressView()
                    .controlSize(.small)
                    .tint(RelayTheme.accent)
                    .frame(width: 18, height: 18)

                Text(presentation.outputStartedAt == nil ? "正在思考" : "正在处理")
                    .font(.system(size: 12, weight: .semibold))

                Spacer(minLength: 8)
                if let outputStartedAt = presentation.outputStartedAt {
                    LiveElapsedText(startedAt: outputStartedAt)
                }

                Button {
                    RelayHaptics.selection()
                    manuallyCollapsed.toggle()
                } label: {
                    Image(systemName: isCollapsed ? "chevron.down" : "chevron.up")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(compact)
                .accessibilityLabel(isCollapsed ? "展开当前任务" : "折叠当前任务")

                Button {
                    RelayHaptics.impact()
                    showTimeline()
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("查看完整任务活动")
            }
            .padding(.horizontal, 13)
            .frame(height: 38)

            if !isCollapsed && (hasReasoning || hasProgress || hasPlan || hasCommands || hasFileChanges) {
                Divider().opacity(0.45)
            }

            if !isCollapsed, let reasoning = feed.latestReasoningText?.nonEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(RelayTheme.accent)
                        .frame(width: 16, height: 16)
                    ShimmeringStatusText(cleanActivityText(reasoning), font: .system(size: 11.5))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
            }

            if !isCollapsed && hasPlan {
                MobilePlanWindow(steps: presentation.plan)
                    .padding(.horizontal, 7)
                    .padding(.top, hasReasoning ? 0 : 8)
            }

            if !isCollapsed && hasProgress {
                MobileProgressWindow(feed: feed)
                    .padding(.horizontal, 7)
                    .padding(.top, hasPlan || hasReasoning ? 7 : 8)
            }

            if !isCollapsed && hasCommands {
                MobileCommandWindow(feed: feed)
                    .padding(.horizontal, 7)
                    .padding(.top, 7)
            }

            if !isCollapsed && hasFileChanges {
                MobileFileChangeWindow(summary: fileChangeSummary)
                    .padding(.horizontal, 7)
                    .padding(.top, 7)
            }

            if !isCollapsed && (hasReasoning || hasProgress || hasPlan || hasCommands || hasFileChanges) {
                Color.clear.frame(height: 8)
            }
        }
        .background(RelayTheme.elevated)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(RelayTheme.hairline, lineWidth: 1)
        }
        .transaction { $0.animation = nil }
    }

    private var isCollapsed: Bool { manuallyCollapsed || compact }

}

private struct MobilePlanWindow: View {
    let steps: [ExecutionPlanStep]
    @State private var expanded = false

    private var summary: MobilePlanSummary? { MobilePlanSummary.make(steps: steps) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { toggleExpandedWithoutAnimation() } label: {
                HStack(spacing: 7) {
                    Circle()
                        .stroke(RelayTheme.accent.opacity(0.65), lineWidth: 1.4)
                        .frame(width: 11, height: 11)
                    if let summary {
                        Text("第 \(summary.currentStep)/\(summary.totalSteps) 步")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                        if let currentText = summary.currentText {
                            Text(currentText)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Spacer(minLength: 4)
                        }
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .padding(.horizontal, 10)
                .frame(height: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? "折叠任务步骤" : "展开任务步骤")

            if expanded {
                Divider().opacity(0.35)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(steps) { step in
                        HStack(alignment: .top, spacing: 8) {
                            planStatus(step)
                                .frame(width: 13, height: 15)
                            Text(step.text)
                                .font(.system(size: 10.5))
                                .foregroundStyle(step.isCompleted ? Color.secondary : Color.primary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
            }
        }
        .background(RelayTheme.softFill)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .transaction { $0.animation = nil }
    }

    @ViewBuilder
    private func planStatus(_ step: ExecutionPlanStep) -> some View {
        if step.isCompleted {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(RelayTheme.accent)
        } else if step.isRunning {
            ProgressView().controlSize(.mini)
        } else {
            Circle()
                .stroke(Color.secondary.opacity(0.55), lineWidth: 1.2)
                .frame(width: 10, height: 10)
        }
    }

    private func toggleExpandedWithoutAnimation() {
        RelayHaptics.selection()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { expanded.toggle() }
    }
}

private struct MobileProgressWindow: View {
    let feed: MobileActivityFeed
    @State private var followsLatest = true
    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0

    private let coordinateSpace = "relay-mobile-progress-window"

    private var canScroll: Bool {
        ActivityWindowScrollMetrics.isScrollable(
            contentHeight: contentHeight,
            viewportHeight: viewportHeight
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            windowHeader(title: "进展", count: feed.progressItems.count)

            ScrollViewReader { proxy in
                ZStack(alignment: .bottomTrailing) {
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(feed.progressItems) { item in
                                InlineMarkdownText(
                                    cleanActivityText(item.text),
                                    size: 11.5,
                                    lineSpacing: 2
                                )
                                .foregroundStyle(.secondary)
                                .id(item.id)
                            }

                            Color.clear
                                .frame(height: 1)
                                .id("mobile-progress-bottom")
                                .background {
                                    GeometryReader { geometry in
                                        Color.clear.preference(
                                            key: ActivityWindowBottomPreferenceKey.self,
                                            value: geometry.frame(in: .named(coordinateSpace)).maxY
                                        )
                                    }
                                }
                        }
                        .font(.system(size: 11.5))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background {
                            GeometryReader { geometry in
                                Color.clear.preference(
                                    key: ActivityWindowContentHeightPreferenceKey.self,
                                    value: geometry.size.height
                                )
                            }
                        }
                    }
                    .coordinateSpace(name: coordinateSpace)
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(
                                key: ActivityWindowViewportHeightPreferenceKey.self,
                                value: geometry.size.height
                            )
                        }
                    }
                    .onPreferenceChange(ActivityWindowContentHeightPreferenceKey.self) { height in
                        if abs(contentHeight - height) > 0.5 { contentHeight = height }
                    }
                    .onPreferenceChange(ActivityWindowViewportHeightPreferenceKey.self) { height in
                        if abs(viewportHeight - height) > 0.5 { viewportHeight = height }
                    }
                    .onPreferenceChange(ActivityWindowBottomPreferenceKey.self) { bottomY in
                        let tolerance: CGFloat = followsLatest ? 24 : 10
                        guard let atBottom = ActivityWindowScrollMetrics.isAtBottom(
                            bottomY: bottomY,
                            viewportHeight: viewportHeight,
                            tolerance: tolerance
                        ) else { return }
                        followsLatest = atBottom
                    }
                    .onAppear { scrollToLatest(proxy, animated: false) }
                    .onChange(of: feed.progressRevision) { _ in
                        guard followsLatest else { return }
                        scrollToLatest(proxy, animated: false)
                    }

                    if canScroll, !followsLatest {
                        latestButton {
                            followsLatest = true
                            scrollToLatest(proxy, animated: true)
                        }
                    }
                }
            }
            .frame(height: 104)
        }
        .background(RelayTheme.softFill)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy, animated: Bool) {
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo("mobile-progress-bottom", anchor: .bottom)
                }
            } else {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    proxy.scrollTo("mobile-progress-bottom", anchor: .bottom)
                }
            }
        }
    }
}

private struct MobileCommandWindow: View {
    let feed: MobileActivityFeed
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { toggleExpandedWithoutAnimation() } label: {
                HStack(spacing: 7) {
                    Image(systemName: "terminal")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                    Text("正在执行指令")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                    if let command = feed.currentCommand {
                        Text(commandTitle(command))
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Spacer(minLength: 4)
                    }
                    HStack(spacing: 4) {
                        Text("成功 \(feed.successfulCommandCount)")
                            .foregroundStyle(Color.green)
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text("失败 \(feed.failedCommandCount)")
                            .foregroundStyle(feed.failedCommandCount > 0 ? Color.red : Color.secondary.opacity(0.72))
                    }
                        .font(.system(size: 9.5, weight: .medium))
                        .fixedSize(horizontal: true, vertical: false)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .padding(.horizontal, 10)
                .frame(height: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? "折叠执行指令" : "展开执行指令")

            if expanded {
                Divider().opacity(0.35)
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(feed.commandItems) { command in
                            HStack(spacing: 7) {
                                commandStatus(command)
                                Text(commandTitle(command))
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(command.isFailedStatus ? Color.red : Color.primary)
                                    .lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                .frame(height: min(96, CGFloat(feed.commandItems.count) * 31 + 10))
            }
        }
        .background(RelayTheme.codeFill)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .transaction { $0.animation = nil }
    }

    @ViewBuilder
    private func commandStatus(_ item: TranscriptItem) -> some View {
        if item.isRunningStatus {
            ProgressView().controlSize(.mini).frame(width: 12, height: 12)
        } else {
            Image(systemName: item.isFailedStatus ? "xmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(item.isFailedStatus ? Color.red : RelayTheme.accent)
                .frame(width: 12, height: 12)
        }
    }

    private func toggleExpandedWithoutAnimation() {
        RelayHaptics.selection()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { expanded.toggle() }
    }
}

private struct MobileFileChangeWindow: View {
    let summary: MobileFileChangeSummary
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { toggleExpandedWithoutAnimation() } label: {
                HStack(spacing: 7) {
                    Image(systemName: "doc.badge.plus")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                    Text("文件修改 \(summary.items.count)")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    if summary.hasLineCounts {
                        diffCounts(added: summary.added, removed: summary.removed)
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .padding(.horizontal, 10)
                .frame(height: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? "折叠文件修改" : "展开文件修改")

            if expanded {
                Divider().opacity(0.35)
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(summary.items) { item in
                            HStack(spacing: 7) {
                                Image(systemName: "doc.text")
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 12)
                                Text(item.path.lastPathComponentForDisplay)
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if let added = item.added, let removed = item.removed {
                                    diffCounts(added: added, removed: removed)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                .frame(height: min(104, CGFloat(summary.items.count) * 27 + 10))
            }
        }
        .background(RelayTheme.softFill)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .transaction { $0.animation = nil }
    }

    private func diffCounts(added: Int, removed: Int) -> some View {
        HStack(spacing: 5) {
            Text("+\(added)").foregroundStyle(Color.green)
            Text("-\(removed)").foregroundStyle(Color.red)
        }
        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
        .fixedSize(horizontal: true, vertical: false)
    }

    private func toggleExpandedWithoutAnimation() {
        RelayHaptics.selection()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { expanded.toggle() }
    }
}

private struct ActivityWindowContentHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct ActivityWindowViewportHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct ActivityWindowBottomPreferenceKey: PreferenceKey {
    static var defaultValue = CGFloat.greatestFiniteMagnitude
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = min(value, nextValue()) }
}

private func windowHeader(title: String, count: Int) -> some View {
    HStack(spacing: 5) {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
        if count > 0 {
            Text("\(count)")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
        }
        Spacer()
    }
    .padding(.horizontal, 10)
    .frame(height: 22)
}

private func latestButton(action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Image(systemName: "arrow.down")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 25, height: 25)
            .background(.ultraThinMaterial)
            .clipShape(Circle())
    }
    .buttonStyle(.plain)
    .padding(5)
}

private func commandTitle(_ item: TranscriptItem) -> String {
    let source = item.text.nonEmpty ?? item.title?.nonEmpty ?? "指令"
    return source
        .split(whereSeparator: \.isNewline)
        .first
        .map(String.init) ?? source
}

private struct LiveElapsedText: View {
    let startedAt: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(MobileActivityElapsedFormatter.text(
                seconds: startedAt.map { max(0, Int(context.date.timeIntervalSince($0))) }
            ))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 44, alignment: .trailing)
        }
        .accessibilityLabel("处理时间")
    }

}

private func cleanActivityText(_ source: String) -> String {
    source
        .replacingOccurrences(of: #"</?thinking\b[^>]*>"#, with: "", options: [.regularExpression, .caseInsensitive])
        .replacingOccurrences(of: "**", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

struct MobileCompletedActivityRow: View {
    let id: String
    let feed: MobileActivityFeed
    let metadata: TurnMetadata
    let action: (MobileActivityPresentation) -> Void

    init(
        id: String,
        revision: Int,
        items: [TranscriptItem],
        metadata: TurnMetadata,
        action: @escaping (MobileActivityPresentation) -> Void
    ) {
        self.id = id
        feed = CompletedActivityFeedCache.feed(id: id, revision: revision, items: items)
        self.metadata = metadata
        self.action = action
    }

    var body: some View {
        if !feed.entries.isEmpty || metadata.durationMs != nil {
            Button {
                action(MobileActivityPresentation(
                    id: id,
                    feed: feed,
                    metadata: metadata,
                    outputStartedAt: nil,
                    isLive: false,
                    plan: [],
                    diffStatistics: nil
                ))
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

private enum CompletedActivityFeedCache {
    private static let cache: NSCache<NSString, MobileActivityFeedBox> = {
        let cache = NSCache<NSString, MobileActivityFeedBox>()
        cache.countLimit = 96
        cache.totalCostLimit = 8_192
        return cache
    }()

    static func feed(id: String, revision: Int, items: [TranscriptItem]) -> MobileActivityFeed {
        let key = "\(id).\(revision)" as NSString
        if let cached = cache.object(forKey: key) { return cached.value }
        let value = MobileActivityFeed.make(items: items)
        cache.setObject(MobileActivityFeedBox(value), forKey: key, cost: max(1, items.count))
        return value
    }
}

private final class MobileActivityFeedBox: NSObject {
    let value: MobileActivityFeed
    init(_ value: MobileActivityFeed) { self.value = value }
}

struct MobileActivitySheet: View {
    let presentation: MobileActivityPresentation
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: RelayStore
    @State private var window: MobileActivityWindow

    init(presentation: MobileActivityPresentation) {
        self.presentation = presentation
        _window = State(initialValue: MobileActivityWindow(entries: presentation.feed.entries))
    }

    var body: some View {
        let current = resolvedPresentation
        let entries = current.feed.entries
        let visibleEntries = window.visibleEntries(in: entries)
        let hiddenEntryCount = window.hiddenEntryCount(in: entries)
        NavigationView {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if hiddenEntryCount > 0 {
                        Button {
                            window.showEarlier(in: entries)
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
        .onChange(of: entries.map(\.id)) { _ in
            window.synchronize(with: entries)
        }
    }

    private var resolvedPresentation: MobileActivityPresentation {
        let turnId = presentation.isLive ? (store.activeTurnId ?? presentation.id) : presentation.id
        let items = store.transcriptItems(turnId: turnId).filter(\.isActivity)
        guard !items.isEmpty || store.turnMetadata[turnId] != nil else { return presentation }
        var metadata = store.turnMetadata[turnId] ?? presentation.metadata
        if metadata.startedAt == nil {
            metadata.startedAt = store.selectedThreadId.flatMap { store.taskRunStates[$0]?.startedAt }
        }
        let isLive = store.isRunning && store.activeTurnId == turnId
        return MobileActivityPresentation(
            id: turnId,
            feed: MobileActivityFeed.make(items: items),
            metadata: metadata,
            outputStartedAt: isLive
                ? (store.selectedThreadId.flatMap { store.taskRunStates[$0]?.outputStartedAt }
                    ?? presentation.outputStartedAt
                    ?? items.firstVisibleTaskActivityAt(turnId: turnId))
                : presentation.outputStartedAt,
            isLive: isLive,
            plan: isLive ? store.activePlan : [],
            diffStatistics: isLive ? store.activeTurnDiffStatistics : nil
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
                Group {
                    if isLive {
                        ShimmeringStatusText(
                            text.replacingOccurrences(of: "**", with: ""),
                            font: .system(size: 12)
                        )
                    } else {
                        Text(text.replacingOccurrences(of: "**", with: ""))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
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

private struct ShimmeringStatusText: View {
    let text: String
    let font: Font
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ text: String, font: Font) {
        self.text = text
        self.font = font
    }

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(.secondary)
            .overlay {
                if !reduceMotion {
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                        GeometryReader { geometry in
                            let highlightWidth = max(44, geometry.size.width * 0.42)
                            let phase = shimmerPhase(at: context.date)
                            LinearGradient(
                                colors: [.clear, Color.primary.opacity(0.72), .clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: highlightWidth)
                            .offset(x: -highlightWidth + phase * (geometry.size.width + highlightWidth * 2))
                            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
                            .mask(alignment: .leading) {
                                Text(text)
                                    .font(font)
                                    .frame(width: geometry.size.width, alignment: .leading)
                            }
                        }
                    }
                    .allowsHitTesting(false)
                }
            }
            .clipped()
    }

    private func shimmerPhase(at date: Date) -> CGFloat {
        CGFloat(date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.65) / 1.65)
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
