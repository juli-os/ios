import Foundation
import CryptoKit
import Security

/// 一个可切换的服务器档案（2026-10-16 多服务器）：URL 在 UserDefaults 的
/// profiles JSON 里，密码在该 profile 专属的 Keychain 槽位（延续「密码不落
/// UserDefaults」的既有纪律）。
struct ServerProfile: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var serverURL: String
}

class Config: ObservableObject {
    static let shared = Config()

    /// Factory default server address — the fallback when nothing is stored or
    /// the stored value can't form a URL. 宁可连不上，不崩（2026-09-20 P2）。
    static let defaultServerURL = "https://juli-server.example:7171"

    private enum Key {
        static let serverURL = "makro_server_url"
        static let password = "makro_password"
        static let profiles = "makro_profiles"
        static let activeProfileID = "makro_active_profile_id"
        static let azureRegion = "azure_speech_region"
        static let azureKey = "azure_speech_key"
        static let commitPhrases = "makro_commit_phrases"
        static let vadEnabled = "makro_vad_enabled"
        static let vadThreshold = "makro_vad_threshold"
    }

    /// 当前激活 profile 的镜像（全 App 现有引用零改动）——save() 时写回。
    @Published var serverURL: String
    /// 同上：激活 profile 的 Keychain 密码镜像。
    @Published var password: String
    @Published var azureRegion: String
    @Published var azureKey: String
    /// Comma-separated结束语 the user says to submit a voice turn, e.g. "请发送".
    /// Matched at the trailing edge of a recognized segment in call mode.
    @Published var commitPhrases: String
    /// When true, call mode uses local VAD + a push-stream recognizer that only
    /// consumes cloud STT quota while real speech is detected. When false, call
    /// mode falls back to the legacy always-on recognizer (silence-based send).
    @Published var vadEnabled: Bool
    /// Normalized RMS energy 0...1 above which a mic frame counts as speech.
    @Published var vadThreshold: Double
    // —— 多服务器 Profile（2026-10-16）：唯一事实源 ——
    @Published private(set) var profiles: [ServerProfile]
    @Published private(set) var activeProfileID: UUID

    private init() {
        let defaults = UserDefaults.standard
        // 存量安装首启：单服务器配置无感迁移成 "Default" profile。
        // 局部变量先算齐再赋存储属性（Swift 要求全部就位前不得经过 self）。
        let loadedProfiles: [ServerProfile]
        // true = 本次启动走了「从单服务器存量合成 profiles」的迁移分支，
        // init 收尾须把结果落盘（2026-10-16 P1：否则每次冷启动重迁移）。
        var migratedProfiles = false
        if let data = defaults.data(forKey: Key.profiles),
           let loaded = try? JSONDecoder().decode([ServerProfile].self, from: data),
           !loaded.isEmpty {
            loadedProfiles = loaded
        } else {
            let legacyURL = defaults.string(forKey: Key.serverURL) ?? Self.defaultServerURL
            // Keychain 旧单槽位 → profile 槽位；更老的 UserDefaults 明文密码兼容一次。
            var legacyPW = KeychainHelper.get(Key.password) ?? ""
            if legacyPW.isEmpty,
               let plain = defaults.string(forKey: Key.password), !plain.isEmpty {
                legacyPW = plain
                defaults.removeObject(forKey: Key.password)
            }
            let first = ServerProfile(id: UUID(), name: "Default", serverURL: legacyURL)
            loadedProfiles = [first]
            if !legacyPW.isEmpty { KeychainHelper.set(legacyPW, for: Self.profilePasswordKey(first.id)) }
            migratedProfiles = true
        }
        let savedActive = defaults.string(forKey: Key.activeProfileID).flatMap(UUID.init(uuidString:))
        let activeID = loadedProfiles.first(where: { $0.id == savedActive })?.id ?? loadedProfiles[0].id
        let active = loadedProfiles.first(where: { $0.id == activeID })
        serverURL = active?.serverURL ?? Self.defaultServerURL
        password = KeychainHelper.get(Self.profilePasswordKey(activeID)) ?? ""
        profiles = loadedProfiles
        activeProfileID = activeID
        // TLS 钉扎键一次性迁移：host-only → host:port（同 host 不同端口的
        // profile 切换不再互踩）。
        Self.migrateLegacyPins(portByHost: Self.profilePorts(loadedProfiles))
        azureRegion = defaults.string(forKey: Key.azureRegion) ?? "eastasia"
        azureKey = defaults.string(forKey: Key.azureKey) ?? ""
        commitPhrases = defaults.string(forKey: Key.commitPhrases)
            ?? "请发送,我说完了,OK,好,就这样,可以了"
        // object(forKey:) so the first-launch default is `true`; bool(forKey:)
        // returns false for an unset key, which would wrongly disable VAD.
        vadEnabled = (defaults.object(forKey: Key.vadEnabled) as? Bool) ?? true
        vadThreshold = (defaults.object(forKey: Key.vadThreshold) as? Double) ?? 0.02
        // 迁移一次性落盘（2026-10-16 P1）：否则老用户不开设置页时
        // makro_profiles 永不写入，每次冷启动重走迁移分支——UUID() 每启动
        // 生成新 id、按新 id 写新 Keychain 槽位，旧槽位成孤儿（密码副本每
        // 启动累积一份）。在 init 收尾处调用：存储属性全部就位前不得经过
        // self，故不能用迁移分支内的位置。
        if migratedProfiles, persistProfiles() {
            // 落盘成功才清 legacy 单槽位（2026-10-16 P2，顺序耦合）：先落盘
            // 后清理——顺序颠倒且 encode 失败时，重迁移读不到旧密码 = 丢密码。
            KeychainHelper.remove(Key.password)
        }
    }

