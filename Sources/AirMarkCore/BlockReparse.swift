import Foundation

extension MarkdownParser {
    /// Parses `source` by reparsing only the top-level blocks that `edits` touched, given `previous`,
    /// the parse of the text the edits were made to, in order. Returns the parse, which equals
    /// `parse(source, revision:)`, and the span of `source` whose parse may differ from `previous`;
    /// nil when the whole document has to be parsed.
    ///
    /// The window reparsed is the touched blocks plus at least one unchanged margin block on each side,
    /// widened until both ends are at a blank line between blocks, or between two items of a top-level
    /// list: an item starts on its own line whatever the item before it holds, so a long list is not one
    /// block. Display math is the one thing found without regard to blocks, and only a blank line stops
    /// it: a `$$` outside the window could pair with one inside, or through the window, or stop at a
    /// table or code span that the edit made or unmade. So items are cut apart only when no `$$` stands
    /// between the window and the blank lines around it; otherwise the window is widened to those. Block structure is decided line by
    /// line from the containers still open, so when the margin blocks reparse to exactly what they were,
    /// the edit did not reach past them: an unterminated fence, an HTML block, or a paragraph or list
    /// that absorbed its neighbour would change them. The window then doubles its margins, and past a
    /// quarter of the document (or 64KB) the document is parsed whole. Inline syntax and math do not cross
    /// a blank line, so the window holds them too.
    ///
    /// Link reference definitions resolve links anywhere in the document, and nothing else about them
    /// reaches outside their own paragraph: cmark collects them while it builds blocks and reads them
    /// only when it parses inlines. So the window is parsed with the document's other definitions
    /// standing before and after it, as they do in the document, and the result is kept only if the
    /// window's own definitions are the ones it had. A change to a definition parses the document
    /// whole; typing anywhere else does not, however many definitions there are.
    public static func reparse(_ source: String, revision: UInt64, previous: ParsedDocument, edits: [PresentationEdit])
        -> (document: ParsedDocument, changed: SourceSpan)? {
        let blocks = previous.blocks, count = blocks.count
        guard count > 0 else { return nil }
        let old = previous.source as NSString, new = source as NSString
        guard let first = edits.first else {
            guard old.length == new.length else { return nil }
            var document = previous
            document.source = source; document.revision = revision
            return (document, SourceSpan(0, 0))
        }
        // The one range, in the new text, outside which the text only moved: before it unchanged, after
        // it shifted by `delta`.
        var dirty = SourceSpan(first.range.location, first.replacementLength)
        var delta = first.replacementLength - first.range.length
        for edit in edits.dropFirst() {
            let shift = edit.replacementLength - edit.range.length
            let start = min(dirty.location, edit.range.location)
            dirty = SourceSpan(start, max(dirty.end, edit.range.end) + shift - start)
            delta += shift
        }
        let dirtyOldEnd = dirty.end - delta
        guard old.length + delta == new.length, dirty.location >= 0, dirty.end <= new.length, dirtyOldEnd >= dirty.location else { return nil }
        // Touched blocks are `touchedFirst...touchedLast` (empty when the edit lies between blocks).
        let touchedFirst = firstIndex(blocks) { $0.end >= dirty.location }
        let touchedLast = firstIndex(blocks) { $0.location > dirtyOldEnd } - 1
        func blankLine(between lower: Int, _ upper: Int) -> Bool {
            var index = lower, lineStart = false
            while index < upper {
                let unit = old.character(at: index)
                if unit == 10 || unit == 13 {
                    if unit == 13, index + 1 < upper, old.character(at: index + 1) == 10 { index += 1 }
                    if lineStart { return true }
                    lineStart = true
                } else if unit != 32 && unit != 9 {
                    lineStart = false
                }
                index += 1
            }
            return false
        }
        var betweenItems = true
        /// Whether the window may be cut before block `index`; `itemCut` reports a cut with no blank line.
        func cut(before index: Int, itemCut: inout Bool) -> Bool {
            if blankLine(between: blocks[index - 1].end, blocks[index].location) { return true }
            guard betweenItems, blocks[index - 1].isListItem, blocks[index].isListItem else { return false }
            itemCut = true
            return true
        }
        /// Whether `$$` stands outside the window `start..<end` of blocks `lower...upper`, before the
        /// blank lines on either side of it.
        func displayMathAround(_ lower: Int, _ upper: Int, _ start: Int, _ end: Int) -> Bool {
            var first = lower, last = upper
            while first > 0, !blankLine(between: blocks[first - 1].end, blocks[first].location) { first -= 1 }
            while last < count - 1, !blankLine(between: blocks[last].end, blocks[last + 1].location) { last += 1 }
            let from = first == 0 ? 0 : blocks[first].location, to = last == count - 1 ? old.length : blocks[last + 1].location
            func found(_ lower: Int, _ upper: Int) -> Bool {
                upper > lower && old.range(of: "$$", options: .literal, range: NSRange(location: lower, length: upper - lower)).location != NSNotFound
            }
            return found(min(from, start), start) || found(end, max(to, end))
        }
        let limit = max(65_536, old.length / 4)
        var margin = 1
        while true {
            var lower = max(touchedFirst - margin, 0), upper = min(touchedLast + margin, count - 1)
            var itemCut = false
            while lower > 0, !cut(before: lower, itemCut: &itemCut) { lower -= 1 }
            while upper < count - 1, !cut(before: upper + 1, itemCut: &itemCut) { upper += 1 }
            let whole = lower == 0 && upper == count - 1
            let start = lower == 0 ? 0 : old.lineRange(for: NSRange(location: blocks[lower].location, length: 0)).location
            let oldEnd = upper == count - 1 ? old.length : old.lineRange(for: NSRange(location: blocks[upper + 1].location, length: 0)).location
            guard oldEnd - start <= limit || whole else { return nil }
            let window = SourceSpan(start, oldEnd + delta - start)
            if itemCut, displayMathAround(lower, upper, start, oldEnd) { betweenItems = false; continue }
            let text = new.substring(with: window.nsRange)
            guard nestingEstimate(text) <= nestingLimit, inlineNestingEstimate(text) <= inlineNestingLimit else { return nil }
            // The definitions the window held, and where they stand among the document's. Two equal
            // runs are interchangeable: either way the parse below ranks the same definitions in the
            // same order as the document does.
            let all = previous.definitions
            var held: [ReferenceDefinition] = []
            if !all.isEmpty {
                let oldText = old.substring(with: NSRange(location: start, length: oldEnd - start))
                if mayDefineReferences(oldText) { held = parse(oldText, revision: revision).definitions }
            }
            guard let position = held.isEmpty ? all.count : (0...(all.count - min(all.count, held.count))).first(where: { all[$0...].starts(with: held) }),
                  let part = parse(text, revision: revision, enforcingLimit: true, before: Array(all[..<position]), after: Array(all[(position + held.count)...])),
                  part.definitions == held else { return nil }
            let largest = all.lazy.map(\.size).max() ?? 0
            guard part.referenceExpansion + largest <= referenceExpansionFloor,
                  previous.referenceExpansion + part.referenceExpansion + largest <= max(referenceExpansionFloor, new.length) else { return nil }
            func moved(_ block: Block, by offset: Int) -> Block { Block(SourceSpan(block.location + offset, block.span.length), isListItem: block.isListItem) }
            let reparsed = part.blocks.map { moved($0, by: start) }
            let leading = blocks[lower..<max(lower, touchedFirst)]
            let trailing = blocks[min(touchedLast + 1, upper + 1)..<(upper + 1)].map { moved($0, by: delta) }
            let fits = reparsed.count >= leading.count + trailing.count
                && reparsed.prefix(leading.count).elementsEqual(leading)
                && reparsed.suffix(trailing.count).elementsEqual(trailing)
            if fits || whole {
                return (splice(previous, part, source: source, revision: revision, window: window, oldEnd: oldEnd, delta: delta), window)
            }
            margin *= 2
        }
    }

