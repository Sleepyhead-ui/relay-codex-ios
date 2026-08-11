import SwiftUI

struct MobileActivityPresentation: Identifiable {
    let id: String
    let feed: MobileActivityFeed
    let metadata: TurnMetadata
    let isLive: Bool
    let plan: [ExecutionPlanStep]
}

struct MobileLiveActivityConsole: View {
    let presentation: MobileActivityPresentation
    let compact: Bool
    let showTimeline: () -> Void
    @State private var manuallyCollapsed = false

    var body: some View {
        let hasThinking = presentation.feed.latestReasoningText?.nonEmpty != nil
        let hasProgress = !presentation.feed.progressItems.isEmpty
        let hasTools = !presentation.feed.toolItems.isEmpty

        VStack(spacing: 0) {
            HStack(spacing: 9) {
                ProgressView()
                    .controlSize(.small)
                    .tint(RelayTheme.accent)
                    .frame(width: 18, height: 18)

                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("正在处理 \(elapsedText(at: context.date))")
                }
                .font(.system(size: 12, weight: .semibold))

                Spacer(minLength: 8)

                if !compact {
                    Button {
                        manuallyCollapsed.toggle()
                    } label: {
                        Image(systemName: manuallyCollapsed ? "chevron.down" : "chevron.up")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(manuallyCollapsed ? "展开当前任务" : "折叠当前任务")
                }

                Button(action: showTimeline) {
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

            if !manuallyCollapsed && (hasThinking || (!compact && (hasProgress || hasTools))) {
                Divider().opacity(0.45)
            }

            if !manuallyCollapsed, let summary = compactSummary {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(RelayTheme.accent)
                        .frame(width: 16, height: 16)

                    ShimmeringStatusText(summary, font: .system(size: 11.5))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 13)
                .frame(height: 34)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if hasProgress && !compact && !manuallyCollapsed {
                MobileProgressWindow(feed: presentation.feed, compact: compact)
                    .padding(.horizontal, 7)
                    .padding(.top, hasThinking ? 0 : 8)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if hasTools && !compact && !manuallyCollapsed {
                MobileToolWindow(feed: presentation.feed, compact: compact, showTimeline: showTimeline)
                    .padding(.horizontal, 7)
                    .padding(.top, 8)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if !manuallyCollapsed && (hasThinking || hasProgress || hasTools) {
                Color.clear.frame(height: 8)
            }
        }
        .background(RelayTheme.elevated)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(RelayTheme.hairline, lineWidth: 1)
        }
        .animation(.easeOut(duration: 0.18), value: hasThinking)
        .animation(.easeOut(duration: 0.18), value: hasProgress)
        .animation(.easeOut(duration: 0.18), value: hasTools)
    }

    private var compactSummary: String? {
        if let reasoning = presentation.feed.latestReasoningText?.nonEmpty {
            return cleanActivityText(reasoning)
        }
        guard compact else { return nil }
        if let progress = presentation.feed.progressItems.last?.text.nonEmpty {
            return cleanActivityText(progress)
        }
        if let tool = presentation.feed.toolItems.last {
            return tool.title?.nonEmpty ?? tool.text.nonEmpty
        }
        return nil
    }

    private func elapsedText(at date: Date) -> String {
        let startedAt = presentation.metadata.startedAt ?? date
        let seconds = max(0, Int(date.timeIntervalSince(startedAt)))
        if seconds < 60 { return "\(seconds) 秒" }
        return "\(seconds / 60) 分 \(seconds % 60) 秒"
    }
}

private struct MobileProgressWindow: View {
    let feed: MobileActivityFeed
    let compact: Bool
    @State private var followsLatest = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            windowHeader(title: "进展", count: feed.progressItems.count)

            ScrollViewReader { proxy in
                ZStack(alignment: .bottomTrailing) {
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(alignment: .leading, spacing: 7) {
                            if feed.progressItems.isEmpty {
                                Text("等待任务进展")
                                    .foregroundStyle(.tertiary)
                            } else {
                                ForEach(feed.progressItems) { item in
                                    InlineMarkdownText(
                                        cleanActivityText(item.text),
                                        size: 11.5,
                                        lineSpacing: 2
                                    )
                                        .foregroundStyle(.secondary)
                                        .id(item.id)
                                }
                            }

                            Color.clear
                                .frame(height: 1)
                                .id("mobile-progress-bottom")
                                .onAppear { followsLatest = true }
                        }
                        .font(.system(size: 11.5))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                    }
                    .scrollDisabled(feed.progressItems.count <= 4)
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 5)
                            .onChanged { _ in followsLatest = false }
                    )
                    .onAppear { scrollToLatest(proxy, animated: false) }
                    .onChange(of: feed.progressRevision) { _ in
                        guard followsLatest else { return }
                        scrollToLatest(proxy, animated: false)
                    }

                    if !followsLatest, !feed.progressItems.isEmpty {
                        latestButton {
                            followsLatest = true
                            scrollToLatest(proxy, animated: true)
                        }
                    }
                }
            }
            .frame(height: compact ? 72 : 104)
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

private struct MobileToolWindow: View {
    let feed: MobileActivityFeed
    let compact: Bool
    let showTimeline: () -> Void
    @State private var followsLatest = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            windowHeader(title: "操作", count: feed.toolItems.count)

