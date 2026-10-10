// Intake chat view (recovered from the Makro archive repo 4a4a625^ on
// 09-29, copy and entry semantics adapted to the juli intake chat: clarify
// loop → plan card → confirm intake).
// ⚠️ CallRouter.pendingStart's double consumption (.onReceive warm path +
// .task cold-start read of the current value) is a load-bearing design —
// both are required; see the comments below, do not "simplify".

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct ChatView: View {
    @StateObject private var vm = ChatViewModel()
    @State private var inputText = ""
    @State private var showCall = false
    @State private var showClearConfirm = false
    @State private var appeared = false
    // Attachment entry (wf_3310501a9fe4): ➕ → pick one of camera/photo library/files.
    @State private var showAttachMenu = false
    @State private var showCamera = false
    @State private var showPhotos = false
    @State private var showFiles = false
    @FocusState private var inputFocused: Bool

    /// Shared system draft (wf_030261e0a13a): Share Extension → App Group →
    /// Router; fills the input box and focuses it, waiting for the user to
    /// edit and send (no auto-send — the intake confirmation right belongs
    /// to the user).
    private func takeShareDraft() {
        if let draft = DeepLinkRouter.shared.shareDraft, !draft.isEmpty {
            DeepLinkRouter.shared.shareDraft = nil
            inputText = draft
            inputFocused = true
        }
    }

    /// Create a follow-up based on a job (wf_9d93ee9f7adb): prefills the
    /// input box (original job ID + title + follow-up semantics); the user
    /// adds a sentence about what to do and sends — still going through the
    /// "confirm on the plan card to start the job" flow; the engine carries
    /// the original-job association naturally from the conversation context.
    private func followUp(wfID: String, title: String) {
        let quoted = title.isEmpty ? "" : "\"\(title)\""
        inputText = "Follow-up \(wfID)\(quoted): keep iterating with this job’s context —"
        inputFocused = true
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        if vm.messages.isEmpty && vm.thinkingText == nil {
                            emptyState
                                .padding(.top, 80)
                        } else {
                            LazyVStack(alignment: .leading, spacing: 10) {
                                ForEach(vm.messages) { msg in
                                    MessageRow(message: msg, onFollow: followUp)
                                        .id(msg.id)
                                        .transition(.asymmetric(
                                            insertion: .opacity.combined(with: .move(edge: .bottom)),
                                            removal: .opacity
                                        ))
                                }
                                if vm.thinkingText != nil {
                                    ThinkingIndicator(text: vm.thinkingText)
                                        .id("thinking")
                                        .padding(.top, 4)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                        }
                    }
                    .simultaneousGesture(
                        TapGesture().onEnded { inputFocused = false }
                    )
                    .onChange(of: vm.messages.count) { _ in
                        if let last = vm.messages.last {
                            withAnimation(.easeOut(duration: 0.18)) {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                    .onChange(of: vm.thinkingText) { _ in
                        if vm.thinkingText != nil {
                            withAnimation(.easeOut(duration: 0.18)) {
                                proxy.scrollTo("thinking", anchor: .bottom)
                            }
                        }
                    }
                    // The message stream anchors to the very bottom (0930
                    // user ruling): on view appearance (including tab
                    // switches back — ScrollView position is not kept) land
                    // directly on the newest message; no opening onto the old
                    // top.
                    .onAppear {
                        if let last = vm.messages.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }

                // Plan card (0930 backfill: pendingPlan used to render only
                // in CallView; once the text-chat mode converged, the card
                // never appeared = the user could never reach the "start"
                // button and no job got created — server-side evidence:
                // phase=proposed left hanging, unconsumed).
                if vm.pendingPlan != nil {
                    planCard
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                inputBar
            }
            .animation(DS.snappy, value: vm.pendingPlan)
            .background(DS.Canvas.app.ignoresSafeArea())
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Intake")
                        .font(DS.display(18, .semibold))
                        .tracking(-0.3)
                        .foregroundStyle(.primary)
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    ConnectionBadge(state: vm.connectionState)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    // Call entry + clear conversation (after 0929 history persistence, an exit was needed to start a new intake).
                    HStack(spacing: 14) {
                        Button { showClearConfirm = true } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(DS.Ink.zinc)
                        }
                        Button { showCall = true } label: {
                            Image(systemName: "phone.fill")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(DS.Ink.mint)
                        }
                    }
                }
            }
            .fullScreenCover(isPresented: $showCall) {
                CallView(vm: vm)
            }
            .onReceive(DeepLinkRouter.shared.$shareDraft) { draft in
                // Shared draft arrived (including cold-start replay): if non-empty, take it and fill the input box.
                if let draft, !draft.isEmpty { takeShareDraft() }
            }
            .onReceive(CallRouter.shared.$pendingStart) { wantsCall in
                // Warm re-trigger: app already running and ChatView alive.
                guard wantsCall else { return }
                CallRouter.shared.pendingStart = false
                showCall = true
            }
            .task {
                await vm.loadHistory()
                vm.connect()
                withAnimation(DS.spring) { appeared = true }
                takeShareDraft() // cold start: shareDraft exists before this view (replay covers it, belt and suspenders)
                // Cold start: Siri may have set the flag before this view
                // existed, so .onReceive (which only fires on future changes)
                // would miss it. Check the current value on appear.
                if CallRouter.shared.pendingStart {
                    CallRouter.shared.pendingStart = false
                    showCall = true
                }
            }
            // ⚠️ LOAD-BEARING DUAL-CONSUME of `CallRouter.pendingStart`:
            // `pendingStart` is read in TWO places above — `.onReceive`
            // (warm) and `.task` (cold-start). BOTH are required:
            //   • `.onReceive` fires only on changes emitted AFTER the view
            //     subscribes, so it covers warm re-triggers (app running,
            //     Siri invoked again) but cannot see a value that was set
            //     before this view existed.
            //   • `.task` reads the *current* value on first appear, which
            //     is the only path that catches a cold-launch hang-up where
            //     `StartCallIntent.perform()` set the flag before ChatView
            //     was on screen.
            // `@Published` emits on EVERY assignment (including repeated
            // `true`), which is what makes the Bool one-shot work — the
            // consumer resets it to `false` and the next `true` re-fires.
            // DO NOT add `.removeDuplicates()` to the publisher chain (it
            // would coalesce `false → true → false → true` into a single
            // emission and silently break re-trigger). DO NOT delete the
            // `.task` current-value check (cold launch would stop working).
            // 0929: removed onDisappear→disconnect — TabView fires it on
            // every tab switch, so peeking at Flow/Agents mid-chat dropped
            // the in-between reply broadcasts on return (the server does not
            // replay). The socket lifetime is managed by the VM on
            // foreground/background events (see ChatViewModel).
            .confirmationDialog("Clear this conversation?", isPresented: $showClearConfirm, titleVisibility: .visible) {
                Button("Clear", role: .destructive) { vm.clearTranscript() }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    // MARK: - Plan card (converged → user confirms intake; cancel returns to the discussion)

    @ViewBuilder
    private var planCard: some View {
        if let plan = vm.pendingPlan {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DS.Ink.mintDeep)
                    Text("Job card — confirm to create")
                        .font(DS.text(14, .semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                }
                Text(plan.title)
                    .font(DS.text(15, .medium))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if !plan.summary.isEmpty && plan.summary != plan.title {
                    Text(plan.summary)
                        .font(DS.text(13, .regular))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !plan.brief.isEmpty && plan.brief != plan.summary {
                    Text(plan.brief)
                        .font(DS.mono(11, .regular))
                        .foregroundStyle(.secondary)
                        .lineLimit(6)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Resolved target session (0930 "everything goes through
                // routing"): the target session judged by the routing layer —
                // confirming intake pins it into input.session; the note
                // shows the reroute/queue reason.
                if let landing = plan.landing, !landing.session.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "arrowshape.turn.up.right.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(DS.Ink.mintDeep)
                        Text("Lands: \(landing.session)")
                            .font(DS.text(12, .semibold))
                            .foregroundStyle(.primary)
                        if !landing.note.isEmpty {
                            Text(landing.note)
                                .font(DS.text(11, .regular))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                Toggle(isOn: $vm.pendingAutoApprove) {
                    Text("Auto-approve this job (outbound email still waits for me)")
                        .font(DS.text(12, .regular))
                        .foregroundStyle(.secondary)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 10) {
                    Button { vm.denyPlan() } label: {
                        Text("Cancel")
                            .font(DS.text(14, .semibold))
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(DS.Canvas.inset)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    Button { vm.confirmPlan() } label: {
                        Text("Create job")
                            .font(DS.text(14, .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                LinearGradient(
                                    colors: [DS.Ink.mint, DS.Ink.mintDeep],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
                .padding(.top, 2)
            }
            .padding(14)
            .background(DS.Canvas.card)
            .clipShape(RoundedRectangle(cornerRadius: DS.R.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.R.lg, style: .continuous)
                    .stroke(DS.Ink.mint.opacity(0.4), lineWidth: 1)
            )
        }
    }

    private var emptyState: some View {        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .stroke(DS.Ink.mint.opacity(0.18), lineWidth: 1)
                    .frame(width: 88, height: 88)
                Circle()
                    .fill(DS.Ink.mint.opacity(0.08))
                    .frame(width: 56, height: 56)
                Image(systemName: "bubble.left")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(DS.Ink.mint)
            }
            VStack(spacing: 4) {
                Text("One sentence is enough")
                    .font(DS.display(17, .semibold))
                    .foregroundStyle(.primary)
                Text("juli asks until the request is clear, then hands you a job card — nothing runs until you confirm.")
                    .font(DS.text(13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .opacity(appeared ? 1 : 0)
        .animation(DS.spring, value: appeared)
    }

    private var inputBar: some View {
        VStack(spacing: 0) {
            // Voice-mode status line: shows the live partial transcript while
            // listening, or a "speaking…" hint while TTS plays.
            if vm.isListening {
                listeningBar
            } else if vm.isSpeaking {
                speakingBar
            }

            // Pending-attachment tray (wf_3310501a9fe4): thumbnail/file chips in a row, deletable.
            if !vm.pendingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(vm.pendingAttachments) { p in
                            ZStack(alignment: .topTrailing) {
                                if let ui = UIImage(data: p.data) {
                                    Image(uiImage: ui)
                                        .resizable().scaledToFill()
                                        .frame(width: 52, height: 52)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                } else {
                                    HStack(spacing: 4) {
                                        Image(systemName: "doc.fill")
                                        Text(p.name).lineLimit(1)
                                    }
                                    .font(DS.mono(10))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 10).padding(.vertical, 8)
                                    .background(DS.Canvas.inset)
                                    .clipShape(Capsule())
                                }
                                Button {
                                    vm.pendingAttachments.removeAll { $0.id == p.id }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 14))
                                        .foregroundStyle(.secondary)
                                        .background(Circle().fill(.white))
                                }
                                .offset(x: 6, y: -6)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            HStack(spacing: 10) {
                // ➕ Attachment entry (wf_3310501a9fe4): pick one of camera/photo library/files.
                Button { showAttachMenu = true } label: {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .confirmationDialog("Add attachment", isPresented: $showAttachMenu) {
                    Button("Take photo") { showCamera = true }
                    Button("Photo library") { showPhotos = true }
                    Button("Choose file") { showFiles = true }
                    Button("Cancel", role: .cancel) {}
                }

                micButton

                Group {
                    if vm.isListening, let partial = vm.partialTranscript, !partial.isEmpty {
                        Text(partial)
                            .font(DS.mono(14, .regular))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    } else {
                        TextField("What do you need? One line is enough", text: $inputText)
                            .font(DS.mono(14, .regular))
                            .foregroundStyle(.primary)
                            .focused($inputFocused)
                            .onSubmit { send() }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(DS.Canvas.inset)
                .clipShape(RoundedRectangle(cornerRadius: DS.R.md, style: .continuous))
                .glassBorder(DS.R.md)

                Button(action: { vm.isStreaming ? vm.cancel() : send() }) {
                    Image(systemName: vm.isStreaming ? "stop.fill" : "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(buttonColor)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Color.white.opacity(0.08), lineWidth: 0.5))
                }
                .disabled(!vm.isStreaming && inputText.isEmpty && vm.pendingAttachments.isEmpty)
                .animation(DS.snappy, value: vm.isStreaming)
                .animation(DS.snappy, value: inputText.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.bar)
            .sheet(isPresented: $showCamera) {
                CameraAttachmentPicker(vm: vm, show: $showCamera)
                    .ignoresSafeArea()
            }
            .sheet(isPresented: $showPhotos) {
                PhotoAttachmentPicker(show: $showPhotos, vm: vm)
            }
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.image, .pdf, .text, .plainText, .json, .zip, .spreadsheet, .presentation], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result {
                    for url in urls {
                        guard url.startAccessingSecurityScopedResource() else { continue }
                        defer { url.stopAccessingSecurityScopedResource() }
                        if let data = try? Data(contentsOf: url) {
                            // R1 P2-8: take the real MIME via UTType —
                            // previously hand-built illegal MIME like
                            // "file/pdf" went into the server-side ref and
                            // the prompt line.
                            let mime = UTType(filenameExtension: url.pathExtension)?
                                .preferredMIMEType ?? "application/octet-stream"
                            vm.addPendingAttachment(data: data, name: url.lastPathComponent, mime: mime)
                        }
                    }
                }
            }
        }
    }

    private var micButton: some View {
        Button {
            // Tap mic → start/stop listening directly. No persistent voice
            // mode: typed messages are never spoken, and a spoken reply is
            // read aloud exactly once (managed by expectSpokenReply).
            vm.toggleListening()
        } label: {
            Image(systemName: micIcon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(micColor)
                .frame(width: 40, height: 40)
                .background(micColor.opacity(0.14))
                .clipShape(Circle())
                .breathing(vm.isListening || vm.isSpeaking)
        }
        .animation(DS.snappy, value: vm.isListening)
    }

    private var micIcon: String {
        if vm.isListening { return "waveform" }
        if vm.isSpeaking { return "speaker.wave.2.fill" }
        return "mic"
    }

    private var micColor: Color {
        if vm.isListening { return DS.Ink.rose }
        if vm.isSpeaking { return DS.Ink.mint }
        return DS.Ink.zinc
    }

    private var listeningBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DS.Ink.rose)
            Text(vm.partialTranscript?.isEmpty == false ? vm.partialTranscript! : "Listening…")
                .font(DS.mono(12, .regular))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button { vm.stopListening() } label: {
                Text("Stop")
                    .font(DS.micro(10, .semibold))
                    .foregroundStyle(DS.Ink.rose)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(DS.Ink.rose.opacity(0.08))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var speakingBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DS.Ink.mint)
            Text("Speaking…")
                .font(DS.mono(12, .regular))
                .foregroundStyle(.secondary)
            Spacer()
            Button { vm.stopSpeaking() } label: {
                Text("Stop")
                    .font(DS.micro(10, .semibold))
                    .foregroundStyle(DS.Ink.mint)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(DS.Ink.mint.opacity(0.08))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var buttonColor: Color {
        if vm.isStreaming { return DS.Ink.rose }
        return inputText.isEmpty ? DS.Ink.zinc : DS.Ink.mint
    }

    private func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !vm.pendingAttachments.isEmpty else { return }
        // Dismiss the keyboard before clearing the text (2026-10-01
        // user-reported "input box still holds the sent text after sending =
        // the message looks duplicated"): the IME/dictation uncommitted
        // buffer re-writes the original text into the TextField after the
        // state is cleared (an IME re-commit race) — resigning first
        // responder ends the dictation/composition session and the buffer is
        // dropped with it; one more clearing beat later mops up any late
        // re-write.
        inputFocused = false
        inputText = ""
        vm.send(text: text)
        DispatchQueue.main.async { inputText = "" }
    }
}

// MARK: - The three attachment pickers (wf_3310501a9fe4)

/// Photo library (PhotosPicker multi-select, images).
private struct PhotoAttachmentPicker: View {
    @Binding var show: Bool
    let vm: ChatViewModel
    @State private var picks: [PhotosPickerItem] = []

    var body: some View {
        PhotosPicker(selection: $picks, maxSelectionCount: ChatViewModel.PendingAttachment.maxCount,
                     matching: .images) {
            Text("Pick image")
        }
        .onChange(of: picks) { items in
            show = false
            for item in items {
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        await MainActor.run {
                            // R1 P2-8: keep the original format name by data
                            // magic number — previously everything was
                            // force-named .jpg/image/jpeg (the content could
                            // be PNG/HEIC, name and reality mismatched); no
                            // image transcoding introduced.
                            let kind = Self.imageFormat(data)
                            let base = item.itemIdentifier ?? "image"
                            let name = base.lowercased().hasSuffix(".\(kind.ext)") ? base : "\(base).\(kind.ext)"
                            vm.addPendingAttachment(data: data, name: name, mime: kind.mime)
                        }
                    }
                }
            }
            picks = []
        }
        .padding()
    }

    /// Data magic number → the real (mime, extension). Unknown magic numbers fall back to jpeg (the camera/screenshot majority).
    private static func imageFormat(_ data: Data) -> (mime: String, ext: String) {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return ("image/png", "png") }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return ("image/jpeg", "jpg") }
        if data.starts(with: [0x47, 0x49, 0x46, 0x38]) { return ("image/gif", "gif") } // "GIF8"
        if data.count > 12, data.starts(with: [0x52, 0x49, 0x46, 0x46]), // "RIFF…WEBP"
           data.subdata(in: 8..<12) == Data("WEBP".utf8) { return ("image/webp", "webp") }
        if data.count > 11, data.subdata(in: 4..<8) == Data("ftyp".utf8) { return ("image/heic", "heic") }
        return ("image/jpeg", "jpg")
    }
}

/// Take a photo (a thin wrapper over the UIImagePickerController camera).
private struct CameraAttachmentPicker: UIViewControllerRepresentable {
    let vm: ChatViewModel
    @Binding var show: Bool

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        if UIImagePickerController.isSourceTypeAvailable(.camera) { p.sourceType = .camera }
        p.delegate = context.coordinator
        return p
    }
    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraAttachmentPicker
        init(_ p: CameraAttachmentPicker) { parent = p }
        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage, let data = img.jpegData(compressionQuality: 0.85) {
                parent.vm.addPendingAttachment(data: data, name: "photo-\(Int(Date().timeIntervalSince1970)).jpg",
                                               mime: "image/jpeg")
            }
            parent.show = false
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.show = false }
    }
}

// MARK: - Message row

private struct MessageRow: View {
    let message: ChatMessage
    var onFollow: ((String, String) -> Void)? = nil

    /// Job ID inside a message (wf_8bbd5a47b528): renders a work-order card
    /// under the bubble — title/status visible at a glance; tapping the card
    /// deep-links to that job's artifacts. The same job mentioned repeatedly
    /// yields only one card.
    private var workflowRefs: [String] { WorkflowRef.ids(in: message.text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch message.role {
            case .system:
                systemRow
            case .user:
                userRow
            case .assistant:
                assistantRow
            }
            if let atts = message.attachments, !atts.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(atts) { a in
                            HStack(spacing: 4) {
                                Image(systemName: a.mime.hasPrefix("image") ? "photo" : "doc.fill")
                                    .font(.system(size: 10))
                                Text(a.name).lineLimit(1)
                            }
                            .font(DS.mono(10))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(DS.Canvas.inset)
                            .clipShape(Capsule())
                        }
                    }
                }
                .padding(.horizontal, 2)
            }
            if !workflowRefs.isEmpty {
                VStack(spacing: 6) {
                    ForEach(workflowRefs, id: \.self) { refID in
                        WorkflowRefCard(wfID: refID, onFollow: onFollow)
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    private var systemRow: some View {
        Text(message.text)
            .font(DS.micro(10, .medium))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .background(DS.Canvas.inset.opacity(0.5))
            .clipShape(Capsule())
            .padding(.vertical, 4)
            .textSelection(.enabled)
    }

    private var userRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Spacer(minLength: 56)
            Text(message.text)
                .font(DS.text(15, .regular))
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .foregroundStyle(.white)
                .background(
                    LinearGradient(
                        colors: [DS.Ink.mint, DS.Ink.mintDeep],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: DS.R.lg, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.R.lg, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                )
        }
    }

    private var assistantRow: some View {
        HStack(alignment: .top, spacing: 8) {
            MarkdownTextView(text: message.text)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.Canvas.card)
                .clipShape(RoundedRectangle(cornerRadius: DS.R.lg, style: .continuous))
                .glassBorder(DS.R.lg)

            Spacer(minLength: 56)
        }
    }
}

// MARK: - Thinking indicator (3-dot staggered)

private struct ThinkingIndicator: View {
    let text: String?
    @State private var phase = 0

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(spacing: 4) {
                ForEach(0..<3) { i in
                    Circle()
                        .fill(DS.Ink.mint)
                        .frame(width: 5, height: 5)
                        .scaleEffect(phase == i ? 1.0 : 0.5)
                        .opacity(phase == i ? 1.0 : 0.4)
                        .animation(
                            .easeInOut(duration: 0.5).repeatForever().delay(Double(i) * 0.15),
                            value: phase
                        )
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .background(DS.Ink.mint.opacity(0.1))
            .clipShape(Capsule())

            if let text, !text.isEmpty {
                Text(text)
                    .font(DS.mono(11, .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .onAppear {
            phase = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { phase = 2 }
        }
    }
}

// MARK: - Connection badge

private struct ConnectionBadge: View {
    let state: ConnectionState

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .breathing(state != .disconnected)
        }
        .padding(.horizontal, 4)
    }

    private var color: Color {
        switch state {
        case .connected: return DS.Ink.mint
        case .connecting: return DS.Ink.amber
        case .disconnected: return DS.Ink.zinc
        }
    }
}

// MARK: - Markdown rendering (block + prose + inline)

enum MarkdownBlock {
    case text(String)
    case code(language: String, content: String)
}

struct MarkdownTextView: View {
    let text: String
    var fontSize: CGFloat = 14

    var body: some View {
        let blocks = Self.parseBlocks(from: text)
        VStack(alignment: .leading, spacing: 8) {
            if blocks.isEmpty {
                Text(text)
                    .font(DS.text(fontSize, .regular))
                    .foregroundStyle(.primary)
                    .tint(DS.Ink.mint)
            } else {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .text(let content):
                        ProseRenderView(text: content, fontSize: fontSize)
                    case .code(let language, let code):
                        CodeBlockView(language: language, code: code)
                    }
                }
            }
        }
    }

    static func parseBlocks(from text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let parts = text.components(separatedBy: "```")
        for (i, part) in parts.enumerated() {
            if part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            if i % 2 == 0 {
                blocks.append(.text(part))
            } else {
                if let nl = part.firstIndex(of: "\n") {
                    let lang = String(part[..<nl]).trimmingCharacters(in: .whitespaces)
                    let code = String(part[part.index(after: nl)...])
                    blocks.append(.code(language: lang, content: code))
                } else {
                    blocks.append(.code(language: "", content: part))
                }
            }
        }
        return blocks
    }

    static func renderInline(_ text: String) -> AttributedString {
        if let attr = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return attr
        }
        return AttributedString(text)
    }
}

/// Per-line prose renderer: headings, bullets, numbered lists, hrules, paragraphs, GFM tables.
struct ProseRenderView: View {
    let text: String
    var fontSize: CGFloat = 14

    private static let headings: [(prefix: String, drop: Int, weight: Font.Weight, size: CGFloat)] = [
        ("### ", 4, .semibold, 1.0),
        ("## ",  3, .semibold, 1.12),
        ("# ",   2, .bold, 1.25),
    ]

    var body: some View {
        let segments = Self.segment(text)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .prose(let lines):
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            renderLine(line)
                        }
                    }
                case .table(let header, let rows, let aligns):
                    MarkdownTableView(header: header, rows: rows, aligns: aligns, fontSize: fontSize)
                }
            }
        }
    }

    @ViewBuilder
    private func renderLine(_ line: String) -> some View {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if trimmed.isEmpty {
            Spacer().frame(height: 4)
        } else if isHRule(trimmed) {
            Rectangle()
                .fill(DS.Ink.zinc.opacity(0.25))
                .frame(height: 1)
                .padding(.vertical, 4)
        } else if let cfg = Self.headings.first(where: { trimmed.hasPrefix($0.prefix) }) {
            Text(MarkdownTextView.renderInline(String(trimmed.dropFirst(cfg.drop))))
                .font(.system(size: fontSize * cfg.size, weight: cfg.weight))
                .foregroundStyle(.primary)
                .tint(DS.Ink.mint)
        } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            HStack(alignment: .top, spacing: 6) {
                Text("\u{2022}")
                    .font(DS.text(fontSize))
                    .foregroundStyle(DS.Ink.mint)
                Text(MarkdownTextView.renderInline(String(trimmed.dropFirst(2))))
                    .font(DS.text(fontSize))
                    .foregroundStyle(.primary)
                    .tint(DS.Ink.mint)
            }
        } else if isNumberedList(trimmed) {
            numberedList(trimmed)
        } else {
            Text(MarkdownTextView.renderInline(trimmed))
                .font(DS.text(fontSize))
                .foregroundStyle(.primary)
                .tint(DS.Ink.mint)
        }
    }

    private func isHRule(_ line: String) -> Bool {
        let chars = line.filter { $0 != " " }
        guard chars.count >= 3 else { return false }
        return chars.allSatisfy { $0 == "-" || $0 == "*" || $0 == "_" }
    }

    private func isNumberedList(_ line: String) -> Bool {
        guard let dotRange = line.range(of: ". ", options: .literal) else { return false }
        return line[line.startIndex..<dotRange.lowerBound].allSatisfy(\.isNumber)
    }

    @ViewBuilder
    private func numberedList(_ trimmed: String) -> some View {
        let dotRange = trimmed.range(of: ". ", options: .literal)!
        let num = trimmed[trimmed.startIndex..<dotRange.lowerBound]
        let content = trimmed[dotRange.upperBound...]
        HStack(alignment: .top, spacing: 6) {
            Text(num + ".")
                .font(DS.mono(fontSize - 1, .medium))
                .foregroundStyle(DS.Ink.mint)
                .frame(minWidth: 18, alignment: .trailing)
            Text(MarkdownTextView.renderInline(String(content)))
                .font(DS.text(fontSize))
                .foregroundStyle(.primary)
                .tint(DS.Ink.mint)
        }
    }

    // MARK: - Table detection

    private enum Segment {
        case prose([String])
        case table(header: [String], rows: [[String]], aligns: [TextAlignment])
    }

    private static func segment(_ text: String) -> [Segment] {
        let lines = text.components(separatedBy: "\n")
        var segments: [Segment] = []
        var proseBuffer: [String] = []
        var i = 0

        func flushProse() {
            if !proseBuffer.isEmpty {
                segments.append(.prose(proseBuffer))
                proseBuffer = []
            }
        }

        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if isTableStart(trimmed: trimmed, lines: lines, idx: i) {
                flushProse()
                let (header, rows, aligns, consumed) = parseTable(lines: lines, fromIdx: i)
                segments.append(.table(header: header, rows: rows, aligns: aligns))
                i += consumed
            } else {
                proseBuffer.append(lines[i])
                i += 1
            }
        }
        flushProse()
        return segments
    }

    private static func isTableStart(trimmed: String, lines: [String], idx: Int) -> Bool {
        guard trimmed.contains("|") else { return false }
        guard idx + 1 < lines.count else { return false }
        let next = lines[idx + 1].trimmingCharacters(in: .whitespaces)
        return next.contains("|") && isSeparatorRow(next)
    }

    private static func isSeparatorRow(_ line: String) -> Bool {
        let chars = line.filter { !$0.isWhitespace }
        guard chars.contains("-") else { return false }
        return chars.allSatisfy { $0 == "-" || $0 == ":" || $0 == "|" }
    }

    private static func parseTable(lines: [String], fromIdx: Int) -> (header: [String], rows: [[String]], aligns: [TextAlignment], consumed: Int) {
        let header = splitRow(lines[fromIdx])
        let aligns = parseAligns(lines[fromIdx + 1])
        var rows: [[String]] = []
        var i = fromIdx + 2
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.contains("|") && !trimmed.isEmpty {
                rows.append(splitRow(lines[i]))
                i += 1
            } else {
                break
            }
        }
        return (header, rows, aligns, i - fromIdx)
    }

    private static func splitRow(_ line: String) -> [String] {
        var parts = line.components(separatedBy: "|")
        if let first = parts.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            parts.removeFirst()
        }
        if let last = parts.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            parts.removeLast()
        }
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func parseAligns(_ line: String) -> [TextAlignment] {
        splitRow(line).map { cell in
            let t = cell.trimmingCharacters(in: .whitespaces)
            let leftColon = t.hasPrefix(":")
            let rightColon = t.hasSuffix(":")
            if leftColon && rightColon { return .center }
            if rightColon { return .trailing }
            return .leading
        }
    }
}

