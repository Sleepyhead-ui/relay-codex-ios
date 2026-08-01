import SwiftUI
import UIKit
import ImageIO

struct TurnGroupView: View, Equatable {
    let group: TranscriptGroup
    let isLive: Bool
    let store: RelayStore
    let onOpenActivity: (MobileActivityPresentation) -> Void

    static func == (lhs: TurnGroupView, rhs: TurnGroupView) -> Bool {
        lhs.group.id == rhs.group.id
            && lhs.group.revision == rhs.group.revision
            && lhs.group.metadata == rhs.group.metadata
            && lhs.isLive == rhs.isLive
    }

    var body: some View {
        let timeline = timelineSegments
        let lastAnswerId = group.answerItems.last?.id

        VStack(alignment: .leading, spacing: 14) {
            ForEach(timeline) { segment in
                switch segment {
                case .user(let item, let isFollowUp):
                    TranscriptRow(
                        item: item,
                        isFollowUp: isFollowUp,
                        timestamp: item.createdAt ?? group.metadata.startedAt,
                        store: store
                    )
                case .activity:
                    EmptyView()
                case .item(let item):
                    TranscriptRow(
                        item: item,
                        timestamp: item.isFinalAnswer ? (group.metadata.completedAt ?? group.metadata.startedAt) : nil,
                        forkTurnId: !isLive && item.id == lastAnswerId ? group.turnId : nil,
                        store: store
                    )
                }
            }

            if !isLive, !group.activityItems.isEmpty {
                MobileCompletedActivityRow(
                    id: group.turnId ?? group.id,
                    items: group.activityItems,
                    metadata: group.metadata,
                    action: onOpenActivity
                )
            }

            if group.answerItems.isEmpty, let error = group.metadata.errorMessage, !error.isEmpty {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var timelineSegments: [TurnTimelineSegment] {
        var result: [TurnTimelineSegment] = []
        var pendingActivity: [TranscriptItem] = []
        var hasSeenUserMessage = false

        func flushActivity() {
            guard let first = pendingActivity.first else { return }
            result.append(.activity(id: "activity.\(first.id)", items: pendingActivity))
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
            result.append(.activity(id: "activity.pending.\(group.id)", items: []))
        }
        return result
    }
}

private enum TurnTimelineSegment: Identifiable {
    case user(TranscriptItem, isFollowUp: Bool)
    case activity(id: String, items: [TranscriptItem])
    case item(TranscriptItem)

    var id: String {
        switch self {
        case .user(let item, _): return "user.\(item.id)"
        case .activity(let id, _): return id
        case .item(let item): return "item.\(item.id)"
        }
    }

    var isActivity: Bool {
        if case .activity = self { return true }
        return false
    }
}

struct TranscriptRow: View {
    let item: TranscriptItem
    let isFollowUp: Bool
    let timestamp: Date?
    let forkTurnId: String?
    // Intentionally unobserved: the item value owns row updates. Observing the
    // global store here would invalidate every historical row on each token.
    let store: RelayStore

    init(
        item: TranscriptItem,
        isFollowUp: Bool = false,
        timestamp: Date? = nil,
        forkTurnId: String? = nil,
        store: RelayStore
    ) {
        self.item = item
        self.isFollowUp = isFollowUp
        self.timestamp = timestamp
        self.forkTurnId = forkTurnId
        self.store = store
    }

    var body: some View {
        switch item.role {
        case .user:
            HStack {
                Spacer(minLength: 34)
                VStack(alignment: .trailing, spacing: 4) {
                    if isFollowUp {
                        Text("引导")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .padding(.trailing, 3)
                    }
                    if !item.imagePaths.isEmpty {
                        InlineImageGrid(paths: item.imagePaths, store: store)
                    }
                    if !item.text.isEmpty {
                        UserMessageBubble(text: item.text)
                    }
                    if let deliveryState = item.deliveryState {
                        deliveryStatus(deliveryState)
                    }
                    if item.deliveryState == nil, !item.text.isEmpty {
                        MessageActionsRow(text: item.text, timestamp: timestamp, forkTurnId: nil, store: store)
                    }
                }
            }
            .padding(.trailing, -6)
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
                        DownloadFileLinks(paths: item.downloadablePaths, store: store)
                    }
                    if !item.text.isEmpty {
                        MessageActionsRow(text: item.text, timestamp: timestamp, forkTurnId: forkTurnId, store: store)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .tool:
            ToolEventRow(item: item, store: store)
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
                if store.canEditFailedTurnStart(item.id) {
                    Text("任务未启动")
                    Button { store.restoreMessageToComposer(item.id) } label: {
                        Label("编辑后重发", systemImage: "pencil")
                    }
                    .fontWeight(.semibold)
                } else {
                    Text("引导未发送")
                }
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

struct QueuedFollowUpRow: View {
    let item: QueuedFollowUp
    @EnvironmentObject private var store: RelayStore
    @State private var copied = false

    var body: some View {
        HStack {
            Spacer(minLength: 34)
            VStack(alignment: .trailing, spacing: 5) {
                if !item.imagePaths.isEmpty {
                    InlineImageGrid(paths: item.imagePaths, store: store)
                }
                if !item.text.isEmpty {
                    UserMessageBubble(text: item.text)
                }
                if !item.nonImageAttachmentNames.isEmpty {
                    HStack(spacing: 5) {
                        Image(systemName: "paperclip")
                            .font(.system(size: 10, weight: .semibold))
                        Text(item.nonImageAttachmentNames.joined(separator: "、"))
                            .lineLimit(1)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .frame(height: 26)
                    .background(RelayTheme.elevated)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }

                HStack(spacing: 9) {
                    Label("等待处理", systemImage: "clock")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)

                    Text(item.createdAt.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)

                    Button {
                        UIPasteboard.general.string = item.displayText
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(copied ? "已复制" : "复制内容")

                    Button { store.beginEditingQueuedFollowUp(item) } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 28, height: 28)
                            .background(RelayTheme.elevated)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("编辑等待处理的消息")

                    Menu {
                        Button { store.beginEditingQueuedFollowUp(item) } label: {
                            Label("编辑消息", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            store.removeQueuedFollowUp(item.id)
                        } label: {
                            Label("删除消息", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("更多消息操作")
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(.trailing, -6)
    }
}

private struct MessageActionsRow: View {
    let text: String
    let timestamp: Date?
    let forkTurnId: String?
    let store: RelayStore
    @State private var copied = false
    @State private var isForking = false

    var body: some View {
        HStack(spacing: 13) {
            Button {
                UIPasteboard.general.string = text
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(copied ? "已复制" : "复制内容")

            if let forkTurnId {
                Button {
                    Task {
                        isForking = true
                        await store.forkThread(through: forkTurnId)
                        isForking = false
                    }
                } label: {
                    Group {
                        if isForking {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 13, weight: .medium))
                        }
                    }
                    .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .disabled(isForking)
                .accessibilityLabel("在新任务中继续")
            }

            if let timestamp {
                Text(timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .foregroundStyle(.secondary)
        .frame(height: 24)
    }
}

private struct UserMessageBubble: View {
    let text: String

    var body: some View {
        Group {
            if canAttemptSingleLineLayout {
                ViewThatFits(in: .horizontal) {
                    singleLineBubble
                    multiLineBubble
                }
            } else {
                multiLineBubble
            }
        }
        .frame(maxWidth: 320, alignment: .trailing)
    }

    private var singleLineBubble: some View {
        InlineMarkdownText(
            text,
            size: 16,
            lineSpacing: 4,
            expandsHorizontally: false
        )
        .lineLimit(1)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(RelayTheme.softFill)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var multiLineBubble: some View {
        MarkdownContentView(source: text)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: 320, alignment: .leading)
            .background(RelayTheme.softFill)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var canAttemptSingleLineLayout: Bool {
        guard !text.contains(where: \.isNewline) else { return false }
        let blocks = MarkdownParser.parse(text)
        guard blocks.count == 1, case .paragraph = blocks[0] else { return false }
        return true
    }
}

private struct InlineImageGrid: View {
    let paths: [String]
    let store: RelayStore

    var body: some View {
        Group {
            if paths.count == 1, let path = paths.first {
                InlineMessageImage(path: path, width: 200, height: 150, store: store)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 6) {
                        ForEach(paths, id: \.self) { path in
                            InlineMessageImage(path: path, width: 112, height: 84, store: store)
                        }
                    }
                }
                .frame(width: galleryWidth, height: 84)
                .clipped()
            }
        }
        .transaction { $0.animation = nil }
    }

    private var galleryWidth: CGFloat {
        min(278, max(180, UIScreen.main.bounds.width - 112))
    }
}

private struct InlineMessageImage: View {
    let path: String
    let width: CGFloat
    let height: CGFloat
    let store: RelayStore
    @State private var image: UIImage?
    @State private var isLoading = false

    var body: some View {
        Button {
            Task { await store.openImagePreview(path: path) }
        } label: {
            ZStack {
                RelayTheme.softFill
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else if isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .task(id: path) { await loadImage() }
    }

    private func loadImage() async {
        isLoading = true
        if store.imagePreviewURLs[path] == nil { await store.loadImagePreview(path: path) }
        if let url = store.imagePreviewURLs[path] {
            image = await MessageImageDecoder.image(at: url, maxPixelSize: max(width, height) * 3)
        }
        isLoading = false
    }
}

enum MessageImageDecoder {
    private static let cache = NSCache<NSString, UIImage>()

    static func image(at url: URL, maxPixelSize: CGFloat) async -> UIImage? {
        let key = "\(url.path)#\(Int(maxPixelSize))" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        return await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(1, Int(maxPixelSize))
                  ] as CFDictionary) else { return nil }
            let decoded = UIImage(cgImage: cgImage)
            cache.setObject(decoded, forKey: key)
            return decoded
        }.value
    }
}

private struct DownloadFileLinks: View {
    let paths: [String]
    let store: RelayStore
    @State private var activePath: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(paths, id: \.self) { path in
                Button {
                    Task {
                        activePath = path
                        await store.downloadFile(path: path)
                        activePath = nil
                    }
                } label: {
                    HStack(spacing: 6) {
                        if activePath == path { ProgressView().controlSize(.mini) }
                        else { Image(systemName: "arrow.down.circle") }
                        Text("下载 \(path.lastPathComponentForDisplay)").lineLimit(1)
                    }
                    .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .disabled(activePath != nil)
            }
        }
    }
}

private struct DisclosureHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct StableDisclosureContent<Content: View>: View {
    let expanded: Bool
    let duration: Double
    private let content: () -> Content
    @State private var measuredHeight: CGFloat = 0
    @State private var mounted: Bool
    @State private var revealed: Bool
    @State private var transitionGeneration = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(expanded: Bool, duration: Double = 0.16, @ViewBuilder content: @escaping () -> Content) {
        self.expanded = expanded
        self.duration = duration
        self.content = content
        _mounted = State(initialValue: expanded)
        _revealed = State(initialValue: expanded)
    }

    var body: some View {
        Group {
            if mounted {
                content()
                    .fixedSize(horizontal: false, vertical: true)
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(key: DisclosureHeightPreferenceKey.self, value: proxy.size.height)
                        }
                    }
                    .frame(height: revealed ? measuredHeight : 0, alignment: .top)
                    .clipped()
                    .opacity(revealed ? 1 : 0)
                    .allowsHitTesting(revealed)
                    .accessibilityHidden(!revealed)
                    .animation(reduceMotion ? nil : .easeOut(duration: duration), value: revealed)
            }
        }
        .onChange(of: expanded) { shouldExpand in
            transitionGeneration += 1
            let generation = transitionGeneration
            if shouldExpand {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { mounted = true }
            } else {
                revealed = false
                DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0 : duration + 0.03)) {
                    guard generation == transitionGeneration, !revealed else { return }
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        mounted = false
                        measuredHeight = 0
                    }
                }
            }
        }
        .onPreferenceChange(DisclosureHeightPreferenceKey.self) { height in
            guard mounted, height > 0, abs(height - measuredHeight) > 0.5 else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { measuredHeight = height }
            if expanded, !revealed {
                let generation = transitionGeneration
                DispatchQueue.main.async {
                    guard generation == transitionGeneration, expanded, mounted else { return }
                    revealed = true
                }
            }
        }
    }
}

private struct CompactTechnicalDetail: View {
    let detail: String

    var body: some View {
        let preview = TechnicalTextPreview.make(source: detail)
        ScrollView(.horizontal, showsIndicators: true) {
            Text(preview.text)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(9)
        }
        .frame(height: CGFloat(preview.lineCount) * 14 + 18)
        .background(RelayTheme.codeFill)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct ToolEventRow: View {
    let item: TranscriptItem
    let store: RelayStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false
    @State private var downloadingPath: String?

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
                            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: expanded)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 4)
                    }
                }
                .contentShape(Rectangle())
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)

            if item.kind == .image, let path = item.downloadablePaths.first {
                InlineMessageImage(path: path, width: 200, height: 150, store: store)
                    .padding(.leading, 29)
                    .padding(.bottom, 7)
            }

            if !item.downloadablePaths.isEmpty, expanded || item.kind == .image {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(item.downloadablePaths, id: \.self) { path in
                        Button {
                            Task {
                                downloadingPath = path
                                await store.downloadFile(path: path)
                                downloadingPath = nil
                            }
                        } label: {
                            HStack(spacing: 6) {
                                if downloadingPath == path {
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
                        .disabled(downloadingPath != nil)
                    }
                }
                .padding(.leading, 29)
                .padding(.bottom, 8)
            }

            if let detail = item.detail, !detail.isEmpty {
                StableDisclosureContent(expanded: expanded) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("技术详情")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                        detailView(detail)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, item.kind == .fileChange ? 0 : 29)
                    .padding(.bottom, 10)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
