import AppKit
import Testing
import AirMarkCore
@testable import AirMarkEditor
@testable import AirMarkRender

/// Release measurements for the recovery, resize and table work. Runs only when AIRMARK_BENCH is set,
/// so an ordinary `swift test` does not pay for it:
///
///     swift test -c release --disable-sandbox --filter RecoveryResizeTableBench
///
/// Nothing here repeats the parse benchmarks — `ParsePacingBench` and `ScaleTests` own those, and a
/// second copy of them would only be a second set of numbers to keep honest.
@Suite(.serialized) @MainActor struct RecoveryResizeTableBench {
    struct Env {
        static let values = ProcessInfo.processInfo.environment
        static var on: Bool { values["AIRMARK_BENCH"] == "1" }
    }
    static func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
    static func p50(_ v: [Double]) -> Double { v.isEmpty ? .nan : v.sorted()[v.count / 2] }
    static func line(_ v: [Double]) -> String {
        String(format: "p50=%.2f min=%.2f max=%.2f", p50(v), v.min() ?? .nan, v.max() ?? .nan)
    }

    // MARK: - Recovery launch

    /// A document of about `bytes`, built from a repeating line so the size is the variable.
    static func document(bytes: Int) -> String {
        let line = "A line of a recovered document, with 한글 and an emoji 😀 in it.\n"
        return String(repeating: line, count: max(1, bytes / line.utf8.count))
    }

    /// What a launch costs for a directory of `count` documents of `bytes` each. Clean records — the
    /// common case, where every document's text was on disk when it was recorded — and a dirty
    /// variant, which is the worst case because the record may hold the only copy and has to be
    /// compared.
    @Test(.enabled(if: Env.on)) func recoveryLaunchCost() async throws {
        for bytes in [1_000_000, 10_000_000] {
            for count in [1, 8, 32] {
                for unsaved in [false, true] {
                    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AirMarkBenchRecovery-" + UUID().uuidString)
                    let recovery = root.appendingPathComponent("Recovery")
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                    defer { try? FileManager.default.removeItem(at: root) }
                    let source = Self.document(bytes: bytes)
                    let writer = RecoveryStore(directory: recovery)
                    var records: [RecoveryRecord] = []
                    for index in 0..<count {
                        let file = root.appendingPathComponent("doc\(index).md")
                        // A dirty record is one whose text is on no disk, so the file differs from it.
                        try Data((unsaved ? source + "edited\n" : source).utf8).write(to: file)
                        var record = RecoveryRecord(id: UUID(), filePath: file.path, source: source, hasBOM: false, revision: 1,
                                                    selection: SourceSpan(0, 0), scrollY: 0, state: .quit, hasUnsavedChanges: unsaved,
                                                    sessionID: writer.sessionID, order: index)
                        record.date = Date().addingTimeInterval(Double(index))
                        try writer.saveImmediately(record)
                        records.append(record)
                    }

                    // A fresh store per sample: the one the app makes at launch has read nothing yet.
                    var metadataCost: [Double] = [], planCost: [Double] = [], recordsCost: [Double] = [], legacyCost: [Double] = []
                    let clock = ContinuousClock()
                    for _ in 0..<3 {
                        let store = RecoveryStore(directory: recovery)
                        var t = clock.now
                        let metadata = await store.metadata()
                        metadataCost.append(Self.ms(t.duration(to: clock.now)))
                        #expect(metadata.count == count)

                        let planning = RecoveryStore(directory: recovery)
                        t = clock.now
                        let plans = await planning.launchPlans(recentPaths: [])
                        planCost.append(Self.ms(t.duration(to: clock.now)))
                        #expect(plans.count == count, "\(plans.count) plans for \(count) documents")
                        let drafts = plans.filter { if case .recoverDraft = $0 { return true } else { return false } }
                        #expect(drafts.count == (unsaved ? count : 0), "unsaved=\(unsaved) gave \(drafts.count) drafts")

                        let loading = RecoveryStore(directory: recovery)
                        t = clock.now
                        _ = await loading.records()
                        recordsCost.append(Self.ms(t.duration(to: clock.now)))

                        // The decision the way it was made before: every source loaded, then every
                        // document's file read and compared with it, whatever the record said. Written
                        // out here rather than inferred, so the comparison is a measurement.
                        let legacy = RecoveryStore(directory: recovery)
                        t = clock.now
                        for record in await legacy.records() {
                            guard let path = record.filePath else { continue }
                            let onDisk = try? Data(contentsOf: URL(fileURLWithPath: path))
                            _ = onDisk == DocumentBytes(source: record.source, hasBOM: record.hasBOM).data
                        }
                        legacyCost.append(Self.ms(t.duration(to: clock.now)))
                    }

                    // What the launch actually read, counted rather than timed.
                    var stats = 0, filesRead = 0, sourcesLoaded = 0
                    let counting = LaunchStorage(
                        size: { stats += 1; return (try? URL(fileURLWithPath: $0).resourceValues(forKeys: [.fileSizeKey]))?.fileSize },
                        data: { filesRead += 1; return try? Data(contentsOf: URL(fileURLWithPath: $0)) },
                        source: { metadata in
                            sourcesLoaded += 1
                            return records.first { $0.id == metadata.id }.map { DocumentBytes(source: $0.source, hasBOM: $0.hasBOM) }
                        })
                    let store = RecoveryStore(directory: recovery)
                    _ = LaunchPlan.resolve(records: await store.metadata(), recentPaths: [], storage: counting)

                    print("BENCH_RECOVERY docs=\(count) size=\(bytes / 1_000_000)MB \(unsaved ? "unsaved" : "clean") "
                          + "| metadata \(Self.line(metadataCost)) | launchPlans \(Self.line(planCost)) | records() \(Self.line(recordsCost)) "
                          + "| decideTheOldWay \(Self.line(legacyCost)) "
                          + "| stats=\(stats) filesRead=\(filesRead) sourcesLoaded=\(sourcesLoaded)")
                }
            }
        }
    }

