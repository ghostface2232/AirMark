import Foundation

/// Keeps the last visual styles in source coordinates while semantic parsing runs.
/// This does not decide Markdown syntax; the next parser result replaces it.
public struct PresentationEdit: Sendable {
    public let range: SourceSpan
    public let replacementLength: Int
    public init(range: NSRange, replacement: String) {
        self.init(range: range, replacementLength: replacement.utf16.count)
    }
    /// An edit is only ever asked how long its replacement is, never what it says.
    public init(range: NSRange, replacementLength: Int) {
        self.range = SourceSpan(range); self.replacementLength = replacementLength
    }
    public func unchanged(_ span: SourceSpan) -> SourceSpan? {
        let delta = replacementLength - range.length
        if span.end <= range.location { return span }
        if span.location >= range.end { return SourceSpan(span.location + delta, span.length) }
        return nil
    }
    public func enclosing(_ span: SourceSpan) -> SourceSpan? {
        if span.end < range.location { return span }
        if span.location > range.end { return SourceSpan(span.location + replacementLength - range.length, span.length) }
        let start = min(span.location, range.location)
        let end = max(range.location + replacementLength, span.end + replacementLength - range.length)
        return end > start ? SourceSpan(start, end - start) : nil
    }
    /// Where `enclosing` moves the start of a span beginning at `position`. Monotonic, so an
    /// ordered list of starts stays ordered.
    public func start(of position: Int) -> Int {
        position > range.end ? position + replacementLength - range.length : min(position, range.location)
    }
}

extension ParsedDocument {
    public func rebased(for edit: PresentationEdit) -> ParsedDocument {
        var result = self
        result.styles = styles.compactMap { run in
            guard let span = edit.enclosing(run.span) else { return nil }
            return StyleRun(span: span, kind: run.kind, markers: run.markers.compactMap(edit.unchanged))
        }
        result.elements = elements.compactMap { element in
            guard let span = edit.unchanged(element.span) else { return nil }
            var moved = element; moved.span = span; return moved
        }
        result.checkboxes = checkboxes.compactMap(edit.unchanged)
        return result
    }
}
