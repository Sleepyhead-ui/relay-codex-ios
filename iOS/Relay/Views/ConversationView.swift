import SwiftUI

struct ConversationView: View {
    @EnvironmentObject private var store: RelayStore

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider().opacity(0.55)
            transcript
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { ComposerView() }
        .background(RelayTheme.canvas)
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
                    .frame(width: 28, height: 42)
            }

            Button {
                Task { await store.newThread() }
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
                ScrollView {
                    LazyVStack(spacing: 24) {
                        ForEach(store.messages) { item in
                            TranscriptRow(item: item)
                                .id(item.id)
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                        if store.isRunning {
                            WorkingIndicator()
                                .id("working")
                        }
                    }
                    .frame(maxWidth: RelayTheme.contentWidth)
                    .padding(.horizontal, RelayTheme.horizontalPadding)
                    .padding(.top, 24)
                    .padding(.bottom, 18)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: store.messages) { _ in
                    withAnimation(.easeOut(duration: 0.22)) {
                        if store.isRunning { proxy.scrollTo("working", anchor: .bottom) }
                        else if let lastId = store.messages.last?.id { proxy.scrollTo(lastId, anchor: .bottom) }
                    }
                }
            }
        }
    }

    private var connectionColor: Color {
        switch store.socket.state {
        case .connected: return RelayTheme.accent
        case .connecting, .reconnecting: return .orange
        case .disconnected, .failed: return .secondary
        }
    }

    private var connectionLabel: String {
        switch store.socket.state {
        case .connected: return store.host.name
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
                Text(store.host.workingDirectory.isEmpty ? "Connected to \(store.host.name)" : store.host.workingDirectory)
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

private struct WorkingIndicator: View {
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(RelayTheme.accent)
                .frame(width: 8, height: 8)
                .scaleEffect(pulse ? 1 : 0.65)
                .opacity(pulse ? 1 : 0.45)
            Text("Working")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}