    // MARK: - Live resize

    /// A document whose elements all render without WebKit, so the numbers are about the resize and not
    /// about Mermaid or KaTeX starting up.
    static func imageDocument(count: Int) -> String {
        (0..<count).map { "Paragraph \($0)\n\n![Two color swatches](swatch.png)\n" }.joined(separator: "\n")
    }

    /// What a window being resized costs: renders started for widths it passes through, how long after
    /// the last step the renders begin and the pixels land, and how long the main thread is held at each
    /// step. The steps here are frame changes, which is the coalescing path — `view.inLiveResize` is
    /// false, because AppKit has no public way to begin a live resize and none of these steps is one.
    /// `UITests.testFullScreenResizeKeepsTheDocumentIntact` drives a real window resize instead, and
    /// cannot read counters.
    @Test(.enabled(if: Env.on)) func liveResizeCost() async throws {
        _ = NSApplication.shared
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let editor = EditorController(source: Self.imageDocument(count: 12))
        editor.fileURL = repository.appendingPathComponent("Fixtures/Showcase.md")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = editor; window.orderFront(nil)
        defer { window.orderOut(nil) }
        editor.view.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        editor.view.layoutSubtreeIfNeeded(); editor.viewDidAppear()
        for _ in 0..<400 where editor.renderedElementCount < 1 { try await Task.sleep(for: .milliseconds(20)) }
        let rendered = editor.renderedElementCount
        #expect(rendered > 0, "nothing rendered to keep in place")

        let phases = EditorPhases.shared
        phases.isRecording = true; phases.reset()
        defer { phases.isRecording = false; phases.reset() }
        let clock = ContinuousClock()
        let requestsBefore = editor.renderRequestCount
        var stalls: [Double] = []
        // 770 down to 610 in 8-point steps, the widths a drag passes through below the centring inset.
        for width in stride(from: 770.0, through: 610.0, by: -8.0) {
            editor.view.frame = NSRect(x: 0, y: 0, width: width, height: 700)
            let t = clock.now
            editor.view.layoutSubtreeIfNeeded()
            stalls.append(Self.ms(t.duration(to: clock.now)))
        }
        let lastStep = clock.now
        let duringDrag = editor.renderRequestCount - requestsBefore
        // Still measured, so every element keeps its place and its pixels while the width moves. Held
        // geometry is a separate thing and is zero here by definition: nothing has been adopted yet.
        let measuredDuringDrag = editor.measuredElementCount

        for _ in 0..<1000 where editor.renderRequestCount == requestsBefore + duringDrag { try await Task.sleep(for: .milliseconds(1)) }
        let started = Self.ms(lastStep.duration(to: clock.now))
        for _ in 0..<2000 where editor.heldGeometryCount > 0 { try await Task.sleep(for: .milliseconds(2)) }
        let settled = Self.ms(lastStep.duration(to: clock.now))

        let paragraph = phases.durations[.paragraph, default: []].map(Self.ms)
        let artifacts = phases.durations[.artifacts, default: []].map(Self.ms)
        let afterRound = editor.renderRequestCount - requestsBefore
        print("BENCH_RESIZE elements=\(rendered) steps=21 rendersDuringDrag=\(duringDrag) measuredDuringDrag=\(measuredDuringDrag) rendersInTheRoundAfter=\(afterRound) "
              + "| rendersStart \(String(format: "%.1f", started))ms afterLastStep | pixelsBack \(String(format: "%.1f", settled))ms "
              + "| mainThread perStep \(Self.line(stalls)) totalDuringDrag=\(String(format: "%.1f", stalls.reduce(0, +)))ms "
              + "| paragraph n=\(paragraph.count) \(Self.line(paragraph)) | artifacts n=\(artifacts.count) \(Self.line(artifacts))")
        #expect(duringDrag == 0, "renders were started for widths the drag passed through")
        #expect(measuredDuringDrag == rendered, "the drag dropped an element's metrics")
        // One round, not one per step: a round asks for as many elements as the render window holds,
        // so what is bounded is the rounds, and 21 steps must not cost 21 of them.
        #expect(afterRound > 0 && afterRound <= rendered, "\(afterRound) requests after the drag for \(rendered) elements")
    }

