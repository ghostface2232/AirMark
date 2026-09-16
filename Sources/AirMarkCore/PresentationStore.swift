import Foundation

/// The presentation the editor draws while the next parse runs: styles and render elements in
/// source coordinates, moved by each edit exactly as `ParsedDocument.rebased(for:)` moves them.
///
/// Styles live in parallel arrays so an edit shifts integers in place. Only styles that can reach
/// the edit are visited: `reach` is a prefix maximum over each style's end (and its markers' ends),
/// so the first affected style is found by binary search and every style before it is untouched.
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
    /// `removed` marks a marker an edit touched.
    private var markerStarts: [Int] = []
    private var markerLengths: [Int] = []
    /// Prefix maximum of the last position at which each style is affected by an edit.
    private var reach: [Int] = []
    public private(set) var elements: [RenderElement] = []
    /// GFM task boxes `[ ]` / `[x]`, sorted and disjoint. A box an edit touches is dropped.
    public private(set) var checkboxes: [SourceSpan] = []

    public init() {}

    public init(_ document: ParsedDocument) {
        let count = document.styles.count
        starts.reserveCapacity(count); ends.reserveCapacity(count); kinds.reserveCapacity(count)
        markerBounds.reserveCapacity(count + 1); reach.reserveCapacity(count)
        var running = Self.removed
        for run in document.styles {
            starts.append(run.span.location)
            ends.append(run.span.end)
            kinds.append(run.kind)
            for marker in run.markers {
                markerStarts.append(marker.location)
                markerLengths.append(marker.length)
            }
            markerBounds.append(markerStarts.count)
            running = max(running, ownReach(starts.count - 1))
            reach.append(running)
        }
        elements = document.elements
        checkboxes = document.checkboxes.sorted { $0.location < $1.location }
    }

    /// Number of styles still present, excluding those removed by edits.
    public var styleCount: Int { ends.reduce(0) { $1 == Self.removed ? $0 : $0 + 1 } }

    /// Every live style in document order. Linear; intended for tests and diagnostics.
    public var styles: [StyleRun] { (0..<starts.count).compactMap(run) }

    // MARK: Edits

    public mutating func apply(_ edit: PresentationEdit) {
        let location = edit.range.location
        let pivot = firstIndex(in: reach) { $0 >= location }
        var running = pivot > 0 ? reach[pivot - 1] : Self.removed
        for index in pivot..<starts.count {
            if ends[index] != Self.removed {
                if let span = edit.enclosing(SourceSpan(starts[index], ends[index] - starts[index])) {
                    starts[index] = span.location
                    ends[index] = span.end
                    for marker in markerBounds[index]..<markerBounds[index + 1] where markerStarts[marker] != Self.removed {
                        markerStarts[marker] = edit.unchanged(SourceSpan(markerStarts[marker], markerLengths[marker]))?.location ?? Self.removed
                    }
                } else {
                    starts[index] = edit.start(of: starts[index])
                    ends[index] = Self.removed
                }
            } else {
                starts[index] = edit.start(of: starts[index])
            }
            running = max(running, ownReach(index))
            reach[index] = running
        }
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
        var result = ends[index]
        for marker in markerBounds[index]..<markerBounds[index + 1] where markerStarts[marker] != Self.removed {
            result = max(result, markerStarts[marker] + markerLengths[marker] - 1)
        }
        return result
    }

    // MARK: Queries

    /// Styles intersecting `range`, in document order. A zero-length range returns the styles
    /// strictly containing its location.
    public func styles(intersecting range: SourceSpan) -> [StyleRun] {
        var result: [StyleRun] = []
        var index = firstIndex(in: reach) { $0 > range.location }
        while index < starts.count, starts[index] < range.end {
            if ends[index] != Self.removed, ends[index] > range.location, let run = run(index) { result.append(run) }
            index += 1
        }
        return result
    }

    /// Elements intersecting `range`, in document order. Element ends are monotonic.
    public func elements(intersecting range: SourceSpan) -> ArraySlice<RenderElement> {
        let first = firstIndex(in: elements) { $0.span.end > range.location }
        var last = first
        while last < elements.count, elements[last].span.location < range.end { last += 1 }
        return elements[first..<last]
    }

    private func run(_ index: Int) -> StyleRun? {
        guard ends[index] != Self.removed else { return nil }
        var markers: [SourceSpan] = []
        for marker in markerBounds[index]..<markerBounds[index + 1] where markerStarts[marker] != Self.removed {
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
            let left = (leftStart..<a).compactMap(run), right = (rightStart..<b).compactMap(other.run)
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
            while marker < end, markerStarts[marker] == Self.removed { marker += 1 }
            while otherMarker < otherEnd, other.markerStarts[otherMarker] == Self.removed { otherMarker += 1 }
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
