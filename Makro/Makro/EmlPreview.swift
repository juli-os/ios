import Foundation

/// .eml 工件预览（2026-09-21 用户报：手机上打开邮件工件一堆奇怪的东西——
/// MIME 原文落进 video/黑屏分支）。最小 MIME 解析：头展开 + RFC2047 B/Q +
/// multipart 递归 + base64/QP 解码；**只解码 text/\* 部件**，附件只列名与
/// 近似体积（邮件常挂数 MB base64，解不动也不该解）。渲染成 HTML 走现成
/// HTMLPreviewView（WKWebView 本地串，与 html 工件同路）。
enum EmlPreview {

    struct View {
        var subject: String
        var from: String
        var to: String
        var cc: String
        var date: String
        var text: String
        var html: String
        var attachments: [(name: String, sizeLabel: String)]
        var rawSizeLabel: String
    }

    // ---- 解码原语 ---------------------------------------------------------

    private static func decoder(forCharset cs: String) -> String.Encoding {
        let name = cs.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'")).lowercased()
        if name.contains("gb") {
            let enc = CFStringEncodings.GB_18030_2000.rawValue
            let ns = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(enc))
            return String.Encoding(rawValue: ns)
        }
        return .utf8
    }

    private static func bytesToString(_ bytes: [UInt8], charset: String) -> String {
        String(bytes: bytes, encoding: decoder(forCharset: charset)) ?? String(decoding: bytes, as: UTF8.self)
    }

    private static func base64Bytes(_ s: String) -> [UInt8] {
        let clean = s.filter { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "/" || $0 == "=" }
        return Array(Data(base64Encoded: clean) ?? Data())
    }

    private static func qpBytes(_ s: String) -> [UInt8] {
        let noSoft = s.replacingOccurrences(of: "=\r\n", with: "")
            .replacingOccurrences(of: "=\n", with: "")
        var out: [UInt8] = []
        out.reserveCapacity(noSoft.utf8.count)
        let chars = Array(noSoft)
        var i = 0
        while i < chars.count {
            if chars[i] == "=", i + 2 < chars.count,
               let b = UInt8(String(chars[i + 1...i + 2]), radix: 16) {
                out.append(b)
                i += 3
            } else {
                out.append(chars[i].asciiValue ?? 0x3F)
                i += 1
            }
        }
        return out
    }

    /// RFC 2047：=?charset?B/Q?text?=（大小写不敏感，可连续多段）。
    static func decodeMimeWords(_ s: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "=\\?([^?]+)\\?([bBqQ])\\?([^?]*)\\?=") else { return s }
        let ns = s as NSString
        var out = ""
        var last = 0
        regex.enumerateMatches(in: s, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m = m else { return }
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let charset = ns.substring(with: m.range(at: 1))
            let enc = ns.substring(with: m.range(at: 2)).lowercased()
            let text = ns.substring(with: m.range(at: 3))
            if enc == "b" {
                out += bytesToString(base64Bytes(text), charset: charset)
            } else {
                out += bytesToString(qpBytes(text.replacingOccurrences(of: "_", with: " ")), charset: charset)
            }
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out.trimmingCharacters(in: .whitespaces)
    }

    // ---- 结构解析 ---------------------------------------------------------

    private struct Headers {
        private let pairs: [(name: String, value: String)]
        init(_ block: String) {
            let unfolded = block
                .replacingOccurrences(of: "\r\n ", with: " ")
                .replacingOccurrences(of: "\r\n\t", with: " ")
                .replacingOccurrences(of: "\n\t", with: " ")
            var pairs: [(String, String)] = []
            for line in unfolded.components(separatedBy: .newlines) {
                if let i = line.firstIndex(of: ":") {
                    pairs.append((String(line[..<i]).trimmingCharacters(in: .whitespaces).lowercased(),
                                  String(line[line.index(after: i)...]).trimmingCharacters(in: .whitespaces)))
                }
            }
            self.pairs = pairs
        }
        func value(_ name: String) -> String { pairs.first { $0.name == name }?.value ?? "" }
    }

    private static func param(_ value: String, _ name: String) -> String {
        guard let m = value.range(of: "\(name)\\s*=\\s*\"?([^\";]+)\"?", options: .regularExpression) else { return "" }
        let hit = value[m].replacingOccurrences(of: "\(name)=", with: "")
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        return hit
    }

    private struct Acc { var text = ""; var html = ""; var attachments: [(String, String)] = [] }

    private static func collect(_ headers: Headers, body: String, into acc: inout Acc, depth: Int) {
        guard depth < 8 else { return }
        let contentType = headers.value("content-type").isEmpty ? "text/plain; charset=utf-8" : headers.value("content-type")
        let encoding = headers.value("content-transfer-encoding").lowercased()
        let disposition = headers.value("content-disposition").lowercased()
        let boundary = param(contentType, "boundary")
        if !boundary.isEmpty {
            let parts = body
                .components(separatedBy: "--\(boundary)")
                .dropFirst()
            for part in parts {
                var chunk = part
                if chunk.hasSuffix("--") { chunk = String(chunk.dropLast(2)) }
                guard let cut = chunk.range(of: "\r\n\r\n") ?? chunk.range(of: "\n\n") else { continue }
                let head = String(chunk[..<cut.lowerBound])
                let bodyText = String(chunk[cut.upperBound...])
                collect(Headers(head), body: bodyText, into: &acc, depth: depth + 1)
            }
            return
        }
        let ctype = (contentType.components(separatedBy: ";").first ?? "text/plain")
            .trimmingCharacters(in: .whitespaces).lowercased()
        let filename = param(headers.value("content-disposition"), "filename")
        let isAttachment = disposition.hasPrefix("attachment")
        let plain = ctype == "text/plain"
        let html = ctype == "text/html"
        let charset = param(contentType, "charset").isEmpty ? "utf-8" : param(contentType, "charset")
        func decoded() -> String {
            if encoding == "base64" { return bytesToString(base64Bytes(body), charset: charset) }
            if encoding == "quoted-printable" { return bytesToString(qpBytes(body), charset: charset) }
            return body
        }
        if plain && !isAttachment {
            let t = decoded()
            acc.text = acc.text.isEmpty ? t : acc.text + "\n\n" + t
        } else if html && !isAttachment {
            if acc.html.isEmpty { acc.html = decoded() }
        } else {
            let approx = encoding == "base64" ? body.filter { $0.isLetter || $0.isNumber }.count * 3 / 4 : body.utf8.count
            acc.attachments.append((filename.isEmpty ? ctype : filename, humanSize(approx)))
        }
    }

    private static func humanSize(_ bytes: Int) -> String {
        bytes >= 1024 * 1024 ? String(format: "%.1f MB", Double(bytes) / 1024 / 1024)
            : bytes >= 1024 ? "\(bytes / 1024) KB" : "\(bytes) B"
    }

    static func parse(_ raw: String) -> View {
        guard let cut = raw.range(of: "\r\n\r\n") ?? raw.range(of: "\n\n") else {
            return View(subject: "(空邮件)", from: "", to: "", cc: "", date: "", text: "", html: "", attachments: [], rawSizeLabel: "0 B")
        }
        let headers = Headers(String(raw[..<cut.lowerBound]))
        let body = String(raw[cut.upperBound...])
        var acc = Acc()
        collect(headers, body: body, into: &acc, depth: 0)
        let decode = decodeMimeWords
        return View(
            subject: decode(headers.value("subject")).isEmpty ? "(无主题)" : decode(headers.value("subject")),
            from: decode(headers.value("from")),
            to: decode(headers.value("to")),
            cc: decode(headers.value("cc")),
            date: headers.value("date"),
            text: acc.text,
            html: acc.html,
            attachments: acc.attachments.map { ($0.0, $0.1) },
            rawSizeLabel: humanSize(raw.utf8.count)
        )
    }

    // ---- 渲染：生成 HTML 串，走现成 HTMLPreviewView（WKWebView 本地加载）--

    static func renderHTML(_ raw: String) -> String {
        let v = parse(raw)
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        var rows = ""
        for (k, val) in [("主题", v.subject), ("发件人", v.from), ("收件人", v.to), ("抄送", v.cc), ("时间", v.date)] where !val.isEmpty {
            rows += "<div class='row'><span class='k'>\(k)</span><span class='v'>\(esc(val))</span></div>"
        }
        let atts = v.attachments.isEmpty ? "" :
            "<div class='atts'>" + v.attachments.map { "<span class='att'>\(esc($0.name)) · \(esc($0.sizeLabel))</span>" }.joined() + "</div>"
        let body: String
        if !v.text.isEmpty {
            body = "<pre>\(esc(v.text))</pre>"
        } else if !v.html.isEmpty {
            body = "<iframe sandbox srcdoc=\"\(esc(v.html).replacingOccurrences(of: "\"", with: "&quot;"))\"></iframe>"
        } else {
            body = "<p class='muted'>(无可读正文部件)</p>"
        }
        return """
        <html><head><meta charset='utf-8'><meta name='viewport' content='width=device-width, initial-scale=1'>
        <style>
          body { margin: 0; padding: 14px; background: #FAFAF8; color: #1A1A1A;
                 font: 14px/1.55 -apple-system, 'PingFang SC', sans-serif; }
          .row { display: flex; gap: 10px; padding: 3px 0; }
          .k { color: #8E8C84; min-width: 52px; flex: none; font-size: 12px; padding-top: 1px; }
          .v { color: #1A1A1A; word-break: break-all; }
          .atts { display: flex; flex-wrap: wrap; gap: 6px; margin: 10px 0; }
          .att { background: #F3F1EB; color: #5C5A54; border-radius: 999px; padding: 4px 10px; font-size: 12px; }
          pre { white-space: pre-wrap; word-break: break-word; font: 14px/1.6 -apple-system, 'PingFang SC', sans-serif; }
          .muted { color: #8E8C84; font-size: 12px; }
          iframe { width: 100%; min-height: 220px; border: 1px solid #ECEAE3; border-radius: 10px; }
        </style></head><body>
        <div>\(rows)</div>\(atts)\(body)
        <p class='muted'>原始 eml 物证 · \(v.rawSizeLabel)</p>
        </body></html>
        """
    }
}
