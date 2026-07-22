import Foundation

@MainActor
extension RelayStore {
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
        } else if isRunning {
            await steerActiveTurn(text: text, readyAttachments: readyAttachments, threadId: threadId)
        } else {
            composerText = ""
            attachments = []
            await startTurn(text: text, readyAttachments: readyAttachments, threadId: threadId)
        }
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
        outboundDrafts[clientMessageId] = OutboundDraft(threadId: threadId, text: text, attachments: readyAttachments)
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
                "sandboxPolicy": workspaceAccess.sandboxPolicy(workingDirectory: currentWorkingDirectory)
            ]
            if let model = selectedModel?.model { params["model"] = .string(model) }
            if !selectedEffort.isEmpty { params["effort"] = .string(selectedEffort) }
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
            outboundDrafts.removeValue(forKey: clientMessageId)
        } catch {
            let wasAccepted = acceptedMessageIds.remove(clientMessageId) != nil
            let uncertain = wasAccepted || isUncertainDeliveryError(error)
            updateDeliveryState(
                clientMessageId,
                state: uncertain ? .uncertain("Bridge 可能已接收，正在等待历史确认。") : .failed(error.localizedDescription),
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
        nextUserMessageSequence += 1
        userMessagePlacements[clientMessageId] = UserMessagePlacement(
            threadId: threadId,
            turnId: expectedTurnId,
            afterItemId: messages.last(where: { $0.turnId == expectedTurnId })?.id,
            sequence: nextUserMessageSequence
        )
        outboundDrafts[clientMessageId] = OutboundDraft(threadId: threadId, text: text, attachments: readyAttachments)
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
            outboundDrafts.removeValue(forKey: clientMessageId)
        } catch {
            let wasAccepted = acceptedMessageIds.remove(clientMessageId) != nil
            let uncertain = wasAccepted || isUncertainDeliveryError(error)
            updateDeliveryState(
                clientMessageId,
                state: uncertain ? .uncertain("引导可能已接收，正在等待历史确认。") : .failed(error.localizedDescription),
                threadId: threadId
            )
            errorMessage = uncertain
                ? "引导已保留在实际位置，Relay 将在重连后确认是否送达。"
                : "引导发送失败，内容已保留；可在消息下方恢复并重试。"
        }
    }
}
