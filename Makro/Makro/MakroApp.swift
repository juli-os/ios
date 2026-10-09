import SwiftUI

struct GateLink: Equatable {
    let workflowID: String
    let stepID: String
}

/// Push deep-links land here from the AppDelegate. A plain NotificationCenter
/// post loses cold-start taps (they fire before any SwiftUI view subscribes);
/// this object exists from launch and @Published replays the current value to
/// late subscribers.
@MainActor
final class DeepLinkRouter: ObservableObject {
    static let shared = DeepLinkRouter()
    @Published var gate: GateLink?
    @Published var session: String?
    /// Artifacts 过滤视图深链（板 06「它的产物」→ Artifacts tab + producer 筛选）。
    @Published var artifactsProducer: String?
    /// 系统分享草稿（wf_030261e0a13a）：Share Extension 经 App Group 落
    /// pending_share，主 app 激活时读出置此 → ChatView 填输入框（用户编辑后发送）。
    @Published var shareDraft: String?
}

@main
struct MakroApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var bonjourTrigger = LocalNetworkTrigger()
    @State private var selectedTab = 0
    @State private var gateLink: GateLink?

    var body: some Scene {
        WindowGroup {
            TabView(selection: $selectedTab) {
                // 发单 = 前门（09-29 对话定案：说一句话开一单——clarify
                // loop + 只读查询 + 确认开单走 startTask 正门）。反馈也是
                // 开单的一种（0929 用户裁决），随发单对话集成，反馈 tab 退役。
                ChatView()
                    .tabItem { Label("Intake", systemImage: "bubble.left") }
                    .tag(0)

                LifecycleView(deepLink: $gateLink)
                    .tabItem { Label("Flow", systemImage: "arrow.triangle.branch") }
                    .tag(1)

                AgentsView()
                    .tabItem { Label("Agents", systemImage: "cpu") }
                    .tag(2)

                ArtifactsView()
                    .tabItem { Label("Artifacts", systemImage: "doc.richtext") }
                    .tag(3)

                // 设置 = tab 栏末项（板 02 视觉裁决：全局可达，无文字）。
                NavigationStack { SettingsView() }
                    .tabItem { Label("", systemImage: "gearshape") }
                    .tag(4)
            }
            .onReceive(CallRouter.shared.$pendingStart) { wantsCall in
                // Siri/Shortcuts「开始通话」→ 先切到发单 tab（CallView 的
                // 宿主），ChatView 的双消费逻辑负责弹全屏通话。
                if wantsCall { selectedTab = 0 }
            }
            .onReceive(DeepLinkRouter.shared.$gate) { link in
                // Gate push → Flow tab (the approval inbox).
                guard let link else { return }
                gateLink = link
                selectedTab = 1
            }
            .onReceive(DeepLinkRouter.shared.$session) { session in
                // Session push → Agents tab; AgentsView replays the router
                // value into its navigation path on subscription.
                guard session != nil else { return }
                selectedTab = 2
            }
            .onReceive(DeepLinkRouter.shared.$artifactsProducer) { producer in
                // 板 06 跨维芯片：Agents 的「它的产物」→ Artifacts 过滤视图。
                guard let producer else { return }
                selectedTab = 3
            }
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active {
                NotificationCenter.default.post(name: .makroReconnect, object: nil)
                // 系统分享草稿（wf_030261e0a13a）：Share Extension 落 App Group，
                // 激活即取走 → ChatView 输入框（用户编辑后发送开单/讨论）。
                if let group = UserDefaults(suiteName: "group.com.cybernagle.makro"),
                   let payload = group.dictionary(forKey: "pending_share"),
                   let text = payload["text"] as? String, !text.isEmpty {
                    group.removeObject(forKey: "pending_share")
                    DeepLinkRouter.shared.shareDraft = text
                }
            }
        }
    }
}

private class LocalNetworkTrigger: NSObject, ObservableObject, NetServiceBrowserDelegate {
    private var browser: NetServiceBrowser?
    private var foundServices: [NetService] = []

    override init() {
        super.init()
        browser = NetServiceBrowser()
        browser?.delegate = self
        browser?.searchForServices(ofType: "_http._tcp.", inDomain: "local.")
    }
}

extension Notification.Name {
    static let makroReconnect = Notification.Name("makroReconnect")
    /// `CallRouter.requestEnd()` 发出：即使 CallView 不在前台（app 后台/
    /// 未呈现），ChatViewModel 也能在模型层停掉 STT/TTS/音频。
    static let makroEndCall = Notification.Name("makroEndCall")
}
