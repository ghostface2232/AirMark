import Foundation
import Testing
@testable import AirMarkCore

/// `PresentationStore` must match `ParsedDocument.rebased(for:)`, the straightforward whole-array
/// implementation, after any sequence of edits, including edits inside surrogate pairs.
struct PresentationStoreTests {
    struct Generator {
        var state: UInt64
        mutating func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return bound <= 0 ? 0 : Int((state >> 33) % UInt64(bound))
        }
    }
    static let pieces = ["# ", "## ", "**", "*", "~~", "`", "```\n", "~~~\n", "> ", "- ", "- [ ] ", "1. ", "[a](b)", "![i](p.png)",
                         "$x$", "$$\n", "| a | b |\n| - | - |\n", "한글", "😀", "e\u{301}", "\r\n", "\n", "\n\n", " ", "word", "\\", "---\n", "Title\n===\n"]

    static func document(_ generator: inout Generator, pieces count: Int) -> String {
        (0..<count).map { _ in pieces[generator.next(pieces.count)] }.joined()
    }

    static func randomSpan(_ generator: inout Generator, length: Int) -> SourceSpan {
        let location = generator.next(length + 1)
        return SourceSpan(location, generator.next(min(40, length - location) + 1))
    }

    @Test func editsMatchWholeArrayRebase() {
        var generator = Generator(state: 7)
        for round in 0..<60 {
            let text = NSMutableString(string: Self.document(&generator, pieces: 20 + generator.next(120)))
            var reference = MarkdownParser.parse(text as String)
            var store = PresentationStore(reference)
            for step in 0..<40 {
                let range = Self.randomSpan(&generator, length: text.length)
                let replacement = generator.next(3) == 0 ? "" : Self.pieces[generator.next(Self.pieces.count)]
                let edit = PresentationEdit(range: range.nsRange, replacement: replacement)
                text.replaceCharacters(in: range.nsRange, with: replacement)
                reference = reference.rebased(for: edit)
                store.apply(edit)
                #expect(store.styles == reference.styles, "round \(round) step \(step)")
                #expect(store.elements == reference.elements, "round \(round) step \(step)")
                #expect(store.checkboxes == reference.checkboxes.sorted { $0.location < $1.location }, "round \(round) step \(step)")
                let probe = Self.randomSpan(&generator, length: text.length)
                #expect(store.styles(intersecting: probe) == reference.styles.filter { $0.span.end > probe.location && $0.span.location < probe.end },
                        "round \(round) step \(step) probe \(probe)")
                #expect(Array(store.elements(intersecting: probe)) == reference.elements.filter { $0.span.end > probe.location && $0.span.location < probe.end })
            }
            // A newer parse is compared with the edited store the way the editor applies it.
            let latest = MarkdownParser.parse(text as String)
            let next = PresentationStore(latest)
            let expectedSpans = Set(Set(reference.styles).symmetricDifference(Set(latest.styles)).map(\.span))
            #expect(Set(store.changedStyleSpans(comparedTo: next)) == expectedSpans, "round \(round)")
            #expect(Set(store.unchangedElements(comparedTo: next)) == Set(reference.elements).intersection(Set(latest.elements)), "round \(round)")
        }
    }

    /// Queries at a single position return the styles strictly containing it, as caret rules need.
    @Test func zeroLengthQueryReturnsContainingStyles() {
        let source = "> **bold** and *em*\n> more\n"
        let store = PresentationStore(MarkdownParser.parse(source))
        let kinds = store.styles(intersecting: SourceSpan(4, 0)).map(\.kind)
        #expect(kinds.contains(.quote))
        #expect(kinds.contains(.strong))
        #expect(!kinds.contains(.emphasis))
    }

    /// Deleting everything leaves tombstones only; inserting afterwards must not resurrect them.
    @Test func removedStylesStayRemoved() {
        let source = "**a** *b* `c`\n"
        var reference = MarkdownParser.parse(source)
        var store = PresentationStore(reference)
        for edit in [PresentationEdit(range: NSRange(location: 0, length: source.utf16.count), replacement: ""),
                     PresentationEdit(range: NSRange(location: 0, length: 0), replacement: "xyz")] {
            reference = reference.rebased(for: edit)
            store.apply(edit)
            #expect(store.styles == reference.styles)
        }
        #expect(store.styleCount == 0)
    }

    /// A closing fence marker reaches one line break past its block. An edit just after the
    /// block must still remove that marker even though the block itself ends before the edit.
    @Test func markerPastStyleEndIsUpdated() throws {
        let source = "```\ncode\n```\r\nafter\n"
        var reference = MarkdownParser.parse(source)
        var store = PresentationStore(reference)
        let block = try #require(reference.styles.first { $0.kind == .codeBlock })
        #expect(block.markers.last.map { $0.end > block.span.end } == true)
        let edit = PresentationEdit(range: NSRange(location: block.span.end + 1, length: 0), replacement: "x")
        reference = reference.rebased(for: edit)
        store.apply(edit)
        #expect(store.styles == reference.styles)
    }
}
