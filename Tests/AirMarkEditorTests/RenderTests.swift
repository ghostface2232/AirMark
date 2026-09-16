import AppKit
import Testing
import AirMarkCore
@testable import AirMarkRender

/// Fraction of pixels that are neither fully transparent nor the page background.
func inkCoverage(_ image: CGImage) -> Double {
    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    var ink = 0
    for index in stride(from: 0, to: pixels.count, by: 4) {
        let alpha = pixels[index + 3]
        if alpha > 16 && (pixels[index] < 200 || pixels[index + 1] < 200 || pixels[index + 2] < 200) { ink += 1 }
    }
    return Double(ink) / Double(width * height)
}

@Suite(.serialized) @MainActor struct RenderTests {
    @Test func offlineMathAndDiagramSnapshots() async throws {
        _ = NSApplication.shared
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; window.orderFront(nil)
        defer { window.orderOut(nil) }
        let environment = RenderEnvironment(width: 680, fontSize: 16, scale: 2, dark: false)
        // Pure glyphs: nothing but loaded fonts can put ink into this snapshot, and it is the first render.
        let math = RenderElement(span: SourceSpan(0, 5), kind: .math, content: "E = mc^2", inline: true)
        let artifact = try await RenderService.shared.render(math, environment: environment, baseURL: nil, host: host)
        #expect(artifact.size.width > 20)
        #expect(artifact.size.height > 10)
        #expect(artifact.baseline > 0 && artifact.baseline <= artifact.size.height)
        #expect(artifact.image.width > 20)
        #expect(inkCoverage(artifact.image) > 0.03, "inline math snapshot has no visible ink")
        let display = RenderElement(span: SourceSpan(0, 5), kind: .math, content: "x = \\frac{-b \\pm \\sqrt{b^2-4ac}}{2a}", inline: false)
        let displayArtifact = try await RenderService.shared.render(display, environment: environment, baseURL: nil, host: host)
        #expect(inkCoverage(displayArtifact.image) > 0.01, "display math snapshot has no visible ink")
        let key = RenderService.shared.key(math, environment: environment, baseURL: nil)
        #expect(RenderService.shared.cached(key) != nil)
        let diagram = RenderElement(span: SourceSpan(6, 20), kind: .mermaid, content: "graph LR\n A[Start] --> B[End]")
        let result = try await RenderService.shared.render(diagram, environment: environment, baseURL: nil, host: host)
        #expect(result.size.width > 50)
        #expect(result.size.height > 20)
        #expect(inkCoverage(result.image) > 0.005, "diagram snapshot has no visible ink")
    }
    /// The WebView keeps the frame of its last snapshot; a display formula rendered after a
    /// small inline one must still measure its natural width.
    @Test func displayMathAfterInlineKeepsNaturalWidth() async throws {
        _ = NSApplication.shared
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; window.orderFront(nil)
        defer { window.orderOut(nil) }
        let environment = RenderEnvironment(width: 720, fontSize: 16, scale: 2, dark: false)
        let inline = RenderElement(span: SourceSpan(0, 1), kind: .math, content: "a_1", inline: true)
        let display = RenderElement(span: SourceSpan(2, 1), kind: .math, content: "y = \\frac{-b \\pm \\sqrt{b^2 - 4ac}}{2a}", inline: false)
        let small = try await RenderService.shared.render(inline, environment: environment, baseURL: nil, host: host)
        #expect(small.size.width < 60)
        let artifact = try await RenderService.shared.render(display, environment: environment, baseURL: nil, host: host)
        #expect(artifact.size.width > 100 && artifact.size.width < 400)
        #expect(artifact.size.height > 40 && artifact.size.height < 120)
        #expect(inkCoverage(artifact.image) > 0.03)
    }

    @Test func localImageIsDownsampledToTheColumn() async throws {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let document = repository.appendingPathComponent("Fixtures/Showcase.md")
        let element = RenderElement(span: SourceSpan(0, 10), kind: .image, content: "swatch.png", label: "Two color swatches")
        let artifact = try await RenderService.shared.render(element, environment: .init(width: 600, fontSize: 16, scale: 2, dark: false), baseURL: document, host: host)
        #expect(artifact.size == CGSize(width: 32, height: 20))
        #expect(artifact.label == "Two color swatches")
        #expect(inkCoverage(artifact.image) > 0.5)
        // Without a document location a relative path cannot be resolved; remote images are never fetched.
        await #expect(throws: (any Error).self) { try await RenderService.shared.render(element, environment: .init(width: 600, fontSize: 16, scale: 2, dark: false), baseURL: nil, host: host) }
        let remote = RenderElement(span: SourceSpan(0, 10), kind: .image, content: "https://example.org/a.png")
        await #expect(throws: (any Error).self) { try await RenderService.shared.render(remote, environment: .init(width: 600, fontSize: 16, scale: 2, dark: false), baseURL: document, host: host) }
    }

    /// Snapshots are painted on the editor's background so they blend in dark appearance.
    @Test func snapshotsUseTheRequestedBackground() async throws {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; window.orderFront(nil)
        defer { window.orderOut(nil) }
        let dark = RenderEnvironment(width: 600, fontSize: 16, scale: 2, dark: true, background: "#1e1e1e")
        let artifact = try await RenderService.shared.render(RenderElement(span: SourceSpan(0, 1), kind: .math, content: "a+b", inline: true), environment: dark, baseURL: nil, host: host)
        let image = artifact.image
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        // The corner pixel is background: dark, not white.
        #expect(pixels[0] < 60 && pixels[1] < 60 && pixels[2] < 60, "corner pixel \(pixels[0]),\(pixels[1]),\(pixels[2])")
        var bright = 0
        for index in stride(from: 0, to: pixels.count, by: 4) where pixels[index] > 150 && pixels[index + 1] > 150 { bright += 1 }
        #expect(bright > 20, "light glyph pixels expected on a dark background")
    }

    @Test func nativeTableHasContentAndDimensions() async throws {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let element = RenderElement(span: SourceSpan(0, 10), kind: .table, content: "[[\"이름\",\"Value\"],[\"한글\",\"42\"]]")
        let artifact = try await RenderService.shared.render(element, environment: .init(width: 600, fontSize: 16, scale: 2, dark: false), baseURL: nil, host: host)
        #expect(artifact.size.width >= 600)
        #expect(artifact.size.height > 50)
        #expect(inkCoverage(artifact.image) > 0.005)
    }
}