    func save() {
        // serverURL 校验与镜像→profile 写回收敛进 persistActiveProfileEdits
        // （与 switchProfile 共用同一语义，2026-10-16 P2）。
        persistActiveProfileEdits()
        persistProfiles()
        UserDefaults.standard.set(azureRegion, forKey: Key.azureRegion)
        UserDefaults.standard.set(azureKey, forKey: Key.azureKey)
        UserDefaults.standard.set(commitPhrases, forKey: Key.commitPhrases)
        UserDefaults.standard.set(vadEnabled, forKey: Key.vadEnabled)
        UserDefaults.standard.set(vadThreshold, forKey: Key.vadThreshold)
    }

    // MARK: - 多服务器 Profile（2026-10-16）

    var activeProfile: ServerProfile? { profiles.first(where: { $0.id == activeProfileID }) }

    static func profilePasswordKey(_ id: UUID) -> String { "makro_password_" + id.uuidString }

    /// 设置页镜像（serverURL/password）按 save() 语义写回当前激活 profile。
    /// URL 解析失败拒存并回退该 profile 的上次有效值（2026-09-20 P2：坏值
    /// 落库后启动首屏渲染 URL 强解即崩，且只能删 App 恢复）；密码空删
    /// Keychain 槽位、非空 upsert。save() 与 switchProfile（2026-10-16 P2：
    /// 切换前保存未落盘编辑，不静默丢弃）共用。
    private func persistActiveProfileEdits() {
        if let valid = httpURLString {
            serverURL = valid
        } else if let previous = activeProfile?.serverURL {
            serverURL = previous
        } else {
            serverURL = Self.defaultServerURL
        }
        if let idx = profiles.firstIndex(where: { $0.id == activeProfileID }) {
            profiles[idx].serverURL = serverURL
            if password.isEmpty {
                KeychainHelper.remove(Self.profilePasswordKey(activeProfileID))
            } else {
                KeychainHelper.set(password, for: Self.profilePasswordKey(activeProfileID))
            }
        }
    }

    /// profiles JSON + activeProfileID 落盘。返回 encode/写入是否成功
    /// （2026-10-16 P1：init 迁移收尾须确认成功才清 legacy 密码槽位）。
    @discardableResult
    private func persistProfiles() -> Bool {
        guard let data = try? JSONEncoder().encode(profiles) else { return false }
        UserDefaults.standard.set(data, forKey: Key.profiles)
        UserDefaults.standard.set(activeProfileID.uuidString, forKey: Key.activeProfileID)
        return true
    }

