import Foundation

struct TaskEventTransition {
    let threadId: String?
    let turnId: String?
    let events: [TaskRunEvent]
}

struct TaskStateCore {
    private(set) var completedTurnIds = Set<String>()

    mutating func apply(
        threadId: String,
        event: TaskRunEvent,
        to states: inout [String: TaskRunState]
    ) -> Bool {
        let previous = states[threadId] ?? TaskRunState(threadId: threadId)
        if let turnId = event.referencedTurnId,
           completedTurnIds.contains(turnId),
           event.isReplayableProgress {
            return false
        }

        var next = previous
        next.apply(event)
        let completionsBefore = completedTurnIds
        switch event {
        case .terminal(let turnId, _, _):
            if let completed = turnId ?? previous.turnId { completedTurnIds.insert(completed) }
        case .hydrate(let running, let turnId, _):
            if running, let turnId {
                completedTurnIds.remove(turnId)
            } else if !running, let turnId {
                completedTurnIds.insert(turnId)
            }
        default:
            break
        }
        let stateChanged = next != previous
        if stateChanged { states[threadId] = next }
        return stateChanged || completedTurnIds != completionsBefore
    }

    func isCompleted(_ turnId: String) -> Bool { completedTurnIds.contains(turnId) }
    mutating func markCompleted(_ turnId: String) { completedTurnIds.insert(turnId) }
    mutating func reset() { completedTurnIds.removeAll() }
}

private extension TaskRunEvent {
    var referencedTurnId: String? {
        switch self {
        case .started(let turnId, _), .progress(let turnId, _), .plan(let turnId, _): return turnId
        case .retrying(let turnId, _), .terminal(let turnId, _, _): return turnId
        case .hydrate(_, let turnId, _): return turnId
        case .reset, .starting, .clearRetry: return nil
        }
    }

    var isReplayableProgress: Bool {
        switch self {
        case .started, .progress, .plan: return true
        default: return false
        }
    }
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
            || (method.hasPrefix("item/") && (method.hasSuffix("/delta") || method.hasSuffix("Delta")))
    }
}

struct TaskEventReplay {
    private(set) var states: [String: TaskRunState] = [:]
    private var core = TaskStateCore()

    mutating func apply(method: String, params: JSONValue, fallbackThreadId: String? = nil) {
        let transition = TaskEventDecoder.decode(method: method, params: params, fallbackThreadId: fallbackThreadId)
        guard let threadId = transition.threadId else { return }
        for event in transition.events { _ = core.apply(threadId: threadId, event: event, to: &states) }
    }

    mutating func hydrate(threadId: String, running: Bool, turnId: String?, startedAt: Date? = nil) {
        _ = core.apply(
            threadId: threadId,
            event: .hydrate(running: running, turnId: turnId, startedAt: startedAt),
            to: &states
        )
    }
}
