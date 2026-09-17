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
@MainActor final class ArtifactStore {
    private struct Entry {
        let id: Int
        var metrics: ArtifactMetrics
        var image: CGImage?
        var cost: Int
        /// Created on first draw; wraps `image` without copying.
        var drawable: NSImage?
    }
    private var entries: [SourceSpan: Entry] = [:]
    private var spansByID: [Int: SourceSpan] = [:]
    private var nextID = 0
    /// Pixels held outside the protected range are released beyond this many bytes.
    let pixelBudget: Int
    private(set) var pixelBytes = 0

    init(pixelBudget: Int = 64 * 1024 * 1024) { self.pixelBudget = pixelBudget }

    var count: Int { entries.count }
    var residentCount: Int { entries.values.reduce(0) { $1.image == nil ? $0 : $0 + 1 } }
    var residentImages: [CGImage] { entries.values.compactMap(\.image) }

    func store(_ artifact: RenderArtifact, at span: SourceSpan, environment: RenderEnvironment) {
        let metrics = ArtifactMetrics(size: artifact.size, baseline: artifact.baseline, label: artifact.label, environment: environment)
        if var entry = entries[span] {
            pixelBytes -= entry.image == nil ? 0 : entry.cost
            entry.metrics = metrics; entry.image = artifact.image; entry.cost = artifact.cost; entry.drawable = nil
            entries[span] = entry
        } else {
            nextID += 1
            entries[span] = Entry(id: nextID, metrics: metrics, image: artifact.image, cost: artifact.cost)
            spansByID[nextID] = span
        }
        pixelBytes += artifact.cost
    }

    /// Metrics and drawing identity for an element, only if measured in `environment`.
    func layout(at span: SourceSpan, environment: RenderEnvironment) -> (metrics: ArtifactMetrics, id: Int)? {
        guard let entry = entries[span], entry.metrics.environment == environment else { return nil }
        return (entry.metrics, entry.id)
    }

    /// True when the element has no pixels for `environment` and should be rendered.
    func needsPixels(at span: SourceSpan, environment: RenderEnvironment) -> Bool {
        guard let entry = entries[span], entry.metrics.environment == environment else { return true }
        return entry.image == nil
    }

    func hasPixels(at span: SourceSpan) -> Bool { entries[span]?.image != nil }

    /// The image to draw for an attachment, or nil while its pixels are released.
    func drawable(for id: Int) -> NSImage? {
        guard let span = spansByID[id], var entry = entries[span], let image = entry.image else { return nil }
        if let drawable = entry.drawable { return drawable }
        let drawable = NSImage(cgImage: image, size: entry.metrics.size)
        drawable.accessibilityDescription = entry.metrics.label
        entry.drawable = drawable
        entries[span] = entry
        return drawable
    }

    /// While over budget, releases pixels outside `protected`, farthest from it first. Metrics are kept.
    func releasePixels(protecting protected: NSRange, budget: Int? = nil) {
        let pixelBudget = budget ?? self.pixelBudget
        guard pixelBytes > pixelBudget else { return }
        var candidates: [(span: SourceSpan, distance: Int)] = []
        for (span, entry) in entries where entry.image != nil {
            if span.location < NSMaxRange(protected) && span.end > protected.location { continue }
            candidates.append((span, span.location >= NSMaxRange(protected) ? span.location - NSMaxRange(protected) : protected.location - span.end))
        }
        for candidate in candidates.sorted(by: { $0.distance > $1.distance }) {
            guard pixelBytes > pixelBudget else { break }
            release(candidate.span)
        }
    }

    private func release(_ span: SourceSpan) {
        guard var entry = entries[span], entry.image != nil else { return }
        pixelBytes -= entry.cost
        entry.image = nil; entry.drawable = nil
        entries[span] = entry
    }

    /// Moves entries with an edit; an entry the edit touches is removed.
    func apply(_ edit: PresentationEdit) {
        var moved: [SourceSpan: Entry] = [:]
        moved.reserveCapacity(entries.count)
        for (span, entry) in entries {
            if let span = edit.unchanged(span) {
                moved[span] = entry
                spansByID[entry.id] = span
            } else {
                forget(entry)
            }
        }
        entries = moved
    }

    /// Keeps only entries whose spans are in `spans`.
    func retain(_ spans: Set<SourceSpan>) {
        for (span, entry) in entries where !spans.contains(span) { entries[span] = nil; forget(entry) }
    }

    func remove(_ span: SourceSpan) {
        guard let entry = entries.removeValue(forKey: span) else { return }
        forget(entry)
    }

    func removeAll() {
        entries.removeAll(); spansByID.removeAll(); pixelBytes = 0
    }

    private func forget(_ entry: Entry) {
        spansByID[entry.id] = nil
        if entry.image != nil { pixelBytes -= entry.cost }
    }
}
