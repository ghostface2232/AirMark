import Foundation

/// The presentation the editor draws while the next parse runs: styles and render elements in
/// source coordinates, moved by each edit exactly as `ParsedDocument.rebased(for:)` moves them.
///
/// Styles live in parallel arrays so an edit shifts integers in place. Each style's reach (its end,
/// or a marker's end past it) is a leaf of a maximum tree. The first style an edit can affect is found
/// by descending that tree, and every style before it is untouched. Queries descend only into subtrees
/// that reach the range, so a style inside a long block quote does not scan the whole quote.
/// A style that an edit removes stays in the arrays as a tombstone until the next parse replaces
/// the store; removing it would shift every later entry.
public struct PresentationStore: Sendable {
    private static let removed = Int.min

    private var starts: [Int] = []
    /// `removed` marks a style deleted by an edit.
    private var ends: [Int] = []
    private var kinds: [StyleKind] = []
    /// Markers of style `i` are `markerStarts[markerBounds[i]..<markerBounds[i + 1]]`.
    private var markerBounds: [Int] = [0]
    /// Within a style, markers are sorted and disjoint. A marker an edit touched has length
    /// `removedMarker`; its start keeps moving with edits so starts stay ordered for binary search.
    private var markerStarts: [Int] = []
    private var markerLengths: [Int] = []
    private static let removedMarker = -1
    /// Maximum tree over `ownReach`: leaves at `leafBase + i`, padding leaves hold `removed`.
    private var reach: [Int] = [removed, removed]
    private var leafBase = 1
    public private(set) var elements: [RenderElement] = []
    /// GFM task boxes `[ ]` / `[x]`, sorted and disjoint. A box an edit touches is dropped.
    public private(set) var checkboxes: [SourceSpan] = []

    public init() {}

    public init(_ document: ParsedDocument) {
        let count = document.styles.count
        starts.reserveCapacity(count); ends.reserveCapacity(count); kinds.reserveCapacity(count)
        markerBounds.reserveCapacity(count + 1)
        for run in document.styles {
            starts.append(run.span.location)
            ends.append(run.span.end)
            kinds.append(run.kind)
            for marker in run.markers {
                markerStarts.append(marker.location)
                markerLengths.append(marker.length)
            }
            markerBounds.append(markerStarts.count)
        }
        while leafBase < count { leafBase *= 2 }
        reach = Array(repeating: Self.removed, count: 2 * leafBase)
        for index in 0..<count { reach[leafBase + index] = ownReach(index) }
        for node in stride(from: leafBase - 1, to: 0, by: -1) { reach[node] = max(reach[2 * node], reach[2 * node + 1]) }
        elements = document.elements
        checkboxes = document.checkboxes.sorted { $0.location < $1.location }
    }

    /// Number of styles still present, excluding those removed by edits.
    public var styleCount: Int { ends.reduce(0) { $1 == Self.removed ? $0 : $0 + 1 } }

    /// Every live style in document order. Linear; intended for tests and diagnostics.
    public var styles: [StyleRun] { (0..<starts.count).compactMap { run($0) } }

    // MARK: Edits

    public mutating func apply(_ edit: PresentationEdit) {
        let location = edit.range.location
        let pivot = firstReaching(location)
        for index in pivot..<starts.count {
            if ends[index] != Self.removed {
                if let span = edit.enclosing(SourceSpan(starts[index], ends[index] - starts[index])) {
                    starts[index] = span.location
                    ends[index] = span.end
                    for marker in markerBounds[index]..<markerBounds[index + 1] {
                        if markerLengths[marker] != Self.removedMarker, let moved = edit.unchanged(SourceSpan(markerStarts[marker], markerLengths[marker])) {
                            markerStarts[marker] = moved.location
                        } else {
                            markerStarts[marker] = edit.start(of: markerStarts[marker])
                            markerLengths[marker] = Self.removedMarker
                        }
                    }
                } else {
                    starts[index] = edit.start(of: starts[index])
                    ends[index] = Self.removed
                }
            } else {
                starts[index] = edit.start(of: starts[index])
            }
            reach[leafBase + index] = ownReach(index)
        }
        updateTree(from: pivot)
        Self.apply(edit, to: &elements, span: \.span)
        Self.apply(edit, to: &checkboxes, span: \.self)
    }

