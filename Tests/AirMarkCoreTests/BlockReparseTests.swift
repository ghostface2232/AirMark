import Foundation
import Testing
import Markdown
@testable import AirMarkCore

/// `MarkdownParser.reparse` must produce exactly the whole-document parse after any sequence of edits.
struct BlockReparseTests {
    typealias Generator = PresentationStoreTests.Generator
    static let lines = ["# Heading", "## Sub", "Title", "===", "---", "***", "para with **bold** and *em*", "continued `code` line",
                        "   indented lazy line", "> quote", "> > nested", "- item", "- [ ] task", "  - child", "    four spaces", "1. one",
                        "* star", "```", "```swift", "~~~", "$$", "x^2 $$ y", "$a$ and $$b$$", "| a | b |", "| - | - |", "<div>",
                        "</div>", "<!--", "-->", "![i](p.png)", "[l](u)", "[r][id]", "[ID] and [x][Dup] and [none]", "![img][pic] [t][ titled ]", "한글 😀 e\u{301}", "\t tab", "", "", "", " \t"]
    static let insertions = ["\n", "\n\n", "\r\n", "\r", "#", "# ", ">", "> ", "- ", "1. ", "*", "**", "_", "`", "```", "~~~", "$", "$$",
                             "|", "<", "<!--", "-->", "[", "]", "](u)", "    ", "\t", "x", "word ", "한", "😀", "---\n", "===\n"]

    /// Definitions in the forms cmark cleans differently, with a label defined twice (the first wins),
    /// one spelled in another case, one inside a container and one in swift-cmark's attribute form.
    static let definitions = ["[id]: /u", "[ID]: /shadowed", "[dup]: /first", "[dup]: /second 'never'", "[pic]: <p q.png> \"a \\\" title\"",
                              "[ titled ]: /t\n  'two\nlines'", "> [quoted]: /in-a-quote", "[amp]: /a&amp;b\\*c", "^[attr]: {\"k\": 1}",
                              "[id]: /u\n[dup]: /again\ntrailing text"]

    /// Blocks of one to four lines, mostly separated by blank lines as real documents are, with the
    /// line ending of the whole document varying. Half the documents define link references, up to
    /// six of them, anywhere.
    static func document(_ generator: inout Generator) -> String {
        let newline = ["\n", "\n", "\r\n", "\r"][generator.next(4)]
        var blocks = (0..<(4 + generator.next(60))).map { _ in
            (0..<(1 + generator.next(4))).map { _ in lines[generator.next(lines.count)] }.joined(separator: newline)
        }
        if generator.next(2) == 0 {
            for _ in 0..<(1 + generator.next(6)) { blocks.insert(definitions[generator.next(definitions.count)], at: generator.next(blocks.count + 1)) }
        }
        return blocks.map { $0 + newline + (generator.next(5) == 0 ? "" : newline) }.joined()
    }

    /// An edit on composed character boundaries, as the text view makes.
    static func edit(_ generator: inout Generator, in text: NSString) -> (range: NSRange, replacement: String) {
        let location = generator.next(text.length + 1)
        var range = NSRange(location: location, length: generator.next(3) == 0 ? generator.next(min(30, text.length - location) + 1) : 0)
        if text.length > 0 { range = text.rangeOfComposedCharacterSequences(for: range) }
        let replacement = generator.next(4) == 0 ? "" : generator.next(200) == 0 ? "]: /d" : insertions[generator.next(insertions.count)]
        return (range, replacement)
    }

    /// Styles in a canonical order: the parser sorts by start and length, which leaves the order of runs
    /// with equal spans unspecified.
    static func canonical(_ document: ParsedDocument) -> [String] {
        document.styles.map { "\($0.span) \($0.kind) \($0.markers)" }.sorted()
    }

