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

    /// Everything must be the reference's, except block quote markers, where the reference is wrong in
    /// one way: it matched `>` from the start of each line of a quote's own text, so on the lines after
    /// a nested quote's first it found the outer quote's `>` again and never the inner one. There the
    /// parser may differ, under two conditions that pin it down. A marker of the reference's that the
    /// parser lacks must be one the reference also gave to another quote, which is that duplicate, or
    /// the same `>` without a list item's indentation before it. And
    /// the parser's quote markers must each be a `>` with at most three spaces before it and one space
    /// or tab after, none shared between two quotes.
    ///
    /// Setext headings are the other exception. cmark ends one on the line after its underline, and both
    /// parsers correct that, but finding the underline takes the containers into account (a line indented
    /// four columns, or one a quote continues lazily, is not one) and the reference, which has no container
    /// cursor, cannot. So a setext heading's span and its block are compared by where they start, and the
    /// parser's are held to what an underline is: its marker is a line break and a line that, past quote
    /// markers and indentation, is only `=` or only `-`, and the heading ends where the marker does.
    static func expectSame(_ source: String, _ context: @autoclosure () -> String) -> Bool {
        let actual = MarkdownParser.parse(source, revision: 0, enforcingLimit: false), expected = ReferenceParser.parse(source)
        let index = SourceIndex(source)
        func isSetext(_ run: StyleRun) -> Bool {
            if case .heading = run.kind { return index.unit(at: run.span.location) != 35 }                // "#"
            return false
        }
        /// Quote markers dropped, and setext headings and their blocks reduced to their first line.
        func normalized(_ document: ParsedDocument) -> ParsedDocument {
            var document = document
            let setext = Set(document.styles.filter(isSetext).map(\.span.location))
            func firstLine(_ span: SourceSpan) -> SourceSpan { SourceSpan(span.location, index.contentEnd(ofLine: index.lineNumber(at: span.location)) - span.location) }
            document.styles = document.styles.map { run in
                if run.kind == .quote { return StyleRun(span: run.span, kind: .quote) }
                return isSetext(run) ? StyleRun(span: firstLine(run.span), kind: run.kind) : run
            }
            document.blocks = document.blocks.map { setext.contains($0.location) ? Block(firstLine($0.span), isListItem: $0.isListItem) : $0 }
            return document
        }
        guard BlockReparseTests.expectSame(normalized(actual), normalized(expected), context(), definitions: false) else { return false }
        var headingsSound = true
        for heading in actual.styles.filter(isSetext) {
            let underline = heading.markers.last.map { index.text(in: $0) } ?? ""
            let content = underline.drop { $0.isNewline }.drop { $0 == " " || $0 == "\t" || $0 == ">" }.trimmingCharacters(in: .whitespaces)
            let shaped = underline.first?.isNewline == true && (content.first == "=" || content.first == "-") && content.allSatisfy { $0 == content.first }
            if !shaped || heading.markers.last?.end != heading.span.end { headingsSound = false }
        }
        #expect(headingsSound, "setext headings \(actual.styles.filter(isSetext).map { index.text(in: $0.span).debugDescription }) \(context().prefix(300))")
        guard headingsSound else { return false }
        let quotes = actual.styles.filter { $0.kind == .quote }, referenceQuotes = expected.styles.filter { $0.kind == .quote }
        let markers = quotes.flatMap(\.markers)
        var sound = Set(markers).count == markers.count, unsound: [String] = []
        for marker in markers {
            let text = index.text(in: marker).drop { $0 == " " || $0 == "\t" }
            if marker.length - text.utf16.count > 3 || ![">", "> ", ">\t"].contains(String(text)) { sound = false; unsound.append("\(marker.location):" + index.text(in: marker).debugDescription) }
        }
        for (quote, reference) in zip(quotes, referenceQuotes) {
            for lost in Set(reference.markers).subtracting(quote.markers) {
                // Inside a list item the indentation before `>` is the item's, and the marker starts after it.
                let trimmed = quote.markers.contains { $0.end == lost.end && $0.location >= lost.location }
                if !trimmed, !referenceQuotes.contains(where: { $0.span != reference.span && $0.markers.contains(lost) }) { sound = false; unsound.append("lost \(lost.location):" + index.text(in: lost).debugDescription) }
            }
        }
        #expect(sound, "quote markers \(unsound.prefix(5)) \(context().prefix(300))")
        return sound
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

    /// Each `>` belongs to the quote at its depth, on every line, and a line a quote only continues
    /// lazily has no marker for it.
    @Test func nestedQuoteMarkersBelongToTheirOwnQuote() {
        func markers(_ source: String) -> [[String]] {
            let index = SourceIndex(source)
            return MarkdownParser.parse(source).styles.filter { $0.kind == .quote }.map { $0.markers.map { "\($0.location):" + index.text(in: $0) } }
        }
        #expect(markers("> > a\n> > b\n>> c\n") == [["0:> ", "6:> ", "12:>"], ["2:> ", "8:> ", "13:> "]])
        #expect(markers("> a\nlazy\n> b\n") == [["0:> ", "9:> "]])
        #expect(markers("> > a\n> lazy for the inner\n") == [["0:> ", "6:> "], ["2:> "]])
        #expect(markers("> a\n    > not a marker\n") == [["0:> "]])
        // Inside list items, however deep: the reference looked at most three spaces into the line.
        #expect(markers("- a\n  - > q\n    > r\n") == [["8:> ", "16:> "]])
        #expect(markers("1. > q\n   > r\n\n   > s\n") == [["3:> ", "10:> "], ["18:> "]])
        #expect(markers("> - a\n>   > q\n>   > r\n") == [["0:> ", "6:> ", "14:> "], ["10:> ", "18:> "]])
        #expect(markers(" > a\r\n >\r\n > b") == [["1:> ", "6: >", "10: > "]])
        // Indentation is columns, not characters: a tab here is four, which is past the item's content
        // and makes `> b` text; with spaces to the same column it is the same. A wide marker's item needs
        // as many columns, and a line short of them is lazy.
        #expect(markers("- > a\n\t  > b\n") == [["2:> "]])
        #expect(markers("- > a\n      > b\n") == [["2:> "]])
        #expect(markers("100.\n     > a\n    > b\n") == [["10:> "]])
        #expect(markers("100. > a\n     > b\n") == [["5:> ", "14:> "]])
        // A tab that is exactly the item's indentation is the item's; one a quote takes a column of is
        // left to what is inside, where it is indentation again.
        #expect(markers("-\t> a\n\t> b\n") == [["2:> ", "7:> "]])
        #expect(markers(">\t> a\n>\t> b\n") == [["0:>", "6:>"], ["2:> ", "7:\t> "]])
    }

    /// The tree is freed when the parse returns; nothing the parse hands back may point into it.
    @Test func resultsOutliveTheTree() {
        let parsed = MarkdownParser.parse("![alt](a.png)\n\n```mermaid\ngraph TD\n```\n\n| a |\n| - |\n| b |\n\n[l](https://e.org)")
        #expect(parsed.elements.map(\.content) == ["a.png", "graph TD\n", "[[\"a\"],[\"b\"]]"])
        #expect(parsed.elements.first?.label == "alt")
        #expect(parsed.styles.contains { $0.kind == .link("https://e.org") })
    }
}
