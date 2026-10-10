import SwiftUI

// Intervene-to-correct sheet (Penpot board 11 · makro-iphone).
// Talking to a drifting agent beats typing — voice + an editable
// transcript; delivery goes through the first-class intervene endpoint,
// fully traced (intervention history / activity timeline / audit events /
// heartbeat renewal). Errors show in place, not in the list banner hidden
// behind the sheet.

struct InterveneSheet: View {
    @ObservedObject var vm: LifecycleViewModel
    let step: LifecycleStep
    @Environment(\.dismiss) private var dismiss

    @StateObject private var speech = AzureSpeechManager()
    @State private var text = ""
    @State private var errorText: String?
    @State private var busy = false

    private var isListening: Bool {
        if case .listening = speech.listenState { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("\(step.seq). \(step.displayTitle) · \(step.status == "running" ? "Running" : step.status)")
                        .font(DS.mono(11)).foregroundStyle(.secondary)

                    TextEditor(text: $text)
                        .font(DS.text(13))
                        .frame(minHeight: 120)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(DS.Canvas.card)
                        .clipShape(RoundedRectangle(cornerRadius: DS.R.md, style: .continuous))

                    if isListening, case .listening(let partial) = speech.listenState, !partial.isEmpty {
                        Text("Listening…\(partial.suffix(10))")
                            .font(DS.mono(10)).foregroundStyle(DS.Ink.mint)
                    }
                    if let errorText {
                        Text(errorText)
                            .font(DS.mono(11)).foregroundStyle(DS.Ink.rose)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(DS.Ink.rose.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: DS.R.sm))
                    }

                    Text("Traced: replayable intervention history · activity timeline · audit events · heartbeat")
                        .font(DS.mono(9.5)).foregroundStyle(.secondary)
                }
                .padding(16)
            }
            .background(DS.Canvas.app.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) { micBar }
            .navigationTitle("Intervene")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { speech.stopListening(); dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        send()
                    } label: {
                        if busy { ProgressView().controlSize(.small) } else { Text("Deliver →") }
                    }
                    .font(DS.text(14, .semibold))
                    .disabled(busy || text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onChange(of: speech.listenState) { state in
                if case .error(let msg) = state { errorText = msg }
            }
            .onDisappear { speech.stopListening() }
        }
    }

    private var micBar: some View {
        HStack(spacing: 16) {
            Button {
                toggleMic()
            } label: {
                MicGlyph().frame(width: 26, height: 26).foregroundStyle(isListening ? .white : DS.Ink.mint)
            }
            .background(Circle().fill(isListening ? DS.Ink.mint : DS.Ink.mint.opacity(0.12)))
            .breathing(isListening)
            .accessibilityLabel(isListening ? "Stop recording" : "Voice input")
            Text("Voice or typing — the transcript is editable")
                .font(DS.mono(9.5)).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.bar)
    }

    private func toggleMic() {
        if isListening { speech.stopListening(); return }
        guard speech.isConfigured else {
            errorText = "Voice not configured (Settings → Voice) — typing still works"
            return
        }
        speech.onRecognized = { piece in
            Task { @MainActor in
                let p = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                if !p.isEmpty { text += p }
            }
        }
        speech.startListening(continuous: true)
    }

    private func send() {
        busy = true
        speech.stopListening()
        let payload = text.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                try await vm.intervene(stepID: step.id, text: payload)
                dismiss()
            } catch {
                errorText = error.localizedDescription
            }
            busy = false
        }
    }
}

// MARK: - Amend-inputs sheet (amend: failed steps missing input; the engine prefills candidate values)

import SwiftUI

struct AmendSheet: View {
    @ObservedObject var vm: LifecycleViewModel
    let step: LifecycleStep
    @Environment(\.dismiss) private var dismiss

    @State private var rows: [AmendSuggestion] = []
    @State private var edits: [String: String] = [:]
    @State private var loading = true
    @State private var busy = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView("Loading candidates…")
                } else if rows.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "tray").font(.system(size: 26)).foregroundStyle(.tertiary)
                        Text("No amendable inputs on this step").font(DS.text(13)).foregroundStyle(.secondary)
                    }
                } else {
                    List {
                        Section("Amend inputs · auto-rerun after submit") {
                            ForEach(rows) { row in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(row.key).font(DS.mono(12, .semibold))
                                        Spacer()
                                        Text(row.source).font(DS.mono(9)).foregroundStyle(.tertiary)
                                    }
                                    TextField("Candidate: \(row.value)", text: Binding(
                                        get: { edits[row.key] ?? row.value },
                                        set: { edits[row.key] = $0 }))
                                        .font(DS.mono(12))
                                        .textFieldStyle(.roundedBorder)
                                }
                            }
                        }
                        if let errorText {
                            Section { Text(errorText).font(DS.mono(11)).foregroundStyle(DS.Ink.rose) }
                        }
                    }
                }
            }
            .navigationTitle("Amend · \(step.seq). \(step.displayTitle)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        submit()
                    } label: {
                        if busy { ProgressView().controlSize(.small) } else { Text("Submit & rerun →") }
                    }
                    .disabled(loading || busy || rows.isEmpty)
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        do {
            rows = try await APIClient.shared.fetchAmendSuggestions(workflowID: step.workflow_id)
        } catch {
            errorText = error.localizedDescription
        }
        loading = false
    }

    private func submit() {
        busy = true
        let patch = Dictionary(uniqueKeysWithValues: rows.map { r in
            (r.key, edits[r.key] ?? r.value)
        })
        Task {
            do {
                try await APIClient.shared.amendStep(stepID: step.id, patch: patch)
                dismiss()
                await vm.refresh()
            } catch {
                errorText = error.localizedDescription
            }
            busy = false
        }
    }
}
