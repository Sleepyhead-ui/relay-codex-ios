import Foundation

@MainActor
final class RelaySocket: ObservableObject {
    enum State: Equatable {
        case disconnected
        case connecting
        case reconnecting(Int)
        case connected
        case failed(String)

        var isConnecting: Bool {
            switch self {
            case .connecting, .reconnecting: return true
            default: return false
            }
        }
    }

    enum SocketError: LocalizedError {
        case invalidEndpoint
        case disconnected
        case remote(String)

        var errorDescription: String? {
            switch self {
            case .invalidEndpoint: return "Enter a valid ws:// or wss:// address."
            case .disconnected: return "The Windows host is disconnected."
            case .remote(let message): return message
            }
        }
    }

    @Published private(set) var state: State = .disconnected
    @Published private(set) var desktopSyncMode = "unknown"
    var onConnected: (() -> Void)?
    var onBridgeStatus: ((JSONValue) -> Void)?
    var onEvent: ((String, JSONValue) -> Void)?
    var onSessionSnapshot: ((String, JSONValue) -> Void)?
    var onPromptQueueUpdated: ((String, JSONValue) -> Void)?
    var onServerRequest: ((JSONValue) -> Void)?
    var onServerRequestResolved: ((JSONValue) -> Void)?
    var onNonfatalError: ((String) -> Void)?

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var pending: [String: CheckedContinuation<JSONValue, Error>] = [:]
    private var pendingAccepted: [String: () -> Void] = [:]
    private var pendingAcceptanceTimeouts: [String: Task<Void, Never>] = [:]
    private var pendingTimeouts: [String: Task<Void, Never>] = [:]
    private var endpoint: String?
    private var token: String?
    private var shouldReconnect = false
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var stableConnectionTask: Task<Void, Never>?
    private var connectionTimeoutTask: Task<Void, Never>?
    private var connectionGeneration = UUID()

    func connect(endpoint: String, token: String) throws {
        guard let url = URL(string: endpoint), ["ws", "wss"].contains(url.scheme?.lowercased() ?? "") else {
            throw SocketError.invalidEndpoint
        }

        self.endpoint = url.absoluteString
        self.token = token
        shouldReconnect = true
        reconnectAttempt = 0
        openConnection()
    }

    func reconnectIfNeeded() {
        guard shouldReconnect, state != .connected else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        openConnection()
    }

    func disconnect() {
        shouldReconnect = false
        reconnectTask?.cancel()
        reconnectTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        stableConnectionTask?.cancel()
        stableConnectionTask = nil
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        failPending(with: SocketError.disconnected)
        state = .disconnected
    }

