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
    var onConnected: (() -> Void)?
    var onEvent: ((String, JSONValue) -> Void)?
    var onServerRequest: ((JSONValue) -> Void)?

    private var task: URLSessionWebSocketTask?
    private var pending: [String: CheckedContinuation<JSONValue, Error>] = [:]
    private var endpoint: String?
    private var token: String?
    private var shouldReconnect = false
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
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
        guard shouldReconnect, task == nil else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        scheduleReconnect(immediate: true)
    }

    func disconnect() {
        shouldReconnect = false
        reconnectTask?.cancel()
        reconnectTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        failPending(with: SocketError.disconnected)
        state = .disconnected
    }

    func rpc(method: String, params: [String: JSONValue] = [:]) async throws -> JSONValue {
        guard state == .connected, task != nil else { throw SocketError.disconnected }
        let id = UUID().uuidString
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, Error>) in
            pending[id] = continuation
            Task {
                do {
                    try await send([
                        "type": "rpc",
                        "id": id,
                        "method": method,
                        "params": JSONValue.object(params).rawValue
                    ])
                } catch {
                    pending.removeValue(forKey: id)?.resume(throwing: error)
                }
            }
        }
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

        reconnectTask?.cancel()
        reconnectTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        failPending(with: SocketError.disconnected)

        let generation = UUID()
        connectionGeneration = generation
        state = reconnectAttempt == 0 ? .connecting : .reconnecting(reconnectAttempt)

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let socketTask = URLSession.shared.webSocketTask(with: request)
        task = socketTask
        socketTask.resume()
        receiveNext(generation: generation)
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
                        self.receiveNext(generation: generation)
                    } catch {
                        self.handleConnectionFailure(error, generation: generation)
                    }
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
            let status = raw["status"] as? String
            if status == "ready" {
                reconnectAttempt = 0
                state = .connected
                startHeartbeat(generation: generation)
                onConnected?()
            } else if status == "codexExited" {
                throw SocketError.remote("Codex App Server stopped on Windows.")
            }
        case "rpcResult":
            guard let id = raw["id"] as? String, let continuation = pending.removeValue(forKey: id) else { return }
            if let error = raw["error"] as? [String: Any] {
                continuation.resume(throwing: SocketError.remote(error["message"] as? String ?? "Codex request failed."))
            } else {
                continuation.resume(returning: JSONValue(any: raw["result"] ?? NSNull()))
            }
        case "event":
            if let method = raw["method"] as? String { onEvent?(method, message["params"] ?? .object([:])) }
        case "serverRequest":
            onServerRequest?(message)
        case "bridgeError":
            throw SocketError.remote(raw["message"] as? String ?? "Bridge error.")
        default:
            break
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

    private func handleConnectionFailure(_ error: Error, generation: UUID) {
        guard generation == connectionGeneration else { return }
        heartbeatTask?.cancel()
        heartbeatTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
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
        let delay = immediate ? 0.0 : min(pow(2.0, Double(max(0, attempt - 1))), 20.0)
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
        let continuations = pending.values
        pending.removeAll()
        continuations.forEach { $0.resume(throwing: error) }
    }
}
