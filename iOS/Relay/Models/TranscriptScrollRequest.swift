import Foundation

struct TranscriptScrollRequest: Equatable {
    enum Reason: Equatable {
        case outgoingMessage
    }

    let sequence: Int
    let targetId: String
    let reason: Reason
}
