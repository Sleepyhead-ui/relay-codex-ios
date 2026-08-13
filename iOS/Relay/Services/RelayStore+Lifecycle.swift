import Foundation

@MainActor
extension RelayStore {
    func refreshDiagnostics() async {
        guard socket.state == .connected else { return }
        do {
            let result = try await socket.rpc(method: "relay/diagnostics/report", timeoutSeconds: 12, reconnectOnTimeout: false)
            var combined = result.objectValue ?? [:]
            combined["appBuild"] = AppBuildIdentity().json
            combined["clientPerformance"] = socket.performanceMetrics.report()
            let uniqueMessageIds = Set(messages.map(\.id)).count
            combined["clientState"] = .object([
                "selectedThreadId": selectedThreadId.map(JSONValue.string) ?? .null,
                "isRunning": .bool(isRunning),
                "activeTurnId": activeTurnId.map(JSONValue.string) ?? .null,
                "messageCount": .number(Double(messages.count)),
                "uniqueMessageIdCount": .number(Double(uniqueMessageIds)),
                "duplicateMessageIdCount": .number(Double(messages.count - uniqueMessageIds))
            ])
            let timelineViolations = TranscriptTimelineAudit.violations(in: messages)
            var checks = combined["checks"]?.arrayValue ?? []
            checks.append(.object([
                "id": .string("ios-transcript-timeline"),
                "level": .string(timelineViolations.isEmpty ? "ok" : "error"),
                "title": .string("对话时间线"),
                "detail": .string(timelineViolations.isEmpty
                    ? "当前消息顺序通过唯一 ID、连续任务分组和首条提示词位置检查。"
                    : "检测到 \(timelineViolations.count) 项顺序异常，诊断导出中包含脱敏回放轨迹。")
            ]))
            combined["checks"] = .array(checks)
            combined["transcriptTrace"] = transcriptTrace.report(currentMessages: messages)
            combined["transcriptScroll"] = TranscriptScrollDiagnostics.shared.report()
            diagnosticsReport = DiagnosticsReport(json: .object(combined))
        } catch {
            report(error)
        }
    }

    func prepareDiagnosticsExport() async -> SharedFile? {
        guard let snapshot = diagnosticsReport?.raw else { return nil }
        do {
            let url = try await Task.detached(priority: .userInitiated) {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(snapshot)
                guard data.count <= 8 * 1_024 * 1_024 else {
                    throw DiagnosticsExportError.reportTooLarge
                }
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("Relay-Diagnostics-\(UUID().uuidString).json")
                try data.write(to: url, options: .atomic)
                return url
            }.value
            return SharedFile(url: url)
        } catch {
            report(error)
            return nil
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
            presentation.sharedFile = SharedFile(url: localURL)
        } catch {
            report(error)
        }
    }

    func forgetHost() {
        let forgottenHostId = currentHostId
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
        taskStateCore.reset()
        goalStates = [:]
        sendingThreadIds = []
        queuedFollowUps = []
        pendingApprovals = []
        resolvingApprovalIds = []
        acceptedMessageIds = []
        outboundDrafts = [:]
        forgetOutboundDeliveries(hostId: forgottenHostId)
        threadSnapshots.removeAll()
        transcriptTrace.reset()
        olderTurnsCursorByThread = [:]
        hasOlderTurns = false
        workingDirectoryOverrides = [:]
        showingSettings = false
        showingConnection = true
    }

    func consumePairingURL(_ url: URL) {
        guard url.scheme == "relay",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        if url.host == "thread",
           let threadId = components.queryItems?.first(where: { $0.name == "threadId" })?.value?.nonEmpty {
            Task { await handleNotificationAction(.openThread(threadId)) }
            return
        }
        if url.host == "open" { return }
        guard let pairing = PairingPayload(url: url) else { return }
        host.endpoint = pairing.endpoint
        host.name = pairing.computerName
        token = pairing.token
        if let existing = savedHosts.first(where: { $0.endpoint.caseInsensitiveCompare(host.endpoint) == .orderedSame }) {
            currentHostId = existing.id
        } else {
            currentHostId = UUID().uuidString
        }
        showingConnection = true
    }
}

private enum DiagnosticsExportError: LocalizedError {
    case reportTooLarge

    var errorDescription: String? {
        switch self {
        case .reportTooLarge:
            return "The diagnostics report is too large to share."
        }
    }
}
