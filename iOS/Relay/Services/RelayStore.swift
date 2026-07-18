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
    @Published var attachments: [PendingAttachment] = []
    @Published var workspaceAccess: WorkspaceAccessMode = .workspaceWrite
    @Published var sharedFile: SharedFile?
    @Published var downloadingPath: String?
    @Published var activePlan: [ExecutionPlanStep] = []

    let socket = RelaySocket()
    private let hostDefaultsKey = "relay.host.configuration"
    private let modelDefaultsKey = "relay.model"
    private let effortDefaultsKey = "relay.reasoningEffort"
    private let accessDefaultsKey = "relay.workspaceAccess"
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
        if let storedAccess = UserDefaults.standard.string(forKey: accessDefaultsKey),
           let access = WorkspaceAccessMode(rawValue: storedAccess) {
            workspaceAccess = access
        }

        socket.onConnected = { [weak self] in
            Task { await self?.handleConnectionRestored() }
        }
        socket.onEvent = { [weak self] method, params in self?.handleEvent(method: method, params: params) }
        socket.onServerRequest = { [weak self] message in self?.pendingApproval = ApprovalRequest(message: message) }
        socket.onNonfatalError = { [weak self] message in self?.errorMessage = message }
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
            activePlan = []
            var params: [String: JSONValue] = [
                "approvalPolicy": .string("on-request"),
                "sandbox": .string(workspaceAccess.threadSandbox),
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
        activePlan = []
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
            activeTurnId = turns.last(where: { self.isActiveStatus($0["status"]?.stringValue) })?["id"]?.stringValue
            isRunning = isActiveStatus(status) || activeTurnId != nil
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
        let readyAttachments = attachments.filter { $0.state == .ready && $0.remotePath != nil }
        guard !text.isEmpty || !readyAttachments.isEmpty else { return }
        guard socket.state == .connected else {
            socket.reconnectIfNeeded()
            return
        }
        if selectedThreadId == nil { await newThread() }
        guard let threadId = selectedThreadId else { return }

        let clientMessageId = UUID().uuidString
        activePlan = []
        composerText = ""
        attachments = []
        isRunning = true
        let attachmentSummary = readyAttachments.map { "📎 \($0.name)" }.joined(separator: "\n")
        let displayText = [text, attachmentSummary].filter { !$0.isEmpty }.joined(separator: "\n\n")
        messages.append(TranscriptItem(id: clientMessageId, role: .user, kind: .message, text: displayText))
        do {
            var input: [JSONValue] = []
            if !text.isEmpty { input.append(.object(["type": .string("text"), "text": .string(text)])) }
            for attachment in readyAttachments {
                guard let path = attachment.remotePath else { continue }
                if attachment.isImage {
                    input.append(.object(["type": .string("localImage"), "path": .string(path)]))
                } else {
                    input.append(.object(["type": .string("mention"), "name": .string(attachment.name), "path": .string(path)]))
                }
            }
            var params: [String: JSONValue] = [
                "threadId": .string(threadId),
                "clientUserMessageId": .string(clientMessageId),
                "input": .array(input),
                "summary": .string("detailed"),
                "sandboxPolicy": workspaceAccess.sandboxPolicy(workingDirectory: host.workingDirectory)
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
            // A lost RPC response does not prove the Windows turn stopped. Keep the
            // stop control visible until thread/resume confirms the real state.
            if socket.state == .connected { isRunning = false }
            attachments = readyAttachments
            report(error)
        }
    }

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

    func selectWorkspaceAccess(_ access: WorkspaceAccessMode) async {
        workspaceAccess = access
        UserDefaults.standard.set(access.rawValue, forKey: accessDefaultsKey)
        await applyThreadSettings(showErrors: true)
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
            "summary": .string("detailed"),
            "sandboxPolicy": workspaceAccess.sandboxPolicy(workingDirectory: host.workingDirectory)
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
            activePlan = []
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
            let completedActiveTurn = activeTurnId == nil || turnId == activeTurnId
            if completedActiveTurn {
                isRunning = false
                activeTurnId = nil
                activePlan = []
            }
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
            activePlan = steps.enumerated().compactMap { index, step in
                guard let text = step["step"]?.stringValue, !text.isEmpty else { return nil }
                return ExecutionPlanStep(
                    id: "\(turnId).\(index)",
                    text: text,
                    status: step["status"]?.stringValue ?? "pending"
                )
            }
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

    private func isActiveStatus(_ status: String?) -> Bool {
        let normalized = status?
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .lowercased() ?? ""
        return ["active", "inprogress", "running"].contains(normalized)
    }

    private func report(_ error: Error, show shouldShow: Bool = true) {
        guard shouldShow, socket.state == .connected else { return }
        errorMessage = error.localizedDescription
    }
}
