import Foundation

struct TaskEventTransition {
    let threadId: String?
    let turnId: String?
    let events: [TaskRunEvent]
}

enum TaskEventDecoder {
    static func decode(method: String, params: JSONValue, fallbackThreadId: String? = nil) -> TaskEventTransition {
        let threadId = params["threadId"]?.stringValue ?? fallbackThreadId
        let turn = params["turn"] ?? .object([:])
        let turnId = params["turnId"]?.stringValue ?? turn["id"]?.stringValue
        let startedAt = turn["startedAt"]?.doubleValue.map { Date(timeIntervalSince1970: $0) }
        let completedAt = turn["completedAt"]?.doubleValue.map { Date(timeIntervalSince1970: $0) }
        let events: [TaskRunEvent]

        switch method {
        case "turn/started":
            events = turnId.map { [.started(turnId: $0, startedAt: startedAt)] } ?? []
        case "turn/completed", "turn/aborted", "turn/interrupted", "turn/failed":
            let phase: TaskRunPhase = method == "turn/failed"
                ? .failed
                : (method == "turn/completed" ? .completed : .interrupted)
            events = [.terminal(turnId: turnId, phase: phase, completedAt: completedAt)]
        case "turn/plan/updated":
            guard let turnId else { events = []; break }
            let steps = (params["plan"]?.arrayValue ?? []).enumerated().compactMap { index, step -> ExecutionPlanStep? in
                guard let text = step["step"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty else { return nil }
                return ExecutionPlanStep(
                    id: "\(turnId).\(index)",
                    text: text,
                    status: step["status"]?.stringValue ?? "pending"
                )
            }
            events = [
                .progress(turnId: turnId, startedAt: nil),
                .plan(turnId: turnId, steps: steps)
            ]
        case "error":
            let message = params["error"]?["message"]?.stringValue ?? params["message"]?.stringValue
            if params["willRetry"]?.boolValue == true {
                events = [.retrying(turnId: turnId, message: message)]
            } else if params["willRetry"]?.boolValue == false {
                events = [.terminal(turnId: turnId, phase: .failed, completedAt: nil)]
            } else {
                events = [.clearRetry]
            }
        default:
            if isProgress(method), let turnId {
                events = [.progress(turnId: turnId, startedAt: nil)]
            } else {
                events = []
            }
        }

        return TaskEventTransition(threadId: threadId, turnId: turnId, events: events)
    }

    static func isProgress(_ method: String) -> Bool {
        method == "item/started"
            || method == "item/completed"
            || (method.hasPrefix("item/") && method.hasSuffix("/delta"))
    }
}

struct TaskEventReplay {
    private(set) var states: [String: TaskRunState] = [:]
    private var completedTurnIds = Set<String>()

    mutating func apply(method: String, params: JSONValue, fallbackThreadId: String? = nil) {
        let transition = TaskEventDecoder.decode(method: method, params: params, fallbackThreadId: fallbackThreadId)
        guard let threadId = transition.threadId else { return }
        if let turnId = transition.turnId,
           completedTurnIds.contains(turnId),
           method == "turn/started" || method == "turn/plan/updated" || TaskEventDecoder.isProgress(method) {
            return
        }
        var state = states[threadId] ?? TaskRunState(threadId: threadId)
        for event in transition.events { state.apply(event) }
        states[threadId] = state
        if method == "turn/completed" || method == "turn/aborted" || method == "turn/interrupted" || method == "turn/failed",
           let turnId = transition.turnId {
            completedTurnIds.insert(turnId)
        }
    }
}
