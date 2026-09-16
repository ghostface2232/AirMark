import AppKit
import Testing
import AirMarkCore
@testable import AirMarkEditor

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
