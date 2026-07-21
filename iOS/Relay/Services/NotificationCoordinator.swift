import Foundation
import UserNotifications

final class NotificationCoordinator {
    private let center = UNUserNotificationCenter.current()

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) ?? false
    }

    func schedule(identifier: String, title: String, body: String, threadId: String?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let threadId { content.userInfo = ["threadId": threadId] }
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }
}
