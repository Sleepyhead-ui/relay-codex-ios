import Foundation

@MainActor
extension RelayStore {
    func storeOutboundDelivery(
        id: String,
        draft: OutboundDraft,
        placement: UserMessagePlacement
    ) {
        outboundDrafts[id] = draft
        userMessagePlacements[id] = placement
        guard !currentHostId.isEmpty, !activeCodexProfileId.isEmpty else { return }
        persistedOutboundDeliveries[id] = OutboundDeliveryEnvelope(
            id: id,
            hostId: currentHostId,
            profileId: activeCodexProfileId,
            draft: draft,
            sequence: placement.sequence,
            createdAt: Date()
        )
        persistOutboundDeliveryOutbox()
    }

    func removeOutboundDelivery(_ id: String) {
        outboundDrafts.removeValue(forKey: id)
        persistedOutboundDeliveries.removeValue(forKey: id)
        persistOutboundDeliveryOutbox()
    }

    func restoreOutboundDeliveriesForCurrentScope() {
        guard !currentHostId.isEmpty, !activeCodexProfileId.isEmpty else { return }
        let records = OutboundDeliveryOutbox.scoped(
            persistedOutboundDeliveries,
            hostId: currentHostId,
            profileId: activeCodexProfileId
        )
        for record in records {
            outboundDrafts[record.id] = record.draft
            if userMessagePlacements[record.id] == nil {
                userMessagePlacements[record.id] = UserMessagePlacement(
                    threadId: record.draft.threadId,
                    turnId: record.draft.expectedTurnId,
                    afterItemId: nil,
                    sequence: record.sequence
                )
            }
            nextUserMessageSequence = max(nextUserMessageSequence, record.sequence)
        }
    }

    func forgetOutboundDeliveries(hostId: String) {
        persistedOutboundDeliveries = persistedOutboundDeliveries.filter { $0.value.hostId != hostId }
        persistOutboundDeliveryOutbox()
    }

    func outboundTranscriptItem(id: String, draft: OutboundDraft) -> TranscriptItem {
        let attachmentSummary = draft.attachments
            .filter { !$0.isImage }
            .map { "附件 \($0.name)" }
            .joined(separator: "\n")
        return TranscriptItem(
            id: id,
            turnId: draft.expectedTurnId,
            role: .user,
            kind: .message,
            text: [draft.text, attachmentSummary].filter { !$0.isEmpty }.joined(separator: "\n\n"),
            deliveryState: persistedOutboundDeliveries[id]?.automaticallyRecoverable == false
                ? .failed("上次发送未能启动任务，可编辑后重新发送。")
                : .uncertain("正在等待 Windows 确认是否送达。"),
            imagePaths: draft.attachments.filter(\.isImage).compactMap(\.remotePath)
        )
    }

    private func setOutboundDeliveryAutomaticallyRecoverable(_ id: String, _ recoverable: Bool) {
        guard var envelope = persistedOutboundDeliveries[id],
              envelope.automaticallyRecoverable != recoverable else { return }
        envelope.automaticallyRecoverable = recoverable
        persistedOutboundDeliveries[id] = envelope
        persistOutboundDeliveryOutbox()
    }

    private func markOutboundDeliveryFailed(_ id: String, message: String, threadId: String) {
        acceptedMessageIds.remove(id)
        setOutboundDeliveryAutomaticallyRecoverable(id, false)
        updateDeliveryState(id, state: .failed(message), threadId: threadId)
    }

