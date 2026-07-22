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
            Task {
                do {
                    let uploaded = try await socket.uploadFile(url) { [weak self] progress in
                        guard let index = self?.attachments.firstIndex(where: { $0.id == id }) else { return }
                        self?.attachments[index].progress = progress
                    }
                    guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
                    attachments[index].remotePath = uploaded.path
                    attachments[index].size = uploaded.size
                    attachments[index].progress = 1
                    attachments[index].state = .ready
                } catch {
                    guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
                    attachments[index].state = .failed(error.localizedDescription)
                    errorMessage = "上传 \(attachments[index].name) 失败：\(error.localizedDescription)"
                }
            }
        }
    }

    func removeAttachment(_ id: UUID) {
        attachments.removeAll { $0.id == id }
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
}
