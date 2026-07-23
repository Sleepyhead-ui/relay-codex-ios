import Foundation

@MainActor
extension RelayStore {
    func upsert(_ item: TranscriptItem) {
        TranscriptReconciler.upsert(item, into: &messages)
    }

    func appendDelta(id: String?, delta: String?, turnId: String?, role: TranscriptRole, kind: TranscriptKind, title: String? = nil) {
        guard let id, let delta else { return }
        socket.performanceMetrics.recordQueuedDelta()
        if pendingTextDeltas[id] == nil && pendingDetailDeltas[id] == nil { pendingDeltaOrder.append(id) }
        if var pending = pendingTextDeltas[id] {
            pending.text += delta
            if pending.turnId == nil { pending.turnId = turnId }
            pendingTextDeltas[id] = pending
        } else {
            pendingTextDeltas[id] = PendingTextDelta(text: delta, turnId: turnId, role: role, kind: kind, title: title)
        }
        scheduleDeltaFlush()
    }

    func flushPendingTextDeltas() { flushPendingDeltas() }

    func appendDetail(id: String?, delta: String?, turnId: String?, kind: TranscriptKind) {
        guard let id, let delta else { return }
        socket.performanceMetrics.recordQueuedDelta()
        if pendingTextDeltas[id] == nil && pendingDetailDeltas[id] == nil { pendingDeltaOrder.append(id) }
        if var pending = pendingDetailDeltas[id] {
            pending.text += delta
            if pending.turnId == nil { pending.turnId = turnId }
            pendingDetailDeltas[id] = pending
        } else {
            pendingDetailDeltas[id] = PendingDetailDelta(text: delta, turnId: turnId, kind: kind)
        }
        scheduleDeltaFlush()
    }

    func flushPendingDetailDeltas() { flushPendingDeltas() }

