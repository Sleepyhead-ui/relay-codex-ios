import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: RelayStore
    @Environment(\.dismiss) private var dismiss
    @State private var showingForgetConfirmation = false
    @AppStorage(RelayHaptics.preferenceKey) private var hapticsEnabled = true

    var body: some View {
        NavigationView {
            Form {
                windowsSection
                codexProfilesSection
                taskDefaultsSection
                notificationsSection
                aboutSection

                Section {
                    Button("移除此电脑", role: .destructive) {
                        showingForgetConfirmation = true
                    }
                } footer: {
                    Text("只会移除这台手机保存的连接信息，不会删除 Windows 上的项目或 Codex 对话。")
                }
            }
            .relayScrollContentBackgroundHidden()
            .background(RelayTheme.canvas)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .confirmationDialog("移除此电脑？", isPresented: $showingForgetConfirmation, titleVisibility: .visible) {
                Button("移除", role: .destructive) { store.forgetHost() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("之后需要重新输入连接地址和配对令牌才能连接。")
            }
            .task { await store.refreshSavedHostStatus() }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private var windowsSection: some View {
        Section("Windows 电脑") {
            HStack(spacing: 11) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.host.name.nonEmpty ?? "Windows 电脑")
                    Text(store.host.endpoint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 12)
                Text(status)
                    .font(.subheadline)
                    .foregroundStyle(statusColor)
            }

            Button {
                dismiss()
                store.showingConnection = true
            } label: {
                Label("编辑连接", systemImage: "network")
            }

            ForEach(otherSavedHosts) { entry in
                Button {
                    store.switchHost(entry.id)
                    dismiss()
                } label: {
                    HStack(spacing: 11) {
                        Circle()
                            .fill(store.hostAvailability[entry.id] == true ? Color.green : Color.secondary.opacity(0.5))
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.name).foregroundStyle(.primary)
                            Text(entry.endpoint)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Text("切换")
                            .font(.subheadline)
                            .foregroundStyle(RelayTheme.accent)
                    }
                }
            }

            if store.isCheckingHosts {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("正在检查已配对电脑")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var codexProfilesSection: some View {
        Section("Codex 实例") {
            if store.codexProfiles.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("正在发现 Windows 实例")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(sortedProfiles) { profile in
                    Button {
                        Task { await store.switchCodexProfile(profile.id) }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: profile.isRunning ? "circle.fill" : "circle")
                                .font(.system(size: 8))
                                .foregroundStyle(profile.isRunning ? Color.green : Color.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.name)
                                    .foregroundStyle(.primary)
                                Text(profile.isRunning ? "正在运行" : "已保存")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if profile.id == store.activeCodexProfileId {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(RelayTheme.accent)
                            }
                        }
                    }
                    .disabled(profileSwitchDisabled || profile.id == store.activeCodexProfileId)
                }
            }

            if store.isSwitchingCodexProfile {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("正在切换并刷新对话")
                        .foregroundStyle(.secondary)
                }
            } else if store.isRunning || store.pendingApproval != nil {
                Text("任务运行或等待确认时不能切换实例。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let runtime = store.codexRuntimeInfo {
                RelayLabeledRow("运行时") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(runtime.version.map { "Codex \($0)" } ?? "版本未知")
                            .foregroundStyle(.primary)
                        Text("\(runtime.sourceLabel) · \(runtime.compatibilityLabel)")
                            .font(.caption)
                            .foregroundStyle(runtime.compatibility == "compatible" ? Color.secondary : Color.orange)
                    }
                }
            }
        }
    }

    private var taskDefaultsSection: some View {
        Section {
            HStack {
                Text("项目目录")
                Spacer(minLength: 16)
                TextField("未设置", text: $store.host.workingDirectory)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(1)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: store.host.workingDirectory) { _ in store.saveHostConfiguration() }
            }

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
                RelayLabeledRow("模型") {
                    Text(store.selectedModel?.displayName ?? "默认")
                }
            }
            .disabled(store.modelOptions.isEmpty)

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
                RelayLabeledRow("思考深度") {
                    Text(selectedEffortName)
                }
            }

            Picker("文件权限", selection: $store.workspaceAccess) {
                ForEach(WorkspaceAccessMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: store.workspaceAccess) { mode in
                Task { await store.selectWorkspaceAccess(mode) }
            }

            Label(store.workspaceAccess.detail, systemImage: accessIcon)
                .font(.footnote)
                .foregroundStyle(store.workspaceAccess == .fullAccess ? Color.orange : Color.secondary)
        } header: {
            Text("任务设置")
        } footer: {
            Text("项目目录用于新任务；模型、思考深度和文件权限会同时应用到当前任务。完全访问不会再逐项请求审批。")
        }
    }

    private var notificationsSection: some View {
        Section {
            Toggle("任务通知", isOn: Binding(
                get: { store.notificationsEnabled },
                set: { enabled in Task { await store.setNotificationsEnabled(enabled) } }
            ))
            Toggle("触感反馈", isOn: $hapticsEnabled)
                .onChange(of: hapticsEnabled) { enabled in
                    if enabled { RelayHaptics.selection() }
                }
            Button {
                dismiss()
                store.showingDiagnostics = true
            } label: {
                Label("诊断中心", systemImage: "stethoscope")
            }
        } header: {
            Text("提醒与反馈")
        } footer: {
            Text("任务完成、执行失败或需要确认时发送通知；触感反馈只用于主动操作。")
        }
    }

    private var aboutSection: some View {
        Section("关于 Relay") {
            RelayLabeledRow("版本") {
                Text(AppBuildIdentity().displayText)
            }

            if let update = store.updateInfo, update.available {
                Button {
                    Task { await store.downloadLatestIPA() }
                } label: {
                    HStack(spacing: 10) {
                        if store.isDownloadingUpdate {
                            ProgressView(value: store.updateDownloadProgress ?? 0)
                        }
                        Label(updateDownloadLabel(update.latestVersion), systemImage: "arrow.down.circle")
                    }
                }
                .disabled(store.isDownloadingUpdate)
            } else if store.updateInfo != nil {
                Label("已是最新版本", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }

            Button {
                Task { await store.checkForUpdate() }
            } label: {
                HStack(spacing: 10) {
                    if store.isCheckingUpdate { ProgressView() }
                    Text(store.isCheckingUpdate ? "正在检查" : "检查更新")
                }
            }
            .disabled(store.isCheckingUpdate)
        }
    }

    private var sortedProfiles: [CodexProfile] {
        store.codexProfiles.sorted { left, right in
            if left.isActive != right.isActive { return left.isActive }
            if left.isRunning != right.isRunning { return left.isRunning }
            return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
        }
    }

    private var otherSavedHosts: [RelayHostEntry] {
        store.savedHosts.filter { $0.id != store.currentHostId }
    }

    private var profileSwitchDisabled: Bool {
        store.isSwitchingCodexProfile || store.isRunning || store.pendingApproval != nil
    }

    private var selectedEffortName: String {
        store.availableEfforts.first(where: { $0.id == store.selectedEffort })?.displayName ?? "默认"
    }

    private func updateDownloadLabel(_ version: String) -> String {
        if store.isDownloadingUpdate {
            return "正在下载 \(Int((store.updateDownloadProgress ?? 0) * 100))%"
        }
        return "下载 v\(version) 安装包"
    }

    private var accessIcon: String {
        switch store.workspaceAccess {
        case .readOnly: return "lock"
        case .workspaceWrite: return "folder.badge.gearshape"
        case .fullAccess: return "exclamationmark.shield"
        }
    }

    private var status: String {
        switch store.socket.state {
        case .connected: return "已连接"
        case .connecting: return "连接中"
        case .reconnecting: return "重连中"
        case .disconnected: return "离线"
        case .failed: return "连接失败"
        }
    }

    private var statusColor: Color {
        switch store.socket.state {
        case .connected: return .green
        case .connecting, .reconnecting: return .orange
        case .disconnected, .failed: return .secondary
        }
    }
}
