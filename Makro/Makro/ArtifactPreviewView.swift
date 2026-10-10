import SwiftUI
import WebKit
import AVKit
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Previews a single artifact. HTML renders in a WKWebView loaded from local
/// string data; video downloads then plays via AVPlayer. Both load locally to
/// sidestep the self-signed TLS cert (WKWebView/AVPlayer don't share the
/// URLSession's pinned trust, so remote fetch would fail cert validation).
struct ArtifactPreviewView: View {
    let artifact: Artifact

    /// Threshold of the board-13 global "large attachment 50MB gate".
    static let sizeGateBytes: Int64 = 50 * 1024 * 1024

    @State private var loadState: LoadState = .loading
    // Owning-job banner and jump-back (wf_1bc08ecd4184, option A v2: the
    // title shows in full without truncation; the wfId stays out of the
    // display layer — used for navigation only). Legacy makro artifacts have
    // no workflow key; no banner is shown.
    @StateObject private var caseVM = LifecycleViewModel()
    @State private var showCase = false
    @State private var sharing = false
    @State private var shareError: String?
    @State private var showShareError = false
    @State private var sharedURL = ""
    @State private var showQR = false

    enum LoadState: Equatable {
        case loading
        case htmlString(String)
        case videoURL(URL)
        case imageData(Data)
        case pdfURL(URL)
        case quickLookURL(URL)
        case failed(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let wf = artifact.workflow {
                Button {
                    Task { await caseVM.select(wf.id) }
                    showCase = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(DS.Ink.mintDeep)
                        Text(wf.title)
                            .font(DS.mono(11, .medium))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(FlowStatus.label(wf.status))
                            .font(DS.mono(10, .semibold))
                            .foregroundStyle(FlowStatus.color(wf.status))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(DS.Canvas.inset)
                    .clipShape(RoundedRectangle(cornerRadius: DS.R.md, style: .continuous))
                    .padding(.horizontal, 12).padding(.top, 6)
                }
                .sheet(isPresented: $showCase) {
                    WorkflowDetailSheet(vm: caseVM, workflowID: wf.id)
                        .presentationDetents([.large])
                }
            }
            Group {
                switch loadState {
            case .loading:
                ProgressView("Loading…")
            case .htmlString(let html):
                HTMLPreviewView(html: html)
            case .videoURL(let url):
                VideoPreviewView(url: url)
            case .imageData(let data):
                ImagePreviewView(data: data)
            case .pdfURL(let url):
                PDFPreviewView(url: url)
            case .quickLookURL(let url):
                QuickLookPreview(url: url)
            case .failed(let msg):
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 28))
                        .foregroundStyle(DS.Ink.amber)
                    Text(msg)
                        .font(DS.text(13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 32)
            }
            }
        }
        .navigationTitle(artifact.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadContent() }
        .toolbar {
            // Share: uploads to OSS (server-side) + pops a QR sheet with the
            // presigned URL. Mac backend must be reachable + OSS creds configured.
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await shareArtifact() }
                } label: {
                    if sharing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                .disabled(sharing)
                .accessibilityLabel("Share")
            }
        }
        .alert("Share failed", isPresented: $showShareError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(shareError ?? "")
        }
        .sheet(isPresented: $showQR) {
            ShareQRView(url: sharedURL)
        }
    }

    private func loadContent() async {
        // Large-attachment gate (boards 09+13): no pointless multi-MB download
        // on the phone — the preview surface says "file too large (XMB) —
        // best viewed on desktop" right away, saving both traffic and waiting
        // at the entry point.
        if artifact.size > Self.sizeGateBytes {
            let mb = Double(artifact.size) / 1024 / 1024
            await MainActor.run {
                loadState = .failed(String(format: "File too large (%.0fMB)\nbest viewed on desktop", mb))
            }
            return
        }
        do {
            let data = try await APIClient.shared.fetchArtifactContent(session: artifact.session, path: artifact.path)
            if artifact.name.lowercased().hasSuffix(".eml") {
                // Email evidence (2026-09-21 user report: opening an eml
                // showed a pile of weirdness) — the raw MIME used to fall
                // into the video branch; when a header card + readable body
                // parse out, go through the HTML preview.
                let raw = String(data: data, encoding: .utf8) ?? ""
                let html = EmlPreview.renderHTML(raw)
                await MainActor.run { loadState = .htmlString(html) }
                return
            }
            // Multi-format rich-text viewing (wf_b93d083f6682, 2026-10-05):
            // previously md/json/images/pdf/office all fell into the video
            // branch (AVPlayer cannot play them = black screen), and the
            // PDF/QuickLook components were never wired up. Here predicates
            // dispatch to each rich view.
            // R1 P1-1: the extension predicates must sit entirely before
            // isHTML — the server's artifactEntryType returns "html" for
            // anything non-video (artifacts.ts:29-32); putting isHTML first
            // would swallow md/json/txt/images/pdf/office into the bare HTML
            // branch, leaving the later dispatch as dead code.
            if artifact.isMarkdown {
                let md = String(data: data, encoding: .utf8) ?? ""
                await MainActor.run { loadState = .htmlString(MarkdownRenderer.render(md, title: artifact.name)) }
                return
            }
            if artifact.isJSON {
                let raw = String(data: data, encoding: .utf8) ?? ""
                await MainActor.run { loadState = .htmlString(JSONFormatterView.render(raw, title: artifact.name)) }
                return
            }
            if artifact.isTextLike {
                let raw = String(data: data, encoding: .utf8) ?? ""
                await MainActor.run { loadState = .htmlString(RichTextShell.render(raw, title: artifact.name)) }
                return
            }
            if artifact.isImage {
                await MainActor.run { loadState = .imageData(data) }
                return
            }
            if artifact.isPDF || artifact.isOffice {
                // PDFKit / QuickLook both need a local file URL — write a temp file (same route as the video branch).
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent(artifact.name)
                try data.write(to: tmp)
                await MainActor.run { loadState = artifact.isPDF ? .pdfURL(tmp) : .quickLookURL(tmp) }
                return
            }
            if artifact.isZipLike {
                await MainActor.run {
                    loadState = .failed("Open archives on desktop\n(share via the top-right exports the file)")
                }
                return
            }
            // Bare HTML artifacts (.html/.htm, type=="html"): the existing
            // rendering path unchanged — reaching here means no rich-format
            // extension matched (R1 P1-1).
            if artifact.isHTML {
                let html = String(data: data, encoding: .utf8) ?? ""
                await MainActor.run { loadState = .htmlString(html) }
                return
            }
            // Video (existing behavior): AVPlayer needs a file URL, not raw Data.
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent(artifact.name)
            try data.write(to: tmp)
            await MainActor.run { loadState = .videoURL(tmp) }
        } catch {
            await MainActor.run { loadState = .failed(error.localizedDescription) }
        }
    }

    /// Requests a share link for the ledger artifact (server mints a 1h
    /// HMAC-signed URL) then pops a QR sheet. Artifacts without a ledger id
    /// (legacy central-store files) are not shareable — explicit error.
    private func shareArtifact() async {
        sharing = true
        defer { sharing = false }
        guard let artifactId = artifact.ledgerId else {
            await MainActor.run {
                shareError = "This artifact is not in the ledger (legacy file) — no share link can be generated"
                showShareError = true
            }
            return
        }
        do {
            let res = try await APIClient.shared.shareArtifact(id: artifactId)
            await MainActor.run {
                sharedURL = res.url
                showQR = true
            }
        } catch {
            await MainActor.run {
                shareError = error.localizedDescription
                showShareError = true
            }
        }
    }
}