    // MARK: - Table raster

    /// A table's cache: what a miss costs, what a hit costs, and that 1× and 2× are two entries with
    /// pixel dimensions that follow the scale and one fixed sRGB profile between them.
    @Test(.enabled(if: Env.on)) func tableCacheAndRaster() async throws {
        _ = NSApplication.shared
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        let rows = (0..<40).map { r in (0..<5).map { c in "row \(r) cell \(c) 한글" } }
        let content = String(data: try JSONEncoder().encode(rows), encoding: .utf8)!
        let element = RenderElement(span: SourceSpan(0, 1), kind: .table, content: content, label: "Table, \(rows.count) rows")
        let clock = ContinuousClock()

        for scale in [1.0, 2.0] {
            let service = RenderService()
            let environment = RenderEnvironment(width: 700, fontSize: 16, scale: scale, dark: false)
            var t = clock.now
            let miss = try await service.render(element, environment: environment, baseURL: nil, host: host)
            let missCost = Self.ms(t.duration(to: clock.now))
            var hits: [Double] = []
            for _ in 0..<20 {
                t = clock.now
                _ = try await service.render(element, environment: environment, baseURL: nil, host: host)
                hits.append(Self.ms(t.duration(to: clock.now)))
            }
            #expect(service.renderedCount == 1, "a hit rendered again")
            #expect(miss.image.width == Int(ceil(miss.size.width * scale)))
            #expect(miss.image.colorSpace?.name == CGColorSpace.sRGB)
            print("BENCH_TABLE scale=\(Int(scale))x \(rows.count)x\(rows[0].count) points=\(Int(miss.size.width))x\(Int(miss.size.height)) "
                  + "pixels=\(miss.image.width)x\(miss.image.height) bytes=\(miss.cost) "
                  + "| miss \(String(format: "%.2f", missCost))ms | hit \(Self.line(hits)) | renders=\(service.renderedCount)")
        }

        // Both scales through one service: two entries, two renders, and neither serves the other.
        let service = RenderService()
        let one = try await service.render(element, environment: RenderEnvironment(width: 700, fontSize: 16, scale: 1, dark: false), baseURL: nil, host: host)
        let two = try await service.render(element, environment: RenderEnvironment(width: 700, fontSize: 16, scale: 2, dark: false), baseURL: nil, host: host)
        #expect(service.renderedCount == 2, "1× and 2× shared a cache entry")
        #expect(one.size == two.size, "the raster moved the table")
        #expect(two.image.width == one.image.width * 2 || two.image.width == Int(ceil(one.size.width * 2)))
        print("BENCH_TABLE both scales in one cache: renders=\(service.renderedCount) 1x=\(one.image.width)x\(one.image.height) 2x=\(two.image.width)x\(two.image.height)")
    }
}
