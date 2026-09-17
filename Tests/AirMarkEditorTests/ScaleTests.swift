import AppKit
import Testing
import AirMarkCore
@testable import AirMarkEditor
import AirMarkRender

/// Behaviour on a 1MB document: parsing stays off the main thread, only elements near the viewport
/// are rendered, in-flight renders are capped, and a keystroke's main-thread work stays small.
/// Printed timings use the selected build configuration and are observations, not budgets.
@Suite(.serialized) @MainActor struct ScaleTests {
    static func source(bytes: Int) -> String {
        let block = "## Heading\n\nA paragraph with **bold**, *emphasis*, [link](https://example.org) and 한글. Inline $x_{n}^2$ formula.\n\n- [ ] Task\n\n"
        var text = ""
        while text.utf8.count < bytes { text += block }
        return text
    }
    @Test func largeDocumentRendersNearTheViewportAndStaysResponsive() async throws {
        _ = NSApplication.shared
        let source = Self.source(bytes: 1_000_000)
        let clock = ContinuousClock()
        let started = clock.now
        let editor = EditorController(source: source)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = editor
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        editor.loadViewIfNeeded(); editor.view.frame = NSRect(x: 0, y: 0, width: 880, height: 760); editor.view.layoutSubtreeIfNeeded()
        let loaded = clock.now
        // A paragraph far from the viewport, materialized before the parse lands, is stale afterwards.
        let content = try #require(editor.textView.textLayoutManager?.textContentManager as? NSTextContentStorage)
        let text = editor.textView.textStorage!.mutableString
        let lastHeading = text.range(of: "## Heading", options: .backwards)
        let lastParagraph = text.paragraphRange(for: lastHeading)
        func materialized() -> NSFont? {
            let range = NSTextRange(location: content.location(content.documentRange.location, offsetBy: lastParagraph.location)!, end: content.location(content.documentRange.location, offsetBy: NSMaxRange(lastParagraph))!)!
            let paragraph = content.textElements(for: range).first as? NSTextParagraph
            return paragraph?.attributedString.attribute(.font, at: 3, effectiveRange: nil) as? NSFont
        }
        #expect(materialized()?.pointSize == 16)
        // `textView.string` is NSString-backed; comparing it with a native String normalizes every scalar and takes
        // about a second per comparison at this size, so wait on cheap counts instead.
        let sourceLength = source.utf16.count
        for _ in 0..<600 where !(editor.parsed.source.utf16.count == sourceLength && !editor.parsed.elements.isEmpty) { try await Task.sleep(for: .milliseconds(50)) }
        #expect(editor.parsed.source.utf16.count == sourceLength)
        let parsed = clock.now
        // Presentation for the far paragraph is deferred until the viewport reaches it.
        #expect(editor.pendingInvalidationCount > 0)
        // Every keystroke moves the pending ranges, so they must stay few rather than one per paragraph.
        #expect(editor.pendingInvalidationCount < 100, "pending ranges: \(editor.pendingInvalidationCount)")
        #expect(materialized()?.pointSize == 16)
        // Layout heights are estimates until laid out, so scroll by range rather than by frame height.
        editor.textView.scrollRangeToVisible(lastParagraph)
        editor.viewportDidChange()
        #expect(materialized()?.pointSize == 24, "heading near the end should be styled once scrolled into view")
        editor.scrollView.contentView.scroll(to: .zero)
        editor.viewportDidChange()
        let total = editor.parsed.elements.count
        #expect(total > 1000)
        try await Task.sleep(for: .seconds(3))
        let rendered = editor.renderedElementCount
        #expect(rendered > 0)
        #expect(rendered < total / 10, "only elements near the viewport should render (\(rendered) of \(total))")
        #expect(editor.pendingRenderCount <= 12)
        // Keystrokes at the end of the document while the viewport shows the start.
        var costs: [Duration] = []
        var split: [[EditorPhases.Phase: Duration]] = []
        let end = source.utf16.count
        editor.textView.setSelectedRange(NSRange(location: end, length: 0))
        EditorPhases.shared.isRecording = true
        defer { EditorPhases.shared.isRecording = false; EditorPhases.shared.reset() }
        for index in 0..<30 {
            EditorPhases.shared.reset()
            let before = clock.now
            editor.performEdit(range: NSRange(location: end + index, length: 0), replacement: "x")
            costs.append(before.duration(to: clock.now))
            split.append(Dictionary(uniqueKeysWithValues: EditorPhases.Phase.allCases.map { ($0, EditorPhases.shared.total($0)) }))
        }
        EditorPhases.shared.isRecording = false
        let sorted = costs.sorted()
        func ms(_ duration: Duration) -> Double { Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15 }
        print(String(format: "SCALE load=%.0fms parse=%.0fms elements=%d rendered=%d keystroke p50=%.2fms p95=%.2fms max=%.2fms", ms(started.duration(to: loaded)), ms(loaded.duration(to: parsed)), total, rendered, ms(sorted[Int(ceil(Double(sorted.count) * 0.5)) - 1]), ms(sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1]), ms(sorted.last!)))
        print("SCALE_PHASES \(Self.phaseSummary(split))")
        #expect(ms(sorted[sorted.count / 2]) < 50)
        #expect(editor.source.hasSuffix(String(repeating: "x", count: 30)))
        #expect(editor.textKitFallbackCount == 0)
    }

    /// Include the document's snapshot copying and dirty-state callback, which the editor-only
    /// measurement above does not exercise. Head/middle/tail edits all rebase different suffixes.
    @Test func documentKeystrokeCostsIncludeSnapshotAndDirtyState() async throws {
        try await measureDocumentKeystrokes(bytes: 1_000_000, label: "DOCUMENT_SCALE")
    }

    /// The same measurement at 10MB. Slow to set up, so it runs only when AIRMARK_SCALE_10MB=1.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AIRMARK_SCALE_10MB"] == "1"))
    func tenMegabyteDocumentKeystrokeCosts() async throws {
        try await measureDocumentKeystrokes(bytes: 10_000_000, label: "DOCUMENT_SCALE_10MB")
    }

    /// A typed Space near the start of a line, where the task shortcut is checked, and one that
    /// completes the shortcut. Both are main-thread time of one `insertText`.
    @Test func spaceKeystrokeCosts() async throws {
        try await measureSpaceKeystrokes(bytes: 1_000_000, label: "SPACE_SCALE")
    }

    /// The same measurement at 10MB. Slow to set up, so it runs only when AIRMARK_SCALE_10MB=1.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AIRMARK_SCALE_10MB"] == "1"))
    func tenMegabyteSpaceKeystrokeCosts() async throws {
        try await measureSpaceKeystrokes(bytes: 10_000_000, label: "SPACE_SCALE_10MB")
    }

    /// Return at the end of a task item in the middle of the document, which continues the list.
    /// LF and CRLF documents; main-thread time of one `insertNewline`.
    @Test func returnKeystrokeCosts() async throws {
        try await measureReturnKeystrokes(bytes: 1_000_000, label: "RETURN_SCALE")
    }

    /// The same measurement at 10MB. Slow to set up, so it runs only when AIRMARK_SCALE_10MB=1.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AIRMARK_SCALE_10MB"] == "1"))
    func tenMegabyteReturnKeystrokeCosts() async throws {
        try await measureReturnKeystrokes(bytes: 10_000_000, label: "RETURN_SCALE_10MB")
    }

    /// Time from the last key of a typing burst until the presentation shows that revision, which
    /// is what "typing stopped, formatting caught up" means to a reader. 100KB and 1MB; the burst
    /// types at 80ms, near a fast typist's cadence.
    @Test func typingSettleTimes() async throws {
        _ = try await measureTypingSettle(bytes: 100_000, label: "SETTLE_100KB")
        _ = try await measureTypingSettle(bytes: 1_000_000, label: "SETTLE_1MB")
    }

    /// The same measurement at 10MB, where a parse takes seconds. Slow to set up, so it runs only
    /// when AIRMARK_SCALE_10MB=1.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AIRMARK_SCALE_10MB"] == "1"))
    func tenMegabyteTypingSettleTime() async throws {
        _ = try await measureTypingSettle(bytes: 10_000_000, label: "SETTLE_10MB")
    }

    /// Types `keys` characters `interval` apart in the middle of the document, then waits for the
    /// parse of the final text to be applied. Polled at 2ms, so the resolution is 2ms; this is the
    /// time until the editor holds a current parse, not key-to-display latency. Reports the parses
    /// each burst started and how many of those were already stale when they finished.
    @discardableResult
    func measureTypingSettle(bytes: Int, label: String, keys: Int = 15, interval: Duration = .milliseconds(80), rounds: Int = 3) async throws
        -> (settle: [Duration], parses: [Int], stale: [Int]) {
        _ = NSApplication.shared
        let document = MarkdownDocument()
        let source = Self.source(bytes: bytes)
        document.snapshot.set(DocumentBytes(source: source, hasBOM: false))
        document.makeWindowControllers()
        defer { document.close() }
        let editor = try #require(document.editor)
        editor.view.frame = NSRect(x: 0, y: 0, width: 880, height: 760)
        for _ in 0..<2400 where editor.parsed.revision != editor.revision || editor.parsed.styles.isEmpty {
            try await Task.sleep(for: .milliseconds(25))
        }
        try #require(editor.parsed.revision == editor.revision)
        let text = editor.textView.textStorage!.mutableString
        let clock = ContinuousClock()
        var settles: [Duration] = [], parses: [Int] = [], stale: [Int] = []
        for round in 0..<rounds {
            let offset = text.paragraphRange(for: NSRange(location: text.length / 2, length: 0)).location
            let parsesBefore = editor.parseCompletedCount, staleBefore = editor.staleParseCount
            for number in 0..<keys {
                editor.performEdit(range: NSRange(location: offset + number, length: 0), replacement: "x")
                if number + 1 < keys { try await Task.sleep(for: interval) }
            }
            let last = clock.now
            for _ in 0..<15_000 where editor.parsed.revision != editor.revision { try await Task.sleep(for: .milliseconds(2)) }
            settles.append(last.duration(to: clock.now))
            parses.append(editor.parseCompletedCount - parsesBefore)
            stale.append(editor.staleParseCount - staleBefore)
            #expect(editor.parsed.revision == editor.revision, "round \(round)")
        }
        print(String(format: "%@ bytes=%d keys=%d interval=%.0fms delay=%.0fms staleness_limit=%.0fms settle p50=%.0fms max=%.0fms parses=%@ stale=%@",
                     label, source.utf8.count, keys, Self.ms(interval), Self.ms(editor.parseDelay), Self.ms(editor.parseStalenessLimit),
                     Self.percentile(settles, 0.5), Self.ms(settles.max()!), "\(parses)", "\(stale)"))
        #expect(editor.textKitFallbackCount == 0)
        return (settles, parses, stale)
    }

    /// The artifact store alone, with a long history of measured elements whose pixels are mostly
    /// released: single-character edits at the head, middle and tail, and the release that follows
    /// each render completing while scrolling. Main-thread time per call.
    @Test func artifactStoreHistoryCosts() {
        let environment = RenderEnvironment(width: 680, fontSize: 16, scale: 2, dark: false)
        let artifact = ArtifactResidencyTests.artifact(width: 64, height: 40)
        let clock = ContinuousClock()
        for count in [1_000, 10_000, 50_000] {
            let spacing = 130, length = count * spacing
            let started = clock.now
            let store = ArtifactStore()
            for index in 0..<count { store.store(artifact, at: SourceSpan(index * spacing + 40, 9), environment: environment) }
            store.releasePixels(protecting: NSRange(location: 0, length: 5_000))
            let seeded = started.duration(to: clock.now)
            #expect(store.count == count)
            #expect(store.pixelBytes <= store.pixelBudget)
            var line = String(format: "ARTIFACT_STORE measured=%d resident=%d seed=%.1fms", count, store.residentCount, Self.ms(seeded))
            for (name, location) in [("head", 0), ("middle", length / 2 + 3), ("tail", length)] {
                var costs: [Duration] = []
                for number in 0..<200 {
                    let start = clock.now
                    store.apply(PresentationEdit(range: NSRange(location: location + number, length: 0), replacement: "x"))
                    costs.append(start.duration(to: clock.now))
                }
                line += String(format: " edit_%@ p50=%.4fms p95=%.4fms max=%.4fms", name, Self.percentile(costs, 0.5), Self.percentile(costs, 0.95), Self.ms(costs.max()!))
            }
            #expect(store.count == count)
            // Scrolling from the top to the end: at each step twelve elements near the viewport render
            // and each completion releases the farthest pixels.
            var stores: [Duration] = [], releases: [Duration] = []
            for step in 0..<200 {
                let first = count * step / 200
                let window = NSRange(location: first * spacing, length: 12 * spacing)
                for index in first..<min(count, first + 12) {
                    let span = SourceSpan(index * spacing + 40 + 600, 9)
                    guard store.needsPixels(at: span, environment: environment) else { continue }
                    let start = clock.now
                    store.store(artifact, at: span, environment: environment)
                    let stored = clock.now
                    store.releasePixels(protecting: window)
                    stores.append(start.duration(to: stored)); releases.append(stored.duration(to: clock.now))
                }
            }
            #expect(store.pixelBytes <= store.pixelBudget)
            line += String(format: " store p50=%.4fms p95=%.4fms release p50=%.4fms p95=%.4fms max=%.4fms samples=%d", Self.percentile(stores, 0.5), Self.percentile(stores, 0.95), Self.percentile(releases, 0.5), Self.percentile(releases, 0.95), Self.ms(releases.max() ?? .zero), releases.count)
            print(line)
        }
    }

    /// Keystrokes on a document with 50,000 formulas where every one of them failed to render, as
    /// scrolling through a document of broken images or invalid formulas leaves behind, against the
    /// same document with no failures. Slow to set up, so it runs only when AIRMARK_SCALE_HISTORY=1.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AIRMARK_SCALE_HISTORY"] == "1"))
    func renderFailureKeystrokeCosts() async throws {
        for failures in [false, true] { try await measureRenderFailures(elements: 50_000, failures: failures) }
    }

    func measureRenderFailures(elements count: Int, failures: Bool) async throws {
        _ = NSApplication.shared
        let block = "## Heading\n\nA paragraph with **bold**, *emphasis*, [link](https://example.org) and 한글. Inline $x_{n}^2$ formula.\n\n- [ ] Task\n\n"
        let source = String(repeating: block, count: count)
        let label = failures ? "FAILURES_SCALE failures=all" : "FAILURES_SCALE failures=none"
        let document = MarkdownDocument()
        document.snapshot.set(DocumentBytes(source: source, hasBOM: false))
        document.makeWindowControllers()
        let window = try #require(document.windowControllers.first?.window)
        window.orderFront(nil)
        defer { document.close(); EditorPhases.shared.isRecording = false; EditorPhases.shared.reset() }
        let editor = try #require(document.editor)
        editor.view.frame = NSRect(x: 0, y: 0, width: 880, height: 760)
        let phases = EditorPhases.shared
        func waitForParse() async throws {
            for _ in 0..<2400 where editor.parsed.revision != editor.revision || editor.parsed.styles.isEmpty {
                try await Task.sleep(for: .milliseconds(25))
            }
            #expect(editor.parsed.revision == editor.revision)
        }
        try await waitForParse()
        #expect(editor.parsed.elements.count == count)
        if failures {
            editor.seedRenderFailures()
            #expect(editor.renderErrorCount == count)
        }
        print("\(label) elements=\(count) bytes=\(source.utf8.count) errors=\(editor.renderErrorCount)")
        let text = editor.textView.textStorage!.mutableString
        let clock = ContinuousClock()
        for (name, target) in [("head", 0), ("middle", source.utf16.count / 2), ("tail", source.utf16.count)] {
            phases.reset(); phases.isRecording = true
            try await waitForParse()
            phases.isRecording = false
            let applyParse = Self.ms(phases.total(.applyParse))
            let offset = text.paragraphRange(for: NSRange(location: min(target, text.length), length: 0)).location
            var costs: [Duration] = []
            var split: [[EditorPhases.Phase: Duration]] = []
            for number in 0..<30 {
                phases.reset(); phases.isRecording = true
                let start = clock.now
                editor.performEdit(range: NSRange(location: offset + number, length: 0), replacement: "x")
                costs.append(start.duration(to: clock.now))
                phases.isRecording = false
                split.append(Dictionary(uniqueKeysWithValues: EditorPhases.Phase.allCases.map { ($0, phases.total($0)) }))
            }
            print(String(format: "%@ position=%@ samples=%d p50=%.3fms p95=%.3fms max=%.3fms previous_applyParse=%.2fms errors=%d", label, name, costs.count,
                         Self.percentile(costs, 0.5), Self.percentile(costs, 0.95), Self.ms(costs.max()!), applyParse, editor.renderErrorCount))
            print("\(label)_PHASES position=\(name) \(Self.phaseSummary(split))")
        }
        #expect(editor.textKitFallbackCount == 0)
    }

    /// W1's document keystrokes and scrolling on a document with 50,000 formulas, without and with a
    /// render history for every one of them (metrics kept, pixels bounded by the budget). Slow to set
    /// up, so it runs only when AIRMARK_SCALE_HISTORY=1.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AIRMARK_SCALE_HISTORY"] == "1"))
    func artifactHistoryKeystrokeAndScrollCosts() async throws {
        for history in [false, true] { try await measureArtifactHistory(elements: 50_000, history: history) }
    }

    func measureArtifactHistory(elements count: Int, history: Bool) async throws {
        _ = NSApplication.shared
        let block = "## Heading\n\nA paragraph with **bold**, *emphasis*, [link](https://example.org) and 한글. Inline $x_{n}^2$ formula.\n\n- [ ] Task\n\n"
        let source = String(repeating: block, count: count)
        let label = history ? "HISTORY_SCALE history=all" : "HISTORY_SCALE history=none"
        let document = MarkdownDocument()
        document.snapshot.set(DocumentBytes(source: source, hasBOM: false))
        document.makeWindowControllers()
        let window = try #require(document.windowControllers.first?.window)
        window.orderFront(nil)
        defer { document.close(); EditorPhases.shared.isRecording = false; EditorPhases.shared.reset() }
        let editor = try #require(document.editor)
        editor.view.frame = NSRect(x: 0, y: 0, width: 880, height: 760)
        let phases = EditorPhases.shared
        func waitForParse() async throws {
            for _ in 0..<2400 where editor.parsed.revision != editor.revision || editor.parsed.styles.isEmpty {
                try await Task.sleep(for: .milliseconds(25))
            }
            #expect(editor.parsed.revision == editor.revision)
        }
        try await waitForParse()
        #expect(editor.parsed.elements.count == count)
        let clock = ContinuousClock()
        if history {
            let start = clock.now
            editor.seedArtifactHistory(ArtifactResidencyTests.artifact(width: 64, height: 40, label: "x_{n}^2"))
            print(String(format: "%@ seed=%.1fms", label, Self.ms(start.duration(to: clock.now))))
            #expect(editor.measuredElementCount == count)
        }
        print("\(label) elements=\(count) bytes=\(source.utf8.count) measured=\(editor.measuredElementCount) resident=\(editor.renderedElementCount) pixels=\(editor.retainedPixelBytes)")
        let text = editor.textView.textStorage!.mutableString
        let manager = try #require(editor.textView.textLayoutManager)
        let content = try #require(manager.textContentManager)
        for (name, target) in [("head", 0), ("middle", source.utf16.count / 2), ("tail", source.utf16.count)] {
            phases.reset(); phases.isRecording = true
            try await waitForParse()
            phases.isRecording = false
            let applyParse = Self.ms(phases.total(.applyParse))
            let offset = text.paragraphRange(for: NSRange(location: min(target, text.length), length: 0)).location
            var costs: [Duration] = [], layouts: [Duration] = []
            var split: [[EditorPhases.Phase: Duration]] = []
            for number in 0..<30 {
                phases.reset(); phases.isRecording = true
                let start = clock.now
                editor.performEdit(range: NSRange(location: offset + number, length: 0), replacement: "x")
                costs.append(start.duration(to: clock.now))
                let paragraph = text.paragraphRange(for: NSRange(location: offset + number, length: 0))
                let layoutStart = clock.now
                if let from = content.location(content.documentRange.location, offsetBy: paragraph.location),
                   let to = content.location(from, offsetBy: paragraph.length), let range = NSTextRange(location: from, end: to) {
                    manager.ensureLayout(for: range)
                }
                layouts.append(layoutStart.duration(to: clock.now))
                phases.isRecording = false
                split.append(Dictionary(uniqueKeysWithValues: EditorPhases.Phase.allCases.map { ($0, phases.total($0)) }))
            }
            print(String(format: "%@ position=%@ samples=%d p50=%.2fms p95=%.2fms max=%.2fms layout p50=%.2fms p95=%.2fms previous_applyParse=%.2fms measured=%d", label, name, costs.count,
                         Self.percentile(costs, 0.5), Self.percentile(costs, 0.95), Self.ms(costs.max()!),
                         Self.percentile(layouts, 0.5), Self.percentile(layouts, 0.95), applyParse, editor.measuredElementCount))
            print("\(label)_PHASES position=\(name) \(Self.phaseSummary(split))")
        }
        try await waitForParse()
        // Scroll through the document. `scroll` is the synchronous viewport update; `release` is each
        // pixel release that follows, including those after renders completing while the step settles.
        var scrolls: [Duration] = [], moves: [Duration] = [], paragraphs: [Duration] = [], releases: [Duration] = []
        let length = text.length
        for step in 1...20 {
            let location = text.paragraphRange(for: NSRange(location: length * step / 21, length: 0)).location
            phases.reset(); phases.isRecording = true
            let start = clock.now
            editor.textView.scrollRangeToVisible(NSRange(location: location, length: 0))
            let moved = clock.now
            editor.viewportDidChange()
            scrolls.append(start.duration(to: clock.now))
            moves.append(start.duration(to: moved))
            paragraphs.append(phases.total(.paragraph))
            for _ in 0..<150 where editor.pendingRenderCount > 0 { try await Task.sleep(for: .milliseconds(20)) }
            phases.isRecording = false
            releases += phases.durations[.artifacts] ?? []
        }
        print(String(format: "%@ scroll steps=%d p50=%.2fms p95=%.2fms max=%.2fms (scrollRangeToVisible p50=%.2fms, paragraphs p50=%.2fms) release calls=%d p50=%.4fms p95=%.4fms max=%.4fms measured=%d resident=%d errors=%d", label, scrolls.count,
                     Self.percentile(scrolls, 0.5), Self.percentile(scrolls, 0.95), Self.ms(scrolls.max()!), Self.percentile(moves, 0.5), Self.percentile(paragraphs, 0.5),
                     releases.count, releases.isEmpty ? 0 : Self.percentile(releases, 0.5), releases.isEmpty ? 0 : Self.percentile(releases, 0.95), Self.ms(releases.max() ?? .zero),
                     editor.measuredElementCount, editor.renderedElementCount, editor.renderErrorCount))
        #expect(editor.textKitFallbackCount == 0)
    }

    static func ms(_ value: Duration) -> Double { Double(value.components.seconds) * 1000 + Double(value.components.attoseconds) / 1e15 }
    /// Nearest-rank percentile.
    static func percentile(_ values: [Duration], _ fraction: Double) -> Double {
        let sorted = values.sorted()
        return ms(sorted[max(0, Int(ceil(Double(sorted.count) * fraction)) - 1)])
    }
    /// One line per phase: p50/p95 of that phase's time summed within each keystroke.
    static func phaseSummary(_ samples: [[EditorPhases.Phase: Duration]]) -> String {
        EditorPhases.Phase.allCases.map { phase in
            let values = samples.map { $0[phase] ?? .zero }
            return String(format: "%@ p50=%.2f p95=%.2f", String(describing: phase), percentile(values, 0.5), percentile(values, 0.95))
        }.joined(separator: " | ")
    }

    func measureSpaceKeystrokes(bytes: Int, label: String) async throws {
        _ = NSApplication.shared
        let document = MarkdownDocument()
        let source = Self.source(bytes: bytes)
        document.snapshot.set(DocumentBytes(source: source, hasBOM: false))
        document.makeWindowControllers()
        defer { document.close() }
        let editor = try #require(document.editor)
        editor.view.frame = NSRect(x: 0, y: 0, width: 880, height: 760)
        for _ in 0..<2400 where editor.parsed.revision != editor.revision || editor.parsed.styles.isEmpty {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(editor.parsed.revision == editor.revision)
        let text = editor.textView.textStorage!.mutableString
        let none = NSRange(location: NSNotFound, length: 0)
        let clock = ContinuousClock()
        // A paragraph line in the middle of the document; Space is checked against the line so far.
        let line = text.range(of: "A paragraph", options: [], range: NSRange(location: text.length / 2, length: text.length / 2)).location
        var check: [Duration] = [], plain: [Duration] = [], shortcut: [Duration] = []
        var split: [[EditorPhases.Phase: Duration]] = []
        // The shortcut check alone, where it finds no shortcut, apart from the edit that follows it.
        for _ in 0..<30 {
            let start = clock.now
            #expect(!editor.convertToTask(before: line + 1))
            check.append(start.duration(to: clock.now))
        }
        let phases = EditorPhases.shared
        defer { phases.isRecording = false; phases.reset() }
        for _ in 0..<30 {
            editor.textView.setSelectedRange(NSRange(location: line + 1, length: 0))
            phases.reset(); phases.isRecording = true
            let start = clock.now
            editor.textView.insertText(" ", replacementRange: none)
            plain.append(start.duration(to: clock.now))
            phases.isRecording = false
            split.append(Dictionary(uniqueKeysWithValues: EditorPhases.Phase.allCases.map { ($0, phases.total($0)) }))
        }
        #expect(text.substring(with: NSRange(location: line, length: 33)) == "A" + String(repeating: " ", count: 31) + "p")
        for _ in 0..<30 {
            editor.performEdit(range: NSRange(location: line, length: 0), replacement: "[]\n")
            editor.textView.setSelectedRange(NSRange(location: line + 2, length: 0))
            let start = clock.now
            editor.textView.insertText(" ", replacementRange: none)
            shortcut.append(start.duration(to: clock.now))
            #expect(text.substring(with: NSRange(location: line, length: 7)) == "- [ ] \n")
        }
        print(String(format: "%@ bytes=%d check p50=%.4fms p95=%.4fms plain p50=%.3fms p95=%.3fms max=%.3fms shortcut p50=%.3fms p95=%.3fms max=%.3fms", label, source.utf8.count,
                     Self.percentile(check, 0.5), Self.percentile(check, 0.95),
                     Self.percentile(plain, 0.5), Self.percentile(plain, 0.95), Self.ms(plain.max()!),
                     Self.percentile(shortcut, 0.5), Self.percentile(shortcut, 0.95), Self.ms(shortcut.max()!)))
        print("\(label)_PHASES plain \(Self.phaseSummary(split))")
        #expect(editor.textKitFallbackCount == 0)
    }

    func measureReturnKeystrokes(bytes: Int, label: String) async throws {
        _ = NSApplication.shared
        for newline in ["\n", "\r\n"] {
            let document = MarkdownDocument()
            let base = Self.source(bytes: bytes)
            let source = newline == "\n" ? base : base.replacingOccurrences(of: "\n", with: "\r\n")
            document.snapshot.set(DocumentBytes(source: source, hasBOM: false))
            document.makeWindowControllers()
            defer { document.close() }
            let editor = try #require(document.editor)
            editor.view.frame = NSRect(x: 0, y: 0, width: 880, height: 760)
            for _ in 0..<2400 where editor.parsed.revision != editor.revision || editor.parsed.styles.isEmpty {
                try await Task.sleep(for: .milliseconds(25))
            }
            #expect(editor.parsed.revision == editor.revision)
            let text = editor.textView.textStorage!.mutableString
            let clock = ContinuousClock()
            let item = text.range(of: "- [ ] Task", options: [], range: NSRange(location: text.length / 2, length: text.length / 2))
            let end = NSMaxRange(item)
            var costs: [Duration] = []
            var split: [[EditorPhases.Phase: Duration]] = []
            let phases = EditorPhases.shared
            defer { phases.isRecording = false; phases.reset() }
            for _ in 0..<30 {
                editor.textView.setSelectedRange(NSRange(location: end, length: 0))
                phases.reset(); phases.isRecording = true
                let start = clock.now
                editor.textView.insertNewline(nil)
                costs.append(start.duration(to: clock.now))
                phases.isRecording = false
                split.append(Dictionary(uniqueKeysWithValues: EditorPhases.Phase.allCases.map { ($0, phases.total($0)) }))
            }
            let inserted = newline + "- [ ] "
            #expect(text.substring(with: NSRange(location: end, length: inserted.utf16.count)) == inserted)
            let name = newline == "\n" ? "lf" : "crlf"
            print(String(format: "%@ newline=%@ bytes=%d samples=%d p50=%.3fms p95=%.3fms max=%.3fms", label, name, source.utf8.count, costs.count,
                         Self.percentile(costs, 0.5), Self.percentile(costs, 0.95), Self.ms(costs.max()!)))
            print("\(label)_PHASES newline=\(name) \(Self.phaseSummary(split))")
            #expect(editor.textKitFallbackCount == 0)
        }
    }

    func measureDocumentKeystrokes(bytes: Int, label: String) async throws {
        _ = NSApplication.shared
        let document = MarkdownDocument()
        let source = Self.source(bytes: bytes)
        document.snapshot.set(DocumentBytes(source: source, hasBOM: true))
        document.makeWindowControllers()
        defer { document.close(); EditorPhases.shared.isRecording = false; EditorPhases.shared.reset() }
        let editor = try #require(document.editor)
        editor.view.frame = NSRect(x: 0, y: 0, width: 880, height: 760)
        let clock = ContinuousClock()
        let phases = EditorPhases.shared
        for (name, target) in [("head", 0), ("middle", source.utf16.count / 2), ("tail", source.utf16.count)] {
            for _ in 0..<2400 where editor.parsed.revision != editor.revision || editor.parsed.styles.isEmpty {
                try await Task.sleep(for: .milliseconds(25))
            }
            #expect(editor.parsed.revision == editor.revision)
            let text = editor.textView.textStorage!.mutableString
            // Start on a paragraph boundary, never in the middle of a surrogate pair.
            let offset = text.paragraphRange(for: NSRange(location: min(target, text.length), length: 0)).location
            var costs: [Duration] = [], layouts: [Duration] = []
            var split: [[EditorPhases.Phase: Duration]] = []
            let manager = try #require(editor.textView.textLayoutManager)
            let content = try #require(manager.textContentManager)
            phases.isRecording = true
            for number in 0..<30 {
                phases.reset()
                let start = clock.now
                editor.performEdit(range: NSRange(location: offset + number, length: 0), replacement: "x")
                costs.append(start.duration(to: clock.now))
                // The document callback ran and was timed; a zero here means the copy is genuinely cheap.
                #expect(phases.durations[.snapshot]?.count == 1)
                // TextKit regenerates the edited paragraph at the next layout, not inside the edit.
                // Lay it out now so the paragraph phase and layout time are part of the sample.
                let paragraph = text.paragraphRange(for: NSRange(location: offset + number, length: 0))
                let layoutStart = clock.now
                if let from = content.location(content.documentRange.location, offsetBy: paragraph.location),
                   let to = content.location(from, offsetBy: paragraph.length), let range = NSTextRange(location: from, end: to) {
                    manager.ensureLayout(for: range)
                }
                layouts.append(layoutStart.duration(to: clock.now))
                split.append(Dictionary(uniqueKeysWithValues: EditorPhases.Phase.allCases.map { ($0, phases.total($0)) }))
            }
            phases.isRecording = false
            print(String(format: "%@ position=%@ samples=%d p50=%.2fms p95=%.2fms max=%.2fms layout p50=%.2fms p95=%.2fms", label, name, costs.count,
                         Self.percentile(costs, 0.5), Self.percentile(costs, 0.95), Self.ms(costs.max()!),
                         Self.percentile(layouts, 0.5), Self.percentile(layouts, 0.95)))
            print("\(label)_PHASES position=\(name) \(Self.phaseSummary(split))")
            #expect(document.snapshot.get().data == Data([0xEF, 0xBB, 0xBF]) + Data(editor.source.utf8))
            #expect(document.isDocumentEdited)
        }
        #expect(editor.textKitFallbackCount == 0)
    }
}