// MARK: - Share QR sheet

/// Shows a QR for the share URL + copy / system-share actions. The QR encodes
/// the presigned URL directly (OSS V1 signature is over the path+expires, so
/// the recipient scans → opens the exact signed link).
struct ShareQRView: View {
    let url: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if let qr = generateQRImage(from: url) {
                        Image(uiImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 232, height: 232)
                            .padding(16)
                            .background(Color.white)
                            .cornerRadius(14)
                            .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
                    } else {
                        Image(systemName: "qrcode")
                            .font(.system(size: 64))
                            .foregroundStyle(.tertiary)
                            .frame(width: 232, height: 232)
                    }
                    Text("Scan to view on a phone")
                        .font(DS.text(14, .medium))
                        .foregroundStyle(.secondary)

                    Text(url)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .padding(.horizontal, 24)
                        .textSelection(.enabled)

                    HStack(spacing: 12) {
                        Button {
                            UIPasteboard.general.string = url
                        } label: {
                            Label("Copy link", systemImage: "doc.on.doc")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        Button {
                            // MUST pass a URL object (not a String) — WeChat only
                            // card-generates for URL share items; a String is treated
                            // as plain text (no link preview).
                            if let u = URL(string: url) { presentShareSheet(items: [u]) }
                        } label: {
                            Label("Share via…", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                }
                .padding(.vertical, 28)
            }
            .background(DS.Canvas.app.ignoresSafeArea())
            .navigationTitle("Share")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// Generates a QR UIImage for the string via CoreImage (built into iOS, no
/// external dep). correctionLevel "M" balances density + damage tolerance.
func generateQRImage(from string: String, scale: CGFloat = 8) -> UIImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(string.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) else {
        return nil
    }
    let context = CIContext()
    guard let cg = context.createCGImage(output, from: output.extent) else { return nil }
    return UIImage(cgImage: cg)
}

/// Presents the system share sheet (WeChat / mail / AirDrop / copy) from the
/// topmost view controller.
func presentShareSheet(items: [Any]) {
    guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
          let root = scene.windows.first?.rootViewController else { return }
    let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
    var top = root
    while let p = top.presentedViewController { top = p }
    top.present(vc, animated: true)
}

// MARK: - HTML preview

/// Wraps WKWebView in SwiftUI. Loads HTML from a string so no remote request
/// is made — the self-signed cert never comes into play.
struct HTMLPreviewView: UIViewRepresentable {
    let html: String

    /// Viewport adaptation (wf_8cfa4772fc03): external artifact HTML without
    /// a viewport meta renders at the 980px desktop width — the phone sees
    /// only a left-edge sliver = unviewable. Inject/replace a device-width
    /// viewport uniformly; no user-scalable=no, so pinch zoom stays (wide
    /// archify canvas artifacts can still be zoomed in for detail).
    static func mobileHTML(_ html: String) -> String {
        let meta = #"<meta name="viewport" content="width=device-width, initial-scale=1">"#
        if let r = html.range(of: #"<meta[^>]*viewport[^>]*>"#, options: .regularExpression) {
            return html.replacingCharacters(in: r, with: meta)
        }
        if let r = html.range(of: #"<head[^>]*>"#, options: .regularExpression) {
            var s = html
            s.insert(contentsOf: meta, at: r.upperBound)
            return s
        }
        return meta + html
    }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        let view = WKWebView(frame: .zero, configuration: cfg)
        view.loadHTMLString(Self.mobileHTML(html), baseURL: nil)
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // Reload only if the HTML actually changed (compare on the adapted
        // string so the coordinator baseline matches what was loaded).
        let adapted = Self.mobileHTML(html)
        if context.coordinator.lastHTML != adapted {
            uiView.loadHTMLString(adapted, baseURL: nil)
            context.coordinator.lastHTML = adapted
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastHTML: String?
    }
}

// MARK: - Video preview

/// Plays a local video file with AVPlayer. Local file URL avoids the
/// self-signed TLS issue entirely. The player is created on first appear so
/// AVPlayerItem is bound to the resolved file URL.
struct VideoPreviewView: View {
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
            } else {
                ProgressView("Preparing to play…")
            }
        }
        .onAppear {
            if player == nil {
                let p = AVPlayer(url: url)
                player = p
                p.play()
            }
        }
        .onDisappear {
            player?.pause()
        }
    }
}

