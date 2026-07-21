import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var store: RelayStore
    @State private var search = ""
    @State private var collapsedProjects = Set<String>()
    @State private var renamingThread: ThreadSummary?
    @State private var renameDraft = ""

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
                .accessibilityLabel("关闭侧栏")
            }
            .padding(.horizontal, 14)
            .frame(height: 62)

            Button {
                store.showingNewTask = true
                store.sidebarOpen = false
            } label: {
                HStack(spacing: 11) {
                    Image(systemName: "square.and.pencil")
                    Text("新任务")
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
                TextField("搜索任务或项目", text: $search)
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
                LazyVStack(alignment: .leading, spacing: 3) {
                    Text("项目")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 13)
                        .padding(.top, 19)
                        .padding(.bottom, 5)

                    ForEach(projectGroups) { group in
                        ProjectHeader(
                            group: group,
                            expanded: search.isEmpty ? !collapsedProjects.contains(group.id) : true
                        ) {
                            withAnimation(.easeOut(duration: 0.18)) {
                                if collapsedProjects.contains(group.id) {
                                    collapsedProjects.remove(group.id)
                                } else {
                                    collapsedProjects.insert(group.id)
                                }
                            }
                        }

                        if search.isEmpty ? !collapsedProjects.contains(group.id) : true {
                            ForEach(group.threads) { thread in
                                ThreadRow(
                                    thread: thread,
                                    selected: thread.id == store.selectedThreadId,
                                    running: store.isThreadRunning(thread.id),
                                    needsApproval: store.hasPendingApproval(threadId: thread.id),
                                    pinned: store.isThreadPinned(thread.id)
                                ) {
                                    Task { await store.selectThread(thread.id) }
                                }
                                .contextMenu {
                                    if !store.showingArchivedThreads {
                                        Button {
                                            store.toggleThreadPin(thread.id)
                                        } label: {
                                            Label(store.isThreadPinned(thread.id) ? "取消置顶" : "置顶", systemImage: store.isThreadPinned(thread.id) ? "pin.slash" : "pin")
                                        }
                                        Button {
                                            renameDraft = thread.title
                                            renamingThread = thread
                                        } label: {
                                            Label("重命名", systemImage: "pencil")
                                        }
                                        Button(role: .destructive) {
                                            Task { await store.archiveThread(thread.id) }
                                        } label: {
                                            Label("归档", systemImage: "archivebox")
                                        }
                                    } else {
                                        Button {
                                            Task { await store.unarchiveThread(thread.id) }
                                        } label: {
                                            Label("恢复任务", systemImage: "arrow.uturn.backward")
                                        }
                                    }
                                }
                                .padding(.leading, 15)
                            }
                        }
                    }

                    if projectGroups.isEmpty {
                        Text(search.isEmpty ? "暂无任务" : "没有匹配结果")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 12)
                    }
                }
                .padding(.horizontal, 7)
                .padding(.bottom, 12)
            }
            .refreshable { await store.refreshThreads() }

            Divider().opacity(0.55)
            Button {
                Task { await store.setShowingArchivedThreads(!store.showingArchivedThreads) }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: store.showingArchivedThreads ? "tray.full" : "archivebox")
                        .frame(width: 22)
                    Text(store.showingArchivedThreads ? "返回当前任务" : "已归档任务")
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 13)
                .frame(height: 38)
            }
            .buttonStyle(.plain)
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
        .alert("重命名任务", isPresented: Binding(
            get: { renamingThread != nil },
            set: { if !$0 { renamingThread = nil } }
        )) {
            TextField("任务名称", text: $renameDraft)
            Button("取消", role: .cancel) { renamingThread = nil }
            Button("保存") {
                guard let thread = renamingThread else { return }
                let name = renameDraft
                renamingThread = nil
                Task { await store.renameThread(thread.id, to: name) }
            }
        }
    }

    private var projectGroups: [ProjectGroup] {
        let matchingThreads = store.threads.filter { thread in
            search.isEmpty || thread.title.localizedCaseInsensitiveContains(search)
                || thread.cwd.localizedCaseInsensitiveContains(search)
                || thread.cwd.lastPathComponentForDisplay.localizedCaseInsensitiveContains(search)
        }
        let grouped = Dictionary(grouping: matchingThreads) { thread in
            thread.cwd.isEmpty ? "relay.no-project" : thread.cwd.normalizedWindowsPath
        }
        return grouped.map { id, threads in
            ProjectGroup(
                id: id,
                path: threads.first?.cwd ?? "",
                threads: threads.sorted { left, right in
                    let leftPinned = store.isThreadPinned(left.id)
                    let rightPinned = store.isThreadPinned(right.id)
                    return leftPinned == rightPinned ? left.updatedAt > right.updatedAt : leftPinned
                }
            )
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }
}

private struct ProjectGroup: Identifiable {
    let id: String
    let path: String
    let threads: [ThreadSummary]

    var name: String { path.isEmpty ? "未归类" : path.lastPathComponentForDisplay }
    var updatedAt: Date { threads.map(\.updatedAt).max() ?? .distantPast }
    var runningCount: Int { threads.filter(\.isRunning).count }
}

private struct ProjectHeader: View {
    let group: ProjectGroup
    let expanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 12)
                Image(systemName: "folder")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(group.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                if group.runningCount > 0 {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(RelayTheme.accent)
                        .accessibilityHidden(true)
                }
                Text("\(group.threads.count)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .frame(height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(group.name)，\(group.threads.count) 个任务")
        .accessibilityValue(group.path)
    }
}

private struct ThreadRow: View {
    let thread: ThreadSummary
    let selected: Bool
    let running: Bool
    let needsApproval: Bool
    let pinned: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if running {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(RelayTheme.accent)
                        .frame(width: 13, height: 13)
                        .transition(.scale.combined(with: .opacity))
                }
                if needsApproval {
                    Image(systemName: "exclamationmark.shield.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.orange)
                        .frame(width: 13, height: 13)
                }
                if pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 11, height: 13)
                }
                Text(thread.title)
                    .font(.system(size: 14, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(relativeDate)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? RelayTheme.softFill : .clear)
            .clipShape(RoundedRectangle(cornerRadius: RelayTheme.controlRadius))
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.18), value: running)
        .animation(.easeOut(duration: 0.18), value: needsApproval)
        .accessibilityValue(needsApproval ? "等待审批" : running ? "正在运行" : relativeDate)
    }

    private var relativeDate: String {
        RelativeDateTimeFormatter().localizedString(for: thread.updatedAt, relativeTo: Date())
    }
}
