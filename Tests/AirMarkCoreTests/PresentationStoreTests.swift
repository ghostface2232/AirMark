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
        for round in 0..<400 {
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
                // Several probes per step, half of them caret-sized, where marker searches are most fragile.
                for probeNumber in 0..<8 {
                    var probe = Self.randomSpan(&generator, length: text.length)
                    if probeNumber % 2 == 0 { probe.length = 0 }
                    let expected = reference.styles.filter { $0.span.end > probe.location && $0.span.location < probe.end }.map { run in
                        StyleRun(span: run.span, kind: run.kind, markers: run.markers.filter { $0.end >= probe.location && $0.location <= probe.end })
                    }
                    #expect(store.styles(intersecting: probe) == expected, "round \(round) step \(step) probe \(probe)")
                    #expect(Array(store.elements(intersecting: probe)) == reference.elements.filter { $0.span.end > probe.location && $0.span.location < probe.end })
                }
            }
            // A newer parse is compared with the edited store the way the editor applies it.
            let latest = MarkdownParser.parse(text as String)
            let next = PresentationStore(latest)
            let expectedSpans = Set(Set(reference.styles).symmetricDifference(Set(latest.styles)).map(\.span))
            #expect(Set(store.changedStyleSpans(comparedTo: next)) == expectedSpans, "round \(round)")
            let difference = store.elementDiff(comparedTo: next)
            #expect(Set(difference.unchanged) == Set(Set(reference.elements).intersection(Set(latest.elements)).map(\.span)), "round \(round)")
            #expect(Set(difference.changed) == Set(Set(reference.elements).symmetricDifference(Set(latest.elements)).map(\.span)), "round \(round)")
            // The editor merges both lists against other sorted span lists, and retains artifacts
            // and render failures by walking `unchanged`, which must also be disjoint.
            #expect(zip(difference.changed, difference.changed.dropFirst()).allSatisfy { $0.location <= $1.location }, "round \(round)")
            #expect(zip(difference.unchanged, difference.unchanged.dropFirst()).allSatisfy { $0.end <= $1.location }, "round \(round)")
        }
    }

    /// A caret-sized query inside a long block quote examines about as many tree nodes as one in a
    /// short document: the cost follows the styles that reach the range, not the quote's length.
    @Test func queryCostIsIndependentOfContainerLength() {
        func visits(_ source: String) -> Int {
            let store = PresentationStore(MarkdownParser.parse(source))
            let middle = source.utf16.count / 2
            var count = 0
            let found = store.styles(intersecting: SourceSpan(middle - 2, 6), visits: &count)
            #expect(found.contains { $0.kind == .quote })
            return count
        }
        let line = "> quoted line with **bold** and *em* text\n"
        let short = visits(String(repeating: line, count: 50))
        let long = visits(String(repeating: line, count: 20_000))
        #expect(long <= short * 3, "short quote: \(short) visits, long quote: \(long)")
        let source = String(repeating: line, count: 20_000)
        let quote = PresentationStore(MarkdownParser.parse(source)).styles(intersecting: SourceSpan(source.utf16.count / 2, 0)).first { $0.kind == .quote }
        #expect((quote?.markers.count ?? .max) <= 2, "a query returns only the quote markers near it")
    }

    /// An empty fenced block: the opening marker takes its line break, and the closing marker must not
    /// claim the same one. Overlapping markers broke the ordered search, dropping the opening marker
    /// from a query after an edit.
    @Test func emptyFencedBlockMarkersDoNotOverlap() {
        for (source, insertAt, probe) in [("```\n```\n", 5, 4), ("```\r\n```\r\n", 7, 4)] {
            var reference = MarkdownParser.parse(source)
            var store = PresentationStore(reference)
            let edit = PresentationEdit(range: NSRange(location: insertAt, length: 0), replacement: "x")
            reference = reference.rebased(for: edit)
            store.apply(edit)
            let range = SourceSpan(probe, 0)
            let expected = reference.styles.filter { $0.span.end > range.location && $0.span.location < range.end }.map { run in
                StyleRun(span: run.span, kind: run.kind, markers: run.markers.filter { $0.end >= range.location && $0.location <= range.end })
            }
            #expect(store.styles(intersecting: range) == expected, "\(source.debugDescription)")
        }
    }

    /// Every style's markers are sorted and disjoint, which the store's marker searches rely on.
    @Test func parsedMarkersAreSortedAndDisjoint() {
        var generator = Generator(state: 13)
        for round in 0..<3_000 {
            let source = Self.document(&generator, pieces: 1 + generator.next(40))
            for run in MarkdownParser.parse(source).styles {
                for (earlier, later) in zip(run.markers, run.markers.dropFirst()) {
                    #expect(earlier.end <= later.location, "round \(round): \(source.debugDescription) \(run.kind) \(run.markers)")
                }
            }
        }
    }

    /// The editor edits before its first parse lands, on an empty store.
    @Test func emptyStoreAcceptsEditsAndQueries() {
        var store = PresentationStore()
        store.apply(PresentationEdit(range: NSRange(location: 0, length: 0), replacement: "hello"))
        #expect(store.styles(intersecting: SourceSpan(0, 5)).isEmpty)
        var single = PresentationStore(MarkdownParser.parse("**a**"))
        single.apply(PresentationEdit(range: NSRange(location: 0, length: 0), replacement: "x"))
        #expect(single.styles(intersecting: SourceSpan(0, 6)).map(\.span) == [SourceSpan(0, 6)])
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
