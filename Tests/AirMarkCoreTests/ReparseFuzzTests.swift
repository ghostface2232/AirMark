import Foundation
import Testing
@testable import AirMarkCore

/// `MarkdownParser.reparse` against `MarkdownParser.parse`, on documents built from pools of lines that
/// aim at the places a partial parse can go wrong. The pools are the review fuzzer's of 2026-09-19, which
/// found five differences that `BlockReparseTests` had not; each pool keeps the lines that found them.
///
/// Unlike `BlockReparseTests`, half the steps continue from the partial result rather than from a whole
/// parse, so what a partial parse carries forward (its definitions, its expansion count, its blocks) is
/// used again by the next one. One round in four edits at raw UTF-16 offsets, which can split a surrogate
/// pair or a CRLF, as the editor never does; the result must still equal the whole parse.
///
/// A short run is part of the suite. Longer ones, for a parser change or a swift-cmark upgrade:
///
///     AIRMARK_FUZZ_ROUNDS=400 AIRMARK_FUZZ_SEEDS=1,2,3 swift test -c release --disable-sandbox --filter ReparseFuzzTests
///
/// A difference is reported with the smallest document found by deleting whole lines that still shows
/// it, as a source string, a range and a replacement that `reproduce` takes directly.
struct ReparseFuzzTests {
    typealias Generator = PresentationStoreTests.Generator

    static let environment = ProcessInfo.processInfo.environment
    static let rounds = Int(environment["AIRMARK_FUZZ_ROUNDS"] ?? "") ?? 60
    static let seeds = (environment["AIRMARK_FUZZ_SEEDS"] ?? "1").split(separator: ",").compactMap { UInt64($0) }

    static let pools: [String: [String]] = [
        "list": ["- item", "- item\n  more", "- lazy\ncont", "* star", "+ plus", "1. one", "2. two", "10) ten", "-", "- ", "---", "* * *",
                 "===", "  - child", "    code", "\tcode", "- ```", "  ```", "```", "~~~", "- <div>", "- <!--", "-->", "</div>", "<pre>",
                 "</pre>", "- > q", "> q", "> - x", "- $$", "$$", "- a $$ b", "\\$$", "- $x$", "- | a | b |", "  | - | - |", "| a | b |",
                 "| - | - |", "- [r][id]", "[id]: /u", "- [id]: /v", "  [id2]: /w", "[r][id2]", "text", "  text", "   - three", "- [ ] t",
                 "-\n  x", "- a\n\n  b", "", "", " ", "# h", "- # h", "100. wide", "  1. n", "- `code", "` end", "- **b", "b**", "- [l", "](u)"],
        "references": ["[a]: /1", "[a]: /2", "[A]: /3", "[b]: /b 'title'", "[b]: /b 'title'", "[c]:\n  /c", "[c]: /c\n'title\nmore'",
                       "text [x][a] [y][b] [c] [a]", "- [a]: /item", "- text [a]", "> [a]: /q", "> [q][a]", "[a]: /1\ntrailing [a]",
                       "para\n[a]: /notdef", "", "", "[d]: <>", "^[attr]: {\"k\":1}", "[foo][attr]", "===", "---", "| [a] | b |", "| - | - |",
                       "```", "[e]: /e", "\\[a]: /x", "[ a ]: /sp", "[ẞ]: /ss", "[ss]: /ss2", "[x][SS] [y][ẞ]", "![i][a]", "- item [b]", "- item"],
        "math": ["- a $$", "- $$ b", "- $$x$$", "$$", "- x", "- y `$$`", "- `", "- \\$$", "- $", "- $a$ b $", "text $$", "$$ text", "",
                 "- | $$ | b |", "  | - | - |", "- <span>$$</span>", "- ![$$](u)", "- [$$](u)", "* z", "1. $$", "  $$", "- ```", "  ```",
                 "> $$", "- > $$", "\\", "$"],
        "quote": ["> a", "> > b", ">> c", "> - x", "> - > y", ">   > z", "- > a", "  > b", "\t> c", "\t  > d", "      > e", "1. > a", "   > b",
                  "100.", "     > a", "    > b", ">", "> ```", "> > code", "> ```", "lazy", "    > lazy4", "", "> <div>", "> > html", "-",
                  "  - > n", "    > m", ">\t> t", "> \t> u", ">- > v", "*\t> w", "\t\t> x"],
        "exotic": ["- a", "- b\u{2028}c", "\u{FEFF}- bom", "\u{FEFF}", "\u{0C}", "- \u{0C}", "- a  ", "- a\\", "  ---", "  ===", "- t\n  ===",
                   "- t\n  ---", "- > t\n  > ===", "1. a", "1. b\n   ---", "- <!--", "  -->", "- <pre>", "  </pre>", "- <?", "  ?>", "- ```",
                   "- ~~~", "  ~~~", "      code", "- [x](", "  u)", "- ![a](", "- *a", "  b*", "- `a", "  b`", "- a\u{85}b", "", "text",
                   "- | a |\n  | - |\n  | b |", "- | a |", "  | - |", "  x | y", "-\t- n", "- - n\n  - m", "- 1. n", "   2. m", "- # h",
                   "  # h2 #", "- * * *", "- ---", "* - -", "+ +", "- &amp;", "- <a@b.co>", "- <http://x>", "Title\n===\nnext"],
    ]
    static let insertions = ["\n", "\n\n", "\r\n", "- ", "-", " ", "  ", "    ", "\t", "$", "$$", "\\", "`", "```", "~~~", "*", "1. ", ">", "> ",
                             "<", "<!--", "-->", "|", "[", "]", "]: /d", "[id]: /z\n", "x", "---", "===", "#", "* * *", "<div>", "</div>\n", "한", "😀"]

