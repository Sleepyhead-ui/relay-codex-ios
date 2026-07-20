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

                Section {
                    Button("Forget this host", role: .destructive) { store.forgetHost() }
                }

                Section {
                    LabeledContent("Relay", value: "0.6.15")
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
