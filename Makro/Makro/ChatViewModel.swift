// Intake chat ViewModel (recovered from the Makro archive repo at 4a4a625^ on
// 09-29 and rewired to juli-service's chat intake endpoint):
//   · REST action surface → POST /api/chat/intake/* (turn/confirm/deny);
//   · event stream unchanged — /ws/chat mirror (assistant/thinking/done/plan/
//     phase/dispatched/system), zero transport-layer changes;
//   · single intake discipline (the old casual/follow-through/query tri-mode
//     was cut): clarify loop → plan card (title/summary/brief) → user
//     confirmation → the server's startTask front door.
// The voice machinery (AzureSpeechManager/VAD/submit phrase/quota) is reused as-is.
//
// 0929 fixes for two user complaints:
//   · disconnects: switching tabs tore down the socket (onDisappear→disconnect)
//     + nothing reconnected on foreground return + normalClosure close codes
//     did not reconnect → changed to "only a deliberate close skips reconnect"
//     + foreground/background event wiring + stale URLSession invalidation;
//     socket lifetime promoted to app level.
//   · history loss: the transcript used to be pure in-memory UI state (old
//     note: "losing it on reopen is acceptable") → reversed: local persistence
//     added (Documents/chat-transcript.json, write-through, capped at 500).

import Foundation
import Combine
import UIKit

extension ChatMessage: Codable {
    // Retrospective Codable hand-written in ChatViewModel (Models.swift has
    // parallel changes — leave it alone); Swift does not auto-synthesize across
    // file extensions, so init(from:)/encode(to:) must be written out.
    private enum CodingKeys: String, CodingKey { case id, role, text, timestamp, attachments }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(UUID.self, forKey: .id),
            role: .init(rawValue: try c.decode(String.self, forKey: .role)) ?? .system,
            text: try c.decode(String.self, forKey: .text),
            timestamp: try c.decode(Date.self, forKey: .timestamp),
            // Attachment metadata (wf_3310501a9fe4): decodeIfPresent tolerance for keys missing in old records.
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

    // Attachment tray (wf_3310501a9fe4): local state of attachments waiting to
    // send — data feeds tray thumbnails and upload; on send each item is
    // uploaded and swapped for the server's ChatAttachment metadata.
    @Published var pendingAttachments: [PendingAttachment] = []

    struct PendingAttachment: Identifiable {
        let id = UUID()
        let data: Data
        let name: String
        let mime: String
        static let maxBytes = 10 * 1024 * 1024
        static let maxCount = 5
    }

    /// Add to the tray (all entry points go through here): size/count limits enforced; over-limit reported in place via a system bubble.
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
    // intake/cancel buttons while set.
    @Published private(set) var pendingPlan: PendingPlan?
    /// Plan-card "auto-approve this job" checkbox (2026-10-07): travels into
    /// meta with confirm — a human control surface; whatever the LLM writes in
    /// its plan block is not honored.
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
    /// Set only when the user/lifecycle deliberately closes (disconnect) —
    /// every other close code (including the server's normal 1000/1001) is
    /// treated as unexpected and auto-reconnects as usual.
    private var userClosed = false
    /// During background/suspension (0930: the root cause of still seeing
    /// "connection lost" after switching apps) — a suspension-induced
    /// disconnect is expected behavior and is not announced; the turn may also
    /// still be running server-side and frames can resume after the foreground
    /// reconnect. Closing out is left to real events / the watchdog after
    /// returning to foreground — the turn is not killed at the moment of
    /// disconnect.
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
        // Socket lifetime promoted to app level (tab switches no longer tear
        // it down): true background → deliberate clean close (iOS will kill it
        // anyway); foreground return → reconnect immediately. makroReconnect is
        // dispatched by MakroApp's scenePhase=.active (previously only Terminal
        // listened; chat never got reconnected on foreground return).
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
        // Surface partial recognition so the UI can show "listening…".
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
        urlSession?.invalidateAndCancel() // the old implementation only cancelled tasks without destroying the session — leaked one URLSession per tab switch
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

    /// Reconnect recovery: pull the intake state to recover a staged plan card
    /// (the server does not replay the conversation; the transcript is carried
    /// by local persistence — see restoreTranscript).
    func loadHistory() async {
        guard let state = try? await api.fetchIntakeState() else { return }
        pendingPlan = state.plan
        callPhase = state.phase
    }

