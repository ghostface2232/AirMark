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

/// Parses off the main actor on a thread with a large stack. swift-markdown converts its tree
/// recursively, and a concurrency-pool thread's stack (about 512KB) ran out at about 70 nested block
/// quotes, which crashed the app. With 16MB, nesting survives past 1,500 levels, far above
/// `MarkdownParser.nestingLimit`.
///
/// A parse thread cannot be stopped, so parses run one at a time: callers wait their turn in order,
/// and a caller cancelled while waiting leaves the queue at once instead of holding its source until
/// the running parse ends. Without this, typing in a large document started a new thread every few
/// hundred milliseconds while earlier ones were still parsing.
public actor MarkdownParsingWorker {
    static let stackSize = 16 << 20
    private var busy = false
    private var waiting: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)] = []
    public init() {}
    public func parse(_ source: String, revision: UInt64) async throws -> ParsedDocument {
        try await takeTurn()
        defer { endTurn() }
        try Task.checkCancellation()
        return await onLargeStack { MarkdownParser.parse(source, revision: revision) }
    }
    /// The parse and the presentation built from it, so neither is constructed on the main actor,
    /// with what the work itself took. `cost` excludes waiting for a parse already running, so a
    /// caller can pace its requests by what a parse of this document costs rather than by how long
    /// it happened to wait.
    public func parsePresentation(_ source: String, revision: UInt64) async throws -> (document: ParsedDocument, store: PresentationStore, cost: Duration) {
        try await takeTurn()
        defer { endTurn() }
        try Task.checkCancellation()
        return await onLargeStack {
            let started = ContinuousClock.now
            let document = MarkdownParser.parse(source, revision: revision)
            let store = PresentationStore(document)
            return (document, store, started.duration(to: ContinuousClock.now))
        }
    }
    /// A parse that skips the nesting limit, for tests that compare the estimate with real depth.
    func parseIgnoringLimit(_ source: String) async throws -> ParsedDocument {
        try await takeTurn()
        defer { endTurn() }
        return await onLargeStack { MarkdownParser.parse(source, revision: 0, enforcingLimit: false) }
    }
    private func takeTurn() async throws {
        try Task.checkCancellation()
        guard busy else { busy = true; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in waiting.append((id, continuation)) }
        } onCancel: {
            Task { await self.leave(id) }
        }
    }
    private func leave(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(throwing: CancellationError())
    }
    /// Hands the turn to the next waiter, which then owns `busy`.
    private func endTurn() {
        if waiting.isEmpty { busy = false } else { waiting.removeFirst().continuation.resume() }
    }
    /// This worker's parse threads running now and the most seen at once; a test hook.
    final class ThreadCount: @unchecked Sendable {
        private let lock = NSLock()
        private var running = 0, highest = 0
        var peak: Int { lock.withLock { highest } }
        func enter() { lock.withLock { running += 1; highest = max(highest, running) } }
        func leave() { lock.withLock { running -= 1 } }
    }
    nonisolated let threads = ThreadCount()
    private func onLargeStack<Result: Sendable>(_ work: @escaping @Sendable () -> Result) async -> Result {
        let threads = threads
        return await withCheckedContinuation { continuation in
            let thread = Thread {
                threads.enter()
                let result = work()
                threads.leave()
                continuation.resume(returning: result)
            }
            thread.stackSize = Self.stackSize
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }
}

public enum MarkdownParser {
    /// Documents whose containers may nest deeper than this are presented as plain text. Real notes
    /// stay far below it; it exists so a short hostile line cannot exhaust the parser's stack, which
    /// on an 8MB main thread lasts to about 890 nested list items.
    public static let nestingLimit = 256
    /// The same for inline nesting (emphasis inside emphasis, brackets inside brackets). swift-markdown
    /// crashed a 16MB thread at about 2,050 nested emphasis levels.
    public static let inlineNestingLimit = 1_000

    /// An upper bound on container nesting: for each line, the block quote and list markers at its start
    /// plus half its leading whitespace in columns. A line stays inside a block quote only with its `>`
    /// and inside a list item only when indented at least two columns per item, so both are counted;
    /// separators after markers are counted too, which only overestimates. Tabs expand to the next stop
    /// from the line's real column, markers included. A lazy continuation line cannot open containers,
    /// so the line that opened them bounds the depth. Byte order marks at the start are skipped, as the
    /// parser skips them. Linear; no parse.
    public static func nestingEstimate(_ source: String) -> Int {
        withBytes(source) { bytes in
            var deepest = 0, depth = 0, whitespace = 0, column = 0, atLineStart = true
            var index = leadingByteOrderMarks(bytes)
            func endsMarker(_ position: Int) -> Bool {
                position >= bytes.count || bytes[position] == 32 || bytes[position] == 9 || bytes[position] == 10 || bytes[position] == 13
            }
            while index < bytes.count {
                let byte = bytes[index]
                if byte == 10 || byte == 13 {
                    deepest = max(deepest, depth + whitespace / 2)
                    depth = 0; whitespace = 0; column = 0; atLineStart = true
                    index += 1
                    continue
                }
                guard atLineStart else { index += 1; continue }
                switch byte {
                case 32: column += 1; whitespace += 1
                case 9: let width = 4 - column % 4; column += width; whitespace += width
                case 62: depth += 1; column += 1                                      // ">"
                case 45, 43, 42:                                                     // "-", "+", "*"
                    if endsMarker(index + 1) { depth += 1; column += 1 } else { atLineStart = false }
                case 48...57:                                                        // "1." or "1)"
                    var end = index
                    while end < bytes.count, (48...57).contains(bytes[end]) { end += 1 }
                    if end < bytes.count, bytes[end] == 46 || bytes[end] == 41, endsMarker(end + 1) {
                        depth += 1; column += end + 1 - index; index = end
                    } else { atLineStart = false }
                default: atLineStart = false
                }
                index += 1
            }
            return max(deepest, depth + whitespace / 2)
        }
    }

