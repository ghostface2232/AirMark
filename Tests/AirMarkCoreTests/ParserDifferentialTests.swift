import Foundation
import Testing
@testable import AirMarkCore

/// `MarkdownParser.parse` reads cmark-gfm's tree directly. `ReferenceParser` is the parser it
/// replaced, which reached the same tree through swift-markdown; the two must describe every
/// document identically, down to the block spans `reparse` cuts between.
struct ParserDifferentialTests {
    typealias Generator = PresentationStoreTests.Generator

    /// Lines chosen for what the tree walk reads rather than for block structure: nested and adjacent
    /// inline runs, link and image forms, smart punctuation (which changes text, not positions),
    /// tables with inline content, task items, fence info strings and indented continuation lines,
    /// where inline columns need correcting.
    static let lines = [
        "***both*** and **bold *em* bold** and *em **bold** em*", "__under__ _score_ snake_case_word", "~~gone~~ and ~single~",
        "`` code with ` tick `` and ```triple```", "\"quoted\" 'single' -- dash --- dash ... dots", "line with two spaces  ", "back\\",
        "[**bold** link](https://e.org \"title\") tail", "[`code` first](u) and [last *em*](u)", "<https://auto.link> and <a@b.co>",
        "![alt **bold** `c`](img.png \"t\") ![](empty.png)", "[ref] [full][id] [collapsed][]", "[id]: /destination \"title\"",
        "inline <span>html</span> <!-- c -->", "| *a* | `b|c` | [l](u) |", "| :-- | :-: | --: |", "| \"q\" | x -- y | ~~s~~ |", "| only |",
        "- [x] done **bold**", "* [ ] star task", "+ plus item", "1. [ ] ordered brackets", "10) paren", "   - three spaces",
        "> - quoted item", "> > - deeper **b**", ">   spaced quote `c`", "```mermaid\ngraph TD; A-->B\n```", "``` Math extra\nx^2\n```", "~~~latex\n\\frac{a}{b}\n~~~", "```swift\nlet x = 1\n```\n",
        "    indented code", "\tcode by tab", "  two **b** spaces", "      six *e* spaces", "\t**tabbed** [l](u)", "Setext", "=", "-",
        "$x$ **b** $$y$$ *e*", "price $5 and $6", "\\*not em\\* \\[not link\\]", "&amp; &#35; entity", "한글 **굵게** 😀 *e\u{301}* [링크](주소)",
        "a*b*c a_b_c a**b**c", "****", "** **", "[]()", "[a]( b )", "![a][id]", "<div>**not bold**</div>", "\u{FEFF}bom line", "nul\u{0}byte",
    ]

    static func document(_ generator: inout Generator) -> String {
        let newline = ["\n", "\n", "\r\n", "\r"][generator.next(4)]
        let blocks = (0..<(3 + generator.next(40))).map { _ in
            // Mostly these lines; one in five from the block generator, whose open fences, HTML blocks and
            // display math swallow what follows and would otherwise leave little for the walk to read.
            (0..<(1 + generator.next(5))).map { _ in
                generator.next(5) == 0 ? BlockReparseTests.lines[generator.next(BlockReparseTests.lines.count)] : lines[generator.next(lines.count)]
            }.joined(separator: newline)
        }
        return blocks.map { $0 + newline + (generator.next(4) == 0 ? "" : newline) }.joined()
    }

    static func expectSame(_ source: String, _ context: @autoclosure () -> String) -> Bool {
        let actual = MarkdownParser.parse(source, revision: 0, enforcingLimit: false)
        return BlockReparseTests.expectSame(actual, ReferenceParser.parse(source), context())
    }

    @Test func generatedDocumentsParseAsTheReferenceDoes() {
        var generator = Generator(state: 7)
        var styles = 0, elements = 0
        for round in 0..<3_000 {
            let source = Self.document(&generator)
            guard Self.expectSame(source, "round \(round) source \(source.debugDescription)") else { return }
            let parsed = MarkdownParser.parse(source)
            styles += parsed.styles.count; elements += parsed.elements.count
        }
        // The comparison says little unless the documents exercise the walk.
        #expect(styles > 100_000 && elements > 10_000, "styles \(styles), elements \(elements)")
    }

    /// The block-structure generator `reparse` is tested with, and the text the edits leave behind,
    /// which is where half-typed syntax comes from.
    @Test func editedDocumentsParseAsTheReferenceDoes() {
        var generator = Generator(state: 41)
        for round in 0..<300 {
            let text = NSMutableString(string: BlockReparseTests.document(&generator))
            for step in 0..<10 {
                guard Self.expectSame(text as String, "round \(round) step \(step) source \((text as String).debugDescription)") else { return }
                let (range, replacement) = BlockReparseTests.edit(&generator, in: text)
                text.replaceCharacters(in: range, with: replacement)
            }
        }
    }

    /// Every Markdown file in the repository, native and as the editor hands text over: bridged from
    /// the text storage's `NSString`.
    @Test func repositoryDocumentsParseAsTheReferenceDoes() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var files: [URL] = []
        for case let url as URL in FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])! where url.pathExtension == "md" {
            if !url.path.contains("/node_modules/") { files.append(url) }
        }
        #expect(files.count >= 10)
        for url in files {
            let source = try String(contentsOf: url, encoding: .utf8)
            #expect(Self.expectSame(source, url.lastPathComponent))
            let bridged = NSMutableString(string: source).copy() as! String
            #expect(Self.expectSame(bridged, "bridged " + url.lastPathComponent))
        }
    }

    /// The tree is freed when the parse returns; nothing the parse hands back may point into it.
    @Test func resultsOutliveTheTree() {
        let parsed = MarkdownParser.parse("![alt](a.png)\n\n```mermaid\ngraph TD\n```\n\n| a |\n| - |\n| b |\n\n[l](https://e.org)")
        #expect(parsed.elements.map(\.content) == ["a.png", "graph TD\n", "[[\"a\"],[\"b\"]]"])
        #expect(parsed.elements.first?.label == "alt")
        #expect(parsed.styles.contains { $0.kind == .link("https://e.org") })
    }
}
