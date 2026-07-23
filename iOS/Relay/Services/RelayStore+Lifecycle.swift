import Foundation

@MainActor
extension RelayStore {
    func refreshDiagnostics() async {
        guard socket.state == .connected else { return }
        do {
            let result = try await socket.rpc(method: "relay/diagnostics/report", timeoutSeconds: 12, reconnectOnTimeout: false)
            var combined = result.objectValue ?? [:]
            combined["clientPerformance"] = socket.performanceMetrics.report()
            diagnosticsReport = DiagnosticsReport(json: .object(combined))
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
        taskStateCore.reset()
        goalStates = [:]
        sendingThreadIds = []
        queuedFollowUps = []
        pendingApprovals = []
        acceptedMessageIds = []
        outboundDrafts = [:]
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
}