    private func scheduleDeltaFlush() {
        guard deltaFlushTask == nil else { return }
        deltaFlushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled else { return }
            self?.flushPendingDeltas()
        }
    }

    private func flushPendingDeltas() {
        deltaFlushTask?.cancel()
        deltaFlushTask = nil
        guard !pendingTextDeltas.isEmpty || !pendingDetailDeltas.isEmpty else { return }
        let pendingText = pendingTextDeltas
        let pendingDetail = pendingDetailDeltas
        let pendingOrder = pendingDeltaOrder
        let startedAt = ClientPerformanceClock.now()
        let updatedItemCount = pendingOrder.count
        pendingTextDeltas.removeAll(keepingCapacity: true)
        pendingDetailDeltas.removeAll(keepingCapacity: true)
        pendingDeltaOrder.removeAll(keepingCapacity: true)
        let updates = pendingOrder.compactMap { id -> TranscriptDeltaUpdate? in
            if let text = pendingText[id], let detail = pendingDetail[id] {
                return TranscriptDeltaUpdate(id: id, turnId: text.turnId ?? detail.turnId, role: text.role, kind: text.kind, title: text.title, text: text.text, detail: detail.text)
            }
            if let text = pendingText[id] {
                return TranscriptDeltaUpdate(id: id, turnId: text.turnId, role: text.role, kind: text.kind, title: text.title, text: text.text, detail: "")
            }
            if let detail = pendingDetail[id] {
                return TranscriptDeltaUpdate(id: id, turnId: detail.turnId, role: .tool, kind: detail.kind, title: detail.kind == .reasoning ? "思考" : "运行命令", text: "", detail: detail.text)
            }
            return nil
        }
        isApplyingIndexedTranscriptMutation = true
        _ = transcriptIndex.applyDeltaBatch(updates, to: &messages)
        isApplyingIndexedTranscriptMutation = false
        socket.performanceMetrics.recordDeltaFlush(
            items: updatedItemCount,
            milliseconds: ClientPerformanceClock.milliseconds(since: startedAt)
        )
    }

    func ensureLiveSessionSync() {
        guard liveSessionSyncTask == nil, isRunning, selectedThreadId != nil, socket.state == .connected else { return }
        liveSessionSyncTask = Task { [weak self] in
            guard let self, let initialThreadId = self.selectedThreadId else { return }
            if let initial = try? await self.socket.rpc(
                method: "relay/thread/session/subscribe",
                params: ["threadId": .string(initialThreadId), "incremental": .bool(true)],
                timeoutSeconds: 12,
                reconnectOnTimeout: false
            ) {
                self.subscribedSessionThreadId = initialThreadId
                self.applySessionSnapshot(initial, threadId: initialThreadId)
            }
            while !Task.isCancelled {
                guard let threadId = self.selectedThreadId, self.isRunning, self.socket.state == .connected else { break }
                do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { break }
                if Date().timeIntervalSince(self.lastSessionUpdateAt[threadId] ?? .distantPast) >= 25 {
                    await self.syncSessionSnapshot(threadId: threadId)
                }
            }
            self.liveSessionSyncTask = nil
        }
    }

    private func syncSessionSnapshot(threadId: String) async {
        guard !recoveringSessionThreadIds.contains(threadId) else { return }
        socket.performanceMetrics.recordSessionRecovery()
        recoveringSessionThreadIds.insert(threadId)
        defer { recoveringSessionThreadIds.remove(threadId) }
        guard let result = try? await socket.rpc(
            method: "relay/thread/session/subscribe",
            params: ["threadId": .string(threadId), "incremental": .bool(true)],
            timeoutSeconds: 12,
            reconnectOnTimeout: false
        ) else { return }
        subscribedSessionThreadId = threadId
        applySessionSnapshot(result, threadId: threadId)
    }

    func applySessionSnapshot(_ result: JSONValue, threadId: String) {
        guard selectedThreadId == threadId, result["known"]?.boolValue == true,
              let turnId = result["turnId"]?.stringValue else { return }
        let startedAt = ClientPerformanceClock.now()
        defer { socket.performanceMetrics.recordSessionSnapshot(milliseconds: ClientPerformanceClock.milliseconds(since: startedAt)) }
        sessionRevisionTracker.reset(threadId: threadId, revision: result["revision"]?.intValue ?? 0)
        lastSessionUpdateAt[threadId] = Date()
        let snapshotItems = result["items"]?.arrayValue?.compactMap { TranscriptItem.from(json: $0, turnId: turnId) } ?? []
        if !snapshotItems.isEmpty { mergeSessionItems(snapshotItems, turnId: turnId) }
        applySessionStatus(result, threadId: threadId, turnId: turnId)
    }

    func applySessionPatch(_ patch: JSONValue, threadId: String) {
        guard selectedThreadId == threadId, patch["known"]?.boolValue == true,
              let turnId = patch["turnId"]?.stringValue,
              let baseRevision = patch["baseRevision"]?.intValue,
              let revision = patch["revision"]?.intValue else { return }
        guard sessionRevisionTracker.acceptPatch(threadId: threadId, baseRevision: baseRevision, revision: revision) else {
            socket.performanceMetrics.recordRevisionGap()
            Task { [weak self] in await self?.syncSessionSnapshot(threadId: threadId) }
            return
        }
        let startedAt = ClientPerformanceClock.now()
        defer { socket.performanceMetrics.recordSessionPatch(milliseconds: ClientPerformanceClock.milliseconds(since: startedAt)) }
        lastSessionUpdateAt[threadId] = Date()
        let upserts = patch["upsertItems"]?.arrayValue?.compactMap { TranscriptItem.from(json: $0, turnId: turnId) } ?? []
        let removedItemIds = Set(patch["removedItemIds"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        if !upserts.isEmpty || !removedItemIds.isEmpty {
            flushPendingTextDeltas()
            flushPendingDetailDeltas()
            let nextMessages = TranscriptReconciler.mergeSessionPatchItems(upserts, removedItemIds: removedItemIds, turnId: turnId, into: messages)
            let changedItemIds = Set(upserts.compactMap { incoming in
                nextMessages.first(where: { $0.id == incoming.id })?.id
                    ?? nextMessages.first(where: { $0.turnId == turnId && TranscriptReconciler.semanticallyMatches($0, incoming) })?.id
            })
            adoptReconciledSessionPatch(nextMessages, changedItemIds: changedItemIds, hasRemovals: !removedItemIds.isEmpty)
            applyUserMessagePlacements(turnId: turnId, threadId: threadId)
        }
        applySessionStatus(patch, threadId: threadId, turnId: turnId)
    }

    private func applySessionStatus(_ result: JSONValue, threadId: String, turnId: String) {
        let snapshotIsStale = result["stale"]?.boolValue == true
        if result["isRunning"]?.boolValue == true, !snapshotIsStale { bindPendingUserPrompt(to: turnId, threadId: threadId) }
        var metadata = turnMetadata[turnId] ?? TurnMetadata()
        if let startedAt = result["startedAt"]?.doubleValue { metadata.startedAt = Date(timeIntervalSince1970: startedAt) }
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
            if let completedAt = result["completedAt"]?.doubleValue { metadata.completedAt = Date(timeIntervalSince1970: completedAt) }
            else if metadata.completedAt == nil { metadata.completedAt = Date() }
            turnMetadata[turnId] = metadata
            if activeTurnId == nil || activeTurnId == turnId {
                setThreadStatus(threadId, status: "idle")
                liveSessionSyncTask?.cancel()
                liveSessionSyncTask = nil
            }
            applyTaskRunEvent(threadId: threadId, event: .terminal(turnId: turnId, phase: snapshotIsStale ? .interrupted : .completed, completedAt: metadata.completedAt))
        }
        cacheCurrentThread()
    }

    func bindPendingUserPrompt(to turnId: String, threadId: String) {
        guard selectedThreadId == threadId else { return }
        var pending: (messageId: String, sequence: Int)?
        for (messageId, placement) in userMessagePlacements {
            guard placement.threadId == threadId, placement.turnId == nil,
                  let message = messages.first(where: { $0.id == messageId }),
                  message.deliveryState == .sending || message.deliveryState == .accepted else { continue }
            if pending?.sequence ?? Int.min < placement.sequence { pending = (messageId, placement.sequence) }
        }
        guard let messageId = pending?.messageId else { return }
        bindUserPrompt(messageId, to: turnId, threadId: threadId)
    }

    func bindUserPrompt(_ messageId: String, to turnId: String, threadId: String) {
        guard selectedThreadId == threadId, userMessagePlacements[messageId]?.threadId == threadId else { return }
        userMessagePlacements[messageId]?.turnId = turnId
        applyUserMessagePlacements(turnId: turnId, threadId: threadId)
    }

    private func mergeSessionItems(_ snapshotItems: [TranscriptItem], turnId: String) {
        flushPendingTextDeltas()
        flushPendingDetailDeltas()
        messages = TranscriptReconciler.mergeSessionItems(snapshotItems, turnId: turnId, into: messages)
        applyUserMessagePlacements(turnId: turnId, threadId: selectedThreadId ?? "")
    }

    private func adoptReconciledSessionPatch(
        _ nextMessages: [TranscriptItem],
        changedItemIds: Set<String>,
        hasRemovals: Bool
    ) {
        guard nextMessages != messages else { return }
        let adopted = !hasRemovals && transcriptIndex.adoptReconciledUpserts(
            nextMessages,
            changedItemIds: changedItemIds
        )
        isApplyingIndexedTranscriptMutation = adopted
        messages = nextMessages
        isApplyingIndexedTranscriptMutation = false
    }

    func applyUserMessagePlacements(turnId: String, threadId: String) {
        let nextMessages = TranscriptReconciler.applyUserMessagePlacements(
            userMessagePlacements,
            turnId: turnId,
            threadId: threadId,
            to: messages
        )
        if nextMessages != messages { messages = nextMessages }
    }

    func cacheCurrentThread() {
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
    func restoreThreadSnapshot(_ threadId: String) -> Bool {
        guard let snapshot = threadSnapshots[threadId] else { return false }
        messages = snapshot.messages
        turnMetadata = snapshot.turnMetadata
        applyTaskRunEvent(threadId: threadId, event: .hydrate(
            running: snapshot.isRunning,
            turnId: snapshot.activeTurnId,
            startedAt: snapshot.activeTurnId.flatMap { snapshot.turnMetadata[$0]?.startedAt }
        ))
        if let turnId = snapshot.activeTurnId, snapshot.activePlanTurnId == turnId {
            applyTaskRunEvent(threadId: threadId, event: .plan(turnId: turnId, steps: snapshot.activePlan))
        }
        selectedModelId = snapshot.modelId
        selectedEffort = snapshot.effort
        return true
    }
}

struct PendingDetailDelta {
    var text: String
    var turnId: String?
    let kind: TranscriptKind
}

struct PendingTextDelta {
    var text: String
    var turnId: String?
    let role: TranscriptRole
    let kind: TranscriptKind
    let title: String?
}
