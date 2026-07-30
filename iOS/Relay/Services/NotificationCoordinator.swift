import Foundation
import UserNotifications

enum RelayNotificationAction: Equatable {
    case openThread(String)
    case reply(threadId: String, text: String)
}

struct PendingNotificationReply: Codable, Equatable, Identifiable {
    let id: String
    let threadId: String
    let text: String
    let createdAt: Date

    init(id: String = UUID().uuidString, threadId: String, text: String, createdAt: Date = Date()) {
        self.id = id
        self.threadId = threadId
        self.text = text
        self.createdAt = createdAt
    }
}

enum NotificationPreview {
    static func text(from source: String, limit: Int = 220) -> String {
        let parsed = AgentMessageContent.parse(source).visibleText
        let replacements: [(String, String)] = [
            (#"!\[([^\]]*)\]\([^\)]*\)"#, "$1"),
            (#"\[([^\]]+)\]\([^\)]*\)"#, "$1"),
            (#"```[^\n]*\n?"#, ""),
            (#"[`*_>#]"#, ""),
            (#"\s+"#, " ")
        ]
        let normalized = replacements.reduce(parsed) { value, replacement in
            value.replacingOccurrences(
                of: replacement.0,
                with: replacement.1,
                options: .regularExpression
            )
        }.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > limit else { return normalized }
        let end = normalized.index(normalized.startIndex, offsetBy: max(1, limit - 1))
        return String(normalized[..<end]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}

final class NotificationCoordinator: NSObject, UNUserNotificationCenterDelegate {
    static let taskCompletedCategoryIdentifier = "relay.task.completed"
    static let replyActionIdentifier = "relay.task.reply"

    private let center: UNUserNotificationCenter
    private var actionHandler: ((RelayNotificationAction) -> Void)?

    override init() {
        center = .current()
        super.init()
        center.delegate = self
        registerCategories()
    }

    func configure(actionHandler: @escaping (RelayNotificationAction) -> Void) {
        self.actionHandler = actionHandler
        center.delegate = self
        registerCategories()
    }

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) ?? false
    }

    func schedule(
        identifier: String,
        title: String,
        subtitle: String? = nil,
        body: String,
        threadId: String?,
        categoryIdentifier: String? = nil
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        if let subtitle { content.subtitle = subtitle }
        content.body = body
        content.sound = .default
        if let threadId {
            content.userInfo = ["threadId": threadId]
            content.threadIdentifier = threadId
        }
        if let categoryIdentifier { content.categoryIdentifier = categoryIdentifier }
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        guard let threadId = response.notification.request.content.userInfo["threadId"] as? String else { return }
        if response.actionIdentifier == Self.replyActionIdentifier,
           let response = response as? UNTextInputNotificationResponse {
            let text = response.userText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            actionHandler?(.reply(threadId: threadId, text: text))
        } else if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            actionHandler?(.openThread(threadId))
        }
    }

    private func registerCategories() {
        let reply = UNTextInputNotificationAction(
            identifier: Self.replyActionIdentifier,
            title: "回复",
            options: [.foreground],
            textInputButtonTitle: "发送",
            textInputPlaceholder: "继续这个任务"
        )
        let category = UNNotificationCategory(
            identifier: Self.taskCompletedCategoryIdentifier,
            actions: [reply],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }
}
