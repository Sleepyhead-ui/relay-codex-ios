import Foundation

@MainActor
final class RelayStore: ObservableObject {
    @Published var host = HostConfiguration()
    @Published var token = ""
    @Published var threads: [ThreadSummary] = []
    @Published var selectedThreadId: String?
    @Published var messages: [TranscriptItem] = []
    @Published var composerText = ""
    @Published var sidebarOpen = false
    @Published var showingConnection = false
    @Published var showingSettings = false
    @Published var showingNewTask = false
    @Published private(set) var pendingApprovals: [ApprovalRequest] = []
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
    @Published private(set) var imagePreviewURLs: [String: URL] = [:]
    @Published private(set) var loadingImagePaths = Set<String>()
    @Published var followUpBehavior: FollowUpBehavior = .steer
    @Published var queuedFollowUps: [QueuedFollowUp] = []
    @Published private(set) var taskRunStates: [String: TaskRunState] = [:]
    @Published private(set) var goalStates: [String: GoalState] = [:]
    @Published private(set) var sendingThreadIds = Set<String>()
    @Published private(set) var isPreparingPrompt = false
    @Published private(set) var codexProfiles: [CodexProfile] = []
    @Published private(set) var activeCodexProfileId = ""
    @Published private(set) var isSwitchingCodexProfile = false
    @Published private(set) var pinnedThreadIds = Set<String>()
    @Published private(set) var showingArchivedThreads = false
    @Published var showingDiagnostics = false
    @Published private(set) var diagnosticsReport: DiagnosticsReport?
    @Published private(set) var notificationsEnabled = false
    @Published private(set) var savedHosts: [RelayHostEntry] = []
    @Published private(set) var hostAvailability: [String: Bool] = [:]
    @Published private(set) var currentHostId = ""
    @Published private(set) var isCheckingHosts = false
    @Published private(set) var updateInfo: RelayUpdateInfo?
    @Published private(set) var isCheckingUpdate = false
    @Published private(set) var isDownloadingUpdate = false
    @Published private(set) var updateDownloadProgress: Double?

    let socket = RelaySocket()
    private let hostDefaultsKey = "relay.host.configuration"
    private let modelDefaultsKey = "relay.model"
    private let effortDefaultsKey = "relay.reasoningEffort"
    private let accessDefaultsKey = "relay.workspaceAccess"
    private let projectAccessDefaultsKey = "relay.workspaceAccessByProject"
    private let lastThreadDefaultsKey = "relay.lastThreadId"
    private let threadCacheDefaultsKey = "relay.cachedThreads"
    private let followUpDefaultsKey = "relay.followUpBehavior"
    private let pinnedThreadsDefaultsPrefix = "relay.pinnedThreads"
    private let notificationsDefaultsKey = "relay.notifications.enabled"
    private let hostRegistryDefaultsKey = "relay.host.registry"
    private let currentHostDefaultsKey = "relay.host.currentId"
    private let notificationCoordinator = NotificationCoordinator()
    private var applicationIsActive = true
    private var notifiedCompletionTurnIds = Set<String>()
    private var threadLoadGeneration = UUID()
    private var reconcilingThreadId: String?
    private var queuedEvents: [(method: String, params: JSONValue)] = []
    private var threadSnapshots = ThreadSnapshotCache()
    private var olderTurnsCursorByThread: [String: String] = [:]
    private var workingDirectoryOverrides: [String: String] = [:]
    private var workspaceAccessByProject: [String: WorkspaceAccessMode] = [:]
    private var defaultWorkspaceAccess: WorkspaceAccessMode = .workspaceWrite
    private var acceptedMessageIds = Set<String>()
    private var outboundDrafts: [String: OutboundDraft] = [:]
    private var userMessagePlacements: [String: UserMessagePlacement] = [:]
    private var nextUserMessageSequence = 0
    private var completedTurnIds = Set<String>()
    private var restorationTask: Task<Void, Never>?
    private var liveSessionSyncTask: Task<Void, Never>?
    private var subscribedSessionThreadId: String?
    private var pendingDetailDeltas: [String: PendingDetailDelta] = [:]
    private var detailDeltaFlushTask: Task<Void, Never>?

    var needsConnection: Bool { host.endpoint.isEmpty || token.isEmpty }
    var selectedThread: ThreadSummary? { threads.first { $0.id == selectedThreadId } }
    var isSendingPrompt: Bool {
        if isPreparingPrompt { return true }
        guard let selectedThreadId else { return false }
        return sendingThreadIds.contains(selectedThreadId)
    }
    var isSelectedThreadUpstreamRetrying: Bool {
        guard let selectedThreadId else { return false }
        return taskRunStates[selectedThreadId]?.phase == .retrying
    }
    var isRunning: Bool {
        guard let selectedThreadId else { return false }
        return taskRunStates[selectedThreadId]?.isRunning == true
    }
    var activePlan: [ExecutionPlanStep] {
        guard let selectedThreadId,
              let state = taskRunStates[selectedThreadId],
              state.planTurnId == state.turnId else { return [] }
        return state.plan
    }
    private var activeTurnId: String? {
        guard let selectedThreadId else { return nil }
        return taskRunStates[selectedThreadId]?.turnId
    }
    var currentPendingApprovals: [ApprovalRequest] {
        ApprovalQueue.prioritized(pendingApprovals, selectedThreadId: selectedThreadId)
    }
    var pendingApproval: ApprovalRequest? { currentPendingApprovals.first }
    func hasPendingApproval(threadId: String) -> Bool {
        ApprovalQueue.contains(pendingApprovals, threadId: threadId)
    }
    var currentQueuedFollowUps: [QueuedFollowUp] {
        guard let selectedThreadId else { return [] }
        return queuedFollowUps.filter { $0.threadId == selectedThreadId }
    }
    var currentGoal: GoalState? {
        guard let selectedThreadId else { return nil }
        return goalStates[selectedThreadId]
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
        if let data = UserDefaults.standard.data(forKey: hostRegistryDefaultsKey),
           let storedHosts = try? JSONDecoder().decode([RelayHostEntry].self, from: data) {
            savedHosts = storedHosts
        }
        currentHostId = UserDefaults.standard.string(forKey: currentHostDefaultsKey) ?? ""
        if currentHostId.isEmpty, !host.endpoint.isEmpty {
            let migrated = RelayHostEntry(configuration: host)
            savedHosts = [migrated]
            currentHostId = migrated.id
            if let legacyToken = KeychainStore.loadToken() {
                try? KeychainStore.saveToken(legacyToken, account: tokenAccount(for: migrated.id))
            }
            persistHostRegistry()
        }
        if let selected = savedHosts.first(where: { $0.id == currentHostId }) { host = selected.configuration }
        token = KeychainStore.loadToken(account: tokenAccount(for: currentHostId)) ?? KeychainStore.loadToken() ?? ""
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
            defaultWorkspaceAccess = access
        }
        if let storedProjects = UserDefaults.standard.dictionary(forKey: projectAccessDefaultsKey) as? [String: String] {
            workspaceAccessByProject = storedProjects.reduce(into: [:]) { result, entry in
                if let access = WorkspaceAccessMode(rawValue: entry.value) { result[entry.key] = access }
            }
        }
        if let storedFollowUp = UserDefaults.standard.string(forKey: followUpDefaultsKey),
           let behavior = FollowUpBehavior(rawValue: storedFollowUp) {
            followUpBehavior = behavior
        }
        notificationsEnabled = UserDefaults.standard.bool(forKey: notificationsDefaultsKey)

