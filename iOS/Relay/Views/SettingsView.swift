import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: RelayStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Windows host") {
                    LabeledContent("Name", value: store.host.name)
                    LabeledContent("Address", value: store.host.endpoint)
                    LabeledContent("Status", value: status)
                    Button("Edit connection") {
                        dismiss()
                        store.showingConnection = true
                    }
                    if store.savedHosts.count > 1 {
                        ForEach(store.savedHosts) { entry in
                            Button {
                                store.switchHost(entry.id)
                                dismiss()
                            } label: {
                                HStack(spacing: 9) {
                                    Circle()
                                        .fill(store.hostAvailability[entry.id] == true ? Color.green : Color.secondary.opacity(0.5))
                                        .frame(width: 7, height: 7)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.name).foregroundStyle(.primary)
                                        Text(entry.endpoint).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                    if entry.id == store.currentHostId { Image(systemName: "checkmark").foregroundStyle(RelayTheme.accent) }
                                }
                            }
                            .disabled(entry.id == store.currentHostId)
                        }
                    }
                    if store.isCheckingHosts {
                        HStack { ProgressView(); Text("正在检查已配对电脑").foregroundStyle(.secondary) }
                    }
                }

                Section("Codex 实例") {
                    if store.codexProfiles.isEmpty {
                        HStack {
                            ProgressView()
                            Text("正在发现 Windows 实例")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(store.codexProfiles.sorted { left, right in
                            if left.isActive != right.isActive { return left.isActive }
                            if left.isRunning != right.isRunning { return left.isRunning }
                            return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
                        }) { profile in
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
                                        Text(profile.isRunning ? "Windows 上正在运行" : "已保存的实例")
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
                            .disabled(store.isSwitchingCodexProfile || store.isRunning || store.pendingApproval != nil || profile.id == store.activeCodexProfileId)
                        }
                    }
                    if store.isSwitchingCodexProfile {
                        HStack {
                            ProgressView()
                            Text("正在切换并刷新对话")
                                .foregroundStyle(.secondary)
                        }
                    } else if store.isRunning || store.pendingApproval != nil {
                        Text("任务运行或等待审批时不能切换实例。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Task defaults") {
                    TextField("默认项目目录", text: $store.host.workingDirectory)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: store.host.workingDirectory) { _ in store.saveHostConfiguration() }
                    LabeledContent("Model", value: store.selectedModel?.displayName ?? "Default")
                    LabeledContent("Reasoning", value: store.availableEfforts.first(where: { $0.id == store.selectedEffort })?.displayName ?? "Default")

                }

                Section("工作区权限") {
                    Picker("访问级别", selection: $store.workspaceAccess) {
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

                    Text("权限会应用到新任务和之后发送的每一轮；越过当前边界的操作仍可能要求确认。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Conversation continuity") {
                    LabeledContent("桌面同步", value: desktopSyncLabel)
                    Text("增强刷新会在手机任务完成后让 Windows Codex 重新读取当前线程。若显示“基础深链”，请完全退出 Windows Codex，再从手机发送一次消息；Bridge 会用仅限本机的增强模式重新启动它。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("运行与通知") {
                    Toggle("任务完成和审批通知", isOn: Binding(
                        get: { store.notificationsEnabled },
                        set: { enabled in Task { await store.setNotificationsEnabled(enabled) } }
                    ))
                    Button {
                        dismiss()
                        store.showingDiagnostics = true
                    } label: {
                        Label("打开诊断中心", systemImage: "stethoscope")
                    }
                }

                Section("应用更新") {
                    if let update = store.updateInfo {
                        LabeledContent("当前版本", value: update.currentVersion)
                        LabeledContent("最新版本", value: update.latestVersion)
                        if update.available {
                            Button {
                                Task { await store.downloadLatestIPA() }
                            } label: {
                                HStack {
                                    if store.isDownloadingUpdate { ProgressView() }
                                    Label(store.isDownloadingUpdate ? "正在通过 Windows 下载" : "下载 IPA", systemImage: "arrow.down.circle")
                                }
                            }
                            .disabled(store.isDownloadingUpdate)
                        } else {
                            Label("当前已是最新版本", systemImage: "checkmark.circle")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button {
                        Task { await store.checkForUpdate() }
                    } label: {
                        HStack {
                            if store.isCheckingUpdate { ProgressView() }
                            Text(store.isCheckingUpdate ? "正在检查" : "检查更新")
                        }
                    }
                    .disabled(store.isCheckingUpdate)
                }

                Section {
                    Button("Forget this host", role: .destructive) { store.forgetHost() }
                }

                Section {
                    LabeledContent("Relay", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown")
                    LabeledContent("Protocol", value: "Codex 0.144.x")
                }
            }
            .scrollContentBackground(.hidden)
            .background(RelayTheme.canvas)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .task { await store.refreshSavedHostStatus() }
        }
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
        case .connected: return "Connected"
        case .connecting: return "Connecting"
        case .reconnecting(let attempt): return "Reconnecting (\(attempt))"
        case .disconnected: return "Offline"
        case .failed: return "Connection lost"
        }
    }

    private var desktopSyncLabel: String {
        switch store.socket.desktopSyncMode {
        case "enhanced": return "增强刷新"
        case "deep-link": return "基础深链"
        case "pending": return "等待检测"
        case "off": return "关闭"
        default: return "未知"
        }
    }
}
