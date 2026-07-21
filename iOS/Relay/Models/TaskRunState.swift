import Foundation

enum TaskRunPhase: Equatable {
    case idle
    case starting
    case running
    case retrying
    case completed
    case interrupted
    case failed
}

struct TaskRunState: Equatable {
    let threadId: String
    var phase: TaskRunPhase = .idle
    var turnId: String?
    var startedAt: Date?
    var completedAt: Date?
    var retryMessage: String?
    var planTurnId: String?
    var plan: [ExecutionPlanStep] = []

    var isRunning: Bool { phase == .starting || phase == .running || phase == .retrying }

    mutating func apply(_ event: TaskRunEvent) {
        switch event {
        case .reset:
            self = TaskRunState(threadId: threadId)
        case .starting(let startedAt):
            self = TaskRunState(threadId: threadId, phase: .starting, startedAt: startedAt ?? Date())
        case .hydrate(let running, let turnId, let startedAt):
            if running {
                self = TaskRunState(
                    threadId: threadId,
                    phase: turnId == nil ? .starting : .running,
                    turnId: turnId,
                    startedAt: startedAt ?? Date()
                )
            } else {
                self = TaskRunState(threadId: threadId)
            }
        case .started(let turnId, let startedAt):
            self = TaskRunState(threadId: threadId, phase: .running, turnId: turnId, startedAt: startedAt ?? Date())
        case .progress(let turnId, let startedAt):
            let canAdoptTurn = self.turnId == nil && (phase == .idle || phase == .starting || phase == .retrying)
            guard self.turnId == turnId || canAdoptTurn else { return }
            if self.turnId != turnId {
                plan = []
                planTurnId = nil
                self.startedAt = startedAt ?? Date()
            } else if self.startedAt == nil {
                self.startedAt = startedAt ?? Date()
            }
            self.turnId = turnId
            phase = .running
            completedAt = nil
            retryMessage = nil
        case .plan(let turnId, let steps):
            guard self.turnId == turnId, isRunning else { return }
            planTurnId = turnId
            plan = steps
        case .retrying(let turnId, let message):
            guard turnId == nil || self.turnId == nil || self.turnId == turnId else { return }
            if isRunning { phase = .retrying }
            retryMessage = message
        case .clearRetry:
            if phase == .retrying { phase = turnId == nil ? .starting : .running }
            retryMessage = nil
        case .terminal(let turnId, let terminalPhase, let completedAt):
            guard turnId == nil || self.turnId == nil || self.turnId == turnId else { return }
            phase = terminalPhase
            self.turnId = nil
            self.completedAt = completedAt ?? Date()
            retryMessage = nil
            planTurnId = nil
            plan = []
        }
    }
}

enum TaskRunEvent {
    case reset
    case starting(startedAt: Date?)
    case hydrate(running: Bool, turnId: String?, startedAt: Date?)
    case started(turnId: String, startedAt: Date?)
    case progress(turnId: String, startedAt: Date?)
    case plan(turnId: String, steps: [ExecutionPlanStep])
    case retrying(turnId: String?, message: String?)
    case clearRetry
    case terminal(turnId: String?, phase: TaskRunPhase, completedAt: Date?)
}