    /// Suspension-gap backfill (wf_e2f2bfba8865 P0, 2026-10-05): /ws/chat does
    /// not replay history, so assistant/done frames missed while suspended are
    /// lost forever (the root cause of the watchdog's 110s "response timeout").
    /// After every WS reconnect, pull /api/chat/history (the chathub 200-entry
    /// ring) and align the tail turn against local state — idempotent: zero
    /// action when content already matches.
    /// Alignment rules: take the trailing assistant run (to the end or a done)
    /// from the history tail as "the full text T of the latest turn" — local
    /// last assistant == T (already synced); it is a prefix of T (stream cut
    /// mid-flight) → replace and complete; local tail is user (the whole turn
    /// was lost) → append.
    /// If history carries done and isStreaming → the server already finished;
    /// close out locally (the watchdog clears with it).
    func resyncFromHistory() async {
        guard let frames = try? await api.fetchChatHistory(), !frames.isEmpty else { return }
        // Trailing assistant run (skip thinking/tool intermediate frames; scan backwards until a non-assistant frame)
        var tail: [String] = []
        var hasDone = false
        for f in frames.reversed() {
            if f.type == "assistant" { tail.insert(f.data, at: 0); continue }
            if f.type == "done" {
                // R1 P2-7 / R3 rework: before letting a done through, check the
                // tail —
                //   · non-empty tail = a turn mid-stream (text emitted, no done
                //     yet); the done encountered belongs to the previous turn,
                //     stop in place (R2 let it through unconditionally, merging
                //     the old full text across turns);
                //   · empty tail and no done seen = the latest turn genuinely
                //     has no body, let it through and keep collecting (the
                //     normal end-of-turn marker pulled in by close-out);
                //   · empty tail but hasDone already set = consecutive empty
                //     turns, stop; do not cross the boundary into old turns.
                if !tail.isEmpty { break }
                if !hasDone { hasDone = true; continue }
                break
            }
            break // any other frame = turn boundary
        }
        guard !tail.isEmpty || hasDone else { return }
        let full = tail.joined()
        if !full.isEmpty {
            if let lastIdx = messages.lastIndex(where: { $0.role == .assistant }) {
                // Only touch the latest turn's bubble: it must come after the last user message (never rewrite historical turns)
                let lastUser = messages.lastIndex(where: { $0.role == .user }) ?? -1
                if lastIdx > lastUser {
                    let local = messages[lastIdx].text
                    if local == full { /* already synced */ }
                    else if full.hasPrefix(local) || local.isEmpty {
                        messages[lastIdx].text = full // prefix → complete the stream cut half-way
                    } else if lastIdx == messages.count - 1, hasDone, !local.isEmpty {
                        messages[lastIdx].text = full // conservative replace: the local leftover is a partial fragment
                    } else {
                        appendMessage(.assistant, full) // no local counterpart (mismatch) → append
                    }
                } else {
                    appendMessage(.assistant, full)
                }
            } else {
                appendMessage(.assistant, full) // the whole turn was lost (local tail is user)
            }
        }
        if hasDone && isStreaming {
            thinkingText = nil
            markTurnEnd()
            persistTranscript()
        }
    }

    // MARK: - Transcript persistence (0929: history lost on app relaunch → local write-through)

