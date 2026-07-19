import SwiftUI

struct NewTaskView: View {
    @EnvironmentObject private var store: RelayStore
    @Environment(\.dismiss) private var dismiss
    @State private var projectPath = ""
    @State private var newFolderName = ""
    @State private var isCreating = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 9) {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                        TextField("C:\\path\\to\\project", text: $projectPath)
                            .font(.system(size: 14, design: .monospaced))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    if !store.host.workingDirectory.isEmpty,
                       projectPath.normalizedWindowsPath != store.host.workingDirectory.normalizedWindowsPath {
                        Button("使用默认项目目录") {
                            projectPath = store.host.workingDirectory
                        }
                    }
                } header: {
                    Text("项目目录")
                } footer: {
                    Text("它决定命令的起始目录、相对路径和仓库上下文，不会限制“完全访问”模式可读取的其他文件。")
                }

                if !store.recentProjectDirectories.isEmpty {
                    Section("最近项目") {
                        ForEach(store.recentProjectDirectories.prefix(8), id: \.normalizedWindowsPath) { path in
                            Button {
                                projectPath = path
                            } label: {
                                HStack(spacing: 11) {
                                    Image(systemName: projectPath.normalizedWindowsPath == path.normalizedWindowsPath ? "checkmark.circle.fill" : "folder")
                                        .foregroundStyle(projectPath.normalizedWindowsPath == path.normalizedWindowsPath ? RelayTheme.accent : Color.secondary)
                                        .frame(width: 19)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(path.lastPathComponentForDisplay)
                                            .font(.system(size: 14, weight: .medium))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Text(path)
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                }
                            }
                        }
                    }
                }

                if !store.host.workingDirectory.isEmpty {
                    Section {
                        TextField("文件夹名称", text: $newFolderName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button {
                            Task { await createProjectAndStart() }
                        } label: {
                            HStack {
                                Label("创建并开始任务", systemImage: "folder.badge.plus")
                                Spacer()
                                if isCreating { ProgressView().controlSize(.small) }
                            }
                        }
                        .disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isCreating)
                    } header: {
                        Text("新建项目")
                    } footer: {
                        Text("在默认项目目录 \(store.host.workingDirectory.lastPathComponentForDisplay) 下创建一个子文件夹。")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(RelayTheme.canvas)
            .navigationTitle("新任务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("创建") {
                        Task { await startTask(at: projectPath) }
                    }
                    .fontWeight(.semibold)
                    .disabled(isCreating)
                }
            }
        }
        .onAppear {
            if projectPath.isEmpty { projectPath = store.currentWorkingDirectory }
        }
        .interactiveDismissDisabled(isCreating)
    }

    private func startTask(at path: String) async {
        isCreating = true
        defer { isCreating = false }
        if await store.newThread(workingDirectory: path) { dismiss() }
    }

    private func createProjectAndStart() async {
        isCreating = true
        defer { isCreating = false }
        guard let path = await store.createProjectFolder(named: newFolderName) else { return }
        projectPath = path
        if await store.newThread(workingDirectory: path) { dismiss() }
    }
}
