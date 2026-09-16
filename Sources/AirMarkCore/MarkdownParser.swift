import Foundation
import Markdown

public enum StyleKind: Hashable, Sendable {
    case heading(Int), strong, emphasis, strike, code, codeBlock, quote, list, link(String), rule
    /// The `-`, `+` or `*` of an unordered list item; presented as a bullet symbol.
    case bullet
    /// A GFM task box `[ ]` / `[x]`; presented as a checkbox symbol.
    case checkbox(Bool)
}
public struct StyleRun: Hashable, Sendable {
    public var span: SourceSpan
    public var kind: StyleKind
    public var markers: [SourceSpan]
    public init(span: SourceSpan, kind: StyleKind, markers: [SourceSpan] = []) { self.span = span; self.kind = kind; self.markers = markers }
}
public enum ElementKind: String, Codable, Sendable { case math, mermaid, image, table }
public struct RenderElement: Hashable, Sendable {
    public var span: SourceSpan
    public var kind: ElementKind
    public var content: String
    public var inline: Bool
    public var label: String
    public init(span: SourceSpan, kind: ElementKind, content: String, inline: Bool = false, label: String = "") {
        self.span = span; self.kind = kind; self.content = content; self.inline = inline; self.label = label
    }
}
public struct ParsedDocument: Sendable {
    public var source: String
    public var revision: UInt64
    public var styles: [StyleRun]
    public var elements: [RenderElement]
    public var checkboxes: [SourceSpan]
    public init(source: String, revision: UInt64 = 0, styles: [StyleRun] = [], elements: [RenderElement] = [], checkboxes: [SourceSpan] = []) {
        self.source = source; self.revision = revision; self.styles = styles; self.elements = elements; self.checkboxes = checkboxes
    }
}

public actor MarkdownParsingWorker {
    public init() {}
    public func parse(_ source: String, revision: UInt64) throws -> ParsedDocument {
        try Task.checkCancellation()
        return MarkdownParser.parse(source, revision: revision)
    }
}

