import AppKit
import Testing
import AirMarkCore
@testable import AirMarkEditor

@Suite(.serialized) @MainActor struct LayoutTests {
    @Test func layoutFragmentsDoNotOverlap() async throws {
        _ = NSApplication.shared
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/Showcase.md")
        let source = try String(contentsOf: url, encoding: .utf8)
        let editor = EditorController(source: source)
        editor.fileURL = url  // the fixture references a relative image
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = editor
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        editor.loadViewIfNeeded()
        editor.view.frame = NSRect(x: 0, y: 0, width: 880, height: 760)
        window.layoutIfNeeded()
        editor.view.layoutSubtreeIfNeeded()
        for _ in 0..<300 {
            if editor.parsed.source == source, editor.renderedElementCount + editor.renderErrorCount >= editor.parsed.elements.count { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(editor.renderErrorCount == 0)
        #expect(editor.renderedElementCount == editor.parsed.elements.count)
        let manager = try #require(editor.textView.textLayoutManager)
        let content = manager.textContentManager!
        manager.ensureLayout(for: content.documentRange)
        var previousMaxY = -CGFloat.infinity
        var overlaps: [String] = []
        manager.enumerateTextLayoutFragments(from: content.documentRange.location, options: [.ensuresLayout]) { fragment in
            let range = fragment.rangeInElement
            let start = content.offset(from: content.documentRange.location, to: range.location)
            let end = content.offset(from: content.documentRange.location, to: range.endLocation)
            let text = (source as NSString).substring(with: NSRange(location: start, length: end - start)).replacingOccurrences(of: "\n", with: "⏎")
            let frame = fragment.layoutFragmentFrame
            let lines = fragment.textLineFragments.map { String(format: "%.1f", $0.typographicBounds.height) }.joined(separator: ",")
            if let line = fragment.textLineFragments.first, line.attributedString.string.unicodeScalars.contains("\u{FFFC}") {
                var hasAttachment = false
                line.attributedString.enumerateAttribute(.attachment, in: NSRange(location: 0, length: line.attributedString.length)) { value, r, _ in if value != nil { hasAttachment = true; print("  attachment run \(r) \(type(of: value!)) bounds \((value as! NSTextAttachment).bounds)") } }
                if !hasAttachment { print("  U+FFFC present but no .attachment attribute") }
            }
            print(String(format: "y=%7.1f h=%6.1f lines=[%@] %@", frame.minY, frame.height, lines, String(text.prefix(40))))
            if frame.minY < previousMaxY - 0.5 { overlaps.append(text) }
            previousMaxY = max(previousMaxY, frame.maxY)
            return true
        }
        #expect(overlaps.isEmpty, "Overlapping fragments: \(overlaps)")
    }
}
