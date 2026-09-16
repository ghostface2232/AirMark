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
