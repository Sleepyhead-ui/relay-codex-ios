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
                    TextField("Working directory", text: $store.host.workingDirectory)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    LabeledContent("Model", value: store.selectedModel?.displayName ?? "Default")
                    LabeledContent("Reasoning", value: store.availableEfforts.first(where: { $0.id == store.selectedEffort })?.displayName ?? "Default")
                    Text("New tasks use workspace-write sandboxing and request approval for actions that cross the configured boundary.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Conversation continuity") {
                    Text("Start the Bridge with -DesktopSync to activate the same thread in the official Windows Codex app when a mobile turn starts or completes. This refresh mode is experimental and may briefly bring Codex to the foreground.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button("Forget this host", role: .destructive) { store.forgetHost() }
                }

                Section {
                    LabeledContent("Relay", value: "0.3.0")
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

    private var status: String {
        switch store.socket.state {
        case .connected: return "Connected"
        case .connecting: return "Connecting"
        case .reconnecting(let attempt): return "Reconnecting (\(attempt))"
        case .disconnected: return "Offline"
        case .failed: return "Connection lost"
        }
    }
}
