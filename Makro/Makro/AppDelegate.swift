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
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
            DispatchQueue.main.async {
                // 显示授权只管横幅；token 注册不依赖它——无条件注册（2026-10-15
                // 修复：曾因 granted=false 永不注册，权限一关整条链路静默死）。
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
        // 换服务器 → 失效 token 去重记忆并向新服务器补传（2026-10-16 P1）。
        // post 侧是 switchProfile 的 UI 调用线程=主线程，本 observer 亦主线程。
        NotificationCenter.default.addObserver(
            self, selector: #selector(serverDidChange),
            name: .makroServerChanged, object: nil
        )
        return true
    }

    /// App 前台化 = 用户正在看，通知中心的旧横幅不再是提醒面——全部清掉
    /// （含角标归零）。否则完结案卷的旧通知永远挂在那里：点进去没有对应
    /// 内容，也没有任何机制让它消失。
    func applicationDidBecomeActive(_ application: UIApplication) {
        application.applicationIconBadgeNumber = 0
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(token, forKey: Self.apnsTokenKey)
        print("[APNs] token registered: \(token.prefix(16))… (\(token.count) hex chars)")
        Self.uploadToken(token)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("[APNs] registration FAILED: \(error.localizedDescription)")
        print("[APNs] hint: check entitlements aps-environment + provisioning profile has Push capability")
    }

    // MARK: - 上传与重试（2026-10-15 修复：旧实现一次性上传无重试，冷启动时
    // 服务器不可达 token 就白拿；现缓存 token，前台激活时补发。服务端幂等
    // upsert，重复上传无害。）

    private static let apnsTokenKey = "makro_apns_token"

    /// 最近一次上传（含在途乐观标记）的 token + 失败旗标：2026-10-16 修复——
    /// 每次前台 retryPendingTokenUpload 既主动补发缓存 token，又无条件
    /// registerForRemoteNotifications 让 didRegister 回调再传一次（每前台
    /// 2 次 POST，纯流量冗余）。token 未变且上次上传未失败 → 跳过；失败
    /// 旗标置位 → 下次前台照常重试（「补发」语义不变）。
    private static var uploadedToken: String?
    private static var uploadFailed = false

    /// MakroApp scenePhase=.active 时调用：重注册（让系统轮换的 token 刷上来）
    /// + 补发缓存里未确认的 token。
    static func retryPendingTokenUpload() {
        UIApplication.shared.registerForRemoteNotifications()
        guard let token = UserDefaults.standard.string(forKey: apnsTokenKey) else { return }
        uploadToken(token)
    }

    /// Config.switchProfile 实际换了服务器时调用（经 .makroServerChanged）：
    /// token 没变但上传目标变了——去重键只有 token，不先失效「已上传」记忆
    /// 的话补传会被 uploadToken 守卫静默吞成 no-op，新服务器要等到下一次
    /// 后台→前台才拿得到 token。清记忆后补传一次（下一前台同 token 且未失败
    /// → 跳过，不多发）；无缓存 token（注册回调未到）时不补：didRegister
    /// 稍后自会上传到「当时」的服务器，此时已是新服务器。
    ///
    /// 已知产品缺口（2026-10-16 备案，客户端侧无法修复）：旧服务器持有的
    /// token 不会注销——服务端注册表是扁平 token 列表、推送全量扇出，
    /// `POST /api/device-token` 无删除语义，除名仅靠 APNs Unregistered 回馈。
    /// 切换 profile ≠ 退出旧服务器的通知，需服务端补注销端点后客户端在切换
    /// 时对旧 base 调用。
    @objc private func serverDidChange() {
        Self.uploadTokenAfterServerChange()
    }

    static func uploadTokenAfterServerChange() {
        uploadedToken = nil
        uploadFailed = false
        guard let token = UserDefaults.standard.string(forKey: apnsTokenKey) else { return }
        uploadToken(token)
    }

    private static func uploadToken(_ token: String) {
        // 未变且未失败（含在途）→ 跳过：didRegister 回调与前台补发同 token
        // 只发一次；轮换后的新 token 必发。
        if token == uploadedToken && !uploadFailed { return }
        uploadedToken = token
        uploadFailed = false
        let deviceID = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        // @MainActor（2026-10-16 P2）：uploadFailed 是无隔离静态 Bool，读侧
        // （本函数 + 三个调用方）全在主线程，await 返回后的失败置位也须收敛
        // 回主线程，否则与主线程读写构成数据竞争。
        Task { @MainActor in
            do {
                try await APIClient.shared.registerDeviceToken(deviceID: deviceID, token: token)
                print("[APNs] token uploaded to backend")
            } catch {
                uploadFailed = true
                print("[APNs] token upload failed: \(error) — retry on next foreground")
            }
        }
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
            // 注记（2026-09-20 审查）：服务端 apnsAlertPayload 从不携带 `session`
            // 键——「会话推送直达终端」原是死分支，已删。若将来服务端补发
            // session 键，在这里恢复 DeepLinkRouter.shared.session 路由即可。
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
