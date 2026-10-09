// 开单对话 ViewModel（09-29 从 Makro 存档仓 4a4a625^ 捞回复用，接线适配
// juli-service 的 chat intake 端点）：
//   · REST 动作面 → POST /api/chat/intake/*（turn/confirm/deny）；
//   · 事件流不变——/ws/chat 镜像（assistant/thinking/done/plan/phase/
//     dispatched/system），传输层零改动；
//   · 单一开单纪律（原 闲聊/落实/查询 三模式裁撤）：clarify loop →
//     计划卡（title/summary/brief）→ 用户确认 → 服务端 startTask 正门。
// 语音机械（AzureSpeechManager/VAD/提交短语/配额）原样复用。
//
// 0929 用户双反馈修复：
//   · 断线：切 tab 即拆 socket（onDisappear→disconnect）+ 回前台无人重连 +
//     normalClosure 关码不重连 → 改为「仅主动关闭不重连」+ 前后台事件接线 +
//     陈旧 URLSession invalidate；socket 生命周期升到 app 级。
//   · 历史丢失：transcript 原是纯内存 UI 态（旧注释「重开丢掉可接受」）→
//     翻案做本地持久化（Documents/chat-transcript.json，写穿透，上限 500 条）。

import Foundation
import Combine
import UIKit

extension ChatMessage: Codable {
    // 追溯性 Codable 手写在 ChatViewModel（Models.swift 有并行改动不动它）；
    // Swift 跨文件 extension 不给自动合成，init(from:)/encode(to:) 都要明写。
    private enum CodingKeys: String, CodingKey { case id, role, text, timestamp, attachments }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(UUID.self, forKey: .id),
            role: .init(rawValue: try c.decode(String.self, forKey: .role)) ?? .system,
            text: try c.decode(String.self, forKey: .text),
            timestamp: try c.decode(Date.self, forKey: .timestamp),
            // 附件元数据（wf_3310501a9fe4）：旧档缺键 decodeIfPresent 容错。
            attachments: try c.decodeIfPresent([ChatAttachment].self, forKey: .attachments)
        )
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(role.rawValue, forKey: .role)
        try c.encode(text, forKey: .text)
        try c.encode(timestamp, forKey: .timestamp)
        try c.encodeIfPresent(attachments, forKey: .attachments)
    }
}

@MainActor
final class ChatViewModel: NSObject, ObservableObject {

    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var isStreaming = false
    @Published private(set) var thinkingText: String?

    // 附件托盘（wf_3310501a9fe4）：待发附件本地态——data 供托盘缩略与
    // 上传；发送时逐件上传换服务端 ChatAttachment 元数据。
    @Published var pendingAttachments: [PendingAttachment] = []

    struct PendingAttachment: Identifiable {
        let id = UUID()
        let data: Data
        let name: String
        let mime: String
        static let maxBytes = 10 * 1024 * 1024
        static let maxCount = 5
    }

    /// 托盘加入（入口统一走这里）：限大小/件数，超限就地报系统气泡。
    func addPendingAttachment(data: Data, name: String, mime: String) {
        if data.count > PendingAttachment.maxBytes {
            appendMessage(.system, "[Attachment ‘\(name)’ is over 10MB — not added]")
            return
        }
        guard pendingAttachments.count < PendingAttachment.maxCount else {
            appendMessage(.system, "[At most \(PendingAttachment.maxCount) attachments per message]")
            return
        }
        pendingAttachments.append(PendingAttachment(data: data, name: name, mime: mime))
    }

    // Voice conversation state.
    // expectSpokenReply is a one-shot flag: set true only when the user's
    // message was produced by speech recognition, and cleared right after the
    // reply is spoken (or interrupted). This keeps typed messages silent.
    @Published private(set) var partialTranscript: String?
    @Published private(set) var isListening = false
    @Published private(set) var isSpeaking = false
    private var expectSpokenReply = false

    // Call mode (phone-call style): continuous listening + auto TTS loop.
    @Published var isInCall = false
    @Published var isMuted = false
    /// User-paused (hold): mic + TTS fully stopped, but the call context
    /// (pendingPlan, callPhase, Now Playing card) survives, so resume
    /// continues the same conversation instead of a fresh start.
    @Published var isCallPaused = false