public enum MarkdownParser {
    public static func parse(_ source: String, revision: UInt64 = 0) -> ParsedDocument {
        let index = SourceIndex(source)
        var output = ParsedDocument(source: source, revision: revision)
        let document = Document(parsing: source)
        var protected: [SourceSpan] = []
        func span(_ node: any Markup) -> SourceSpan? {
            guard let r = node.range, let a = index.offset(line: r.lowerBound.line, utf8Column: r.lowerBound.column),
                  let b = index.offset(line: r.upperBound.line, utf8Column: r.upperBound.column), b >= a, b <= index.utf16Count else { return nil }
            return SourceSpan(a, b - a)
        }
        func plain(_ node: any Markup) -> String {
            if let t = node as? Text { return t.string }
            if let t = node as? InlineCode { return t.code }
            if node is SoftBreak || node is LineBreak { return " " }
            return node.children.map { plain($0) }.joined()
        }
        func walk(_ node: any Markup) {
            guard let s = span(node) else { for child in node.children { walk(child) }; return }
            let raw = index.text(in: s)
            func add(_ kind: StyleKind, markers: [SourceSpan] = []) { output.styles.append(StyleRun(span: s, kind: kind, markers: markers)) }
            func edges(_ n: Int) -> [SourceSpan] { s.length >= n * 2 ? [SourceSpan(s.location, n), SourceSpan(s.end - n, n)] : [] }
            switch node {
            case let heading as Heading:
                let prefix = raw.prefix { $0 == "#" || $0 == " " }.utf16.count
                var markers: [SourceSpan] = []
                if raw.hasPrefix("#") { markers.append(SourceSpan(s.location, prefix)) }
                else if let last = raw.lastIndex(where: { $0 == "\n" || $0 == "\r" }) {
                    markers.append(SourceSpan(s.location + last.utf16Offset(in: raw), raw[last...].utf16.count))
                }
                add(.heading(heading.level), markers: markers)
            case is Strong: add(.strong, markers: edges(2))
            case is Emphasis: add(.emphasis, markers: edges(1))
            case is Strikethrough: add(.strike, markers: edges(2))
            case is InlineCode:
                let count = raw.prefix { $0 == "`" }.count
                add(.code, markers: edges(count)); protected.append(s)
            case let code as CodeBlock:
                protected.append(s)
                let lang = (code.language ?? "").lowercased().split(separator: " ").first.map(String.init) ?? ""
                if lang == "mermaid" || lang == "math" || lang == "latex" {
                    output.elements.append(RenderElement(span: s, kind: lang == "mermaid" ? .mermaid : .math, content: code.code))
                } else {
                    var markers = fenceMarkers(raw, at: s.location)
                    // The block span stops before its line break. Hide that break with the closing
                    // fence so the fence line collapses instead of leaving an empty code line.
                    if markers.count == 2 {
                        let following = index.text(in: SourceSpan(s.end, min(2, index.utf16Count - s.end)))
                        if following.hasPrefix("\r\n") { markers[1].length += 2 }
                        else if let first = following.first, first.isNewline { markers[1].length += 1 }
                    }
                    add(.codeBlock, markers: markers)
                }
            case is BlockQuote:
                var markers: [SourceSpan] = []
                if let regex = try? NSRegularExpression(pattern: "^[ \\t]{0,3}>[ \\t]?", options: .anchorsMatchLines) {
                    for match in regex.matches(in: raw, range: NSRange(location: 0, length: (raw as NSString).length)) {
                        markers.append(SourceSpan(s.location + match.range.location, match.range.length))
                    }
                }
                add(.quote, markers: markers)
            case is ListItem:
                var extra: [StyleRun] = [], markers: [SourceSpan] = []
                if let regex = try? NSRegularExpression(pattern: "^[ \\t]*([-+*]|[0-9]+[.)])[ \\t]+(?:(\\[[ xX]\\])(?=[ \\t]))?"),
                   let m = regex.firstMatch(in: raw, range: NSRange(location: 0, length: (raw as NSString).length)) {
                    let marker = m.range(at: 1), box = m.range(at: 2)
                    if box.location != NSNotFound {
                        // A task item shows only its checkbox; the list marker before it is hidden.
                        markers.append(SourceSpan(s.location + marker.location, box.location - marker.location))
                        let span = SourceSpan(s.location + box.location, box.length)
                        output.checkboxes.append(span)
                        extra.append(StyleRun(span: span, kind: .checkbox((raw as NSString).substring(with: box).lowercased() == "[x]")))
                    } else if marker.length == 1 {
                        extra.append(StyleRun(span: SourceSpan(s.location + marker.location, 1), kind: .bullet))
                    }
                }
                add(.list, markers: markers)
                output.styles += extra
            case let image as Markdown.Image:
                output.elements.append(RenderElement(span: s, kind: .image, content: image.source ?? "", label: plain(image)))
                protected.append(s); return
            case let link as Link:
                var markers: [SourceSpan] = []
                let children = Array(link.children)
                if let first = children.first, let last = children.last, let a = span(first), let b = span(last) {
                    if a.location > s.location { markers.append(SourceSpan(s.location, a.location - s.location)) }
                    if b.end < s.end { markers.append(SourceSpan(b.end, s.end - b.end)) }
                }
                add(.link(link.destination ?? ""), markers: markers)
            case let table as Table:
                var rows: [[String]] = []
                for child in table.children {
                    if child is Table.Head { rows.append(child.children.map { plain($0) }) }
                    else { for row in child.children { rows.append(row.children.map { plain($0) }) } }
                }
                if let data = try? JSONEncoder().encode(rows), let json = String(data: data, encoding: .utf8) {
                    output.elements.append(RenderElement(span: s, kind: .table, content: json, label: "Table, \(rows.count) rows"))
                }
                protected.append(s); return
            case is ThematicBreak: add(.rule)
            case is HTMLBlock, is InlineHTML: protected.append(s)
            default: break
            }
            for child in node.children { walk(child) }
        }
        walk(document)
        output.elements += mathSpans(source, excluding: protected)
        output.elements.sort { $0.span.location < $1.span.location }
        // A math expression's contents are TeX, never Markdown emphasis/links.
        let mathElements = output.elements.filter { $0.kind == .math }
        output.styles.removeAll { run in
            // Math ranges are sorted and disjoint. Find the possible containing
            // range without comparing every style against every formula.
            var low = 0, high = mathElements.count
            while low < high {
                let middle = (low + high) / 2
                if mathElements[middle].span.location <= run.span.location { low = middle + 1 }
                else { high = middle }
            }
            guard low > 0 else { return false }
            let math = mathElements[low - 1].span
            return math.end >= run.span.end && math.intersects(run.span)
        }
        return output
    }