    /// 切换立即生效并广播 .makroReconnect——Chat/终端按新地址重建连接。
    /// 三个调用方（chip 点击/addProfile/deleteProfile）共用本收口：URL 没变
    /// 不发 .makroServerChanged，token 补传每次实际换服务器恰好一次。
    func switchProfile(to id: UUID) {
        guard let profile = profiles.first(where: { $0.id == id }), id != activeProfileID else { return }
        // 先把设置页未 Save 的编辑按 save() 语义写回旧 profile（2026-10-16
        // P2）：否则 URL/密码框改了没点 Save，点另一枚 chip 即静默丢失。
        persistActiveProfileEdits()
        let previousBase = httpBaseURL.absoluteString
        activeProfileID = id
        serverURL = profile.serverURL
        password = KeychainHelper.get(Self.profilePasswordKey(id)) ?? ""
        persistProfiles()
        NotificationCenter.default.post(name: .makroReconnect, object: nil)
        // 真的换了服务器才补传 token（2026-10-16 P1）：去重键只有 token，
        // 经 .makroServerChanged 让 AppDelegate 先失效「已上传」记忆再补传，
        // 新服务器不必等下一次后台→前台才拿到 token；同 URL 的 profile 切换
        // 不发（token 在该服务器本来就有效）。
        if httpBaseURL.absoluteString != previousBase {
            NotificationCenter.default.post(name: .makroServerChanged, object: nil)
        }
    }

    /// 新建即切换（添加服务器的自然意图就是马上用它）。返回 nil = URL 无效
    /// 或同 URL 已存在（UI 层 AddProfileSheet 先查重弹提示，此处防御兜底）。
    @discardableResult
    func addProfile(name: String, serverURL url: String, password pw: String) -> ServerProfile? {
        guard let valid = Self.normalizedHTTPURL(url) else { return nil }
        // 同 URL 拒绝重复添加（2026-10-16 P2）。
        guard !profiles.contains(where: { $0.serverURL == valid }) else { return nil }
        let display = name.trimmingCharacters(in: .whitespaces)
        // 默认名带端口（2026-10-16 P2）：同 host 双端口（如 1532/1533）的
        // chips 才分得清。URL 未写端口则裸 host。
        let fallbackName: String
        if let parsed = URL(string: valid), let host = parsed.host {
            fallbackName = host + (parsed.port.map { ":\($0)" } ?? "")
        } else {
            fallbackName = valid
        }
        let profile = ServerProfile(
            id: UUID(),
            name: display.isEmpty ? fallbackName : display,
            serverURL: valid
        )
        profiles.append(profile)
        if !pw.isEmpty { KeychainHelper.set(pw, for: Self.profilePasswordKey(profile.id)) }
        persistProfiles()
        switchProfile(to: profile.id)
        return profile
    }