    /// Moves sorted, disjoint spans exactly as `PresentationEdit.unchanged` does. The spans an edit
    /// removes are contiguous, and only those after them move.
    private static func apply<Item>(_ edit: PresentationEdit, to items: inout [Item], span: WritableKeyPath<Item, SourceSpan>) {
        var low = 0, high = items.count
        while low < high {
            let middle = (low + high) / 2
            if items[middle][keyPath: span].end > edit.range.location { high = middle } else { low = middle + 1 }
        }
        var last = low
        while last < items.count, items[last][keyPath: span].location < edit.range.end { last += 1 }
        items.removeSubrange(low..<last)
        let delta = edit.replacementLength - edit.range.length
        guard delta != 0 else { return }
        for index in low..<items.count { items[index][keyPath: span].location += delta }
    }

    /// The last source position at which an edit still changes style `index`. A live style is
    /// affected while its end is at or after the edit and a marker while its end is after it;
    /// a tombstone only needs its start kept in order.
    private func ownReach(_ index: Int) -> Int {
        guard ends[index] != Self.removed else { return starts[index] }
        // Markers are sorted and disjoint, so the last live one reaches furthest.
        for marker in (markerBounds[index]..<markerBounds[index + 1]).reversed() where markerLengths[marker] != Self.removedMarker {
            return max(ends[index], markerStarts[marker] + markerLengths[marker] - 1)
        }
        return ends[index]
    }

    // MARK: Queries

    /// Styles intersecting `range`, in document order. A zero-length range returns the styles
    /// strictly containing its location. Each style carries only the markers touching `range`
    /// (ending at or after its start and starting at or before its end): a block quote has a marker
    /// on every line, and copying all of them made one query cost as much as the quote is long.
    public func styles(intersecting range: SourceSpan) -> [StyleRun] {
        var visits = 0
        return styles(intersecting: range, visits: &visits)
    }

    /// `visits` counts tree nodes examined, so tests can check a query's cost is independent of
    /// how far the styles around it extend.
    func styles(intersecting range: SourceSpan, visits: inout Int) -> [StyleRun] {
        // Starts are ordered, so candidates are a prefix; among them, keep styles reaching past the range start.
        let candidates = firstIndex(in: starts) { $0 >= range.end }
        var result: [StyleRun] = []
        guard candidates > 0 else { return result }
        var stack = [1]
        while let node = stack.popLast() {
            visits += 1
            guard reach[node] > range.location else { continue }
            if node >= leafBase {
                let index = node - leafBase
                if ends[index] != Self.removed, ends[index] > range.location, let run = run(index, markersTouching: range) { result.append(run) }
                continue
            }
            // Right child first so the left one is popped first and results stay in document order.
            // A left child starts where its parent does, which was already a candidate.
            if Self.firstLeaf(of: 2 * node + 1, base: leafBase) < candidates { stack.append(2 * node + 1) }
            stack.append(2 * node)
        }
        return result
    }

    /// The leftmost leaf index under `node`.
    private static func firstLeaf(of node: Int, base: Int) -> Int {
        var node = node
        while node < base { node *= 2 }
        return node - base
    }

    /// The first style whose own reach is at least `location`; every style before it is unaffected
    /// by an edit there.
    private func firstReaching(_ location: Int) -> Int {
        guard reach[1] >= location else { return starts.count }
        var node = 1
        while node < leafBase { node = reach[2 * node] >= location ? 2 * node : 2 * node + 1 }
        return min(node - leafBase, starts.count)
    }

    /// Recomputes the internal nodes above leaves `first...` after they changed.
    private mutating func updateTree(from first: Int) {
        guard first < starts.count else { return }
        var low = (leafBase + first) / 2, high = (leafBase + starts.count - 1) / 2
        while low >= 1 {
            for node in low...high { reach[node] = max(reach[2 * node], reach[2 * node + 1]) }
            if low == 1 { break }
            low /= 2; high /= 2
        }
    }

    /// Elements intersecting `range`, in document order. Element ends are monotonic.
    public func elements(intersecting range: SourceSpan) -> ArraySlice<RenderElement> {
        let first = firstIndex(in: elements) { $0.span.end > range.location }
        var last = first
        while last < elements.count, elements[last].span.location < range.end { last += 1 }
        return elements[first..<last]
    }

