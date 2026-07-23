import Foundation

enum ConnectionRetryPolicy {
    static let stableResetSeconds: UInt64 = 10

    static func delaySeconds(attempt: Int, immediate: Bool = false) -> TimeInterval {
        guard !immediate else { return 0 }
        return min(pow(1.7, Double(max(0, attempt - 1))), 8)
    }
}
