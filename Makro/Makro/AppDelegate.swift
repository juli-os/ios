import UIKit
import UserNotifications

/// Bridges UIApplicationDelegate into the SwiftUI lifecycle so the app can
/// register for APNs remote notifications.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            DispatchQueue.main.async {
                if granted {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            }
        }
        return true
    }

    /// App foregrounded = the user is looking at it; the old banners in
    /// Notification Center are no longer the reminder surface — clear them
    /// all (badge to zero too). Otherwise the old notification for a
    /// finished case hangs there forever: tapping in shows no matching
    /// content, and nothing ever makes it go away.
    func applicationDidBecomeActive(_ application: UIApplication) {
        application.applicationIconBadgeNumber = 0
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        print("[APNs] token registered: \(token.prefix(16))… (\(token.count) hex chars)")
        let deviceID = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        Task {
            do {
                try await APIClient.shared.registerDeviceToken(deviceID: deviceID, token: token)
                print("[APNs] token uploaded to backend")
            } catch {
                print("[APNs] token upload failed: \(error)")
            }
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("[APNs] registration FAILED: \(error.localizedDescription)")
        print("[APNs] hint: check entitlements aps-environment + provisioning profile has Push capability")
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    // Tapping the banner → deep-link into the relevant entity. Routed through
    // DeepLinkRouter (not NotificationCenter): cold-start taps fire before any
    // SwiftUI view exists to subscribe.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        DispatchQueue.main.async {
            if let workflow = info["workflow_id"] as? String {
                // Pipeline gate push → straight to the workflow detail sheet.
                DeepLinkRouter.shared.gate = GateLink(
                    workflowID: workflow,
                    stepID: info["step_id"] as? String ?? ""
                )
            }
            // Note (2026-09-20 review): the server's apnsAlertPayload never
            // carries a `session` key — "push-to-terminal for a session" was
            // a dead branch and was removed. If the server ever starts
            // sending the session key, restore the DeepLinkRouter.shared.session
            // routing here.
        }
        completionHandler()
    }

    // Show banner while app is in foreground too.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
