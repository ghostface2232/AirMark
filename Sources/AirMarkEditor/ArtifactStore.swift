import AppKit
import AirMarkCore
import AirMarkRender

/// What layout needs from a rendered element. Kept for every element rendered in the current
/// environment, whether or not its pixels are still held, so releasing pixels never moves text.
/// Valid only for the environment it was measured in: a different width, font size, scale or
/// appearance can change the size, so a lookup under another environment finds nothing.
struct ArtifactMetrics: Equatable {
    var size: CGSize
    var baseline: CGFloat
    var label: String
    var environment: RenderEnvironment
}

/// Rendered elements keyed by source span, with pixel residency separate from layout metrics.
///
/// ImageIO and WebKit results decode lazily and stay resident once drawn, so holding every element
/// ever scrolled past held every decoded pixel. Pixels are now kept for elements near the viewport
/// and, beyond that, only within a byte budget, released farthest first. Metrics stay, and drawing
/// asks the store for pixels by a stable identity that survives edits moving the span.
///
/// Metrics accumulate for every element rendered in the environment, which in a long document is far
/// more than the pixels held. So the two are separate collections: every operation that runs per
/// keystroke, per render or per scroll costs at most a binary search plus the entries after an edit,
/// shifted as integers, and pixel release looks only at elements holding pixels.
@MainActor final class ArtifactStore {
    private struct Record {
        let id: Int
        var metrics: ArtifactMetrics
    }
    private struct Pixels {
        var image: CGImage
        var cost: Int
        var size: CGSize
        var label: String
        /// Created on first draw; wraps `image` without copying.
        var drawable: NSImage?
    }
    /// Every measured element.
    private var measured = SpanList<Record>()
    /// The elements holding pixels, by identity; a subset of `measured` at the same spans.
    private var resident = SpanList<Int>()
    private var pixels: [Int: Pixels] = [:]
    private var nextID = 0
    /// Pixels held outside the protected range are released beyond this many bytes.
    let pixelBudget: Int
    private(set) var pixelBytes = 0

    init(pixelBudget: Int = 64 * 1024 * 1024) { self.pixelBudget = pixelBudget }

    var count: Int { measured.count }
    var residentCount: Int { resident.count }
    var residentImages: [CGImage] { pixels.values.map(\.image) }

    func store(_ artifact: RenderArtifact, at span: SourceSpan, environment: RenderEnvironment) {
        let metrics = ArtifactMetrics(size: artifact.size, baseline: artifact.baseline, label: artifact.label, environment: environment)
        let id: Int
        if let index = measured.index(of: span) {
            id = measured.payloads[index].id
            measured.payloads[index].metrics = metrics
        } else {
            nextID += 1
            id = nextID
            // Elements never overlap, so nothing is displaced in practice; a displaced entry is forgotten.
            for (removedSpan, record) in measured.insert(Record(id: id, metrics: metrics), at: span) { forget(record.id, at: removedSpan) }
        }
        if let held = pixels[id] { pixelBytes -= held.cost } else { _ = resident.insert(id, at: span) }
        pixels[id] = Pixels(image: artifact.image, cost: artifact.cost, size: artifact.size, label: artifact.label)
        pixelBytes += artifact.cost
    }

    /// Metrics and drawing identity for an element, only if measured in `environment`.
    func layout(at span: SourceSpan, environment: RenderEnvironment) -> (metrics: ArtifactMetrics, id: Int)? {
        guard let index = measured.index(of: span) else { return nil }
        let record = measured.payloads[index]
        guard record.metrics.environment == environment else { return nil }
        return (record.metrics, record.id)
    }

    /// True when the element has no pixels for `environment` and should be rendered.
    func needsPixels(at span: SourceSpan, environment: RenderEnvironment) -> Bool {
        guard let index = measured.index(of: span), measured.payloads[index].metrics.environment == environment else { return true }
        return pixels[measured.payloads[index].id] == nil
    }

    func hasPixels(at span: SourceSpan) -> Bool {
        guard let index = measured.index(of: span) else { return false }
        return pixels[measured.payloads[index].id] != nil
    }

    /// The image to draw for an attachment, or nil while its pixels are released.
    func drawable(for id: Int) -> NSImage? {
        guard var held = pixels[id] else { return nil }
        if let drawable = held.drawable { return drawable }
        let drawable = NSImage(cgImage: held.image, size: held.size)
        drawable.accessibilityDescription = held.label
        held.drawable = drawable
        pixels[id] = held
        return drawable
    }

    /// While over budget, releases pixels outside `protected`, farthest from it first. Metrics are kept.
    ///
    /// Resident spans are sorted and disjoint, so those before `protected` get nearer from the first
    /// one on and those after it get nearer from the last one back: the farthest remaining element is
    /// always at one of the two ends, and what is released is a prefix and a suffix.
    func releasePixels(protecting protected: NSRange, budget: Int? = nil) {
        let pixelBudget = budget ?? self.pixelBudget
        guard pixelBytes > pixelBudget else { return }
        let before = resident.firstEnding(after: protected.location)
        let after = max(before, resident.firstStarting(atOrAfter: NSMaxRange(protected)))
        var prefix = 0, suffix = resident.count
        while pixelBytes > pixelBudget, prefix < before || suffix > after {
            let left = prefix < before ? protected.location - resident.spans[prefix].end : -1
            let right = suffix > after ? resident.spans[suffix - 1].location - NSMaxRange(protected) : -1
            let index: Int
            if left >= right { index = prefix; prefix += 1 } else { suffix -= 1; index = suffix }
            if let held = pixels.removeValue(forKey: resident.payloads[index]) { pixelBytes -= held.cost }
        }
        resident.removeSubrange(suffix..<resident.count)
        resident.removeSubrange(0..<prefix)
    }

