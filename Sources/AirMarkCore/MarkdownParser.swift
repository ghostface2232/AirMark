import Foundation

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
/// A top-level block, or an item of a top-level list. Two items may be cut apart with no blank line
/// between them: a list item starts on its own line whatever precedes it in the list.
public struct Block: Hashable, Sendable {
    public var span: SourceSpan
    public var isListItem: Bool
    public init(_ span: SourceSpan, isListItem: Bool = false) { self.span = span; self.isListItem = isListItem }
    public var location: Int { span.location }
    public var end: Int { span.end }
}
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
    /// What `MarkdownParser.reparse` cuts between, in order: the top-level blocks, with a top-level list
    /// given as its items, so typing in a long list does not reparse the list. Empty when one of them
    /// has no source range or the document exceeded a nesting limit.
    public var blocks: [Block]
    /// The source's link reference definitions, in order. They resolve links anywhere in the document,
    /// so `MarkdownParser.reparse` hands the ones outside its window to the parse of the window.
    public var definitions: [ReferenceDefinition] = []
    /// At least the bytes this document's reference links expand to, which cmark caps; see
    /// `MarkdownParser.referenceExpansionFloor`. Exact after a whole parse, and only ever over after
    /// a partial one, which adds its window's without taking away what the window held before.
    public var referenceExpansion = 0
    public init(source: String, revision: UInt64 = 0, styles: [StyleRun] = [], elements: [RenderElement] = [], checkboxes: [SourceSpan] = [],
                blocks: [Block] = []) {
        self.source = source; self.revision = revision; self.styles = styles; self.elements = elements; self.checkboxes = checkboxes
        self.blocks = blocks
    }
}

