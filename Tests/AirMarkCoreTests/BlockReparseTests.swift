import Foundation
import Testing
@testable import AirMarkCore

/// `MarkdownParser.reparse` must produce exactly the whole-document parse after any sequence of edits.
struct BlockReparseTests {
    typealias Generator = PresentationStoreTests.Generator
    static let lines = ["# Heading", "## Sub", "Title", "===", "---", "***", "para with **bold** and *em*", "continued `code` line",
                        "   indented lazy line", "> quote", "> > nested", "- item", "- [ ] task", "  - child", "    four spaces", "1. one",
                        "* star", "```", "```swift", "~~~", "$$", "x^2 $$ y", "$a$ and $$b$$", "| a | b |", "| - | - |", "<div>",
                        "</div>", "<!--", "-->", "![i](p.png)", "[l](u)", "[r][id]", "한글 😀 e\u{301}", "\t tab", "", "", "", " \t"]
    static let insertions = ["\n", "\n\n", "\r\n", "\r", "#", "# ", ">", "> ", "- ", "1. ", "*", "**", "_", "`", "```", "~~~", "$", "$$",
                             "|", "<", "<!--", "-->", "[", "]", "](u)", "    ", "\t", "x", "word ", "한", "😀", "---\n", "===\n"]

    /// Blocks of one to four lines, mostly separated by blank lines as real documents are, with the
    /// line ending of the whole document varying. One document in twenty defines a link reference.
    static func document(_ generator: inout Generator) -> String {
        let newline = ["\n", "\n", "\r\n", "\r"][generator.next(4)]
        var blocks = (0..<(4 + generator.next(60))).map { _ in
            (0..<(1 + generator.next(4))).map { _ in lines[generator.next(lines.count)] }.joined(separator: newline)
        }
        if generator.next(20) == 0 { blocks.insert("[id]: /u", at: generator.next(blocks.count + 1)) }
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

    static func expectSame(_ actual: ParsedDocument, _ expected: ParsedDocument, _ context: String) -> Bool {
        let same = canonical(actual) == canonical(expected) && actual.elements == expected.elements
            && actual.checkboxes == expected.checkboxes && actual.blocks == expected.blocks
            && actual.mayDefineReferences == expected.mayDefineReferences && actual.source == expected.source
        #expect(same, "\(context)")
        return same
    }

    @Test func reparseEqualsWholeParseAfterRandomEdits() {
        var generator = Generator(state: 23)
        var reparsed = 0, whole = 0, partial = 0
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
                    if window.length < (source as NSString).length / 2 { partial += 1 }
                    guard Self.expectSame(result.document, expected, "round \(round) step \(step) window \(window) source \(source.debugDescription)") else { return }
                } else {
                    whole += 1
                }
                previous = expected
            }
        }
        // The generated blocks are dense with fences, HTML and lists, which widen windows; enough of them
        // must still stay under half the document, or the test says little about the partial path.
        #expect(reparsed > whole * 4 && partial > 2_000, "reparsed \(reparsed), under half the document \(partial), whole \(whole)")
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

    /// Anything that may define a link reference is parsed whole, and so is an unterminated fence
    /// that swallows the rest of the document.
    @Test func referenceDefinitionsAndOpenFencesParseWhole() throws {
        let body = (0..<50).map { "Paragraph \($0) [a][id].\n\n" }.joined()
        let withDefinition = body + "[id]: /one\n"
        #expect(MarkdownParser.reparse(withDefinition + "x", revision: 1, previous: MarkdownParser.parse(withDefinition),
                                       edits: [PresentationEdit(range: NSRange(location: (withDefinition as NSString).length, length: 0), replacement: "x")]) == nil)
        let typed = PresentationEdit(range: NSRange(location: 0, length: 0), replacement: "[id]: /two\n\n")
        #expect(MarkdownParser.reparse("[id]: /two\n\n" + body, revision: 1, previous: MarkdownParser.parse(body), edits: [typed]) == nil)
        let fence = PresentationEdit(range: NSRange(location: 0, length: 0), replacement: "```\n")
        if let result = MarkdownParser.reparse("```\n" + body, revision: 1, previous: MarkdownParser.parse(body), edits: [fence]) {
            #expect(Self.expectSame(result.document, MarkdownParser.parse("```\n" + body, revision: 1), "open fence"))
        }
    }
}
