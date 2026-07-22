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
        guard applyDecodedTaskEvents(method: method, params: params, fallbackThreadId: selectedThreadId) else { return }
        switch method {
        case "turn/started":
            let metadata = TurnMetadata(json: params["turn"] ?? .object([:]))
            markTurnActive(params["turn"]?["id"]?.stringValue, startedAt: metadata.startedAt)
        case "turn/completed", "turn/aborted", "turn/interrupted", "turn/failed":
            flushPendingTextDeltas()
            flushPendingDetailDeltas()
            let turn = params["turn"] ?? .object([:])
            let turnId = turn["id"]?.stringValue ?? eventTurnId
            if let turnId {
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
            liveSessionSyncTask?.cancel()
            liveSessionSyncTask = nil
            Task {
                await refreshThreads(showErrors: false)
                if let selectedThreadId { await refreshGoal(threadId: selectedThreadId) }
            }
            if let selectedThreadId {
                notifyTaskCompleted(threadId: selectedThreadId, turnId: turnId, failed: method == "turn/failed")
            }
            scheduleCompletionReconciliation(threadId: selectedThreadId)
        case "item/started", "item/completed":
            guard eventTurnId.map({ !taskStateCore.isCompleted($0) }) ?? true else { break }
            markTurnActive(eventTurnId)
            if method == "item/completed" {
                flushPendingTextDeltas()
                flushPendingDetailDeltas()
            }
            if let itemJSON = params["item"], let item = TranscriptItem.from(json: itemJSON, turnId: eventTurnId) { upsert(item) }
        case "item/agentMessage/delta":
            guard eventTurnId.map({ !taskStateCore.isCompleted($0) }) ?? true else { break }
            markTurnActive(eventTurnId)
            appendDelta(id: params["itemId"]?.stringValue, delta: params["delta"]?.stringValue, turnId: eventTurnId, role: .assistant, kind: .message)
        case "item/reasoning/summaryTextDelta", "item/reasoningSummaryText/delta":
            guard eventTurnId.map({ !taskStateCore.isCompleted($0) }) ?? true else { break }
            markTurnActive(eventTurnId)
            appendDelta(id: params["itemId"]?.stringValue, delta: params["delta"]?.stringValue, turnId: eventTurnId, role: .tool, kind: .reasoning, title: "思考")
        case "item/reasoning/textDelta":
            guard eventTurnId.map({ !taskStateCore.isCompleted($0) }) ?? true else { break }
            markTurnActive(eventTurnId)
            appendDetail(id: params["itemId"]?.stringValue, delta: params["delta"]?.stringValue, turnId: eventTurnId, kind: .reasoning)
        case "item/commandExecution/outputDelta":
            guard eventTurnId.map({ !taskStateCore.isCompleted($0) }) ?? true else { break }
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

    func applyBackgroundEvent(method: String, params: JSONValue, threadId: String) {
        let turnId = params["turnId"]?.stringValue ?? params["turn"]?["id"]?.stringValue
        guard applyDecodedTaskEvents(method: method, params: params, fallbackThreadId: threadId) else { return }
        switch method {
        case "turn/started", "item/started", "item/completed", "item/agentMessage/delta",
             "item/reasoning/summaryTextDelta", "item/reasoningSummaryText/delta",
             "item/reasoning/textDelta", "item/commandExecution/outputDelta", "turn/plan/updated":
            break
        case "turn/completed", "turn/aborted", "turn/interrupted", "turn/failed":
            Task {
                await refreshThreads(showErrors: false)
                await refreshGoal(threadId: threadId)
            }
            notifyTaskCompleted(threadId: threadId, turnId: turnId, failed: method == "turn/failed")
        case "error":
            break
        case "thread/tokenUsage/updated":
            if let usage = params["tokenUsage"] { tokenUsageByThread[threadId] = ThreadTokenUsage(json: usage) }
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
            markTurnActive(runtime["activeTurnId"]?.stringValue, startedAt: startedAt)
        } else {
            if let staleTurnId = activeTurnId, var metadata = turnMetadata[staleTurnId], metadata.isRunning {
                metadata.status = runtimeError == nil ? "completed" : "failed"
                metadata.errorMessage = runtimeError
                if metadata.durationMs == nil, metadata.completedAt == nil { metadata.completedAt = Date() }
                turnMetadata[staleTurnId] = metadata
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
        liveSessionSyncTask?.cancel()
        liveSessionSyncTask = nil
        setThreadStatus(threadId, status: "idle", touchUpdatedAt: false)
        cacheCurrentThread()
    }

    func finishThreadReconciliation(_ threadId: String) {
        guard reconcilingThreadId == threadId, selectedThreadId == threadId else { return }
        reconcilingThreadId = nil
        let events = queuedEvents
        queuedEvents = []
        for event in events { applyEvent(method: event.method, params: event.params) }
        cacheCurrentThread()
    }

    func scheduleCompletionReconciliation(threadId: String?) {
        guard let threadId else { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, self.selectedThreadId == threadId, !self.isRunning, self.activeTurnId == nil else { return }
            await self.selectThread(threadId, closeSidebar: false, showErrors: false)
        }
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