/// Parses off the main actor on a thread with a large stack. The tree is walked recursively, and a
/// concurrency-pool thread's stack (about 512KB) ran out at about 70 nested block quotes when
/// swift-markdown's conversion was the recursion, which crashed the app. With 16MB, nesting survives
/// far past `MarkdownParser.nestingLimit`.
///
/// A parse thread cannot be stopped, so parses run one at a time: callers wait their turn in order,
/// and a caller cancelled while waiting leaves the queue at once instead of holding its source until
/// the running parse ends. Without this, typing in a large document started a new thread every few
/// hundred milliseconds while earlier ones were still parsing.
public actor MarkdownParsingWorker {
    static let stackSize = 16 << 20
    private var busy = false
    private var waiting: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)] = []
    /// The last parse and the caller's edit number it was made at, which the next request's edits start from.
    private var last: (document: ParsedDocument, sequence: Int)?
    /// The parse before `last`, released when the next one replaces it. The caller still holds it when
    /// a parse arrives, and releasing a large parse costs milliseconds, so the last release happens here.
    private var retired: ParsedDocument?
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
    ///
    /// `sequence` numbers this request among the caller's edits. When `edits` are those made since the
    /// request numbered `since`, which this worker parsed last, only the blocks they touched are parsed
    /// again (`MarkdownParser.reparse`) and `changed` is the span outside which the result is that
    /// parse moved by the edits; otherwise the document is parsed whole and `changed` is nil.
    public func parsePresentation(_ source: String, revision: UInt64, sequence: Int? = nil, edits: (since: Int, edits: [PresentationEdit])? = nil)
        async throws -> (document: ParsedDocument, store: PresentationStore, cost: Duration, changed: SourceSpan?) {
        try await takeTurn()
        defer { endTurn() }
        try Task.checkCancellation()
        let previous = last.flatMap { last in edits.flatMap { $0.since == last.sequence ? last.document : nil } }
        let result = await onLargeStack {
            let started = ContinuousClock.now
            let reparsed = previous.flatMap { MarkdownParser.reparse(source, revision: revision, previous: $0, edits: edits?.edits ?? []) }
            let document = reparsed?.document ?? MarkdownParser.parse(source, revision: revision)
            let store = PresentationStore(document)
            return (document: document, store: store, cost: started.duration(to: ContinuousClock.now), changed: reparsed?.changed)
        }
        retired = last?.document
        last = sequence.map { (result.document, $0) }
        return result
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
    public static func nestingEstimate(_ source: String) -> Int { withBytes(source, nestingEstimate) }
    static func nestingEstimate(_ bytes: Bytes) -> Int {
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

    /// An upper bound on inline nesting within a paragraph: the open emphasis delimiters plus the open
    /// brackets, counted separately and added. Every run of `*`, `_` or `~` that could open emphasis (not
    /// followed by whitespace) adds its length, and a run that can only close subtracts it; treating runs
    /// that could both open and close as openers only overestimates. An `_` run inside a word can neither
    /// open nor close and is skipped. `[` and `]` add and subtract one. A backslash makes the next character
    /// literal. Lines inside a fenced code block are skipped. Counts restart at blank lines, which end
    /// paragraphs; CRLF is one line break. Linear; no parse.
    public static func inlineNestingEstimate(_ source: String) -> Int { withBytes(source, inlineNestingEstimate) }
    static func inlineNestingEstimate(_ bytes: Bytes) -> Int { inlineNesting(bytes).estimate }
    /// The estimate, and whether any line was taken for a fence. Fences are the one thing the estimate
    /// carries from one paragraph to the next, so text without them is estimated the same alone as in
    /// its document; `reparse` relies on that.
    static func inlineNesting(_ source: String) -> (estimate: Int, fences: Bool) { withBytes(source) { inlineNesting($0) } }
    static func inlineNesting(_ bytes: Bytes) -> (estimate: Int, fences: Bool) {
        var deepest = 0, emphasis = 0, brackets = 0, index = 0, fences = false
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
                    fences = true
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
        return (deepest, fences)
    }

    /// Compiled once: compiling this per list item was about an eighth of a 10MB parse.
    /// `NSRegularExpression` is immutable and safe to match from several threads.
    nonisolated(unsafe) static let listItemMarker = try? NSRegularExpression(pattern: "^[ \\t]*([-+*]|[0-9]+[.)])[ \\t]+(?:(\\[[ xX]\\])(?=[ \\t]))?")

    /// cmark stops resolving reference links once their destinations and titles add up to the size of
    /// the document, or to this when the document is smaller: a defence against a short document that
    /// expands without bound. A window is smaller than its document, so its parse has less to spend.
    /// A partial parse is used only while the whole document's links fit under the cap with room for
    /// the largest definition; then no link in either parse is refused, and the two agree.
    static let referenceExpansionFloor = 100_000

    /// Whether `source` contains `]:`, which every link reference definition does.
    static func mayDefineReferences(_ source: String) -> Bool { withBytes(source, mayDefineReferences) }
    static func mayDefineReferences(_ bytes: Bytes) -> Bool {
        var previous: UInt8 = 0
        for byte in bytes {
            if byte == 58, previous == 93 { return true }
            previous = byte
        }
        return false
    }

    typealias Bytes = UnsafeBufferPointer<UInt8>

    /// `parse` comes here once for every scan it makes and for cmark; copying the bytes into an array
    /// per scan cost two document-sized allocations per parse.
    static func withBytes<Result>(_ source: String, _ body: (Bytes) -> Result) -> Result { source.withUTF8Bytes(body) }

    private static func leadingByteOrderMarks(_ bytes: Bytes) -> Int {
        var index = 0
        while index + 2 < bytes.count, bytes[index] == 0xEF, bytes[index + 1] == 0xBB, bytes[index + 2] == 0xBF { index += 3 }
        return index
    }

    public static func parse(_ source: String, revision: UInt64 = 0) -> ParsedDocument {
        parse(source, revision: revision, enforcingLimit: true)
    }
    static func parse(_ source: String, revision: UInt64, enforcingLimit: Bool) -> ParsedDocument {
        parse(source, revision: revision, enforcingLimit: enforcingLimit, before: [], after: [])!
    }
    /// `source` parsed as part of a document whose other link reference definitions are `before` and
    /// `after` it; the result's `definitions` are the source's own. Nil when the source ends inside a
    /// paragraph, whose definitions could then not be ranked before `after`.
    static func parse(_ source: String, revision: UInt64, enforcingLimit: Bool, before: [ReferenceDefinition], after: [ReferenceDefinition]) -> ParsedDocument? {
        var output = ParsedDocument(source: source, revision: revision)
        var bytes = 0
        let parsed: MarkdownTree? = withBytes(source) {
            bytes = $0.count
            if enforcingLimit, nestingEstimate($0) > nestingLimit || inlineNestingEstimate($0) > inlineNestingLimit { return nil }
            return MarkdownTree(parsing: $0, before: before, after: after)
        }
        guard let document = parsed else { return output }
        guard document.definitionsAreOrdered else { return nil }
        output.definitions = Array(document.definitions[document.ownDefinitions])
        // A whole parse that came near the cap may have had links refused, which no window would see.
        let largest = document.definitions.lazy.map(\.size).max() ?? 0
        let refused = document.referenceExpansion + largest > max(referenceExpansionFloor, bytes)
        output.referenceExpansion = refused ? .max / 2 : document.referenceExpansion
        let index = SourceIndex(source)
        var protected: [SourceSpan] = []
        /// Column corrections for inline nodes, by line. cmark reports inline columns on a paragraph's
        /// continuation lines relative to where it considers the line's content to start, so
        /// "para\n   three **b**" placed the strong run three columns early and concealed "ee". The shift is
        /// first estimated from the line's leading whitespace and quote markers, then checked against the
        /// delimiters (and, on one line, the text) of nodes that have them; a line whose delimiters are
        /// found elsewhere nearby takes that shift for all its inline nodes. A delimited node that cannot be
        /// matched to its source is left unstyled.
        var inlineColumnShift: [Int: Int] = [:]
        /// Lines to add to the inline positions of the paragraph or heading being walked. cmark takes
        /// the link reference definitions off the front of a paragraph before it parses its inlines, and
        /// then numbers the lines of what is left from the paragraph's first line, so every inline after
        /// a definition was placed that many lines early: its delimiters were not found there and it
        /// went unstyled, `**bold**` on the line after `[a]: /u` included.
        var inlineLineShift = 0
        func offsets(_ r: MarkdownTree.Range, shift lower: Int, _ upper: Int) -> SourceSpan? {
            guard let a = index.offset(line: r.lowerLine, utf8Column: r.lowerColumn + lower),
                  let b = index.offset(line: r.upperLine, utf8Column: r.upperColumn + upper), b >= a, b <= index.utf16Count else { return nil }
            return SourceSpan(a, b - a)
        }
        /// The characters a delimited inline node's source must start and end with, or nil.
        func delimiters(_ kind: MarkdownTree.Kind) -> (start: Set<UInt16>, end: Set<UInt16>)? {
            switch kind {
            case .strong, .emphasis: return ([42, 95], [42, 95])                      // * _
            case .strikethrough: return ([126], [126])                                // ~
            case .inlineCode: return ([96], [96])                                     // `
            case .link: return ([91, 60], [41, 93, 62])                               // [ <  ) ] >
            case .image: return ([33], [41, 93])                                      // !  ) ]
            default: return nil
            }
        }
        func span(_ node: MarkdownTree.Node) -> SourceSpan? {
            guard var r = node.range else { return nil }
            guard !node.isBlock else { return offsets(r, shift: 0, 0) }
            r.lowerLine += inlineLineShift; r.upperLine += inlineLineShift
            let lowerLine = r.lowerLine, upperLine = r.upperLine
            let lower = inlineColumnShift[lowerLine] ?? 0, upper = inlineColumnShift[upperLine] ?? 0
            let estimated = offsets(r, shift: lower, upper)
            guard let expected = delimiters(node.kind) else { return estimated }
            // On one line, a shifted candidate must also contain the node's text: adjacent runs such as
            // "**b**> **b**" put matching delimiters at the ends of a wrong candidate. Computed only when a
            // shift is involved; unshifted positions are what the parser reported and are accepted.
            var content: String?
            func fits(_ span: SourceSpan?, checkingContent: Bool) -> Bool {
                guard let span, span.length >= 2 else { return false }
                guard expected.start.contains(index.unit(at: span.location)), expected.end.contains(index.unit(at: span.end - 1)) else { return false }
                guard checkingContent, lowerLine == upperLine else { return true }
                if content == nil { content = node.plainText }
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
        func continuationShifts(_ paragraph: MarkdownTree.Node) -> [Int: Int] {
            guard let range = paragraph.range, range.upperLine > range.lowerLine else { return [:] }
            var shifts: [Int: Int] = [:]
            for line in (range.lowerLine + 1)...min(range.upperLine, index.lines.count) {
                let contentStart = index.leadingUnits(ofLine: line) { $0 == 32 || $0 == 9 || $0 == 62 }   // space, tab, ">"
                let shift = contentStart - (range.lowerColumn - 1)
                if shift != 0 { shifts[line] = shift }
            }
            return shifts
        }
        /// Where, on each line, the containers walked so far stop and their content starts, as cmark
        /// leaves it after matching them: an offset, and the column there, which differs from the
        /// offset after a tab and may stand inside one that a container took part of. -1 is the line's
        /// start; `lazy` is a line that continues a paragraph without its containers' markers, on which
        /// the containers further in have none either. A block quote's marker on a line is the next `>`
        /// from there, and a list item's content starts past its indentation, so each container reads
        /// one line's prefix once and leaves the rest to the containers inside it.
        ///
        /// Matching `^[ \t]{0,3}>` over each quote's own text instead found, on every line after a
        /// nested quote's first, the outer quote's `>` again: the inner one was never hidden, and the
        /// text of a quote was copied and matched once for each quote around it.
        let lazy = -2
        var contentStart = [Int](repeating: -1, count: index.lines.count)
        var contentColumn = [Int](repeating: 0, count: index.lines.count)
        /// Where the spaces and tabs at `offset` on one-based `line` end, with tabs to stops of four from
        /// `column`. Every list item around a line asks this of the same run of spaces, each from a
        /// little further in, so the answer is kept until a `>` moves the line past it.
        var indentationEnd = [(offset: Int, column: Int)](repeating: (-1, 0), count: index.lines.count)
        func indentation(onLine line: Int, from offset: Int, column: Int, to end: Int) -> (offset: Int, column: Int) {
            if indentationEnd[line - 1].offset >= offset { return indentationEnd[line - 1] }
            indentationEnd[line - 1] = indentation(from: offset, column: column, to: end)
            return indentationEnd[line - 1]
        }
        func indentation(from offset: Int, column: Int, to end: Int) -> (offset: Int, column: Int) {
            var offset = offset, column = column
            while offset < end {
                switch index.unit(at: offset) {
                case 32: column += 1
                case 9: column += 4 - column % 4
                default: return (offset, column)
                }
                offset += 1
            }
            return (offset, column)
        }
        /// Moves `count` columns on, as cmark's `S_advance_offset` does: a tab wider than what is left
        /// to take is taken in part, and the offset stays on it.
        func advance(_ offset: inout Int, _ column: inout Int, by count: Int, to end: Int) {
            var count = count
            while count > 0, offset < end {
                let width = index.unit(at: offset) == 9 ? 4 - column % 4 : 1
                column += min(count, width)
                if count >= width { offset += 1 }
                count -= min(count, width)
            }
        }
        /// The marker of a block quote on one-based `line`: up to three columns of indentation, `>`,
        /// and one column of space after it. `first` is where the quote itself starts, on its first
        /// line. Nil on a line the quote only continues lazily.
        func quoteMarker(onLine line: Int, first: Int?) -> SourceSpan? {
            let lineStart = index.lines[line - 1].location, end = index.contentEnd(ofLine: line)
            guard contentStart[line - 1] != lazy || first != nil else { return nil }
            let start = first ?? max(contentStart[line - 1], lineStart)
            let mark: (offset: Int, column: Int)
            if let first {
                // The prefix before it is markers, spaces and tabs, a column each but for the tabs.
                var column = 0
                for offset in lineStart..<first { column += index.unit(at: offset) == 9 ? 4 - column % 4 : 1 }
                mark = (first, column)
            } else {
                let column = contentColumn[line - 1]
                mark = indentation(onLine: line, from: start, column: column, to: end)
                guard mark.column - column <= 3, mark.offset < end, index.unit(at: mark.offset) == 62 else {   // ">"
                    if mark.offset < end { contentStart[line - 1] = lazy }
                    return nil
                }
            }
            var offset = mark.offset + 1, column = mark.column + 1
            if offset < end, index.unit(at: offset) == 32 || index.unit(at: offset) == 9 { advance(&offset, &column, by: 1, to: end) }
            contentStart[line - 1] = offset; contentColumn[line - 1] = column
            return SourceSpan(start, offset - start)
        }
        /// Whether one-based `line`'s content, past its containers, is a setext underline: up to three
        /// columns of indentation, counted as cmark counts them from where the containers left off (a tab
        /// they took part of is part of it), then only `=` or only `-`, then spaces and tabs. A lazy line
        /// is not one.
        func isSetextUnderline(_ line: Int) -> Bool {
            guard line >= 1, line <= index.lines.count, contentStart[line - 1] != lazy else { return false }
            let end = index.contentEnd(ofLine: line), column = contentColumn[line - 1]
            let indented = indentation(from: max(contentStart[line - 1], index.lines[line - 1].location), column: column, to: end)
            guard indented.column - column <= 3 else { return false }
            var position = indented.offset
            let mark = index.unit(at: position)
            guard position < end, mark == 61 || mark == 45 else { return false }                          // "=" or "-"
            while position < end, index.unit(at: position) == mark { position += 1 }
            while position < end, index.unit(at: position) == 32 || index.unit(at: position) == 9 { position += 1 }
            return position == end
        }
        /// Lines the link reference definitions at the front of a paragraph took, found by where its last
        /// inline really ends against where cmark numbered it; 0 when the last inline has no position.
        func definitionLines(lastTextLine: Int, _ node: MarkdownTree.Node) -> Int {
            guard let last = node.lastChild?.range else { return 0 }
            return max(0, lastTextLine - last.upperLine)
        }
        /// A list item's later lines start their content past the item's indentation, which cmark keeps
        /// as columns from where the containers around the item stop. A line indented less is blank or
        /// continues a paragraph lazily.
        func indentItemContent(_ item: MarkdownTree.Node, _ range: MarkdownTree.Range) {
            guard range.upperLine > range.lowerLine else { return }
            for line in (range.lowerLine + 1)...min(range.upperLine, index.lines.count) where contentStart[line - 1] != lazy {
                let end = index.contentEnd(ofLine: line)
                var offset = max(contentStart[line - 1], index.lines[line - 1].location), column = contentColumn[line - 1]
                let content = indentation(onLine: line, from: offset, column: column, to: end)
                if content.offset == end { (offset, column) = content }
                else if content.column - column >= item.itemIndentation { advance(&offset, &column, by: item.itemIndentation, to: end) }
                else { contentStart[line - 1] = lazy; continue }
                contentStart[line - 1] = offset; contentColumn[line - 1] = column
            }
        }
        // Top-level blocks, and the items of top-level lists, are what `reparse` cuts between; their
        // spans are the ones `walk` computes anyway, except for a paragraph, whose own span it has no
        // other use for.
        var blockSpansComplete = true
        /// The estimates above are meant to bound the tree's depth and do not always: they take `~~~`
        /// inside an HTML block for a fence and skip what follows. The walk is the recursion they
        /// protect, so it counts for itself, and a tree deeper than both limits together is presented
        /// as plain text like one the estimates turned away. Measured on the tree, the verdict on a
        /// block is the same whether it is parsed in a window or in its document.
        var tooDeep = false
        /// `within` is where the block quote or list item around the node ends.
        func walk(_ node: MarkdownTree.Node, topLevel: Bool = false, topLevelItem: Bool = false, within: Int? = nil, depth: Int = 0) {
            guard depth <= nestingLimit + inlineNestingLimit else { tooDeep = true; return }
            let kind = node.kind
            if kind == .paragraph {
                if topLevel {
                    if let span = span(node) { output.blocks.append(Block(span)) } else { blockSpansComplete = false }
                }
                let outer = (inlineColumnShift, inlineLineShift)
                inlineColumnShift = continuationShifts(node)
                // A paragraph's last inline ends on its last line.
                inlineLineShift = node.range.map { definitionLines(lastTextLine: $0.upperLine, node) } ?? 0
                for child in node.children { walk(child, depth: depth + 1) }
                (inlineColumnShift, inlineLineShift) = outer
                return
            }
            // Plain text and line breaks are most nodes and add no style; their spans have no side
            // effects (no delimiters to match), so skip computing them.
            if kind == .text || kind == .softBreak || kind == .lineBreak { return }
            let cut = topLevel && kind != .list || topLevelItem
            var resolved = span(node)
            // The two blocks below are given an end on the line after them, and that line need not be
            // addressable: cmark counts a NUL as the three bytes it replaces it with. Their start is
            // enough, since their end is worked out here anyway; without it the block was dropped from
            // the whole parse and kept by a window that stopped before that line.
            if resolved == nil, let range = node.range, let start = index.offset(line: range.lowerLine, utf8Column: range.lowerColumn) {
                if kind == .codeBlock, let within, start <= within { resolved = SourceSpan(start, within - start) }
                else if node.isSetextHeading { resolved = SourceSpan(start, 0) }
            }
            guard var s = resolved else {
                if topLevel || topLevelItem { blockSpansComplete = false }
                for child in node.children { walk(child, within: within, depth: depth + 1) }
                return
            }
            // cmark gives a setext heading, like a fenced block, the end of the line being read when it
            // closes, which is the line after its underline, or the underline itself at the end of the
            // input: the span took the next line in, hid it as the underline, and left the underline
            // showing. The heading ends with its underline, the one of those two lines that is one. (Not
            // found from the heading's text: text cmark made from delimiters it did not match, such as a
            // lone `~~`, has no position.)
            //
            // A heading made from a paragraph that began with link reference definitions keeps the
            // paragraph's start, though the definitions are not its text, and its inlines are numbered
            // from there as a paragraph's are. The heading's text starts where its first inline does.
            var headingLines = 0, headingStart: Int?
            if node.isSetextHeading, let range = node.range,
               let underline = [range.upperLine - 1, range.upperLine].first(where: { $0 > range.lowerLine && isSetextUnderline($0) }) {
                s = SourceSpan(s.location, max(0, index.contentEnd(ofLine: underline) - s.location))
                headingLines = definitionLines(lastTextLine: underline - 1, node)
                if headingLines > 0, let first = node.firstChild?.range,
                   let start = index.offset(line: first.lowerLine + headingLines, utf8Column: first.lowerColumn), start < s.end {
                    headingStart = start
                }
            }
            // A fence left open ends with the container it is in, but cmark gives a fenced block the
            // end of the line being read when it closes, taking that for the closing fence; here it is
            // the first line after the container, which was then styled as code and kept from math.
            if kind == .codeBlock, let within, s.end > within { s = SourceSpan(s.location, max(0, within - s.location)) }
            if cut { output.blocks.append(Block(s, isListItem: topLevelItem)) }
            if topLevel, kind == .list {
                for child in node.children { walk(child, topLevelItem: true, depth: depth + 1) }
                return
            }
            func add(_ kind: StyleKind, markers: [SourceSpan] = []) { output.styles.append(StyleRun(span: s, kind: kind, markers: markers)) }
            func edges(_ n: Int) -> [SourceSpan] { s.length >= n * 2 ? [SourceSpan(s.location, n), SourceSpan(s.end - n, n)] : [] }
            switch kind {
            case .heading:
                // The block keeps the definitions before a setext heading's text; the style does not.
                let styled = headingStart.map { SourceSpan($0, s.end - $0) } ?? s
                let raw = index.text(in: styled)
                let prefix = raw.prefix { $0 == "#" || $0 == " " }.utf16.count
                var markers: [SourceSpan] = []
                if raw.hasPrefix("#") { markers.append(SourceSpan(styled.location, prefix)) }
                else if let last = raw.lastIndex(where: { $0.isNewline }) {                // "\r\n" is one Character
                    markers.append(SourceSpan(styled.location + last.utf16Offset(in: raw), raw[last...].utf16.count))
                }
                output.styles.append(StyleRun(span: styled, kind: .heading(node.headingLevel), markers: markers))
            case .strong: add(.strong, markers: edges(2))
            case .emphasis: add(.emphasis, markers: edges(1))
            case .strikethrough: add(.strike, markers: edges(2))
            case .inlineCode:
                let raw = index.text(in: s)
                let count = raw.prefix { $0 == "`" }.count
                add(.code, markers: edges(count)); protected.append(s)
            case .codeBlock:
                protected.append(s)
                let lang = node.fenceInfo.lowercased().split(separator: " ").first.map(String.init) ?? ""
                if lang == "mermaid" || lang == "math" || lang == "latex" {
                    output.elements.append(RenderElement(span: s, kind: lang == "mermaid" ? .mermaid : .math, content: node.literal))
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
            case .blockQuote:
                var markers: [SourceSpan] = []
                if let range = node.range {
                    for line in range.lowerLine...min(range.upperLine, index.lines.count) {
                        if let marker = quoteMarker(onLine: line, first: line == range.lowerLine ? s.location : nil) { markers.append(marker) }
                    }
                }
                add(.quote, markers: markers)
            case .listItem:
                if let range = node.range { indentItemContent(node, range) }
                // The marker is on the item's first line; the item's whole text was copied here once for
                // every list around it.
                let firstLine = node.range.map { index.lines[min($0.lowerLine, index.lines.count) - 1].end } ?? s.end
                let raw = index.text(in: SourceSpan(s.location, max(0, min(s.end, firstLine) - s.location)))
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
            case .image:
                output.elements.append(RenderElement(span: s, kind: .image, content: node.destination, label: node.plainText))
                protected.append(s); return
            case .link:
                var markers: [SourceSpan] = []
                if let first = node.firstChild, let last = node.lastChild, let a = span(first), let b = span(last) {
                    if a.location > s.location { markers.append(SourceSpan(s.location, a.location - s.location)) }
                    if b.end < s.end { markers.append(SourceSpan(b.end, s.end - b.end)) }
                }
                add(.link(node.destination), markers: markers)
            case .table:
                // The header row, then the body rows; cmark keeps them as the table's children in order.
                let rows = node.children.map { row in row.children.map(\.plainText) }
                if let data = try? JSONEncoder().encode(rows), let json = String(data: data, encoding: .utf8) {
                    output.elements.append(RenderElement(span: s, kind: .table, content: json, label: "Table, \(rows.count) rows"))
                }
                protected.append(s); return
            case .thematicBreak: add(.rule)
            case .htmlBlock, .inlineHTML: protected.append(s)
            default: break
            }
            let inside = kind == .blockQuote || kind == .listItem ? s.end : within
            let outer = inlineLineShift
            if kind == .heading { inlineLineShift = headingLines }
            for child in node.children { walk(child, within: inside, depth: depth + 1) }
            inlineLineShift = outer
        }
        // Nodes point into the tree, which nothing after this line would otherwise keep alive.
        withExtendedLifetime(document) {
            for child in document.root.children { walk(child, topLevel: true) }
        }
        guard !tooDeep else { return ParsedDocument(source: source, revision: revision) }
        if !blockSpansComplete { output.blocks.removeAll() }
        finish(&output, protected: protected, units: index.units)
        return output
    }

    /// Orders what the walk collected, adds math, and drops styles inside it. `units` is the source's
    /// UTF-16 when the caller already has it.
    static func finish(_ output: inout ParsedDocument, protected: [SourceSpan], units: [UInt16]?) {
        // Sorted by start, containers before their contents, so presentation can binary-search.
        output.styles.sort { $0.span.location != $1.span.location ? $0.span.location < $1.span.location : $0.span.length > $1.span.length }
        output.elements += mathSpans(units ?? Array(output.source.utf16), excluding: protected)
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
    }

    /// The opening fence line including its line break, and the closing fence including the
    /// line break before it. Indented code blocks and unterminated fences have fewer markers.
    static func fenceMarkers(_ raw: String, at base: Int) -> [SourceSpan] {
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
        mathSpans(Array(source.utf16), excluding: excluding)
    }
    static func mathSpans(_ units: [UInt16], excluding: [SourceSpan]) -> [RenderElement] {
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
                result.append(RenderElement(span: s, kind: .math, content: String(decoding: units[(i + delimiter)..<close], as: UTF16.self), inline: !display))
                i = s.end
            } else {
                if display { displayFailsBefore = j } else { inlineFailsBefore = j }
                i += delimiter
            }
        }
        return result
    }
}
