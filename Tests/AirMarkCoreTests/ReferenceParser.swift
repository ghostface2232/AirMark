import Foundation
import Markdown
@testable import AirMarkCore

/// The parser as it was while swift-markdown's tree backed it, kept word for word as the reference
/// for `MarkdownParser.parse`, which now reads cmark-gfm's tree directly. Both end in
/// `MarkdownParser.finish`, and the marker helpers are shared: what differs, and what the
/// differential tests compare, is how the tree is reached. One thing was added since: a top-level
/// list is recorded as its items, as the parser now records it, so that `blocks` stays comparable.
/// And one thing was corrected in both: a setext heading ends with its underline, not on the line
/// after it, where cmark puts it.
enum ReferenceParser {
    static func parse(_ source: String, revision: UInt64 = 0) -> ParsedDocument {
        let quoteMarker = try? NSRegularExpression(pattern: "^[ \\t]{0,3}>[ \\t]?", options: .anchorsMatchLines)
        let listItemMarker = MarkdownParser.listItemMarker
        func fenceMarkers(_ raw: String, at base: Int) -> [SourceSpan] { MarkdownParser.fenceMarkers(raw, at: base) }
        let index = SourceIndex(source)
        var output = ParsedDocument(source: source, revision: revision)
        let document = Document(parsing: source)
        var protected: [SourceSpan] = []
        /// Column corrections for inline nodes, by line. swift-markdown reports inline columns on a
        /// paragraph's continuation lines relative to where it considers the line's content to start, so
        /// "para\n   three **b**" placed the strong run three columns early and concealed "ee". The shift is
        /// first estimated from the line's leading whitespace and quote markers, then checked against the
        /// delimiters (and, on one line, the text) of nodes that have them; a line whose delimiters are
        /// found elsewhere nearby takes that shift for all its inline nodes. A delimited node that cannot be
        /// matched to its source is left unstyled.
        var inlineColumnShift: [Int: Int] = [:]
        func offsets(_ r: SourceRange, shift lower: Int, _ upper: Int) -> SourceSpan? {
            guard let a = index.offset(line: r.lowerBound.line, utf8Column: r.lowerBound.column + lower),
                  let b = index.offset(line: r.upperBound.line, utf8Column: r.upperBound.column + upper), b >= a, b <= index.utf16Count else { return nil }
            return SourceSpan(a, b - a)
        }
        /// The characters a delimited inline node's source must start and end with, or nil.
        func delimiters(_ node: any Markup) -> (start: Set<UInt16>, end: Set<UInt16>)? {
            switch node {
            case is Strong, is Emphasis: return ([42, 95], [42, 95])                  // * _
            case is Strikethrough: return ([126], [126])                              // ~
            case is InlineCode: return ([96], [96])                                   // `
            case is Link: return ([91, 60], [41, 93, 62])                             // [ <  ) ] >
            case is Markdown.Image: return ([33], [41, 93])                           // !  ) ]
            default: return nil
            }
        }
        func span(_ node: any Markup) -> SourceSpan? {
            guard let r = node.range else { return nil }
            guard !(node is BlockMarkup) else { return offsets(r, shift: 0, 0) }
            let lowerLine = r.lowerBound.line, upperLine = r.upperBound.line
            let lower = inlineColumnShift[lowerLine] ?? 0, upper = inlineColumnShift[upperLine] ?? 0
            let estimated = offsets(r, shift: lower, upper)
            guard let expected = delimiters(node) else { return estimated }
            // On one line, a shifted candidate must also contain the node's text: adjacent runs such as
            // "**b**> **b**" put matching delimiters at the ends of a wrong candidate. Computed only when a
            // shift is involved; unshifted positions are what the parser reported and are accepted.
            var content: String?
            func fits(_ span: SourceSpan?, checkingContent: Bool) -> Bool {
                guard let span, span.length >= 2 else { return false }
                guard expected.start.contains(index.unit(at: span.location)), expected.end.contains(index.unit(at: span.end - 1)) else { return false }
                guard checkingContent, lowerLine == upperLine else { return true }
                if content == nil { content = plain(node) }
                return content!.isEmpty || index.text(in: span).contains(content!)
            }
            if fits(estimated, checkingContent: lower != 0 || upper != 0) { return estimated }
            for distance in 1...8 {
                for delta in [distance, -distance] {
                    let candidate = offsets(r, shift: lower + delta, lowerLine == upperLine ? upper + delta : upper)
                    if fits(candidate, checkingContent: true) {
                        inlineColumnShift[lowerLine] = lower + delta
                        if lowerLine == upperLine { inlineColumnShift[upperLine] = upper + delta }
                        return candidate
                    }
                }
            }
            // Not found in the source: leave the node unstyled rather than conceal characters it does not own.
            return nil
        }
        /// For each continuation line of a paragraph, where its content starts relative to the paragraph's
        /// start column. The parser reports a continuation line's inline columns as if its content began
        /// at that column, after stripping leading whitespace and block quote markers. List item content
        /// indentation is whitespace here and already matches the start column, so it needs no correction.
        func continuationShifts(_ paragraph: Paragraph) -> [Int: Int] {
            guard let range = paragraph.range, range.upperBound.line > range.lowerBound.line else { return [:] }
            var shifts: [Int: Int] = [:]
            for line in (range.lowerBound.line + 1)...min(range.upperBound.line, index.lines.count) {
                var contentStart = 0
                for byte in index.text(in: index.lines[line - 1]).utf8 {
                    guard byte == 32 || byte == 9 || byte == 62 else { break }        // space, tab, ">"
                    contentStart += 1
                }
                let shift = contentStart - (range.lowerBound.column - 1)
                if shift != 0 { shifts[line] = shift }
            }
            return shifts
        }
        func plain(_ node: any Markup) -> String {
            if let t = node as? Text { return t.string }
            if let t = node as? InlineCode { return t.code }
            if node is SoftBreak || node is LineBreak { return " " }
            return node.children.map { plain($0) }.joined()
        }
        // Top-level blocks are what `reparse` cuts between; their spans are the ones `walk` computes
        // anyway, except for a paragraph, whose own span it has no other use for.
        var blockSpansComplete = true
        func walk(_ node: any Markup, topLevel: Bool = false, topLevelItem: Bool = false) {
            if let paragraph = node as? Paragraph {
                if topLevel {
                    if let span = span(paragraph) { output.blocks.append(Block(span)) } else { blockSpansComplete = false }
                }
                let outer = inlineColumnShift
                inlineColumnShift = continuationShifts(paragraph)
                for child in node.children { walk(child) }
                inlineColumnShift = outer
                return
            }
            // Plain text and line breaks are most nodes and add no style; their spans have no side
            // effects (no delimiters to match), so skip computing them and the casts below.
            if node is Text || node is SoftBreak || node is LineBreak { return }
            var resolved = span(node)
            // As in the parser: a setext heading's end is worked out below, so its start is enough.
            if resolved == nil, node is Heading, let range = node.range, let start = index.offset(line: range.lowerBound.line, utf8Column: range.lowerBound.column),
               index.unit(at: start) != 35 { resolved = SourceSpan(start, 0) }
            guard var s = resolved else {
                if topLevel || topLevelItem { blockSpansComplete = false }
                for child in node.children { walk(child) }
                return
            }
            // The underline is the first later line that is one once quote markers and indentation are
            // taken off; the parser finds it through its container cursor instead.
            if node is Heading, index.unit(at: s.location) != 35, let range = node.range, range.upperBound.line > range.lowerBound.line {
                for line in (range.lowerBound.line + 1)...min(range.upperBound.line, index.lines.count) {
                    let text = index.text(in: index.lines[line - 1]).drop { $0 == " " || $0 == "\t" || $0 == ">" }.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let mark = text.first, mark == "=" || mark == "-", text.allSatisfy({ $0 == mark }) {
                        s = SourceSpan(s.location, max(0, index.contentEnd(ofLine: line) - s.location)); break
                    }
                }
            }
            let isList = node is UnorderedList || node is OrderedList
            if topLevel && !isList || topLevelItem { output.blocks.append(Block(s, isListItem: topLevelItem)) }
            if topLevel, isList {
                for child in node.children { walk(child, topLevelItem: true) }
                return
            }
            func add(_ kind: StyleKind, markers: [SourceSpan] = []) { output.styles.append(StyleRun(span: s, kind: kind, markers: markers)) }
            func edges(_ n: Int) -> [SourceSpan] { s.length >= n * 2 ? [SourceSpan(s.location, n), SourceSpan(s.end - n, n)] : [] }
            switch node {
            case let heading as Heading:
                let raw = index.text(in: s)
                let prefix = raw.prefix { $0 == "#" || $0 == " " }.utf16.count
                var markers: [SourceSpan] = []
                if raw.hasPrefix("#") { markers.append(SourceSpan(s.location, prefix)) }
                else if let last = raw.lastIndex(where: { $0.isNewline }) {                // "\r\n" is one Character
                    markers.append(SourceSpan(s.location + last.utf16Offset(in: raw), raw[last...].utf16.count))
                }
                add(.heading(heading.level), markers: markers)
            case is Strong: add(.strong, markers: edges(2))
            case is Emphasis: add(.emphasis, markers: edges(1))
            case is Strikethrough: add(.strike, markers: edges(2))
            case is InlineCode:
                let raw = index.text(in: s)
                let count = raw.prefix { $0 == "`" }.count
                add(.code, markers: edges(count)); protected.append(s)
            case let code as CodeBlock:
                protected.append(s)
                let lang = (code.language ?? "").lowercased().split(separator: " ").first.map(String.init) ?? ""
                if lang == "mermaid" || lang == "math" || lang == "latex" {
                    output.elements.append(RenderElement(span: s, kind: lang == "mermaid" ? .mermaid : .math, content: code.code))
                } else {
                    var markers = fenceMarkers(index.text(in: s), at: s.location)
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
                let raw = index.text(in: s)
                var markers: [SourceSpan] = []
                if let regex = quoteMarker {
                    for match in regex.matches(in: raw, range: NSRange(location: 0, length: (raw as NSString).length)) {
                        markers.append(SourceSpan(s.location + match.range.location, match.range.length))
                    }
                }
                add(.quote, markers: markers)
            case is ListItem:
                let raw = index.text(in: s)
                var extra: [StyleRun] = [], markers: [SourceSpan] = []
                if let regex = listItemMarker,
                   let m = regex.firstMatch(in: raw, range: NSRange(location: 0, length: (raw as NSString).length)) {
                    let marker = m.range(at: 1), box = m.range(at: 2)
                    // Only bulleted items are tasks. An ordered item keeps its number visible and
                    // its brackets as text, so a number and a checkbox are never active together.
                    if box.location != NSNotFound, marker.length == 1 {
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
        for child in document.children { walk(child, topLevel: true) }
        if !blockSpansComplete { output.blocks.removeAll() }
        MarkdownParser.finish(&output, protected: protected, units: nil)
        return output
    }
}
