import AppKit
import Testing
import AirMarkCore
@testable import AirMarkEditor

/// Behaviour on a 1MB document: parsing stays off the main thread, only elements near the viewport
/// are rendered, in-flight renders are capped, and a keystroke's main-thread work stays small.
/// Printed timings are from a Debug build and are observations, not budgets.
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
        let end = source.utf16.count
        editor.textView.setSelectedRange(NSRange(location: end, length: 0))
        for index in 0..<30 {
            let before = clock.now
            editor.performEdit(range: NSRange(location: end + index, length: 0), replacement: "x")
            costs.append(before.duration(to: clock.now))
        }
        let sorted = costs.sorted()
        func ms(_ duration: Duration) -> Double { Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15 }
        print(String(format: "SCALE load=%.0fms parse=%.0fms elements=%d rendered=%d keystroke p50=%.2fms p95=%.2fms max=%.2fms", ms(started.duration(to: loaded)), ms(loaded.duration(to: parsed)), total, rendered, ms(sorted[sorted.count / 2]), ms(sorted[Int(Double(sorted.count) * 0.95) - 1]), ms(sorted.last!)))
        #expect(ms(sorted[sorted.count / 2]) < 50)
        #expect(editor.source.hasSuffix(String(repeating: "x", count: 30)))
        #expect(editor.textKitFallbackCount == 0)
    }
}
