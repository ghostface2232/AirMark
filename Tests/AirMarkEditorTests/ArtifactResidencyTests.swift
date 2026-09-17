import AppKit
import Testing
import AirMarkCore
@testable import AirMarkEditor
@testable import AirMarkRender

/// Rendered pixels and the layout they occupy are separate: pixels far from the viewport may be
/// released, while the element keeps its size, position and click target, and draws again once
/// its pixels return.
@Suite(.serialized) @MainActor struct ArtifactResidencyTests {
    static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Draws the layout fragment holding `location` into a bitmap, as the screen would, and returns
    /// its frame and how many sampled pixels are strongly colored (the swatch fixture is saturated).
    static func draw(_ editor: EditorController, at location: Int) -> (frame: CGRect, colored: Int)? {
        guard let manager = editor.textView.textLayoutManager, let content = manager.textContentManager,
              let position = content.location(content.documentRange.location, offsetBy: location) else { return nil }
        manager.ensureLayout(for: content.documentRange)
        guard let fragment = manager.textLayoutFragment(for: position) else { return nil }
        let frame = fragment.layoutFragmentFrame
        let width = Int(ceil(frame.width)), height = Int(ceil(frame.height))
        guard width > 0, height > 0, let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        fragment.draw(at: .zero, in: context)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var colored = 0
        for y in stride(from: 0, to: height, by: 2) {
            for x in stride(from: 0, to: width, by: 2) {
                let i = (y * width + x) * 4
                let (r, g, b, a) = (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]), Int(pixels[i + 3]))
                if a > 128 && max(r, g, b) - min(r, g, b) > 60 { colored += 1 }
            }
        }
        return (frame, colored)
    }

    static func make(_ source: String, fileURL: URL = repository.appendingPathComponent("Fixtures/Showcase.md")) async throws -> (EditorController, NSWindow) {
        _ = NSApplication.shared
        let editor = EditorController(source: source)
        editor.fileURL = fileURL
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = editor; window.orderFront(nil)
        editor.view.frame = NSRect(x: 0, y: 0, width: 800, height: 600); editor.view.layoutSubtreeIfNeeded(); editor.viewDidAppear()
        for _ in 0..<250 where editor.renderedElementCount == 0 { try await Task.sleep(for: .milliseconds(20)) }
        return (editor, window)
    }

    @Test func renderedImageIsDrawnByItsLayoutFragment() async throws {
        let (editor, window) = try await Self.make("Before\n\n![Two color swatches](swatch.png)\n\nAfter\n")
        defer { window.orderOut(nil) }
        try #require(editor.renderedElementCount == 1)
        let location = try #require(editor.parsed.elements.first?.span.location)
        let drawn = try #require(Self.draw(editor, at: location))
        print("RESIDENCY drawn frame=\(drawn.frame) colored=\(drawn.colored)")
        #expect(drawn.colored > 20)
    }

    /// Releasing pixels leaves the element's space, position and click target; drawing shows nothing
    /// until one render request brings the pixels back.
    @Test func releasedPixelsKeepLayoutAndReturnOnRequest() async throws {
        let (editor, window) = try await Self.make("Before\n\n![Two color swatches](swatch.png)\n\nAfter\n")
        defer { window.orderOut(nil) }
        try #require(editor.renderedElementCount == 1)
        let location = try #require(editor.parsed.elements.first?.span.location)
        let before = try #require(Self.draw(editor, at: location))
        #expect(before.colored > 20)
        let requests = editor.renderRequestCount
        editor.releaseAllPixels()
        #expect(editor.renderedElementCount == 0)
        #expect(editor.measuredElementCount == 1)
        #expect(editor.retainedPixelBytes == 0)
        let released = try #require(Self.draw(editor, at: location))
        #expect(released.frame == before.frame, "releasing pixels moved the element")
        #expect(released.colored == 0, "released pixels were still drawn")
        editor.requestRenders()
        for _ in 0..<250 where editor.renderedElementCount == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(editor.renderRequestCount == requests + 1)
        let restored = try #require(Self.draw(editor, at: location))
        #expect(restored.frame == before.frame)
        #expect(restored.colored > 20)
        // The element is still a single click target while its pixels are away.
        editor.releaseAllPixels()
        #expect(editor.enterElement(at: location + 1))
        #expect(editor.textView.selectedRange().location == location)
    }

    static func artifact(width: Int = 10, height: Int = 10, label: String = "") -> RenderArtifact {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return RenderArtifact(image: context.makeImage()!, size: CGSize(width: width, height: height), baseline: CGFloat(height), label: label)
    }

    /// Metrics measured for one environment are not used for another.
    @Test func metricsBelongToTheirEnvironment() {
        let store = ArtifactStore()
        let light = RenderEnvironment(width: 600, fontSize: 16, scale: 2, dark: false)
        var narrow = light; narrow.width = 300
        let span = SourceSpan(4, 10)
        store.store(Self.artifact(label: "a"), at: span, environment: light)
        #expect(store.layout(at: span, environment: light)?.metrics.label == "a")
        #expect(store.layout(at: span, environment: narrow) == nil)
        #expect(store.needsPixels(at: span, environment: narrow))
        #expect(!store.needsPixels(at: span, environment: light))
    }

    /// Over budget, pixels outside the protected range go farthest first until the budget holds.
    /// Metrics and drawing identities survive, and follow edits.
    @Test func releaseOrderAndIdentityAcrossEdits() {
        let environment = RenderEnvironment(width: 600, fontSize: 16, scale: 2, dark: false)
        let one = Self.artifact(width: 100, height: 100).cost
        let store = ArtifactStore(pixelBudget: one * 2)
        let spans = [SourceSpan(0, 5), SourceSpan(1_000, 5), SourceSpan(2_000, 5), SourceSpan(3_000, 5), SourceSpan(50_000, 5)]
        for span in spans { store.store(Self.artifact(width: 100, height: 100), at: span, environment: environment) }
        let id = store.layout(at: spans[3], environment: environment)!.id
        store.releasePixels(protecting: NSRange(location: 0, length: 10))
        #expect(store.hasPixels(at: spans[0]), "protected, even though the budget is exceeded by others")
        #expect(!store.hasPixels(at: spans[4]) && !store.hasPixels(at: spans[3]) && !store.hasPixels(at: spans[2]), "farthest first")
        #expect(store.hasPixels(at: spans[1]))
        #expect(store.pixelBytes == one * 2)
        #expect(store.count == spans.count)
        // An edit before the elements moves them; the drawing identity still finds the entry.
        store.store(Self.artifact(width: 100, height: 100), at: spans[3], environment: environment)
        store.apply(PresentationEdit(range: NSRange(location: 500, length: 0), replacement: "xyz"))
        #expect(store.layout(at: SourceSpan(3_003, 5), environment: environment)?.id == id)
        #expect(store.drawable(for: id) != nil)
        // An edit inside an element removes it and its pixels.
        store.apply(PresentationEdit(range: NSRange(location: 3_004, length: 1), replacement: ""))
        #expect(store.drawable(for: id) == nil)
        #expect(store.count == spans.count - 1)
        #expect(store.pixelBytes == one * 2)
    }

    /// If an element whose pixels were released fails to render again, it shows its source with the
    /// error, as an element that never rendered does, instead of an empty space of the old size.
    @Test func failedRerenderAfterReleaseShowsSourceAndError() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AirMarkRerender-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appendingPathComponent("swatch.png")
        try FileManager.default.copyItem(at: Self.repository.appendingPathComponent("Fixtures/swatch.png"), to: image)
        let (editor, window) = try await Self.make("Before\n\n![Two color swatches](swatch.png)\n\nAfter\n", fileURL: directory.appendingPathComponent("Note.md"))
        defer { window.orderOut(nil) }
        try #require(editor.renderedElementCount == 1)
        let element = try #require(editor.parsed.elements.first)
        editor.releaseAllPixels()
        try FileManager.default.removeItem(at: image)
        editor.requestRenders()
        for _ in 0..<250 where editor.renderErrorCount == 0 { try await Task.sleep(for: .milliseconds(20)) }
        try #require(editor.renderErrorCount == 1)
        let storage = try #require(editor.textView.textLayoutManager?.textContentManager as? NSTextContentStorage)
        let range = editor.textView.textStorage!.mutableString.paragraphRange(for: element.span.nsRange)
        // Read the paragraph TextKit holds, not a freshly built one: the change must have been applied.
        #expect(editor.pendingInvalidationCount == 0)
        let start = try #require(storage.location(storage.documentRange.location, offsetBy: range.location))
        let end = try #require(storage.location(start, offsetBy: range.length))
        let paragraphRange = try #require(NSTextRange(location: start, end: end))
        let held = try #require(storage.textElements(for: paragraphRange).first as? NSTextParagraph)
        let shown = held.attributedString
        #expect(shown.attribute(.attachment, at: element.span.location - range.location, effectiveRange: nil) == nil, "an empty space stands in for the element")
        #expect(shown.attribute(.toolTip, at: 0, effectiveRange: nil) != nil, "the failure is not shown")
        #expect(editor.measuredElementCount == 0)
    }
}
