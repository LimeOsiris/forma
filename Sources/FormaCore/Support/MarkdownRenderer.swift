import Foundation

/// A small, dependency-free Markdown → HTML renderer covering CommonMark essentials
/// plus GitHub tables, strikethrough and task lists. Raw HTML in the source is escaped,
/// never passed through, so previews can't run scripts.
public struct MarkdownRenderer: Sendable {
    public init() {}

    // MARK: - Public API

    /// The HTML body fragment.
    public func renderBody(_ markdown: String) -> String {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\t", with: "    ")
            .components(separatedBy: "\n")
        return renderBlocks(lines[...])
    }

    /// A complete, standalone HTML document with readable typography that also prints well.
    public func renderDocument(_ markdown: String, title: String, forPrint: Bool = false) -> String {
        """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="generator" content="Forma">
        <title>\(escape(title))</title>
        <style>
        \(forPrint ? Self.printCSS : Self.screenCSS)
        </style>
        </head>
        <body>
        <article>
        \(renderBody(markdown))
        </article>
        </body>
        </html>
        """
    }

    static let sharedCSS = """
    body { font-family: -apple-system, "Helvetica Neue", Helvetica, Arial, sans-serif; line-height: 1.55; }
    h1, h2, h3, h4, h5, h6 { line-height: 1.25; margin: 1.4em 0 0.5em; font-weight: 600; }
    h1 { font-size: 2em; } h2 { font-size: 1.5em; } h3 { font-size: 1.25em; } h4 { font-size: 1.05em; }
    p, ul, ol, blockquote, pre, table { margin: 0 0 1em; }
    code, pre { font-family: "SF Mono", Menlo, Monaco, monospace; font-size: 0.9em; }
    pre { padding: 12px 14px; border-radius: 8px; overflow-x: auto; }
    blockquote { margin-left: 0; padding-left: 1em; }
    table { border-collapse: collapse; }
    th, td { padding: 6px 12px; text-align: left; }
    img { max-width: 100%; }
    hr { border: none; height: 1px; margin: 2em 0; }
    li.task { list-style: none; margin-left: -1.3em; }
    """

    static let screenCSS = sharedCSS + """

    :root { color-scheme: light dark; }
    body { max-width: 46em; margin: 3em auto; padding: 0 1.5em; color: #1d1d1f; background: #fff; font-size: 16px; }
    a { color: #0066cc; }
    code { background: rgba(0,0,0,0.05); padding: 0.1em 0.3em; border-radius: 4px; }
    pre { background: #f5f5f7; } pre code { background: none; padding: 0; }
    blockquote { border-left: 3px solid #d2d2d7; color: #6e6e73; }
    th, td { border: 1px solid #d2d2d7; } th { background: #f5f5f7; }
    hr { background: #d2d2d7; }
    @media (prefers-color-scheme: dark) {
      body { color: #f5f5f7; background: #1d1d1f; }
      a { color: #2997ff; }
      code { background: rgba(255,255,255,0.08); } pre { background: #2c2c2e; }
      blockquote { border-left-color: #48484a; color: #a1a1a6; }
      th, td { border-color: #48484a; } th { background: #2c2c2e; } hr { background: #48484a; }
    }
    """

    static let printCSS = sharedCSS + """

    body { color: #111; font-size: 11pt; }
    a { color: #0645ad; }
    code { background-color: #f2f2f2; }
    pre { background-color: #f2f2f2; }
    blockquote { border-left: 3px solid #ccc; color: #555; }
    th, td { border: 1px solid #bbb; } th { background-color: #f2f2f2; }
    hr { background-color: #ccc; }
    """

    // MARK: - Blocks

    private func renderBlocks(_ lines: ArraySlice<String>) -> String {
        var out: [String] = []
        var i = lines.startIndex
        var paragraph: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let text = paragraph.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
            out.append("<p>\(renderInline(text))</p>")
            paragraph.removeAll()
        }

        while i < lines.endIndex {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = line.prefix { $0 == " " }.count

            if trimmed.isEmpty { flushParagraph(); i += 1; continue }

            // Fenced code
            if indent < 4, let fence = Self.fence(trimmed) {
                flushParagraph()
                let lang = trimmed.dropFirst(fence.count).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.endIndex, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(String(lines[i].dropFirst(min(indent, lines[i].prefix { $0 == " " }.count))))
                    i += 1
                }
                i += 1
                let cls = lang.isEmpty ? "" : " class=\"language-\(escape(String(lang.split(separator: " ").first ?? "")))\""
                out.append("<pre><code\(cls)>\(escape(code.joined(separator: "\n")))</code></pre>")
                continue
            }