    private func run(_ index: Int, markersTouching range: SourceSpan? = nil) -> StyleRun? {
        guard ends[index] != Self.removed else { return nil }
        var first = markerBounds[index], last = markerBounds[index + 1]
        if let range {
            // Marker ends are ordered (a removed marker counts as ending at its start).
            var high = last
            while first < high {
                let middle = (first + high) / 2
                if markerStarts[middle] + max(0, markerLengths[middle]) >= range.location { high = middle } else { first = middle + 1 }
            }
            var stop = first
            while stop < last, markerStarts[stop] <= range.end { stop += 1 }
            last = stop
        }
        var markers: [SourceSpan] = []
        for marker in first..<last where markerLengths[marker] != Self.removedMarker {
            markers.append(SourceSpan(markerStarts[marker], markerLengths[marker]))
        }
        return StyleRun(span: SourceSpan(starts[index], ends[index] - starts[index]), kind: kinds[index], markers: markers)
    }

    // MARK: Comparison with a newer parse

    /// Spans of styles present in exactly one of the two stores. Equivalent to the spans of
    /// `Set(styles).symmetricDifference(Set(other.styles))`, found by walking both stores in start
    /// order instead of hashing every style.
    public func changedStyleSpans(comparedTo other: PresentationStore) -> [SourceSpan] {
        var result: [SourceSpan] = []
        var a = 0, b = 0
        while a < starts.count || b < other.starts.count {
            let start = min(a < starts.count ? starts[a] : .max, b < other.starts.count ? other.starts[b] : .max)
            let leftStart = a, rightStart = b
            while a < starts.count, starts[a] == start { a += 1 }
            while b < other.starts.count, other.starts[b] == start { b += 1 }
            // Most groups are identical in the same order; compare fields without building runs.
            if a - leftStart == b - rightStart,
               zip(leftStart..<a, rightStart..<b).allSatisfy({ sameRun($0, in: other, at: $1) }) { continue }
            let left = (leftStart..<a).compactMap { run($0) }, right = (rightStart..<b).compactMap { other.run($0) }
            if left.count + right.count <= 16 {
                result += left.filter { !right.contains($0) }.map(\.span)
                result += right.filter { !left.contains($0) }.map(\.span)
            } else {
                result += Set(left).symmetricDifference(Set(right)).map(\.span)
            }
        }
        return result
    }

    private func sameRun(_ index: Int, in other: PresentationStore, at otherIndex: Int) -> Bool {
        let removed = ends[index] == Self.removed, otherRemoved = other.ends[otherIndex] == Self.removed
        guard removed == otherRemoved else { return false }
        guard !removed else { return true }
        guard ends[index] == other.ends[otherIndex], kinds[index] == other.kinds[otherIndex] else { return false }
        var marker = markerBounds[index], otherMarker = other.markerBounds[otherIndex]
        let end = markerBounds[index + 1], otherEnd = other.markerBounds[otherIndex + 1]
        while true {
            while marker < end, markerLengths[marker] == Self.removedMarker { marker += 1 }
            while otherMarker < otherEnd, other.markerLengths[otherMarker] == Self.removedMarker { otherMarker += 1 }
            guard marker < end, otherMarker < otherEnd else { return marker == end && otherMarker == otherEnd }
            guard markerStarts[marker] == other.markerStarts[otherMarker], markerLengths[marker] == other.markerLengths[otherMarker] else { return false }
            marker += 1; otherMarker += 1
        }
    }

    /// Elements equal in both stores, at the same spans. Equivalent to
    /// `Set(elements).intersection(Set(other.elements))` for sorted, non-overlapping elements.
    public func unchangedElements(comparedTo other: PresentationStore) -> [RenderElement] {
        var result: [RenderElement] = []
        var a = 0, b = 0
        while a < elements.count, b < other.elements.count {
            let left = elements[a], right = other.elements[b]
            if left.span.location < right.span.location { a += 1 }
            else if right.span.location < left.span.location { b += 1 }
            else {
                if left == right { result.append(left) }
                a += 1; b += 1
            }
        }
        return result
    }

    /// The first index whose value satisfies a predicate that is false then true across the array.
    private func firstIndex<Element>(in array: [Element], where predicate: (Element) -> Bool) -> Int {
        var low = 0, high = array.count
        while low < high {
            let middle = (low + high) / 2
            if predicate(array[middle]) { high = middle } else { low = middle + 1 }
        }
        return low
    }
}
