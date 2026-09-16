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
// Inputs chosen to defeat the index and the math scanner rather than to look like real notes.
// Each prints parse time and, for the presentation store, the time of caret-sized style queries.
if CommandLine.arguments.contains("--adversarial") {
    func repeated(_ piece: String, bytes: Int) -> String { String(repeating: piece, count: max(1, bytes / piece.utf8.count)) }
    let megabyte = 1_000_000
    var corpora: [(String, String)] = [
        ("normal", repeated(fixture, bytes: megabyte)),
        ("long-quote", repeated("> quoted line with **bold** and *em* text\n", bytes: megabyte)),
        ("nested-containers", repeated("> - > - > item with **bold**\n", bytes: megabyte)),
        ("long-list", repeated("- item with **bold** and *em*\n", bytes: megabyte)),
        ("currency-lines", repeated(String(repeating: "$1 ", count: 300) + "\n", bytes: megabyte)),
        ("escaped-dollars", repeated("\\$a \\$$ ", bytes: megabyte)),
        ("unclosed-display", repeated("$$ a `c` ", bytes: megabyte)),
    ]
    for length in [5_000, 20_000, 80_000] {
        corpora.append(("currency-one-line-\(length / 1000)k", String(repeating: "$1 ", count: length / 3)))
    }
    var generator: UInt64 = 1
    for (name, source) in corpora {
        let samples = source.utf8.count > 50_000 ? 5 : 20
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
        print(String(format: "ADVERSARIAL %@ bytes=%d styles=%d elements=%d parse_p50=%.3fms parse_p95=%.3fms query2000_p50=%.3fms",
                     name, source.utf8.count, document.styles.count, document.elements.count,
                     percentile(parses, 0.5), percentile(parses, 0.95), percentile(queries, 0.5)))
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