    /// An upper bound on inline nesting within a paragraph: the open emphasis delimiters plus the open
    /// brackets, counted separately and added. Every run of `*`, `_` or `~` that could open emphasis (not
    /// followed by whitespace) adds its length, and a run that can only close subtracts it; treating runs
    /// that could both open and close as openers only overestimates. An `_` run inside a word can neither
    /// open nor close and is skipped. `[` and `]` add and subtract one. A backslash makes the next character
    /// literal. Lines inside a fenced code block are skipped. Counts restart at blank lines, which end
    /// paragraphs; CRLF is one line break. Linear; no parse.
    public static func inlineNestingEstimate(_ source: String) -> Int {
        withBytes(source) { bytes in
            var deepest = 0, emphasis = 0, brackets = 0, index = 0
            var fence: (character: UInt8, length: Int)? = nil
            func isSpace(_ byte: UInt8) -> Bool { byte == 32 || byte == 9 || byte == 10 || byte == 13 }
            func isWordCharacter(_ byte: UInt8) -> Bool { byte >= 0x80 || (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) }
            while index < bytes.count {
                var lineEnd = index
                while lineEnd < bytes.count, bytes[lineEnd] != 10, bytes[lineEnd] != 13 { lineEnd += 1 }
                let next = lineEnd < bytes.count && bytes[lineEnd] == 13 && lineEnd + 1 < bytes.count && bytes[lineEnd + 1] == 10 ? lineEnd + 2 : lineEnd + 1
                // A fence line opens or closes a code block; neither it nor the block's content can nest inline.
                var start = index
                while start < lineEnd, start - index < 3, bytes[start] == 32 { start += 1 }
                if start < lineEnd, bytes[start] == 96 || bytes[start] == 126 {
                    var run = start
                    while run < lineEnd, bytes[run] == bytes[start] { run += 1 }
                    // A backtick fence's info string cannot contain a backtick; such a line is inline code.
                    let isFence = run - start >= 3 && (bytes[start] == 126 || fence != nil || !bytes[run..<lineEnd].contains(96))
                    if isFence {
                        if let open = fence {
                            if open.character == bytes[start], run - start >= open.length { fence = nil }
                        } else {
                            fence = (bytes[start], run - start)
                        }
                        emphasis = 0; brackets = 0
                        index = next
                        continue
                    }
                }
                if fence != nil { index = next; continue }
                var position = index, blank = true
                while position < lineEnd {
                    let byte = bytes[position]
                    switch byte {
                    case 92:                                                         // "\" escapes the next character
                        blank = false
                        position += position + 1 < lineEnd && !isSpace(bytes[position + 1]) ? 2 : 1
                    case 42, 95, 126:                                                // "*", "_", "~"
                        var end = position
                        while end < lineEnd, bytes[end] == byte { end += 1 }
                        let length = end - position
                        let before: UInt8? = position > 0 ? bytes[position - 1] : nil
                        let after: UInt8? = end < bytes.count ? bytes[end] : nil
                        let spaceBefore = before.map(isSpace) ?? true
                        let spaceAfter = after.map(isSpace) ?? true
                        let intraword = byte == 95 && before.map(isWordCharacter) == true && after.map(isWordCharacter) == true
                        if !intraword {
                            if !spaceAfter { emphasis += length } else if !spaceBefore { emphasis = max(0, emphasis - length) }
                        }
                        blank = false
                        position = end
                    case 91: brackets += 1; blank = false; position += 1               // "["
                    case 93: brackets = max(0, brackets - 1); blank = false; position += 1  // "]"
                    case 32, 9: position += 1
                    default: blank = false; position += 1
                    }
                    deepest = max(deepest, emphasis + brackets)
                }
                if blank { emphasis = 0; brackets = 0 }
                index = next
            }
            return deepest
        }
    }