    /// Capped at 500 entries: enough context to look back on; full JSON read/write is not a cost concern.
    private static let transcriptLimit = 500
    private static var transcriptFileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("chat-transcript.json")
    }

    /// Single entry point: every message lands through here (append +
    /// persist). In-place merges of streaming chunks skip the disk; one write
    /// happens at turn close-out (done/error/interrupt).
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

    /// Clear the conversation (start a new intake): memory and disk cleared together.
    func clearTranscript() {
        messages = []
        try? FileManager.default.removeItem(at: Self.transcriptFileURL)
    }

    /// Send a chat message. `voice` flags the message as coming from a voice
    /// call so the server uses a spoken-friendly prompt (conversational, no
    /// tables/code). STT turns set voice = isInCall; typed messages omit it.
    /// Attachments (wf_3310501a9fe4): pendingAttachments are uploaded per item
    /// when the message sends, then carried as references; a pure-attachment
    /// message uses the body placeholder "[N attachments]" (the server requires
    /// non-empty input).
    func send(text: String, voice: Bool = false) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let outgoing = pendingAttachments
        guard !trimmed.isEmpty || !outgoing.isEmpty else { return }
        pendingAttachments = []
        let displayText = trimmed.isEmpty ? "[\(outgoing.count) attachments]" : trimmed
        // No attachments: keep the optimistic immediate display (original
        // behavior); with attachments: display only after upload succeeds (the
        // bubble needs the attachment metadata the server fills in); the
        // streaming indicator holds the place during upload.
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
                // R1 P2-5: reset the watchdog after uploads finish — the time
                // spent uploading 5×10MB on a slow network no longer eats into
                // the turn's 110s (during upload the old timer set at dispatch
                // still covers; a genuinely hung upload still times out and
                // closes out); sends without attachments do not reset.
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
    /// indicator never sticks. Aligned with the turn request's 120s timeout
    /// (intake multi-round LLM turns measured at 30s+; 60s would falsely kill
    /// long turns).
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
        // exactly what's stuck). Reset locally right away. Intake turn is a
        // synchronous request scope — the server has no cancellable background
        // generation; closing out locally is complete.
        endStreaming()
    }

    /// Confirm the staged intake plan → server runs startTask (the intake
    /// front door). Failures made visible: the card stays retryable (the
    /// server-side staging is unconsumed), never silently swallowed — intake
    /// is the core verb of this feature.
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
                // A failed cancel does not block the conversation (the next turn's input also makes the server drop the staging).
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
    /// suspended during playback to avoid echo). The intake chat has no
    /// server-side call state (the intake loop has no dispatch-class tool to
    /// intercept); start/stop are purely local.
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
        // Intake chat = a pause after speaking sends (silence auto-completes the turn; the submit phrase still completes instantly).
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
        // would go live while the UI / lock screen still say muted.
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

    // MARK: - WebSocket (/ws/chat event stream, transport layer identical to the archived version)

    private func openConnection() {
        let url = config.chatWSURL
        // Session-level replacement: the old implementation's repeated
        // openConnection only swapped the task without destroying the session —
        // delegate leaks + stale callbacks (the more reconnects, the faster the
        // leak).
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
            // The closing turn's text event carries a ```intake-plan block —
            // stripped from the bubble (the plan arrives via the plan event and
            // its own card); raw JSON never enters the chat UI (review P1-1).
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
            persistTranscript() // in-place merges of streaming chunks skip the disk; turn close-out writes once
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
            // Only a truly in-flight turn closes out — a chat:error from a
            // failed confirm is not inside a turn; decrementing pendingTurns by
            // mistake would extinguish the indicator early (review P2).
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
        // Background/suspension-induced disconnect = expected behavior
        // (didEnterBackground already closed deliberately; the failure callback
        // for an OS-severed line during suspension is only handled after
        // returning to foreground) — stay silent, no "connection lost"
        // announcement, and do not kill in-flight turns: the server may still
        // be running; assistant/done frames resume normally after the
        // foreground reconnect (if truly lost, the watchdog closes out).
        let suspendedDrop = appInBackground || UIApplication.shared.applicationState != .active
        if isStreaming && !suspendedDrop {
            // WS dropped mid-turn: the backend's `done` broadcast has no
            // buffer and no replay, so it's already lost. Close the turn now
            // rather than leaving the indicator pinned until the watchdog.
            appendMessage(.system, "[connection lost — reconnecting]")
            endStreaming()
        }
        if suspendedDrop {
            // No backoff reconnection scheduled during suspension (timers do
            // not run = pure spinning) — makroReconnect reconnects immediately
            // on foreground return.
            return
        }
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        // No reconnect on deliberate close (background/exit) or during suspension — the latter is reconnected by makroReconnect on foreground return
        guard !userClosed, !appInBackground else { return }
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, 60)
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            // Prevent double-connects: if a previous reconnect already moved the state off disconnected, this one yields
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
            // Pull intake state immediately after reconnecting: phase/plan may
            // have changed during the disconnect window (confirmed/cancelled on
            // another surface) — do not mislead the user with a stale card.
            await self.loadHistory()
            // Backfill (wf_e2f2bfba8865 P0): assistant/done frames missed
            // during suspension are realigned from the 200-entry ring history —
            // "switch out of the app and come back to the full reply".
            await self.resyncFromHistory()
        }
    }

    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        Task { @MainActor in
            self.stopPing()
            self.task = nil
            self.connectionState = .disconnected
            // The old logic only reconnected on non-normalClosure — normal
            // close codes from the server/middle layer (1000/1001) left chat
            // permanently down until the page was re-entered. Now only a
            // deliberate user close (userClosed) skips reconnect; everything
            // else is treated as unexpected.
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