// MARK: - PDF preview (PDFKit: paging/zoom/thumbnails/search come native, zero dependencies)
// Fed a local file URL — the same authenticated-download → temp-file →
// local-render pipeline as HTML/video; a remote URL would hit the
// self-signed TLS pinning.

import PDFKit

struct PDFPreviewView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.document = PDFDocument(url: url)
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {}
}

// MARK: - QuickLook (the system-level read-only previewer for docx/xlsx/pptx and other office formats)
// Best practice for iOS document viewing — the same route as
// Dropbox/Slack, no third-party dependencies.

import QuickLook

struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}

// MARK: - Image preview (wf_b93d083f6682: images previously fell into the video branch, black screen)
// Fit-to-screen + pinch zoom + double-tap reset; large images auto-fit,
// small ones shown centered at native size.

struct ImagePreviewView: View {
    let data: Data
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1

    var body: some View {
        if let ui = UIImage(data: data) {
            GeometryReader { geo in
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFit()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .scaleEffect(scale)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { v in
                                scale = min(max(lastScale * v, 1), 6)
                            }
                            .onEnded { _ in lastScale = scale }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(DS.spring) { scale = 1; lastScale = 1 }
                    }
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "photo")
                    .font(.system(size: 28))
                    .foregroundStyle(DS.Ink.amber)
                Text("Image decode failed (unsupported format?)")
                    .font(DS.text(13))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Text-family rich reading shell (wf_b93d083f6682, 2026-10-05)
// Three renderers share the same juli-toned CSS shell; the body is injected
// JSON-encoded, eliminating injection.

enum RichShell {
    static func page(title: String, bodyHTML: String) -> String {
        """
        <!DOCTYPE html><html lang="zh-CN"><head><meta charset="UTF-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>\(title)</title>
        <style>
        :root{--bg:#FAFAF8;--card:#FFF;--ink:#1A1A1A;--body:#5C5A54;--dim:#8E8C84;
        --line:rgba(26,26,26,.08);--c:#D97C26;--c-deep:#B8681A;--c-soft:rgba(217,124,38,.07);
        --mono:'SF Mono','JetBrains Mono',Menlo,monospace;
        --sans:-apple-system,'PingFang SC','Helvetica Neue',Arial,sans-serif}
        *{margin:0;padding:0;box-sizing:border-box}
        body{background:var(--bg);color:var(--ink);font-family:var(--sans);
        line-height:1.75;font-size:15.5px;padding:18px 16px 48px}
        h1,h2,h3,h4{line-height:1.35;margin:1.2em 0 .5em;letter-spacing:-.3px}
        h1{font-size:1.55em}h2{font-size:1.3em;border-bottom:1px solid var(--line);padding-bottom:.25em}
        h3{font-size:1.12em}h4{font-size:1em}
        p{margin:.6em 0;color:var(--body)}
        a{color:var(--c-deep)}
        code{font-family:var(--mono);font-size:.86em;background:var(--c-soft);
        color:var(--c-deep);padding:2px 5px;border-radius:4px;word-break:break-all}
        pre{background:var(--card);border:1px solid var(--line);border-radius:10px;
        padding:14px;overflow-x:auto;margin:.8em 0}
        pre code{background:none;padding:0;font-size:12.5px;line-height:1.6;color:var(--ink)}
        blockquote{border-left:3px solid var(--c);padding:2px 0 2px 14px;margin:.8em 0;color:var(--body)}
        ul,ol{margin:.6em 0 .6em 1.4em;color:var(--body)}
        li{margin:.3em 0}
        table{border-collapse:collapse;margin:1em 0;font-size:.9em;width:100%}
        th,td{border:1px solid var(--line);padding:7px 10px;text-align:left}
        th{background:var(--c-soft);color:var(--ink);font-weight:600}
        td{color:var(--body)}
        hr{border:none;border-top:1px solid var(--line);margin:1.4em 0}
        .shell-head{font-family:var(--mono);font-size:11px;color:var(--dim);
        letter-spacing:1px;margin-bottom:14px;word-break:break-all}
        </style></head><body>
        <div class="shell-head">\(title)</div>
        \(bodyHTML)
        </body></html>
        """
    }

    /// Swift-side safe injection: the body goes in as a single text node
    /// inside <script>, read and placed by each renderer's own script after
    /// it defines its render function (mk-out) — avoids splicing the body
    /// into the HTML structure and causing tag injection/XSS. (R1 P1-2: the
    /// old place parameter was never interpolated; removed.)
    static func safeBodySlot(payloadJSON: String) -> String {
        """
        <script id="mk-payload" type="application/json">\(payloadJSON)</script>
        <div id="mk-out">…</div>
        """
    }
}

// MARK: - Markdown renderer (hand-written lightweight md→HTML, ~zero dependencies)

enum MarkdownRenderer {
    static func render(_ md: String, title: String) -> String {
        let payload = jsonString(md)
        return RichShell.page(title: title, bodyHTML: RichShell.safeBodySlot(
            payloadJSON: payload
        ) + """
        <script>
        window.__md = function(src){
          const esc = s => s.replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;");
          const inl = s => esc(s)
            .replace(/`([^`]+)`/g,(m,c)=>"<code>"+c+"</code>")
            .replace(/!\\[([^\\]]*)\\]\\(([^)\\s]+)\\)/g,'<em>[$1]</em>')
            .replace(/\\[([^\\]]+)\\]\\(([^)\\s]+)\\)/g,'<a href="$2" target="_blank" rel="noopener">$1</a>')
            .replace(/\\*\\*([^*]+)\\*\\*/g,"<strong>$1</strong>")
            .replace(/(^|\\W)\\*([^*\\n]+)\\*(?=\\W|$)/g,"$1<em>$2</em>");
          const lines = src.split("\\n"); let out = [], i = 0;
          const flushList = (tag, items) => out.push("<"+tag+">"+items.map(t=>"<li>"+t+"</li>").join("")+"</"+tag+">");
          while (i < lines.length) {
            const L = lines[i];
            if (/^```/.test(L)) {
              let buf = []; i++;
              while (i < lines.length && !/^```/.test(lines[i])) { buf.push(lines[i]); i++; }
              i++; out.push("<pre><code>"+esc(buf.join("\\n"))+"</code></pre>"); continue;
            }
            let m;
            if ((m = L.match(/^(#{1,4})\\s+(.*)$/))) { out.push("<h"+m[1].length+">"+inl(m[2])+"</h"+m[1].length+">"); i++; continue; }
            if (/^(-{3,}|\\*{3,})$/.test(L.trim())) { out.push("<hr>"); i++; continue; }
            if ((m = L.match(/^\\s*[-*+]\\s+(.*)$/))) {
              let items = [];
              while (i < lines.length && (m = lines[i].match(/^\\s*[-*+]\\s+(.*)$/))) { items.push(inl(m[1])); i++; }
              flushList("ul", items); continue;
            }
            if ((m = L.match(/^\\s*\\d+[.)]\\s+(.*)$/))) {
              let items = [];
              while (i < lines.length && (m = lines[i].match(/^\\s*\\d+[.)]\\s+(.*)$/))) { items.push(inl(m[1])); i++; }
              flushList("ol", items); continue;
            }
            if (/^>\\s?/.test(L)) {
              let buf = [];
              while (i < lines.length && /^>\\s?/.test(lines[i])) { buf.push(inl(lines[i].replace(/^>\\s?/,""))); i++; }
              out.push("<blockquote>"+buf.join("<br>")+"</blockquote>"); continue;
            }
            if (L.includes("|") && i+1 < lines.length && /^\\s*\\|?[\\s:|-]+\\|\\s*$/.test(lines[i+1])) {
              const cells = r => r.replace(/^\\s*\\|/,"").replace(/\\|\\s*$/,"").split("|").map(c=>c.trim());
              let head = cells(L); i += 2; let rows = [];
              while (i < lines.length && lines[i].includes("|")) { rows.push(cells(lines[i])); i++; }
              out.push("<table><thead><tr>"+head.map(h=>"<th>"+inl(h)+"</th>").join("")+"</tr></thead><tbody>"
                + rows.map(r=>"<tr>"+r.map(c=>"<td>"+inl(c)+"</td>").join("")+"</tr>").join("")+"</tbody></table>");
              continue;
            }
            if (!L.trim()) { i++; continue; }
            let buf = [inl(L)]; i++;
            while (i < lines.length && lines[i].trim() && !/^(#{1,4}\\s|```|\\s*[-*+]\\s|\\s*\\d+[.)]\\s|>)/.test(lines[i])) { buf.push(inl(lines[i])); i++; }
            out.push("<p>"+buf.join("<br>")+"</p>");
          }
          return out.join("\\n");
        };
        // R1 P1-2: the fill-in landed — previously __md was only defined, never called, so md previews were stuck on the "…" placeholder.
        const P = JSON.parse(document.getElementById("mk-payload").textContent);
        document.getElementById("mk-out").innerHTML = window.__md(P.text);
        </script>
        """)
    }

    private static func jsonString(_ s: String) -> String {
        let d = (try? JSONEncoder().encode([s])) ?? Data("[]".utf8)
        return String(data: d.dropFirst().dropLast(), encoding: .utf8) ?? "\"\""
    }
}

// MARK: - JSON formatted view (recursive collapsible tree + type coloring + stats; falls back to raw text on failure)

enum JSONFormatterView {
    static func render(_ raw: String, title: String) -> String {
        let payload = MarkdownRenderer.jsonStringExport(raw)
        return RichShell.page(title: title, bodyHTML: RichShell.safeBodySlot(
            payloadJSON: payload
        ) + """
        <style>
        .jf-root{font-family:var(--mono);font-size:12.5px;line-height:1.7}
        .jf-item{padding-left:14px;border-left:1px dashed var(--line)}
        .jf-row{display:block;padding:1px 0}
        .jf-caret{cursor:pointer;user-select:none;color:var(--c-deep);margin-right:4px;font-size:10px}
        .jf-k{color:#8E6BB8}.jf-s{color:#2E7D32}.jf-n{color:#B8681A}
        .jf-b{color:#B3382A}.jf-nul{color:var(--dim)}
        .jf-meta{font-family:var(--mono);font-size:11px;color:var(--dim);margin:0 0 12px}
        .jf-collapsed>.jf-item{display:none}
        .jf-err{white-space:pre-wrap;font-family:var(--mono);font-size:12px;color:var(--body);
        background:var(--card);border:1px solid var(--line);border-radius:10px;padding:14px}
        </style>
        <script>
        window.__jf = function(text){
          let v; try { v = JSON.parse(text); } catch (e) {
            return '<div class="jf-err">⚠️ JSON parse failed ('+esc(e.message)+'), raw text follows:\\n\\n'+esc(text)+'</div>';
          }
          const esc = s => String(s).replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;");
          let counts = {obj:0,arr:0,str:0,num:0,bool:0,nul:0};
          const node = (k, val, depth) => {
            let head = "";
            if (k !== null) head += '<span class="jf-k">'+esc(k)+'</span>: ';
            if (Array.isArray(val)) {
              counts.arr++;
              return '<div class="jf-row"><span class="jf-caret" onclick="this.parentElement.classList.toggle(\'jf-collapsed\')">▾</span>'
                + head + '[<span style="color:var(--dim)">'+val.length+'</span>]'
                + '<div class="jf-item">' + val.map(x => node(null, x, depth+1)).join("") + '</div>]</div>';
            }
            if (val && typeof val === "object") {
              counts.obj++;
              const ks = Object.keys(val);
              return '<div class="jf-row"><span class="jf-caret" onclick="this.parentElement.classList.toggle(\'jf-collapsed\')">▾</span>'
                + head + '{<span style="color:var(--dim)">'+ks.length+'</span>'
                + '<div class="jf-item">' + ks.map(kk => node(kk, val[kk], depth+1)).join("") + '</div>}</div>';
            }
            if (typeof val === "string") { counts.str++; return '<div class="jf-row">'+head+'<span class="jf-s">"'+esc(val)+'"</span></div>'; }
            if (typeof val === "number") { counts.num++; return '<div class="jf-row">'+head+'<span class="jf-n">'+val+'</span></div>'; }
            if (typeof val === "boolean") { counts.bool++; return '<div class="jf-row">'+head+'<span class="jf-b">'+val+'</span></div>'; }
            counts.nul++; return '<div class="jf-row">'+head+'<span class="jf-nul">null</span></div>';
          };
          const tree = node(null, v, 0);
          return '<p class="jf-meta">📦 objects '+counts.obj+' · arrays '+counts.arr+' · strings '+counts.str
            + ' · numbers '+counts.num+' · booleans '+counts.bool+' · null '+counts.nul
            + ' (▾ collapsible)</p><div class="jf-root">'+tree+'</div>';
        };
        const __P = JSON.parse(document.getElementById("mk-payload").textContent);
        document.getElementById("mk-out").innerHTML = window.__jf(__P.text);
        </script>
        """)
    }
}

// MARK: - Rich-text shell (txt/log/csv etc.: monospaced reading, no more bare files)

enum RichTextShell {
    static func render(_ raw: String, title: String) -> String {
        let payload = MarkdownRenderer.jsonStringExport(raw)
        return RichShell.page(title: title, bodyHTML: RichShell.safeBodySlot(
            payloadJSON: payload
        ) + """
        <script>window.__esc = s => s.replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;");
        const _o=document.getElementById("mk-out");
        document.getElementById("mk-out").innerHTML = (function(){
          const P = JSON.parse(document.getElementById("mk-payload").textContent);
          return '<pre style="white-space:pre-wrap;word-break:break-word;font-family:var(--mono);font-size:12.5px;line-height:1.7;color:var(--ink);background:var(--card);border:1px solid var(--line);border-radius:10px;padding:14px">'+window.__esc(P.text).replace(/\\n/g,"<br>")+'</pre>';
        })();
        </script>
        """)
    }
}

extension MarkdownRenderer {
    /// Safe-encode a JSON string (wrap as a single string then strip the brackets, for safeBodySlot injection).
    static func jsonStringExport(_ s: String) -> String {
        jsonString(s)
    }
}
