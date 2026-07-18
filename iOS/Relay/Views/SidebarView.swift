import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var store: RelayStore
    @State private var search = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                RelayMark(size: 30)
                Text("Relay")
                    .font(.system(size: 19, weight: .semibold))
                Spacer()
                Button {
                    withAnimation { store.sidebarOpen = false }
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 16, weight: .medium))
                }
                .relayIconButton()
                .accessibilityLabel("Close sidebar")
            }
            .padding(.horizontal, 14)
            .frame(height: 62)

            Button {
                Task { await store.newThread() }
            } label: {
                HStack(spacing: 11) {
                    Image(systemName: "square.and.pencil")
                    Text("New task")
                        .font(.system(size: 15, weight: .medium))
                    Spacer()
                }
                .padding(.horizontal, 13)
                .frame(height: 44)
                .background(RelayTheme.elevated)
                .clipShape(RoundedRectangle(cornerRadius: RelayTheme.controlRadius))
                .overlay { RoundedRectangle(cornerRadius: RelayTheme.controlRadius).stroke(RelayTheme.hairline) }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(RelayTheme.softFill)
            .clipShape(RoundedRectangle(cornerRadius: RelayTheme.controlRadius))
            .padding(.horizontal, 12)
            .padding(.top, 10)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    Text("Conversations")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 13)
                        .padding(.top, 19)
                        .padding(.bottom, 7)

                    ForEach(filteredThreads) { thread in
                        ThreadRow(thread: thread, selected: thread.id == store.selectedThreadId) {
                            Task { await store.selectThread(thread.id) }
                        }
                    }
                }
                .padding(.horizontal, 7)
            }
            .refreshable { await store.refreshThreads() }

            Divider().opacity(0.55)
            Button {
                store.showingSettings = true
                store.sidebarOpen = false
            } label: {
                HStack(spacing: 11) {
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 15))
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.host.name)
                            .font(.system(size: 14, weight: .medium))
                        Text(store.host.endpoint)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Circle()
                        .fill(store.socket.state == .connected ? RelayTheme.accent : (store.socket.state.isConnecting ? Color.orange : Color.secondary))
                        .frame(width: 7, height: 7)
                }
                .padding(.horizontal, 13)
                .frame(height: 58)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RelayTheme.sidebar.ignoresSafeArea())
    }

    private var filteredThreads: [ThreadSummary] {
        guard !search.isEmpty else { return store.threads }
        return store.threads.filter {
            $0.title.localizedCaseInsensitiveContains(search) || $0.cwd.localizedCaseInsensitiveContains(search)
        }
    }
}

private struct ThreadRow: View {
    let thread: ThreadSummary
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(thread.title)
                        .font(.system(size: 14, weight: selected ? .semibold : .regular))
                        .lineLimit(1)
                    Spacer()
                    Text(relativeDate)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                HStack(spacing: 5) {
                    Image(systemName: "folder")
                        .font(.system(size: 9))
                    Text(thread.cwd.lastPathComponentForDisplay)
                        .lineLimit(1)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? RelayTheme.softFill : .clear)
            .clipShape(RoundedRectangle(cornerRadius: RelayTheme.controlRadius))
        }
        .buttonStyle(.plain)
    }

    private var relativeDate: String {
        RelativeDateTimeFormatter().localizedString(for: thread.updatedAt, relativeTo: Date())
    }
}
