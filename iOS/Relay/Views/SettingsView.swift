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
                    Text("New tasks use workspace-write sandboxing and request approval for actions that cross the configured boundary.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Conversation continuity") {
                    Text("Relay stores turns on this Windows host. A Codex desktop chat that is already open will not refresh live; reopen or resume the thread on Windows to load mobile turns.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button("Forget this host", role: .destructive) { store.forgetHost() }
                }

                Section {
                    LabeledContent("Relay", value: "0.2.0")
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