        socket.onConnected = { [weak self] in
            self?.scheduleRestoration()
        }
        socket.onBridgeStatus = { [weak self] message in self?.handleBridgeStatus(message) }
        socket.onEvent = { [weak self] method, params in self?.handleEvent(method: method, params: params) }
        socket.onSessionSnapshot = { [weak self] threadId, snapshot in
            self?.applySessionSnapshot(snapshot, threadId: threadId)
        }
        socket.onPromptQueueUpdated = { [weak self] threadId, message in
            self?.applyPromptQueueUpdate(threadId: threadId, items: message["items"]?.arrayValue ?? [])
        }
        socket.onUpdateProgress = { [weak self] message in
            guard let downloaded = message["downloadedBytes"]?.doubleValue,
                  let total = message["totalBytes"]?.doubleValue, total > 0 else { return }
            self?.updateDownloadProgress = min(1, max(0, downloaded / total))
        }
        socket.onServerRequest = { [weak self] message in self?.enqueueApproval(message) }
        socket.onServerRequestResolved = { [weak self] message in
            guard let id = message["id"]?.stringValue ?? message["id"]?.intValue.map(String.init) else { return }
            self?.pendingApprovals.removeAll { $0.id == id }
        }
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

    func refreshSavedHostStatus() async {
        guard !savedHosts.isEmpty else { return }
        isCheckingHosts = true
        defer { isCheckingHosts = false }
        await withTaskGroup(of: (String, Bool).self) { group in
            for entry in savedHosts {
                group.addTask {
                    guard var components = URLComponents(string: entry.endpoint) else { return (entry.id, false) }
                    components.scheme = components.scheme == "wss" ? "https" : "http"
                    components.path = "/health"
                    guard let url = components.url else { return (entry.id, false) }
                    var request = URLRequest(url: url)
                    request.timeoutInterval = 2.5
                    do {
                        let (_, response) = try await URLSession.shared.data(for: request)
                        return (entry.id, (response as? HTTPURLResponse)?.statusCode == 200)
                    } catch {
                        return (entry.id, false)
                    }
                }
            }
            for await (id, available) in group { hostAvailability[id] = available }
        }
    }

    func switchHost(_ id: String) {
        guard id != currentHostId, let entry = savedHosts.first(where: { $0.id == id }) else { return }
        disconnect()
        resetForHostSwitch()
        currentHostId = id
        host = entry.configuration
        token = KeychainStore.loadToken(account: tokenAccount(for: id)) ?? ""
        UserDefaults.standard.set(id, forKey: currentHostDefaultsKey)
        if token.isEmpty {
            showingSettings = false
            showingConnection = true
        } else {
            connect()
        }
    }

    func applicationBecameActive() {
        applicationIsActive = true
        if socket.state == .connected {
            scheduleRestoration()
        } else {
            socket.reconnectIfNeeded()
        }
    }

    func applicationEnteredBackground() {
        applicationIsActive = false
    }

    func setNotificationsEnabled(_ enabled: Bool) async {
        let allowed = enabled ? await notificationCoordinator.requestAuthorization() : false
        notificationsEnabled = enabled && allowed
        UserDefaults.standard.set(notificationsEnabled, forKey: notificationsDefaultsKey)
        if enabled && !allowed { errorMessage = "系统未授予 Relay 通知权限。" }
    }

    func refreshDiagnostics() async {
        guard socket.state == .connected else { return }
        do {
            let result = try await socket.rpc(method: "relay/diagnostics/report", timeoutSeconds: 12, reconnectOnTimeout: false)
            diagnosticsReport = DiagnosticsReport(json: result)
        } catch {
            report(error)
        }
    }

