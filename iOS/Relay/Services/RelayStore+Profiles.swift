import Foundation

@MainActor
extension RelayStore {
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
            // The Bridge's switching notification owns the reset. Resetting
            // again here can erase conversations already restored by a fast
            // ready notification that overtook this RPC response.
        } catch {
            isSwitchingCodexProfile = false
            report(error)
        }
    }
}
