import Foundation
import Testing
@testable import AirMarkCore

/// The one-pass math scanner must find exactly what the original scanner found, which rescanned the
/// rest of a line from every unclosed dollar sign.
struct MathScannerTests {
    enum Reference {
        static func referenceMathSpans(_ source: String, excluding: [SourceSpan]) -> [RenderElement] {
            let units = Array(source.utf16), text = source as NSString
            var result: [RenderElement] = [], i = 0, protectedIndex = 0
            let excluded = excluding.sorted { $0.location < $1.location }
            func escaped(_ n: Int) -> Bool { var j = n - 1, c = 0; while j >= 0 && units[j] == 92 { c += 1; j -= 1 }; return c % 2 == 1 }
            func whitespace(_ u: UInt16) -> Bool { u == 32 || u == 9 || u == 10 || u == 13 }
            func blankLineAfter(_ n: Int) -> Bool {
                guard units[n] == 10 || units[n] == 13 else { return false }
                var k = n + (units[n] == 13 && n + 1 < units.count && units[n + 1] == 10 ? 2 : 1)
                while k < units.count && (units[k] == 32 || units[k] == 9) { k += 1 }
                return k < units.count && (units[k] == 10 || units[k] == 13)
            }
            while i < units.count {
                while protectedIndex < excluded.count && excluded[protectedIndex].end <= i { protectedIndex += 1 }
                if protectedIndex < excluded.count && excluded[protectedIndex].contains(i) { i = excluded[protectedIndex].end; continue }
                guard units[i] == 36, !escaped(i), i + 1 < units.count else { i += 1; continue }
                let display = units[i + 1] == 36, delimiter = display ? 2 : 1
                if !display && whitespace(units[i + 1]) { i += 1; continue }
                var j = i + delimiter, found: Int?
                while j < units.count {
                    if (!display && (units[j] == 10 || units[j] == 13)) || (display && blankLineAfter(j)) { break }
                    if protectedIndex < excluded.count && j >= excluded[protectedIndex].location { break }
                    if units[j] == 36 && !escaped(j) {
                        if display {
                            if j + 1 < units.count && units[j + 1] == 36 { found = j; break }
                        } else if j > i + 1 && !whitespace(units[j - 1]) && !(j + 1 < units.count && (48...57).contains(units[j + 1])) {
                            found = j; break
                        }
                    }
                    j += 1
                }
                if let close = found {
                    let s = SourceSpan(i, close + delimiter - i)
                    result.append(RenderElement(span: s, kind: .math, content: text.substring(with: NSRange(location: i + delimiter, length: close - i - delimiter)), inline: !display))
                    i = s.end
                } else { i += delimiter }
            }
            return result
        }
    }

    /// Display math ends at a blank line, even one of spaces or tabs or with CRLF endings, so typing an
    /// opening `$$` does not pair it with the next formula several paragraphs away.
    @Test func displayMathDoesNotCrossBlankLines() {
        func math(_ source: String) -> [String] { MarkdownParser.mathSpans(source, excluding: []).map(\.content) }
        #expect(math("$$\n\\frac{a}{b}\n$$") == ["\n\\frac{a}{b}\n"])
        #expect(math("$$a\n\nb$$") == [])
        #expect(math("$$a\n \t\nb$$") == [])
        #expect(math("$$a\r\n\r\nb$$") == [])
        #expect(math("$$a\r\rb$$") == [])
        #expect(math("$$ open\n\ntext\n\n$$x$$") == ["x"])
    }

    @Test func matchesTheRescanningScanner() {
        let pieces = ["$", "$$", "\\", "\\$", "a", "b ", " ", "1", "\n", "\r\n", "\r", "\n \t\n", "x^2", "\t", "한", "😀"]
        var state: UInt64 = 11
        func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(bound))
        }
        for round in 0..<3_000 {
            let source = (0..<(1 + next(40))).map { _ in pieces[next(pieces.count)] }.joined()
            let length = source.utf16.count
            // Sorted, possibly nested or overlapping protected spans, as code and tables produce.
            let excluded = (0..<next(4)).map { _ -> SourceSpan in
                let location = next(length + 1)
                return SourceSpan(location, next(length - location + 1))
            }
            let expected = Reference.referenceMathSpans(source, excluding: excluded)
            let actual = MarkdownParser.mathSpans(source, excluding: excluded)
            #expect(actual == expected, "round \(round): \(source.debugDescription) excluding \(excluded)")
            if actual != expected { return }
        }
    }
}
