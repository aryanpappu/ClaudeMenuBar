import Foundation
import UserNotifications

/// Posts native macOS notifications when a session needs approval or finishes,
/// with inline Approve/Focus actions that route back into AppState.
@MainActor
final class NotificationManager: NSObject {
    static let shared = NotificationManager()

    private let center = UNUserNotificationCenter.current()

    private enum Category {
        static let waiting = "WAITING"
        static let waitingOpenOnly = "WAITING_OPEN"
        static let done = "DONE"
    }
    private enum Action {
        static let approve = "APPROVE"
        static let focus = "FOCUS"
    }

    // Call once at launch: registers action categories, becomes the delegate,
    // and asks for permission.
    func setup() {
        center.delegate = self

        let approve = UNNotificationAction(identifier: Action.approve, title: "Approve", options: [])
        let openAction = UNNotificationAction(identifier: Action.focus, title: "Open", options: [.foreground])
        let focus = UNNotificationAction(identifier: Action.focus, title: "Focus", options: [.foreground])
        let waiting = UNNotificationCategory(identifier: Category.waiting,
                                             actions: [approve, focus], intentIdentifiers: [])
        // Same banner without the Approve button, used while one-click
        // Approve is turned off.
        let waitingOpenOnly = UNNotificationCategory(identifier: Category.waitingOpenOnly,
                                                     actions: [openAction], intentIdentifiers: [])
        let done = UNNotificationCategory(identifier: Category.done,
                                          actions: [focus], intentIdentifiers: [])
        center.setNotificationCategories([waiting, waitingOpenOnly, done])

        // Alert only — the app already plays its own SoundManager cues, so we
        // don't want a duplicate system notification sound.
        center.requestAuthorization(options: [.alert]) { granted, error in
            if let error { NSLog("Notification authorization error: \(error)") }
            else if !granted { NSLog("Notifications not granted — banners disabled") }
        }
    }

    func notifyWaiting(session: Session) {
        let content = UNMutableNotificationContent()
        content.title = "Approval needed — \(session.displayName)"
        content.body = session.needsAnswer
            ? "Claude has a question for you"
            : session.pendingRequest.map { "Wants to use \($0)" } ?? "Claude needs your permission"
        content.categoryIdentifier = (AppState.shared.oneClickApprove && !session.needsAnswer)
            ? Category.waiting : Category.waitingOpenOnly
        content.userInfo = ["session_id": session.id]
        post(content, id: "waiting-\(session.id)")
    }

    func notifyDone(session: Session) {
        let content = UNMutableNotificationContent()
        content.title = "Done — \(session.displayName)"
        content.body = (AppState.shared.notificationPreviews ? session.activity : nil) ?? "Task finished"
        content.categoryIdentifier = Category.done
        content.userInfo = ["session_id": session.id]
        post(content, id: "done-\(session.id)")
    }

    /// Removes a delivered/pending "approval needed" banner once the request
    /// has been answered, so its Approve action can't fire later.
    func clearWaiting(sessionID: String) {
        let id = "waiting-\(sessionID)"
        center.removeDeliveredNotifications(withIdentifiers: [id])
        center.removePendingNotificationRequests(withIdentifiers: [id])
    }

    private func post(_ content: UNMutableNotificationContent, id: String) {
        // Reuse a stable id per session+kind so a newer notification replaces
        // the older one instead of stacking.
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}

extension NotificationManager: UNUserNotificationCenterDelegate {
    // Show the banner even while our (accessory) app is active.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let sessionID = response.notification.request.content.userInfo["session_id"] as? String
        let actionID = response.actionIdentifier
        // Keep the response alive until the action has actually been dispatched
        // on the main actor — calling completionHandler() synchronously here
        // risks the (accessory) app being suspended before the work runs.
        Task { @MainActor in
            defer { completionHandler() }
            guard let sessionID else { return }
            switch actionID {
            case Action.approve:
                AppState.shared.sendApproval(for: sessionID)
            case Action.focus, UNNotificationDefaultActionIdentifier:
                if let session = AppState.shared.sessions[sessionID] {
                    AppState.shared.focusTerminal(for: session)
                }
            default:
                break
            }
        }
    }
}