    // Intake phase (discuss → proposed). pendingPlan is non-nil while a
    // brief is awaiting the user's confirmation; CallView shows the
    // 开单/取消 buttons while set.
    @Published private(set) var pendingPlan: PendingPlan?
    /// 计划卡「本单免批」勾选（2026-10-07）：confirm 时随 body 进 meta——
    /// 人的 control 面，LLM 计划块里写什么都不认。
    @Published var pendingAutoApprove = false
    @Published private(set) var callPhase: String = "discuss"

    private var cancellables: Set<AnyCancellable> = []

    private var task: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var pingTimer: Timer?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectDelay: TimeInterval = 1
    private var streamingWatchdog: Task<Void, Never>?
    private var pendingTurns = 0
    /// 仅在用户/生命周期主动关闭（disconnect）时置位——其余一切关闭码
    /// （含服务器正常关 1000/1001）都视为意外，照常自动重连。
    private var userClosed = false
    /// 后台/挂起期（0930：切 app 后仍见「连接中断」的根因）——挂起致断是
    /// 预期行为不播报；且回合可能仍在服务端跑，回前台重连后帧可续上，
    /// 收口交给回前台后的真实事件/看门狗，不在断线瞬间杀回合。
    private var appInBackground = false
    private let config: Config
    private let api: APIClient
    private let speech: AzureSpeechManager

