import SwiftUI

// Intake · voice-first (Penpot board 10 · makro-iphone).
// Typing is too costly — voice is the first-class input: a big mic,
// tap-to-start/stop, Azure transcription (the project's existing
// AzureSpeechManager, already configured in Settings), editable transcript,
// and typing always available. The title auto-takes the first sentence.
// Submit = POST /api/lifecycle/tasks (same contract as the web #/trigger;
// dispatch takes over immediately); on success the new case detail opens
// automatically.

struct TaskComposerView: View {
    /// Submit succeeded → hand the new case id back; the caller opens the detail.
    let onStarted: (String) -> Void
    /// Follow-up attachment: points at an existing case (enters the causal chain on the ledger).
    var relatesTo: String? = nil
    @Environment(\.dismiss) private var dismiss

    @StateObject private var speech = AzureSpeechManager()
    @State private var transcript = ""
    @State private var title = ""
    @State private var titleEdited = false
    @State private var submitting = false
    @State private var errorText: String?
    @State private var micError: String?
    @State private var startedAt: Date?
    @State private var tick: Date = .now
    @State private var timerHolder: Timer?

    private var isListening: Bool {
        if case .listening = speech.listenState { return true }
        return false
    }

    private var charCount: Int { transcript.count }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let relatesTo, !relatesTo.isEmpty {
                        Label("Follows \(relatesTo.prefix(14))… (causal chain in the ledger)", systemImage: "arrow.triangle.branch")
                            .font(DS.mono(10, .semibold))
                            .foregroundStyle(DS.Ink.mintDeep)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(DS.Ink.mint.opacity(0.1))
                            .clipShape(Capsule())
                    }
                    // Title: auto-generated from the first sentence, editable
                    Text("Title · auto-generated, editable")
                        .font(DS.mono(11, .semibold)).foregroundStyle(.secondary)
                    TextField("Name this job…", text: $title, onEditingChanged: { titleEdited = $0 })
                        .font(DS.text(14, .semibold))
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .background(DS.Canvas.card)
                        .clipShape(RoundedRectangle(cornerRadius: DS.R.md, style: .continuous))

