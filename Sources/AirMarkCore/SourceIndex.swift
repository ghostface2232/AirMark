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
    /// The source's UTF-16, which every offset here counts in.
    public private(set) var units: [UInt16]
    private struct Checkpoint: Sendable {
        var utf8: Int
        var utf16: Int
    }
    private var checkpoints: [Checkpoint] = []
    private var lineByteOffsets: [Int] = []
    /// Leading UTF-16 units of each line below U+0080. A column within them is the same number of
    /// UTF-16 units, so most parser locations need neither a checkpoint search nor a scalar walk.
    private var lineASCIIPrefix: [Int] = []
    private var byteCount = 0
    public var utf16Count: Int { units.count }
    public init(_ source: String) {
        self.source = source
        // One bulk copy. The editor's text is bridged from `NSString`, whose `utf16` view is iterated
        // a unit at a time through the bridge; a native string transcodes here as fast either way.
        let text = source as NSString, length = text.length
        self.units = [UInt16](unsafeUninitializedCapacity: length) { buffer, count in
            if length > 0 { text.getCharacters(buffer.baseAddress!, range: NSRange(location: 0, length: length)) }
            count = length
        }
        self.lines = Self.lineRanges(units)
        rebuildColumns()
    }
    /// Checkpoints about every 64 UTF-16 units bound a lookup to at most 65 units (a surrogate pair
    /// can cross the threshold).
    /// No line-sized strings, byte arrays or decoded prefixes are allocated per AST location.
    private mutating func rebuildColumns() {
        checkpoints = [Checkpoint(utf8: 0, utf16: 0)]
        lineByteOffsets = []
        lineByteOffsets.reserveCapacity(lines.count)
        lineASCIIPrefix = []
        lineASCIIPrefix.reserveCapacity(lines.count)
        var offset = 0, bytes = 0, line = 0, asciiRun = false
        while offset < units.count {
            if line < lines.count, lines[line].location == offset {
                lineByteOffsets.append(bytes); lineASCIIPrefix.append(0); line += 1; asciiRun = true
            }
            if asciiRun {
                if units[offset] < 0x80 { lineASCIIPrefix[line - 1] += 1 } else { asciiRun = false }
            }
            if offset - checkpoints.last!.utf16 >= 64 {
                checkpoints.append(Checkpoint(utf8: bytes, utf16: offset))
            }
            let width = scalarWidth(at: offset)
            offset += width.utf16; bytes += width.utf8
        }
        if line < lines.count { lineByteOffsets.append(bytes); lineASCIIPrefix.append(0) }
        byteCount = bytes
    }
    private func scalarWidth(at offset: Int) -> (utf8: Int, utf16: Int) {
        let unit = units[offset]
        if unit < 0x80 { return (1, 1) }
        if unit < 0x800 { return (2, 1) }
        if unit >= 0xD800 && unit <= 0xDBFF { return (4, 2) }
        return (3, 1)
    }
    private static func lineRanges(_ units: [UInt16]) -> [SourceSpan] {
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
        let start = lineByteOffsets[line - 1]
        let end = line < lines.count ? lineByteOffsets[line] : byteCount
        let count = utf8Column - 1
        guard count <= end - start else { return nil }
        if count <= lineASCIIPrefix[line - 1] { return lines[line - 1].location + count }
        let target = start + count
        var low = 0, high = checkpoints.count
        while low < high {
            let middle = (low + high) / 2
            if checkpoints[middle].utf8 <= target { low = middle + 1 } else { high = middle }
        }
        var position = checkpoints[low - 1]
        while position.utf8 < target {
            let width = scalarWidth(at: position.utf16)
            position.utf8 += width.utf8; position.utf16 += width.utf16
        }
        return position.utf8 == target ? position.utf16 : nil
    }
    public func paragraph(at offset: Int) -> SourceSpan {
        let string = source as NSString
        guard string.length > 0 else { return SourceSpan(0, 0) }
        return SourceSpan(string.paragraphRange(for: NSRange(location: min(max(0, offset), string.length), length: 0)))
    }
    /// How many units at the start of one-based `line` satisfy `predicate`.
    public func leadingUnits(ofLine line: Int, while predicate: (UInt16) -> Bool) -> Int {
        let span = lines[line - 1]
        var count = 0
        while count < span.length, predicate(units[span.location + count]) { count += 1 }
        return count
    }
    /// The UTF-16 unit at `offset`, or 0 outside the source.
    public func unit(at offset: Int) -> UInt16 { offset >= 0 && offset < units.count ? units[offset] : 0 }
    public func text(in span: SourceSpan) -> String {
        guard span.location >= 0, span.length >= 0, span.end <= utf16Count else { return "" }
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
        lines = Array(lines.prefix(first)) + Self.lineRanges(Array(suffix.utf16)).map { SourceSpan($0.location + restart, $0.length) }
        rebuildColumns()
    }
}

public enum SourceError: Error { case invalidRange, invalidUTF8 }

extension String {
    /// The string's UTF-8, in place when the string is native. The editor's text arrives bridged from
    /// `NSString`, which has no UTF-8 to point at: Foundation transcodes that in bulk, where reading a
    /// bridged string's `utf8` view, or making the string native, goes through the bridge a piece at a
    /// time (measured on 10MB: about 14 ms against 85–105 ms). Only text Foundation will not encode, a lone
    /// surrogate, takes the slow way, which encodes it as the standard library does.
    public func withUTF8Bytes<Result>(_ body: (UnsafeBufferPointer<UInt8>) -> Result) -> Result {
        if let result = utf8.withContiguousStorageIfAvailable(body) { return result }
        if let data = (self as NSString).data(using: String.Encoding.utf8.rawValue) {
            return data.withUnsafeBytes { body($0.bindMemory(to: UInt8.self)) }
        }
        var native = self
        return native.withUTF8(body)
    }
}
