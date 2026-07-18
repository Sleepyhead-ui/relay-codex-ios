import SwiftUI

struct ComposerView: View {
    @EnvironmentObject private var store: RelayStore
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 8) {
            if store.socket.state != .connected {
                Button {
                    store.showingConnection = true
                } label: {
                    Label("Connect to Windows", systemImage: "bolt.horizontal.circle")
                        .font(.system(size: 13, weight: .semibold))
                }
            }

            HStack(alignment: .bottom, spacing: 8) {
                Button {
                    store.showingSettings = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 36, height: 36)
                }
                .accessibilityLabel("Task settings")

                TextField("Message Codex", text: $store.composerText, axis: .vertical)
                    .font(.system(size: 16))
                    .lineLimit(1...6)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .padding(.vertical, 8)
                    .submitLabel(.send)
                    .onSubmit {
                        guard !store.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                        Task { await store.sendPrompt() }
                    }

                Button {
                    Task {
                        if store.isRunning { await store.stopTurn() }
                        else { await store.sendPrompt() }
                    }
                } label: {
                    Image(systemName: store.isRunning ? "stop.fill" : "arrow.up")
                        .font(.system(size: store.isRunning ? 12 : 15, weight: .bold))
                        .foregroundStyle(canSend || store.isRunning ? RelayTheme.canvas : Color.secondary)
                        .frame(width: 34, height: 34)
                        .background(canSend || store.isRunning ? Color.primary : RelayTheme.softFill)
                        .clipShape(Circle())
                }
                .disabled(!canSend && !store.isRunning)
                .accessibilityLabel(store.isRunning ? "Stop task" : "Send")
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 6)
            .background(RelayTheme.elevated)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(RelayTheme.hairline, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.06), radius: 10, y: 3)
        }
        .frame(maxWidth: RelayTheme.contentWidth)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
    }

    private var canSend: Bool {
        store.socket.state == .connected && !store.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

