import Foundation

@MainActor
final class RelayStore: ObservableObject {
    @Published var host = HostConfiguration()
    @Published var token = ""
    @Published var threads: [ThreadSummary] = []
    @Published var selectedThreadId: String?
    @Published var messages: [TranscriptItem] = []
    @Published var composerText = ""
    @Published var isRunning = false
    @Published var sidebarOpen = false
    @Published var showingConnection = false
    @Published var showingSettings = false
    @Published var pendingApproval: ApprovalRequest?
    @Published var errorMessage: String?

    let socket = RelaySocket()
    private let hostDefaultsKey = "relay.host.configuration"
    private var activeTurnId: String?

    var needsConnection: Bool { host.endpoint.isEmpty || token.isEmpty }
    var selectedThread: ThreadSummary? { threads.first { $0.id == selectedThreadId } }

    init() {
        if let data = UserDefaults.standard.data(forKey: hostDefaultsKey),
           let stored = try? JSONDecoder().decode(HostConfiguration.self, from: data) {
            host = stored
        }
        token = KeychainStore.loadToken() ?? ""

        socket.onConnected = { [weak self] in
            Task { await self?.refreshThreads() }
        }
        socket.onEvent = { [weak self] method, params in self?.handleEvent(method: method, params: params) }
        socket.onServerRequest = { [weak self] message in self?.pendingApproval = ApprovalRequest(message: message) }
    }

    func connect() {
        errorMessage = nil
        do {
            try persistConnection()
            try socket.connect(endpoint: host.endpoint, token: token)
            showingConnection = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func disconnect() {
        socket.disconnect()
    }

    func forgetHost() {
        disconnect()
        KeychainStore.deleteToken()
        UserDefaults.standard.removeObject(forKey: hostDefaultsKey)
        token = ""
        host = HostConfiguration()
        threads = []
        selectedThreadId = nil
        messages = []
        showingSettings = false
        showingConnection = true
    }

    func consumePairingURL(_ url: URL) {
        guard url.scheme == "relay", url.host == "connect",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            if let value = item.value { values[item.name] = value }
        }
        if let endpoint = values["url"] { host.endpoint = endpoint }
        if let pairingToken = values["token"] { token = pairingToken }
        showingConnection = true
    }

    func refreshThreads() async {
        guard socket.state == .connected else { return }
        do {
            let result = try await socket.rpc(method: "thread/list", params: [
                "limit": .number(50),
                "sortKey": .string("updated_at"),
                "sortDirection": .string("desc")
            ])
            threads = result["data"]?.arrayValue?.compactMap(ThreadSummary.init(json:)) ?? []
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func newThread() async {
        do {
            var params: [String: JSONValue] = [
                "approvalPolicy": .string("on-request"),
                "sandbox": .string("workspace-write")
            ]
            if !host.workingDirectory.isEmpty { params["cwd"] = .string(host.workingDirectory) }
            let result = try await socket.rpc(method: "thread/start", params: params)
            guard let id = result["thread"]?["id"]?.stringValue else { throw RelaySocket.SocketError.remote("Codex did not return a thread id.") }
            selectedThreadId = id
            messages = []
            sidebarOpen = false
            await refreshThreads()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectThread(_ id: String) async {
        selectedThreadId = id
        sidebarOpen = false
        do {
            let result = try await socket.rpc(method: "thread/read", params: [
                "threadId": .string(id),
                "includeTurns": .bool(true)
            ])
            let turns = result["thread"]?["turns"]?.arrayValue ?? []
            messages = turns.flatMap { turn in
                turn["items"]?.arrayValue?.compactMap(TranscriptItem.from(json:)) ?? []
            }
            let status = result["thread"]?["status"]?["type"]?.stringValue ?? "idle"
            isRunning = status == "active"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func sendPrompt() async {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if selectedThreadId == nil { await newThread() }
        guard let threadId = selectedThreadId else { return }

        composerText = ""
        isRunning = true
        messages.append(TranscriptItem(id: "local-\(UUID().uuidString)", role: .user, kind: .message, text: text))
        do {
            let result = try await socket.rpc(method: "turn/start", params: [
                "threadId": .string(threadId),
                "input": .array([.object(["type": .string("text"), "text": .string(text)])])
            ])
            activeTurnId = result["turn"]?["id"]?.stringValue
        } catch {
            isRunning = false
            errorMessage = error.localizedDescription
        }
    }

    func stopTurn() async {
        guard let threadId = selectedThreadId, let activeTurnId else { return }
        do {
            _ = try await socket.rpc(method: "turn/interrupt", params: [
                "threadId": .string(threadId),
                "turnId": .string(activeTurnId)
            ])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func resolveApproval(_ decision: String) async {
        guard let approval = pendingApproval else { return }
        do {
            let result: [String: JSONValue]
            if approval.method.contains("permissions") {
                result = [
                    "permissions": decision == "accept" ? (approval.requestedPermissions ?? .object([:])) : .object([:]),
                    "scope": .string("turn")
                ]
            } else {
                result = ["decision": .string(decision)]
            }
            try await socket.respond(to: approval.rpcId, result: result)
            pendingApproval = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func persistConnection() throws {
        guard !token.isEmpty else { throw RelaySocket.SocketError.remote("Enter the pairing token shown by Relay Bridge.") }
        let data = try JSONEncoder().encode(host)
        UserDefaults.standard.set(data, forKey: hostDefaultsKey)
        try KeychainStore.saveToken(token)
    }

    private func handleEvent(method: String, params: JSONValue) {
        guard params["threadId"]?.stringValue == nil || params["threadId"]?.stringValue == selectedThreadId else { return }
        switch method {
        case "turn/started":
            isRunning = true
            activeTurnId = params["turn"]?["id"]?.stringValue
        case "turn/completed":
            isRunning = false
            activeTurnId = nil
            Task { await refreshThreads() }
        case "item/started", "item/completed":
            if let itemJSON = params["item"], let item = TranscriptItem.from(json: itemJSON) { upsert(item) }
        case "item/agentMessage/delta":
            appendDelta(id: params["itemId"]?.stringValue, delta: params["delta"]?.stringValue, role: .assistant, kind: .message)
        case "item/reasoningSummaryText/delta":
            appendDelta(id: params["itemId"]?.stringValue, delta: params["delta"]?.stringValue, role: .tool, kind: .reasoning, title: "Reasoning")
        case "item/commandExecution/outputDelta":
            appendDetail(id: params["itemId"]?.stringValue, delta: params["delta"]?.stringValue)
        case "error":
            errorMessage = params["error"]?["message"]?.stringValue ?? params["message"]?.stringValue ?? "Codex reported an error."
            isRunning = false
        default:
            break
        }
    }

    private func upsert(_ item: TranscriptItem) {
        if let index = messages.firstIndex(where: { $0.id == item.id }) { messages[index] = item }
        else if item.role != .user || !messages.contains(where: { $0.role == .user && $0.text == item.text }) { messages.append(item) }
    }

    private func appendDelta(id: String?, delta: String?, role: TranscriptRole, kind: TranscriptKind, title: String? = nil) {
        guard let id, let delta else { return }
        if let index = messages.firstIndex(where: { $0.id == id }) { messages[index].text += delta }
        else { messages.append(TranscriptItem(id: id, role: role, kind: kind, title: title, text: delta)) }
    }

    private func appendDetail(id: String?, delta: String?) {
        guard let id, let delta, let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].detail = (messages[index].detail ?? "") + delta
    }
}
