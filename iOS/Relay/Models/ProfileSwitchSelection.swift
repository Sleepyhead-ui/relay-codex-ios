import Foundation

enum ProfileSwitchSelection {
    static func restoredThreadId(previous: String?, availableThreadIds: [String]) -> String? {
        if let previous, availableThreadIds.contains(previous) { return previous }
        return availableThreadIds.first
    }
}
