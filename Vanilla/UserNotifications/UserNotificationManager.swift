//
//  UserNotificationManager.swift
//  Ice
//

import UserNotifications

/// Manager for user notifications.
@MainActor
final class UserNotificationManager: NSObject {
    /// The shared app state.
    private(set) weak var appState: AppState?

    /// The current notification center.
    var notificationCenter: UNUserNotificationCenter { .current() }

    /// Creates a user notification manager with the given app state.
    init(appState: AppState) {
        self.appState = appState
        super.init()
    }

    /// Sets up the manager.
    func performSetup() {
        notificationCenter.delegate = self
    }

    /// Requests authorization to allow user notifications for the app.
    func requestAuthorization() {
        Task {
            do {
                try await notificationCenter.requestAuthorization(options: [.badge, .alert, .sound])
            } catch {
                Logger.userNotifications.error("Failed to request authorization for notifications: \(error)")
            }
        }
    }

    /// Schedules the delivery of a local notification.
    func addRequest(with identifier: UserNotificationIdentifier, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body

        let request = UNNotificationRequest(
            identifier: identifier.rawValue,
            content: content,
            trigger: nil
        )

        notificationCenter.add(request)
    }

    /// Removes the notifications from Notification Center that match the given identifiers.
    func removeDeliveredNotifications(with identifiers: [UserNotificationIdentifier]) {
        notificationCenter.removeDeliveredNotifications(withIdentifiers: identifiers.map { $0.rawValue })
    }
}

// MARK: UserNotificationManager: UNUserNotificationCenterDelegate
extension UserNotificationManager: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        // UserNotifications can call its delegate away from the main actor.
        // Pass only immutable identifiers to the UI handler.
        let identifier = response.notification.request.identifier
        let actionIdentifier = response.actionIdentifier
        await handleResponse(identifier: identifier, actionIdentifier: actionIdentifier)
    }

    private func handleResponse(identifier: String, actionIdentifier: String) {
        guard
            UserNotificationIdentifier(rawValue: identifier) == .updateCheck,
            actionIdentifier == UNNotificationDefaultActionIdentifier
        else { return }
        appState?.updatesManager.checkForUpdates()
    }
}

// MARK: - Logger
private extension Logger {
    static let userNotifications = Logger(category: "UserNotifications")
}
