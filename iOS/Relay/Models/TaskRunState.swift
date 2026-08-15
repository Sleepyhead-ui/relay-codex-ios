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
    var outputStartedAt: Date?
    var completedAt: Date?
    var retryMessage: String?
    var planTurnId: String?
    var plan: [ExecutionPlanStep] = []
    var diffTurnId: String?
    var diffStatistics: DiffStatistics?

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
                diffTurnId = nil
                diffStatistics = nil
                self.startedAt = startedAt ?? Date()
            } else if self.startedAt == nil {
                self.startedAt = startedAt ?? Date()
            }
            self.turnId = turnId
            phase = .running
            completedAt = nil
            retryMessage = nil
        case .outputStarted(let turnId, let outputStartedAt):
            guard self.turnId == turnId, isRunning, self.outputStartedAt == nil else { return }
            self.outputStartedAt = outputStartedAt ?? Date()
        case .plan(let turnId, let steps):
            guard self.turnId == turnId, isRunning else { return }
            planTurnId = turnId
            plan = steps
        case .diff(let turnId, let statistics):
            guard self.turnId == turnId, isRunning else { return }
            diffTurnId = turnId
            diffStatistics = statistics
        case .retrying(let turnId, let message):
            guard turnId == nil || self.turnId == nil || self.turnId == turnId else { return }
            if isRunning { phase = .retrying }
            retryMessage = message
        case .clearRetry:
            if phase == .retrying { phase = turnId == nil ? .starting : .running }
            retryMessage = nil
        case .terminal(let turnId, let terminalPhase, let completedAt):
            // Once a concrete turn is known, an unscoped terminal event can
            // belong to an older App Server request while Desktop Codex keeps
            // writing the active rollout. Only a matching turn may stop it.
            if let activeTurnId = self.turnId {
                guard turnId == activeTurnId else { return }
            }
            phase = terminalPhase
            self.turnId = nil
            self.completedAt = completedAt ?? Date()
            outputStartedAt = nil
            retryMessage = nil
            planTurnId = nil
            plan = []
            diffTurnId = nil
            diffStatistics = nil
        }
    }
}

enum TaskRunEvent {
    case reset
    case starting(startedAt: Date?)
    case hydrate(running: Bool, turnId: String?, startedAt: Date?)
    case started(turnId: String, startedAt: Date?)
    case progress(turnId: String, startedAt: Date?)
    case outputStarted(turnId: String, at: Date?)
    case plan(turnId: String, steps: [ExecutionPlanStep])
    case diff(turnId: String, statistics: DiffStatistics)
    case retrying(turnId: String?, message: String?)
    case clearRetry
    case terminal(turnId: String?, phase: TaskRunPhase, completedAt: Date?)
}