    /// The fields that differ between two parses; empty when they are the same.
    static func differences(_ actual: ParsedDocument, _ expected: ParsedDocument) -> [String] {
        let styles = (Set(BlockReparseTests.canonical(actual)), Set(BlockReparseTests.canonical(expected)))
        var result: [String] = []
        if styles.0 != styles.1 {
            result.append("styles only in reparse \(styles.0.subtracting(styles.1).sorted().prefix(3)), only in parse \(styles.1.subtracting(styles.0).sorted().prefix(3))")
        }
        if actual.elements != expected.elements { result.append("elements \(actual.elements.map(\.span)) != \(expected.elements.map(\.span))") }
        if actual.checkboxes != expected.checkboxes { result.append("checkboxes") }
        if actual.blocks != expected.blocks { result.append("blocks \(actual.blocks.map(\.span)) != \(expected.blocks.map(\.span))") }
        if actual.definitions != expected.definitions { result.append("definitions") }
        if actual.source != expected.source { result.append("source") }
        return result
    }

    /// What `reparse` gets wrong for one edit of `old`, or nil when it declines or agrees.
    static func reproduce(_ old: String, _ range: NSRange, _ replacement: String) -> [String]? {
        let new = (old as NSString).replacingCharacters(in: range, with: replacement)
        guard let result = MarkdownParser.reparse(new, revision: 1, previous: MarkdownParser.parse(old),
                                                  edits: [PresentationEdit(range: range, replacement: replacement)]) else { return nil }
        let found = differences(result.document, MarkdownParser.parse(new, revision: 1))
        return found.isEmpty ? nil : found
    }

    /// Deletes whole lines away from the edit while the difference persists.
    static func minimize(_ old: String, _ range: NSRange, _ replacement: String) -> (old: String, range: NSRange) {
        var old = old, range = range, shrinking = true
        while shrinking {
            shrinking = false
            let text = old as NSString
            var lines: [NSRange] = [], position = 0
            while position < text.length { let line = text.lineRange(for: NSRange(location: position, length: 0)); lines.append(line); position = NSMaxRange(line) }
            for line in lines.reversed() where NSIntersectionRange(line, range).length == 0 && !(line.location <= range.location && range.location <= NSMaxRange(line)) {
                let candidate = text.replacingCharacters(in: line, with: "")
                var moved = range
                if line.location < range.location { moved.location -= line.length }
                if reproduce(candidate, moved, replacement) != nil { old = candidate; range = moved; shrinking = true; break }
            }
        }
        return (old, range)
    }

    struct Run { var partial = 0, whole = 0, small = 0; var failures: [String] = [] }

