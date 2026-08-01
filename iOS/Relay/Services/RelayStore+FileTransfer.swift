import Foundation

@MainActor
extension RelayStore {
    func addAttachments(_ urls: [URL]) {
        for url in urls {
            let id = UUID()
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            let size = Int64(values?.fileSize ?? 0)
            let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tiff"]
            attachments.append(PendingAttachment(
                id: id,
                name: url.lastPathComponent,
                localURL: url,
                size: size,
                progress: 0,
                state: .uploading,
                isImage: imageExtensions.contains(url.pathExtension.lowercased())
            ))
            let uploadTask = Task { [weak self] in
                guard let self else { return }
                defer {
                    self.attachmentUploadTasks.removeValue(forKey: id)
                    self.cleanupStagedAttachment(at: url)
                }
                do {
                    let uploaded = try await self.socket.uploadFile(url) { [weak self] progress in
                        guard let index = self?.attachments.firstIndex(where: { $0.id == id }) else { return }
                        self?.attachments[index].progress = progress
                    }
                    guard !Task.isCancelled,
                          let index = self.attachments.firstIndex(where: { $0.id == id }) else { return }
                    self.attachments[index].remotePath = uploaded.path
                    self.attachments[index].size = uploaded.size
                    self.attachments[index].progress = 1
                    self.attachments[index].state = .ready
                } catch {
                    guard !Task.isCancelled,
                          let index = attachments.firstIndex(where: { $0.id == id }) else { return }
                    attachments[index].state = .failed(error.localizedDescription)
                    errorMessage = "上传 \(attachments[index].name) 失败：\(error.localizedDescription)"
                }
            }
            attachmentUploadTasks[id] = uploadTask
        }
    }

    func removeAttachment(_ id: UUID) {
        let localURL = attachments.first(where: { $0.id == id })?.localURL
        attachmentUploadTasks.removeValue(forKey: id)?.cancel()
        attachments.removeAll { $0.id == id }
        if let localURL { cleanupStagedAttachment(at: localURL) }
    }

    func downloadFile(path: String) async {
        guard downloadingPath == nil else { return }
        downloadingPath = path
        defer { downloadingPath = nil }
        do {
            let url = try await socket.downloadFile(at: path) { _ in }
            sharedFile = SharedFile(url: url)
        } catch {
            report(error)
        }
    }

    func loadImagePreview(path: String) async {
        guard imagePreviewURLs[path] == nil, !loadingImagePaths.contains(path) else { return }
        loadingImagePaths.insert(path)
        defer { loadingImagePaths.remove(path) }
        do {
            imagePreviewURLs[path] = try await socket.downloadImage(at: path)
        } catch {
            // A missing preview should not interrupt the conversation. Tapping the placeholder retries it.
        }
    }

    func shareImagePreview(path: String) async {
        if imagePreviewURLs[path] == nil { await loadImagePreview(path: path) }
        guard let url = imagePreviewURLs[path] else {
            errorMessage = "图片暂时无法从 Windows 读取。"
            return
        }
        sharedFile = SharedFile(url: url)
    }

    private func cleanupStagedAttachment(at url: URL) {
        let temporaryRoot = FileManager.default.temporaryDirectory.standardizedFileURL.path
        let staged = url.standardizedFileURL
        guard staged.path.hasPrefix(temporaryRoot),
              (staged.path.contains("Relay Imports") || staged.path.contains("Relay Photos")) else { return }
        try? FileManager.default.removeItem(at: staged)
        let parent = staged.deletingLastPathComponent()
        if (try? FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty) == true {
            try? FileManager.default.removeItem(at: parent)
        }
    }
}