    init(config: Config = .shared, api: APIClient = .shared) {
        self.config = config
        self.api = api
        self.speech = AzureSpeechManager(config: config)
        super.init()
        wireSpeech()
        restoreTranscript()
        // socket 生命周期升到 app 级（切 tab 不再拆）：
        // 真后台 → 主动干净关闭（反正 iOS 会掐）；回前台 → 立即接回。
        // makroReconnect 由 MakroApp 的 scenePhase=.active 派发（原来只有
        // Terminal 在听，聊天回前台一直没人接）。
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                self.appInBackground = true
                self.disconnect()
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .makroReconnect)
            .sink { [weak self] _ in
                guard let self else { return }
                self.appInBackground = false
                self.userClosed = false
                if self.connectionState == .connected { self.reconnectIfNeeded() }
                else if self.connectionState == .disconnected { self.connect() }
            }
            .store(in: &cancellables)
        // Model-level hang-up: `EndCallIntent` posts `.makroEndCall` so the
        // call stops (STT/TTS/audio torn down) even when `CallView` isn't
        // presenting or its `.onReceive` is suspended.
        NotificationCenter.default.publisher(for: .makroEndCall)
            .sink { [weak self] _ in
                Task { @MainActor in self?.endCall() }
            }
            .store(in: &cancellables)
    }

    private func wireSpeech() {
        // STT result → send as a normal chat message (reuses existing path)
        // and arm the one-shot flag so the reply gets read aloud.
        speech.onRecognized = { [weak self] text in
            guard let self else { return }
            self.partialTranscript = nil
            self.isListening = false
            self.expectSpokenReply = true
            // Voice turns tag the message so the server uses a spoken-friendly
            // prompt (conversational, no tables/code). isInCall gates this so
            // a one-shot voice send outside a call stays unstyled.
            self.send(text: text, voice: self.isInCall)
        }
        // First partial of a new utterance → if the assistant is still
        // speaking, stop it. This is the interruption path: the user talks
        // over the TTS and we cut it off. .voiceChat echo cancellation keeps
        // the assistant's own audio from falsely triggering this.
        speech.onPartialSpeech = { [weak self] in
            guard let self else { return }
            if self.isSpeaking {
                self.stopSpeaking()
            }
        }
        // Surface partial recognition so the UI can show "正在听…".
        speech.$listenState.sink { [weak self] state in
            guard let self else { return }
            switch state {
            case .listening(let partial):
                self.partialTranscript = partial
                self.isListening = true
            case .error:
                self.partialTranscript = nil
                self.isListening = false
            case .idle:
                // Cleared by onRecognized; nothing to do here.
                break
            }
        }.store(in: &cancellables)
        // Speaking state → drives the waveform animation + button affordance.
        speech.$speakState.sink { [weak self] state in
            guard let self else { return }
            self.isSpeaking = (state == .speaking)
            if state != .speaking, !self.isInCall {
                self.expectSpokenReply = false
            }
        }.store(in: &cancellables)
        // Quota wall → tell the user and stop active listening/speaking.
        speech.onQuotaExhausted = { [weak self] msg in
            guard let self else { return }
            self.appendMessage(.system, msg)
            self.expectSpokenReply = false
            self.isInCall = false
            self.isCallPaused = false
            self.stopListening()
            self.stopSpeaking()
        }
        // Commit-mode nudge when the user has spoken a long time without a
        // commit phrase. Silence auto-send is on for the intake conversation,
        // so the hint teaches the pause-to-send behavior.
        speech.onMaxDurationHint = { [weak self] in
            _ = self
            NowPlayingManager.shared.updatePhase("Long utterance — pause to send")
        }
    }

    func connect() {
        userClosed = false
        guard connectionState == .disconnected else { return }
        connectionState = .connecting
        openConnection()
    }

    func disconnect() {
        userClosed = true
        reconnectTask?.cancel()
        stopPing()
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        urlSession?.invalidateAndCancel() // 旧实现只 cancel 任务不毁会话——每次切 tab 泄一个 URLSession
        urlSession = nil
        connectionState = .disconnected
    }

    deinit {
        // Belt-and-suspenders cleanup. onDisappear calls disconnect(), but a
        // stuck URLSession delegate or an in-flight reconnect sleep could
        // otherwise extend this VM's lifetime. Stored-property access only —
        // safe in a nonisolated deinit.
        streamingWatchdog?.cancel()
        reconnectTask?.cancel()
        pingTimer?.invalidate()
        task?.cancel(with: .goingAway, reason: nil)
    }

    func reconnectIfNeeded() {
        guard connectionState == .connected else { return }
        stopPing()
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        connectionState = .disconnected
        connect()
    }

    /// 重连恢复：拉 intake 状态把暂存中的计划卡找回来（服务端不回放对话，
    /// transcript 由本地持久化承接——见 restoreTranscript）。
    func loadHistory() async {
        guard let state = try? await api.fetchIntakeState() else { return }
        pendingPlan = state.plan
        callPhase = state.phase
    }

    /// 挂起期补帧（wf_e2f2bfba8865 P0，2026-10-05）：/ws/chat 不回放历史，
    /// 挂起期错过的 assistant/done 帧永久丢失（看门狗 110s 报「响应超时」的
    /// 根因）。每次 WS 接回后拉 /api/chat/history（chathub 环形 200 条），
    /// 与本地做尾部回合对齐——幂等：内容一致时零动作。
    /// 对齐规则：取 history 尾部最后一个 assistant 连续块（至末尾或 done）为
    /// 「最新回合全文 T」——本地最后 assistant == T（已同步）；是 T 的前缀
    /// （流式中途断）→ 替换补齐；本地尾部是 user（整回合丢失）→ append。
    /// history 带 done 且 isStreaming → 服务端已跑完，本地收口（看门狗随之解除）。
    func resyncFromHistory() async {
        guard let frames = try? await api.fetchChatHistory(), !frames.isEmpty else { return }
        // 尾部 assistant 块（跳过 thinking/tool 等中间帧；倒扫到非 assistant 止）
        var tail: [String] = []
        var hasDone = false
        for f in frames.reversed() {
            if f.type == "assistant" { tail.insert(f.data, at: 0); continue }
            if f.type == "done" {
                // R1 P2-7 / R3 重修：done 分支放行前先查 tail——
                //   · tail 非空 = 流中回合（已出 text 尚无 done），撞到的 done
                //     属上一回合，就地停（R2 版无条件放行会跨回合合并旧全文）；
                //   · tail 空且未见 done = 最新回合确无正文，放行继续收集
                //     （正常收口回拉的回合结束标记）；
                //   · tail 空但 hasDone 已置 = 连续空回合，停，不跨界采旧回合。
                if !tail.isEmpty { break }
                if !hasDone { hasDone = true; continue }
                break
            }
            break // 其他帧=回合边界
        }
        guard !tail.isEmpty || hasDone else { return }
        let full = tail.joined()
        if !full.isEmpty {
            if let lastIdx = messages.lastIndex(where: { $0.role == .assistant }) {
                // 只动「最后一回合」的气泡：它必须晚于最后一条 user（防改历史回合）
                let lastUser = messages.lastIndex(where: { $0.role == .user }) ?? -1
                if lastIdx > lastUser {
                    let local = messages[lastIdx].text
                    if local == full { /* 已同步 */ }
                    else if full.hasPrefix(local) || local.isEmpty {
                        messages[lastIdx].text = full // 前缀 → 补齐断在半路的流
                    } else if lastIdx == messages.count - 1, hasDone, !local.isEmpty {
                        messages[lastIdx].text = full // 保守替换：本地残留不完整片段
                    } else {
                        appendMessage(.assistant, full) // 本地无对应（对不上）→ 追加
                    }
                } else {
                    appendMessage(.assistant, full)
                }
            } else {
                appendMessage(.assistant, full) // 整回合丢失（本地尾部是 user）
            }
        }
        if hasDone && isStreaming {
            thinkingText = nil
            markTurnEnd()
            persistTranscript()
        }
    }

    // MARK: - Transcript 持久化（0929：重开 APP 历史丢掉 → 本地写穿透）

    /// 上限 500 条：够回看上下文，JSON 全量读写不构成开销。
    private static let transcriptLimit = 500
    private static var transcriptFileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("chat-transcript.json")
    }

    /// 统一入口：所有消息落账都走这里（append + 持久化）。流式 chunk 的原位
    /// 合并不写盘，回合收口（done/错误/中断）时统一落一次。
    private func appendMessage(_ role: ChatMessage.Role, _ text: String) {
        messages.append(ChatMessage(role: role, text: text))
        persistTranscript()
    }

    private func persistTranscript() {
        let store = messages.suffix(Self.transcriptLimit).map {
            ChatMessage(id: $0.id, role: $0.role, text: $0.text, timestamp: $0.timestamp, attachments: $0.attachments)
        }
        let url = Self.transcriptFileURL
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(store) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private func restoreTranscript() {
        guard let data = try? Data(contentsOf: Self.transcriptFileURL),
              let store = try? JSONDecoder().decode([ChatMessage].self, from: data) else { return }
        messages = Array(store.suffix(Self.transcriptLimit))
    }

    /// 清空对话（新开一单）：内存与磁盘一起清。
    func clearTranscript() {
        messages = []
        try? FileManager.default.removeItem(at: Self.transcriptFileURL)
    }

    /// Send a chat message. `voice` flags the message as coming from a voice
    /// call so the server uses a spoken-friendly prompt (conversational, no
    /// tables/code). STT turns set voice = isInCall; typed messages omit it.
    /// 附件（wf_3310501a9fe4）：pendingAttachments 随消息逐件上传后携带引用；
    /// 纯附件消息正文占位「[附件 N 件]」（服务端要求 input 非空）。
    func send(text: String, voice: Bool = false) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let outgoing = pendingAttachments
        guard !trimmed.isEmpty || !outgoing.isEmpty else { return }
        pendingAttachments = []
        let displayText = trimmed.isEmpty ? "[\(outgoing.count) attachments]" : trimmed
        // 无附件：保持乐观先上屏（原行为）；有附件：上传成功才上屏（气泡
        // 需携带服务端回填的附件元数据），上传期间靠 streaming 指示器占位。
        if outgoing.isEmpty {
            messages.append(ChatMessage(role: .user, text: displayText))
            persistTranscript()
        }
        // Concurrent turns (e.g. voice onRecognized firing while a reply is
        // still streaming) share the indicator via pendingTurns — each send
        // bumps the count, each done/error decrements; the indicator only
        // clears when the last one finishes. No reentry truncation, so a
        // legitimate in-flight reply is never cut short.
        pendingTurns += 1
        isStreaming = true
        startStreamingWatchdog()
        Task {
            do {
                var uploaded: [ChatAttachment] = []
                for p in outgoing {
                    uploaded.append(try await api.uploadChatAttachment(data: p.data, name: p.name, mime: p.mime))
                }
                // R1 P2-5：上传完成后重置看门狗——5×10MB 慢网上传的耗时不再
                // 挤占回合的 110s（上传期仍由发起时那枚旧计时兜底，真挂死照
                // 样超时收口）；无附件发送不重置。
                if !outgoing.isEmpty { startStreamingWatchdog() }
                if !uploaded.isEmpty {
                    messages.append(ChatMessage(role: .user, text: displayText, attachments: uploaded))
                    persistTranscript()
                }
                try await api.sendIntakeTurn(text: displayText, voice: voice, attachments: uploaded)
            } catch {
                appendMessage(.system, "[error: \(error.localizedDescription)]")
                markTurnEnd()
            }
        }
    }

    /// One in-flight turn finished normally (done/error/HTTP-fail). Decrement;
    /// only drop the indicator when the last concurrent turn finishes — so a
    /// fast voice follow-up doesn't extinguish a still-streaming reply.
    private func markTurnEnd() {
        pendingTurns = max(0, pendingTurns - 1)
        guard pendingTurns == 0 else { return }
        streamingWatchdog?.cancel()
        streamingWatchdog = nil
        isStreaming = false
    }

    /// Force-clear ALL in-flight turns (watchdog timeout / WS drop / cancel).
    private func endStreaming() {
        streamingWatchdog?.cancel()
        streamingWatchdog = nil
        pendingTurns = 0
        isStreaming = false
    }

    /// Failsafe: if no `done`/`error` arrives within 110s (WS dropped the
    /// broadcast, or a server path skipped it), force the turn closed so the
    /// indicator never sticks. 与 turn 请求的 120s 超时对齐（intake 多轮
    /// LLM 回合 30s+ 实测，60s 会误杀长回合）。
    private func startStreamingWatchdog() {
        streamingWatchdog?.cancel()
        streamingWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 110 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.isStreaming else { return }
                self.appendMessage(.system, "[timed out — closed automatically]")
                self.endStreaming()
            }
        }
    }

    func cancel() {
        // User-initiated stop: don't wait for the server's done (that may be
        // exactly what's stuck). Reset locally right away. Intake turn 是同
        // 步请求作用域——服务端无可取消的后台生成，本地收口即完整。
        endStreaming()
    }

    /// Confirm the staged intake plan → server runs startTask（开单正门）.
    /// 失败显性化：卡片保留可重试（服务端 staged 未消费），绝不静默吞错——
    /// 开单是本 feat 的核心动词。
    func confirmPlan() {
        guard pendingPlan != nil else { return }
        Task {
            do {
                try await api.confirmIntakePlan(autoApprove: pendingAutoApprove)
                pendingPlan = nil
            } catch {
                appendMessage(.system, "[Job creation failed: \(error.localizedDescription)] — the plan card is kept, you can retry")
            }
        }
    }

    /// Deny the staged plan → server returns to discussion.
    func denyPlan() {
        pendingPlan = nil
        Task {
            do {
                try await api.denyIntakePlan()
            } catch {
                // 取消失败不阻塞继续对话（下轮输入服务端也会丢弃暂存）。
                appendMessage(.system, "[Cancel failed: \(error.localizedDescription)]")
            }
        }
    }

    // MARK: - Voice conversation

    /// Toggle mic listening. Tap to start, tap again (or trailing silence) to stop.
    func toggleListening() {
        if isListening {
            stopListening()
        } else {
            // Stop any ongoing playback before listening.
            stopSpeaking()
            speech.startListening()
        }
    }

    func stopListening() {
        speech.stopListening()
        isListening = false
        partialTranscript = nil
    }

    func stopSpeaking() {
        speech.stopSpeaking()
        isSpeaking = false
        // Stopping playback also cancels any pending spoken reply (outside
        // of an active call; in a call, keep the loop armed).
        if !isInCall {
            expectSpokenReply = false
        }
    }

    // MARK: - Call mode (phone-call style)

    /// Start a continuous voice call: the mic stays open, every recognized
    /// utterance is sent, and every reply is read aloud (with the mic briefly
    /// suspended during playback to avoid echo). 开单对话无服务端通话态
    /// （intake loop 无派发类工具可拦），起止纯本地。
    func startCall() {
        guard speech.isConfigured else {
            appendMessage(.system, "Fill in the Azure Speech key and region in Settings first")
            return
        }
        isInCall = true
        isMuted = false
        pendingPlan = nil
        callPhase = "discuss"
        // Arm spoken replies for the whole call; the done→TTS path checks isInCall.
        stopSpeaking()
        // Defensive: a stale suspendAutoRestart from an earlier call (endCall
        // normally clears it) must not mute the fresh recognizer.
        speech.suspendAutoRestart = false
        // 开单对话 = 说完了停顿即发送（静默自动成回；说提交短语仍即时成回）。
        speech.startListening(continuous: true, commit: config.vadEnabled, silenceAuto: true)
        // Wire lock-screen controls.
        NowPlayingManager.shared.onHangUp = { [weak self] in
            Task { @MainActor in self?.endCall() }
        }
        NowPlayingManager.shared.onToggleMute = { [weak self] in
            Task { @MainActor in self?.toggleMute() }
        }
        NowPlayingManager.shared.startCall()
    }

    /// End the call: stop the mic and any playback.
    func endCall() {
        isInCall = false
        isMuted = false
        isCallPaused = false
        expectSpokenReply = false
        pendingPlan = nil
        callPhase = "discuss"
        NowPlayingManager.shared.endCall()
        // Cancel any pending post-Siri auto-resume so ending a call (button or
        // Siri "hang up") isn't immediately undone when the audio interruption
        // from Siri itself ends.
        speech.suppressAudioResume()
        speech.suspendAutoRestart = false
        stopListening()
        stopSpeaking()
    }

    /// Pause (hold) the call without tearing down its context — for when a
    /// human conversation interrupts. Fully stops the mic + TTS (so nothing is
    /// transcribed or billed while paused) but keeps pendingPlan, callPhase,
    /// and the Now Playing card, unlike endCall(). Reply messages still arrive
    /// and land in the transcript; they are just not spoken until resume.
    func pauseCall() {
        guard isInCall, !isCallPaused else { return }
        isCallPaused = true
        // Interruptions / route changes while paused must not auto-restart
        // the recognizer (that would resurrect the mic against the user's
        // intent). Cleared again in resumeCall().
        speech.suspendAutoRestart = true
        stopListening()
        stopSpeaking()
        NowPlayingManager.shared.updatePhase("Paused")
    }

    /// Resume a paused call: rebuild the recognizer (~1-2s) and continue the
    /// same conversation — context was never dropped, so nothing to restore.
    func resumeCall() {
        guard isInCall, !isCallPaused else { return }
        isCallPaused = false
        speech.suspendAutoRestart = false
        stopSpeaking()
        speech.startListening(continuous: true, commit: config.vadEnabled, silenceAuto: true)
        // startListening clears the suspended flag; re-apply mute or the mic
        // would go live while the UI / lock screen still say 已静音.
        if isMuted { speech.suspendListening() }
        NowPlayingManager.shared.updatePhase(isMuted ? "Muted" : "Listening…")
    }

    /// Mute/unmute the mic during a call (mapped to the lock-screen play/pause button).
    func toggleMute() {
        guard isInCall, !isCallPaused else { return }
        isMuted.toggle()
        if isMuted {
            speech.suspendListening()
            NowPlayingManager.shared.updatePhase("Muted")
        } else {
            speech.resumeListening()
            NowPlayingManager.shared.updatePhase("Listening…")
        }
    }

    // MARK: - WebSocket（/ws/chat 事件流，传输层与存档版一致）

    private func openConnection() {
        let url = config.chatWSURL
        // 会话级换新：旧实现反复 openConnection 只换 task 不毁 session，
        // delegate 泄漏 + 陈旧回调（断线重连越多漏得越快）。
        urlSession?.invalidateAndCancel()
        urlSession = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let wsTask = urlSession!.webSocketTask(with: url)
        self.task = wsTask
        wsTask.resume()
        scheduleReceive()
        startPing()
    }

    private func scheduleReceive() {
        task?.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch result {
                case .success(let message):
                    self.handleMessage(message)
                    self.scheduleReceive()
                case .failure:
                    self.handleDisconnect()
                }
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        guard case .string(let text) = message,
              let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        switch type {
        case "ping":
            return
        case "thinking":
            let chunk = json["data"] as? String ?? ""
            if thinkingText == nil { thinkingText = "" }
            thinkingText! += chunk
        case "assistant":
            thinkingText = nil
            // 收敛回合的 text 事件携带 ```intake-plan 块——气泡里剥掉（计划
            // 经 plan 事件走卡片），原始 JSON 不进聊天界面（审查 P1-1）。
            let chunk = stripPlanBlocks(json["data"] as? String ?? "")
            if !chunk.isEmpty {
                if !messages.isEmpty && messages.last?.role == .assistant && isStreaming {
                    messages[messages.count - 1].text += chunk
                } else {
                    appendMessage(.assistant, chunk)
                }
            }
        case "done":
            thinkingText = nil
            markTurnEnd()
            persistTranscript() // 流式 chunk 原位合并不写盘，回合收口统一落账
            // Read aloud when this turn was triggered by voice, or whenever we
            // are in an active call (every reply is spoken in call mode).
            if (expectSpokenReply || isInCall), !isCallPaused,
               let last = messages.last,
               last.role == .assistant {
                // Strip the ```intake-plan block so TTS reads only the
                // conversational summary, not the raw JSON execution target.
                let spoken = stripPlanBlocks(last.text)
                if !spoken.isEmpty { speech.speak(spoken) }
            }
        case "error":
            let msg = json["data"] as? String ?? "Unknown error"
            appendMessage(.system, "[error: \(msg)]")
            // 只有真回合在途才收口——confirm 失败的 chat:error 不在回合内，
            // 误减 pendingTurns 会提前熄灭指示器（审查 P2）。
            if pendingTurns > 0 { markTurnEnd() }
        case "system":
            let msg = json["data"] as? String ?? ""
            appendMessage(.system, msg)
        case "plan":
            // Assistant proposed an intake plan → surface the confirm
            // affordance. The prose summary is already in the last assistant
            // message; this carries the structured brief {title,summary,brief}.
            if let dataStr = json["data"] as? String,
               let d = dataStr.data(using: .utf8) {
                pendingPlan = try? JSONDecoder().decode(PendingPlan.self, from: d)
            }
            pendingAutoApprove = false
                case "phase":
            let p = json["data"] as? String ?? "discuss"
            callPhase = p
            // Leaving "proposed" (confirm / deny / dispatch) clears the card.
            if p != "proposed" { pendingPlan = nil }
        case "dispatched":
            pendingPlan = nil
        default:
            break
        }
    }

    private func handleDisconnect() {
        guard connectionState != .disconnected else { return }
        stopPing()
        task = nil
        connectionState = .disconnected
        // 后台/挂起致断 = 预期行为（didEnterBackground 已主动关过；挂起期
        // OS 掐线的 failure 回调在回前台后才被处理）——沉默，不播「连接中
        // 断」，也不杀在途回合：服务端可能还在跑，回前台重连后 assistant/
        // done 帧照常续上（真丢了由看门狗收口）。
        let suspendedDrop = appInBackground || UIApplication.shared.applicationState != .active
        if isStreaming && !suspendedDrop {
            // WS dropped mid-turn: the backend's `done` broadcast has no
            // buffer and no replay, so it's already lost. Close the turn now
            // rather than leaving the indicator pinned until the watchdog.
            appendMessage(.system, "[connection lost — reconnecting]")
            endStreaming()
        }
        if suspendedDrop {
            // 挂起期不排退避重连（定时器不跑=纯空转）——回前台由
            // makroReconnect 立即接回。
            return
        }
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        // 主动关闭（后台/退出）与挂起期不重连——后者回前台由 makroReconnect 接回
        guard !userClosed, !appInBackground else { return }
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, 60)
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            // 防双开：前一个重连已把状态推离 disconnected 时本次让位
            guard self.connectionState == .disconnected, !self.userClosed else { return }
            self.connectionState = .connecting
            self.openConnection()
        }
    }

    private func startPing() {
        stopPing()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.task?.sendPing { _ in } }
        }
    }

    private func stopPing() {
        pingTimer?.invalidate()
        pingTimer = nil
    }
}

