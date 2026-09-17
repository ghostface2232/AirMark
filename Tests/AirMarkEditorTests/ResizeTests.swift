import AppKit
import Testing
import AirMarkCore
@testable import AirMarkEditor
@testable import AirMarkRender

/// Dragging a window edge changes the render environment on every step. The rendered elements keep
/// their place while it moves and are rendered again, once, after it settles.
@Suite(.serialized) @MainActor struct ResizeTests {
    static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func make(_ source: String, width: CGFloat = 800) async throws -> (EditorController, NSWindow) {
        _ = NSApplication.shared
        let editor = EditorController(source: source)
        editor.fileURL = repository.appendingPathComponent("Fixtures/Showcase.md")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = editor; window.orderFront(nil)
        editor.view.frame = NSRect(x: 0, y: 0, width: width, height: 600)
        editor.view.layoutSubtreeIfNeeded(); editor.viewDidAppear()
        for _ in 0..<250 where editor.renderedElementCount == 0 { try await Task.sleep(for: .milliseconds(20)) }
        return (editor, window)
    }

    /// The attachment the editor would draw for the element at `span`, from a freshly built paragraph.
    /// Nil means the paragraph shows the element's Markdown source instead.
    static func attachment(_ editor: EditorController, at span: SourceSpan) -> NSTextAttachment? {
        guard let storage = editor.textView.textStorage,
              let content = editor.textView.textLayoutManager?.textContentManager as? NSTextContentStorage else { return nil }
        let range = storage.mutableString.paragraphRange(for: span.nsRange)
        guard let paragraph = editor.textContentStorage(content, textParagraphWith: range) else { return nil }
        let shown = paragraph.attributedString
        let offset = span.location - range.location
        guard offset >= 0, offset < shown.length else { return nil }
        return shown.attribute(.attachment, at: offset, effectiveRange: nil) as? NSTextAttachment
    }

    /// Widths below 776 points: above that the editor's centring inset keeps the text container at 720
    /// points wide and the render environment does not change at all.
    static let dragWidths: [CGFloat] = stride(from: 770.0, through: 610.0, by: -8.0).map { CGFloat($0) }

    /// Every step of a drag used to cancel the renders, drop every artifact and invalidate every
    /// element, so the elements flipped between their rendered form and their source while the window
    /// moved. They now keep their metrics and their pixels, scaled into the width available.
    @Test func draggingAWindowKeepsRenderedElementsInPlace() async throws {
        let (editor, window) = try await Self.make("Before\n\n![Two color swatches](swatch.png)\n\nAfter\n")
        defer { window.orderOut(nil) }
        try #require(editor.renderedElementCount == 1)
        let span = try #require(editor.parsed.elements.first?.span)
        let measured = try #require(Self.attachment(editor, at: span)?.bounds)
        let requests = editor.renderRequestCount
        var widths: [CGFloat] = []
        for width in Self.dragWidths {
            editor.view.frame = NSRect(x: 0, y: 0, width: width, height: 600)
            editor.view.layoutSubtreeIfNeeded()
            #expect(editor.measuredElementCount == 1, "the drag dropped the element's metrics at \(width)")
            #expect(editor.renderedElementCount == 1, "the drag dropped the element's pixels at \(width)")
            let bounds = try #require(Self.attachment(editor, at: span)?.bounds, "the element fell back to its source at \(width)")
            #expect(bounds.height > 0)
            widths.append(bounds.width)
        }
        print("RESIZE drag steps=\(Self.dragWidths.count) measured=\(measured.size) drawn widths \(widths.first.map { "\($0)" } ?? "-")…\(widths.last.map { "\($0)" } ?? "-") requests=\(editor.renderRequestCount - requests)")
        #expect(editor.renderRequestCount == requests, "renders were started for widths the drag passed through")
        // Settling adopts the last width once, keeping the measurements as temporary geometry, and
        // renders the element again for it.
        for _ in 0..<250 where editor.renderRequestCount == requests { try await Task.sleep(for: .milliseconds(20)) }
        #expect(editor.renderRequestCount == requests + 1, "one round of renders after the drag, not one per step")
        #expect(editor.measuredElementCount == 1)
        for _ in 0..<250 where editor.heldGeometryCount > 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(editor.heldGeometryCount == 0, "the element was never measured again for the settled width")
        #expect(editor.renderedElementCount == 1)
        #expect(Self.attachment(editor, at: span) != nil)
    }

    /// A changed font size or appearance paints something else, so there the measurements go, as before.
    @Test func changingTheFontSizeRemeasuresFromScratch() async throws {
        let (editor, window) = try await Self.make("Before\n\n![Two color swatches](swatch.png)\n\nAfter\n")
        defer { window.orderOut(nil) }
        try #require(editor.measuredElementCount == 1)
        editor.fontSize = 21
        #expect(editor.measuredElementCount == 0, "metrics from another font size were kept")
        #expect(editor.heldGeometryCount == 0)
        for _ in 0..<250 where editor.renderedElementCount == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(editor.renderedElementCount == 1)
    }
}
