import AppKit
import Testing
import AirMarkCore
@testable import AirMarkEditor
@testable import AirMarkRender

/// The dictionary-backed artifact store that `ArtifactStore` replaced, kept as the reference for its
/// behavior. Its release order among equal distances was unspecified; here the element before the
/// protected range goes first, as in `ArtifactStore`.
@MainActor final class ReferenceArtifactStore {
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
        // Equal distances can only be one element before and one after; the one before goes first.
        for candidate in candidates.sorted(by: { $0.distance != $1.distance ? $0.distance > $1.distance : $0.span.location < $1.span.location }) {
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

/// `ArtifactStore` against the reference on random operations: stores at disjoint element spans,
/// edits of every shape, releases with random protected ranges and budgets, parse retention and
/// removals. Every observable answer must match after each step.
@Suite @MainActor struct ArtifactStoreDifferentialTests {
    @Test func matchesReferenceOnRandomOperations() {
        var generator: UInt64 = 0x9E3779B97F4A7C15
        func random(_ bound: Int) -> Int {
            generator = generator &* 6364136223846793005 &+ 1442695040888963407
            return Int((generator >> 33) % UInt64(max(1, bound)))
        }
        let light = RenderEnvironment(width: 600, fontSize: 16, scale: 2, dark: false)
        var narrow = light; narrow.width = 300
        let images = (1...4).map { ArtifactResidencyTests.artifact(width: 4 * $0, height: 3 * $0, label: "image \($0)") }
        var steps = 0
        for round in 0..<60 {
            let budget = images[0].cost * (1 + random(12))
            let store = ArtifactStore(pixelBudget: budget), reference = ReferenceArtifactStore(pixelBudget: budget)
            var length = 2_000
            // The current parse's elements: disjoint, sorted, moved by edits like the presentation's.
            var elements: [SourceSpan] = []
            func reparse() {
                elements = []
                var position = random(20)
                while position < length - 2 {
                    let span = SourceSpan(position, 1 + random(30))
                    guard span.end <= length else { break }
                    elements.append(span)
                    position = span.end + random(60)
                }
            }
            reparse()
            for _ in 0..<400 {
                steps += 1
                switch random(10) {
                case 0...3 where !elements.isEmpty:
                    let span = elements[random(elements.count)], image = images[random(images.count)]
                    let environment = random(8) == 0 ? narrow : light
                    store.store(image, at: span, environment: environment); reference.store(image, at: span, environment: environment)
                case 4, 5:
                    let location = random(length + 1), removed = random(4) == 0 ? random(min(200, length - location) + 1) : random(min(3, length - location) + 1)
                    let inserted = random(3) == 0 ? "" : String(repeating: "x", count: 1 + random(5))
                    let edit = PresentationEdit(range: NSRange(location: location, length: removed), replacement: inserted)
                    store.apply(edit); reference.apply(edit)
                    elements = elements.compactMap(edit.unchanged)
                    length += inserted.utf16.count - removed
                case 6, 7:
                    let location = random(length + 1)
                    let protected = NSRange(location: location, length: random(min(400, length - location) + 1))
                    let budget = random(3) == 0 ? random(budget + 1) : nil
                    store.releasePixels(protecting: protected, budget: budget); reference.releasePixels(protecting: protected, budget: budget)
                case 8:
                    // A new parse keeps some unchanged elements.
                    let kept = Set(elements.filter { _ in random(4) != 0 })
                    store.retain(kept); reference.retain(kept)
                    reparse()
                    elements = Array(Set(elements).union(kept)).sorted { $0.location < $1.location }
                    var disjoint: [SourceSpan] = []
                    for span in elements where disjoint.last.map({ $0.end <= span.location }) ?? true { disjoint.append(span) }
                    elements = disjoint
                    let dropped = kept.subtracting(elements)
                    for span in dropped { store.remove(span); reference.remove(span) }
                default:
                    if let span = elements.randomElementDeterministic(random) { store.remove(span); reference.remove(span) }
                }
                #expect(store.count == reference.count, "round \(round) step \(steps)")
                #expect(store.residentCount == reference.residentCount, "round \(round) step \(steps)")
                #expect(store.pixelBytes == reference.pixelBytes, "round \(round) step \(steps)")
                for span in elements {
                    for environment in [light, narrow] {
                        let a = store.layout(at: span, environment: environment), b = reference.layout(at: span, environment: environment)
                        #expect(a?.metrics == b?.metrics && a?.id == b?.id, "round \(round) step \(steps) span \(span)")
                        #expect(store.needsPixels(at: span, environment: environment) == reference.needsPixels(at: span, environment: environment))
                    }
                    #expect(store.hasPixels(at: span) == reference.hasPixels(at: span), "round \(round) step \(steps) span \(span)")
                    if let id = store.layout(at: span, environment: light)?.id ?? store.layout(at: span, environment: narrow)?.id {
                        #expect((store.drawable(for: id) != nil) == (reference.drawable(for: id) != nil))
                    }
                }
            }
        }
    }
}

private extension Array {
    func randomElementDeterministic(_ random: (Int) -> Int) -> Element? { isEmpty ? nil : self[random(count)] }
}