extension ChatViewModel: URLSessionWebSocketDelegate {
    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        Task { @MainActor in
            self.connectionState = .connected
            self.reconnectDelay = 1
            // 接回后立即拉一次 intake 状态：断线窗口里 phase/plan 可能已变
            //（确认/取消在别的面发生），别拿旧卡片误导用户。
            await self.loadHistory()
            // 补帧（wf_e2f2bfba8865 P0）：挂起期错过的 assistant/done 帧
            // 从 200 条环形历史对齐补回——「切出 APP 回来还能看到完整回复」。
            await self.resyncFromHistory()
        }
    }

    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        Task { @MainActor in
            self.stopPing()
            self.task = nil
            self.connectionState = .disconnected
            // 旧逻辑只对非 normalClosure 重连——服务器/中间层的正常关码
            // （1000/1001）会让聊天永久躺断直到重进页面。现在只有用户主动
            // 关闭（userClosed）不重连，其余一律按意外处理。
            if !self.userClosed { self.scheduleReconnect() }
        }
    }

    nonisolated func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        Config.handleTLSChallenge(challenge, completionHandler: completionHandler)
    }
}

// stripPlanBlocks removes ```intake-plan fenced blocks from assistant text so
// TTS and the call transcript surface only the conversational summary, not the
// raw JSON execution target (which is delivered separately via the `plan` WS
// event).
private func stripPlanBlocks(_ text: String) -> String {
    guard let re = try? NSRegularExpression(pattern: "```(?:intake-)?plan[\\s\\S]*?```\\s*", options: []) else {
        return text
    }
    let range = NSRange(text.startIndex..., in: text)
    return re.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
}
