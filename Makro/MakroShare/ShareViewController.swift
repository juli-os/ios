import Social
import UIKit
import UniformTypeIdentifiers

// 系统分享 → Makro Chat（wf_030261e0a13a）：微信等 App 分享面板选「Makro」，
// 内容经 App Group 落 pending_share，用户切回 Makro 时由主 app 读取并填入
// chat 输入框作草稿（用户可编辑后发送开单/讨论）。
//
// 不做 openURL 唤起：Share Extension 的 extensionContext.open 是非官方行为
// （不可靠且有审核风险），靠「保存 → 切回 Makro」即可，UI 文案明示。
class ShareViewController: SLComposeServiceViewController {
    static let groupID = "group.com.cybernagle.makro"
    static let pendingKey = "pending_share"

    override func isContentValid() -> Bool {
        (contentText?.count ?? 0) <= 20000
    }

    override func configurationItems() -> [Any]! { [] }

    private var attachmentURL: String?
    // R1 P2-6：URL 附件加载完成栅栏——didSelectPost 时加载可能尚未回填
    // （loadItem 异步），旧实现直接发布=秒按发布丢链接。
    private var urlLoadSettled = false
    private var pendingPostText: String?
    private var finished = false

    override func viewDidLoad() {
        super.viewDidLoad()
        placeholder = "发给 Makro 开单（可编辑）"
        // 取第一个 URL 附件（微信文章等场景分享的是链接）
        if let item = extensionContext?.inputItems.first as? NSExtensionItem {
            var foundURLProvider = false
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    foundURLProvider = true
                    provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { [weak self] item, _ in
                        // 回调队列不定（可能主线程）——归队主线程再落状态；
                        // 绝不在主线程信号量等待（与回调同队列=死锁）。
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
            if !foundURLProvider { urlLoadSettled = true } // 本来就没有 URL 附件，发布无需等待
        } else {
            urlLoadSettled = true
        }
        // 兜底：provider 回调异常不来也得发布（3s 后照常落盘，只是没链接）。
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.settleURLLoad()
        }
    }

    /// 完成栅栏：只结算一次；若用户已按发布（pendingPostText 暂存）则此刻发布。
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
            pendingPostText = text // 回调/超时结算后补 URL 再发布
        }
    }

    /// 唯一发布出口：finished 幂等守卫，completeRequest 恰一次。
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
