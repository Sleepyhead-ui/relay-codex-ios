import Foundation

@MainActor
extension RelayStore {
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
}
