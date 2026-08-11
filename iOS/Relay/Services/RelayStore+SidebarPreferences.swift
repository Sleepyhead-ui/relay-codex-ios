import Foundation

@MainActor
extension RelayStore {
    func loadSidebarPreferences() async {
        guard socket.state == .connected else { return }
        do {
            let result = try await socket.rpc(
                method: "relay/preferences/get",
                timeoutSeconds: 8,
                reconnectOnTimeout: false
            )
            applySidebarPreferences(result["sidebar"] ?? result, persist: true)
        } catch {
            // The locally persisted choice remains usable while an older Bridge is running.
        }
    }

    func setSidebarOrganization(_ value: SidebarOrganization) {
        sidebarOrganization = value
        persistSidebarPreferences()
    }

    func setSidebarSort(_ value: SidebarSort) {
        sidebarSort = value
        persistSidebarPreferences()
    }

    func applySidebarPreferences(_ value: JSONValue, persist: Bool) {
        let selection = SidebarPreferencesSelection(
            organization: sidebarOrganization,
            sort: sidebarSort
        ).merging(json: value)
        sidebarOrganization = selection.organization
        sidebarSort = selection.sort
        if persist { persistSidebarPreferencesLocally() }
    }

    private func persistSidebarPreferences() {
        persistSidebarPreferencesLocally()
        guard socket.state == .connected else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await socket.rpc(
                    method: "relay/preferences/update",
                    params: [
                        "sidebar": .object([
                            "organization": .string(sidebarOrganization.rawValue),
                            "sort": .string(sidebarSort.rawValue)
                        ])
                    ],
                    timeoutSeconds: 8,
                    reconnectOnTimeout: false
                )
            } catch {
                // Keep the local value and retry on the next connection.
            }
        }
    }

    private func persistSidebarPreferencesLocally() {
        UserDefaults.standard.set(sidebarOrganization.rawValue, forKey: "relay.sidebar.organization")
        UserDefaults.standard.set(sidebarSort.rawValue, forKey: "relay.sidebar.sort")
    }
}
