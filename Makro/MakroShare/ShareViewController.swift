import Social
import UIKit
import UniformTypeIdentifiers

// System share → Makro Chat (wf_030261e0a13a): pick "Makro" in the share
// sheet of WeChat and other apps; the content lands in pending_share via the
// App Group, and when the user switches back to Makro the main app reads it
// and fills the chat input box as a draft (the user can edit, then send to
// start a job or discuss).
//
// No openURL invocation: extensionContext.open in a Share Extension is
// unofficial behavior (unreliable and an App Review risk); "save → switch
// back to Makro" suffices, and the UI copy says so explicitly.
class ShareViewController: SLComposeServiceViewController {
    static let groupID = "group.com.cybernagle.makro"
    static let pendingKey = "pending_share"

    override func isContentValid() -> Bool {
        (contentText?.count ?? 0) <= 20000
    }

    override func configurationItems() -> [Any]! { [] }

    private var attachmentURL: String?
    // R1 P2-6: URL-attachment load-completion fence — at didSelectPost the
    // load may not have landed yet (loadItem is async); the old
    // implementation published immediately = an instant publish lost the link.
    private var urlLoadSettled = false
    private var pendingPostText: String?
    private var finished = false

    override func viewDidLoad() {
        super.viewDidLoad()
        placeholder = "Send to Makro intake (editable)"
        // Take the first URL attachment (WeChat articles and similar share a link)
        if let item = extensionContext?.inputItems.first as? NSExtensionItem {
            var foundURLProvider = false
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    foundURLProvider = true
                    provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { [weak self] item, _ in
                        // The callback queue is unspecified (possibly main) —
                        // hop to the main queue before settling state; never
                        // semaphore-wait on the main thread (same queue as the
                        // callback = deadlock).
                        DispatchQueue.main.async {
                            guard let self else { return }
                            if let url = item as? URL {
                                self.attachmentURL = url.absoluteString
                            } else if let url = item as? NSURL {
                                self.attachmentURL = url.absoluteString
                            } else if let s = item as? String {
                                self.attachmentURL = s
                            }
                            self.settleURLLoad()
                        }
                    }
                    break
                }
            }
            if !foundURLProvider { urlLoadSettled = true } // there was no URL attachment to begin with; publishing need not wait
        } else {
            urlLoadSettled = true
        }
        // Fallback: publish even if the provider callback never arrives (after 3s it still saves, just without the link).
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.settleURLLoad()
        }
    }

    /// Completion fence: settle exactly once; if the user already hit publish (stashed in pendingPostText), publish right now.
    private func settleURLLoad() {
        guard !urlLoadSettled else { return }
        urlLoadSettled = true
        if let text = pendingPostText {
            pendingPostText = nil
            publish(text: text)
        }
    }

    override func didSelectPost() {
        let text = contentText ?? ""
        if urlLoadSettled {
            publish(text: text)
        } else {
            pendingPostText = text // publish with the URL attached after the callback/timeout settles
        }
    }

    /// The single publish exit: an idempotent finished guard; completeRequest exactly once.
    private func publish(text: String) {
        guard !finished else { return }
        finished = true
        var t = text
        if let u = attachmentURL, !t.contains(u) {
            t = t.isEmpty ? u : t + "\n" + u
        }
        var sourceApp = ""
        if let items = extensionContext?.inputItems, let item = items.first as? NSExtensionItem {
            let info = item.userInfo
            if let key = info?["NSExtensionItemSourceApplicationIdentifierKey"], let s = key as? String {
                sourceApp = s
            }
        }
        let payload: [String: Any] = [
            "text": t,
            "source": sourceApp,
            "at": Date().timeIntervalSince1970,
        ]
        UserDefaults(suiteName: Self.groupID)?.set(payload, forKey: Self.pendingKey)
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }
}
