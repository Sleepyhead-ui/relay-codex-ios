import SwiftUI

struct ComposerView: View {
    @EnvironmentObject private var store: RelayStore
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 8) {
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
                        .lineLimit(1...7)
                        .textFieldStyle(.plain)
                        .focused($focused)
                        .padding(.vertical, 8)
                        .submitLabel(.send)
                        .onSubmit {
                            guard canSend else { return }
                            Task { await store.sendPrompt() }
                        }

                    Button {
                        Task {
                            if store.isRunning { await store.stopTurn() }
                            else { await store.sendPrompt() }
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
            .shadow(color: .black.opacity(0.06), radius: 10, y: 3)
            .animation(.easeOut(duration: 0.16), value: focused)
        }
        .frame(maxWidth: RelayTheme.contentWidth)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focused = false }
                    .fontWeight(.semibold)
            }
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
                .foregroundStyle(percentage >= 85 ? Color.orange : Color.secondary)
                .padding(.horizontal, 7)
                .frame(height: 28)
            }
        }
    }

    private var currentEffortName: String {
        store.availableEfforts.first(where: { $0.id == store.selectedEffort })?.displayName ?? "推理"
    }

    private var canSend: Bool {
        store.socket.state == .connected && !store.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
