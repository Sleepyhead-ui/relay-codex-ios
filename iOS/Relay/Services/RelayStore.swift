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
    @Published var isLoadingThread = false
    @Published var modelOptions: [CodexModelOption] = []
    @Published var selectedModelId = ""
    @Published var selectedEffort = ""
    @Published var turnMetadata: [String: TurnMetadata] = [:]
    @Published var tokenUsageByThread: [String: ThreadTokenUsage] = [:]
    @Published var isCompacting = false

    let socket = RelaySocket()
    private let hostDefaultsKey = "relay.host.configuration"
    private let modelDefaultsKey = "relay.model"
    private let effortDefaultsKey = "relay.reasoningEffort"
    private var activeTurnId: String?
    private var threadLoadGeneration = UUID()

    var needsConnection: Bool { host.endpoint.isEmpty || token.isEmpty }
    var selectedThread: ThreadSummary? { threads.first { $0.id == selectedThreadId } }
    var selectedModel: CodexModelOption? {
        modelOptions.first { $0.id == selectedModelId || $0.model == selectedModelId }
    }
    var availableEfforts: [ReasoningEffortOption] {
        let advertised = selectedModel?.efforts ?? []
        if !advertised.isEmpty { return advertised }
        return ["low", "medium", "high", "xhigh", "ultra"].compactMap {
            ReasoningEffortOption(json: .object([
                "reasoningEffort": .string($0),
                "description": .string("")
            ]))
        }
    }
    var currentTokenUsage: ThreadTokenUsage? {
        guard let selectedThreadId else { return nil }
        return tokenUsageByThread[selectedThreadId]
    }
    var transcriptGroups: [TranscriptGroup] {
        var groups: [TranscriptGroup] = []
        var indexes: [String: Int] = [:]
        for item in messages {
            let key = item.turnId.map { "turn.\($0)" } ?? "item.\(item.id)"
            if let index = indexes[key] {
                groups[index].items.append(item)
            } else {
                indexes[key] = groups.count
                groups.append(TranscriptGroup(
                    id: key,
                    turnId: item.turnId,
                    items: [item],
                    metadata: item.turnId.flatMap { turnMetadata[$0] } ?? TurnMetadata()
                ))
            }
        }
        return groups
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: hostDefaultsKey),
           let stored = try? JSONDecoder().decode(HostConfiguration.self, from: data) {
            host = stored
        }
        token = KeychainStore.loadToken() ?? ""
        selectedModelId = UserDefaults.standard.string(forKey: modelDefaultsKey) ?? ""
        selectedEffort = UserDefaults.standard.string(forKey: effortDefaultsKey) ?? ""

        socket.onConnected = { [weak self] in
            Task { await self?.handleConnectionRestored() }
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

    func disconnect() { socket.disconnect() }

    func applicationBecameActive() { socket.reconnectIfNeeded() }

    func forgetHost() {
        disconnect()
        KeychainStore.deleteToken()
        UserDefaults.standard.removeObject(forKey: hostDefaultsKey)
        token = ""
        host = HostConfiguration()
        threads = []
        selectedThreadId = nil
        messages = []
        turnMetadata = [:]
        tokenUsageByThread = [:]
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

    func refreshModels(showErrors: Bool = false) async {
        guard socket.state == .connected else { return }
        do {
            let result = try await socket.rpc(method: "model/list", params: [
                "limit": .number(100),
                "includeHidden": .bool(false)
            ])
            let models = result["data"]?.arrayValue?.compactMap(CodexModelOption.init(json:)) ?? []
            guard !models.isEmpty else { return }
            modelOptions = models
            if selectedModel == nil {
                let preferred = models.first(where: \.isDefault) ?? models.first
                selectedModelId = preferred?.model ?? ""
            }
            normalizeEffortForSelectedModel()
            persistGenerationSettings()
        } catch {
            report(error, show: showErrors)
        }
    }

    func refreshThreads(showErrors: Bool = true) async {
        guard socket.state == .connected else { return }
        do {
            let result = try await socket.rpc(method: "thread/list", params: [
                "limit": .number(50),
                "sortKey": .string("updated_at"),
                "sortDirection": .string("desc"),
                "useStateDbOnly": .bool(true)
            ])
            threads = result["data"]?.arrayValue?.compactMap(ThreadSummary.init(json:)) ?? []
        } catch {
            report(error, show: showErrors)
        }
    }

    func newThread() async {
        guard socket.state == .connected else {
            socket.reconnectIfNeeded()
            return
        }
        do {
            var params: [String: JSONValue] = [
                "approvalPolicy": .string("on-request"),
                "sandbox": .string("workspace-write"),
                "threadSource": .string("relay-ios")
            ]
            if !host.workingDirectory.isEmpty { params["cwd"] = .string(host.workingDirectory) }
            if let model = selectedModel?.model { params["model"] = .string(model) }
            let result = try await socket.rpc(method: "thread/start", params: params)
            guard let id = result["thread"]?["id"]?.stringValue else {
                throw RelaySocket.SocketError.remote("Codex did not return a thread id.")
            }
            selectedThreadId = id
            messages = []
            turnMetadata = [:]
            sidebarOpen = false
            if let model = result["model"]?.stringValue { selectedModelId = model }
            await applyThreadSettings(showErrors: false)
            await refreshThreads()
        } catch {
            report(error)
        }
    }

    func selectThread(_ id: String, closeSidebar: Bool = true, showErrors: Bool = true) async {
        let loadGeneration = UUID()
        threadLoadGeneration = loadGeneration
        selectedThreadId = id
        if closeSidebar { sidebarOpen = false }
        isLoadingThread = true
        defer {
            if threadLoadGeneration == loadGeneration { isLoadingThread = false }
        }

        do {
            let result = try await socket.rpc(method: "thread/resume", params: ["threadId": .string(id)])
            guard selectedThreadId == id, threadLoadGeneration == loadGeneration else { return }
            let turns = result["thread"]?["turns"]?.arrayValue ?? []
            var loadedMessages: [TranscriptItem] = []
            var loadedMetadata: [String: TurnMetadata] = [:]
            for turn in turns {
                guard let turnId = turn["id"]?.stringValue else { continue }
                loadedMetadata[turnId] = TurnMetadata(json: turn)
                loadedMessages.append(contentsOf: turn["items"]?.arrayValue?.compactMap {
                    TranscriptItem.from(json: $0, turnId: turnId)
                } ?? [])
            }
            messages = loadedMessages
            turnMetadata = loadedMetadata
            let status = result["thread"]?["status"]?["type"]?.stringValue ?? "idle"
            isRunning = status == "active"
            activeTurnId = turns.last(where: { $0["status"]?.stringValue == "inProgress" })?["id"]?.stringValue
            if let model = result["model"]?.stringValue { selectedModelId = model }
            if let effort = result["reasoningEffort"]?.stringValue { selectedEffort = effort }
            normalizeEffortForSelectedModel()
            persistGenerationSettings()
        } catch {
            guard selectedThreadId == id, threadLoadGeneration == loadGeneration else { return }
            report(error, show: showErrors)
        }
    }

    func sendPrompt() async {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard socket.state == .connected else {
            socket.reconnectIfNeeded()
            return
        }
        if selectedThreadId == nil { await newThread() }
        guard let threadId = selectedThreadId else { return }

        let clientMessageId = UUID().uuidString
        composerText = ""
        isRunning = true
        messages.append(TranscriptItem(id: clientMessageId, role: .user, kind: .message, text: text))
        do {
            var params: [String: JSONValue] = [
                "threadId": .string(threadId),
                "clientUserMessageId": .string(clientMessageId),
                "input": .array([.object(["type": .string("text"), "text": .string(text)])]),
                "summary": .string("detailed")
            ]
            if let model = selectedModel?.model { params["model"] = .string(model) }
            if !selectedEffort.isEmpty { params["effort"] = .string(selectedEffort) }
            let result = try await socket.rpc(method: "turn/start", params: params)
            activeTurnId = result["turn"]?["id"]?.stringValue
            if let activeTurnId {
                if let index = messages.firstIndex(where: { $0.id == clientMessageId }) {
                    messages[index].turnId = activeTurnId
                }
                turnMetadata[activeTurnId] = TurnMetadata(json: result["turn"] ?? .object([:]))
            }
        } catch {
            isRunning = false
            report(error)
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
            report(error)
        }
    }

    func selectModel(_ model: CodexModelOption) async {
        selectedModelId = model.model
        normalizeEffortForSelectedModel()
        persistGenerationSettings()
        await applyThreadSettings(showErrors: true)
    }

    func selectEffort(_ effort: String) async {
        selectedEffort = effort
        persistGenerationSettings()
        await applyThreadSettings(showErrors: true)
    }

    func compactContext() async {
        guard let threadId = selectedThreadId, !isCompacting else { return }
        isCompacting = true
        defer { isCompacting = false }
        do {
            _ = try await socket.rpc(method: "thread/compact/start", params: ["threadId": .string(threadId)])
        } catch {
            report(error)
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
            report(error)
        }
    }

    private func applyThreadSettings(showErrors: Bool) async {
        guard let threadId = selectedThreadId, socket.state == .connected else { return }
        var params: [String: JSONValue] = [
            "threadId": .string(threadId),
            "summary": .string("detailed")
        ]
        if let model = selectedModel?.model { params["model"] = .string(model) }
        if !selectedEffort.isEmpty { params["effort"] = .string(selectedEffort) }
        do {
            _ = try await socket.rpc(method: "thread/settings/update", params: params)
        } catch {
            report(error, show: showErrors)
        }
    }

    private func persistConnection() throws {
        guard !token.isEmpty else {
            throw RelaySocket.SocketError.remote("Enter the pairing token shown by Relay Bridge.")
        }
        let data = try JSONEncoder().encode(host)
        UserDefaults.standard.set(data, forKey: hostDefaultsKey)
        try KeychainStore.saveToken(token)
    }

    private func persistGenerationSettings() {
        UserDefaults.standard.set(selectedModelId, forKey: modelDefaultsKey)
        UserDefaults.standard.set(selectedEffort, forKey: effortDefaultsKey)
    }

    private func normalizeEffortForSelectedModel() {
        guard let model = selectedModel else { return }
        let ids = Set(model.efforts.map(\.id))
        if selectedEffort.isEmpty || (!ids.isEmpty && !ids.contains(selectedEffort)) {
            selectedEffort = model.defaultEffort
        }
    }

    private func handleEvent(method: String, params: JSONValue) {
        guard params["threadId"]?.stringValue == nil || params["threadId"]?.stringValue == selectedThreadId else { return }
        let eventTurnId = params["turnId"]?.stringValue ?? params["turn"]?["id"]?.stringValue
        switch method {
        case "turn/started":
            isRunning = true
            activeTurnId = params["turn"]?["id"]?.stringValue
            if let activeTurnId { turnMetadata[activeTurnId] = TurnMetadata(json: params["turn"] ?? .object([:])) }
        case "turn/completed":
            let turn = params["turn"] ?? .object([:])
            let turnId = turn["id"]?.stringValue ?? eventTurnId
            if let turnId {
                turnMetadata[turnId] = TurnMetadata(json: turn)
                for itemJSON in turn["items"]?.arrayValue ?? [] {
                    if let item = TranscriptItem.from(json: itemJSON, turnId: turnId) { upsert(item) }
                }
            }
            isRunning = false
            activeTurnId = nil
            Task { await refreshThreads(showErrors: false) }
        case "item/started", "item/completed":
            if let itemJSON = params["item"], let item = TranscriptItem.from(json: itemJSON, turnId: eventTurnId) { upsert(item) }
        case "item/agentMessage/delta":
            appendDelta(id: params["itemId"]?.stringValue, delta: params["delta"]?.stringValue, turnId: eventTurnId, role: .assistant, kind: .message)
        case "item/reasoning/summaryTextDelta", "item/reasoningSummaryText/delta":
            appendDelta(id: params["itemId"]?.stringValue, delta: params["delta"]?.stringValue, turnId: eventTurnId, role: .tool, kind: .reasoning, title: "思考")
        case "item/reasoning/textDelta":
            appendDetail(id: params["itemId"]?.stringValue, delta: params["delta"]?.stringValue, turnId: eventTurnId, kind: .reasoning)
        case "item/commandExecution/outputDelta":
            appendDetail(id: params["itemId"]?.stringValue, delta: params["delta"]?.stringValue, turnId: eventTurnId, kind: .command)
        case "turn/plan/updated":
            guard let turnId = eventTurnId else { break }
            let steps = params["plan"]?.arrayValue ?? []
            let markdown = steps.map { step -> String in
                let status = step["status"]?.stringValue ?? "pending"
                let marker = status == "completed" ? "[x]" : "[ ]"
                return "- \(marker) \(step["step"]?.stringValue ?? "")"
            }.joined(separator: "\n")
            upsert(TranscriptItem(id: "plan.\(turnId)", turnId: turnId, role: .tool, kind: .plan, title: "执行计划", text: markdown, status: isRunning ? "inProgress" : "completed"))
        case "thread/tokenUsage/updated":
            if let threadId = params["threadId"]?.stringValue, let usage = params["tokenUsage"] {
                tokenUsageByThread[threadId] = ThreadTokenUsage(json: usage)
            }
        case "thread/compacted":
            if let turnId = eventTurnId {
                upsert(TranscriptItem(id: "compaction.\(turnId)", turnId: turnId, role: .tool, kind: .contextCompaction, title: "已压缩上下文", text: "Codex 已整理较早的对话内容，为后续工作释放上下文空间。", status: "completed"))
            }
        case "thread/settings/updated":
            if let model = params["threadSettings"]?["model"]?.stringValue { selectedModelId = model }
            if let effort = params["threadSettings"]?["effort"]?.stringValue { selectedEffort = effort }
            persistGenerationSettings()
        case "error":
            errorMessage = params["error"]?["message"]?.stringValue ?? params["message"]?.stringValue ?? "Codex reported an error."
            isRunning = false
        default:
            break
        }
    }

    private func upsert(_ item: TranscriptItem) {
        if let index = messages.firstIndex(where: { $0.id == item.id }) {
            var replacement = item
            if replacement.turnId == nil { replacement.turnId = messages[index].turnId }
            messages[index] = replacement
        } else if item.role != .user || !messages.contains(where: { $0.role == .user && $0.text == item.text }) {
            messages.append(item)
        }
    }

    private func appendDelta(id: String?, delta: String?, turnId: String?, role: TranscriptRole, kind: TranscriptKind, title: String? = nil) {
        guard let id, let delta else { return }
        if let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index].text += delta
            if messages[index].turnId == nil { messages[index].turnId = turnId }
        } else {
            messages.append(TranscriptItem(id: id, turnId: turnId, role: role, kind: kind, title: title, text: delta))
        }
    }

    private func appendDetail(id: String?, delta: String?, turnId: String?, kind: TranscriptKind) {
        guard let id, let delta else { return }
        if let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index].detail = (messages[index].detail ?? "") + delta
            if messages[index].turnId == nil { messages[index].turnId = turnId }
        } else {
            messages.append(TranscriptItem(id: id, turnId: turnId, role: .tool, kind: kind, title: kind == .reasoning ? "思考" : "运行命令", text: "", detail: delta, status: "inProgress"))
        }
    }

    private func handleConnectionRestored() async {
        await refreshModels(showErrors: false)
        await refreshThreads(showErrors: false)
        if let selectedThreadId {
            await selectThread(selectedThreadId, closeSidebar: false, showErrors: false)
        }
    }

    private func report(_ error: Error, show shouldShow: Bool = true) {
        guard shouldShow, socket.state == .connected else { return }
        errorMessage = error.localizedDescription
    }
}