    /// The opening fence line including its line break, and the closing fence including the
    /// line break before it. Indented code blocks and unterminated fences have fewer markers.
    private static func fenceMarkers(_ raw: String, at base: Int) -> [SourceSpan] {
        let text = raw as NSString
        guard text.length > 0 else { return [] }
        let firstLine = text.lineRange(for: NSRange(location: 0, length: 0))
        let opening = text.substring(with: firstLine).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let fenceCharacter = opening.first, fenceCharacter == "`" || fenceCharacter == "~" else { return [] }
        let fence = opening.prefix { $0 == fenceCharacter }
        guard fence.count >= 3 else { return [] }
        var markers = [SourceSpan(base + firstLine.location, firstLine.length)]
        var end = text.length
        while end > 0, let scalar = Unicode.Scalar(text.character(at: end - 1)), CharacterSet.newlines.contains(scalar) { end -= 1 }
        guard end > NSMaxRange(firstLine) else { return markers }
        let lastLine = text.lineRange(for: NSRange(location: end - 1, length: 0))
        let closing = text.substring(with: NSRange(location: lastLine.location, length: end - lastLine.location)).trimmingCharacters(in: .whitespaces)
        guard closing.count >= fence.count, closing.allSatisfy({ $0 == fenceCharacter }) else { return markers }
        var start = lastLine.location
        if start > 0, let scalar = Unicode.Scalar(text.character(at: start - 1)), CharacterSet.newlines.contains(scalar) {
            start -= 1
            if start > 0, text.character(at: start - 1) == 13, text.character(at: start) == 10 { start -= 1 }
        }
        markers.append(SourceSpan(base + start, end - start))
        return markers
    }

    private static func mathSpans(_ source: String, excluding: [SourceSpan]) -> [RenderElement] {
        let units = Array(source.utf16), text = source as NSString
        var result: [RenderElement] = [], i = 0, protectedIndex = 0
        let excluded = excluding.sorted { $0.location < $1.location }
        func escaped(_ n: Int) -> Bool { var j = n - 1, c = 0; while j >= 0 && units[j] == 92 { c += 1; j -= 1 }; return c % 2 == 1 }
        func whitespace(_ u: UInt16) -> Bool { u == 32 || u == 9 || u == 10 || u == 13 }
        while i < units.count {
            while protectedIndex < excluded.count && excluded[protectedIndex].end <= i { protectedIndex += 1 }
            if protectedIndex < excluded.count && excluded[protectedIndex].contains(i) { i = excluded[protectedIndex].end; continue }
            guard units[i] == 36, !escaped(i), i + 1 < units.count else { i += 1; continue }
            let display = units[i + 1] == 36, delimiter = display ? 2 : 1
            if !display && whitespace(units[i + 1]) { i += 1; continue }
            var j = i + delimiter, found: Int?
            while j < units.count {
                if !display && (units[j] == 10 || units[j] == 13) { break }
                if protectedIndex < excluded.count && j >= excluded[protectedIndex].location { break }
                if units[j] == 36 && !escaped(j) {
                    if display {
                        if j + 1 < units.count && units[j + 1] == 36 { found = j; break }
                    } else if j > i + 1 && !whitespace(units[j - 1]) && !(j + 1 < units.count && (48...57).contains(units[j + 1])) {
                        found = j; break
                    }
                }
                j += 1
            }
            if let close = found {
                let s = SourceSpan(i, close + delimiter - i)
                result.append(RenderElement(span: s, kind: .math, content: text.substring(with: NSRange(location: i + delimiter, length: close - i - delimiter)), inline: !display))
                i = s.end
            } else { i += delimiter }
        }
        return result
    }
}