            // Indented code (not inside a paragraph)
            if indent >= 4 && paragraph.isEmpty {
                var code: [String] = []
                while i < lines.endIndex, lines[i].prefix(while: { $0 == " " }).count >= 4 || lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    code.append(String(lines[i].dropFirst(4)))
                    i += 1
                }
                while code.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { code.removeLast() }
                out.append("<pre><code>\(escape(code.joined(separator: "\n")))</code></pre>")
                continue
            }

            // ATX heading
            if let (level, text) = Self.atxHeading(trimmed) {
                flushParagraph()
                out.append("<h\(level) id=\"\(Self.slug(text))\">\(renderInline(text))</h\(level)>")
                i += 1
                continue
            }

            // Setext heading
            if !paragraph.isEmpty, indent < 4, !trimmed.isEmpty,
               trimmed.allSatisfy({ $0 == "=" }) || (trimmed.allSatisfy({ $0 == "-" }) && trimmed.count >= 2) {
                let level = trimmed.first == "=" ? 1 : 2
                let text = paragraph.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
                paragraph.removeAll()
                out.append("<h\(level) id=\"\(Self.slug(text))\">\(renderInline(text))</h\(level)>")
                i += 1
                continue
            }

            // Thematic break
            if Self.isThematicBreak(trimmed) {
                flushParagraph()
                out.append("<hr>")
                i += 1
                continue
            }

            // Blockquote
            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while i < lines.endIndex {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix(">") {
                        var rest = t.dropFirst()
                        if rest.first == " " { rest = rest.dropFirst() }
                        quoted.append(String(rest))
                    } else if !t.isEmpty, !quoted.isEmpty, !(quoted.last ?? "").isEmpty {
                        quoted.append(t) // lazy continuation
                    } else { break }
                    i += 1
                }
                out.append("<blockquote>\n\(renderBlocks(quoted[...]))\n</blockquote>")
                continue
            }

            // Table
            if i + 1 < lines.endIndex, trimmed.contains("|"), Self.isTableSeparator(lines[i + 1]) {
                flushParagraph()
                let header = Self.tableCells(trimmed)
                let aligns = Self.tableCells(lines[i + 1].trimmingCharacters(in: .whitespaces)).map(Self.alignment)
                i += 2
                var rows: [[String]] = []
                while i < lines.endIndex {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard !t.isEmpty, t.contains("|") else { break }
                    rows.append(Self.tableCells(t))
                    i += 1
                }
                func cell(_ tag: String, _ text: String, _ col: Int) -> String {
                    let a = col < aligns.count ? aligns[col] : nil
                    return "<\(tag)\(a.map { " style=\"text-align: \($0)\"" } ?? "")>\(renderInline(text))</\(tag)>"
                }
                var html = "<table>\n<thead>\n<tr>" + header.enumerated().map { cell("th", $1, $0) }.joined() + "</tr>\n</thead>\n"
                if !rows.isEmpty {
                    html += "<tbody>\n" + rows.map { row in
                        "<tr>" + (0..<header.count).map { cell("td", $0 < row.count ? row[$0] : "", $0) }.joined() + "</tr>"
                    }.joined(separator: "\n") + "\n</tbody>\n"
                }
                out.append(html + "</table>")
                continue
            }

            // Lists
            if let marker = Self.listMarker(line), paragraph.isEmpty || marker.ordered == false || marker.start == 1 {
                flushParagraph()
                let (html, next) = renderList(lines, from: i, marker: marker)
                out.append(html)
                i = next
                continue
            }

            paragraph.append(line)
            i += 1
        }
        flushParagraph()
        return out.joined(separator: "\n")
    }

    struct ListMarker {
        var ordered: Bool
        var start: Int
        var indent: Int
        /// Column where the item's content begins.
        var contentColumn: Int
        var bullet: Character
    }

    static func listMarker(_ line: String) -> ListMarker? {
        let indent = line.prefix { $0 == " " }.count
        guard indent < 4 || true else { return nil }
        let rest = line.dropFirst(indent)
        if let c = rest.first, "-*+".contains(c) {
            let after = rest.dropFirst()
            if after.isEmpty { return ListMarker(ordered: false, start: 1, indent: indent, contentColumn: indent + 2, bullet: c) }
            if after.first == " " {
                if isThematicBreak(String(rest)) { return nil }
                let spaces = min(4, after.prefix { $0 == " " }.count)
                return ListMarker(ordered: false, start: 1, indent: indent, contentColumn: indent + 1 + spaces, bullet: c)
            }
            return nil
        }
        let digits = rest.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 9 else { return nil }
        let after = rest.dropFirst(digits.count)
        guard let delim = after.first, delim == "." || delim == ")" else { return nil }
        let tail = after.dropFirst()
        guard tail.isEmpty || tail.first == " " else { return nil }
        let spaces = min(4, max(1, tail.prefix { $0 == " " }.count))
        return ListMarker(ordered: true, start: Int(digits) ?? 1, indent: indent, contentColumn: indent + digits.count + 1 + spaces, bullet: delim)
    }

    private func renderList(_ lines: ArraySlice<String>, from start: Int, marker first: ListMarker) -> (String, Int) {
        var items: [[String]] = []
        var i = start
        var loose = false
        var sawBlank = false
        while i < lines.endIndex {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                sawBlank = true
                items[items.count - 1].append("")
                i += 1
                continue
            }
            let indent = line.prefix { $0 == " " }.count
            if let m = Self.listMarker(line), m.ordered == first.ordered, indent < first.contentColumn, abs(indent - first.indent) <= 3 {
                if sawBlank && !items.isEmpty { loose = true }
                sawBlank = false
                let content = String(line.dropFirst(min(line.count, m.contentColumn)))
                items.append([content])
                i += 1
                continue
            }
            if indent >= first.contentColumn || (!sawBlank && !items.isEmpty && Self.listMarker(line) == nil && !Self.isThematicBreak(trimmed) && Self.atxHeading(trimmed) == nil) {
                if sawBlank { loose = true }
                sawBlank = false
                let strip = min(indent, first.contentColumn)
                items[items.count - 1].append(String(line.dropFirst(strip)))
                i += 1
                continue
            }
            break
        }
        // Trailing blank lines belong to whatever follows the list.
        while let last = items.last?.last, last.isEmpty { items[items.count - 1].removeLast() }
        if loose == false {
            loose = items.contains { item in
                // A blank line between blocks inside one item also makes the list loose.
                guard let blank = item.firstIndex(of: "") else { return false }
                return item[blank...].contains { !$0.isEmpty && Self.listMarker($0) == nil }
            }
        }

        let tag = first.ordered ? "ol" : "ul"
        let startAttr = first.ordered && first.start != 1 ? " start=\"\(first.start)\"" : ""
        var html = "<\(tag)\(startAttr)>\n"
        for item in items {
            var lines = item
            var liClass = ""
            var prefix = ""
            if !first.ordered, let head = lines.first {
                if head.hasPrefix("[ ] ") || head == "[ ]" {
                    prefix = "<input type=\"checkbox\" disabled> "; liClass = " class=\"task\""
                    lines[0] = String(head.dropFirst(min(4, head.count)))
                } else if head.lowercased().hasPrefix("[x] ") || head.lowercased() == "[x]" {
                    prefix = "<input type=\"checkbox\" checked disabled> "; liClass = " class=\"task\""
                    lines[0] = String(head.dropFirst(min(4, head.count)))
                }
            }
            var body = renderBlocks(lines[...])
            if !loose {
                // Tight lists render their first paragraph without <p>.
                if body.hasPrefix("<p>"), let end = body.range(of: "</p>") {
                    body = String(body[body.index(body.startIndex, offsetBy: 3)..<end.lowerBound]) + body[end.upperBound...]
                }
            }
            html += "<li\(liClass)>\(prefix)\(body)</li>\n"
        }
        html += "</\(tag)>"
        return (html, i)
    }

    static func fence(_ trimmed: String) -> String? {
        for f in ["```", "~~~"] where trimmed.hasPrefix(f) {
            let ch = f.first!
            let run = trimmed.prefix { $0 == ch }
            return String(run)
        }
        return nil
    }

    static func atxHeading(_ trimmed: String) -> (Int, String)? {
        let hashes = trimmed.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = trimmed.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // Optional closing hashes.
        if let r = text.range(of: #"\s+#+$"#, options: .regularExpression) { text.removeSubrange(r) }
        else if text.allSatisfy({ $0 == "#" }) { text = "" }
        return (hashes, text)
    }

    static func isThematicBreak(_ trimmed: String) -> Bool {
        let chars = trimmed.filter { $0 != " " }
        guard chars.count >= 3, let c = chars.first, "-*_".contains(c) else { return false }
        return chars.allSatisfy { $0 == c }
    }

    static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-") else { return false }
        let cells = tableCells(t)
        return !cells.isEmpty && cells.allSatisfy { $0.range(of: #"^:?-+:?$"#, options: .regularExpression) != nil }
    }

    static func tableCells(_ line: String) -> [String] {
        var t = line
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") && !t.hasSuffix("\\|") { t.removeLast() }
        var cells: [String] = []
        var current = ""
        var escaped = false
        var inCode = false
        for ch in t {
            if escaped { current.append(ch == "|" ? "|" : "\\\(ch)"); escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            if ch == "`" { inCode.toggle() }
            if ch == "|" && !inCode { cells.append(current.trimmingCharacters(in: .whitespaces)); current = ""; continue }
            current.append(ch)
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    static func alignment(_ spec: String) -> String? {
        let l = spec.hasPrefix(":"), r = spec.hasSuffix(":")
        if l && r { return "center" }
        if r { return "right" }
        if l { return "left" }
        return nil
    }

    static func slug(_ text: String) -> String {
        let lowered = text.lowercased()
        let kept = lowered.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : (($0 == " " || $0 == "-") ? "-" : nil) }
        return String(kept.compactMap { $0 }).replacingOccurrences(of: "--+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    // MARK: - Inline

    func renderInline(_ text: String) -> String {
        var out = ""
        let chars = Array(text)
        var i = 0
        var openStack: [(marker: String, outIndex: Int)] = []

        func peek(_ s: String, at idx: Int) -> Bool {
            let sc = Array(s)
            guard idx + sc.count <= chars.count else { return false }
            return Array(chars[idx..<idx + sc.count]) == sc
        }

        while i < chars.count {
            let c = chars[i]
            // Escapes
            if c == "\\", i + 1 < chars.count {
                let n = chars[i + 1]
                if n == "\n" { out += "<br>\n"; i += 2; continue }
                if "\\`*_{}[]()#+-.!|~<>\"'".contains(n) { out += escape(String(n)); i += 2; continue }
            }
            // Hard line break: two trailing spaces before newline
            if c == "\n" {
                if out.hasSuffix("  ") { out.removeLast(2); out += "<br>\n" } else { out += "\n" }
                i += 1
                continue
            }
            // Code span
            if c == "`" {
                let run = chars[i...].prefix { $0 == "`" }.count
                let fence = String(repeating: "`", count: run)
                var j = i + run
                var found: Int?
                while j < chars.count {
                    if peek(fence, at: j) && (j + run >= chars.count || chars[j + run] != "`") { found = j; break }
                    j += 1
                }
                if let end = found {
                    var code = String(chars[(i + run)..<end]).replacingOccurrences(of: "\n", with: " ")
                    if code.hasPrefix(" ") && code.hasSuffix(" ") && code.trimmingCharacters(in: .whitespaces).count > 0 {
                        code = String(code.dropFirst().dropLast())
                    }
                    out += "<code>\(escape(code))</code>"
                    i = end + run
                    continue
                }
                out += fence
                i += run
                continue
            }
            // Autolink
            if c == "<", let close = chars[i...].firstIndex(of: ">") {
                let inner = String(chars[(i + 1)..<close])
                if inner.range(of: #"^(https?|mailto):[^\s<>]+$"#, options: .regularExpression) != nil {
                    out += "<a href=\"\(escapeAttr(inner))\">\(escape(inner))</a>"
                    i = close + 1
                    continue
                }
                if inner.range(of: #"^[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+$"#, options: .regularExpression) != nil {
                    out += "<a href=\"mailto:\(escapeAttr(inner))\">\(escape(inner))</a>"
                    i = close + 1
                    continue
                }
            }
            // Images and links
            if (c == "!" && i + 1 < chars.count && chars[i + 1] == "[") || c == "[" {
                let isImage = c == "!"
                let open = isImage ? i + 1 : i
                if let (label, url, title, end) = parseLink(chars, openBracket: open) {
                    let titleAttr = title.map { " title=\"\(escapeAttr($0))\"" } ?? ""
                    if isImage {
                        out += "<img src=\"\(escapeAttr(Self.safeURL(url)))\" alt=\"\(escapeAttr(Self.plain(label)))\"\(titleAttr)>"
                    } else {
                        out += "<a href=\"\(escapeAttr(Self.safeURL(url)))\"\(titleAttr)>\(renderInline(label))</a>"
                    }
                    i = end
                    continue
                }
            }
            // Emphasis, strong, strikethrough
            if c == "*" || c == "_" || (c == "~" && peek("~~", at: i)) {
                let run = chars[i...].prefix { $0 == c }.count
                let prev: Character = i > 0 ? chars[i - 1] : " "
                let next: Character = i + run < chars.count ? chars[i + run] : " "
                let canOpen = !next.isWhitespace && (c != "_" || !(prev.isLetter || prev.isNumber))
                let canClose = !prev.isWhitespace && (c != "_" || !(next.isLetter || next.isNumber))
                var remaining = run
                var idx = i
                while remaining > 0 {
                    if c == "~" && remaining < 2 { out += "~"; remaining -= 1; idx += 1; continue }
                    let take: Int
                    if c == "~" {
                        take = 2
                    } else if canClose, let last = openStack.last(where: { $0.marker.first == c }) {
                        take = min(remaining, last.marker.count)
                    } else {
                        take = remaining >= 2 ? 2 : 1
                    }
                    let marker = String(repeating: c, count: take)
                    if canClose, let k = openStack.lastIndex(where: { $0.marker == marker }) {
                        let tag = c == "~" ? "del" : (take == 2 ? "strong" : "em")
                        let insertAt = out.index(out.startIndex, offsetBy: openStack[k].outIndex)
                        out.insert(contentsOf: "<\(tag)>", at: insertAt)
                        // Drop the placeholder marker text we emitted when opening.
                        let markerStart = out.index(insertAt, offsetBy: tag.count + 2)
                        out.removeSubrange(markerStart..<out.index(markerStart, offsetBy: marker.count))
                        out += "</\(tag)>"
                        openStack.removeSubrange(k...)
                    } else if canOpen {
                        openStack.append((marker, out.count))
                        out += marker
                    } else {
                        out += marker
                    }
                    remaining -= take
                    idx += take
                }
                i += run
                continue
            }
            // Bare URLs (GFM autolink extension)
            if (c == "h" && (peek("https://", at: i) || peek("http://", at: i))) && (i == 0 || chars[i - 1].isWhitespace || chars[i - 1] == "(") {
                var j = i
                while j < chars.count, !chars[j].isWhitespace, chars[j] != "<" { j += 1 }
                while j > i, ".,;:!?)".contains(chars[j - 1]) { j -= 1 }
                let url = String(chars[i..<j])
                out += "<a href=\"\(escapeAttr(url))\">\(escape(url))</a>"
                i = j
                continue
            }
            out += escape(String(c))
            i += 1
        }
        return out
    }

    /// Parses `[label](url "title")` starting at the `[`; returns the index after `)`.
    private func parseLink(_ chars: [Character], openBracket: Int) -> (String, String, String?, Int)? {
        var depth = 0
        var j = openBracket
        var closeBracket: Int?
        while j < chars.count {
            if chars[j] == "\\" { j += 2; continue }
            if chars[j] == "[" { depth += 1 }
            if chars[j] == "]" { depth -= 1; if depth == 0 { closeBracket = j; break } }
            j += 1
        }
        guard let cb = closeBracket, cb + 1 < chars.count, chars[cb + 1] == "(" else { return nil }
        var k = cb + 2
        var parens = 1
        var dest = ""
        while k < chars.count {
            if chars[k] == "(" { parens += 1 }
            if chars[k] == ")" { parens -= 1; if parens == 0 { break } }
            dest.append(chars[k])
            k += 1
        }
        guard k < chars.count else { return nil }
        let label = String(chars[(openBracket + 1)..<cb])
        var url = dest.trimmingCharacters(in: .whitespaces)
        var title: String?
        if let r = url.range(of: #"\s+"([^"]*)"$"#, options: .regularExpression) {
            title = String(url[r]).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            url.removeSubrange(r)
        }
        if url.hasPrefix("<") && url.hasSuffix(">") { url = String(url.dropFirst().dropLast()) }
        return (label, url, title, k + 1)
    }

    /// Blocks script URLs; everything else is left as written.
    static func safeURL(_ url: String) -> String {
        let lower = url.trimmingCharacters(in: .whitespaces).lowercased()
        if lower.hasPrefix("javascript:") || lower.hasPrefix("vbscript:") || lower.hasPrefix("data:text/html") { return "#" }
        return url
    }

    static func plain(_ markdown: String) -> String {
        markdown.replacingOccurrences(of: #"[*_`~\[\]]"#, with: "", options: .regularExpression)
    }

    func escape(_ s: String) -> String {
        var r = ""
        r.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": r += "&amp;"
            case "<": r += "&lt;"
            case ">": r += "&gt;"
            default: r.append(ch)
            }
        }
        return r
    }

    func escapeAttr(_ s: String) -> String {
        escape(s).replacingOccurrences(of: "\"", with: "&quot;")
    }
}
