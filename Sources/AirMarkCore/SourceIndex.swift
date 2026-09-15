import Foundation

public struct SourceSpan: Hashable, Codable, Sendable {
    public var location: Int
    public var length: Int
    public init(_ location: Int, _ length: Int) { self.location = location; self.length = length }
    public init(_ range: NSRange) { self.init(range.location, range.length) }
    public var end: Int { location + length }
    public var nsRange: NSRange { NSRange(location: location, length: length) }
    public func contains(_ offset: Int) -> Bool { location <= offset && offset < end }
    public func intersects(_ other: Self) -> Bool { location < other.end && other.location < end }
}

/// Markdown lines and TextKit paragraphs deliberately have different boundaries.
public struct SourceIndex: Sendable {
    public private(set) var source: String
    public private(set) var lines: [SourceSpan]
    private var units: [UInt16]
    public var utf16Count: Int { units.count }
    public init(_ source: String) {
        self.source = source
        self.units = Array(source.utf16)
        self.lines = Self.lineRanges(source)
    }
    private static func lineRanges(_ source: String) -> [SourceSpan] {
        let units = Array(source.utf16)
        var result: [SourceSpan] = []
        var start = 0, i = 0
        while i < units.count {
            if units[i] == 10 || units[i] == 13 {
                if units[i] == 13 && i + 1 < units.count && units[i + 1] == 10 { i += 1 }
                result.append(SourceSpan(start, i + 1 - start)); start = i + 1
            }
            i += 1
        }
        result.append(SourceSpan(start, units.count - start))
        return result
    }
    public func offset(line: Int, utf8Column: Int) -> Int? {
        guard line > 0, line <= lines.count, utf8Column > 0 else { return nil }
        let span = lines[line - 1]
        let text = self.text(in: span)
        let bytes = Array(text.utf8)
        let count = utf8Column - 1
        guard count <= bytes.count, let prefix = String(bytes: bytes.prefix(count), encoding: .utf8) else { return nil }
        return span.location + prefix.utf16.count
    }
    public func paragraph(at offset: Int) -> SourceSpan {
        let string = source as NSString
        guard string.length > 0 else { return SourceSpan(0, 0) }
        return SourceSpan(string.paragraphRange(for: NSRange(location: min(max(0, offset), string.length), length: 0)))
    }
    public func text(in span: SourceSpan) -> String {
        guard span.location >= 0, span.end <= utf16Count else { return "" }
        return String(decoding: units[span.location..<span.end], as: UTF16.self)
    }
    public mutating func apply(_ range: NSRange, replacement: String) throws {
        guard range.location >= 0, range.length >= 0, NSMaxRange(range) <= utf16Count,
              Range(range, in: source) != nil else { throw SourceError.invalidRange }
        // Rebuild only the affected suffix; offsets remain source coordinates.
        let first = max(0, (lines.lastIndex { $0.location <= range.location } ?? 0) - 1)
        let restart = lines[first].location
        source = (source as NSString).replacingCharacters(in: range, with: replacement)
        units.replaceSubrange(range.location..<NSMaxRange(range), with: replacement.utf16)
        let suffix = (source as NSString).substring(from: restart)
        lines = Array(lines.prefix(first)) + Self.lineRanges(suffix).map { SourceSpan($0.location + restart, $0.length) }
    }
}

public enum SourceError: Error { case invalidRange, invalidUTF8 }
