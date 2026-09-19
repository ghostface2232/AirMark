import Foundation
import AirMarkCore

struct Measurement: Codable {
    let bytes: Int
    let iterations: Int
    let parseP50MS: Double
    let parseP95MS: Double
    let indexP50MS: Double
    let indexP95MS: Double
}
let clock = ContinuousClock()
func measure(_ operation: () -> Void) -> Double {
    let start = clock.now; operation()
    let duration = start.duration(to: clock.now).components
    return Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
}
func percentile(_ values: [Double], _ fraction: Double) -> Double {
    values.sorted()[max(0, min(values.count - 1, Int(ceil(Double(values.count) * fraction)) - 1))]
}
let fixture = "## Heading\n\nA paragraph with **bold**, *emphasis*, [link](https://example.org) and 한글.\n\n- [ ] Task\n- Item\n\nInline $x^2+y^2$ formula.\n\n"
// A long single paragraph exposes repeated line conversion hidden by short-line fixtures.
if CommandLine.arguments.contains("--long-lines") {
    for repetitions in [1_000, 4_000, 16_000] {
        let token = "**한😀e\u{301}** "
        let source = String(repeating: token, count: repetitions)
        let index = SourceIndex(source)
        var lookup: [Double] = [], parse: [Double] = []
        for _ in 0..<5 {
            lookup.append(measure {
                for number in 0..<repetitions {
                    precondition(index.offset(line: 1, utf8Column: number * token.utf8.count + 1) == number * token.utf16.count)
                }
            })
            parse.append(measure { precondition(MarkdownParser.parse(source).styles.count == repetitions) })
        }
        print(String(format: "LONG_LINE bytes=%d lookups=%d lookup_p50=%.3fms lookup_p95=%.3fms parse_p50=%.3fms parse_p95=%.3fms", source.utf8.count, repetitions, percentile(lookup, 0.5), percentile(lookup, 0.95), percentile(parse, 0.5), percentile(parse, 0.95)))
    }
    exit(0)
}
// Cost of moving the presentation with one edit, at doubling sizes. Each sample applies 200 single-
// character insertions at the head, middle or tail of a fresh store. `exponent` is log2 of the time
// ratio to the previous size: 0 when an edit's cost does not grow with the document, 1 when it grows
// with everything after the edit.
if CommandLine.arguments.contains("--edits") {
    func repeated(_ piece: String, bytes: Int) -> String { String(repeating: piece, count: max(1, bytes / piece.utf8.count)) }
    let corpora: [(String, (Int) -> String)] = [
        ("normal", { repeated(fixture, bytes: $0) }),
        ("long-quote", { repeated("> quoted line with **bold** and *em* text\n", bytes: $0) }),
        ("nested-list", { repeated("- item\n  - nested with **bold**\n", bytes: $0) }),
    ]
    for (name, make) in corpora {
        var previous: [String: Double] = [:]
        for size in [125_000, 250_000, 500_000, 1_000_000] {
            let source = make(size)
            let parsed = MarkdownParser.parse(source)
            let length = source.utf16.count
            var line = "EDITS \(name) bytes=\(source.utf8.count)"
            // "inside-tail" is a few units before the end: inside a container that runs to the end.
            for (position, location) in [("head", 0), ("middle", length / 2), ("inside-tail", length - 6), ("tail", length)] {
                var samples: [Double] = []
                for _ in 0..<5 {
                    var store = PresentationStore(parsed)
                    samples.append(measure {
                        for number in 0..<200 { store.apply(PresentationEdit(range: NSRange(location: location + number, length: 0), replacement: "x")) }
                    })
                }
                let p50 = percentile(samples, 0.5)
                line += String(format: " %@=%.3fms", position, p50)
                if let before = previous[position] { line += String(format: "(exp %.2f)", log2(p50 / before)) }
                previous[position] = p50
            }
            // Delete the middle half, then query around the deletion point until the next parse.
            var edited = PresentationStore(parsed)
            let deletion = NSRange(location: length / 4, length: length / 2)
            edited.apply(PresentationEdit(range: deletion, replacement: ""))
            var queries: [Double] = []
            for _ in 0..<5 {
                queries.append(measure {
                    for offset in 0..<2_000 { _ = edited.styles(intersecting: SourceSpan(deletion.location - 2 + offset % 5, 6)) }
                })
            }
            line += String(format: " after-delete-query2000=%.3fms", percentile(queries, 0.5))
            if let before = previous["after-delete"] { line += String(format: "(exp %.2f)", log2(percentile(queries, 0.5) / before)) }
            previous["after-delete"] = percentile(queries, 0.5)
            print(line)
        }
    }
    exit(0)
}

