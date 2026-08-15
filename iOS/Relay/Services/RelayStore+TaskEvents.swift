import Foundation

@MainActor
extension RelayStore {
    func applyTaskRunEvent(threadId: String, event: TaskRunEvent) {
        let previous = taskRunStates[threadId] ?? TaskRunState(threadId: threadId)
        var next = taskRunStates
        if taskStateCore.apply(threadId: threadId, event: event, to: &next) {
            taskRunStates = next
            let current = next[threadId] ?? TaskRunState(threadId: threadId)
            if previous.isRunning != current.isRunning || previous.turnId != current.turnId {
                setThreadStatus(threadId, status: current.isRunning ? "active" : "idle", touchUpdatedAt: false)
                updateCachedSnapshot(
                    threadId: threadId,
                    isRunning: current.isRunning,
                    activeTurnId: current.turnId
                )
            }
        }
    }

    func acceptsTurnEvent(threadId: String, turnId: String?) -> Bool {
        guard let turnId,
              let state = taskRunStates[threadId],
              state.isRunning,
              let activeTurnId = state.turnId else { return true }
        return activeTurnId == turnId
    }

    @discardableResult
    func applyDecodedTaskEvents(method: String, params: JSONValue, fallbackThreadId: String?) -> Bool {
        let transition = TaskEventDecoder.decode(method: method, params: params, fallbackThreadId: fallbackThreadId)
        guard let threadId = transition.threadId else { return true }
        if let turnId = transition.turnId,
           taskStateCore.isCompleted(turnId),
           method == "turn/started" || method == "turn/plan/updated" || TaskEventDecoder.isProgress(method) {
            return false
        }
        if method != "turn/started", !acceptsTurnEvent(threadId: threadId, turnId: transition.turnId) {
            return false
        }
        for event in transition.events { applyTaskRunEvent(threadId: threadId, event: event) }
        return true
    }

