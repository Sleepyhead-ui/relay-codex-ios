import Foundation

enum DeliveryRecoveryAction: Equatable {
    case retry
    case waitForHistory
    case rejectStaleSteer
}

enum DeliveryRecoveryPolicy {
    static func action(
        expectedTurnId: String?,
        runtimeRunning: Bool,
        activeTurnId: String?
    ) -> DeliveryRecoveryAction {
        guard let expectedTurnId else {
            return runtimeRunning ? .waitForHistory : .retry
        }
        guard runtimeRunning, activeTurnId == nil || activeTurnId == expectedTurnId else {
            return .rejectStaleSteer
        }
        return .retry
    }
}
