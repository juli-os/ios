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
    /// Deep link to the Artifacts filtered view (board 06 "its artifacts" → Artifacts tab + producer filter).
    @Published var artifactsProducer: String?
    /// Shared system draft (wf_030261e0a13a): the Share Extension drops it
    /// into pending_share via the App Group; the main app reads it out on
    /// activation and sets it here → ChatView fills the input box (the user
    /// edits, then sends).
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
                // Intake = the front door (09-29 conversation ruling: one
                // sentence starts one job — clarify loop + read-only queries
                // + confirmed intake via the startTask front door). Feedback
                // is also a kind of intake (0929 user ruling); it merged into
                // the intake chat and the feedback tab was retired.
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

                // Settings = the last tab-bar item (board 02 visual ruling: globally reachable, no text).
                NavigationStack { SettingsView() }
                    .tabItem { Label("", systemImage: "gearshape") }
                    .tag(4)
            }
            .onReceive(CallRouter.shared.$pendingStart) { wantsCall in
                // Siri/Shortcuts "start call" → switch to the intake tab
                // first (CallView's host); ChatView's double-consumption
                // logic presents the full-screen call.
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
                // Board 06 cross-dimension chip: Agents' "its artifacts" → the Artifacts filtered view.
                guard let producer else { return }
                selectedTab = 3
            }
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active {
                NotificationCenter.default.post(name: .makroReconnect, object: nil)
                // Shared system draft (wf_030261e0a13a): the Share Extension
                // drops it into the App Group; taken on activation → the
                // ChatView input box (the user edits, then sends to start a
                // job or discuss).
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
    /// Emitted by `CallRouter.requestEnd()`: even when CallView is not in
    /// the foreground (app backgrounded / not presented), ChatViewModel can
    /// still stop STT/TTS/audio at the model layer.
    static let makroEndCall = Notification.Name("makroEndCall")
}