// The editor never hands over a native string: its text is bridged from the text storage's NSString,
// which has no UTF-8 to point at. Every other mode here measures native strings, so this one measures
// the same work on the text as the app sees it.
if CommandLine.arguments.contains("--bridged") {
    for size in [1_000_000, 10_000_000] {
        let native = String(repeating: fixture, count: size / fixture.utf8.count)
        let bridged = NSMutableString(string: native).copy() as! String
        func p50(_ body: () -> Void) -> Double { percentile((0..<5).map { _ in measure(body) }, 0.5) }
        print(String(format: "BRIDGED bytes=%d parse_native=%.2fms parse_bridged=%.2fms",
                     native.utf8.count, p50 { _ = MarkdownParser.parse(native) }, p50 { _ = MarkdownParser.parse(bridged) }))
    }
    exit(0)
}
// A document that defines link references used to be parsed whole on every keystroke. One edit in
// the middle, reparsed against the previous parse and parsed whole, with one definition and with many.
if CommandLine.arguments.contains("--references") {
    let block = "## Heading\n\nA paragraph with **bold**, [link](https://example.org), [ref][id7] and 한글.\n\n- [ ] Task\n\nInline $x^2$ formula.\n\n"
    for (size, definitions) in [(1_000_000, 1), (1_000_000, 2_000), (10_000_000, 1), (10_000_000, 2_000)] {
        let source = String(repeating: block, count: size / block.utf8.count)
            + (0..<definitions).map { "[id\($0)]: https://example.org/page/\($0) \"Title \($0)\"\n" }.joined()
        let previous = MarkdownParser.parse(source)
        let text = NSMutableString(string: source), location = text.length / 2
        text.insert("x", at: location)
        let edited = text.copy() as! String
        let edit = PresentationEdit(range: NSRange(location: location, length: 0), replacement: "x")
        func p50(_ body: () -> Void) -> Double { percentile((0..<5).map { _ in measure(body) }, 0.5) }
        var partial = false
        let reparse = p50 { partial = MarkdownParser.reparse(edited, revision: 1, previous: previous, edits: [edit]) != nil }
        print(String(format: "REFERENCES bytes=%d definitions=%d partial=%@ reparse_p50=%.2fms whole_p50=%.2fms",
                     source.utf8.count, previous.definitions.count, "\(partial)", reparse, p50 { _ = MarkdownParser.parse(edited) }))
    }
    exit(0)
}
// A top-level list used to be one block, so an edit inside it reparsed the whole list. One edit in
// the middle of a list of 20,000 items, flat and with nested children, and of one that holds `$$`,
// which is still cut at blank lines only.
if CommandLine.arguments.contains("--lists") {
    let corpora: [(String, String)] = [
        ("flat", (0..<20_000).map { "- item \($0) with **bold**\n" }.joined()),
        ("nested", (0..<5_000).map { "- item \($0)\n  - child with `code`\n    - grandchild [l](u)\n  continued\n" }.joined()),
        ("with-display-math", (0..<20_000).map { $0 == 10 ? "- $$x^2$$\n" : "- item \($0) with **bold**\n" }.joined()),
    ]
    for (name, source) in corpora {
        let previous = MarkdownParser.parse(source)
        let text = NSMutableString(string: source), location = text.length / 2
        text.insert("x", at: location)
        let edited = text.copy() as! String
        let edit = PresentationEdit(range: NSRange(location: location, length: 0), replacement: "x")
        func p50(_ body: () -> Void) -> Double { percentile((0..<5).map { _ in measure(body) }, 0.5) }
        var window = 0
        let reparse = p50 { window = MarkdownParser.reparse(edited, revision: 1, previous: previous, edits: [edit])?.changed.length ?? -1 }
        print(String(format: "LISTS %@ bytes=%d blocks=%d window=%d reparse_p50=%.2fms whole_p50=%.2fms",
                     name, source.utf8.count, previous.blocks.count, window, reparse, p50 { _ = MarkdownParser.parse(edited) }))
    }
    exit(0)
}
// Inputs chosen to defeat the index and the math scanner rather than to look like real notes.
// Each corpus is measured at doubling sizes; the exponent between neighbours (log2 of the time ratio)
// is about 1 for linear work and about 2 for quadratic work, whatever the absolute times are.
// `query` is 2,000 caret-sized style queries on the presentation store, so its exponent is the
// growth of one query's cost with document size (0 for logarithmic work).
if CommandLine.arguments.contains("--adversarial") {
    func repeated(_ piece: String, bytes: Int) -> String { String(repeating: piece, count: max(1, bytes / piece.utf8.count)) }
    let documentSizes = [125_000, 250_000, 500_000, 1_000_000]
    let corpora: [(name: String, sizes: [Int], make: (Int) -> String)] = [
        ("normal", documentSizes, { repeated(fixture, bytes: $0) }),
        ("long-quote", documentSizes, { repeated("> quoted line with **bold** and *em* text\n", bytes: $0) }),
        ("nested-containers", documentSizes, { repeated("> - > - > item with **bold**\n", bytes: $0) }),
        ("long-list", documentSizes, { repeated("- item with **bold** and *em*\n", bytes: $0) }),
        ("currency-lines", documentSizes, { repeated(String(repeating: "$1 ", count: 300) + "\n", bytes: $0) }),
        ("escaped-dollars", documentSizes, { repeated("\\$a \\$$ ", bytes: $0) }),
        ("unclosed-display", documentSizes, { repeated("$$ a `c` ", bytes: $0) }),
        // One nested list at the nesting limit, repeated: depth is bounded, so size alone should scale.
        ("nested-list-depth-256", documentSizes, { repeated((0..<256).map { String(repeating: "  ", count: $0) + "- item\n" }.joined() + "\n", bytes: $0) }),
        ("nested-quote-depth-256", documentSizes, { repeated((1...256).map { String(repeating: ">", count: $0) + " line\n" }.joined() + "\n", bytes: $0) }),
        ("currency-one-line", [5_000, 10_000, 20_000, 40_000, 80_000], { repeated("$1 ", bytes: $0) }),
        ("dollar-letters-one-line", [5_000, 10_000, 20_000, 40_000, 80_000], { repeated("$a ", bytes: $0) }),
    ]
    var generator: UInt64 = 1
    for corpus in corpora {
        var previous: (parse: Double, query: Double)?
        for size in corpus.sizes {
            let source = corpus.make(size)
            let samples = size >= 500_000 ? 5 : 9
            var parses: [Double] = []
            var document = ParsedDocument(source: "")
            for _ in 0..<samples { parses.append(measure { document = MarkdownParser.parse(source) }) }
            let store = PresentationStore(document)
            let length = source.utf16.count
            var queries: [Double] = []
            for _ in 0..<5 {
                queries.append(measure {
                    for _ in 0..<2_000 {
                        generator = generator &* 6364136223846793005 &+ 1442695040888963407
                        let location = Int((generator >> 33) % UInt64(max(1, length)))
                        _ = store.styles(intersecting: SourceSpan(max(0, location - 2), 6))
                    }
                })
            }
            let parse = percentile(parses, 0.5), query = percentile(queries, 0.5)
            let exponents = previous.map { String(format: " parse_exponent=%.2f query_exponent=%.2f", log2(parse / $0.parse), log2(query / $0.query)) } ?? ""
            print(String(format: "ADVERSARIAL %@ bytes=%d styles=%d elements=%d parse_p50=%.3fms query2000_p50=%.3fms%@",
                         corpus.name, source.utf8.count, document.styles.count, document.elements.count, parse, query, exponents))
            previous = (parse, query)
        }
    }
    exit(0)
}
var measurements: [Measurement] = []
for (size, count) in [(100_000, 20), (1_000_000, 10), (10_000_000, 3)] {
    let source = String(repeating: fixture, count: size / fixture.utf8.count)
    var parses: [Double] = [], indexes: [Double] = []
    for _ in 0..<count {
        indexes.append(measure { precondition(SourceIndex(source).utf16Count == source.utf16.count) })
        parses.append(measure { precondition(!MarkdownParser.parse(source).styles.isEmpty) })
    }
    measurements.append(Measurement(bytes: source.utf8.count, iterations: count,
        parseP50MS: percentile(parses, 0.5), parseP95MS: percentile(parses, 0.95),
        indexP50MS: percentile(indexes, 0.5), indexP95MS: percentile(indexes, 0.95)))
}
let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
print(String(decoding: try encoder.encode(measurements), as: UTF8.self))