    func handleEvent(method: String, params: JSONValue) {
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

    func applyEvent(method: String, params: JSONValue) {
        let eventTurnId = params["turnId"]?.stringValue ?? params["turn"]?["id"]?.stringValue
        let previousOutputStartedAt = selectedThreadId.flatMap { taskRunStates[$0]?.outputStartedAt }
        guard applyDecodedTaskEvents(method: method, params: params, fallbackThreadId: selectedThreadId) else { return }
        if previousOutputStartedAt == nil,
           selectedThreadId.flatMap({ taskRunStates[$0]?.outputStartedAt }) != nil {
            RelayHaptics.impact()
        }
        switch method {
        case "turn/started":
            let metadata = TurnMetadata(json: params["turn"] ?? .object([:]))
            markTurnActive(params["turn"]?["id"]?.stringValue, startedAt: metadata.startedAt)
        case "turn/completed", "turn/aborted", "turn/interrupted", "turn/failed":
            if let selectedThreadId, let eventTurnId {
                bindPendingUserPrompt(to: eventTurnId, threadId: selectedThreadId)
            }
            flushPendingTextDeltas()
            flushPendingDetailDeltas()
            let turn = params["turn"] ?? .object([:])
            let turnId = turn["id"]?.stringValue ?? eventTurnId
            var terminalFailed = method == "turn/failed"
            if let turnId {
                var metadata = TurnMetadata(json: turn)
                if method == "turn/aborted" || method == "turn/interrupted" {
                    metadata.status = "interrupted"
                } else if method == "turn/failed" {
                    metadata.status = "failed"
                } else if metadata.status == nil {
                    metadata.status = "completed"
                }
                if metadata.durationMs == nil, metadata.completedAt == nil { metadata.completedAt = Date() }
                terminalFailed = terminalFailed || metadata.isFailed
                turnMetadata[turnId] = metadata
                let completedItems = turn["items"]?.arrayValue?.compactMap {
                    TranscriptItem.from(json: $0, turnId: turnId)
                } ?? []
                if !completedItems.isEmpty { mergeSessionItems(completedItems, turnId: turnId) }
                let hasOutput = completedItems.contains { $0.role != .user }
                reconcileStartedTurnDelivery(
                    turnId: turnId,
                    status: metadata.status,
                    errorMessage: metadata.errorMessage,
                    hasOutput: hasOutput
                )
            }
            Task {
                await refreshThreads(showErrors: false)
                if let selectedThreadId { await refreshGoal(threadId: selectedThreadId) }
            }
            if let selectedThreadId {
                notifyTaskCompleted(threadId: selectedThreadId, turnId: turnId, failed: terminalFailed)
            }
        case "item/started", "item/completed":
            guard eventTurnId.map({ !taskStateCore.isCompleted($0) }) ?? true else { break }
            markTurnActive(eventTurnId)
            if method == "item/completed" {
                flushPendingTextDeltas()
                flushPendingDetailDeltas()
            }
            if let itemJSON = params["item"], let item = TranscriptItem.from(json: itemJSON, turnId: eventTurnId) {
                upsert(item)
                if item.role != .user, let eventTurnId {
                    reconcileStartedTurnDelivery(turnId: eventTurnId, hasOutput: true)
                }
            }
        case "item/agentMessage/delta":
            guard eventTurnId.map({ !taskStateCore.isCompleted($0) }) ?? true else { break }
            markTurnActive(eventTurnId)
            appendDelta(
                id: params["itemId"]?.stringValue,
                delta: params["delta"]?.stringValue,
                turnId: eventTurnId,
                role: .assistant,
                kind: .message,
                phase: params["phase"]?.stringValue
            )
            if let eventTurnId { reconcileStartedTurnDelivery(turnId: eventTurnId, hasOutput: true) }
        case "item/reasoning/summaryTextDelta", "item/reasoningSummaryText/delta":
            guard eventTurnId.map({ !taskStateCore.isCompleted($0) }) ?? true else { break }
            markTurnActive(eventTurnId)
            appendDelta(id: params["itemId"]?.stringValue, delta: params["delta"]?.stringValue, turnId: eventTurnId, role: .tool, kind: .reasoning, title: "思考")
            if let eventTurnId { reconcileStartedTurnDelivery(turnId: eventTurnId, hasOutput: true) }
        case "item/reasoning/textDelta":
            guard eventTurnId.map({ !taskStateCore.isCompleted($0) }) ?? true else { break }
            markTurnActive(eventTurnId)
            appendDetail(id: params["itemId"]?.stringValue, delta: params["delta"]?.stringValue, turnId: eventTurnId, kind: .reasoning)
            if let eventTurnId { reconcileStartedTurnDelivery(turnId: eventTurnId, hasOutput: true) }
        case "item/commandExecution/outputDelta":
            guard eventTurnId.map({ !taskStateCore.isCompleted($0) }) ?? true else { break }
            markTurnActive(eventTurnId)
            appendDetail(id: params["itemId"]?.stringValue, delta: params["delta"]?.stringValue, turnId: eventTurnId, kind: .command)
            if let eventTurnId { reconcileStartedTurnDelivery(turnId: eventTurnId, hasOutput: true) }
        case "turn/plan/updated", "turn/diff/updated":
            if let eventTurnId { reconcileStartedTurnDelivery(turnId: eventTurnId, hasOutput: true) }
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
            if let mode = params["threadSettings"]?["collaborationMode"]?["mode"]?.stringValue,
               composerMode != .goal {
                composerMode = mode == "plan" ? .plan : .standard
            }
            persistGenerationSettings()
        case "thread/goal/updated":
            if let threadId = params["threadId"]?.stringValue {
                applyGoalResult(params["goal"], threadId: threadId)
            }
        case "thread/goal/cleared":
            if let threadId = params["threadId"]?.stringValue {
                goalStates.removeValue(forKey: threadId)
            }
        case "error":
            let message = params["error"]?["message"]?.stringValue
                ?? params["message"]?.stringValue
                ?? "Codex reported an error."
            let threadId = params["threadId"]?.stringValue ?? selectedThreadId
            if params["willRetry"]?.boolValue != true {
                errorMessage = message
                if params["willRetry"]?.boolValue == false, let threadId {
                    markSelectedThreadFailed(threadId: threadId, turnId: eventTurnId, message: message)
                    if let eventTurnId {
                        reconcileStartedTurnDelivery(turnId: eventTurnId, status: "failed", errorMessage: message)
                    }
                }
            }
        default:
            break
        }
        if [
            "turn/started", "turn/completed", "turn/aborted", "turn/interrupted", "turn/failed",
            "item/started", "item/completed", "thread/compacted"
        ].contains(method) {
            recordTranscriptTrace(source: "event.\(method)", turnId: eventTurnId)
        }
    }

    func applyBackgroundEvent(method: String, params: JSONValue, threadId: String) {
        let turnId = params["turnId"]?.stringValue ?? params["turn"]?["id"]?.stringValue
        guard applyDecodedTaskEvents(method: method, params: params, fallbackThreadId: threadId) else { return }
        switch method {
        case "turn/started":
            break
        case "item/started", "item/completed":
            if let turnId,
               let itemJSON = params["item"],
               let item = TranscriptItem.from(json: itemJSON, turnId: turnId),
               item.role != .user {
                reconcileStartedTurnDelivery(turnId: turnId, hasOutput: true)
            }
        case "item/agentMessage/delta", "item/reasoning/summaryTextDelta",
             "item/reasoningSummaryText/delta", "item/reasoning/textDelta",
             "item/commandExecution/outputDelta", "turn/plan/updated", "turn/diff/updated":
            if let turnId {
                reconcileStartedTurnDelivery(turnId: turnId, hasOutput: true)
            }
        case "turn/completed", "turn/aborted", "turn/interrupted", "turn/failed":
            let turn = params["turn"] ?? .object([:])
            var terminalFailed = method == "turn/failed"
            if let turnId {
                let metadata = TurnMetadata(json: turn)
                terminalFailed = terminalFailed || metadata.isFailed
                let hasOutput = (turn["items"]?.arrayValue ?? []).contains { itemJSON in
                    guard let item = TranscriptItem.from(json: itemJSON, turnId: turnId) else { return false }
                    return item.role != .user
                }
                reconcileStartedTurnDelivery(
                    turnId: turnId,
                    status: method == "turn/failed" ? "failed" : metadata.status,
                    errorMessage: metadata.errorMessage,
                    hasOutput: hasOutput
                )
            }
            Task {
                await refreshThreads(showErrors: false)
                await refreshGoal(threadId: threadId)
            }
            notifyTaskCompleted(threadId: threadId, turnId: turnId, failed: terminalFailed)
        case "error":
            if params["willRetry"]?.boolValue == false, let turnId {
                let message = params["error"]?["message"]?.stringValue
                    ?? params["message"]?.stringValue
                    ?? "Codex reported an error."
                reconcileStartedTurnDelivery(turnId: turnId, status: "failed", errorMessage: message)
            }
        case "thread/tokenUsage/updated":
            if let usage = params["tokenUsage"] { tokenUsageByThread[threadId] = ThreadTokenUsage(json: usage) }
        case "thread/goal/updated":
            applyGoalResult(params["goal"], threadId: threadId)
        case "thread/goal/cleared":
            goalStates.removeValue(forKey: threadId)
        default:
            break
        }
    }

    func markTurnActive(_ turnId: String?, startedAt: Date? = nil) {
        if let selectedThreadId, let turnId {
            guard acceptsTurnEvent(threadId: selectedThreadId, turnId: turnId) else { return }
            applyTaskRunEvent(threadId: selectedThreadId, event: .progress(turnId: turnId, startedAt: startedAt))
        }
        guard let turnId else { return }
        if let selectedThreadId { bindPendingUserPrompt(to: turnId, threadId: selectedThreadId) }
        var metadata = turnMetadata[turnId] ?? TurnMetadata()
        let wasAlreadyActive = metadata.status == "inProgress"
            && metadata.completedAt == nil
            && metadata.durationMs == nil
            && metadata.startedAt != nil
        if !wasAlreadyActive {
            metadata.status = "inProgress"
            metadata.completedAt = nil
            metadata.durationMs = nil
            if metadata.startedAt == nil { metadata.startedAt = startedAt ?? Date() }
            turnMetadata[turnId] = metadata
        }
        ensureLiveSessionSync()
    }

    func reconcileRuntimeState(_ runtime: JSONValue) {
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
            let turnId = runtime["activeTurnId"]?.stringValue
            markTurnActive(turnId, startedAt: startedAt)
            if let selectedThreadId, let turnId,
               let outputStartedAt = runtime["outputStartedAt"]?.doubleValue.map({ Date(timeIntervalSince1970: $0) }) {
                applyTaskRunEvent(threadId: selectedThreadId, event: .outputStarted(turnId: turnId, at: outputStartedAt))
            }
            if let selectedThreadId, let turnId, let plan = runtime["plan"]?.arrayValue {
                let steps = plan.enumerated().compactMap { index, value -> ExecutionPlanStep? in
                    guard let text = value["step"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !text.isEmpty else { return nil }
                    return ExecutionPlanStep(
                        id: "\(turnId).\(index)",
                        text: text,
                        status: value["status"]?.stringValue ?? "pending"
                    )
                }
                applyTaskRunEvent(threadId: selectedThreadId, event: .plan(turnId: turnId, steps: steps))
            }
        } else {
            if let staleTurnId = activeTurnId, var metadata = turnMetadata[staleTurnId], metadata.isRunning {
                metadata.status = runtimeError == nil ? "completed" : "failed"
                metadata.errorMessage = runtimeError
                if metadata.durationMs == nil, metadata.completedAt == nil { metadata.completedAt = Date() }
                turnMetadata[staleTurnId] = metadata
            }
            if let selectedThreadId {
                let reconciledTurnId = runtime["activeTurnId"]?.stringValue
                    ?? runtime["observedTurnId"]?.stringValue
                    ?? taskRunStates[selectedThreadId]?.turnId
                applyTaskRunEvent(
                    threadId: selectedThreadId,
                    event: .terminal(
                        turnId: reconciledTurnId,
                        phase: runtimeError == nil ? .completed : .failed,
                        completedAt: Date()
                    )
                )
            }
        }
    }

    func applyRuntimeUpdate(threadId: String, runtime: JSONValue) {
        guard runtime["known"]?.boolValue == true else { return }
        guard selectedThreadId == threadId else {
            let running = runtime["isRunning"]?.boolValue == true
            let turnId = runtime["activeTurnId"]?.stringValue ?? runtime["observedTurnId"]?.stringValue
            if running, let turnId {
                applyTaskRunEvent(threadId: threadId, event: .progress(turnId: turnId, startedAt: nil))
            } else if !running {
                let reconciledTurnId = turnId ?? taskRunStates[threadId]?.turnId
                applyTaskRunEvent(
                    threadId: threadId,
                    event: .terminal(
                        turnId: reconciledTurnId,
                        phase: runtime["upstreamError"]?.stringValue == nil ? .completed : .failed,
                        completedAt: Date()
                    )
                )
            }
            return
        }
        reconcileRuntimeState(runtime)
    }

    func markSelectedThreadFailed(threadId: String, turnId: String?, message: String) {
        guard selectedThreadId == threadId else { return }
        let failedTurnId = turnId ?? taskRunStates[threadId]?.turnId
        if let failedTurnId {
            taskStateCore.markCompleted(failedTurnId)
            var metadata = turnMetadata[failedTurnId] ?? TurnMetadata()
            metadata.status = "failed"
            metadata.errorMessage = message
            metadata.completedAt = metadata.completedAt ?? Date()
            if metadata.durationMs == nil, let startedAt = metadata.startedAt {
                metadata.durationMs = Int(max(0, Date().timeIntervalSince(startedAt) * 1000))
            }
            turnMetadata[failedTurnId] = metadata
        }
        setThreadStatus(threadId, status: "idle", touchUpdatedAt: false)
        cacheCurrentThread()
    }

    func finishThreadReconciliation(_ threadId: String) {
        guard reconcilingThreadId == threadId, selectedThreadId == threadId else { return }
        reconcilingThreadId = nil
        let events = queuedEvents
        queuedEvents = []
        for event in events { applyEvent(method: event.method, params: event.params) }
        recordTranscriptTrace(source: "reconciliation.complete")
        cacheCurrentThread()
    }

    func updateCachedSnapshot(threadId: String, isRunning: Bool, activeTurnId: String?) {
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
}