            ScrollViewReader { proxy in
                ZStack(alignment: .bottomTrailing) {
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            if feed.toolItems.isEmpty {
                                Text("尚未执行工具或文件操作")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.tertiary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                ForEach(feed.toolItems) { item in
                                    Button(action: showTimeline) {
                                        HStack(spacing: 7) {
                                            toolStatus(item)
                                            Image(systemName: toolIcon(item))
                                                .font(.system(size: 9.5, weight: .medium))
                                                .foregroundStyle(.secondary)
                                                .frame(width: 13)
                                            Text(toolTitle(item))
                                                .font(.system(size: 11.5, weight: .medium))
                                                .foregroundStyle(item.isFailedStatus ? Color.red : Color.primary)
                                                .lineLimit(1)
                                            Spacer(minLength: 4)
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .id(item.id)
                                }
                            }

                            Color.clear
                                .frame(height: 1)
                                .id("mobile-tools-bottom")
                                .onAppear { followsLatest = true }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                    }
                    .scrollDisabled(feed.toolItems.count <= 4)
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 5)
                            .onChanged { _ in followsLatest = false }
                    )
                    .onAppear { scrollToLatest(proxy, animated: false) }
                    .onChange(of: feed.toolRevision) { _ in
                        guard followsLatest else { return }
                        scrollToLatest(proxy, animated: false)
                    }

                    if !followsLatest, !feed.toolItems.isEmpty {
                        latestButton {
                            followsLatest = true
                            scrollToLatest(proxy, animated: true)
                        }
                    }
                }
            }
            .frame(height: compact ? 58 : 86)
        }
        .background(RelayTheme.codeFill)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    @ViewBuilder
    private func toolStatus(_ item: TranscriptItem) -> some View {
        if item.isRunningStatus {
            ProgressView().controlSize(.mini).frame(width: 12, height: 12)
        } else {
            Image(systemName: item.isFailedStatus ? "xmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(item.isFailedStatus ? Color.red : RelayTheme.accent)
                .frame(width: 12, height: 12)
        }
    }

    private func toolIcon(_ item: TranscriptItem) -> String {
        switch item.kind {
        case .command: return "terminal"
        case .fileChange: return "doc.badge.plus"
        case .webSearch: return "globe"
        default: return "wrench.and.screwdriver"
        }
    }

    private func toolTitle(_ item: TranscriptItem) -> String {
        if item.kind == .command, let command = item.text.nonEmpty { return command }
        return item.title?.nonEmpty ?? item.text.nonEmpty ?? "工具操作"
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy, animated: Bool) {
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo("mobile-tools-bottom", anchor: .bottom)
                }
            } else {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    proxy.scrollTo("mobile-tools-bottom", anchor: .bottom)
                }
            }
        }
    }
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

private func cleanActivityText(_ source: String) -> String {
    source
        .replacingOccurrences(of: #"</?thinking\b[^>]*>"#, with: "", options: [.regularExpression, .caseInsensitive])
        .replacingOccurrences(of: "**", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

struct MobileCompletedActivityRow: View {
    let id: String
    let items: [TranscriptItem]
    let metadata: TurnMetadata
    let action: (MobileActivityPresentation) -> Void

    var body: some View {
        let feed = MobileActivityFeed.make(items: items)
        if !feed.entries.isEmpty || metadata.durationMs != nil {
            Button {
                action(MobileActivityPresentation(
                    id: id,
                    feed: feed,
                    metadata: metadata,
                    isLive: false,
                    plan: []
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
            isLive: isLive,
            plan: isLive ? store.activePlan : []
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

private struct ShimmeringStatusText: View {
    let text: String
    let font: Font
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

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
                    GeometryReader { geometry in
                        let highlightWidth = max(44, geometry.size.width * 0.42)
                        ZStack(alignment: .leading) {
                            LinearGradient(
                                colors: [.clear, Color.primary.opacity(0.72), .clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: highlightWidth)
                            .offset(x: phase * (geometry.size.width + highlightWidth))
                        }
                        .frame(
                            width: geometry.size.width,
                            height: geometry.size.height,
                            alignment: .leading
                        )
                        .mask(alignment: .leading) {
                            Text(text)
                                .font(font)
                                .frame(width: geometry.size.width, alignment: .leading)
                        }
                    }
                    .allowsHitTesting(false)
                }
            }
            .clipped()
            .onAppear { startAnimation() }
            .onChange(of: reduceMotion) { _ in startAnimation() }
    }

    private func startAnimation() {
        phase = -1
        guard !reduceMotion else { return }
        withAnimation(.linear(duration: 1.65).repeatForever(autoreverses: false)) {
            phase = 1
        }
    }
}
