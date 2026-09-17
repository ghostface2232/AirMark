import AppKit
import ImageIO
import UniformTypeIdentifiers
import Testing
import AirMarkCore
@testable import AirMarkEditor

/// Memory held for rendered elements while scrolling a long document with many distinct images.
/// Slow and memory-hungry, so it runs only when AIRMARK_MEMORY=1. Numbers are app-process
/// phys_footprint; images do not involve WebKit, whose content processes are not counted.
@Suite(.serialized) @MainActor struct MemoryTests {
    static func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }
    static func megabytes(_ bytes: Int) -> String { String(format: "%.1fMB", Double(bytes) / 1_048_576) }

    /// Writes `count` 1600×1200 PNGs with different colors and returns the document text referencing them.
    static func makeImages(_ count: Int, in directory: URL) throws -> String {
        var text = "# Images\n\n"
        for index in 0..<count {
            let context = CGContext(data: nil, width: 1600, height: 1200, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(red: Double(index % 7) / 7, green: Double(index % 11) / 11, blue: Double(index % 13) / 13, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 1600, height: 1200))
            context.setFillColor(CGColor(gray: Double(index % 5) / 5, alpha: 1))
            context.fill(CGRect(x: (index * 37) % 1200, y: (index * 23) % 800, width: 400, height: 400))
            let name = String(format: "image-%04d.png", index)
            let destination = CGImageDestinationCreateWithURL(directory.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, context.makeImage()!, nil)
            #expect(CGImageDestinationFinalize(destination))
            text += "![Image \(index)](\(name))\n\nParagraph \(index) between images.\n\n"
        }
        return text
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AIRMARK_MEMORY"] == "1"))
    func scrollingManyImagesKeepsMemoryBounded() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AirMarkMemory-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let count = 150
        let source = try Self.makeImages(count, in: directory)
        let editor = EditorController(source: source)
        editor.fileURL = directory.appendingPathComponent("Images.md")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = editor; window.orderFront(nil)
        defer { window.orderOut(nil) }
        editor.view.frame = NSRect(x: 0, y: 0, width: 880, height: 760); editor.view.layoutSubtreeIfNeeded(); editor.viewDidAppear()
        for _ in 0..<500 where editor.parsed.elements.count < count { try await Task.sleep(for: .milliseconds(20)) }
        try #require(editor.parsed.elements.count == count)
        func settle() async throws {
            for _ in 0..<200 where editor.pendingRenderCount > 0 { try await Task.sleep(for: .milliseconds(10)) }
        }
        try await settle()
        let start = Self.footprint()
        var peak = start
        let elements = editor.parsed.elements
        var drawn = Set<ObjectIdentifier>()
        let sink = CGContext(data: nil, width: 16, height: 12, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        func visit(_ indices: some Sequence<Int>) async throws {
            for index in indices {
                editor.textView.scrollRangeToVisible(elements[index].span.nsRange)
                editor.viewportDidChange()
                try await settle()
                // A test window is never composited, so nothing is drawn. ImageIO thumbnails decode
                // lazily and become resident the first time they are drawn, which on screen happens
                // as each element scrolls into view. Stand in for that by drawing each held image once.
                for image in editor.heldImages where drawn.insert(ObjectIdentifier(image)).inserted {
                    sink.draw(image, in: CGRect(x: 0, y: 0, width: 16, height: 12))
                }
                peak = max(peak, Self.footprint())
            }
        }
        let requestsBefore = editor.renderRequestCount
        try await visit(stride(from: 0, to: count, by: 3))
        let down = Self.footprint()
        let heldDown = editor.renderedElementCount, pixelsDown = editor.retainedPixelBytes
        let requestsDown = editor.renderRequestCount - requestsBefore
        try await visit(stride(from: count - 1, through: 0, by: -3))
        let up = Self.footprint()
        print("MEMORY measured=\(editor.measuredElementCount) images=\(count) start=\(Self.megabytes(start)) afterDown=\(Self.megabytes(down)) afterUp=\(Self.megabytes(up)) peak=\(Self.megabytes(peak)) growth=\(Self.megabytes(peak - start)) held=\(heldDown)/\(editor.renderedElementCount) pixels=\(Self.megabytes(pixelsDown))/\(Self.megabytes(editor.retainedPixelBytes)) requestsDown=\(requestsDown) requestsUp=\(editor.renderRequestCount - requestsBefore - requestsDown) errors=\(editor.renderErrorCount)")
        #expect(editor.renderErrorCount == 0)
        // Every element keeps its metrics; pixels are held near the viewport and within the budget.
        #expect(editor.measuredElementCount == count)
        // Near the viewport, plus renders started ahead while under three quarters of the budget and
        // the at most 12 in flight when that happened.
        let oneImage = pixelsDown / max(1, heldDown)
        let nearViewport = oneImage * (12 + 12)
        #expect(editor.retainedPixelBytes <= 64 * 1_048_576 + nearViewport, "held \(Self.megabytes(editor.retainedPixelBytes))")
        #expect(peak - start < 64 * 1_048_576 + nearViewport + 128 * 1_048_576, "growth \(Self.megabytes(peak - start))")
        #expect(editor.renderRequestCount - requestsBefore - requestsDown <= count, "scrolling back requests each element at most once")
    }
}
