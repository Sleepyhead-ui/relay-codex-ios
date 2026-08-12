import SwiftUI
import UIKit
import UniformTypeIdentifiers
import PhotosUI
import CoreTransferable

struct ComposerView: View {
    @EnvironmentObject private var store: RelayStore
    @ObservedObject private var draft: ComposerDraftState
    @FocusState private var focused: Bool
    @State private var showingPhotoPicker = false
    @State private var showingFileImporter = false
    @State private var isImportingAttachments = false
    @State private var selectedPhotos: [PhotosPickerItem] = []

    init(draft: ComposerDraftState) {
        self.draft = draft
    }

    var body: some View {
        VStack(spacing: 8) {
            if !focused, let percentage = store.currentTokenUsage?.contextPercentage, percentage >= 90 {
                ContextPressureNotice(
                    percentage: percentage,
                    isBusy: store.isRunning || store.isCompacting
                ) {
                    Task { await store.compactContext() }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if store.socket.state != .connected {
                if store.socket.state.isConnecting {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.mini)
                        Text("正在重新连接，输入内容会保留")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(Color.orange)
                } else {
                    Button { store.showingConnection = true } label: {
                        Label("连接 Windows", systemImage: "bolt.horizontal.circle")
                            .font(.system(size: 13, weight: .semibold))
                    }
                }
            }

            if !focused && (!store.activePlan.isEmpty || visibleGoal != nil) {
                TaskContextPanel(
                    steps: store.activePlan,
                    goal: visibleGoal
                )
            }

            VStack(spacing: 2) {
                if let editing = store.editingQueuedFollowUp {
                    queuedEditIndicator(editing)
                }

                if store.composerMode != .standard {
                    modeIndicator
                }

                if !store.attachments.isEmpty {
                    attachmentStrip
                }

                HStack(alignment: .bottom, spacing: 8) {
                    Menu {
                        Button {
                            focused = false
                            presentPhotoPicker()
                        } label: {
                            Label("照片或视频", systemImage: "photo.on.rectangle")
                        }
                        Button {
                            focused = false
                            presentFileImporter()
                        } label: {
                            Label("选择文件", systemImage: "folder")
                        }

                        Divider()

                        Button {
                            focused = false
                            store.composerMode = store.composerMode == .plan ? .standard : .plan
                        } label: {
                            Label(
                                store.composerMode == .plan ? "退出计划模式" : "计划模式",
                                systemImage: store.composerMode == .plan ? "checkmark" : "list.bullet.clipboard"
                            )
                        }
                        .disabled(store.isRunning || !store.planModeAvailable)

                        Button {
                            focused = false
                            if store.currentGoal != nil {
                                store.prepareCurrentGoalForEditing()
                            } else {
                                store.composerMode = store.composerMode == .goal ? .standard : .goal
                            }
                        } label: {
                            Label(
                                store.currentGoal == nil ? "目标模式" : "编辑当前目标",
                                systemImage: "scope"
                            )
                        }
                        .disabled(store.isRunning)
                    } label: {
                        Group {
                            if isImportingAttachments {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "plus")
                                    .font(.system(size: 17, weight: .medium))
                            }
                        }
                        .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain)
                    .disabled(isImportingAttachments || store.isSelectedThreadExternallyOwned)
                    .accessibilityLabel("添加内容或选择任务模式")

                    TextField("", text: $draft.text, prompt: composerPrompt, axis: .vertical)
                        .font(.system(size: 16))
                        .lineLimit(1...8)
                        .textFieldStyle(.plain)
                        .focused($focused)
                        .disabled(store.isSelectedThreadExternallyOwned)
                        .padding(.vertical, 9)
                        .frame(minHeight: 44, maxHeight: 164, alignment: .topLeading)
                        .fixedSize(horizontal: false, vertical: true)
                        .submitLabel(.send)
                        .onSubmit {
                            guard canSend else { return }
                            focused = false
                            Task { await store.sendPrompt() }
                        }

                    Button {
                        Task {
                            if showsStopControl {
                                await store.stopTurn()
                            } else {
                                focused = false
                                await store.sendPrompt()
                            }
                        }
                    } label: {
                        Group {
                            if store.isSendingPrompt {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(RelayTheme.canvas)
                            } else {
                                Image(systemName: showsStopControl ? "stop.fill" : "arrow.up")
                                    .font(.system(size: showsStopControl ? 11 : 15, weight: .bold))
                            }
                        }
                        .foregroundStyle(actionEnabled ? RelayTheme.canvas : Color.secondary)
                        .frame(width: 34, height: 34)
                        .background(actionEnabled || store.isSendingPrompt ? Color.primary : RelayTheme.softFill)
                        .clipShape(Circle())
                    }
                    .disabled(!actionEnabled || store.isSendingPrompt)
                    .accessibilityLabel(sendButtonLabel)
                }

                HStack(spacing: 3) {
                    if store.isRunning { followUpMenu }
                    if store.isSelectedThreadExternallyOwned, let threadId = store.selectedThreadId {
                        Button {
                            Task { await store.acquireThreadControl(threadId) }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.orange)
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("再次尝试取得控制权")
                    }
                    Spacer(minLength: 4)
                    runConfigurationMenu
                    contextMenu

                }
                .padding(.leading, 7)
                .padding(.trailing, 4)
                .padding(.bottom, 3)
            }
            .padding(.horizontal, 7)
            .padding(.top, 6)
            .padding(.bottom, 4)
            .background(RelayTheme.elevated)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(focused ? RelayTheme.accent.opacity(0.55) : RelayTheme.hairline, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.16), radius: 16, y: 6)
            .animation(.easeOut(duration: 0.16), value: focused)
            .simultaneousGesture(
                DragGesture(minimumDistance: 14)
                    .onEnded { value in
                        guard focused,
                              value.translation.height > 36,
                              abs(value.translation.width) < value.translation.height else { return }
                        focused = false
                    }
            )
        }
        .frame(maxWidth: RelayTheme.contentWidth)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 0)
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.2), value: store.currentQueuedFollowUps)
        .photosPicker(
            isPresented: $showingPhotoPicker,
            selection: $selectedPhotos,
            maxSelectionCount: 10,
            matching: .any(of: [.images, .videos]),
            photoLibrary: .shared()
        )
        .sheet(isPresented: $showingFileImporter) {
            RelayDocumentPicker { urls in
                showingFileImporter = false
                guard !urls.isEmpty else { return }
                isImportingAttachments = true
                Task { await importSelectedFiles(urls) }
            } onCancel: {
                showingFileImporter = false
            }
        }
        .onChange(of: selectedPhotos) { photos in
            guard !photos.isEmpty else { return }
            isImportingAttachments = true
            Task { await importSelectedPhotos(photos) }
        }
        .onChange(of: focused) { value in
            store.composerIsFocused = value
        }
        .onChange(of: store.editingQueuedFollowUp?.id) { id in
            if id != nil { focused = true }
        }
        .onDisappear { store.composerIsFocused = false }
    }

    private func presentPhotoPicker() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            showingPhotoPicker = true
        }
    }

    private func presentFileImporter() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            showingFileImporter = true
        }
    }

    private func importSelectedPhotos(_ photos: [PhotosPickerItem]) async {
        defer { isImportingAttachments = false }
        do {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("Relay Photos", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            var urls: [URL] = []
            for (index, item) in photos.enumerated() {
                if let videoType = item.supportedContentTypes.first(where: { $0.conforms(to: .movie) }) {
                    guard let video = try await item.loadTransferable(type: PickedVideo.self) else { continue }
                    defer { try? FileManager.default.removeItem(at: video.localURL.deletingLastPathComponent()) }
                    let fileExtension = videoType.preferredFilenameExtension ?? video.localURL.pathExtension.nonEmpty ?? "mov"
                    let url = directory.appendingPathComponent("视频 \(index + 1).\(fileExtension)")
                    try FileManager.default.copyItem(at: video.localURL, to: url)
                    urls.append(url)
                    continue
                }

                guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                guard data.count <= 50 * 1024 * 1024 else {
                    throw AttachmentImportError.fileTooLarge("照片 \(index + 1)")
                }
                let imageType = item.supportedContentTypes.first(where: { $0.conforms(to: .image) })
                let fileExtension = imageType?.preferredFilenameExtension ?? "jpg"
                let url = directory.appendingPathComponent("照片 \(index + 1).\(fileExtension)")
                try data.write(to: url, options: .atomic)
                urls.append(url)
            }

            selectedPhotos = []
            guard !urls.isEmpty else {
                store.errorMessage = "没有读取到可上传的照片或视频。"
                return
            }
            store.addAttachments(urls)
        } catch {
            selectedPhotos = []
            store.errorMessage = "读取照片或视频失败：\(error.localizedDescription)"
        }
    }

    private func importSelectedFiles(_ urls: [URL]) async {
        defer { isImportingAttachments = false }
        do {
            let stagedURLs = try await stageFiles(urls)
            guard !stagedURLs.isEmpty else {
                store.errorMessage = "没有读取到可上传的文件。"
                return
            }
            store.addAttachments(stagedURLs)
        } catch {
            store.errorMessage = "读取文件失败：\(error.localizedDescription)"
        }
    }

    private func stageFiles(_ urls: [URL]) async throws -> [URL] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let directory = FileManager.default.temporaryDirectory
                        .appendingPathComponent("Relay Imports", isDirectory: true)
                        .appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

                    var staged: [URL] = []
                    for url in urls {
                        let accessed = url.startAccessingSecurityScopedResource()
                        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
                        guard fileSize <= 50 * 1024 * 1024 else {
                            throw AttachmentImportError.fileTooLarge(url.lastPathComponent)
                        }
                        let destination = directory.appendingPathComponent(url.lastPathComponent)
                        try FileManager.default.copyItem(at: url, to: destination)
                        staged.append(destination)
                    }
                    continuation.resume(returning: staged)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(store.attachments) { attachment in
                    HStack(spacing: 7) {
                        Group {
                            switch attachment.state {
                            case .uploading:
                                ProgressView(value: attachment.progress).controlSize(.mini)
                            case .ready:
                                Image(systemName: attachment.isImage ? "photo" : "doc")
                                    .foregroundStyle(.secondary)
                            case .failed:
                                Image(systemName: "exclamationmark.circle.fill")
                                    .foregroundStyle(.red)
                            }
                        }
                        .frame(width: 15)

                        Text(attachment.name)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)

                        Button { store.removeAttachment(attachment.id) } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.secondary)
                                .frame(width: 20, height: 20)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.leading, 9)
                    .padding(.trailing, 4)
                    .frame(height: 32)
                    .background(RelayTheme.softFill)
                    .clipShape(Capsule())
                    .accessibilityLabel(attachmentAccessibilityLabel(attachment))
                }
            }
            .padding(.horizontal, 7)
            .padding(.top, 5)
        }
    }

    private func attachmentAccessibilityLabel(_ attachment: PendingAttachment) -> String {
        switch attachment.state {
        case .uploading: return "正在上传 \(attachment.name)"
        case .ready: return "已添加 \(attachment.name)"
        case .failed(let message): return "\(attachment.name) 上传失败：\(message)"
        }
    }

    private var modeIndicator: some View {
        HStack(spacing: 7) {
            Image(systemName: store.composerMode.icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(RelayTheme.accent)
            Text(store.composerMode.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(RelayTheme.accent)
            Spacer()
            Button { store.composerMode = .standard } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("退出\(store.composerMode.title)")
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: 30)
        .background(RelayTheme.accent.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .padding(.horizontal, 5)
        .padding(.top, 5)
    }

    private func queuedEditIndicator(_ item: QueuedFollowUp) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "pencil")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(RelayTheme.accent)
            Text("编辑排队消息")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(RelayTheme.accent)
            if !item.attachmentNames.isEmpty {
                Text("保留 \(item.attachmentNames.count) 个附件")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { store.cancelQueuedFollowUpEdit() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("取消编辑")
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: 30)
        .background(RelayTheme.accent.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .padding(.horizontal, 5)
        .padding(.top, 5)
    }

    private var runConfigurationMenu: some View {
        Menu {
            Menu {
                ForEach(store.modelOptions) { model in
                    Button {
                        Task { await store.selectModel(model) }
                    } label: {
                        if store.selectedModel?.id == model.id {
                            Label(model.displayName, systemImage: "checkmark")
                        } else {
                            Text(model.displayName)
                        }
                    }
                }
            } label: {
                Label("模型 · \(store.selectedModel?.displayName ?? "默认")", systemImage: "cpu")
            }

            Menu {
                ForEach(store.availableEfforts) { effort in
                    Button {
                        Task { await store.selectEffort(effort.id) }
                    } label: {
                        if store.selectedEffort == effort.id {
                            Label(effort.displayName, systemImage: "checkmark")
                        } else {
                            Text(effort.displayName)
                        }
                    }
                }
            } label: {
                Label("推理强度 · \(currentEffortName)", systemImage: "sparkles")
            }

            Menu {
                ForEach(WorkspaceAccessMode.allCases) { mode in
                    Button {
                        Task { await store.selectWorkspaceAccess(mode) }
                    } label: {
                        if store.workspaceAccess == mode {
                            Label(mode.title, systemImage: "checkmark")
                        } else {
                            Text(mode.title)
                        }
                    }
                }
            } label: {
                Label("访问权限 · \(store.workspaceAccess.title)", systemImage: "lock.shield")
            }

            Divider()

            if store.isSelectedThreadRelayOwned, !store.isRunning, let threadId = store.selectedThreadId {
                Button {
                    Task { await store.releaseThreadControl(threadId) }
                } label: {
                    Label("释放任务控制权", systemImage: "arrow.down.left.and.arrow.up.right")
                }

                Divider()
            }

            Button { store.showingSettings = true } label: {
                Label("更多设置", systemImage: "gearshape")
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
                .frame(width: 32, height: 28)
        }
        .accessibilityLabel("运行配置")
    }

    private var followUpMenu: some View {
        Menu {
            ForEach(FollowUpBehavior.allCases) { behavior in
                Button {
                    store.selectFollowUpBehavior(behavior)
                } label: {
                    if store.followUpBehavior == behavior {
                        Label("\(behavior.title) · \(behavior.detail)", systemImage: "checkmark")
                    } else {
                        Text("\(behavior.title) · \(behavior.detail)")
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: store.followUpBehavior == .steer ? "arrow.turn.up.right" : "text.badge.plus")
                Text(store.followUpBehavior.title)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(RelayTheme.accent)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RelayTheme.accent.opacity(0.09))
            .clipShape(Capsule())
        }
        .accessibilityLabel("后续消息方式：\(store.followUpBehavior.title)")
    }

    @ViewBuilder
    private var contextMenu: some View {
        if let usage = store.currentTokenUsage, let percentage = usage.contextPercentage {
            Menu {
                Text("本轮 \(usage.last.totalTokens.formatted()) tokens")
                Text("累计 \(usage.total.totalTokens.formatted()) tokens")
                Button {
                    Task { await store.compactContext() }
                } label: {
                    Label("压缩上下文", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(store.isRunning || store.isCompacting)
            } label: {
                HStack(spacing: 5) {
                    if store.isCompacting {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "circle.dotted")
                    }
                    Text("\(percentage)%")
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(percentage >= 80 ? Color.orange : Color.secondary)
                .padding(.horizontal, 7)
                .frame(height: 28)
            }
        }
    }

    private var currentEffortName: String {
        store.availableEfforts.first(where: { $0.id == store.selectedEffort })?.displayName ?? "推理"
    }

    private var hasDraft: Bool {
        let hasText = !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasReadyFile = store.attachments.contains { $0.state == .ready }
        let hasQueuedFile = store.editingQueuedFollowUp?.input.contains { $0["type"]?.stringValue != "text" } == true
        if store.composerMode == .goal { return hasText }
        return hasText || hasReadyFile || hasQueuedFile
    }

    private var visibleGoal: GoalState? {
        guard let goal = store.currentGoal, goal.status != .complete else { return nil }
        return goal
    }

    private var composerPlaceholder: String {
        if store.isSelectedThreadExternallyOwned { return "Codex 正在运行，可在此查看进展" }
        if store.editingQueuedFollowUp != nil { return "编辑排队消息" }
        if store.isRunning { return "引导当前任务" }
        switch store.composerMode {
        case .standard: return "Message Codex"
        case .plan: return "让 Codex 先制定计划"
        case .goal: return "描述要持续完成的目标"
        }
    }

    private var composerPrompt: Text {
        Text(composerPlaceholder)
            .font(.system(
                size: store.isSelectedThreadExternallyOwned ? 13 : 16,
                weight: store.isSelectedThreadExternallyOwned ? .medium : .regular
            ))
            .foregroundColor(store.isSelectedThreadExternallyOwned ? .orange : .secondary)
    }

    private var canSend: Bool {
        let isUploading = store.attachments.contains { $0.state == .uploading }
        return store.socket.state == .connected
            && !store.isSelectedThreadExternallyOwned
            && !isImportingAttachments
            && !isUploading
            && hasDraft
    }

    private var showsStopControl: Bool {
        store.isRunning && !store.isSelectedThreadExternallyOwned && !hasDraft
    }
    private var actionEnabled: Bool {
        store.socket.state == .connected && (canSend || showsStopControl)
    }
    private var sendButtonLabel: String {
        if store.isSendingPrompt { return "正在发送" }
        if store.editingQueuedFollowUp != nil { return "保存修改" }
        if showsStopControl { return "停止任务" }
        if store.isRunning { return store.followUpBehavior == .steer ? "立即引导当前任务" : "加入等待队列" }
        return "发送"
    }
}

private struct TaskContextPanel: View {
    let steps: [ExecutionPlanStep]
    let goal: GoalState?

    var body: some View {
        VStack(spacing: 0) {
            if !steps.isEmpty {
                ExecutionPlanPanel(steps: steps)
            }
            if !steps.isEmpty, goal != nil {
                Divider()
                    .padding(.horizontal, 11)
            }
            if let goal {
                ActiveGoalPanel(goal: goal)
            }
        }
        .background(RelayTheme.elevated)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(RelayTheme.hairline, lineWidth: 1)
        }
    }
}

private struct ActiveGoalPanel: View {
    let goal: GoalState
    @EnvironmentObject private var store: RelayStore

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "scope")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(statusColor)
            Text(goal.status.label)
                .font(.system(size: 12, weight: .semibold))
                .fixedSize(horizontal: true, vertical: false)
            Text(goal.objective)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Text("·")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Text(elapsedText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)

            Menu {
                if goal.status == .active {
                    Button {
                        Task { await store.updateCurrentGoalStatus(.paused) }
                    } label: {
                        Label("暂停目标", systemImage: "pause")
                    }
                } else {
                    Button {
                        Task { await store.updateCurrentGoalStatus(.active) }
                    } label: {
                        Label("继续目标", systemImage: "play")
                    }
                }
                Button {
                    store.prepareCurrentGoalForEditing()
                } label: {
                    Label("编辑目标", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    Task { await store.clearCurrentGoal() }
                } label: {
                    Label("清除目标", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .accessibilityLabel("目标操作")
        }
        .padding(.horizontal, 11)
        .frame(height: 40)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(goal.status.label)，\(goal.objective)")
    }

    private var statusColor: Color {
        switch goal.status {
        case .blocked, .usageLimited, .budgetLimited: return .orange
        default: return .secondary
        }
    }

    private var elapsedText: String {
        let seconds = max(0, goal.timeUsedSeconds)
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let remainder = seconds % 60
        if hours > 0 { return "\(hours)h \(minutes)m \(remainder)s" }
        if minutes > 0 { return "\(minutes)m \(remainder)s" }
        return "\(remainder)s"
    }
}

private struct ContextPressureNotice: View {
    let percentage: Int
    let isBusy: Bool
    let compact: () -> Void

    var body: some View {
        Button(action: compact) {
            HStack(spacing: 7) {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 12, weight: .medium))
                Text("上下文已使用 \(percentage)%")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(isBusy ? "稍后压缩" : "压缩")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(Color.orange)
            .padding(.horizontal, 11)
            .frame(height: 34)
            .background(Color.orange.opacity(0.09))
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .accessibilityLabel("上下文已使用 \(percentage)%，\(isBusy ? "稍后可压缩" : "点击压缩")")
    }
}

private enum AttachmentImportError: LocalizedError {
    case fileTooLarge(String)

    var errorDescription: String? {
        switch self {
        case .fileTooLarge(let name): return "\(name) 超过 50 MB。"
        }
    }
}

private struct PickedVideo: Transferable {
    let localURL: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { video in
            SentTransferredFile(video.localURL)
        } importing: { received in
            let values = try received.file.resourceValues(forKeys: [.fileSizeKey])
            let size = values.fileSize ?? 0
            guard size <= 50 * 1024 * 1024 else {
                throw AttachmentImportError.fileTooLarge(received.file.lastPathComponent)
            }
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("Relay Video Picker", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let name = received.file.lastPathComponent.nonEmpty ?? "视频.mov"
            let destination = directory.appendingPathComponent(name)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return PickedVideo(localURL: destination)
        }
    }
}

struct RelayDocumentPicker: UIViewControllerRepresentable {
    let onPick: ([URL]) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: true)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = true
        picker.shouldShowFileExtensions = true
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onPick: ([URL]) -> Void
        private let onCancel: () -> Void

        init(onPick: @escaping ([URL]) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }
    }
}

private struct ExecutionPlanPanel: View {
    let steps: [ExecutionPlanStep]
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) { expanded.toggle() }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "list.bullet.clipboard")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("执行计划")
                        .font(.system(size: 12, weight: .semibold))
                    Text("\(completedCount)/\(steps.count)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 11)
                .frame(height: 32)
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    Divider().opacity(0.45)
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(visibleSteps) { step in
                            HStack(alignment: .top, spacing: 7) {
                                planStatus(step)
                                    .frame(width: 14, height: 16)
                                Text(step.text)
                                    .font(.system(size: 12))
                                    .foregroundStyle(step.isCompleted ? Color.secondary : Color.primary)
                                    .lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        if hiddenStepCount > 0 {
                            Text("还有 \(hiddenStepCount) 项")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 21)
                        }
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                }
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity)
            }
        }
    }

    private var completedCount: Int { steps.filter(\.isCompleted).count }
    private var visibleSteps: [ExecutionPlanStep] { Array(steps.prefix(6)) }
    private var hiddenStepCount: Int { max(0, steps.count - visibleSteps.count) }

    @ViewBuilder
    private func planStatus(_ step: ExecutionPlanStep) -> some View {
        if step.isCompleted {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(RelayTheme.accent)
        } else if step.isRunning {
            ProgressView()
                .controlSize(.mini)
                .tint(.secondary)
        } else if step.normalizedStatus.contains("fail") {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.red)
        } else {
            Circle()
                .stroke(Color.secondary.opacity(0.45), lineWidth: 1.2)
                .frame(width: 10, height: 10)
        }
    }
}