    func exportDiagnostics() {
        guard let raw = diagnosticsReport?.raw.rawValue,
              JSONSerialization.isValidJSONObject(raw),
              let data = try? JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys]) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Relay-Diagnostics-\(Int(Date().timeIntervalSince1970)).json")
        do {
            try data.write(to: url, options: .atomic)
            sharedFile = SharedFile(url: url)
        } catch {
            report(error)
        }
    }

    func checkForUpdate() async {
        guard socket.state == .connected else { return }
        isCheckingUpdate = true
        defer { isCheckingUpdate = false }
        do {
            let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
            let result = try await socket.rpc(
                method: "relay/update/check",
                params: ["currentVersion": .string(currentVersion)],
                timeoutSeconds: 20,
                reconnectOnTimeout: false
            )
            updateInfo = RelayUpdateInfo(json: result)
        } catch {
            report(error)
        }
    }

    func downloadLatestIPA() async {
        guard updateInfo?.available == true, !isDownloadingUpdate else { return }
        isDownloadingUpdate = true
        updateDownloadProgress = 0
        defer {
            isDownloadingUpdate = false
            updateDownloadProgress = nil
        }
        do {
            let result = try await socket.rpc(
                method: "relay/update/download-ios",
                timeoutSeconds: 300,
                reconnectOnTimeout: false
            )
            guard let path = result["path"]?.stringValue else {
                throw RelaySocket.SocketError.remote("Bridge did not return the downloaded IPA path.")
            }
            let localURL = try await socket.downloadFile(at: path) { _ in }
            sharedFile = SharedFile(url: localURL)
        } catch {
            report(error)
        }
    }

    func forgetHost() {
        restorationTask?.cancel()
        restorationTask = nil
        liveSessionSyncTask?.cancel()
        liveSessionSyncTask = nil
        disconnect()
        if !currentHostId.isEmpty { KeychainStore.deleteToken(account: tokenAccount(for: currentHostId)) }
        savedHosts.removeAll { $0.id == currentHostId }
        persistHostRegistry()
        token = ""
        if let next = savedHosts.first {
            currentHostId = next.id
            host = next.configuration
            token = KeychainStore.loadToken(account: tokenAccount(for: next.id)) ?? ""
            UserDefaults.standard.set(next.id, forKey: currentHostDefaultsKey)
        } else {
            currentHostId = ""
            host = HostConfiguration()
            UserDefaults.standard.removeObject(forKey: hostDefaultsKey)
            UserDefaults.standard.removeObject(forKey: currentHostDefaultsKey)
        }
        threads = []
        UserDefaults.standard.removeObject(forKey: threadCacheDefaultsKey)
        setSelectedThread(nil)
        messages = []
        turnMetadata = [:]
        tokenUsageByThread = [:]
        taskRunStates = [:]
        goalStates = [:]
        sendingThreadIds = []
        queuedFollowUps = []
        pendingApprovals = []
        acceptedMessageIds = []
        outboundDrafts = [:]
        completedTurnIds = []
        threadSnapshots.removeAll()
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
        if let name = values["name"] { host.name = name }
        if let pairingToken = values["token"] { token = pairingToken }
        if let existing = savedHosts.first(where: { $0.endpoint.caseInsensitiveCompare(host.endpoint) == .orderedSame }) {
            currentHostId = existing.id
        } else {
            currentHostId = UUID().uuidString
        }
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

    func refreshCodexProfiles(showErrors: Bool = false) async {
        guard socket.state == .connected else { return }
        do {
            let result = try await socket.rpc(
                method: "relay/codex/profiles/list",
                params: [:],
                timeoutSeconds: 12,
                reconnectOnTimeout: false
            )
            codexProfiles = result["profiles"]?.arrayValue?.compactMap(CodexProfile.init(json:)) ?? []
            activeCodexProfileId = result["activeProfileId"]?.stringValue
                ?? codexProfiles.first(where: \.isActive)?.id
                ?? ""
        } catch {
            report(error, show: showErrors)
        }
    }

    func switchCodexProfile(_ profileId: String) async {
        guard profileId != activeCodexProfileId, !isSwitchingCodexProfile else { return }
        guard !isRunning, pendingApproval == nil else {
            errorMessage = "请先结束当前任务并处理审批，再切换 Codex 实例。"
            return
        }
        isSwitchingCodexProfile = true
        do {
            let result = try await socket.rpc(
                method: "relay/codex/profiles/switch",
                params: ["profileId": .string(profileId)],
                timeoutSeconds: 20,
                reconnectOnTimeout: false
            )
            activeCodexProfileId = result["profile"]?["id"]?.stringValue ?? profileId
            resetForCodexProfileSwitch()
        } catch {
            isSwitchingCodexProfile = false
            report(error)
        }
    }

    func refreshThreads(showErrors: Bool = true) async {
        guard socket.state == .connected else { return }
        do {
            let result = try await socket.rpc(method: "thread/list", params: [
                "limit": .number(200),
                "sortKey": .string("updated_at"),
                "sortDirection": .string("desc"),
                "useStateDbOnly": .bool(true),
                "archived": .bool(showingArchivedThreads)
            ])
            var fetched = result["data"]?.arrayValue?.compactMap(ThreadSummary.init(json:)) ?? []
            if fetched.isEmpty, !threads.isEmpty {
                return
            }
            for index in fetched.indices where taskRunStates[fetched[index].id]?.isRunning == true {
                fetched[index].status = "active"
            }
            threads = fetched.sorted { left, right in
                let leftPinned = pinnedThreadIds.contains(left.id)
                let rightPinned = pinnedThreadIds.contains(right.id)
                return leftPinned == rightPinned ? left.updatedAt > right.updatedAt : leftPinned
            }
            if !showingArchivedThreads { persistThreadCache() }
        } catch {
            report(error, show: showErrors)
        }
    }

    func setShowingArchivedThreads(_ showing: Bool) async {
        guard showingArchivedThreads != showing else { return }
        cacheCurrentThread()
        showingArchivedThreads = showing
        setSelectedThread(nil)
        threads = []
        messages = []
        turnMetadata = [:]
        await refreshThreads()
        if let first = threads.first?.id { await selectThread(first, closeSidebar: false) }
    }

    func isThreadPinned(_ threadId: String) -> Bool {
        pinnedThreadIds.contains(threadId)
    }

    func toggleThreadPin(_ threadId: String) {
        if pinnedThreadIds.contains(threadId) {
            pinnedThreadIds.remove(threadId)
        } else {
            pinnedThreadIds.insert(threadId)
        }
        persistPinnedThreads()
        threads.sort { left, right in
            let leftPinned = pinnedThreadIds.contains(left.id)
            let rightPinned = pinnedThreadIds.contains(right.id)
            return leftPinned == rightPinned ? left.updatedAt > right.updatedAt : leftPinned
        }
    }

    func renameThread(_ threadId: String, to name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            _ = try await socket.rpc(
                method: "thread/name/set",
                params: ["threadId": .string(threadId), "name": .string(trimmed)]
            )
            if let index = threads.firstIndex(where: { $0.id == threadId }) {
                threads[index].title = trimmed
                if !showingArchivedThreads { persistThreadCache() }
            }
        } catch {
            report(error)
        }
    }

    func archiveThread(_ threadId: String) async {
        guard !isThreadRunning(threadId) else {
            errorMessage = "请先停止正在运行的任务。"
            return
        }
        do {
            _ = try await socket.rpc(method: "thread/archive", params: ["threadId": .string(threadId)])
            removeThreadFromCurrentList(threadId)
        } catch {
            report(error)
        }
    }

    func unarchiveThread(_ threadId: String) async {
        do {
            _ = try await socket.rpc(method: "thread/unarchive", params: ["threadId": .string(threadId)])
            removeThreadFromCurrentList(threadId)
        } catch {
            report(error)
        }
    }

    @discardableResult
    func newThread(workingDirectory: String? = nil) async -> Bool {
        guard socket.state == .connected else {
            socket.reconnectIfNeeded()
            return false
        }
        do {
            showingArchivedThreads = false
            let projectDirectory = (workingDirectory ?? host.workingDirectory)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let projectAccess = storedAccess(for: projectDirectory)
            var params: [String: JSONValue] = [
                "approvalPolicy": .string("on-request"),
                "sandbox": .string(projectAccess.threadSandbox),
                "threadSource": .string("relay-ios")
            ]
            if !projectDirectory.isEmpty { params["cwd"] = .string(projectDirectory) }
            if let model = selectedModel?.model { params["model"] = .string(model) }
            let result = try await socket.rpc(
                method: "thread/start",
                params: params,
                onAccepted: { }
            )
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
            workspaceAccess = projectAccess
            messages = []
            turnMetadata = [:]
            applyTaskRunEvent(threadId: id, event: .reset)
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
        taskRunStates[threadId]?.isRunning == true
            || threads.first(where: { $0.id == threadId })?.isRunning == true
    }

    func selectFollowUpBehavior(_ behavior: FollowUpBehavior) {
        followUpBehavior = behavior
        UserDefaults.standard.set(behavior.rawValue, forKey: followUpDefaultsKey)
    }

    func removeQueuedFollowUp(_ id: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await socket.rpc(
                    method: "relay/prompt/queue/remove",
                    params: ["id": .string(id)],
                    timeoutSeconds: 12,
                    reconnectOnTimeout: false
                )
                queuedFollowUps.removeAll { $0.id == id }
            } catch {
                report(error)
            }
        }
    }

    func selectThread(_ id: String, closeSidebar: Bool = true, showErrors: Bool = true) async {
        flushPendingDetailDeltas()
        let loadGeneration = UUID()
        threadLoadGeneration = loadGeneration
        let switchingThreads = selectedThreadId != id
        // Keep the live snapshot poller alive when restoring the same active
        // thread. Cancelling it here creates a gap in incremental output.
        if switchingThreads {
            liveSessionSyncTask?.cancel()
            liveSessionSyncTask = nil
            if let subscribedSessionThreadId {
                Task { [weak self] in
                    _ = try? await self?.socket.rpc(
                        method: "relay/thread/session/unsubscribe",
                        params: ["threadId": .string(subscribedSessionThreadId)],
                        timeoutSeconds: 4,
                        reconnectOnTimeout: false
                    )
                }
                self.subscribedSessionThreadId = nil
            }
        }
        if switchingThreads { cacheCurrentThread() }
        setSelectedThread(id)
        workspaceAccess = storedAccess(for: currentWorkingDirectory)
        hasOlderTurns = olderTurnsCursorByThread[id] != nil
        reconcilingThreadId = id
        queuedEvents = []
        let restoredFromCache = switchingThreads && restoreThreadSnapshot(id)
        if switchingThreads && !restoredFromCache {
            messages = []
            turnMetadata = [:]
            applyTaskRunEvent(threadId: id, event: .reset)
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
            let result: JSONValue
            if showingArchivedThreads {
                async let summary = socket.rpc(
                    method: "thread/read",
                    params: ["threadId": .string(id), "includeTurns": .bool(false)],
                    timeoutSeconds: 25,
                    reconnectOnTimeout: false
                )
                async let page = socket.rpc(
                    method: "thread/turns/list",
                    params: [
                        "threadId": .string(id),
                        "limit": .number(8),
                        "sortDirection": .string("desc"),
                        "itemsView": .string("full")
                    ],
                    timeoutSeconds: 60,
                    reconnectOnTimeout: false
                )
                let (summaryResult, pageResult) = try await (summary, page)
                result = .object([
                    "thread": summaryResult["thread"] ?? .object([:]),
                    "initialTurnsPage": pageResult
                ])
            } else {
                result = try await socket.rpc(
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
                    timeoutSeconds: 25,
                    reconnectOnTimeout: false
                )
            }
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
            let placedMessages = messages.filter {
                userMessagePlacements[$0.id]?.threadId == id
            }
            let loadedIds = Set(loadedMessages.map(\.id))
            let preservedMessages = (unresolvedMessages + placedMessages).reduce(into: [String: TranscriptItem]()) {
                $0[$1.id] = $1
            }.values.sorted {
                let left = userMessagePlacements[$0.id]?.sequence ?? Int.max
                let right = userMessagePlacements[$1.id]?.sequence ?? Int.max
                return left < right
            }
            for unresolved in preservedMessages where !loadedIds.contains(unresolved.id) {
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
            if switchingThreads {
                messages = loadedMessages
                turnMetadata = loadedMetadata
            } else {
                messages = TranscriptReconciler.mergeHistoryItems(loadedMessages, into: messages)
                turnMetadata.merge(loadedMetadata) { _, loaded in loaded }
            }
            let status = result["thread"]?["status"]?["type"]?.stringValue
                ?? result["thread"]?["status"]?.stringValue
                ?? "idle"
            let threadIsActive = isActiveStatus(status)
            var loadedActiveTurnId = turns.last(where: { self.isActiveStatus($0["status"]?.stringValue) })?["id"]?.stringValue
            if loadedActiveTurnId == nil, threadIsActive {
                loadedActiveTurnId = turns.last?["id"]?.stringValue
            }
            if let loadedActiveTurnId {
                applyUserMessagePlacements(turnId: loadedActiveTurnId, threadId: id)
            }
            applyTaskRunEvent(
                threadId: id,
                event: .hydrate(
                    running: threadIsActive || loadedActiveTurnId != nil,
                    turnId: loadedActiveTurnId,
                    startedAt: loadedActiveTurnId.flatMap { turnMetadata[$0]?.startedAt }
                )
            )
            if let runtime = try? await socket.rpc(
                method: "relay/thread/runtime",
                params: ["threadId": .string(id)]
            ) {
                guard selectedThreadId == id, threadLoadGeneration == loadGeneration else { return }
                reconcileRuntimeState(runtime)
            }
            if isRunning {
                if let activeTurnId {
                    var activeMetadata = turnMetadata[activeTurnId] ?? TurnMetadata()
                    activeMetadata.status = "inProgress"
                    activeMetadata.completedAt = nil
                    activeMetadata.durationMs = nil
                    if activeMetadata.startedAt == nil { activeMetadata.startedAt = Date() }
                    turnMetadata[activeTurnId] = activeMetadata
                }
                setThreadStatus(id, status: "active", touchUpdatedAt: false)
            } else {
                setThreadStatus(id, status: "idle", touchUpdatedAt: false)
            }
            if let model = result["model"]?.stringValue { selectedModelId = model }
            if let effort = result["reasoningEffort"]?.stringValue { selectedEffort = effort }
            normalizeEffortForSelectedModel()
            persistGenerationSettings()
            await refreshGoal(threadId: id)
            cacheCurrentThread()
            if isRunning {
                ensureLiveSessionSync()
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

    private func refreshGoal(threadId: String) async {
        guard socket.state == .connected else { return }
        do {
            let result = try await socket.rpc(
                method: "relay/thread/goal",
                params: ["threadId": .string(threadId)],
                timeoutSeconds: 8,
                reconnectOnTimeout: false
            )
            guard selectedThreadId == threadId || threads.contains(where: { $0.id == threadId }) else { return }
            if let goalJSON = result["goal"], let goal = GoalState(json: goalJSON) {
                goalStates[threadId] = goal
            } else {
                goalStates.removeValue(forKey: threadId)
            }
        } catch {
            // Goal mode is optional on older Bridge versions; transcript loading must still succeed.
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
        guard !isPreparingPrompt else { return }
        isPreparingPrompt = true
        defer { isPreparingPrompt = false }
        // A fresh socket starts thread restoration immediately. Waiting here
        // prevents the first prompt from racing with thread/resume and being
        // held back with the restoration event queue.
        await waitForRestoration()
        guard socket.state == .connected else {
            socket.reconnectIfNeeded()
            errorMessage = "Windows 连接已恢复，请稍后重试；输入内容仍保留在输入框中。"
            return
        }
        if selectedThreadId == nil { await newThread() }
        guard let threadId = selectedThreadId else { return }

        if isRunning, followUpBehavior == .queue {
            await enqueueFollowUp(text: text, readyAttachments: readyAttachments, threadId: threadId)
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
        nextUserMessageSequence += 1
        userMessagePlacements[clientMessageId] = UserMessagePlacement(
            threadId: threadId,
            turnId: nil,
            afterItemId: nil,
            sequence: nextUserMessageSequence
        )
        outboundDrafts[clientMessageId] = OutboundDraft(
            threadId: threadId,
            text: text,
            attachments: readyAttachments
        )
        sendingThreadIds.insert(threadId)
        applyTaskRunEvent(threadId: threadId, event: .starting(startedAt: Date()))
        setThreadStatus(threadId, status: "active")
        let attachmentSummary = readyAttachments.filter { !$0.isImage }.map { "📎 \($0.name)" }.joined(separator: "\n")
        let displayText = [text, attachmentSummary].filter { !$0.isEmpty }.joined(separator: "\n\n")
        let imagePaths = readyAttachments.filter(\.isImage).compactMap(\.remotePath)
        messages.append(TranscriptItem(
            id: clientMessageId,
            role: .user,
            kind: .message,
            text: displayText,
            deliveryState: .sending,
            imagePaths: imagePaths
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
                    applyTaskRunEvent(
                        threadId: threadId,
                        event: .started(turnId: confirmedTurnId, startedAt: turnMetadata[confirmedTurnId]?.startedAt)
                    )
                }
                if selectedThreadId == threadId,
                   messages.contains(where: { $0.id == clientMessageId }) {
                    bindUserPrompt(clientMessageId, to: confirmedTurnId, threadId: threadId)
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
                applyTaskRunEvent(threadId: threadId, event: .terminal(turnId: nil, phase: .failed, completedAt: Date()))
                setThreadStatus(threadId, status: "idle")
                updateCachedSnapshot(threadId: threadId, isRunning: false, activeTurnId: nil)
            }
            errorMessage = uncertain
                ? "消息已保留在对话中，Relay 将在重连后确认是否送达。"
                : "消息发送失败，内容已保留；可在消息下方恢复并重试。"
        }
    }

    private func steerActiveTurn(text: String, readyAttachments: [PendingAttachment], threadId: String) async {
        guard let expectedTurnId = taskRunStates[threadId]?.turnId else {
            errorMessage = "Relay 尚未取得当前任务的运行编号，请稍后重试。"
            return
        }
        let clientMessageId = UUID().uuidString
        let afterItemId = messages.last(where: { $0.turnId == expectedTurnId })?.id
        nextUserMessageSequence += 1
        userMessagePlacements[clientMessageId] = UserMessagePlacement(
            threadId: threadId,
            turnId: expectedTurnId,
            afterItemId: afterItemId,
            sequence: nextUserMessageSequence
        )
        outboundDrafts[clientMessageId] = OutboundDraft(
            threadId: threadId,
            text: text,
            attachments: readyAttachments
        )
        let attachmentSummary = readyAttachments.filter { !$0.isImage }.map { "📎 \($0.name)" }.joined(separator: "\n")
        let displayText = [text, attachmentSummary].filter { !$0.isEmpty }.joined(separator: "\n\n")
        let imagePaths = readyAttachments.filter(\.isImage).compactMap(\.remotePath)
        composerText = ""
        attachments = []
        sendingThreadIds.insert(threadId)
        messages.append(TranscriptItem(
            id: clientMessageId,
            turnId: expectedTurnId,
            role: .user,
            kind: .message,
            text: displayText,
            deliveryState: .sending,
            imagePaths: imagePaths
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
                applyTaskRunEvent(threadId: threadId, event: .progress(turnId: confirmedTurnId, startedAt: nil))
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
        userMessagePlacements.removeValue(forKey: id)
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
            activePlanTurnId: snapshot.activePlanTurnId,
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

    func selectWorkspaceAccess(_ access: WorkspaceAccessMode) async {
        workspaceAccess = access
        let directory = currentWorkingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if directory.isEmpty {
            defaultWorkspaceAccess = access
            UserDefaults.standard.set(access.rawValue, forKey: accessDefaultsKey)
        } else {
            workspaceAccessByProject[directory.normalizedWindowsPath] = access
            UserDefaults.standard.set(workspaceAccessByProject.mapValues(\.rawValue), forKey: projectAccessDefaultsKey)
        }
        await applyThreadSettings(showErrors: true)
    }

    private func storedAccess(for directory: String) -> WorkspaceAccessMode {
        let normalized = directory.trimmingCharacters(in: .whitespacesAndNewlines).normalizedWindowsPath
        return normalized.isEmpty ? defaultWorkspaceAccess : workspaceAccessByProject[normalized] ?? defaultWorkspaceAccess
    }

    func stopTurn() async {
        guard let threadId = selectedThreadId else { return }
        var turnId = taskRunStates[threadId]?.turnId
        if turnId == nil, socket.state == .connected,
           let runtime = try? await socket.rpc(method: "relay/thread/runtime", params: ["threadId": .string(threadId)]) {
            reconcileRuntimeState(runtime)
            turnId = taskRunStates[threadId]?.turnId
        }
        guard let turnId else {
            markSelectedThreadStopped(threadId: threadId)
            return
        }
        do {
            _ = try await socket.rpc(method: "turn/interrupt", params: [
                "threadId": .string(threadId),
                "turnId": .string(turnId)
            ])
            markSelectedThreadStopped(threadId: threadId)
        } catch {
            // The turn may have ended between the runtime check and interrupt.
            // Reconcile once before showing an error or leaving a stale spinner.
            if let runtime = try? await socket.rpc(method: "relay/thread/runtime", params: ["threadId": .string(threadId)]),
               runtime["isRunning"]?.boolValue != true {
                reconcileRuntimeState(runtime)
                markSelectedThreadStopped(threadId: threadId)
            } else {
                report(error)
            }
        }
    }

    private func markSelectedThreadStopped(threadId: String) {
        let stoppedTurnId = taskRunStates[threadId]?.turnId
        if let turnId = activeTurnId, var metadata = turnMetadata[turnId] {
            metadata.status = "interrupted"
            metadata.completedAt = metadata.completedAt ?? Date()
            metadata.durationMs = metadata.durationMs ?? Int(max(0, Date().timeIntervalSince(metadata.startedAt ?? Date()) * 1000))
            turnMetadata[turnId] = metadata
        }
        applyTaskRunEvent(threadId: threadId, event: .terminal(turnId: stoppedTurnId, phase: .interrupted, completedAt: Date()))
        liveSessionSyncTask?.cancel()
        liveSessionSyncTask = nil
        setThreadStatus(threadId, status: "idle", touchUpdatedAt: false)
        cacheCurrentThread()
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
            if approval.method == "mcpServer/elicitation/request" {
                // MCP elicitation uses its own response envelope. A generic
                // `decision` field is rejected by Codex as unsupported.
                result = [
                    "action": .string(decision == "accept" ? "accept" : "decline"),
                    "content": decision == "accept" ? .object([:]) : .null
                ]
            } else if approval.method.contains("permissions") {
                result = [
                    "permissions": decision == "accept" ? (approval.requestedPermissions ?? .object([:])) : .object([:]),
                    "scope": .string("turn")
                ]
            } else {
                result = ["decision": .string(decision)]
            }
            try await socket.respond(to: approval.rpcId, result: result)
            pendingApprovals.removeAll { $0.id == approval.id }
        } catch {
            report(error)
        }
    }

    private func enqueueApproval(_ message: JSONValue) {
        guard let approval = ApprovalRequest(message: message) else { return }
        if let index = pendingApprovals.firstIndex(where: { $0.id == approval.id }) {
            pendingApprovals[index] = approval
        } else {
            pendingApprovals.append(approval)
        }
        if notificationsEnabled, !applicationIsActive || approval.threadId != selectedThreadId {
            notificationCoordinator.schedule(
                identifier: "relay.approval.\(approval.id)",
                title: "Relay 等待确认",
                body: approval.summary,
                threadId: approval.threadId
            )
        }
    }

    private func notifyTaskCompleted(threadId: String, turnId: String?, failed: Bool) {
        guard notificationsEnabled,
              let turnId,
              notifiedCompletionTurnIds.insert(turnId).inserted,
              !applicationIsActive || threadId != selectedThreadId else { return }
        let title = threads.first(where: { $0.id == threadId })?.title ?? "Codex 任务"
        notificationCoordinator.schedule(
            identifier: "relay.turn.\(turnId)",
            title: failed ? "任务执行失败" : "任务已完成",
            body: title,
            threadId: threadId
        )
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
        if currentHostId.isEmpty { currentHostId = UUID().uuidString }
        let entry = RelayHostEntry(id: currentHostId, configuration: host)
        if let index = savedHosts.firstIndex(where: { $0.id == currentHostId }) { savedHosts[index] = entry }
        else { savedHosts.append(entry) }
        persistHostRegistry()
        try KeychainStore.saveToken(token, account: tokenAccount(for: currentHostId))
    }

    private func persistHostRegistry() {
        if let data = try? JSONEncoder().encode(savedHosts) {
            UserDefaults.standard.set(data, forKey: hostRegistryDefaultsKey)
        }
        if !currentHostId.isEmpty { UserDefaults.standard.set(currentHostId, forKey: currentHostDefaultsKey) }
    }

    private func tokenAccount(for hostId: String) -> String {
        hostId.isEmpty ? "bridge-token" : "bridge-token.\(hostId)"
    }

    private func resetForHostSwitch() {
        restorationTask?.cancel()
        liveSessionSyncTask?.cancel()
        restorationTask = nil
        liveSessionSyncTask = nil
        subscribedSessionThreadId = nil
        threads = []
        messages = []
        turnMetadata = [:]
        tokenUsageByThread = [:]
        taskRunStates = [:]
        goalStates = [:]
        queuedFollowUps = []
        pendingApprovals = []
        threadSnapshots.removeAll()
        olderTurnsCursorByThread = [:]
        setSelectedThread(nil)
    }

    private func persistGenerationSettings() {
        UserDefaults.standard.set(selectedModelId, forKey: modelDefaultsKey)
        UserDefaults.standard.set(selectedEffort, forKey: effortDefaultsKey)
    }

    private func persistThreadCache() {
        guard let data = try? JSONEncoder().encode(Array(threads.prefix(200))) else { return }
        UserDefaults.standard.set(data, forKey: threadCacheDefaultsKey)
    }

    private var pinnedThreadsDefaultsKey: String {
        "\(pinnedThreadsDefaultsPrefix).\(activeCodexProfileId.nonEmpty ?? "default")"
    }

    private func loadPinnedThreads() {
        pinnedThreadIds = Set(UserDefaults.standard.stringArray(forKey: pinnedThreadsDefaultsKey) ?? [])
    }

    private func persistPinnedThreads() {
        UserDefaults.standard.set(Array(pinnedThreadIds).sorted(), forKey: pinnedThreadsDefaultsKey)
    }

    private func removeThreadFromCurrentList(_ threadId: String) {
        threads.removeAll { $0.id == threadId }
        pinnedThreadIds.remove(threadId)
        persistPinnedThreads()
        if selectedThreadId == threadId {
            setSelectedThread(nil)
            messages = []
            turnMetadata = [:]
            if let next = threads.first?.id {
                Task { await selectThread(next, closeSidebar: false) }
            }
        }
        if !showingArchivedThreads { persistThreadCache() }
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

    private func applyTaskRunEvent(threadId: String, event: TaskRunEvent) {
        var state = taskRunStates[threadId] ?? TaskRunState(threadId: threadId)
        state.apply(event)
        taskRunStates[threadId] = state
    }

    private func acceptsTurnEvent(threadId: String, turnId: String?) -> Bool {
        guard let turnId,
              let state = taskRunStates[threadId],
              state.isRunning,
              let activeTurnId = state.turnId else { return true }
        return activeTurnId == turnId
    }

    @discardableResult
    private func applyDecodedTaskEvents(method: String, params: JSONValue, fallbackThreadId: String?) -> Bool {
        let transition = TaskEventDecoder.decode(method: method, params: params, fallbackThreadId: fallbackThreadId)
        guard let threadId = transition.threadId else { return true }
        if let turnId = transition.turnId,
           completedTurnIds.contains(turnId),
           method == "turn/started" || method == "turn/plan/updated" || TaskEventDecoder.isProgress(method) {
            return false
        }
        if method != "turn/started", !acceptsTurnEvent(threadId: threadId, turnId: transition.turnId) {
            return false
        }
        for event in transition.events { applyTaskRunEvent(threadId: threadId, event: event) }
        return true
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
        guard applyDecodedTaskEvents(method: method, params: params, fallbackThreadId: selectedThreadId) else { return }
        switch method {
        case "turn/started":
            let metadata = TurnMetadata(json: params["turn"] ?? .object([:]))
            if let turnId = params["turn"]?["id"]?.stringValue {
                completedTurnIds.remove(turnId)
            }
            markTurnActive(params["turn"]?["id"]?.stringValue, startedAt: metadata.startedAt)
        case "turn/completed", "turn/aborted", "turn/interrupted", "turn/failed":
            flushPendingDetailDeltas()
            let turn = params["turn"] ?? .object([:])
            let turnId = turn["id"]?.stringValue ?? eventTurnId
            if let turnId {
                completedTurnIds.insert(turnId)
                var metadata = TurnMetadata(json: turn)
                if method == "turn/aborted" || method == "turn/interrupted" {
                    metadata.status = "interrupted"
                } else if method == "turn/failed" {
                    metadata.status = "failed"
                }
                if metadata.durationMs == nil, metadata.completedAt == nil { metadata.completedAt = Date() }
                turnMetadata[turnId] = metadata
                for itemJSON in turn["items"]?.arrayValue ?? [] {
                    if let item = TranscriptItem.from(json: itemJSON, turnId: turnId) { upsert(item) }
                }
            }
            let completedActiveTurn = activeTurnId == nil || turnId == activeTurnId
            if completedActiveTurn {
                if let selectedThreadId {
                    setThreadStatus(selectedThreadId, status: "idle")
                }
                liveSessionSyncTask?.cancel()
                liveSessionSyncTask = nil
            }
            Task {
                await refreshThreads(showErrors: false)
                if let selectedThreadId { await refreshGoal(threadId: selectedThreadId) }
            }
            if let selectedThreadId {
                notifyTaskCompleted(threadId: selectedThreadId, turnId: turnId, failed: method == "turn/failed")
            }
            scheduleCompletionReconciliation(threadId: selectedThreadId)
        case "item/started", "item/completed":
            guard eventTurnId.map({ !completedTurnIds.contains($0) }) ?? true else { break }
            markTurnActive(eventTurnId)
            if method == "item/completed" { flushPendingDetailDeltas() }
            if let itemJSON = params["item"], let item = TranscriptItem.from(json: itemJSON, turnId: eventTurnId) { upsert(item) }
        case "item/agentMessage/delta":
            guard eventTurnId.map({ !completedTurnIds.contains($0) }) ?? true else { break }
            markTurnActive(eventTurnId)
            appendDelta(id: params["itemId"]?.stringValue, delta: params["delta"]?.stringValue, turnId: eventTurnId, role: .assistant, kind: .message)
        case "item/reasoning/summaryTextDelta", "item/reasoningSummaryText/delta":
            guard eventTurnId.map({ !completedTurnIds.contains($0) }) ?? true else { break }
            markTurnActive(eventTurnId)
            appendDelta(id: params["itemId"]?.stringValue, delta: params["delta"]?.stringValue, turnId: eventTurnId, role: .tool, kind: .reasoning, title: "思考")
        case "item/reasoning/textDelta":
            guard eventTurnId.map({ !completedTurnIds.contains($0) }) ?? true else { break }
            markTurnActive(eventTurnId)
            appendDetail(id: params["itemId"]?.stringValue, delta: params["delta"]?.stringValue, turnId: eventTurnId, kind: .reasoning)
        case "item/commandExecution/outputDelta":
            guard eventTurnId.map({ !completedTurnIds.contains($0) }) ?? true else { break }
            markTurnActive(eventTurnId)
            appendDetail(id: params["itemId"]?.stringValue, delta: params["delta"]?.stringValue, turnId: eventTurnId, kind: .command)
        case "turn/plan/updated":
            break
        case "thread/tokenUsage/updated":
            if let threadId = params["threadId"]?.stringValue, let usage = params["tokenUsage"] {
                tokenUsageByThread[threadId] = ThreadTokenUsage(json: usage)
            }
        case "thread/compacted":
            if let turnId = eventTurnId {
                messages = TranscriptReconciler.removeCompactionSummary(turnId: turnId, from: messages)
                upsert(TranscriptItem(id: "compaction.\(turnId)", turnId: turnId, role: .tool, kind: .contextCompaction, title: "已压缩上下文", text: "Codex 已整理较早的对话内容，为后续工作释放上下文空间。", status: "completed"))
            }
        case "thread/settings/updated":
            if let model = params["threadSettings"]?["model"]?.stringValue { selectedModelId = model }
            if let effort = params["threadSettings"]?["effort"]?.stringValue { selectedEffort = effort }
            persistGenerationSettings()
        case "error":
            let message = params["error"]?["message"]?.stringValue
                ?? params["message"]?.stringValue
                ?? "Codex reported an error."
            let threadId = params["threadId"]?.stringValue ?? selectedThreadId
            if params["willRetry"]?.boolValue != true {
                errorMessage = message
                if params["willRetry"]?.boolValue == false, let threadId {
                    markSelectedThreadFailed(threadId: threadId, turnId: eventTurnId, message: message)
                }
            }
        default:
            break
        }
    }

    private func applyBackgroundEvent(method: String, params: JSONValue, threadId: String) {
        let turnId = params["turnId"]?.stringValue ?? params["turn"]?["id"]?.stringValue
        guard applyDecodedTaskEvents(method: method, params: params, fallbackThreadId: threadId) else { return }
        switch method {
        case "turn/started", "item/started", "item/completed", "item/agentMessage/delta",
             "item/reasoning/summaryTextDelta", "item/reasoningSummaryText/delta",
             "item/reasoning/textDelta", "item/commandExecution/outputDelta", "turn/plan/updated":
            if method == "turn/started", let turnId { completedTurnIds.remove(turnId) }
            if threads.first(where: { $0.id == threadId })?.isRunning != true {
                setThreadStatus(threadId, status: "active")
            }
            updateCachedSnapshot(threadId: threadId, isRunning: true, activeTurnId: turnId)
        case "turn/completed", "turn/aborted", "turn/interrupted", "turn/failed":
            if let turnId { completedTurnIds.insert(turnId) }
            let completesKnownTurn = taskRunStates[threadId]?.turnId == nil
                || turnId == nil
                || taskRunStates[threadId]?.turnId == turnId
            if completesKnownTurn {
                setThreadStatus(threadId, status: "idle")
                updateCachedSnapshot(threadId: threadId, isRunning: false, activeTurnId: nil)
            }
            Task {
                await refreshThreads(showErrors: false)
                await refreshGoal(threadId: threadId)
            }
            notifyTaskCompleted(threadId: threadId, turnId: turnId, failed: method == "turn/failed")
        case "error":
            if params["willRetry"]?.boolValue == false {
                if let turnId { completedTurnIds.insert(turnId) }
                setThreadStatus(threadId, status: "idle")
                updateCachedSnapshot(threadId: threadId, isRunning: false, activeTurnId: nil)
            }
        case "thread/tokenUsage/updated":
            if let usage = params["tokenUsage"] {
                tokenUsageByThread[threadId] = ThreadTokenUsage(json: usage)
            }
        default:
            break
        }
    }

    private func markTurnActive(_ turnId: String?, startedAt: Date? = nil) {
        if let selectedThreadId, let turnId {
            guard acceptsTurnEvent(threadId: selectedThreadId, turnId: turnId) else { return }
            applyTaskRunEvent(threadId: selectedThreadId, event: .progress(turnId: turnId, startedAt: startedAt))
        }
        if let selectedThreadId {
            if threads.first(where: { $0.id == selectedThreadId })?.isRunning != true {
                setThreadStatus(selectedThreadId, status: "active")
            }
        }
        guard let turnId else { return }
        if let selectedThreadId {
            bindPendingUserPrompt(to: turnId, threadId: selectedThreadId)
        }
        var metadata = turnMetadata[turnId] ?? TurnMetadata()
        metadata.status = "inProgress"
        metadata.completedAt = nil
        metadata.durationMs = nil
        if metadata.startedAt == nil { metadata.startedAt = startedAt ?? Date() }
        turnMetadata[turnId] = metadata
        ensureLiveSessionSync()
    }

    private func reconcileRuntimeState(_ runtime: JSONValue) {
        guard runtime["known"]?.boolValue == true else { return }
        let runtimeError = runtime["upstreamError"]?.stringValue
        if let selectedThreadId {
            if runtime["upstreamRetrying"]?.boolValue == true {
                applyTaskRunEvent(
                    threadId: selectedThreadId,
                    event: .retrying(
                        turnId: runtime["activeTurnId"]?.stringValue,
                        message: runtimeError ?? "Codex is reconnecting to the upstream service."
                    )
                )
            } else {
                applyTaskRunEvent(threadId: selectedThreadId, event: .clearRetry)
            }
        }
        if runtime["isRunning"]?.boolValue == true {
            let startedAt = runtime["startedAt"]?.doubleValue.map { Date(timeIntervalSince1970: $0) }
            markTurnActive(runtime["activeTurnId"]?.stringValue, startedAt: startedAt)
        } else {
            if let staleTurnId = activeTurnId, var metadata = turnMetadata[staleTurnId], metadata.isRunning {
                metadata.status = runtimeError == nil ? "completed" : "failed"
                metadata.errorMessage = runtimeError
                if metadata.durationMs == nil, metadata.completedAt == nil { metadata.completedAt = Date() }
                turnMetadata[staleTurnId] = metadata
            }
            if let selectedThreadId {
                setThreadStatus(selectedThreadId, status: "idle", touchUpdatedAt: false)
            }
            if let selectedThreadId {
                applyTaskRunEvent(
                    threadId: selectedThreadId,
                    event: .terminal(
                        turnId: runtime["activeTurnId"]?.stringValue,
                        phase: runtimeError == nil ? .completed : .failed,
                        completedAt: Date()
                    )
                )
            }
        }
    }

    private func markSelectedThreadFailed(threadId: String, turnId: String?, message: String) {
        guard selectedThreadId == threadId else { return }
        let failedTurnId = turnId ?? taskRunStates[threadId]?.turnId
        if let failedTurnId {
            completedTurnIds.insert(failedTurnId)
            var metadata = turnMetadata[failedTurnId] ?? TurnMetadata()
            metadata.status = "failed"
            metadata.errorMessage = message
            metadata.completedAt = metadata.completedAt ?? Date()
            if metadata.durationMs == nil, let startedAt = metadata.startedAt {
                metadata.durationMs = Int(max(0, Date().timeIntervalSince(startedAt) * 1000))
            }
            turnMetadata[failedTurnId] = metadata
        }
        liveSessionSyncTask?.cancel()
        liveSessionSyncTask = nil
        setThreadStatus(threadId, status: "idle", touchUpdatedAt: false)
        cacheCurrentThread()
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
            activePlanTurnId: isRunning ? snapshot.activePlanTurnId : nil,
            modelId: snapshot.modelId,
            effort: snapshot.effort,
            cachedAt: Date()
        )
    }

    private func enqueueFollowUp(text: String, readyAttachments: [PendingAttachment], threadId: String) async {
        let clientMessageId = UUID().uuidString
        var params: [String: JSONValue] = [
            "threadId": .string(threadId),
            "clientUserMessageId": .string(clientMessageId),
            "text": .string(text),
            "input": .array(userInput(text: text, attachments: readyAttachments)),
            "sandboxPolicy": workspaceAccess.sandboxPolicy(workingDirectory: currentWorkingDirectory)
        ]
        if let model = selectedModel?.model { params["model"] = .string(model) }
        if !selectedEffort.isEmpty { params["effort"] = .string(selectedEffort) }
        do {
            let result = try await socket.rpc(
                method: "relay/prompt/queue/add",
                params: params,
                timeoutSeconds: 12,
                reconnectOnTimeout: false
            )
            if let item = result["item"], let followUp = QueuedFollowUp(json: item) {
                queuedFollowUps.removeAll { $0.id == followUp.id }
                queuedFollowUps.append(followUp)
                queuedFollowUps.sort { $0.createdAt < $1.createdAt }
            }
            composerText = ""
            attachments = []
        } catch {
            report(error)
        }
    }

    private func refreshPromptQueue() async {
        guard socket.state == .connected else { return }
        do {
            let result = try await socket.rpc(
                method: "relay/prompt/queue/list",
                timeoutSeconds: 12,
                reconnectOnTimeout: false
            )
            queuedFollowUps = (result["items"]?.arrayValue ?? [])
                .compactMap(QueuedFollowUp.init(json:))
                .sorted { $0.createdAt < $1.createdAt }
        } catch {
            report(error, show: false)
        }
    }

    private func applyPromptQueueUpdate(threadId: String, items: [JSONValue]) {
        let replacements = items.compactMap(QueuedFollowUp.init(json:))
        queuedFollowUps.removeAll { $0.threadId == threadId }
        queuedFollowUps.append(contentsOf: replacements)
        queuedFollowUps.sort { $0.createdAt < $1.createdAt }
    }

    private func upsert(_ item: TranscriptItem) {
        TranscriptReconciler.upsert(item, into: &messages)
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
        if var pending = pendingDetailDeltas[id] {
            pending.text += delta
            if pending.turnId == nil { pending.turnId = turnId }
            pendingDetailDeltas[id] = pending
        } else {
            pendingDetailDeltas[id] = PendingDetailDelta(text: delta, turnId: turnId, kind: kind)
        }
        guard detailDeltaFlushTask == nil else { return }
        detailDeltaFlushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled else { return }
            self?.flushPendingDetailDeltas()
        }
    }

    private func flushPendingDetailDeltas() {
        detailDeltaFlushTask?.cancel()
        detailDeltaFlushTask = nil
        guard !pendingDetailDeltas.isEmpty else { return }
        let pending = pendingDetailDeltas
        pendingDetailDeltas.removeAll(keepingCapacity: true)
        var updated = messages
        for (id, value) in pending {
            if let index = updated.firstIndex(where: { $0.id == id }) {
                updated[index].detail = (updated[index].detail ?? "") + value.text
                if updated[index].turnId == nil { updated[index].turnId = value.turnId }
            } else {
                updated.append(TranscriptItem(id: id, turnId: value.turnId, role: .tool, kind: value.kind, title: value.kind == .reasoning ? "思考" : "运行命令", text: "", detail: value.text, status: "inProgress"))
            }
        }
        messages = updated
    }

    private func handleConnectionRestored() async {
        await refreshCodexProfiles(showErrors: false)
        async let threadsRefresh: Void = refreshThreads(showErrors: false)
        async let queueRefresh: Void = refreshPromptQueue()
        _ = await (threadsRefresh, queueRefresh)
        if modelOptions.isEmpty { await refreshModels(showErrors: false) }
        if let selectedThreadId {
            await selectThread(selectedThreadId, closeSidebar: false, showErrors: false)
        } else {
            if let targetThreadId = threads.first?.id {
                await selectThread(targetThreadId, closeSidebar: false, showErrors: false)
            }
        }
    }

    private func handleBridgeStatus(_ message: JSONValue) {
        if let profileId = message["codexProfile"]?["id"]?.stringValue {
            let profileChanged = activeCodexProfileId != profileId
            activeCodexProfileId = profileId
            if profileChanged { loadPinnedThreads() }
        }
        switch message["status"]?.stringValue {
        case "switching":
            isSwitchingCodexProfile = true
            resetForCodexProfileSwitch()
        case "ready" where isSwitchingCodexProfile:
            Task { [weak self] in
                guard let self else { return }
                await self.handleConnectionRestored()
                self.isSwitchingCodexProfile = false
            }
        default:
            break
        }
    }

    private func resetForCodexProfileSwitch() {
        restorationTask?.cancel()
        restorationTask = nil
        liveSessionSyncTask?.cancel()
        liveSessionSyncTask = nil
        subscribedSessionThreadId = nil
        threadLoadGeneration = UUID()
        threads = []
        messages = []
        turnMetadata = [:]
        tokenUsageByThread = [:]
        taskRunStates = [:]
        goalStates = [:]
        sendingThreadIds = []
        queuedFollowUps = []
        pendingApprovals = []
        threadSnapshots.removeAll()
        olderTurnsCursorByThread = [:]
        acceptedMessageIds = []
        outboundDrafts = [:]
        userMessagePlacements = [:]
        nextUserMessageSequence = 0
        completedTurnIds = []
        isLoadingThread = false
        showingArchivedThreads = false
        setSelectedThread(nil)
        UserDefaults.standard.removeObject(forKey: threadCacheDefaultsKey)
    }

    private func waitForRestoration() async {
        guard let task = restorationTask else { return }
        await task.value
    }

    private func scheduleRestoration() {
        guard restorationTask == nil else { return }
        restorationTask = Task { [weak self] in
            guard let self else { return }
            await self.handleConnectionRestored()
            self.restorationTask = nil
        }
    }

    private func ensureLiveSessionSync() {
        guard liveSessionSyncTask == nil,
              isRunning,
              selectedThreadId != nil,
              socket.state == .connected else { return }
        liveSessionSyncTask = Task { [weak self] in
            guard let self, let initialThreadId = self.selectedThreadId else { return }
            if let initial = try? await self.socket.rpc(
                method: "relay/thread/session/subscribe",
                params: ["threadId": .string(initialThreadId)],
                timeoutSeconds: 12,
                reconnectOnTimeout: false
            ) {
                self.subscribedSessionThreadId = initialThreadId
                self.applySessionSnapshot(initial, threadId: initialThreadId)
            }
            while !Task.isCancelled {
                guard let threadId = self.selectedThreadId,
                      self.isRunning,
                      self.socket.state == .connected else { break }
                await self.syncSessionSnapshot(threadId: threadId)
                do {
                    // File notifications provide the low-latency path. This
                    // slower poll is only a reconciliation fallback.
                    try await Task.sleep(nanoseconds: 8_000_000_000)
                } catch {
                    break
                }
            }
            self.liveSessionSyncTask = nil
        }
    }

    private func syncSessionSnapshot(threadId: String) async {
        do {
            let result = try await socket.rpc(
                method: "relay/thread/session/snapshot",
                params: ["threadId": .string(threadId)],
                timeoutSeconds: 12,
                reconnectOnTimeout: false
            )
            applySessionSnapshot(result, threadId: threadId)
        } catch {
            // Connection recovery owns transport errors; polling should not raise repeated alerts.
        }
    }

    private func applySessionSnapshot(_ result: JSONValue, threadId: String) {
        guard selectedThreadId == threadId,
              result["known"]?.boolValue == true,
              let turnId = result["turnId"]?.stringValue else { return }

        let snapshotIsStale = result["stale"]?.boolValue == true
        if result["isRunning"]?.boolValue == true, !snapshotIsStale {
            bindPendingUserPrompt(to: turnId, threadId: threadId)
        }

        let snapshotItems = result["items"]?.arrayValue?.compactMap {
            TranscriptItem.from(json: $0, turnId: turnId)
        } ?? []
        if !snapshotItems.isEmpty { mergeSessionItems(snapshotItems, turnId: turnId) }

        var metadata = turnMetadata[turnId] ?? TurnMetadata()
        if let startedAt = result["startedAt"]?.doubleValue {
            metadata.startedAt = Date(timeIntervalSince1970: startedAt)
        }
        if result["isRunning"]?.boolValue == true {
            metadata.status = "inProgress"
            metadata.completedAt = nil
            metadata.durationMs = nil
            turnMetadata[turnId] = metadata
            setThreadStatus(threadId, status: "active", touchUpdatedAt: false)
            applyTaskRunEvent(threadId: threadId, event: .progress(turnId: turnId, startedAt: metadata.startedAt))
        } else {
            metadata.status = snapshotIsStale ? "interrupted" : "completed"
            if snapshotIsStale { metadata.durationMs = nil }
            if let completedAt = result["completedAt"]?.doubleValue {
                metadata.completedAt = Date(timeIntervalSince1970: completedAt)
            } else if metadata.completedAt == nil {
                metadata.completedAt = Date()
            }
            turnMetadata[turnId] = metadata
            if activeTurnId == nil || activeTurnId == turnId {
                completedTurnIds.insert(turnId)
                setThreadStatus(threadId, status: "idle")
                liveSessionSyncTask?.cancel()
                liveSessionSyncTask = nil
            }
            applyTaskRunEvent(
                threadId: threadId,
                event: .terminal(
                    turnId: turnId,
                    phase: snapshotIsStale ? .interrupted : .completed,
                    completedAt: metadata.completedAt
                )
            )
        }
        cacheCurrentThread()
    }

    private func bindPendingUserPrompt(to turnId: String, threadId: String) {
        guard selectedThreadId == threadId else { return }
        var pending: (messageId: String, sequence: Int)?
        for (messageId, placement) in userMessagePlacements {
            guard placement.threadId == threadId, placement.turnId == nil,
                  let message = messages.first(where: { $0.id == messageId }),
                  (message.deliveryState == .sending || message.deliveryState == .accepted) else { continue }
            if let current = pending, current.sequence >= placement.sequence {
                continue
            } else {
                pending = (messageId, placement.sequence)
            }
        }
        guard let messageId = pending?.messageId else { return }
        bindUserPrompt(messageId, to: turnId, threadId: threadId)
    }

    private func bindUserPrompt(_ messageId: String, to turnId: String, threadId: String) {
        guard selectedThreadId == threadId,
              userMessagePlacements[messageId]?.threadId == threadId else { return }
        userMessagePlacements[messageId]?.turnId = turnId
        applyUserMessagePlacements(turnId: turnId, threadId: threadId)
    }

    private func mergeSessionItems(_ snapshotItems: [TranscriptItem], turnId: String) {
        messages = TranscriptReconciler.mergeSessionItems(snapshotItems, turnId: turnId, into: messages)
        applyUserMessagePlacements(turnId: turnId, threadId: selectedThreadId ?? "")
    }

    private func applyUserMessagePlacements(turnId: String, threadId: String) {
        messages = TranscriptReconciler.applyUserMessagePlacements(
            userMessagePlacements,
            turnId: turnId,
            threadId: threadId,
            to: messages
        )
    }

    private func cacheCurrentThread() {
        guard let selectedThreadId else { return }
        threadSnapshots.store(ThreadSnapshot(
            messages: messages,
            turnMetadata: turnMetadata,
            isRunning: isRunning,
            activeTurnId: activeTurnId,
            activePlan: activePlan,
            activePlanTurnId: taskRunStates[selectedThreadId]?.planTurnId,
            modelId: selectedModelId,
            effort: selectedEffort,
            cachedAt: Date()
        ), for: selectedThreadId, preserving: selectedThreadId)
    }

    @discardableResult
    private func restoreThreadSnapshot(_ threadId: String) -> Bool {
        guard let snapshot = threadSnapshots[threadId] else { return false }
        messages = snapshot.messages
        turnMetadata = snapshot.turnMetadata
        applyTaskRunEvent(
            threadId: threadId,
            event: .hydrate(
                running: snapshot.isRunning,
                turnId: snapshot.activeTurnId,
                startedAt: snapshot.activeTurnId.flatMap { snapshot.turnMetadata[$0]?.startedAt }
            )
        )
        if let turnId = snapshot.activeTurnId, snapshot.activePlanTurnId == turnId {
            applyTaskRunEvent(threadId: threadId, event: .plan(turnId: turnId, steps: snapshot.activePlan))
        }
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

private struct OutboundDraft {
    let threadId: String
    let text: String
    let attachments: [PendingAttachment]
}

private struct PendingDetailDelta {
    var text: String
    var turnId: String?
    let kind: TranscriptKind
}