                    // Transcript body
                    Text("Content · voice transcript, tap to edit")
                        .font(DS.mono(11, .semibold)).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Circle().fill(transcript.isEmpty ? DS.Ink.zinc : DS.Ink.done)
                                .frame(width: 7, height: 7)
                            Text(transcript.isEmpty
                                 ? (isListening ? "Listening…" : "Tap the mic below to start")
                                 : "✓ Transcribed · \(charCount) chars")
                                .font(DS.mono(10)).foregroundStyle(.secondary)
                            Spacer()
                            if isListening, case .listening(let partial) = speech.listenState, !partial.isEmpty {
                                Text("…\(partial.suffix(12))")
                                    .font(DS.mono(10)).foregroundStyle(DS.Ink.mint)
                                    .lineLimit(1)
                            }
                        }
                        TextEditor(text: $transcript)
                            .font(DS.text(13))
                            .frame(minHeight: 140)
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .background(DS.Canvas.card)
                            .clipShape(RoundedRectangle(cornerRadius: DS.R.md, style: .continuous))
                        Text("Transcription: Azure Speech (configured in Settings)")
                            .font(DS.mono(9)).foregroundStyle(Color.secondary.opacity(0.6))
                    }

                    if let micError {
                        ErrorLine(text: micError + " · typing still works")
                    }
                    if let errorText {
                        ErrorLine(text: errorText)
                    }

                    // "dispatch takes over" hint
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle").font(.system(size: 12))
                        Text("Handed off on create · first node seeded · stops at the gate for you")
                    }
                    .font(DS.mono(10)).foregroundStyle(DS.Ink.mintDeep)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(red: 1.0, green: 0.973, blue: 0.941)) // #FFF8F0 warm orange-white
                    .clipShape(RoundedRectangle(cornerRadius: DS.R.md))
                }
                .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 180)
            }
            .background(DS.Canvas.app.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) { micBar }
            .navigationTitle("Create job")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { stopMic(); dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        submit()
                    } label: {
                        if submitting { ProgressView().controlSize(.small) } else { Text("Go →") }
                    }
                    .font(DS.text(14, .semibold))
                    .disabled(submitting || title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onChange(of: speech.listenState) { state in
                if case .error(let msg) = state { micError = msg }
            }
            .onDisappear { stopMic() }
        }
    }

    // ── Bottom voice bar: waveform + big mic ──
    private var micBar: some View {
        VStack(spacing: 10) {
            if isListening {
                HStack(spacing: 10) {
                    Button { stopMic() } label: {
                        Image(systemName: "xmark").font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Cancel recording")
                    Text(elapsedLabel).font(DS.mono(12, .semibold)).foregroundStyle(DS.Ink.mintDeep)
                    WaveformView(active: isListening)
                    Text("Tap mic to finish").font(DS.mono(9)).foregroundStyle(.secondary)
                }
                .frame(height: 34)
            } else {
                HStack(spacing: 3) {
                    Image(systemName: "keyboard").font(.system(size: 10))
                    Text("Typing always works")
                }.font(DS.mono(9)).foregroundStyle(.secondary)
            }
            Button {
                toggleMic()
            } label: {
                MicGlyph()
                    .frame(width: 54, height: 54)
                    .foregroundStyle(.white)
            }
            .background(Circle().fill(DS.Ink.mint))
            .breathing(isListening)
            .accessibilityLabel(isListening ? "Stop recording" : "Start recording")
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private var elapsedLabel: String {
        guard let startedAt else { return "0:00" }
        let s = max(0, Int(tick.timeIntervalSince(startedAt)))
        return "\(s / 60):\(String(s % 60).paddingStart(2))"
    }

    // ── Voice ──
    private func toggleMic() {
        if isListening { stopMic(); return }
        guard speech.isConfigured else {
            micError = "Voice not configured (Settings → Voice: Azure region/key)"
            return
        }
        micError = nil
        speech.onRecognized = { text in
            Task { @MainActor in
                appendToTranscript(text)
            }
        }
        startedAt = .now
        timerHolder = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in tick = .now }
        }
        speech.startListening(continuous: true)
    }

    private func stopMic() {
        speech.stopListening()
        timerHolder?.invalidate(); timerHolder = nil
        startedAt = nil
        if case .error(let msg) = speech.listenState { micError = msg }
    }

    @MainActor
    private func appendToTranscript(_ text: String) {
        let piece = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !piece.isEmpty else { return }
        transcript += transcript.isEmpty ? piece : piece
        if !titleEdited && title.isEmpty { title = firstSentence(transcript) }
    }

    private func firstSentence(_ s: String) -> String {
        for sep in ["。", "！", "？", "\n", "；"] {
            if let r = s.range(of: sep) {
                let head = String(s[s.startIndex..<r.lowerBound])
                if !head.isEmpty { return String(head.prefix(20)) }
            }
        }
        return String(s.prefix(20))
    }

    // ── Submit ──
    private func submit() {
        let t = title.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else {
            errorText = "Title required — speak a sentence and it is generated"
            return
        }
        submitting = true
        stopMic()
        Task {
            do {
                let id = try await APIClient.shared.startTask(title: t, brief: transcript, relatesTo: relatesTo)
                dismiss()
                onStarted(id)
            } catch {
                errorText = error.localizedDescription
            }
            submitting = false
        }
    }
}

// Symmetric recording waveform (board 10 revision: mirrored around the center line, no emoji).
private struct WaveformView: View {
    let active: Bool
    @State private var phase = false
    private static let bars: [CGFloat] = [6,10,16,24,32,26,17,11,19,29,35,27,16,9,15,24]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<Self.bars.count, id: \.self) { i in
                let h = Self.bars[i] * (active && phase ? 0.6 : 1.0)
                RoundedRectangle(cornerRadius: 2)
                    .fill(i % 3 == 0 ? DS.Ink.mint : DS.Ink.mint.opacity(0.3))
                    .frame(width: 3.5, height: h)
            }
        }
        .frame(height: 36)
        .animation(active ? .easeInOut(duration: 0.5).repeatForever(autoreverses: true) : .default, value: phase)
        .onAppear { phase = true }
    }
}

// Vector microphone (capsule + stem + base — emoji rendering is unreliable; board 10/11 revision).
struct MicGlyph: View {
    var body: some View {
        VStack(spacing: 2) {
            RoundedRectangle(cornerRadius: 8)
                .frame(width: 14, height: 22)
            RoundedRectangle(cornerRadius: 1.5)
                .frame(width: 3, height: 6)
            RoundedRectangle(cornerRadius: 1.5)
                .frame(width: 18, height: 3)
        }
    }
}

private struct ErrorLine: View {
    let text: String
    var body: some View {
        Text(text)
            .font(DS.mono(11)).foregroundStyle(DS.Ink.rose)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Ink.rose.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: DS.R.sm))
    }
}

private extension String {
    func paddingStart(_ n: Int) -> String {
        count >= n ? self : String(repeating: "0", count: n - count) + self
    }
}
