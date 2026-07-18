import Foundation

@MainActor
final class RelaySocket: ObservableObject {
    enum State: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)
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

    func connect(endpoint: String, token: String) throws {
        disconnect()
        guard let url = URL(string: endpoint), ["ws", "wss"].contains(url.scheme?.lowercased() ?? "") else {
            throw SocketError.invalidEndpoint
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        state = .connecting
        let socketTask = URLSession.shared.webSocketTask(with: request)
        task = socketTask
        socketTask.resume()
        receiveNext()
    }

    func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        failPending(with: SocketError.disconnected)
        state = .disconnected
    }

    func rpc(method: String, params: [String: JSONValue] = [:]) async throws -> JSONValue {
        guard task != nil else { throw SocketError.disconnected }
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

    private func send(_ object: [String: Any]) async throws {
        guard let task else { throw SocketError.disconnected }
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let text = String(data: data, encoding: .utf8) else { throw SocketError.remote("Could not encode request.") }
        try await task.send(.string(text))
    }

    private func receiveNext() {
        guard let task else { return }
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let message):
                    do {
                        let data: Data
                        switch message {
                        case .string(let text): data = Data(text.utf8)
                        case .data(let value): data = value
                        @unknown default: throw SocketError.remote("Unsupported WebSocket message.")
                        }
                        try self.handle(data)
                        self.receiveNext()
                    } catch {
                        self.state = .failed(error.localizedDescription)
                    }
                case .failure(let error):
                    self.state = .failed(error.localizedDescription)
                    self.task = nil
                    self.failPending(with: error)
                }
            }
        }
    }

    private func handle(_ data: Data) throws {
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = raw["type"] as? String else { return }
        let message = JSONValue(any: raw)

        switch type {
        case "bridgeStatus":
            let status = raw["status"] as? String
            if status == "ready" {
                let wasConnected = state == .connected
                state = .connected
                if !wasConnected { onConnected?() }
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

    private func failPending(with error: Error) {
        let continuations = pending.values
        pending.removeAll()
        continuations.forEach { $0.resume(throwing: error) }
    }
}
