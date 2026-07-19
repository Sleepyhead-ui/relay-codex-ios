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
    @Published var showingNewTask = false
    @Published var pendingApproval: ApprovalRequest?
    @Published var errorMessage: String?
    @Published var isLoadingThread = false
    @Published var isLoadingOlderTurns = false
    @Published var hasOlderTurns = false
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
    @Published var followUpBehavior: FollowUpBehavior = .steer
    @Published var queuedFollowUps: [QueuedFollowUp] = []
    @Published private(set) var activeTurnIdsByThread: [String: String] = [:]
    @Published private(set) var sendingThreadIds = Set<String>()

    let socket = RelaySocket()
    private let hostDefaultsKey = "relay.host.configuration"
    private let modelDefaultsKey = "relay.model"
    private let effortDefaultsKey = "relay.reasoningEffort"
    private let accessDefaultsKey = "relay.workspaceAccess"
    private let lastThreadDefaultsKey = "relay.lastThreadId"
    private let threadCacheDefaultsKey = "relay.cachedThreads"
    private let followUpDefaultsKey = "relay.followUpBehavior"
    private var activeTurnId: String?
    private var threadLoadGeneration = UUID()
    private var reconcilingThreadId: String?
    private var queuedEvents: [(method: String, params: JSONValue)] = []
    private var threadSnapshots: [String: ThreadSnapshot] = [:]
    private var olderTurnsCursorByThread: [String: String] = [:]
    private var workingDirectoryOverrides: [String: String] = [:]
    private var acceptedMessageIds = Set<String>()
    private var outboundDrafts: [String: OutboundDraft] = [:]
    private var completedTurnIds = Set<String>()
    private var restorationTask: Task<Void, Never>?

    var needsConnection: Bool { host.endpoint.isEmpty || token.isEmpty }
    var selectedThread: ThreadSummary? { threads.first { $0.id == selectedThreadId } }
    var isSendingPrompt: Bool {
        guard let selectedThreadId else { return false }
        return sendingThreadIds.contains(selectedThreadId)
    }
    var currentQueuedFollowUps: [QueuedFollowUp] {
        guard let selectedThreadId else { return [] }
        return queuedFollowUps.filter { $0.threadId == selectedThreadId }
    }
    var currentWorkingDirectory: String {
        if let cwd = selectedThread?.cwd.nonEmpty { return cwd }
        if let selectedThreadId, let cwd = workingDirectoryOverrides[selectedThreadId]?.nonEmpty { return cwd }
        return host.workingDirectory
    }
    var recentProjectDirectories: [String] {
        var seen = Set<String>()
        return threads.compactMap { thread in
            let path = thread.cwd.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty, seen.insert(path.normalizedWindowsPath).inserted else { return nil }
            return path
        }
    }
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
        if let data = UserDefaults.standard.data(forKey: threadCacheDefaultsKey),
           let cachedThreads = try? JSONDecoder().decode([ThreadSummary].self, from: data) {
            threads = cachedThreads
        }
        selectedThreadId = UserDefaults.standard.string(forKey: lastThreadDefaultsKey)
        selectedModelId = UserDefaults.standard.string(forKey: modelDefaultsKey) ?? ""
        selectedEffort = UserDefaults.standard.string(forKey: effortDefaultsKey) ?? ""
        if let storedAccess = UserDefaults.standard.string(forKey: accessDefaultsKey),
           let access = WorkspaceAccessMode(rawValue: storedAccess) {
            workspaceAccess = access
        }
        if let storedFollowUp = UserDefaults.standard.string(forKey: followUpDefaultsKey),
           let behavior = FollowUpBehavior(rawValue: storedFollowUp) {
            followUpBehavior = behavior
        }

        socket.onConnected = { [weak self] in
            self?.scheduleRestoration()
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

    func applicationBecameActive() {
        if socket.state == .connected {
            scheduleRestoration()
        } else {
            socket.reconnectIfNeeded()
        }
    }

    func forgetHost() {
        restorationTask?.cancel()
        restorationTask = nil
        disconnect()
        KeychainStore.deleteToken()
        UserDefaults.standard.removeObject(forKey: hostDefaultsKey)
        token = ""
        host = HostConfiguration()
        threads = []
        UserDefaults.standard.removeObject(forKey: threadCacheDefaultsKey)
        setSelectedThread(nil)
        messages = []
        turnMetadata = [:]
        tokenUsageByThread = [:]
        activeTurnIdsByThread = [:]
        sendingThreadIds = []
        queuedFollowUps = []
        acceptedMessageIds = []
        outboundDrafts = [:]
        completedTurnIds = []
        threadSnapshots = [:]
        olderTurnsCursorByThread = [:]
        hasOlderTurns = false
        workingDirectoryOverrides = [:]
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
                "limit": .number(200),
                "sortKey": .string("updated_at"),
                "sortDirection": .string("desc"),
                "useStateDbOnly": .bool(true)
            ])
            var fetched = result["data"]?.arrayValue?.compactMap(ThreadSummary.init(json:)) ?? []
            if fetched.isEmpty, !threads.isEmpty {
                return
            }
            for index in fetched.indices where activeTurnIdsByThread[fetched[index].id] != nil {
                fetched[index].status = "active"
            }
            threads = fetched
            persistThreadCache()
        } catch {
            report(error, show: showErrors)
        }
    }

    @discardableResult
    func newThread(workingDirectory: String? = nil) async -> Bool {
        guard socket.state == .connected else {
            socket.reconnectIfNeeded()
            return false
        }
        do {
            activePlan = []
            let projectDirectory = (workingDirectory ?? host.workingDirectory)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var params: [String: JSONValue] = [
                "approvalPolicy": .string("on-request"),
                "sandbox": .string(workspaceAccess.threadSandbox),
                "threadSource": .string("relay-ios")
            ]
            if !projectDirectory.isEmpty { params["cwd"] = .string(projectDirectory) }
            if let model = selectedModel?.model { params["model"] = .string(model) }
            let result = try await socket.rpc(method: "thread/start", params: params)
            guard let id = result["thread"]?["id"]?.stringValue else {
                throw RelaySocket.SocketError.remote("Codex did not return a thread id.")
            }
            cacheCurrentThread()
            setSelectedThread(id)
            hasOlderTurns = false
            if let summary = ThreadSummary(json: result["thread"] ?? .object([:])) {
                threads.removeAll { $0.id == summary.id }
                threads.insert(summary, at: 0)
                persistThreadCache()
            }
            if !projectDirectory.isEmpty { workingDirectoryOverrides[id] = projectDirectory }
            messages = []
            turnMetadata = [:]
            isRunning = false
            activeTurnId = nil
            sidebarOpen = false
            if let model = result["model"]?.stringValue { selectedModelId = model }
            await applyThreadSettings(showErrors: false)
            await refreshThreads()
            return true
        } catch {
            report(error)
            return false
        }
    }

    func createProjectFolder(named name: String) async -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            let result = try await socket.rpc(method: "relay/project/create", params: ["name": .string(trimmed)])
            return result["path"]?.stringValue
        } catch {
            report(error)
            return nil
        }
    }

    func saveHostConfiguration() {
        guard let data = try? JSONEncoder().encode(host) else { return }
        UserDefaults.standard.set(data, forKey: hostDefaultsKey)
    }

    func isThreadRunning(_ threadId: String) -> Bool {
        activeTurnIdsByThread[threadId] != nil || threads.first(where: { $0.id == threadId })?.isRunning == true
    }

    func selectFollowUpBehavior(_ behavior: FollowUpBehavior) {
        followUpBehavior = behavior
        UserDefaults.standard.set(behavior.rawValue, forKey: followUpDefaultsKey)
    }

    func removeQueuedFollowUp(_ id: UUID) {
        queuedFollowUps.removeAll { $0.id == id }
    }

    func selectThread(_ id: String, closeSidebar: Bool = true, showErrors: Bool = true) async {
        let loadGeneration = UUID()
        threadLoadGeneration = loadGeneration
        let switchingThreads = selectedThreadId != id
        if switchingThreads { cacheCurrentThread() }
        setSelectedThread(id)
        hasOlderTurns = olderTurnsCursorByThread[id] != nil
        reconcilingThreadId = id
        queuedEvents = []
        let restoredFromCache = switchingThreads && restoreThreadSnapshot(id)
        if switchingThreads && !restoredFromCache {
            messages = []
            turnMetadata = [:]
            isRunning = false
            activeTurnId = nil
            activePlan = []
        }
        if closeSidebar { sidebarOpen = false }
        isLoadingThread = switchingThreads && !restoredFromCache
        defer {
            if threadLoadGeneration == loadGeneration {
                isLoadingThread = false
                finishThreadReconciliation(id)
            }
        }

        do {
            let result = try await socket.rpc(
                method: "thread/resume",
                params: [
                    "threadId": .string(id),
                    "excludeTurns": .bool(true),
                    "initialTurnsPage": .object([
                        "limit": .number(8),
                        "sortDirection": .string("desc"),
                        "itemsView": .string("full")
                    ])
                ],
                timeoutSeconds: 600,
                reconnectOnTimeout: false
            )
            guard selectedThreadId == id, threadLoadGeneration == loadGeneration else { return }
            let pageTurns = result["initialTurnsPage"]?["data"]?.arrayValue ?? []
            let turns = pageTurns.isEmpty
                ? (result["thread"]?["turns"]?.arrayValue ?? [])
                : Array(pageTurns.reversed())
            if let nextCursor = result["initialTurnsPage"]?["nextCursor"]?.stringValue {
                olderTurnsCursorByThread[id] = nextCursor
                hasOlderTurns = true
            } else {
                olderTurnsCursorByThread.removeValue(forKey: id)
                hasOlderTurns = false
            }
            var loadedMessages: [TranscriptItem] = []
            var loadedMetadata: [String: TurnMetadata] = [:]
            for turn in turns {
                guard let turnId = turn["id"]?.stringValue else { continue }
                loadedMetadata[turnId] = TurnMetadata(json: turn)
                loadedMessages.append(contentsOf: turn["items"]?.arrayValue?.compactMap {
                    TranscriptItem.from(json: $0, turnId: turnId)
                } ?? [])
            }
            let unresolvedMessages = messages.filter {
                $0.deliveryState != nil && outboundDrafts[$0.id]?.threadId == id
            }
            let loadedIds = Set(loadedMessages.map(\.id))
            for unresolved in unresolvedMessages where !loadedIds.contains(unresolved.id) {
                var preserved = unresolved
                if preserved.deliveryState == .sending || preserved.deliveryState == .accepted {
                    preserved.deliveryState = .uncertain("连接恢复后仍在确认是否送达。")
                }
                loadedMessages.append(preserved)
            }
            for deliveredId in unresolvedMessages.map(\.id).filter({ loadedIds.contains($0) }) {
                outboundDrafts.removeValue(forKey: deliveredId)
                acceptedMessageIds.remove(deliveredId)
            }
            messages = loadedMessages
            turnMetadata = loadedMetadata
            let status = result["thread"]?["status"]?["type"]?.stringValue
                ?? result["thread"]?["status"]?.stringValue
                ?? "idle"
            let threadIsActive = isActiveStatus(status)
            activeTurnId = turns.last(where: { self.isActiveStatus($0["status"]?.stringValue) })?["id"]?.stringValue
            if activeTurnId == nil, threadIsActive {
                activeTurnId = turns.last?["id"]?.stringValue
            }
            isRunning = threadIsActive || activeTurnId != nil
            if let runtime = try? await socket.rpc(
                method: "relay/thread/runtime",
                params: ["threadId": .string(id)]
            ) {
                guard selectedThreadId == id, threadLoadGeneration == loadGeneration else { return }
                reconcileRuntimeState(runtime)
            }
            if isRunning {
                if let activeTurnId {
                    activeTurnIdsByThread[id] = activeTurnId
                    var activeMetadata = turnMetadata[activeTurnId] ?? TurnMetadata()
                    activeMetadata.status = "inProgress"
                    activeMetadata.completedAt = nil
                    activeMetadata.durationMs = nil
                    if activeMetadata.startedAt == nil { activeMetadata.startedAt = Date() }
                    turnMetadata[activeTurnId] = activeMetadata
                }
                setThreadStatus(id, status: "active", touchUpdatedAt: false)
            } else {
                activeTurnIdsByThread.removeValue(forKey: id)
                setThreadStatus(id, status: "idle", touchUpdatedAt: false)
            }
            if let model = result["model"]?.stringValue { selectedModelId = model }
            if let effort = result["reasoningEffort"]?.stringValue { selectedEffort = effort }
            normalizeEffortForSelectedModel()
            persistGenerationSettings()
            cacheCurrentThread()
            if !isRunning {
                Task { [weak self] in await self?.sendNextQueuedFollowUpIfNeeded(threadId: id) }
            }
        } catch {
            guard selectedThreadId == id, threadLoadGeneration == loadGeneration else { return }
            report(error, show: showErrors)
        }
    }

    func loadOlderTurns() async {
        guard let threadId = selectedThreadId,
              let cursor = olderTurnsCursorByThread[threadId],
              !isLoadingOlderTurns,
              socket.state == .connected else { return }
        isLoadingOlderTurns = true
        defer { isLoadingOlderTurns = false }
        do {
            let result = try await socket.rpc(
                method: "thread/turns/list",
                params: [
                    "threadId": .string(threadId),
                    "cursor": .string(cursor),
                    "limit": .number(8),
                    "sortDirection": .string("desc"),
                    "itemsView": .string("full")
                ],
                timeoutSeconds: 600,
                reconnectOnTimeout: false
            )
            guard selectedThreadId == threadId else { return }
            let turns = Array((result["data"]?.arrayValue ?? []).reversed())
            var olderMessages: [TranscriptItem] = []
            for turn in turns {
                guard let turnId = turn["id"]?.stringValue else { continue }
                turnMetadata[turnId] = TurnMetadata(json: turn)
                olderMessages.append(contentsOf: turn["items"]?.arrayValue?.compactMap {
                    TranscriptItem.from(json: $0, turnId: turnId)
                } ?? [])
            }
            let existingIds = Set(messages.map(\.id))
            messages = olderMessages.filter { !existingIds.contains($0.id) } + messages
            if let nextCursor = result["nextCursor"]?.stringValue {
                olderTurnsCursorByThread[threadId] = nextCursor
                hasOlderTurns = true
            } else {
                olderTurnsCursorByThread.removeValue(forKey: threadId)
                hasOlderTurns = false
            }
            cacheCurrentThread()
        } catch {
            errorMessage = "加载更早对话失败：\(error.localizedDescription)"
        }
    }

    func sendPrompt() async {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        let readyAttachments = attachments.filter { $0.state == .ready && $0.remotePath != nil }
        guard !text.isEmpty || !readyAttachments.isEmpty else { return }
        guard socket.state == .connected else {
            socket.reconnectIfNeeded()
            errorMessage = "尚未连接到 Windows，消息仍保留在输入框中。Relay 正在重新连接。"
            return
        }
        if selectedThreadId == nil { await newThread() }
        guard let threadId = selectedThreadId else { return }

        if isRunning, followUpBehavior == .queue {
            queuedFollowUps.append(QueuedFollowUp(
                id: UUID(),
                threadId: threadId,
                text: text,
                attachments: readyAttachments,
                createdAt: Date()
            ))
            composerText = ""
            attachments = []
            return
        }

        if isRunning {
            await steerActiveTurn(text: text, readyAttachments: readyAttachments, threadId: threadId)
            return
        }

        composerText = ""
        attachments = []
        await startTurn(text: text, readyAttachments: readyAttachments, threadId: threadId)
    }

    private func startTurn(text: String, readyAttachments: [PendingAttachment], threadId: String) async {
        let clientMessageId = UUID().uuidString
        outboundDrafts[clientMessageId] = OutboundDraft(
            threadId: threadId,
            text: text,
            attachments: readyAttachments
        )
        activePlan = []
        sendingThreadIds.insert(threadId)
        isRunning = true
        setThreadStatus(threadId, status: "active")
        let attachmentSummary = readyAttachments.map { "📎 \($0.name)" }.joined(separator: "\n")
        let displayText = [text, attachmentSummary].filter { !$0.isEmpty }.joined(separator: "\n\n")
        messages.append(TranscriptItem(
            id: clientMessageId,
            role: .user,
            kind: .message,
            text: displayText,
            deliveryState: .sending
        ))
        defer { sendingThreadIds.remove(threadId) }
        do {
            var params: [String: JSONValue] = [
                "threadId": .string(threadId),
                "clientUserMessageId": .string(clientMessageId),
                "input": .array(userInput(text: text, attachments: readyAttachments)),
                "summary": .string("detailed"),
                "sandboxPolicy": workspaceAccess.sandboxPolicy(workingDirectory: currentWorkingDirectory)
            ]
            if let model = selectedModel?.model { params["model"] = .string(model) }
            if !selectedEffort.isEmpty { params["effort"] = .string(selectedEffort) }
            let result = try await socket.rpc(
                method: "turn/start",
                params: params,
                timeoutSeconds: 120,
                reconnectOnTimeout: false,
                onAccepted: { [weak self] in
                    self?.markMessageAccepted(clientMessageId, threadId: threadId)
                }
            )
            let confirmedTurnId = result["turn"]?["id"]?.stringValue
            if let confirmedTurnId {
                let existingMetadata = turnMetadata[confirmedTurnId]
                let alreadyCompleted = completedTurnIds.contains(confirmedTurnId)
                    || (existingMetadata.map { !$0.isRunning && $0.startedAt != nil } ?? false)
                if !alreadyCompleted {
                    activeTurnIdsByThread[threadId] = confirmedTurnId
                    if selectedThreadId == threadId { activeTurnId = confirmedTurnId }
                }
                if selectedThreadId == threadId,
                   let index = messages.firstIndex(where: { $0.id == clientMessageId }) {
                    messages[index].turnId = confirmedTurnId
                    messages[index].deliveryState = nil
                }
                if selectedThreadId == threadId, !alreadyCompleted {
                    turnMetadata[confirmedTurnId] = TurnMetadata(json: result["turn"] ?? .object([:]))
                } else if selectedThreadId != threadId, !alreadyCompleted {
                    updateCachedSnapshot(threadId: threadId, isRunning: true, activeTurnId: confirmedTurnId)
                }
            }
            updateDeliveryState(
                clientMessageId,
                state: nil,
                threadId: threadId,
                turnId: confirmedTurnId
            )
            acceptedMessageIds.remove(clientMessageId)
            outboundDrafts.removeValue(forKey: clientMessageId)
        } catch {
            let wasAccepted = acceptedMessageIds.remove(clientMessageId) != nil
            let uncertain = wasAccepted || isUncertainDeliveryError(error)
            updateDeliveryState(
                clientMessageId,
                state: uncertain
                    ? .uncertain("Bridge 可能已接收，正在等待历史确认。")
                    : .failed(error.localizedDescription),
                threadId: threadId
            )
            if !uncertain || !wasAccepted {
                activeTurnIdsByThread.removeValue(forKey: threadId)
                setThreadStatus(threadId, status: "idle")
                updateCachedSnapshot(threadId: threadId, isRunning: false, activeTurnId: nil)
                if selectedThreadId == threadId { isRunning = false }
            }
            errorMessage = uncertain
                ? "消息已保留在对话中，Relay 将在重连后确认是否送达。"
                : "消息发送失败，内容已保留；可在消息下方恢复并重试。"
        }
    }

    private func steerActiveTurn(text: String, readyAttachments: [PendingAttachment], threadId: String) async {
        guard let expectedTurnId = activeTurnId ?? activeTurnIdsByThread[threadId] else {
            errorMessage = "Relay 尚未取得当前任务的运行编号，请稍后重试。"
            return
        }
        let clientMessageId = UUID().uuidString
        outboundDrafts[clientMessageId] = OutboundDraft(
            threadId: threadId,
            text: text,
            attachments: readyAttachments
        )
        let attachmentSummary = readyAttachments.map { "📎 \($0.name)" }.joined(separator: "\n")
        let displayText = [text, attachmentSummary].filter { !$0.isEmpty }.joined(separator: "\n\n")
        composerText = ""
        attachments = []
        sendingThreadIds.insert(threadId)
        messages.append(TranscriptItem(
            id: clientMessageId,
            turnId: expectedTurnId,
            role: .user,
            kind: .message,
            text: displayText,
            deliveryState: .sending
        ))
        defer { sendingThreadIds.remove(threadId) }
        do {
            let result = try await socket.rpc(
                method: "turn/steer",
                params: [
                    "threadId": .string(threadId),
                    "expectedTurnId": .string(expectedTurnId),
                    "clientUserMessageId": .string(clientMessageId),
                    "input": .array(userInput(text: text, attachments: readyAttachments))
                ],
                timeoutSeconds: 120,
                reconnectOnTimeout: false,
                onAccepted: { [weak self] in
                    self?.markMessageAccepted(clientMessageId, threadId: threadId)
                }
            )
            let confirmedTurnId = result["turnId"]?.stringValue ?? expectedTurnId
            let existingMetadata = turnMetadata[confirmedTurnId]
            let alreadyCompleted = completedTurnIds.contains(confirmedTurnId)
                || (existingMetadata.map { !$0.isRunning && $0.startedAt != nil } ?? false)
            if !alreadyCompleted {
                activeTurnIdsByThread[threadId] = confirmedTurnId
                if selectedThreadId == threadId { activeTurnId = confirmedTurnId }
                setThreadStatus(threadId, status: "active")
            }
            updateDeliveryState(
                clientMessageId,
                state: nil,
                threadId: threadId,
                turnId: confirmedTurnId
            )
            acceptedMessageIds.remove(clientMessageId)
            outboundDrafts.removeValue(forKey: clientMessageId)
        } catch {
            let wasAccepted = acceptedMessageIds.remove(clientMessageId) != nil
            let uncertain = wasAccepted || isUncertainDeliveryError(error)
            updateDeliveryState(
                clientMessageId,
                state: uncertain
                    ? .uncertain("引导可能已接收，正在等待历史确认。")
                    : .failed(error.localizedDescription),
                threadId: threadId
            )
            errorMessage = uncertain
                ? "引导已保留在实际位置，Relay 将在重连后确认是否送达。"
                : "引导发送失败，内容已保留；可在消息下方恢复并重试。"
        }
    }

    func restoreMessageToComposer(_ id: String) {
        guard let draft = outboundDrafts[id], draft.threadId == selectedThreadId else { return }
        guard composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, attachments.isEmpty else {
            errorMessage = "请先发送或清空当前输入框，再恢复这条消息。"
            return
        }
        composerText = draft.text
        attachments = draft.attachments
        messages.removeAll { $0.id == id }
        outboundDrafts.removeValue(forKey: id)
        acceptedMessageIds.remove(id)
    }

    func confirmMessageDelivery(_ id: String) async {
        guard let draft = outboundDrafts[id], draft.threadId == selectedThreadId else { return }
        await selectThread(draft.threadId, closeSidebar: false, showErrors: false)
        if messages.contains(where: { $0.id == id && $0.deliveryState == nil }) {
            outboundDrafts.removeValue(forKey: id)
            acceptedMessageIds.remove(id)
        } else {
            updateDeliveryState(
                id,
                state: .failed("Windows 对话历史中暂未找到这条消息。"),
                threadId: draft.threadId
            )
        }
    }

    private func markMessageAccepted(_ id: String, threadId: String) {
        acceptedMessageIds.insert(id)
        sendingThreadIds.remove(threadId)
        updateDeliveryState(id, state: .accepted, threadId: threadId)
    }

    private func updateDeliveryState(
        _ id: String,
        state: MessageDeliveryState?,
        threadId: String? = nil,
        turnId: String? = nil
    ) {
        let targetThreadId = threadId ?? selectedThreadId
        if targetThreadId == selectedThreadId,
           let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index].deliveryState = state
            if let turnId { messages[index].turnId = turnId }
        }
        guard let targetThreadId,
              targetThreadId != selectedThreadId,
              let snapshot = threadSnapshots[targetThreadId],
              let index = snapshot.messages.firstIndex(where: { $0.id == id }) else { return }
        var cachedMessages = snapshot.messages
        cachedMessages[index].deliveryState = state
        if let turnId { cachedMessages[index].turnId = turnId }
        threadSnapshots[targetThreadId] = ThreadSnapshot(
            messages: cachedMessages,
            turnMetadata: snapshot.turnMetadata,
            isRunning: snapshot.isRunning,
            activeTurnId: snapshot.activeTurnId,
            activePlan: snapshot.activePlan,
            modelId: snapshot.modelId,
            effort: snapshot.effort,
            cachedAt: Date()
        )
    }

    private func isUncertainDeliveryError(_ error: Error) -> Bool {
        guard let socketError = error as? RelaySocket.SocketError else { return socket.state != .connected }
        switch socketError {
        case .disconnected: return true
        case .invalidEndpoint: return false
        case .remote(let message):
            let normalized = message.lowercased()
            return normalized.contains("timed out") || normalized.contains("没有完成请求") || socket.state != .connected
        }
    }

    private func userInput(text: String, attachments: [PendingAttachment]) -> [JSONValue] {
        var input: [JSONValue] = []
        if !text.isEmpty { input.append(.object(["type": .string("text"), "text": .string(text)])) }
        for attachment in attachments {
            guard let path = attachment.remotePath else { continue }
            if attachment.isImage {
                input.append(.object(["type": .string("localImage"), "path": .string(path)]))
            } else {
                input.append(.object(["type": .string("mention"), "name": .string(attachment.name), "path": .string(path)]))
            }
        }
        return input
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
            "sandboxPolicy": workspaceAccess.sandboxPolicy(workingDirectory: currentWorkingDirectory)
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

    private func persistThreadCache() {
        guard let data = try? JSONEncoder().encode(Array(threads.prefix(200))) else { return }
        UserDefaults.standard.set(data, forKey: threadCacheDefaultsKey)
    }

    private func setThreadStatus(_ threadId: String, status: String, touchUpdatedAt: Bool = true) {
        guard let index = threads.firstIndex(where: { $0.id == threadId }) else { return }
        let changed = threads[index].status != status
        threads[index].status = status
        if touchUpdatedAt { threads[index].updatedAt = Date() }
        if changed || touchUpdatedAt {
            threads.sort { $0.updatedAt > $1.updatedAt }
            persistThreadCache()
        }
    }

    private func setSelectedThread(_ id: String?) {
        selectedThreadId = id
        if let id {
            UserDefaults.standard.set(id, forKey: lastThreadDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: lastThreadDefaultsKey)
        }
    }

    private func normalizeEffortForSelectedModel() {
        guard let model = selectedModel else { return }
        let ids = Set(model.efforts.map(\.id))
        if selectedEffort.isEmpty || (!ids.isEmpty && !ids.contains(selectedEffort)) {
            selectedEffort = model.defaultEffort
        }
    }

    private func handleEvent(method: String, params: JSONValue) {
        if let eventThreadId = params["threadId"]?.stringValue, eventThreadId != selectedThreadId {
            applyBackgroundEvent(method: method, params: params, threadId: eventThreadId)
            return
        }
        if let reconcilingThreadId, reconcilingThreadId == selectedThreadId {
            queuedEvents.append((method, params))
            return
        }
        applyEvent(method: method, params: params)
    }

    private func applyEvent(method: String, params: JSONValue) {
        let eventTurnId = params["turnId"]?.stringValue ?? params["turn"]?["id"]?.stringValue
        switch method {
        case "turn/started":
            activePlan = []
            let metadata = TurnMetadata(json: params["turn"] ?? .object([:]))
            if let turnId = params["turn"]?["id"]?.stringValue { completedTurnIds.remove(turnId) }
            markTurnActive(params["turn"]?["id"]?.stringValue, startedAt: metadata.startedAt)
        case "turn/completed":
            let turn = params["turn"] ?? .object([:])
            let turnId = turn["id"]?.stringValue ?? eventTurnId
            if let turnId {
                completedTurnIds.insert(turnId)
                var metadata = TurnMetadata(json: turn)
                if metadata.durationMs == nil, metadata.completedAt == nil { metadata.completedAt = Date() }
                turnMetadata[turnId] = metadata
                for itemJSON in turn["items"]?.arrayValue ?? [] {
                    if let item = TranscriptItem.from(json: itemJSON, turnId: turnId) { upsert(item) }
                }
            }
            let completedActiveTurn = activeTurnId == nil || turnId == activeTurnId
            if completedActiveTurn {
                if let selectedThreadId {
                    activeTurnIdsByThread.removeValue(forKey: selectedThreadId)
                    setThreadStatus(selectedThreadId, status: "idle")
                }
                isRunning = false
                activeTurnId = nil
                activePlan = []
            }
            Task { await refreshThreads(showErrors: false) }
            scheduleCompletionReconciliation(threadId: selectedThreadId)
        case "item/started", "item/completed":
            markTurnActive(eventTurnId)
            if let itemJSON = params["item"], let item = TranscriptItem.from(json: itemJSON, turnId: eventTurnId) { upsert(item) }
        case "item/agentMessage/delta":
            markTurnActive(eventTurnId)
            appendDelta(id: params["itemId"]?.stringValue, delta: params["delta"]?.stringValue, turnId: eventTurnId, role: .assistant, kind: .message)
        case "item/reasoning/summaryTextDelta", "item/reasoningSummaryText/delta":
            markTurnActive(eventTurnId)
            appendDelta(id: params["itemId"]?.stringValue, delta: params["delta"]?.stringValue, turnId: eventTurnId, role: .tool, kind: .reasoning, title: "思考")
        case "item/reasoning/textDelta":
            markTurnActive(eventTurnId)
            appendDetail(id: params["itemId"]?.stringValue, delta: params["delta"]?.stringValue, turnId: eventTurnId, kind: .reasoning)
        case "item/commandExecution/outputDelta":
            markTurnActive(eventTurnId)
            appendDetail(id: params["itemId"]?.stringValue, delta: params["delta"]?.stringValue, turnId: eventTurnId, kind: .command)
        case "turn/plan/updated":
            guard let turnId = eventTurnId else { break }
            markTurnActive(turnId)
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

    private func applyBackgroundEvent(method: String, params: JSONValue, threadId: String) {
        let turnId = params["turnId"]?.stringValue ?? params["turn"]?["id"]?.stringValue
        switch method {
        case "turn/started", "item/started", "item/completed", "item/agentMessage/delta",
             "item/reasoning/summaryTextDelta", "item/reasoningSummaryText/delta",
             "item/reasoning/textDelta", "item/commandExecution/outputDelta", "turn/plan/updated":
            let wasRunning = isThreadRunning(threadId)
            if method == "turn/started", let turnId { completedTurnIds.remove(turnId) }
            if let turnId { activeTurnIdsByThread[threadId] = turnId }
            if !wasRunning { setThreadStatus(threadId, status: "active") }
            updateCachedSnapshot(threadId: threadId, isRunning: true, activeTurnId: turnId)
        case "turn/completed":
            if let turnId { completedTurnIds.insert(turnId) }
            let completesKnownTurn = activeTurnIdsByThread[threadId] == nil
                || turnId == nil
                || activeTurnIdsByThread[threadId] == turnId
            if completesKnownTurn {
                activeTurnIdsByThread.removeValue(forKey: threadId)
                setThreadStatus(threadId, status: "idle")
                updateCachedSnapshot(threadId: threadId, isRunning: false, activeTurnId: nil)
            }
            Task { await refreshThreads(showErrors: false) }
        case "thread/tokenUsage/updated":
            if let usage = params["tokenUsage"] {
                tokenUsageByThread[threadId] = ThreadTokenUsage(json: usage)
            }
        default:
            break
        }
    }

    private func markTurnActive(_ turnId: String?, startedAt: Date? = nil) {
        let wasRunning = selectedThreadId.map { isThreadRunning($0) } ?? false
        isRunning = true
        if let selectedThreadId {
            if let turnId { activeTurnIdsByThread[selectedThreadId] = turnId }
            if !wasRunning { setThreadStatus(selectedThreadId, status: "active") }
        }
        guard let turnId else { return }
        activeTurnId = turnId
        var metadata = turnMetadata[turnId] ?? TurnMetadata()
        metadata.status = "inProgress"
        metadata.completedAt = nil
        metadata.durationMs = nil
        if metadata.startedAt == nil { metadata.startedAt = startedAt ?? Date() }
        turnMetadata[turnId] = metadata
    }

    private func reconcileRuntimeState(_ runtime: JSONValue) {
        guard runtime["known"]?.boolValue == true else { return }
        if runtime["isRunning"]?.boolValue == true {
            let startedAt = runtime["startedAt"]?.doubleValue.map { Date(timeIntervalSince1970: $0) }
            markTurnActive(runtime["activeTurnId"]?.stringValue, startedAt: startedAt)
        } else {
            if let staleTurnId = activeTurnId, var metadata = turnMetadata[staleTurnId], metadata.isRunning {
                metadata.status = "completed"
                if metadata.durationMs == nil, metadata.completedAt == nil { metadata.completedAt = Date() }
                turnMetadata[staleTurnId] = metadata
            }
            isRunning = false
            if let selectedThreadId {
                activeTurnIdsByThread.removeValue(forKey: selectedThreadId)
                setThreadStatus(selectedThreadId, status: "idle", touchUpdatedAt: false)
            }
            activeTurnId = nil
            activePlan = []
        }
    }

    private func finishThreadReconciliation(_ threadId: String) {
        guard reconcilingThreadId == threadId, selectedThreadId == threadId else { return }
        reconcilingThreadId = nil
        let events = queuedEvents
        queuedEvents = []
        for event in events { applyEvent(method: event.method, params: event.params) }
        cacheCurrentThread()
    }

    private func scheduleCompletionReconciliation(threadId: String?) {
        guard let threadId else { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, self.selectedThreadId == threadId, !self.isRunning, self.activeTurnId == nil else { return }
            await self.selectThread(threadId, closeSidebar: false, showErrors: false)
        }
    }

    private func updateCachedSnapshot(threadId: String, isRunning: Bool, activeTurnId: String?) {
        guard let snapshot = threadSnapshots[threadId] else { return }
        threadSnapshots[threadId] = ThreadSnapshot(
            messages: snapshot.messages,
            turnMetadata: snapshot.turnMetadata,
            isRunning: isRunning,
            activeTurnId: activeTurnId,
            activePlan: isRunning ? snapshot.activePlan : [],
            modelId: snapshot.modelId,
            effort: snapshot.effort,
            cachedAt: Date()
        )
    }

    private func sendNextQueuedFollowUpIfNeeded(threadId: String) async {
        guard selectedThreadId == threadId, !isRunning, socket.state == .connected,
              let index = queuedFollowUps.firstIndex(where: { $0.threadId == threadId }) else { return }
        let followUp = queuedFollowUps.remove(at: index)
        await startTurn(text: followUp.text, readyAttachments: followUp.attachments, threadId: threadId)
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
        await refreshThreads(showErrors: false)
        if modelOptions.isEmpty { await refreshModels(showErrors: false) }
        if let selectedThreadId {
            await selectThread(selectedThreadId, closeSidebar: false, showErrors: false)
        } else {
            if let targetThreadId = threads.first?.id {
                await selectThread(targetThreadId, closeSidebar: false, showErrors: false)
            }
        }
    }

    private func scheduleRestoration() {
        guard restorationTask == nil else { return }
        restorationTask = Task { [weak self] in
            guard let self else { return }
            await self.handleConnectionRestored()
            self.restorationTask = nil
        }
    }

    private func cacheCurrentThread() {
        guard let selectedThreadId else { return }
        threadSnapshots[selectedThreadId] = ThreadSnapshot(
            messages: messages,
            turnMetadata: turnMetadata,
            isRunning: isRunning,
            activeTurnId: activeTurnId,
            activePlan: activePlan,
            modelId: selectedModelId,
            effort: selectedEffort,
            cachedAt: Date()
        )

        if threadSnapshots.count > 8,
           let oldest = threadSnapshots
            .filter({ $0.key != selectedThreadId })
            .min(by: { $0.value.cachedAt < $1.value.cachedAt })?.key {
            threadSnapshots.removeValue(forKey: oldest)
        }
    }

    @discardableResult
    private func restoreThreadSnapshot(_ threadId: String) -> Bool {
        guard let snapshot = threadSnapshots[threadId] else { return false }
        messages = snapshot.messages
        turnMetadata = snapshot.turnMetadata
        isRunning = snapshot.isRunning
        activeTurnId = snapshot.activeTurnId
        activePlan = snapshot.activePlan
        selectedModelId = snapshot.modelId
        selectedEffort = snapshot.effort
        return true
    }

    private func isActiveStatus(_ status: String?) -> Bool {
        let normalized = status?
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .lowercased() ?? ""
        return ["active", "inprogress", "running", "started", "pending", "queued", "processing"].contains(normalized)
    }

    private func report(_ error: Error, show shouldShow: Bool = true) {
        guard shouldShow else { return }
        errorMessage = error.localizedDescription
    }
}

private struct ThreadSnapshot {
    let messages: [TranscriptItem]
    let turnMetadata: [String: TurnMetadata]
    let isRunning: Bool
    let activeTurnId: String?
    let activePlan: [ExecutionPlanStep]
    let modelId: String
    let effort: String
    let cachedAt: Date
}

private struct OutboundDraft {
    let threadId: String
    let text: String
    let attachments: [PendingAttachment]
}