    /// `definitions` is false for the reference parser, which swift-markdown gives none to.
    static func expectSame(_ actual: ParsedDocument, _ expected: ParsedDocument, _ context: String, definitions: Bool = true) -> Bool {
        let same = canonical(actual) == canonical(expected) && actual.elements == expected.elements
            && actual.checkboxes == expected.checkboxes && actual.blocks == expected.blocks
            && (!definitions || actual.definitions == expected.definitions) && actual.source == expected.source
        let differing = [canonical(actual) == canonical(expected) ? nil : "styles", actual.elements == expected.elements ? nil : "elements",
                         actual.checkboxes == expected.checkboxes ? nil : "checkboxes", actual.blocks == expected.blocks ? nil : "blocks",
                         !definitions || actual.definitions == expected.definitions ? nil : "definitions"].compactMap { $0 }
        #expect(same, "differing: \(differing) \(context)")
        return same
    }

    @Test func reparseEqualsWholeParseAfterRandomEdits() {
        var generator = Generator(state: 23)
        var reparsed = 0, whole = 0, partial = 0, partialWithDefinitions = 0
        for round in 0..<600 {
            let text = NSMutableString(string: Self.document(&generator))
            var previous = MarkdownParser.parse(text as String)
            for step in 0..<30 {
                var edits: [PresentationEdit] = []
                for _ in 0..<(1 + generator.next(3)) {
                    let (range, replacement) = Self.edit(&generator, in: text)
                    edits.append(PresentationEdit(range: range, replacement: replacement))
                    text.replaceCharacters(in: range, with: replacement)
                }
                let source = text as String
                let expected = MarkdownParser.parse(source, revision: UInt64(step))
                if let result = MarkdownParser.reparse(source, revision: UInt64(step), previous: previous, edits: edits) {
                    reparsed += 1
                    let window = result.changed
                    if window.length < (source as NSString).length / 2 {
                        partial += 1
                        if !expected.definitions.isEmpty { partialWithDefinitions += 1 }
                    }
                    guard Self.expectSame(result.document, expected, "round \(round) step \(step) window \(window) source \(source.debugDescription)") else { return }
                } else {
                    whole += 1
                }
                previous = expected
            }
        }
        // The generated blocks are dense with fences, HTML and lists, which widen windows; enough of them
        // must still stay under half the document, or the test says little about the partial path.
        #expect(reparsed > whole * 4 && partial > 2_000 && partialWithDefinitions > 1_000,
                "reparsed \(reparsed), under half the document \(partial), of those with definitions \(partialWithDefinitions), whole \(whole)")
    }

    /// The recorded block spans are the source ranges of the document's top-level blocks.
    @Test func blockSpansAreTheTopLevelBlocks() {
        var generator = Generator(state: 91)
        for _ in 0..<200 {
            let source = Self.document(&generator)
            let index = SourceIndex(source)
            let children = Document(parsing: source).children.map { child -> SourceSpan? in
                guard let range = child.range,
                      let start = index.offset(line: range.lowerBound.line, utf8Column: range.lowerBound.column),
                      let end = index.offset(line: range.upperBound.line, utf8Column: range.upperBound.column), end >= start else { return nil }
                return SourceSpan(start, end - start)
            }
            let parsed = MarkdownParser.parse(source)
            #expect(parsed.blocks == (children.contains(where: { $0 == nil }) ? [] : children.map { $0! }), "\(source.debugDescription)")
        }
    }

    /// Outside the returned window, the new parse is the previous one moved by the edit.
    @Test func changesStayInsideTheWindow() throws {
        let source = (0..<200).map { "## Heading \($0)\n\nA paragraph with **bold** \($0).\n\n- [ ] Task\n\n" }.joined()
        let previous = MarkdownParser.parse(source)
        let text = NSMutableString(string: source)
        let location = text.range(of: "bold** 100").location
        text.replaceCharacters(in: NSRange(location: location, length: 0), with: "x")
        let result = try #require(MarkdownParser.reparse(text as String, revision: 1, previous: previous,
                                                         edits: [PresentationEdit(range: NSRange(location: location, length: 0), replacement: "x")]))
        #expect(result.changed.length < 200, "window \(result.changed)")
        #expect(result.changed.location <= location && location < result.changed.end)
        #expect(Self.expectSame(result.document, MarkdownParser.parse(text as String, revision: 1), "window \(result.changed)"))
    }

    /// cmark refuses reference links once their destinations add up to the size of the document
    /// (100KB for a smaller one). A window has less to spend than its document, so a document near the
    /// cap, where a refusal is possible at all, is parsed whole.
    @Test func documentsNearTheExpansionCapParseWhole() {
        let long = String(repeating: "u", count: 60_000)
        let source = "[big]: /\(long)\n\nfirst [a][big]\n\nsecond [b][big]\n\nthird\n"
        let previous = MarkdownParser.parse(source)
        // The second use would pass the cap, and cmark leaves it as text.
        #expect(previous.styles.filter { $0.kind == .link("/" + long) }.count == 1)
        let end = (source as NSString).length
        #expect(MarkdownParser.reparse(source + "x", revision: 1, previous: previous,
                                       edits: [PresentationEdit(range: NSRange(location: end, length: 0), replacement: "x")]) == nil)
        // Far from the cap the same edit is a partial parse.
        let small = source.replacingOccurrences(of: long, with: "u")
        let result = MarkdownParser.reparse(small + "x", revision: 1, previous: MarkdownParser.parse(small),
                                            edits: [PresentationEdit(range: NSRange(location: (small as NSString).length, length: 0), replacement: "x")])
        #expect(result != nil)
    }

    /// Typing in a document that defines link references reparses part of it, with its links resolved
    /// as the whole document resolves them; changing a definition parses whole, and so does an
    /// unterminated fence that swallows the rest of the document.
    @Test func definitionsReachTheWindowAndChangingOneParsesWhole() throws {
        let body = (0..<50).map { "Paragraph \($0) [a][id] and [b][late].\n\n" }.joined()
        let source = "[id]: /one\n\n" + body + "[late]: /end \"t\"\n[id]: /shadowed\n"
        let previous = MarkdownParser.parse(source)
        #expect(previous.definitions.count == 3)
        func reparse(_ range: NSRange, _ replacement: String) -> (document: ParsedDocument, changed: SourceSpan)? {
            let text = (source as NSString).replacingCharacters(in: range, with: replacement)
            let result = MarkdownParser.reparse(text, revision: 1, previous: previous, edits: [PresentationEdit(range: range, replacement: replacement)])
            if let result { #expect(Self.expectSame(result.document, MarkdownParser.parse(text, revision: 1), "\(range) \(replacement.debugDescription)")) }
            return result
        }
        let middle = (source as NSString).range(of: "Paragraph 25")
        let typed = try #require(reparse(NSRange(location: middle.location, length: 0), "[new][late] "))
        #expect(typed.changed.length < 200, "window \(typed.changed)")
        #expect(typed.document.styles.contains { $0.kind == .link("/end") && typed.changed.contains($0.span.location) })
        #expect(typed.document.styles.allSatisfy { $0.kind != .link("/shadowed") })
        // After the last definition, in its paragraph: the definitions stay what they were.
        #expect(reparse(NSRange(location: (source as NSString).length, length: 0), "text") != nil)
        // A definition changed, added, or taken away.
        #expect(reparse((source as NSString).range(of: "/one"), "/two") == nil)
        #expect(reparse(NSRange(location: middle.location, length: 0), "[fresh]: /f\n\n") == nil)
        #expect(reparse((source as NSString).range(of: "[late]: /end \"t\"\n"), "") == nil)
        // No definitions at all, and `]:` that defines nothing, is no reason to parse whole.
        let plain = body + "array[0]: not a definition\n"
        #expect(MarkdownParser.parse(plain).definitions.isEmpty)
        #expect(MarkdownParser.reparse("x" + plain, revision: 1, previous: MarkdownParser.parse(plain),
                                       edits: [PresentationEdit(range: NSRange(location: 0, length: 0), replacement: "x")]) != nil)
        let fence = PresentationEdit(range: NSRange(location: 0, length: 0), replacement: "```\n")
        if let result = MarkdownParser.reparse("```\n" + body, revision: 1, previous: MarkdownParser.parse(body), edits: [fence]) {
            #expect(Self.expectSame(result.document, MarkdownParser.parse("```\n" + body, revision: 1), "open fence"))
        }
    }
}