    /// Compiled once: compiling these per list item and block quote was about a quarter of a 10MB
    /// parse. `NSRegularExpression` is immutable and safe to match from several threads.
    nonisolated(unsafe) private static let quoteMarker = try? NSRegularExpression(pattern: "^[ \\t]{0,3}>[ \\t]?", options: .anchorsMatchLines)
    nonisolated(unsafe) private static let listItemMarker = try? NSRegularExpression(pattern: "^[ \\t]*([-+*]|[0-9]+[.)])[ \\t]+(?:(\\[[ xX]\\])(?=[ \\t]))?")

    private static func withBytes<Result>(_ source: String, _ body: ([UInt8]) -> Result) -> Result {
        body(Array(source.utf8))
    }

    private static func leadingByteOrderMarks(_ bytes: [UInt8]) -> Int {
        var index = 0
        while index + 2 < bytes.count, bytes[index] == 0xEF, bytes[index + 1] == 0xBB, bytes[index + 2] == 0xBF { index += 3 }
        return index
    }

    public static func parse(_ source: String, revision: UInt64 = 0) -> ParsedDocument {
        parse(source, revision: revision, enforcingLimit: true)
    }
    static func parse(_ source: String, revision: UInt64, enforcingLimit: Bool) -> ParsedDocument {
        if enforcingLimit, nestingEstimate(source) > nestingLimit || inlineNestingEstimate(source) > inlineNestingLimit {
            return ParsedDocument(source: source, revision: revision)
        }
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
        func walk(_ node: any Markup) {
            if let paragraph = node as? Paragraph {
                let outer = inlineColumnShift
                inlineColumnShift = continuationShifts(paragraph)
                for child in node.children { walk(child) }
                inlineColumnShift = outer
                return
            }
            // Plain text and line breaks are most nodes and add no style; their spans have no side
            // effects (no delimiters to match), so skip computing them and the casts below.
            if node is Text || node is SoftBreak || node is LineBreak { return }
            guard let s = span(node) else { for child in node.children { walk(child) }; return }
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
        walk(document)
        // Sorted by start, containers before their contents, so presentation can binary-search.
        output.styles.sort { $0.span.location != $1.span.location ? $0.span.location < $1.span.location : $0.span.length > $1.span.length }
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
        // In an empty block the break before the closing fence is the opening marker's own break; the
        // markers of one style stay disjoint, which the presentation store's searches rely on.
        start = max(start, NSMaxRange(firstLine))
        markers.append(SourceSpan(base + start, end - start))
        return markers
    }

    /// `$…$` and `$$…$$` outside protected spans. One pass: a scan that finds no closing delimiter
    /// stops at a boundary (a line break for inline math, a protected span or the end for both), and
    /// no later opener of the same kind before that boundary can close either, because whether a `$`
    /// closes depends only on its own neighbours. Remembering the boundary keeps a line of unclosed
    /// `$` linear instead of rescanning the rest of the line from each one.
    static func mathSpans(_ source: String, excluding: [SourceSpan]) -> [RenderElement] {
        let units = Array(source.utf16), text = source as NSString
        var result: [RenderElement] = [], i = 0, protectedIndex = 0
        var inlineFailsBefore = 0, displayFailsBefore = 0
        let excluded = excluding.sorted { $0.location < $1.location }
        func escaped(_ n: Int) -> Bool { var j = n - 1, c = 0; while j >= 0 && units[j] == 92 { c += 1; j -= 1 }; return c % 2 == 1 }
        func whitespace(_ u: UInt16) -> Bool { u == 32 || u == 9 || u == 10 || u == 13 }
        /// A line break at `n` followed by a line of only spaces and tabs: a paragraph break, which ends
        /// display math as it does in TeX, so an opening `$$` cannot pair across paragraphs.
        func blankLineAfter(_ n: Int) -> Bool {
            guard units[n] == 10 || units[n] == 13 else { return false }
            var k = n + (units[n] == 13 && n + 1 < units.count && units[n + 1] == 10 ? 2 : 1)
            while k < units.count && (units[k] == 32 || units[k] == 9) { k += 1 }
            return k < units.count && (units[k] == 10 || units[k] == 13)
        }
        while i < units.count {
            while protectedIndex < excluded.count && excluded[protectedIndex].end <= i { protectedIndex += 1 }
            if protectedIndex < excluded.count && excluded[protectedIndex].contains(i) { i = excluded[protectedIndex].end; continue }
            guard units[i] == 36, !escaped(i), i + 1 < units.count else { i += 1; continue }
            let display = units[i + 1] == 36, delimiter = display ? 2 : 1
            if !display && whitespace(units[i + 1]) { i += 1; continue }
            if i < (display ? displayFailsBefore : inlineFailsBefore) { i += delimiter; continue }
            var j = i + delimiter, found: Int?
            while j < units.count {
                if (!display && (units[j] == 10 || units[j] == 13)) || (display && blankLineAfter(j)) { break }
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
            } else {
                if display { displayFailsBefore = j } else { inlineFailsBefore = j }
                i += delimiter
            }
        }
        return result
    }
}