// MARK: - Markdown table

struct MarkdownTableView: View {
    let header: [String]
    let rows: [[String]]
    let aligns: [TextAlignment]
    var fontSize: CGFloat = 14

    private var columnCount: Int { max(header.count, rows.map { $0.count }.max() ?? 0) }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(spacing: 0) {
                rowView(cells: header, isHeader: true)
                ForEach(Array(rows.enumerated()), id: \.offset) { idx, row in
                    rowView(cells: row, isHeader: false)
                        .background(idx % 2 == 0 ? Color.clear : DS.Canvas.inset.opacity(0.35))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: DS.R.sm, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.R.sm, style: .continuous)
                    .stroke(DS.Ink.mint.opacity(0.18), lineWidth: 0.5)
            )
        }
    }

    private func rowView(cells: [String], isHeader: Bool) -> some View {
        let widths = columnWidths()
        return HStack(alignment: .top, spacing: 0) {
            ForEach(0..<columnCount, id: \.self) { colIdx in
                let cell = colIdx < cells.count ? cells[colIdx] : ""
                let resolved = widths[colIdx] ?? 220
                Text(MarkdownTextView.renderInline(cell))
                    .font(isHeader
                          ? DS.text(fontSize - 1, .semibold)
                          : DS.text(fontSize - 2, .regular))
                    .foregroundStyle(isHeader ? DS.Ink.mint : .primary)
                    .tint(DS.Ink.mint)
                    .lineLimit(nil)
                    .multilineTextAlignment(textAlignment(colIdx))
                    .frame(maxWidth: resolved - 20, alignment: alignment(colIdx))
                    .frame(width: resolved)
                    .padding(.vertical, isHeader ? 8 : 6)
                    .textSelection(.enabled)
            }
        }
        .background(isHeader ? DS.Ink.mint.opacity(0.10) : Color.clear)
    }

    /// Per-column max width, capped at `colCap` (default 220pt).
    /// CJK / wide chars count as 2x. Columns whose natural content width
    /// exceeds the cap will wrap text inside the cell instead of growing wider.
    private func columnWidths() -> [Int: CGFloat] {
        let charWidth: CGFloat = 6.5
        let wideCharWidth: CGFloat = 13
        let floor: CGFloat = 80
        let cap: CGFloat = 220

        func textWidth(_ s: String) -> CGFloat {
            var w: CGFloat = 0
            for ch in s {
                w += ch.isASCII ? charWidth : wideCharWidth
            }
            return w
        }

        var natural: [Int: CGFloat] = [:]
        for (i, c) in header.enumerated() {
            natural[i] = max(natural[i, default: 0], textWidth(c))
        }
        for row in rows {
            for (i, c) in row.enumerated() {
                natural[i] = max(natural[i, default: 0], textWidth(c))
            }
        }
        // +20 for horizontal padding (10 each side)
        return natural.mapValues { min(max($0 + 20, floor), cap) }
    }

    private func textAlignment(_ idx: Int) -> TextAlignment {
        guard idx < aligns.count else { return .leading }
        return aligns[idx]
    }

    private func alignment(_ idx: Int) -> Alignment {
        guard idx < aligns.count else { return .leading }
        switch aligns[idx] {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        @unknown default: return .leading
        }
    }
}


struct CodeBlockView: View {
    let language: String
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !language.isEmpty {
                HStack {
                    Text(language)
                        .font(DS.mono(10, .semibold))
                        .foregroundStyle(DS.Canvas.phosphor.opacity(0.5))
                    Spacer()
                    Circle().fill(DS.Canvas.phosphor.opacity(0.3)).frame(width: 4, height: 4)
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 4)
                .background(DS.Canvas.terminal.opacity(0.85))
            }
            Text(code.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(DS.Canvas.phosphor)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.Canvas.terminal)
        }
        .clipShape(RoundedRectangle(cornerRadius: DS.R.sm, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.R.sm, style: .continuous)
                .stroke(Color.white.opacity(0.04), lineWidth: 0.5)
        )
    }
}