    /// Moves entries with an edit; an entry the edit touches is removed.
    func apply(_ edit: PresentationEdit) {
        for (_, record) in measured.apply(edit) {
            if let held = pixels.removeValue(forKey: record.id) { pixelBytes -= held.cost }
        }
        _ = resident.apply(edit)
    }

    /// Keeps only entries whose spans are in `spans`.
    func retain(_ spans: Set<SourceSpan>) {
        for (span, record) in measured.removeAll(where: { !spans.contains($0) }) { forget(record.id, at: span) }
    }

    func remove(_ span: SourceSpan) {
        guard let index = measured.index(of: span) else { return }
        let record = measured.remove(at: index)
        forget(record.id, at: span)
    }

    func removeAll() {
        measured.removeAll(); resident.removeAll(); pixels.removeAll(); pixelBytes = 0
    }

    private func forget(_ id: Int, at span: SourceSpan) {
        guard let held = pixels.removeValue(forKey: id) else { return }
        pixelBytes -= held.cost
        if let index = resident.index(of: span) { _ = resident.remove(at: index) }
    }
}

/// Sorted, disjoint source spans, each with a payload. Render elements never overlap, so the entries
/// an edit touches are contiguous and only those after them move, by integer arithmetic on `spans`.
struct SpanList<Payload> {
    private(set) var spans: [SourceSpan] = []
    var payloads: [Payload] = []

    var count: Int { spans.count }

    /// The first index whose span ends after `location`.
    func firstEnding(after location: Int) -> Int {
        var low = 0, high = spans.count
        while low < high {
            let middle = (low + high) / 2
            if spans[middle].end > location { high = middle } else { low = middle + 1 }
        }
        return low
    }

    /// The first index whose span starts at or after `location`.
    func firstStarting(atOrAfter location: Int) -> Int {
        var low = 0, high = spans.count
        while low < high {
            let middle = (low + high) / 2
            if spans[middle].location >= location { high = middle } else { low = middle + 1 }
        }
        return low
    }

    func index(of span: SourceSpan) -> Int? {
        let index = firstStarting(atOrAfter: span.location)
        return index < spans.count && spans[index] == span ? index : nil
    }

    /// Inserts `payload` at `span` in order and returns the entries it overlapped, which it replaces.
    mutating func insert(_ payload: Payload, at span: SourceSpan) -> [(SourceSpan, Payload)] {
        let low = min(firstEnding(after: span.location), firstStarting(atOrAfter: span.location))
        var high = low
        while high < spans.count, spans[high].location < span.end || spans[high].location == span.location { high += 1 }
        let removed = Array(zip(spans[low..<high], payloads[low..<high]))
        spans.replaceSubrange(low..<high, with: CollectionOfOne(span))
        payloads.replaceSubrange(low..<high, with: CollectionOfOne(payload))
        return removed
    }

    mutating func remove(at index: Int) -> Payload {
        spans.remove(at: index)
        return payloads.remove(at: index)
    }

    mutating func removeSubrange(_ range: Range<Int>) {
        guard !range.isEmpty else { return }
        spans.removeSubrange(range)
        payloads.removeSubrange(range)
    }

    mutating func removeAll() { spans.removeAll(); payloads.removeAll() }

    /// Removes the entries whose spans satisfy `predicate`, keeping order, and returns them.
    mutating func removeAll(where predicate: (SourceSpan) -> Bool) -> [(SourceSpan, Payload)] {
        var removed: [(SourceSpan, Payload)] = []
        var kept = 0
        for index in spans.indices {
            if predicate(spans[index]) {
                removed.append((spans[index], payloads[index]))
            } else {
                if kept != index { spans.swapAt(kept, index); payloads.swapAt(kept, index) }
                kept += 1
            }
        }
        spans.removeSubrange(kept...)
        payloads.removeSubrange(kept...)
        return removed
    }

    /// Moves spans exactly as `PresentationEdit.unchanged` does and returns the entries it removes.
    mutating func apply(_ edit: PresentationEdit) -> [(SourceSpan, Payload)] {
        let low = firstEnding(after: edit.range.location)
        var high = low
        while high < spans.count, spans[high].location < edit.range.end { high += 1 }
        var removed: [(SourceSpan, Payload)] = []
        if high > low {
            removed = Array(zip(spans[low..<high], payloads[low..<high]))
            removeSubrange(low..<high)
        }
        let delta = edit.replacementLength - edit.range.length
        guard delta != 0 else { return removed }
        spans.withUnsafeMutableBufferPointer { buffer in
            for index in low..<buffer.count { buffer[index].location += delta }
        }
        return removed
    }
}
