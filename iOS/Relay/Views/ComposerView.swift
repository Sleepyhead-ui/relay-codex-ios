import SwiftUI
import UniformTypeIdentifiers
import PhotosUI

struct ComposerView: View {
    @EnvironmentObject private var store: RelayStore
    @FocusState private var focused: Bool
    @State private var showingAttachmentOptions = false
    @State private var showingPhotoPicker = false
    @State private var showingFileImporter = false
    @State private var isImportingAttachments = false
    @State private var selectedPhotos: [PhotosPickerItem] = []

    var body: some View {
        VStack(spacing: 8) {
            if store.isRunning, !store.activePlan.isEmpty {
                ExecutionPlanPanel(steps: store.activePlan)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if let percentage = store.currentTokenUsage?.contextPercentage, percentage >= 90 {
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
                    Label("Reconnecting to Windows", systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                } else {
                    Button { store.showingConnection = true } label: {
                        Label("Connect to Windows", systemImage: "bolt.horizontal.circle")
                            .font(.system(size: 13, weight: .semibold))
                    }
                }
            }

            VStack(spacing: 2) {
                if !store.attachments.isEmpty {
                    attachmentStrip
                }

                HStack(alignment: .bottom, spacing: 8) {
                    Button {
                        focused = false
                        showingAttachmentOptions = true
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
                    .disabled(isImportingAttachments)
                    .accessibilityLabel("添加照片或文件")

                    TextField("Message Codex", text: $store.composerText, axis: .vertical)
                        .font(.system(size: 16))
                        .lineLimit(1...8)
                        .textFieldStyle(.plain)
                        .focused($focused)
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
                            if store.isRunning { await store.stopTurn() }
                            else {
                                focused = false
                                await store.sendPrompt()
                            }
                        }
                    } label: {
                        Image(systemName: store.isRunning ? "stop.fill" : "arrow.up")
                            .font(.system(size: store.isRunning ? 11 : 15, weight: .bold))
                            .foregroundStyle(canSend || store.isRunning ? RelayTheme.canvas : Color.secondary)
                            .frame(width: 34, height: 34)
                            .background(canSend || store.isRunning ? Color.primary : RelayTheme.softFill)
                            .clipShape(Circle())
                    }
                    .disabled(!canSend && !store.isRunning)
                    .accessibilityLabel(store.isRunning ? "Stop task" : "Send")
                }

                HStack(spacing: 3) {
                    modelMenu
                    effortMenu
                    Spacer(minLength: 4)
                    contextMenu

                    if focused {
                        Button { focused = false } label: {
                            Image(systemName: "keyboard.chevron.compact.down")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 32, height: 28)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Hide keyboard")
                    }
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
        }
        .frame(maxWidth: RelayTheme.contentWidth)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.2), value: store.activePlan)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focused = false }
                    .fontWeight(.semibold)
            }
        }
        .confirmationDialog("添加附件", isPresented: $showingAttachmentOptions, titleVisibility: .visible) {
            Button {
                presentPhotoPicker()
            } label: {
                Label("照片图库", systemImage: "photo.on.rectangle")
            }
            Button {
                presentFileImporter()
            } label: {
                Label("文件", systemImage: "folder")
            }
            Button("取消", role: .cancel) {}
        }
        .photosPicker(
            isPresented: $showingPhotoPicker,
            selection: $selectedPhotos,
            maxSelectionCount: 10,
            matching: .images,
            photoLibrary: .shared()
        )
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                guard !urls.isEmpty else { return }
                isImportingAttachments = true
                Task { await importSelectedFiles(urls) }
            case .failure(let error): store.errorMessage = error.localizedDescription
            }
        }
        .onChange(of: selectedPhotos) { photos in
            guard !photos.isEmpty else { return }
            isImportingAttachments = true
            Task { await importSelectedPhotos(photos) }
        }
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
            for (index, photo) in photos.enumerated() {
                guard let data = try await photo.loadTransferable(type: Data.self) else { continue }
                let imageType = photo.supportedContentTypes.first(where: { $0.conforms(to: .image) })
                let fileExtension = imageType?.preferredFilenameExtension ?? "jpg"
                let url = directory.appendingPathComponent("照片 \(index + 1).\(fileExtension)")
                try data.write(to: url, options: .atomic)
                urls.append(url)
            }

            selectedPhotos = []
            guard !urls.isEmpty else {
                store.errorMessage = "没有读取到可上传的照片。"
                return
            }
            store.addAttachments(urls)
        } catch {
            selectedPhotos = []
            store.errorMessage = "读取照片失败：\(error.localizedDescription)"
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
                        let data = try Data(contentsOf: url, options: .mappedIfSafe)
                        guard data.count <= 50 * 1024 * 1024 else {
                            throw AttachmentImportError.fileTooLarge(url.lastPathComponent)
                        }
                        let destination = directory.appendingPathComponent(url.lastPathComponent)
                        try data.write(to: destination, options: .atomic)
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

    private var modelMenu: some View {
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
            HStack(spacing: 4) {
                Text(store.selectedModel?.displayName ?? "Model")
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RelayTheme.softFill)
            .clipShape(Capsule())
        }
        .disabled(store.modelOptions.isEmpty)
    }

    private var effortMenu: some View {
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
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                Text(currentEffortName)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RelayTheme.softFill)
            .clipShape(Capsule())
        }
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

    private var canSend: Bool {
        let hasText = !store.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasReadyFile = store.attachments.contains { $0.state == .ready }
        let isUploading = store.attachments.contains { $0.state == .uploading }
        return store.socket.state == .connected && !isUploading && (hasText || hasReadyFile)
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

private struct ExecutionPlanPanel: View {
    let steps: [ExecutionPlanStep]
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) { expanded.toggle() }
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
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(RelayTheme.elevated)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(RelayTheme.hairline, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
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