    /// `previous` before `window`, `part` (parsed from the window's text) in it, and `previous` after
    /// it moved by `delta`. Each list is sorted by start, so every part is a contiguous run.
    private static func splice(_ previous: ParsedDocument, _ part: ParsedDocument, source: String, revision: UInt64,
                               window: SourceSpan, oldEnd: Int, delta: Int) -> ParsedDocument {
        let start = window.location
        func moved(_ span: SourceSpan, by offset: Int) -> SourceSpan { SourceSpan(span.location + offset, span.length) }
        func stitch<Item>(_ before: [Item], _ inside: [Item], location: (Item) -> Int, move: (Item, Int) -> Item) -> [Item] {
            let head = firstIndex(before) { location($0) >= start }, tail = firstIndex(before) { location($0) >= oldEnd }
            var result = Array(before[..<head])
            result.reserveCapacity(before.count - (tail - head) + inside.count)
            result += inside.lazy.map { move($0, start) }
            result += before[tail...].lazy.map { move($0, delta) }
            return result
        }
        var document = ParsedDocument(source: source, revision: revision)
        document.definitions = previous.definitions
        document.referenceExpansion = previous.referenceExpansion + part.referenceExpansion
        document.styles = stitch(previous.styles, part.styles, location: \.span.location) { run, offset in
            StyleRun(span: moved(run.span, by: offset), kind: run.kind, markers: run.markers.map { moved($0, by: offset) })
        }
        document.elements = stitch(previous.elements, part.elements, location: \.span.location) { element, offset in
            var element = element; element.span = moved(element.span, by: offset); return element
        }
        document.checkboxes = stitch(previous.checkboxes, part.checkboxes, location: \.location) { moved($0, by: $1) }
        document.blocks = stitch(previous.blocks, part.blocks, location: \.location) { Block(moved($0.span, by: $1), isListItem: $0.isListItem) }
        return document
    }

    private static func firstIndex<Item>(_ items: [Item], where predicate: (Item) -> Bool) -> Int {
        var low = 0, high = items.count
        while low < high {
            let middle = (low + high) / 2
            if predicate(items[middle]) { high = middle } else { low = middle + 1 }
        }
        return low
    }
}
