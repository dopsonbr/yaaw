import Foundation

public enum MarkdownPreviewRenderer {
    public static func renderHTML(markdown: String, sourceURL: URL) -> String {
        let title = sourceURL.lastPathComponent.isEmpty ? "Markdown Preview" : sourceURL.lastPathComponent
        var renderer = MarkdownBlockRenderer(markdown: markdown)
        let body = renderer.render()
        return """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src 'self' file: data: https: http:; style-src 'unsafe-inline'; script-src 'unsafe-inline';">
          <title>\(Self.escapeHTML(title))</title>
          <style>
        \(Self.styles)
          </style>
        </head>
        <body>
          <main class="markdown-body">
        \(body)
          </main>
          <script>
        \(Self.mermaidRendererScript)
          </script>
        </body>
        </html>
        """
    }

    static func escapeHTML(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.count)
        for character in value {
            switch character {
            case "&":
                escaped += "&amp;"
            case "<":
                escaped += "&lt;"
            case ">":
                escaped += "&gt;"
            case "\"":
                escaped += "&quot;"
            case "'":
                escaped += "&#39;"
            default:
                escaped.append(character)
            }
        }
        return escaped
    }

    public static func isMarkdownURL(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let pathExtension = url.pathExtension.lowercased()
        return pathExtension == "md" || pathExtension == "markdown"
    }

    private static let styles = """
        :root {
          color-scheme: light dark;
          --bg: #ffffff;
          --fg: #24292f;
          --muted: #57606a;
          --border: #d0d7de;
          --accent: #0969da;
          --code-bg: #f6f8fa;
          --quote: #6e7781;
        }
        @media (prefers-color-scheme: dark) {
          :root {
            --bg: #0d1117;
            --fg: #c9d1d9;
            --muted: #8b949e;
            --border: #30363d;
            --accent: #58a6ff;
            --code-bg: #161b22;
            --quote: #8b949e;
          }
        }
        body {
          margin: 0;
          background: var(--bg);
          color: var(--fg);
          font: 16px/1.55 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
        }
        .markdown-body {
          max-width: 980px;
          margin: 0 auto;
          padding: 32px;
        }
        .markdown-body > :first-child { margin-top: 0; }
        .markdown-body > :last-child { margin-bottom: 0; }
        h1, h2, h3, h4, h5, h6 {
          margin: 24px 0 16px;
          font-weight: 600;
          line-height: 1.25;
        }
        h1, h2 { padding-bottom: 0.3em; border-bottom: 1px solid var(--border); }
        h1 { font-size: 2em; }
        h2 { font-size: 1.5em; }
        h3 { font-size: 1.25em; }
        p, blockquote, ul, ol, table, pre, .mermaid-card { margin: 0 0 16px; }
        a { color: var(--accent); text-decoration: none; }
        a:hover { text-decoration: underline; }
        blockquote {
          padding: 0 1em;
          color: var(--quote);
          border-left: 0.25em solid var(--border);
        }
        code {
          padding: 0.2em 0.4em;
          background: var(--code-bg);
          border-radius: 6px;
          font: 85% ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
        }
        pre {
          padding: 16px;
          overflow: auto;
          background: var(--code-bg);
          border-radius: 6px;
        }
        pre code {
          padding: 0;
          background: transparent;
          border-radius: 0;
          font-size: 100%;
        }
        table {
          border-collapse: collapse;
          width: max-content;
          max-width: 100%;
          overflow: auto;
          display: block;
        }
        th, td {
          padding: 6px 13px;
          border: 1px solid var(--border);
        }
        tr:nth-child(2n) { background: color-mix(in srgb, var(--code-bg) 70%, transparent); }
        img { max-width: 100%; box-sizing: content-box; }
        hr {
          height: 0.25em;
          padding: 0;
          margin: 24px 0;
          background: var(--border);
          border: 0;
        }
        .mermaid-card {
          padding: 16px;
          overflow: auto;
          background: var(--code-bg);
          border: 1px solid var(--border);
          border-radius: 8px;
        }
        .mermaid-card svg {
          max-width: 100%;
          height: auto;
          display: block;
        }
        .mermaid-source { display: none; }
        """

    private static let mermaidRendererScript = #"""
        (() => {
          const escape = (value) => String(value)
            .replaceAll('&', '&amp;')
            .replaceAll('<', '&lt;')
            .replaceAll('>', '&gt;')
            .replaceAll('"', '&quot;');

          const parseNode = (raw) => {
            const value = raw.trim();
            const match = value.match(/^([A-Za-z0-9_:-]+)\s*(?:\[\s*(.*?)\s*\]|\{\s*(.*?)\s*\}|\(\(\s*(.*?)\s*\)\)|\(\s*(.*?)\s*\))?$/);
            if (!match) return { id: value, label: value, shape: 'rect' };
            const label = match[2] || match[3] || match[4] || match[5] || match[1];
            const shape = match[3] ? 'diamond' : (match[4] ? 'circle' : 'rect');
            return { id: match[1], label, shape };
          };

          const renderFlowchart = (source) => {
            const nodes = new Map();
            const edges = [];
            const lines = source.split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
            for (const line of lines) {
              if (/^(graph|flowchart)\b/i.test(line)) continue;
              const match = line.match(/^(.*?)\s*(-->|---|-.->|==>)\s*(?:\|\s*(.*?)\s*\|\s*)?(.*?)$/);
              if (!match) {
                const node = parseNode(line);
                nodes.set(node.id, node);
                continue;
              }
              const from = parseNode(match[1]);
              const to = parseNode(match[4]);
              nodes.set(from.id, from);
              nodes.set(to.id, to);
              edges.push({ from: from.id, to: to.id, label: match[3] || '' });
            }
            const ordered = Array.from(nodes.values());
            const width = 760;
            const row = 92;
            const height = Math.max(140, ordered.length * row + 40);
            const positions = new Map();
            ordered.forEach((node, index) => {
              positions.set(node.id, { x: width / 2, y: 50 + index * row });
            });
            const nodeMarkup = ordered.map((node) => {
              const point = positions.get(node.id);
              const label = escape(node.label);
              if (node.shape === 'diamond') {
                return `<g><polygon points="${point.x},${point.y - 34} ${point.x + 88},${point.y} ${point.x},${point.y + 34} ${point.x - 88},${point.y}" fill="var(--bg)" stroke="var(--accent)" stroke-width="2"/><text x="${point.x}" y="${point.y + 5}" text-anchor="middle" font-size="14" fill="var(--fg)">${label}</text></g>`;
              }
              if (node.shape === 'circle') {
                return `<g><ellipse cx="${point.x}" cy="${point.y}" rx="76" ry="34" fill="var(--bg)" stroke="var(--accent)" stroke-width="2"/><text x="${point.x}" y="${point.y + 5}" text-anchor="middle" font-size="14" fill="var(--fg)">${label}</text></g>`;
              }
              return `<g><rect x="${point.x - 96}" y="${point.y - 30}" width="192" height="60" rx="8" fill="var(--bg)" stroke="var(--accent)" stroke-width="2"/><text x="${point.x}" y="${point.y + 5}" text-anchor="middle" font-size="14" fill="var(--fg)">${label}</text></g>`;
            }).join('');
            const edgeMarkup = edges.map((edge) => {
              const from = positions.get(edge.from);
              const to = positions.get(edge.to);
              if (!from || !to) return '';
              const labelY = (from.y + to.y) / 2 - 6;
              const label = edge.label ? `<text x="${from.x + 18}" y="${labelY}" font-size="12" fill="var(--muted)">${escape(edge.label)}</text>` : '';
              return `<g><line x1="${from.x}" y1="${from.y + 34}" x2="${to.x}" y2="${to.y - 34}" stroke="var(--muted)" stroke-width="2" marker-end="url(#arrow)"/>${label}</g>`;
            }).join('');
            return `<svg viewBox="0 0 ${width} ${height}" role="img" aria-label="Mermaid flowchart"><defs><marker id="arrow" markerWidth="10" markerHeight="10" refX="8" refY="3" orient="auto"><path d="M0,0 L0,6 L9,3 z" fill="var(--muted)"/></marker></defs>${edgeMarkup}${nodeMarkup}</svg>`;
          };

          const renderSequence = (source) => {
            const messages = [];
            const participants = [];
            const remember = (name) => {
              if (name && !participants.includes(name)) participants.push(name);
            };
            for (const rawLine of source.split(/\r?\n/)) {
              const line = rawLine.trim();
              if (!line || /^sequenceDiagram\b/i.test(line)) continue;
              const participant = line.match(/^participant\s+(.+)$/i);
              if (participant) {
                remember(participant[1].trim());
                continue;
              }
              const message = line.match(/^(.+?)\s*[-=]+>>\s*(.+?)\s*:\s*(.+)$/);
              if (message) {
                const from = message[1].trim();
                const to = message[2].trim();
                remember(from);
                remember(to);
                messages.push({ from, to, text: message[3].trim() });
              }
            }
            const width = Math.max(520, participants.length * 180 + 80);
            const height = Math.max(160, messages.length * 70 + 110);
            const xFor = (name) => 60 + participants.indexOf(name) * 180;
            const headers = participants.map((name) => {
              const x = xFor(name);
              return `<g><rect x="${x - 52}" y="20" width="104" height="34" rx="6" fill="var(--bg)" stroke="var(--accent)" stroke-width="2"/><text x="${x}" y="42" text-anchor="middle" font-size="13" fill="var(--fg)">${escape(name)}</text><line x1="${x}" y1="54" x2="${x}" y2="${height - 24}" stroke="var(--border)" stroke-dasharray="5 5"/></g>`;
            }).join('');
            const arrows = messages.map((message, index) => {
              const y = 92 + index * 70;
              const x1 = xFor(message.from);
              const x2 = xFor(message.to);
              const direction = x2 >= x1 ? 1 : -1;
              const labelX = (x1 + x2) / 2;
              return `<g><line x1="${x1}" y1="${y}" x2="${x2 - direction * 10}" y2="${y}" stroke="var(--muted)" stroke-width="2" marker-end="url(#arrow)"/><text x="${labelX}" y="${y - 10}" text-anchor="middle" font-size="12" fill="var(--fg)">${escape(message.text)}</text></g>`;
            }).join('');
            return `<svg viewBox="0 0 ${width} ${height}" role="img" aria-label="Mermaid sequence diagram"><defs><marker id="arrow" markerWidth="10" markerHeight="10" refX="8" refY="3" orient="auto"><path d="M0,0 L0,6 L9,3 z" fill="var(--muted)"/></marker></defs>${headers}${arrows}</svg>`;
          };

          for (const source of document.querySelectorAll('.mermaid-source')) {
            const card = source.closest('.mermaid-card');
            const text = source.textContent || '';
            const svg = /^\s*sequenceDiagram\b/i.test(text) ? renderSequence(text) : renderFlowchart(text);
            card.insertAdjacentHTML('beforeend', svg);
          }
        })();
        """#
}

private struct MarkdownBlockRenderer {
    private let lines: [String]
    private var index = 0

    init(markdown: String) {
        self.lines = markdown.components(separatedBy: .newlines)
    }

    mutating func render() -> String {
        var blocks: [String] = []
        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                index += 1
            } else if let fence = fencedCodeBlock() {
                blocks.append(fence)
            } else if let heading = headingBlock(line) {
                blocks.append(heading)
                index += 1
            } else if horizontalRule(line) {
                blocks.append("<hr>")
                index += 1
            } else if tableStarts(at: index) {
                blocks.append(tableBlock())
            } else if unorderedListStarts(line) {
                blocks.append(listBlock(ordered: false))
            } else if orderedListStarts(line) {
                blocks.append(listBlock(ordered: true))
            } else if line.trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                blocks.append(blockquoteBlock())
            } else {
                blocks.append(paragraphBlock())
            }
        }
        return blocks.joined(separator: "\n")
    }

    private mutating func fencedCodeBlock() -> String? {
        let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") else { return nil }
        let marker = String(trimmed.prefix(3))
        let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        index += 1
        var body: [String] = []
        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces).hasPrefix(marker) {
                index += 1
                break
            }
            body.append(line)
            index += 1
        }
        let code = body.joined(separator: "\n")
        if language == "mermaid" {
            return """
            <div class="mermaid-card">
              <pre class="mermaid-source">\(MarkdownPreviewRenderer.escapeHTML(code))</pre>
            </div>
            """
        }
        let className = language.isEmpty ? "" : " class=\"language-\(MarkdownPreviewRenderer.escapeHTML(language))\""
        return "<pre><code\(className)>\(MarkdownPreviewRenderer.escapeHTML(code))</code></pre>"
    }

    private func headingBlock(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let count = trimmed.prefix { $0 == "#" }.count
        guard (1...6).contains(count), trimmed.dropFirst(count).first == " " else { return nil }
        let text = trimmed.dropFirst(count).trimmingCharacters(in: .whitespaces)
        let id = slug(text)
        return "<h\(count) id=\"\(id)\">\(InlineMarkdownRenderer.render(text))</h\(count)>"
    }

    private func horizontalRule(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count >= 3 && Set(trimmed).isSubset(of: Set(["-", "*", "_"]))
    }

    private mutating func paragraphBlock() -> String {
        var paragraph: [String] = []
        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces).isEmpty
                || line.trimmingCharacters(in: .whitespaces).hasPrefix("```")
                || line.trimmingCharacters(in: .whitespaces).hasPrefix("~~~")
                || headingBlock(line) != nil
                || horizontalRule(line)
                || tableStarts(at: index)
                || unorderedListStarts(line)
                || orderedListStarts(line)
                || line.trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                break
            }
            paragraph.append(line.trimmingCharacters(in: .whitespaces))
            index += 1
        }
        return "<p>\(InlineMarkdownRenderer.render(paragraph.joined(separator: " ")))</p>"
    }

    private mutating func listBlock(ordered: Bool) -> String {
        var items: [String] = []
        while index < lines.count {
            let line = lines[index]
            guard ordered ? orderedListStarts(line) : unorderedListStarts(line) else { break }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let item: String
            if ordered, let dotIndex = trimmed.firstIndex(of: ".") {
                item = String(trimmed[trimmed.index(after: dotIndex)...]).trimmingCharacters(in: .whitespaces)
            } else {
                item = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
            items.append("<li>\(InlineMarkdownRenderer.render(item))</li>")
            index += 1
        }
        let tag = ordered ? "ol" : "ul"
        return "<\(tag)>\n\(items.joined(separator: "\n"))\n</\(tag)>"
    }

    private mutating func blockquoteBlock() -> String {
        var quote: [String] = []
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(">") else { break }
            quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
            index += 1
        }
        return "<blockquote>\n<p>\(InlineMarkdownRenderer.render(quote.joined(separator: " ")))</p>\n</blockquote>"
    }

    private mutating func tableBlock() -> String {
        let header = splitTableRow(lines[index])
        index += 2
        var rows: [[String]] = []
        while index < lines.count {
            let line = lines[index]
            guard line.contains("|"), !line.trimmingCharacters(in: .whitespaces).isEmpty else { break }
            rows.append(splitTableRow(line))
            index += 1
        }
        let head = header.map { "<th>\(InlineMarkdownRenderer.render($0))</th>" }.joined()
        let body = rows.map { row in
            "<tr>\(row.map { "<td>\(InlineMarkdownRenderer.render($0))</td>" }.joined())</tr>"
        }.joined(separator: "\n")
        return "<table>\n<thead><tr>\(head)</tr></thead>\n<tbody>\(body)</tbody>\n</table>"
    }

    private func tableStarts(at index: Int) -> Bool {
        guard lines.indices.contains(index + 1), lines[index].contains("|") else { return false }
        let separator = splitTableRow(lines[index + 1])
        return !separator.isEmpty && separator.allSatisfy { cell in
            let trimmed = cell.trimmingCharacters(in: .whitespaces)
            return trimmed.count >= 3 && trimmed.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    private func splitTableRow(_ line: String) -> [String] {
        line.trimmingCharacters(in: CharacterSet(charactersIn: "|"))
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private func unorderedListStarts(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ")
    }

    private func orderedListStarts(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let dotIndex = trimmed.firstIndex(of: ".") else { return false }
        return trimmed[..<dotIndex].allSatisfy(\.isNumber)
            && trimmed.indices.contains(trimmed.index(after: dotIndex))
            && trimmed[trimmed.index(after: dotIndex)] == " "
    }

    private func slug(_ value: String) -> String {
        let allowed = value.lowercased().map { character -> Character in
            if character.isLetter || character.isNumber { return character }
            return "-"
        }
        return String(allowed).split(separator: "-").joined(separator: "-")
    }
}

private enum InlineMarkdownRenderer {
    static func render(_ value: String) -> String {
        let segments = value.split(separator: "`", omittingEmptySubsequences: false)
        var rendered = ""
        for (offset, segment) in segments.enumerated() {
            if offset % 2 == 1 {
                rendered += "<code>\(MarkdownPreviewRenderer.escapeHTML(String(segment)))</code>"
            } else {
                rendered += renderText(String(segment))
            }
        }
        return rendered
    }

    private static func renderText(_ value: String) -> String {
        var rendered = SanitizedHTMLRenderer.render(value)
        rendered = replaceImages(in: rendered)
        rendered = replaceLinks(in: rendered)
        rendered = replaceDelimited(in: rendered, delimiter: "**", tag: "strong")
        rendered = replaceDelimited(in: rendered, delimiter: "__", tag: "strong")
        rendered = replaceDelimited(in: rendered, delimiter: "*", tag: "em")
        rendered = replaceDelimited(in: rendered, delimiter: "_", tag: "em")
        return rendered
    }

    private static func replaceImages(in value: String) -> String {
        replacePattern(#"!\[([^\]]*)\]\(([^)\s]+)(?:\s+"([^"]*)")?\)"#, in: value) { match in
            let alt = sanitizeAttribute(match[1])
            guard let src = sanitizedURLAttribute(match[2]) else { return match[0] }
            let title = match.count > 3 ? sanitizeAttribute(match[3]) : ""
            let titleAttribute = title.isEmpty ? "" : " title=\"\(title)\""
            return "<img src=\"\(src)\" alt=\"\(alt)\"\(titleAttribute)>"
        }
    }

    private static func replaceLinks(in value: String) -> String {
        replacePattern(#"(?<!!)\[([^\]]+)\]\(([^)\s]+)(?:\s+"([^"]*)")?\)"#, in: value) { match in
            guard let href = sanitizedURLAttribute(match[2]) else { return match[0] }
            let title = match.count > 3 ? sanitizeAttribute(match[3]) : ""
            let titleAttribute = title.isEmpty ? "" : " title=\"\(title)\""
            return "<a href=\"\(href)\"\(titleAttribute)>\(match[1])</a>"
        }
    }

    private static func replaceDelimited(in value: String, delimiter: String, tag: String) -> String {
        var output = ""
        var remainder = value[...]
        while let start = remainder.range(of: delimiter), let end = remainder[start.upperBound...].range(of: delimiter) {
            output += remainder[..<start.lowerBound]
            output += "<\(tag)>\(remainder[start.upperBound..<end.lowerBound])</\(tag)>"
            remainder = remainder[end.upperBound...]
        }
        output += remainder
        return output
    }

    private static func replacePattern(
        _ pattern: String,
        in value: String,
        replacement: ([String]) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }
        let nsRange = NSRange(value.startIndex..<value.endIndex, in: value)
        let matches = regex.matches(in: value, range: nsRange).reversed()
        var result = value
        for match in matches {
            let groups = (0..<match.numberOfRanges).map { index -> String in
                guard let range = Range(match.range(at: index), in: result) else { return "" }
                return String(result[range])
            }
            guard let range = Range(match.range(at: 0), in: result) else { continue }
            result.replaceSubrange(range, with: replacement(groups))
        }
        return result
    }

    private static func sanitizedURLAttribute(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()
        guard !lowercased.hasPrefix("javascript:") && !lowercased.hasPrefix("data:text/html") else {
            return nil
        }
        return sanitizeAttribute(trimmed)
    }

    private static func sanitizeAttribute(_ value: String) -> String {
        MarkdownPreviewRenderer.escapeHTML(value)
    }
}

private enum SanitizedHTMLRenderer {
    private static let allowedTags: Set<String> = [
        "a", "abbr", "b", "br", "code", "del", "details", "div", "em", "i", "img", "kbd",
        "li", "mark", "ol", "p", "s", "samp", "span", "strong", "sub", "summary", "sup",
        "table", "tbody", "td", "th", "thead", "tr", "u", "ul"
    ]

    static func render(_ value: String) -> String {
        var output = ""
        var index = value.startIndex
        while index < value.endIndex {
            if value[index] == "<", let close = value[index...].firstIndex(of: ">") {
                let tag = String(value[index...close])
                if let sanitized = sanitizeTag(tag) {
                    output += sanitized
                } else {
                    output += MarkdownPreviewRenderer.escapeHTML(tag)
                }
                index = value.index(after: close)
            } else {
                output += MarkdownPreviewRenderer.escapeHTML(String(value[index]))
                index = value.index(after: index)
            }
        }
        return output
    }

    private static func sanitizeTag(_ tag: String) -> String? {
        let body = tag.dropFirst().dropLast().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        if body.hasPrefix("!--") { return nil }
        let isClosing = body.hasPrefix("/")
        let content = isClosing ? body.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines) : body
        let name = content.prefix { $0.isLetter || $0.isNumber }.lowercased()
        guard allowedTags.contains(String(name)) else { return nil }
        if isClosing { return "</\(name)>" }
        if content.contains("on") && content.range(of: #"on[a-z]+\s*="#, options: .regularExpression) != nil {
            return "<\(name)>"
        }
        switch name {
        case "a":
            return "<a\(sanitizedAttribute(named: "href", in: String(content)).map { " href=\"\($0)\"" } ?? "")>"
        case "img":
            let src = sanitizedAttribute(named: "src", in: String(content)).map { " src=\"\($0)\"" } ?? ""
            let alt = sanitizedAttribute(named: "alt", in: String(content)).map { " alt=\"\($0)\"" } ?? ""
            return "<img\(src)\(alt)>"
        default:
            return "<\(name)>"
        }
    }

    private static func sanitizedAttribute(named name: String, in content: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"\#(name)\s*=\s*["']([^"']*)["']"#, options: .caseInsensitive),
              let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..<content.endIndex, in: content)),
              let range = Range(match.range(at: 1), in: content)
        else { return nil }
        let value = String(content[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = value.lowercased()
        guard !lowercased.hasPrefix("javascript:") && !lowercased.hasPrefix("data:text/html") else {
            return nil
        }
        return MarkdownPreviewRenderer.escapeHTML(value)
    }
}