    func rpc(
        method: String,
        params: [String: JSONValue] = [:],
        timeoutSeconds: UInt64 = 45,
        reconnectOnTimeout: Bool = true,
        onAccepted: (() -> Void)? = nil
    ) async throws -> JSONValue {
        guard state == .connected, task != nil else { throw SocketError.disconnected }
        let id = UUID().uuidString
        let requestGeneration = connectionGeneration
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, Error>) in
            pending[id] = continuation
            if let onAccepted {
                pendingAccepted[id] = onAccepted
                pendingAcceptanceTimeouts[id] = Task { [weak self] in
                    do {
                        try await Task.sleep(nanoseconds: 8_000_000_000)
                    } catch {
                        return
                    }
                    guard let self, !Task.isCancelled,
                          self.pending.removeValue(forKey: id) != nil else { return }
                    self.pendingAccepted.removeValue(forKey: id)
                    self.pendingTimeouts.removeValue(forKey: id)?.cancel()
                    let error = SocketError.remote("Bridge 在 8 秒内没有确认收到消息。")
                    try? await self.send(["type": "rpcCancel", "id": id])
                    continuation.resume(throwing: error)
                    self.handleConnectionFailure(error, generation: requestGeneration)
                }
            }
            pendingTimeouts[id] = Task { [weak self] in
                do {
                    try await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                } catch {
                    return
                }
                guard let self, !Task.isCancelled,
                      let continuation = self.pending.removeValue(forKey: id) else { return }
                self.pendingAcceptanceTimeouts.removeValue(forKey: id)?.cancel()
                self.pendingAccepted.removeValue(forKey: id)
                self.pendingTimeouts.removeValue(forKey: id)
                let error = SocketError.remote(
                    reconnectOnTimeout
                        ? "Windows 长时间没有确认请求，Relay 正在重新连接。"
                        : "Windows 长时间没有完成请求，但连接仍保持。"
                )
                try? await self.send(["type": "rpcCancel", "id": id])
                continuation.resume(throwing: error)
                if reconnectOnTimeout {
                    self.handleConnectionFailure(error, generation: self.connectionGeneration)
                }
            }
            Task {
                do {
                    try await send([
                        "type": "rpc",
                        "id": id,
                        "method": method,
                        "params": JSONValue.object(params).rawValue
                    ])
                } catch {
                    pendingTimeouts.removeValue(forKey: id)?.cancel()
                    pendingAcceptanceTimeouts.removeValue(forKey: id)?.cancel()
                    pendingAccepted.removeValue(forKey: id)
                    pending.removeValue(forKey: id)?.resume(throwing: error)
                    self.handleConnectionFailure(error, generation: requestGeneration)
                }
            }
        }
    }

    func uploadFile(_ url: URL, progress: @escaping (Double) -> Void) async throws -> (path: String, size: Int64) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard fileSize <= 50 * 1024 * 1024 else {
            throw SocketError.remote("文件不能超过 50 MB。")
        }
        let started = try await rpc(method: "relay/file/upload/start", params: [
            "name": .string(url.lastPathComponent),
            "size": .number(Double(fileSize))
        ])
        guard let uploadId = started["uploadId"]?.stringValue else {
            throw SocketError.remote("Windows 未能开始接收文件。")
        }
        let chunkSize = started["chunkSize"]?.intValue ?? (512 * 1024)
        let handle = try FileHandle(forReadingFrom: url)
        var sentSize: Int64 = 0
        var index = 0
        do {
            while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
                _ = try await rpc(method: "relay/file/upload/chunk", params: [
                    "uploadId": .string(uploadId),
                    "index": .number(Double(index)),
                    "data": .string(chunk.base64EncodedString())
                ])
                sentSize += Int64(chunk.count)
                index += 1
                progress(fileSize == 0 ? 1 : min(1, Double(sentSize) / Double(fileSize)))
            }
            try handle.close()
            guard sentSize == fileSize else {
                throw SocketError.remote("文件在上传过程中发生了变化，请重新选择。")
            }
            let finished = try await rpc(method: "relay/file/upload/finish", params: ["uploadId": .string(uploadId)])
            guard let path = finished["path"]?.stringValue else {
                throw SocketError.remote("Windows 未返回上传文件的位置。")
            }
            progress(1)
            return (path, Int64(finished["size"]?.intValue ?? Int(sentSize)))
        } catch {
            try? handle.close()
            _ = try? await rpc(
                method: "relay/file/upload/cancel",
                params: ["uploadId": .string(uploadId)],
                timeoutSeconds: 4,
                reconnectOnTimeout: false
            )
            throw error
        }
    }

    func downloadFile(at remotePath: String, progress: @escaping (Double) -> Void) async throws -> URL {
        try await download(at: remotePath, startMethod: "relay/file/download/start", directoryName: "Relay Downloads", progress: progress)
    }

    func downloadImage(at remotePath: String) async throws -> URL {
        try await download(at: remotePath, startMethod: "relay/image/download/start", directoryName: "Relay Image Cache") { _ in }
    }

    private func download(
        at remotePath: String,
        startMethod: String,
        directoryName: String,
        progress: @escaping (Double) -> Void
    ) async throws -> URL {
        let started = try await rpc(method: startMethod, params: ["path": .string(remotePath)])
        guard let downloadId = started["downloadId"]?.stringValue else {
            throw SocketError.remote("Windows 未能开始发送文件。")
        }
        let name = started["name"]?.stringValue ?? URL(fileURLWithPath: remotePath).lastPathComponent
        let totalSize = Int64(started["size"]?.intValue ?? 0)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = startMethod == "relay/image/download/start"
            ? directory.appendingPathComponent(cacheFileName(for: remotePath, originalName: name))
            : uniqueFileURL(in: directory, name: name)
        let partial = directory.appendingPathComponent(".\(UUID().uuidString).partial")
        guard FileManager.default.createFile(atPath: partial.path, contents: nil) else {
            throw SocketError.remote("无法创建本地下载文件。")
        }
        let handle = try FileHandle(forWritingTo: partial)
        var receivedSize: Int64 = 0
        var index = 0
        var done = false
        do {
            while !done {
                let chunk = try await rpc(method: "relay/file/download/chunk", params: [
                    "downloadId": .string(downloadId),
                    "index": .number(Double(index))
                ])
                guard let encoded = chunk["data"]?.stringValue, let data = Data(base64Encoded: encoded) else {
                    throw SocketError.remote("收到的文件数据无效。")
                }
                try handle.write(contentsOf: data)
                receivedSize += Int64(data.count)
                done = chunk["done"]?.boolValue ?? false
                index += 1
                progress(totalSize == 0 ? 1 : min(1, Double(receivedSize) / Double(totalSize)))
            }
            guard receivedSize == totalSize else {
                throw SocketError.remote("下载内容不完整，请重试。")
            }
            try handle.close()
            if startMethod == "relay/image/download/start", FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: partial, to: destination)
            return destination
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: partial)
            _ = try? await rpc(
                method: "relay/file/download/cancel",
                params: ["downloadId": .string(downloadId)],
                timeoutSeconds: 4,
                reconnectOnTimeout: false
            )
            throw error
        }
    }

    private func cacheFileName(for remotePath: String, originalName: String) -> String {
        let hash = remotePath.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
        return "\(String(hash, radix: 16))-\(originalName)"
    }

    private func uniqueFileURL(in directory: URL, name: String) -> URL {
        let original = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: original.path) else { return original }
        let source = URL(fileURLWithPath: name)
        let base = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        for number in 2...999 {
            let candidateName = ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
            let candidate = directory.appendingPathComponent(candidateName)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return directory.appendingPathComponent("\(UUID().uuidString)-\(name)")
    }

    func respond(to id: JSONValue, result: [String: JSONValue]) async throws {
        try await send([
            "type": "serverResponse",
            "id": id.rawValue,
            "result": JSONValue.object(result).rawValue
        ])
    }

    private func openConnection() {
        guard let endpoint, let token, let url = URL(string: endpoint), shouldReconnect else { return }

        let generation = UUID()
        connectionGeneration = generation
        reconnectTask?.cancel()
        reconnectTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        stableConnectionTask?.cancel()
        stableConnectionTask = nil
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        failPending(with: SocketError.disconnected)

        state = reconnectAttempt == 0 ? .connecting : .reconnecting(reconnectAttempt)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        // A WebSocket is a long-lived resource. The previous 20-second
        // resource timeout closed healthy Tailscale connections shortly
        // after they became ready, leaving accepted prompts uncertain.
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        configuration.waitsForConnectivity = false
        let socketSession = URLSession(configuration: configuration)
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let socketTask = socketSession.webSocketTask(with: request)
        socketTask.maximumMessageSize = 32 * 1024 * 1024
        session = socketSession
        task = socketTask
        socketTask.resume()
        receiveNext(generation: generation)
        startConnectionTimeout(generation: generation)
    }

    private func send(_ object: [String: Any]) async throws {
        guard let task, state == .connected else { throw SocketError.disconnected }
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let text = String(data: data, encoding: .utf8) else { throw SocketError.remote("Could not encode request.") }
        try await task.send(.string(text))
    }

    private func receiveNext(generation: UUID) {
        guard let task, generation == connectionGeneration else { return }
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, generation == self.connectionGeneration else { return }
                switch result {
                case .success(let message):
                    do {
                        let data: Data
                        switch message {
                        case .string(let text): data = Data(text.utf8)
                        case .data(let value): data = value
                        @unknown default: throw SocketError.remote("Unsupported WebSocket message.")
                        }
                        try self.handle(data, generation: generation)
                    } catch {
                        self.onNonfatalError?("Ignored one invalid Bridge message: \(error.localizedDescription)")
                    }
                    self.receiveNext(generation: generation)
                case .failure(let error):
                    self.handleConnectionFailure(error, generation: generation)
                }
            }
        }
    }

    private func handle(_ data: Data, generation: UUID) throws {
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = raw["type"] as? String else { return }
        let message = JSONValue(any: raw)

        switch type {
        case "bridgeStatus":
            connectionTimeoutTask?.cancel()
            connectionTimeoutTask = nil
            let status = raw["status"] as? String
            onBridgeStatus?(message)
            if let desktopSync = raw["desktopSync"] as? [String: Any], let mode = desktopSync["mode"] as? String {
                desktopSyncMode = mode
            } else if let enabled = raw["desktopSync"] as? Bool {
                desktopSyncMode = enabled ? "deep-link" : "off"
            }
            if status == "ready" {
                let becameConnected = state != .connected
                state = .connected
                if becameConnected {
                    startHeartbeat(generation: generation)
                    markConnectionStable(after: 10, generation: generation)
                    onConnected?()
                }
            } else if status == "codexExited" {
                onNonfatalError?("Codex App Server stopped on Windows. Relay will keep the connection and retry when it is available.")
            }
        case "rpcAccepted":
            guard let id = raw["id"] as? String else { return }
            pendingAcceptanceTimeouts.removeValue(forKey: id)?.cancel()
            pendingAccepted.removeValue(forKey: id)?()
        case "rpcResult":
            guard let id = raw["id"] as? String, let continuation = pending.removeValue(forKey: id) else { return }
            pendingAcceptanceTimeouts.removeValue(forKey: id)?.cancel()
            pendingAccepted.removeValue(forKey: id)
            pendingTimeouts.removeValue(forKey: id)?.cancel()
            if let error = raw["error"] as? [String: Any] {
                continuation.resume(throwing: SocketError.remote(error["message"] as? String ?? "Codex request failed."))
            } else {
                continuation.resume(returning: JSONValue(any: raw["result"] ?? NSNull()))
            }
        case "event":
            if let method = raw["method"] as? String { onEvent?(method, message["params"] ?? .object([:])) }
        case "sessionSnapshot":
            if let threadId = raw["threadId"] as? String {
                onSessionSnapshot?(threadId, message["snapshot"] ?? .object([:]))
            }
        case "promptQueueUpdated":
            if let threadId = raw["threadId"] as? String {
                onPromptQueueUpdated?(threadId, message)
            }
        case "serverRequest":
            onServerRequest?(message)
        case "serverRequestResolved":
            onServerRequestResolved?(message)
        case "bridgeError":
            onNonfatalError?(raw["message"] as? String ?? "Bridge reported an error.")
        default:
            break
        }
    }

    private func markConnectionStable(after seconds: UInt64, generation: UUID) {
        stableConnectionTask?.cancel()
        stableConnectionTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            } catch {
                return
            }
            guard let self, !Task.isCancelled,
                  generation == self.connectionGeneration,
                  self.state == .connected,
                  self.task != nil else { return }
            self.reconnectAttempt = 0
            self.stableConnectionTask = nil
        }
    }

    private func startHeartbeat(generation: UUID) {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 15_000_000_000)
                } catch {
                    return
                }
                guard let self, generation == self.connectionGeneration,
                      let currentTask = self.task, self.state == .connected else { return }
                currentTask.sendPing { [weak self] error in
                    guard let error else { return }
                    Task { @MainActor in
                        self?.handleConnectionFailure(error, generation: generation)
                    }
                }
            }
        }
    }

    private func startConnectionTimeout(generation: UUID) {
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 12_000_000_000)
            } catch {
                return
            }
            guard let self, !Task.isCancelled,
                  generation == self.connectionGeneration,
                  self.state != .connected else { return }
            self.handleConnectionFailure(SocketError.remote("Connection timed out."), generation: generation)
        }
    }

    private func handleConnectionFailure(_ error: Error, generation: UUID) {
        guard generation == connectionGeneration else { return }
        heartbeatTask?.cancel()
        heartbeatTask = nil
        stableConnectionTask?.cancel()
        stableConnectionTask = nil
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        failPending(with: error)

        if shouldReconnect {
            scheduleReconnect()
        } else {
            state = .disconnected
        }
    }

    private func scheduleReconnect(immediate: Bool = false) {
        guard shouldReconnect, reconnectTask == nil else { return }
        reconnectAttempt += 1
        let attempt = reconnectAttempt
        let delay = immediate ? 0.0 : min(pow(1.7, Double(max(0, attempt - 1))), 8.0)
        state = .reconnecting(attempt)

        reconnectTask = Task { [weak self] in
            if delay > 0 {
                do {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } catch {
                    return
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.reconnectTask = nil
            self.openConnection()
        }
    }

    private func failPending(with error: Error) {
        let timeouts = pendingTimeouts.values
        pendingTimeouts.removeAll()
        timeouts.forEach { $0.cancel() }
        let continuations = pending.values
        pending.removeAll()
        pendingAcceptanceTimeouts.values.forEach { $0.cancel() }
        pendingAcceptanceTimeouts.removeAll()
        pendingAccepted.removeAll()
        continuations.forEach { $0.resume(throwing: error) }
    }
}
