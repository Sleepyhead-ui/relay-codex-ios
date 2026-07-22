import SwiftUI
import UIKit

struct ConversationView: View {
    @EnvironmentObject private var store: RelayStore
    @State private var isAtBottom = true
    @State private var isUserScrolling = false

    private let bottomAnchor = "relay-conversation-bottom"

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider().opacity(0.55)
            transcript
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if store.showingArchivedThreads {
                archivedBar
            } else {
                ComposerView()
            }
        }
        .background(RelayTheme.canvas)
    }

    private var archivedBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "archivebox")
                .font(.system(size: 13, weight: .medium))
            Text("此任务已归档，仅供查看")
                .font(.system(size: 12, weight: .medium))
            Spacer()
            if let threadId = store.selectedThreadId {
                Button {
                    Task { await store.unarchiveThread(threadId) }
                } label: {
                    Label("恢复", systemImage: "arrow.uturn.backward")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: 54)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider().opacity(0.55) }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation { store.sidebarOpen = true }
            } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 18, weight: .medium))
            }
            .relayIconButton()
            .accessibilityLabel("Open conversations")

            VStack(alignment: .leading, spacing: 2) {
                Text(store.selectedThread?.title ?? "Relay")
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Circle()
                        .fill(connectionColor)
                        .frame(width: 6, height: 6)
                    Text(connectionLabel)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if store.isRunning {
                ProgressView()
                    .controlSize(.small)
                    .tint(.secondary)
                    .frame(width: 26, height: 42)
            }

            Button {
                store.showingSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 17, weight: .medium))
            }
            .relayIconButton()
            .accessibilityLabel("设置和工作区权限")

            Button {
                store.showingNewTask = true
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 17, weight: .medium))
            }
            .relayIconButton()
            .accessibilityLabel("New task")
        }
        .padding(.horizontal, 8)
        .frame(height: 58)
        .background(RelayTheme.canvas)
    }

    @ViewBuilder
    private var transcript: some View {
        if store.isLoadingThread {
            LoadingConversationView()
        } else if store.messages.isEmpty {
            EmptyConversationView()
        } else {
            ScrollViewReader { proxy in
                ZStack(alignment: .bottom) {
                    ScrollView {
                        LazyVStack(spacing: 30) {
                            if store.hasOlderTurns {
                                Button {
                                    Task { await store.loadOlderTurns() }
                                } label: {
                                    HStack(spacing: 7) {
                                        if store.isLoadingOlderTurns {
                                            ProgressView().controlSize(.mini)
                                        } else {
                                            Image(systemName: "clock.arrow.circlepath")
                                                .font(.system(size: 12, weight: .medium))
                                        }
                                        Text(store.isLoadingOlderTurns ? "正在加载更早对话" : "加载更早对话")
                                            .font(.system(size: 12, weight: .semibold))
                                    }
                                    .foregroundStyle(.secondary)
                                    .frame(height: 32)
                                    .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.plain)
                                .disabled(store.isLoadingOlderTurns)
                            }

                            ForEach(store.transcriptGroups) { group in
                                TurnGroupView(group: group, isLive: group.turnId == store.activeTurnId)
                                    .id(group.id)
                                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                            }

                            Color.clear
                                .frame(height: 1)
                                .id(bottomAnchor)
                                .onAppear { isAtBottom = true }
                                .onDisappear { isAtBottom = false }
                        }
                        .frame(maxWidth: RelayTheme.contentWidth)
                        .padding(.horizontal, RelayTheme.horizontalPadding)
                        .padding(.top, 24)
                        .padding(.bottom, 20)
                        .frame(maxWidth: .infinity)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 4)
                            .onChanged { _ in
                                if !isUserScrolling { isUserScrolling = true }
                                if isAtBottom { isAtBottom = false }
                            }
                            .onEnded { _ in
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                    isUserScrolling = false
                                }
                            }
                    )
                    .onTapGesture { dismissKeyboard() }

                    if !isAtBottom {
                        Button {
                            scrollToBottom(proxy, animated: true)
                        } label: {
                            Image(systemName: "arrow.down")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.primary)
                                .frame(width: 38, height: 38)
                                .background(.ultraThinMaterial)
                                .clipShape(Circle())
                                .overlay { Circle().stroke(RelayTheme.hairline, lineWidth: 1) }
                                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, 12)
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                    }
                }
                .onAppear { scrollToBottom(proxy, animated: false) }
                .onChange(of: store.selectedThreadId) { _ in
                    isAtBottom = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                        scrollToBottom(proxy, animated: false)
                    }
                }
                .onChange(of: store.isLoadingThread) { loading in
                    guard !loading else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                        scrollToBottom(proxy, animated: false)
                    }
                }
                .onChange(of: transcriptUpdateKey) { _ in
                    guard isAtBottom, !isUserScrolling else { return }
                    scrollToBottom(proxy, animated: !store.isRunning)
                }
            }
        }
    }

    private var transcriptUpdateKey: String {
        guard let item = store.messages.last else { return "0" }
        return "\(store.messages.count)|\(item.id)|\(item.text.utf8.count)|\(item.detail?.utf8.count ?? 0)"
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        if animated {
            withAnimation(.easeOut(duration: 0.22)) {
                proxy.scrollTo(bottomAnchor, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(bottomAnchor, anchor: .bottom)
        }
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private var connectionColor: Color {
        if store.socket.state == .connected, store.isSelectedThreadUpstreamRetrying { return .orange }
        switch store.socket.state {
        case .connected: return RelayTheme.accent
        case .connecting, .reconnecting: return .orange
        case .disconnected, .failed: return .secondary
        }
    }

    private var connectionLabel: String {
        switch store.socket.state {
        case .connected:
            return store.isSelectedThreadUpstreamRetrying ? "Codex 上游重连中" : store.host.name
        case .connecting: return "Connecting"
        case .reconnecting(let attempt): return "Reconnecting · \(attempt)"
        case .disconnected: return "Offline"
        case .failed: return "Connection lost"
        }
    }
}

private struct LoadingConversationView: View {
    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
            Text("Loading conversation")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
            Spacer().frame(height: 68)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct EmptyConversationView: View {
    @EnvironmentObject private var store: RelayStore

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            RelayMark(size: 52)
            VStack(spacing: 7) {
                Text("What should Codex work on?")
                    .font(.system(size: 22, weight: .semibold))
                    .multilineTextAlignment(.center)
                Text(projectLabel)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            Spacer()
            Spacer().frame(height: 68)
        }
        .padding(.horizontal, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var projectLabel: String {
        let directory = store.currentWorkingDirectory
        return directory.isEmpty ? "已连接到 \(store.host.name)" : directory.lastPathComponentForDisplay
    }
}

struct RelayMark: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(Color.primary)
            Image(systemName: "chevron.right")
                .font(.system(size: size * 0.34, weight: .bold))
                .foregroundStyle(RelayTheme.canvas)
                .offset(x: -size * 0.05)
            Capsule()
                .fill(RelayTheme.canvas)
                .frame(width: size * 0.24, height: max(2, size * 0.055))
                .offset(x: size * 0.19, y: size * 0.19)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
