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
    @Test func nativeTableHasContentAndDimensions() async throws {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let element = RenderElement(span: SourceSpan(0, 10), kind: .table, content: "[[\"이름\",\"Value\"],[\"한글\",\"42\"]]")
        let artifact = try await RenderService.shared.render(element, environment: .init(width: 600, fontSize: 16, scale: 2, dark: false), baseURL: nil, host: host)
        #expect(artifact.size.width >= 600)
        #expect(artifact.size.height > 50)
        #expect(inkCoverage(artifact.image) > 0.005)
    }
}