    /// 删除 profile（连同其 Keychain 密码槽位）；删的是当前 profile 则回落到
    /// 第一个。最后一个被删（UI 已拦，防御路径）时重建 Default。
    func deleteProfile(_ id: UUID) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        profiles.removeAll { $0.id == id }
        KeychainHelper.remove(Self.profilePasswordKey(id))
        if let first = profiles.first {
            if activeProfileID == id {
                switchProfile(to: first.id)
            } else {
                persistProfiles()
            }
        } else {
            let fallback = ServerProfile(id: UUID(), name: "Default", serverURL: Self.defaultServerURL)
            profiles = [fallback]
            activeProfileID = fallback.id
            serverURL = fallback.serverURL
            password = ""
            persistProfiles()
        }
    }

    /// Normalized list of结束语句 parsed from `commitPhrases`. Whitespace trimmed,
    /// empties dropped. Case-folding is left to the CommitPhraseDetector so callers
    /// always see the phrases as the user typed them.
    var commitPhraseList: [String] {
        commitPhrases
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// True when the current serverURL forms a usable http(s) URL.
    var isServerURLValid: Bool { httpURLString != nil }

    /// 任意 URL 串的归一化（ws→http 族、trim、校验）——httpURLString 与
    /// addProfile 共用的单一校验点。
    static func normalizedHTTPURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let http = trimmed
            .replacingOccurrences(of: "wss://", with: "https://")
            .replacingOccurrences(of: "ws://", with: "http://")
        guard let url = URL(string: http),
              let host = url.host, !host.isEmpty,
              url.scheme == "http" || url.scheme == "https" else { return nil }
        return http
    }

    /// serverURL in http(s) form (ws(s):// normalized, whitespace trimmed),
    /// or nil when it can't form a URL — the single validation point.
    var httpURLString: String? { Self.normalizedHTTPURL(serverURL) }

    var httpBaseURL: URL {
        guard let urlString = httpURLString, let url = URL(string: urlString) else {
            // 回退默认地址：宁可连不上也不崩。
            return URL(string: Self.defaultServerURL) ?? URL(string: "http://127.0.0.1:7070")!
        }
        return url
    }

    /// ws(s) base for socket endpoints, falling back to the factory default.
    private var wsBaseString: String {
        let base = httpURLString ?? Self.defaultServerURL
        return base
            .replacingOccurrences(of: "https://", with: "wss://")
            .replacingOccurrences(of: "http://", with: "ws://")
    }

    private func wsURL(path: String, query: String? = nil) -> URL {
        var string = "\(wsBaseString)\(path)"
        if let query { string += "?\(query)" }
        if let url = URL(string: string) { return url }
        return URL(string: "ws://127.0.0.1:7070\(path)") ?? URL(string: "ws://127.0.0.1:7070")!
    }

    private var tokenQuery: String? {
        guard !password.isEmpty else { return nil }
        let encoded = password.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? password
        return "token=\(encoded)"
    }

    var chatWSURL: URL {
        wsURL(path: "/ws/chat", query: tokenQuery)
    }

    func terminalWSURL(for sessionName: String, cols: Int = 80, rows: Int = 24) -> URL {
        let encoded = sessionName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sessionName
        var query = "cols=\(cols)&rows=\(rows)"
        if let token = tokenQuery { query += "&\(token)" }
        return wsURL(path: "/ws/xterm/\(encoded)", query: query)
    }

    /// Snapshot-mode terminal WS. Server pushes periodic tmux capture-pane
    /// output as JSON frames. Used by iOS for cursor-residue-free rendering.
    func snapshotWSURL(for sessionName: String) -> URL {
        let encoded = sessionName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sessionName
        return wsURL(path: "/ws/snapshot/\(encoded)", query: tokenQuery)
    }

    /// HTTP endpoint for sending keystrokes/text to a tmux session.
    func sessionSendURL(for sessionName: String) -> URL {
        let encoded = sessionName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sessionName
        return URL(string: "\(httpBaseURL.absoluteString)/api/sessions/\(encoded)/send")
            ?? httpBaseURL.appendingPathComponent("api/sessions/send")
    }

    /// HTTP endpoint for one-shot pane capture (alternative to snapshot WS).
    func sessionCaptureURL(for sessionName: String) -> URL {
        let encoded = sessionName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sessionName
        return URL(string: "\(httpBaseURL.absoluteString)/api/sessions/\(encoded)/capture")
            ?? httpBaseURL.appendingPathComponent("api/sessions/capture")
    }

    /// Value for the `Authorization: Bearer` header.
    var bearerToken: String { "Bearer \(password)" }

    static func handleTLSChallenge(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let host = challenge.protectionSpace.host
        let expected = URL(string: shared.serverURL)?.host ?? ""
        // Apply the trust override ONLY for the configured server host or
        // loopback. Every other host gets the system default evaluation — no
        // blanket "trust any cert" anymore.
        guard host == expected || host == "127.0.0.1" || host == "localhost" else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        // TOFU pinning（2026-10-16 起 host:port 隔离）: the server uses a
        // self-signed cert, so chain validation can't distinguish it from an
        // attacker's cert. Instead we pin the SHA-256 of the leaf cert's public
        // key on first connect and require a match thereafter — a MITM
        // presenting a different key is rejected. Pin 按 host:port 存：同一
        // host 不同端口（如 1532/1533 同 IP 双服务）各有各的信任，互不干扰。
        // (The very first connection is trusted; if you rotate the server
        // certificate, call resetServerTrustPin(forEndpoint:).)
        let endpoint = "\(host):\(challenge.protectionSpace.port)"
        if let pin = pinnedPubKeyHex(forEndpoint: endpoint) {
            if let leaf = leafPubKeyHex(serverTrust), leaf == pin {
                completionHandler(.useCredential, URLCredential(trust: serverTrust))
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
            return
        }
        if let leaf = leafPubKeyHex(serverTrust) {
            setPinnedPubKeyHex(leaf, forEndpoint: endpoint)
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
            return
        }
        completionHandler(.cancelAuthenticationChallenge, nil)
    }

    // MARK: - TLS pinning (TOFU)

    private static let pinDefaultsKey = "makro_tls_pin_"

    /// SHA-256 (hex) of the leaf certificate's public key, or nil if it can't
    /// be extracted.
    private static func leafPubKeyHex(_ trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first,
              let key = SecCertificateCopyKey(leaf),
              let keyData = SecKeyCopyExternalRepresentation(key, nil) as Data? else { return nil }
        return SHA256.hash(data: keyData).map { String(format: "%02x", $0) }.joined()
    }

    private static func pinnedPubKeyHex(forEndpoint endpoint: String) -> String? {
        UserDefaults.standard.string(forKey: pinDefaultsKey + endpoint)
    }

    private static func setPinnedPubKeyHex(_ hex: String, forEndpoint endpoint: String) {
        UserDefaults.standard.set(hex, forKey: pinDefaultsKey + endpoint)
    }

    /// profiles 里每个 host 实际使用的端口（钉扎迁移用；URL 未写端口则按
    /// scheme 默认 443/80）。
    private static func profilePorts(_ profiles: [ServerProfile]) -> [String: String] {
        var byHost: [String: String] = [:]
        for p in profiles {
            guard let normalized = Self.normalizedHTTPURL(p.serverURL),
                  let url = URL(string: normalized),
                  let host = url.host else { continue }
            let port = url.port.map(String.init) ?? (url.scheme == "https" ? "443" : "80")
            if byHost[host] == nil { byHost[host] = port }
        }
        return byHost
    }

    /// 一次性迁移：host-only 钉扎 → host:port。端口取 profile 里该 host 的
    /// 实际端口；无 profile 对应的旧钉直接弃（下次连接重新 TOFU，只影响已
    /// 不再使用的 host）。迁移后 key 带 ":"，天然幂等。
    private static func migrateLegacyPins(portByHost: [String: String]) {
        let defaults = UserDefaults.standard
        let legacy = defaults.dictionaryRepresentation().keys.filter {
            $0.hasPrefix(pinDefaultsKey) && !$0.dropFirst(pinDefaultsKey.count).contains(":")
        }
        for key in legacy {
            let host = String(key.dropFirst(pinDefaultsKey.count))
            if let port = portByHost[host], let pin = defaults.string(forKey: key) {
                defaults.set(pin, forKey: pinDefaultsKey + "\(host):\(port)")
            }
            defaults.removeObject(forKey: key)
        }
    }

    /// Clear the pinned server cert key. Call after rotating the server's
    /// self-signed certificate, otherwise TOFU will reject the new key as a
    /// presumed MITM. Pass nil to clear pins for all endpoints.
    static func resetServerTrustPin(forEndpoint endpoint: String? = nil) {
        if let endpoint = endpoint {
            UserDefaults.standard.removeObject(forKey: pinDefaultsKey + endpoint)
        } else {
            for key in UserDefaults.standard.dictionaryRepresentation().keys
            where key.hasPrefix(pinDefaultsKey) {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }
}