    private func persistOutboundDeliveryOutbox() {
        persistedOutboundDeliveries = OutboundDeliveryOutbox.pruned(persistedOutboundDeliveries)
        let records = persistedOutboundDeliveries.values.sorted { $0.createdAt < $1.createdAt }
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: outboundDeliveryOutboxDefaultsKey)
    }

    func handleDeliveryUpdate(_ message: JSONValue) {
        guard message["profileId"]?.stringValue == activeCodexProfileId,
              let id = message["clientUserMessageId"]?.stringValue,
              outboundDrafts[id] != nil else { return }
        applyDeliveryResolution(message, id: id)
    }

    func reconcileOutboundDeliveries() async {
        guard socket.state == .connected, !outboundDrafts.isEmpty else { return }
        let pending = OutboundDeliveryOutbox.automaticallyRecoverableScoped(
            persistedOutboundDeliveries,
            hostId: currentHostId,
            profileId: activeCodexProfileId
        )
        for envelope in pending {
            let id = envelope.id
            let threadId = envelope.draft.threadId
            guard outboundDrafts[id] != nil, socket.state == .connected else { continue }
            do {
                let result = try await socket.rpc(
                    method: "relay/delivery/status",
                    params: [
                        "threadId": .string(threadId),
                        "clientUserMessageId": .string(id)
                    ],
                    timeoutSeconds: 12,
                    reconnectOnTimeout: false
                )
                if result["status"]?.stringValue == "unknown" {
                    await retryOutboundDelivery(id: id, threadId: threadId)
                } else {
                    applyDeliveryResolution(result, id: id)
                }
            } catch {
                updateDeliveryState(id, state: .uncertain("连接已恢复，仍在等待 Windows 确认。"), threadId: threadId)
            }
        }
    }

    private func retryOutboundDelivery(id: String, threadId: String) async {
        guard let draft = outboundDrafts[id], socket.state == .connected else { return }
        let expectedTurnId = draft.expectedTurnId ?? userMessagePlacements[id]?.turnId
        let runtime: JSONValue?
        do {
            runtime = try await socket.rpc(
                method: "relay/thread/runtime",
                params: ["threadId": .string(threadId)],
                timeoutSeconds: 12,
                reconnectOnTimeout: false
            )
        } catch {
            runtime = nil
        }
        let running = runtime?["isRunning"]?.boolValue == true
        switch DeliveryRecoveryPolicy.action(
            expectedTurnId: expectedTurnId,
            runtimeRunning: running,
            activeTurnId: runtime?["activeTurnId"]?.stringValue
        ) {
        case .waitForHistory:
            updateDeliveryState(id, state: .uncertain("任务已经开始，正在等待对话记录确认消息。"), threadId: threadId)
            return
        case .rejectStaleSteer:
            markOutboundDeliveryFailed(
                id,
                message: "原任务已经结束，无法重试这条引导。可编辑后作为新消息发送。",
                threadId: threadId
            )
            return
        case .retry:
            break
        }

        sendingThreadIds.insert(threadId)
        updateDeliveryState(id, state: .sending, threadId: threadId)
        defer { sendingThreadIds.remove(threadId) }
        do {
            let input = userInput(text: draft.text, attachments: draft.attachments)
            let result: JSONValue
            if let expectedTurnId {
                result = try await socket.rpc(
                    method: "turn/steer",
                    params: [
                        "threadId": .string(threadId),
                        "expectedTurnId": .string(expectedTurnId),
                        "clientUserMessageId": .string(id),
                        "input": .array(input)
                    ],
                    timeoutSeconds: 120,
                    reconnectOnTimeout: false,
                    onAccepted: { [weak self] in self?.markMessageAccepted(id, threadId: threadId) }
                )
            } else {
                var params: [String: JSONValue] = [
                    "threadId": .string(threadId),
                    "clientUserMessageId": .string(id),
                    "input": .array(input),
                    "summary": .string("detailed"),
                    "sandboxPolicy": draft.sandboxPolicy
                        ?? WorkspaceAccessMode.workspaceWrite.sandboxPolicy(
                            workingDirectory: threads.first(where: { $0.id == threadId })?.cwd ?? host.workingDirectory
                        )
                ]
                if let model = draft.model { params["model"] = .string(model) }
                if let effort = draft.effort { params["effort"] = .string(effort) }
                if let collaborationMode = draft.collaborationMode {
                    params["collaborationMode"] = collaborationMode
                }
                result = try await socket.rpc(
                    method: "turn/start",
                    params: params,
                    timeoutSeconds: 120,
                    reconnectOnTimeout: false,
                    onAccepted: { [weak self] in self?.markMessageAccepted(id, threadId: threadId) }
                )
            }
            let turnId = result["turn"]?["id"]?.stringValue ?? result["turnId"]?.stringValue ?? expectedTurnId
            updateDeliveryState(id, state: nil, threadId: threadId, turnId: turnId)
            if let turnId, selectedThreadId == threadId { bindUserPrompt(id, to: turnId, threadId: threadId) }
            acceptedMessageIds.remove(id)
            removeOutboundDelivery(id)
        } catch {
            let accepted = acceptedMessageIds.remove(id) != nil
            if isUncertainDeliveryFailure(error, bridgeAccepted: accepted) {
                updateDeliveryState(
                    id,
                    state: .uncertain("消息已重新交给 Windows，正在等待确认。"),
                    threadId: threadId
                )
            } else {
                markOutboundDeliveryFailed(id, message: error.localizedDescription, threadId: threadId)
            }
        }
    }

    private func applyDeliveryResolution(_ result: JSONValue, id: String) {
        guard let draft = outboundDrafts[id] else { return }
        let status = result["status"]?.stringValue
        if status == "pending" {
            acceptedMessageIds.insert(id)
            updateDeliveryState(id, state: .accepted, threadId: draft.threadId)
            return
        }
        guard status == "completed" else {
            updateDeliveryState(id, state: .uncertain("Windows 尚未确认是否收到这条消息。"), threadId: draft.threadId)
            return
        }
        if let error = result["error"]?["message"]?.stringValue {
            markOutboundDeliveryFailed(id, message: error, threadId: draft.threadId)
            return
        }
        let turnId = result["turnId"]?.stringValue
            ?? result["result"]?["turn"]?["id"]?.stringValue
            ?? result["result"]?["turnId"]?.stringValue
        updateDeliveryState(id, state: nil, threadId: draft.threadId, turnId: turnId)
        if let turnId, selectedThreadId == draft.threadId {
            bindUserPrompt(id, to: turnId, threadId: draft.threadId)
        }
        acceptedMessageIds.remove(id)
        removeOutboundDelivery(id)
    }

    func restoreMessageToComposer(_ id: String) {
        guard let draft = outboundDrafts[id], draft.threadId == selectedThreadId else { return }
        guard DeliveryFailurePolicy.canEditFailedTurnStart(expectedTurnId: draft.expectedTurnId) else { return }
        guard composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, attachments.isEmpty else {
            errorMessage = "请先发送或清空当前输入框，再恢复这条消息。"
            return
        }
        composerText = draft.text
        attachments = draft.attachments
        messages.removeAll { $0.id == id }
        userMessagePlacements.removeValue(forKey: id)
        removeOutboundDelivery(id)
        acceptedMessageIds.remove(id)
    }

    func canEditFailedTurnStart(_ id: String) -> Bool {
        guard let draft = outboundDrafts[id] else { return false }
        return DeliveryFailurePolicy.canEditFailedTurnStart(expectedTurnId: draft.expectedTurnId)
    }

    func confirmMessageDelivery(_ id: String) async {
        guard let draft = outboundDrafts[id], draft.threadId == selectedThreadId else { return }
        await selectThread(draft.threadId, closeSidebar: false, showErrors: false)
        if messages.contains(where: { $0.id == id && $0.deliveryState == nil }) {
            removeOutboundDelivery(id)
            acceptedMessageIds.remove(id)
        } else {
            markOutboundDeliveryFailed(
                id,
                message: "Windows 对话历史中暂未找到这条消息。",
                threadId: draft.threadId
            )
        }
    }

    func markMessageAccepted(_ id: String, threadId: String) {
        acceptedMessageIds.insert(id)
        sendingThreadIds.remove(threadId)
        updateDeliveryState(id, state: .accepted, threadId: threadId)
    }

    func updateDeliveryState(
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

    func isUncertainDeliveryFailure(_ error: Error, bridgeAccepted: Bool) -> Bool {
        guard let socketError = error as? RelaySocket.SocketError else {
            return DeliveryFailurePolicy.disposition(
                remoteMessage: nil,
                bridgeAccepted: bridgeAccepted,
                transportConnected: socket.state == .connected
            ) == .uncertain
        }
        switch socketError {
        case .disconnected: return true
        case .invalidEndpoint: return false
        case .uncertainRemote: return true
        case .remote(let message):
            return DeliveryFailurePolicy.disposition(
                remoteMessage: message,
                bridgeAccepted: bridgeAccepted,
                transportConnected: socket.state == .connected
            ) == .uncertain
        }
    }

    func userInput(text: String, attachments: [PendingAttachment]) -> [JSONValue] {
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

    func sendPrompt() async {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        let readyAttachments = attachments.filter { $0.state == .ready && $0.remotePath != nil }
        let hasQueuedAttachments = editingQueuedFollowUp?.input.contains { $0["type"]?.stringValue != "text" } == true
        guard !text.isEmpty || !readyAttachments.isEmpty || hasQueuedAttachments else { return }
        guard socket.state == .connected else {
            socket.reconnectIfNeeded()
            errorMessage = "尚未连接到 Windows，消息仍保留在输入框中。Relay 正在重新连接。"
            return
        }
        guard !isPreparingPrompt else { return }
        isPreparingPrompt = true
        defer { isPreparingPrompt = false }
        await waitForRestoration()
        guard socket.state == .connected else {
            socket.reconnectIfNeeded()
            errorMessage = "Windows 连接已恢复，请稍后重试；输入内容仍保留在输入框中。"
            return
        }
        if editingQueuedFollowUp != nil {
            await saveQueuedFollowUpEdit(text: text, newAttachments: readyAttachments)
            return
        }
        if selectedThreadId == nil { await newThread() }
        guard let threadId = selectedThreadId else { return }
        if !isRunning, composerMode == .plan, collaborationModePayload() == nil {
            errorMessage = "计划模式仍在准备运行配置，请稍后重试；输入内容已保留。"
            return
        }
        if !isRunning, composerMode == .goal {
            guard !text.isEmpty else {
                errorMessage = "目标模式需要输入目标内容。"
                return
            }
            guard await setGoal(objective: text, threadId: threadId) else { return }
            composerMode = .standard
        }
        if isRunning, followUpBehavior == .queue {
            await enqueueFollowUp(text: text, readyAttachments: readyAttachments, threadId: threadId)
        } else if isRunning {
            await steerActiveTurn(text: text, readyAttachments: readyAttachments, threadId: threadId)
        } else {
            composerText = ""
            attachments = []
            await startTurn(text: text, readyAttachments: readyAttachments, threadId: threadId)
        }
    }

    func submitNotificationReply(_ source: String, threadId: String, clientMessageId: String) async -> Bool {
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, selectedThreadId == threadId else { return false }
        if isPreparingPrompt {
            for _ in 0..<20 where isPreparingPrompt {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        guard !isPreparingPrompt, socket.state == .connected else { return false }
        if isRunning {
            if followUpBehavior == .queue {
                return await enqueueFollowUp(
                    text: text,
                    readyAttachments: [],
                    threadId: threadId,
                    clientMessageId: clientMessageId
                )
            }
            return await steerActiveTurn(
                text: text,
                readyAttachments: [],
                threadId: threadId,
                clientMessageId: clientMessageId
            )
        }
        return await startTurn(
            text: text,
            readyAttachments: [],
            threadId: threadId,
            clientMessageId: clientMessageId
        )
    }

    func beginEditingQueuedFollowUp(_ item: QueuedFollowUp) {
        guard item.threadId == selectedThreadId else { return }
        guard composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, attachments.isEmpty else {
            errorMessage = "请先发送或清空当前输入框，再编辑排队消息。"
            return
        }
        editingQueuedFollowUp = item
        composerText = item.text
    }

    func cancelQueuedFollowUpEdit() {
        guard editingQueuedFollowUp != nil else { return }
        editingQueuedFollowUp = nil
        composerText = ""
        attachments = []
    }

    private func saveQueuedFollowUpEdit(text: String, newAttachments: [PendingAttachment]) async {
        guard let editing = editingQueuedFollowUp, editing.threadId == selectedThreadId else { return }
        let preservedAttachments = editing.input.filter { $0["type"]?.stringValue != "text" }
        let input = userInput(text: text, attachments: newAttachments) + preservedAttachments
        guard !input.isEmpty else { return }
        do {
            let result = try await socket.rpc(
                method: "relay/prompt/queue/update",
                params: [
                    "id": .string(editing.id),
                    "text": .string(text),
                    "input": .array(input)
                ],
                timeoutSeconds: 12,
                reconnectOnTimeout: false
            )
            if let item = result["item"], let updated = QueuedFollowUp(json: item) {
                queuedFollowUps.removeAll { $0.id == updated.id }
                queuedFollowUps.append(updated)
                queuedFollowUps.sort { $0.createdAt < $1.createdAt }
            }
            editingQueuedFollowUp = nil
            composerText = ""
            attachments = []
        } catch {
            report(error)
        }
    }

    @discardableResult
    private func startTurn(
        text: String,
        readyAttachments: [PendingAttachment],
        threadId: String,
        clientMessageId: String = UUID().uuidString
    ) async -> Bool {
        nextUserMessageSequence += 1
        let placement = UserMessagePlacement(
            threadId: threadId,
            turnId: nil,
            afterItemId: nil,
            sequence: nextUserMessageSequence
        )
        let sandboxPolicy = workspaceAccess.sandboxPolicy(workingDirectory: currentWorkingDirectory)
        let model = selectedModel?.model
        let effort = selectedEffort.isEmpty ? nil : selectedEffort
        let collaborationMode = collaborationModePayload()
        let draft = OutboundDraft(
            threadId: threadId,
            text: text,
            attachments: readyAttachments,
            sandboxPolicy: sandboxPolicy,
            model: model,
            effort: effort,
            collaborationMode: collaborationMode
        )
        storeOutboundDelivery(id: clientMessageId, draft: draft, placement: placement)
        sendingThreadIds.insert(threadId)
        applyTaskRunEvent(threadId: threadId, event: .starting(startedAt: Date()))
        setThreadStatus(threadId, status: "active")
        let attachmentSummary = readyAttachments.filter { !$0.isImage }.map { "📎 \($0.name)" }.joined(separator: "\n")
        let displayText = [text, attachmentSummary].filter { !$0.isEmpty }.joined(separator: "\n\n")
        messages.append(TranscriptItem(
            id: clientMessageId,
            role: .user,
            kind: .message,
            text: displayText,
            deliveryState: .sending,
            imagePaths: readyAttachments.filter(\.isImage).compactMap(\.remotePath)
        ))
        defer { sendingThreadIds.remove(threadId) }
        do {
            var params: [String: JSONValue] = [
                "threadId": .string(threadId),
                "clientUserMessageId": .string(clientMessageId),
                "input": .array(userInput(text: text, attachments: readyAttachments)),
                "summary": .string("detailed"),
                "sandboxPolicy": sandboxPolicy
            ]
            if let model { params["model"] = .string(model) }
            if let effort { params["effort"] = .string(effort) }
            if let collaborationMode { params["collaborationMode"] = collaborationMode }
            let result = try await socket.rpc(
                method: "turn/start",
                params: params,
                timeoutSeconds: 120,
                reconnectOnTimeout: false,
                onAccepted: { [weak self] in self?.markMessageAccepted(clientMessageId, threadId: threadId) }
            )
            let confirmedTurnId = result["turn"]?["id"]?.stringValue
            if let confirmedTurnId {
                let existingMetadata = turnMetadata[confirmedTurnId]
                let alreadyCompleted = taskStateCore.isCompleted(confirmedTurnId)
                    || (existingMetadata.map { !$0.isRunning && $0.startedAt != nil } ?? false)
                if !alreadyCompleted {
                    applyTaskRunEvent(threadId: threadId, event: .started(
                        turnId: confirmedTurnId,
                        startedAt: turnMetadata[confirmedTurnId]?.startedAt
                    ))
                }
                if selectedThreadId == threadId, messages.contains(where: { $0.id == clientMessageId }) {
                    bindUserPrompt(clientMessageId, to: confirmedTurnId, threadId: threadId)
                }
                if selectedThreadId == threadId, !alreadyCompleted {
                    turnMetadata[confirmedTurnId] = TurnMetadata(json: result["turn"] ?? .object([:]))
                } else if selectedThreadId != threadId, !alreadyCompleted {
                    updateCachedSnapshot(threadId: threadId, isRunning: true, activeTurnId: confirmedTurnId)
                }
            }
            updateDeliveryState(clientMessageId, state: nil, threadId: threadId, turnId: confirmedTurnId)
            acceptedMessageIds.remove(clientMessageId)
            removeOutboundDelivery(clientMessageId)
            return true
        } catch {
            let wasAccepted = acceptedMessageIds.remove(clientMessageId) != nil
            let uncertain = isUncertainDeliveryFailure(error, bridgeAccepted: wasAccepted)
            updateDeliveryState(
                clientMessageId,
                state: uncertain ? .uncertain("Bridge 可能已接收，正在等待历史确认。") : .failed(error.localizedDescription),
                threadId: threadId
            )
            if !uncertain {
                setOutboundDeliveryAutomaticallyRecoverable(clientMessageId, false)
            }
            if !uncertain || !wasAccepted {
                applyTaskRunEvent(threadId: threadId, event: .terminal(turnId: nil, phase: .failed, completedAt: Date()))
                setThreadStatus(threadId, status: "idle")
                updateCachedSnapshot(threadId: threadId, isRunning: false, activeTurnId: nil)
            }
            errorMessage = uncertain
                ? "消息已保留在对话中，Relay 将在重连后确认是否送达。"
                : "任务未能启动，提示词已保留；可在消息下方编辑后重新发送。"
            return true
        }
    }

    @discardableResult
    private func steerActiveTurn(
        text: String,
        readyAttachments: [PendingAttachment],
        threadId: String,
        clientMessageId: String = UUID().uuidString
    ) async -> Bool {
        guard let expectedTurnId = taskRunStates[threadId]?.turnId else {
            errorMessage = "Relay 尚未取得当前任务的运行编号，请稍后重试。"
            return false
        }
        nextUserMessageSequence += 1
        let placement = UserMessagePlacement(
            threadId: threadId,
            turnId: expectedTurnId,
            afterItemId: messages.last(where: { $0.turnId == expectedTurnId })?.id,
            sequence: nextUserMessageSequence
        )
        let draft = OutboundDraft(
            threadId: threadId,
            text: text,
            attachments: readyAttachments,
            expectedTurnId: expectedTurnId
        )
        storeOutboundDelivery(id: clientMessageId, draft: draft, placement: placement)
        let attachmentSummary = readyAttachments.filter { !$0.isImage }.map { "📎 \($0.name)" }.joined(separator: "\n")
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
            deliveryState: .sending,
            imagePaths: readyAttachments.filter(\.isImage).compactMap(\.remotePath)
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
                onAccepted: { [weak self] in self?.markMessageAccepted(clientMessageId, threadId: threadId) }
            )
            let confirmedTurnId = result["turnId"]?.stringValue ?? expectedTurnId
            let existingMetadata = turnMetadata[confirmedTurnId]
            let alreadyCompleted = taskStateCore.isCompleted(confirmedTurnId)
                || (existingMetadata.map { !$0.isRunning && $0.startedAt != nil } ?? false)
            if !alreadyCompleted {
                applyTaskRunEvent(threadId: threadId, event: .progress(turnId: confirmedTurnId, startedAt: nil))
                setThreadStatus(threadId, status: "active")
            }
            updateDeliveryState(clientMessageId, state: nil, threadId: threadId, turnId: confirmedTurnId)
            acceptedMessageIds.remove(clientMessageId)
            removeOutboundDelivery(clientMessageId)
            return true
        } catch {
            let wasAccepted = acceptedMessageIds.remove(clientMessageId) != nil
            let uncertain = isUncertainDeliveryFailure(error, bridgeAccepted: wasAccepted)
            updateDeliveryState(
                clientMessageId,
                state: uncertain ? .uncertain("引导可能已接收，正在等待历史确认。") : .failed(error.localizedDescription),
                threadId: threadId
            )
            if !uncertain {
                setOutboundDeliveryAutomaticallyRecoverable(clientMessageId, false)
            }
            errorMessage = uncertain
                ? "引导已保留在实际位置，Relay 将在重连后确认是否送达。"
                : "引导发送失败，内容已保留在对话中。"
            return true
        }
    }
}
