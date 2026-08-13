import os
import UserNotifications

private let log = Logger(subsystem: "com.akram.ecosystem", category: "notifications")

/// Shows phone notifications in macOS Notification Center and routes clicks,
/// dismissals, and inline replies back to the phone.
@MainActor
final class NotificationMirror: NSObject {
    /// Wired by ConnectionManager; fire-and-forget send to the phone.
    var send: (@MainActor (Message) -> Void)?

    private var started = false
    // macOS wants every category registered up front, but the phone's actions
    // differ per notification — so each live notification gets a category named
    // after its key, and the set is re-registered as they come and go.
    private var categories: Set<UNNotificationCategory> = []

    func start() {
        guard !started else { return }
        started = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .badge]) { granted, error in
            if let error { log.warning("authorization: \(error, privacy: .public)") }
            log.info("notification permission granted: \(granted)")
        }
    }

    func handlePosted(_ p: NotifyPostedPayload) {
        start()
        let center = UNUserNotificationCenter.current()

        let content = UNMutableNotificationContent()
        content.title = p.app
        if let title = p.title, !title.isEmpty { content.subtitle = title }
        content.body = p.text ?? ""
        content.threadIdentifier = p.pkg ?? p.app   // group by app, like the phone
        // No sound: the phone already made whatever noise the app wanted.

        let actions = (p.actions ?? []).enumerated().map { index, action in
            action.reply ?? false
                ? UNTextInputNotificationAction(
                    identifier: "a\(index)", title: action.title, options: [],
                    textInputButtonTitle: "Send", textInputPlaceholder: "")
                : UNNotificationAction(identifier: "a\(index)", title: action.title)
        }
        // Even button-less notifications get a category: .customDismissAction is
        // what lets a Mac-side dismiss clear the phone's copy.
        let category = UNNotificationCategory(
            identifier: p.key, actions: actions, intentIdentifiers: [],
            options: .customDismissAction)
        categories = categories.filter { $0.identifier != p.key }
        categories.insert(category)
        center.setNotificationCategories(categories)
        content.categoryIdentifier = p.key

        // Same identifier replaces: updates to one conversation don't stack.
        center.add(UNNotificationRequest(identifier: p.key, content: content,
                                         trigger: nil))
    }

    func handleDismissed(key: String) {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [key])
        let remaining = categories.filter { $0.identifier != key }
        if remaining.count != categories.count {
            categories = remaining
            center.setNotificationCategories(remaining)
        }
    }
}

extension NotificationMirror: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // Pull the Sendable bits out before hopping actors.
        let key = response.notification.request.identifier
        let action = response.actionIdentifier
        let reply = (response as? UNTextInputNotificationResponse)?.userText
        Task { @MainActor in
            switch action {
            case UNNotificationDismissActionIdentifier:
                send?(.notifyDismiss(.init(key: key)))
            case UNNotificationDefaultActionIdentifier:
                break   // plain click on the banner body: nothing to relay
            default:
                if action.hasPrefix("a"), let index = Int(action.dropFirst()) {
                    send?(.notifyAction(.init(key: key, action: index, reply: reply)))
                }
            }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }
}