    static func run(pool name: String, seed: UInt64, rounds: Int) -> Run {
        let pool = pools[name]!
        var generator = Generator(state: seed &* 0x9E37_79B9_7F4A_7C15 &+ UInt64(name.utf8.reduce(0) { $0 &* 31 &+ Int($1) }))
        var run = Run()
        for round in 0..<rounds {
            let newline = ["\n", "\n", "\n", "\r\n", "\r"][generator.next(5)]
            let large = generator.next(4) == 0, raw = generator.next(4) == 0
            let lines = (0..<(large ? 40 + generator.next(80) : 3 + generator.next(25))).map { _ in pool[generator.next(pool.count)] }
            let text = NSMutableString(string: lines.joined(separator: "\n").replacingOccurrences(of: "\n", with: newline) + (generator.next(2) == 0 ? newline : ""))
            var previous = MarkdownParser.parse(text as String)
            for step in 0..<25 {
                let before = text as String
                var edits: [(range: NSRange, replacement: String)] = []
                for _ in 0..<(generator.next(4) == 0 ? 2 : 1) {
                    let location = generator.next(text.length + 1)
                    var range = NSRange(location: location, length: generator.next(3) == 0 ? generator.next(min(12, text.length - location) + 1) : 0)
                    if text.length > 0, !raw { range = text.rangeOfComposedCharacterSequences(for: range) }
                    let replacement = generator.next(4) == 0 ? "" : insertions[generator.next(insertions.count)]
                    edits.append((range, replacement))
                    text.replaceCharacters(in: range, with: replacement)
                }
                let source = text as String
                let expected = MarkdownParser.parse(source, revision: UInt64(step))
                guard let result = MarkdownParser.reparse(source, revision: UInt64(step), previous: previous,
                                                          edits: edits.map { PresentationEdit(range: $0.range, replacement: $0.replacement) }) else {
                    run.whole += 1; previous = expected; continue
                }
                run.partial += 1
                if result.changed.length < text.length / 2 { run.small += 1 }
                let found = differences(result.document, expected)
                guard found.isEmpty else {
                    var report = "pool \(name) seed \(seed) round \(round) step \(step): \(found)"
                    // A difference that depends on what earlier partial parses carried forward, or on two edits
                    // at once, is reported as found; one edit from a whole parse is reduced first.
                    if edits.count == 1, let edit = edits.first, reproduce(before, edit.range, edit.replacement) != nil {
                        let small = minimize(before, edit.range, edit.replacement)
                        report += "\n    reproduce(\(small.old.debugDescription), NSRange(location: \(small.range.location), length: \(small.range.length)), \(edit.replacement.debugDescription))"
                    } else {
                        report += "\n    old \(before.debugDescription) edits \(edits)"
                    }
                    run.failures.append(report)
                    if run.failures.count >= 3 { return run }
                    previous = expected; continue
                }
                previous = generator.next(2) == 0 ? result.document : expected
            }
        }
        return run
    }

    @Test(arguments: ["list", "references", "math", "quote", "exotic"])
    func reparseEqualsParse(pool: String) {
        for seed in Self.seeds {
            let run = Self.run(pool: pool, seed: seed, rounds: Self.rounds)
            for failure in run.failures { Issue.record(Comment(rawValue: failure)) }
            // Most steps must reparse in part, or the comparison says little.
            #expect(run.partial > run.whole * 4, "pool \(pool) seed \(seed): partial \(run.partial), whole \(run.whole)")
            if Self.rounds > 60 { print("FUZZ pool=\(pool) seed=\(seed) rounds=\(Self.rounds) partial=\(run.partial) small=\(run.small) whole=\(run.whole) failures=\(run.failures.count)") }
        }
    }

    /// The differences the review fuzzer found before they were fixed, kept as the fuzzer reports them.
    /// A NUL on a block's last line is here rather than in a pool: it leaves the document without block
    /// spans, so every edit of such a document parses whole and a pool with it would say little. Deep
    /// nesting needs the stack the parsing worker gives it.
    @Test func foundDifferencesStayFixed() {
        let done = DispatchSemaphore(value: 0)
        let thread = Thread { Self.checkFoundDifferences(); done.signal() }
        thread.stackSize = 16 << 20
        thread.start()
        done.wait()
    }
    static func checkFoundDifferences() {
        #expect(reproduce("- x\n- a\n  ===\n- b\n- c\n- d\n- e\n- f\n", NSRange(location: 2, length: 0), "y") == nil)
        #expect(reproduce("- a\n- ~~~\n- x\u{0}y\n\n", NSRange(location: 2, length: 0), "b") == nil)
        // A setext heading whose text is a lone `~~`, which has no position; found by this suite's first long run.
        #expect(reproduce("-- n\n- !  a](\n- ~~\n  ===\n1. b\n", NSRange(location: 5, length: 1), "\r\n") == nil)
        #expect(reproduce(" > t\n  > ===\n-\t- n\n- ~~\n  ===\n1. b\n", NSRange(location: 14, length: 1), "") == nil)
        let stars = String(repeating: "*", count: 1_200)
        #expect(reproduce("<div>\n~~~\n</div>\n\npara one\n\npara two\n\npara three\n\n" + stars + "a" + stars + "\n", NSRange(location: 6, length: 1), "") == nil)
    }
}
