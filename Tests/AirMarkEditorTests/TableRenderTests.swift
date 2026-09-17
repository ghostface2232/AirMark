import AppKit
import Testing
import AirMarkCore
@testable import AirMarkRender

/// Native tables: cost on the main thread for tables far larger than a note needs, including ones the
/// display limit rejects.
@Suite(.serialized) @MainActor struct TableRenderTests {
    static func table(rows: Int, columns: Int, cell: (Int, Int) -> String) -> RenderElement {
        let cells = (0..<rows).map { row in (0..<columns).map { cell(row, $0) } }
        let json = String(decoding: try! JSONEncoder().encode(cells), as: UTF8.self)
        return RenderElement(span: SourceSpan(0, 1), kind: .table, content: json, label: "Table, \(rows) rows")
    }

    /// Pathological tables, from accepted-but-large to far over the display limit.
    static let pathological: [(name: String, element: RenderElement)] = [
        ("accepted-100x6", table(rows: 100, columns: 6) { "r\($0)c\($1)" }),
        ("accepted-2x300", table(rows: 2, columns: 300) { "cell \($0)-\($1)" }),
        ("accepted-long-cells-50x3", table(rows: 50, columns: 3) { row, column in String(repeating: "word\(row)\(column) ", count: 150) }),
        ("accepted-hangul-emoji-60x4", table(rows: 60, columns: 4) { row, column in "한글 \(row) 😀 \(column)" }),
        ("rejected-tall-20000x4", table(rows: 20_000, columns: 4) { "r\($0)c\($1)" }),
        ("rejected-wide-10x5000", table(rows: 10, columns: 5_000) { "r\($0)c\($1)" }),
        ("rejected-long-cells-2000x3", table(rows: 2_000, columns: 3) { row, column in String(repeating: "word\(row)\(column) ", count: 150) }),
        // Tables that display: under both the display limit and the memory limit.
        ("renders-40x6", table(rows: 40, columns: 6) { "r\($0)c\($1)" }),
        ("renders-2x100", table(rows: 2, columns: 100) { "cell \($0)-\($1)" }),
        ("renders-long-cells-20x3", table(rows: 20, columns: 3) { row, column in String(repeating: "word\(row)\(column) ", count: 150) }),
    ]

    /// Renders `element` while a main-actor heartbeat records how long the main thread went without
    /// running it. Returns the outcome, total time and the longest gap.
    static func measure(_ element: RenderElement, environment: RenderEnvironment, reference: Bool = false) async -> (Result<RenderArtifact, any Error>, total: Double, stall: Double) {
        let clock = ContinuousClock()
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let service = RenderService()
        var longest = Duration.zero
        var running = true
        let heartbeat = Task { @MainActor in
            var last = clock.now
            while running {
                try? await Task.sleep(for: .milliseconds(1))
                let now = clock.now
                longest = max(longest, last.duration(to: now))
                last = now
            }
        }
        await Task.yield()
        let start = clock.now
        let outcome: Result<RenderArtifact, any Error>
        do {
            if reference {
                // The previous path: a main-actor task inside `RenderService` ran the AppKit drawing.
                outcome = .success(try await Task { @MainActor in try ReferenceTableRenderer.render(element, environment: environment) }.value)
            } else {
                outcome = .success(try await service.render(element, environment: environment, baseURL: nil, host: host))
            }
        } catch { outcome = .failure(error) }
        let total = start.duration(to: clock.now)
        try? await Task.sleep(for: .milliseconds(5))
        running = false
        await heartbeat.value
        func ms(_ duration: Duration) -> Double { Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15 }
        return (outcome, ms(total), ms(longest))
    }

    /// Draws `image` into 8-bit sRGB so two bitmaps in the same format can be compared by channel.
    static func pixels(_ image: CGImage) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return data
    }

    static let equivalenceCorpus: [(name: String, element: RenderElement)] = [
        ("two-by-two", table(rows: 2, columns: 2) { "r\($0)c\($1)" }),
        ("header-wider", table(rows: 3, columns: 3) { row, column in row == 0 ? "Header \(column) name" : "\(row * column)" }),
        ("ragged", RenderElement(span: SourceSpan(0, 1), kind: .table, content: "[[\"A\",\"B\",\"C\"],[\"1\"],[\"x\",\"y\"],[]]", label: "Table, 4 rows")),
        ("empty-cells", table(rows: 4, columns: 3) { row, column in (row + column) % 2 == 0 ? "" : "v" }),
        ("hangul-emoji", table(rows: 5, columns: 3) { row, column in ["이름", "한글 값 😀", "e\u{301}", "👩‍💻 코드"][(row + column) % 4] }),
        ("trailing-spaces", table(rows: 3, columns: 2) { row, column in "cell \(row)   " }),
        ("long-wrapping", table(rows: 4, columns: 3) { row, column in String(repeating: "word\(column) ", count: 12 + row * 20) }),
        ("wide-sum", table(rows: 3, columns: 12) { row, column in "column \(column) value" }),
        ("rtl", table(rows: 3, columns: 2) { row, column in column == 0 ? "שלום עולם" : "مرحبا \(row)" }),
        ("digits-and-symbols", table(rows: 6, columns: 4) { row, column in ["$1,234.56", "−42", "a | b", "<b>x</b>", "`code`", "**bold**"][(row * 3 + column) % 6] }),
        ("near-memory-limit", table(rows: 40, columns: 6) { "r\($0)c\($1)" }),
        ("over-memory-limit", table(rows: 60, columns: 6) { "r\($0)c\($1)" }),
        ("over-display-limit-by-cells", table(rows: 30, columns: 8) { row, column in String(repeating: "wide ", count: 40) }),
        ("over-display-limit-by-rows", table(rows: 400, columns: 2) { "r\($0)c\($1)" }),
        ("single-column", table(rows: 5, columns: 1) { row, _ in "only \(row)" }),
    ]

    /// The table renderer in the raster the AppKit reference used: the main screen's scale and color
    /// space, which is what `NSImage` rasterized into. Which raster the app asks for is a separate
    /// question, pinned by `tableRasterFollowsTheRequestingWindow`.
    static func coreTextInTheReferenceRaster(_ element: RenderElement, environment: RenderEnvironment) throws -> RenderArtifact {
        let screen = NSScreen.main
        let raster = TableRenderer.Raster(scale: screen.map { Double($0.backingScaleFactor) } ?? environment.scale,
                                          colorSpace: screen?.colorSpace?.cgColorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                          alignment: NSParagraphStyle.defaultWritingDirection(forLanguage: nil) == .rightToLeft ? .right : .left)
        return try TableRenderer.render(element.content, label: element.label, environment: environment, raster: raster,
                                        memoryLimit: ReferenceTableRenderer.memoryLimit)
    }

    /// The CoreText renderer against the AppKit reference: same outcome and failure message, same size,
    /// pixel dimensions, bytes and baseline, and pixels that differ only by glyph rasterization.
    @Test func matchesTheAppKitReference() async throws {
        _ = NSApplication.shared
        for environment in [RenderEnvironment(width: 680, fontSize: 16, scale: 2, dark: false), RenderEnvironment(width: 600.25, fontSize: 13, scale: 1, dark: true), RenderEnvironment(width: 720.5, fontSize: 19, scale: 2, dark: false)] {
            for (name, element) in Self.equivalenceCorpus {
                let expected = Result { try ReferenceTableRenderer.render(element, environment: environment) }
                let actual = Result { try Self.coreTextInTheReferenceRaster(element, environment: environment) }
                switch (expected, actual) {
                case (.success(let old), .success(let new)):
                    #expect(new.size == old.size, "\(name) \(environment.fontSize): size \(new.size) vs \(old.size)")
                    #expect(new.image.width == old.image.width && new.image.height == old.image.height, "\(name): pixels \(new.image.width)x\(new.image.height) vs \(old.image.width)x\(old.image.height)")
                    #expect(new.cost == old.cost && new.baseline == old.baseline && new.label == old.label, "\(name)")
                    #expect(new.image.bitsPerComponent == old.image.bitsPerComponent && new.image.bitmapInfo == old.image.bitmapInfo, "\(name): format")
                    #expect(new.image.colorSpace?.name == old.image.colorSpace?.name, "\(name): color space")
                    guard new.image.width == old.image.width, new.image.height == old.image.height else { continue }
                    let a = Self.pixels(old.image), b = Self.pixels(new.image)
                    var largest = 0, over32 = 0, total = 0
                    for index in a.indices {
                        let difference = abs(Int(a[index]) - Int(b[index]))
                        largest = max(largest, difference); total += difference
                        if difference > 32 { over32 += 1 }
                    }
                    let mean = Double(total) / Double(a.count), fraction = Double(over32) / Double(a.count)
                    print(String(format: "TABLE_EQUIVALENCE %@ font=%.0f dark=%@ size=%.2fx%.2f mean_abs=%.4f max=%d over32=%.5f", name, environment.fontSize, environment.dark ? "yes" : "no", new.size.width, new.size.height, mean, largest, fraction))
                    #expect(mean < 1.0, "\(name): mean channel difference \(mean)")
                    #expect(fraction < 0.01, "\(name): \(fraction) of channels differ by more than 32")
                case (.failure(let old), .failure(let new)):
                    print("TABLE_EQUIVALENCE \(name) font=\(environment.fontSize) both fail: \(old.localizedDescription)")
                    #expect(new.localizedDescription == old.localizedDescription, "\(name): \(new) vs \(old)")
                default:
                    Issue.record("\(name) font=\(environment.fontSize): reference \(expected), renderer \(actual)")
                }
            }
        }
    }

    /// The raster follows the window the table will be drawn in. Both bitmaps used to come out at
    /// `NSScreen.main`'s scale whatever the requesting window's was, so a window on a 1× display beside a
    /// Retina main display got 2× pixels and a Retina window beside a 1× main display got 1×, while
    /// every other element on the page followed the window.
    @Test func tableRasterFollowsTheRequestingWindow() async throws {
        _ = NSApplication.shared
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let element = Self.table(rows: 4, columns: 3) { "r\($0)c\($1)" }
        // Two scales, neither of which can be the main screen's at the same time: the previous code
        // produced one bitmap size for both.
        var rendered: [Double: RenderArtifact] = [:]
        for scale in [1.0, 3.0] {
            rendered[scale] = try await RenderService().render(element, environment: RenderEnvironment(width: 400, fontSize: 16, scale: scale, dark: false), baseURL: nil, host: host)
        }
        let one = try #require(rendered[1.0]), three = try #require(rendered[3.0])
        print("TABLE_RASTER size=\(one.size) 1x=\(one.image.width)x\(one.image.height) 3x=\(three.image.width)x\(three.image.height) main=\(NSScreen.main?.backingScaleFactor ?? 0)")
        #expect(one.size == three.size, "the table's points must not depend on the raster")
        #expect(one.image.width == Int(ceil(one.size.width)) && one.image.height == Int(ceil(one.size.height)))
        #expect(three.image.width == Int(ceil(three.size.width * 3)) && three.image.height == Int(ceil(three.size.height * 3)))
    }

    /// The bitmap is in the host window's screen color space, not the frontmost screen's. On a machine
    /// with one screen the two are the same and this only pins where the value is read from.
    @Test func tableColorSpaceComesFromTheHostWindowsScreen() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 320), styleMask: [.titled], backing: .buffered, defer: false)
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 320))
        window.contentView?.addSubview(host)
        let expected = try #require(window.screen?.colorSpace?.cgColorSpace)
        let environment = RenderEnvironment(width: 300, fontSize: 16, scale: Double(window.backingScaleFactor), dark: false)
        let artifact = try await RenderService().render(Self.table(rows: 2, columns: 2) { "r\($0)c\($1)" }, environment: environment, baseURL: nil, host: host)
        let produced = try #require(artifact.image.colorSpace)
        #expect(CFEqual(produced, expected), "the table was rasterized in another screen's color space")
        #expect(artifact.image.width == Int(ceil(artifact.size.width * environment.scale)))
    }

    /// A table whose row and column counts already exceed a limit is rejected without measuring its
    /// cells; one whose cells decide is not.
    @Test func preflightDecidesOnlyWhatCountsDecide() {
        let environment = RenderEnvironment(width: 680, fontSize: 16, scale: 2, dark: false)
        let raster = TableRenderer.Raster(scale: 2, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        let limit = 48 * 1024 * 1024
        func preflight(_ rows: Int, _ columns: Int) -> RenderFailure? { TableRenderer.preflight(rows: rows, columns: columns, environment: environment, raster: raster, memoryLimit: limit) }
        #expect(preflight(20_000, 4) == TableRenderer.tooLargeToRender)
        #expect(preflight(10, 5_000) == TableRenderer.tooLargeToRender)
        // 60 × 2 at 680pt: 1360 × 4944 pixels of 8 bytes, over 48MiB, and even 300pt columns pass the display limit.
        #expect(preflight(60, 2) == TableRenderer.tooLargeToDisplay)
        // 60 × 6: 300pt columns would exceed the display limit, so the cells decide which failure it is.
        #expect(preflight(60, 6) == nil)
        // 30 × 8: 560pt at minimum width fits memory; wide cells could exceed the display limit, so measure.
        #expect(preflight(30, 8) == nil)
        #expect(preflight(40, 6) == nil)
        #expect(preflight(2, 2) == nil)
    }

    /// Main-thread stalls rendering pathological tables. Slow before tables moved off the main thread,
    /// so it runs only when AIRMARK_TABLE_MEASURE=1.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AIRMARK_TABLE_MEASURE"] == "1"))
    func pathologicalTablesMainThreadStalls() async throws {
        _ = NSApplication.shared
        let environment = RenderEnvironment(width: 680, fontSize: 16, scale: 2, dark: false)
        for (name, element) in Self.pathological {
          for reference in [true, false] {
            var totals: [Double] = [], stalls: [Double] = []
            var summary = ""
            for _ in 0..<5 {
                let (outcome, total, stall) = await Self.measure(element, environment: environment, reference: reference)
                totals.append(total); stalls.append(stall)
                switch outcome {
                case .success(let artifact): summary = String(format: "renders size=%.0fx%.0f pixels=%dx%d", artifact.size.width, artifact.size.height, artifact.image.width, artifact.image.height)
                case .failure(let error): summary = "fails \((error as? RenderFailure)?.errorDescription ?? String(describing: error))"
                }
            }
            totals.sort(); stalls.sort()
            print(String(format: "TABLE_STALL %@ path=%@ json_bytes=%d %@ total p50=%.1fms max=%.1fms stall p50=%.1fms max=%.1fms", name, reference ? "appkit-reference" : "coretext", element.content.utf8.count, summary, totals[2], totals[4], stalls[2], stalls[4]))
          }
        }
    }
}

/// The AppKit table drawing that `TableRenderer` replaced, kept as the reference for its output. It ran
/// on the main actor inside `RenderService`, whose memory limit then rejected results over 48MiB.
@MainActor enum ReferenceTableRenderer {
    static let memoryLimit = 48 * 1024 * 1024
    static func render(_ element: RenderElement, environment: RenderEnvironment) throws -> RenderArtifact {
        let result = try drawTable(element, environment: environment)
        guard result.cost <= memoryLimit else { throw RenderFailure.invalid("This image is too large to display.") }
        return result
    }
        static func drawTable(_ element: RenderElement, environment: RenderEnvironment) throws -> RenderArtifact {
            let rows = try JSONDecoder().decode([[String]].self, from: Data(element.content.utf8))
            guard !rows.isEmpty else { throw RenderFailure.unavailable }
            let columns = rows.map(\.count).max() ?? 1
            let font = NSFont.systemFont(ofSize: environment.fontSize)
            let color: NSColor = environment.dark ? .init(white: 0.87, alpha: 1) : .init(white: 0.16, alpha: 1)
            var widths = Array(repeating: 70.0, count: columns)
            let headerFont = NSFont.boldSystemFont(ofSize: environment.fontSize)
            for (r, row) in rows.enumerated() {
                for (column, text) in row.enumerated() {
                    let measured = (text as NSString).size(withAttributes: [.font: r == 0 ? headerFont : font]).width
                    widths[column] = min(300, max(widths[column], ceil(measured) + 28))
                }
            }
            let natural = widths.reduce(0, +), width = max(environment.width, natural)
            let lineHeight = environment.fontSize * 1.7 + 14
            let size = CGSize(width: width, height: Double(rows.count) * lineHeight)
            guard size.width * size.height * environment.scale * environment.scale < 12_000_000 else { throw RenderFailure.invalid("Table is too large to render.") }
            let image = NSImage(size: size, flipped: true) { bounds in
                for (r, row) in rows.enumerated() {
                    if r == 0 || r % 2 == 0 { NSColor.gray.withAlphaComponent(r == 0 ? 0.12 : 0.04).setFill(); NSRect(x: 0, y: Double(r) * lineHeight, width: width, height: lineHeight).fill() }
                    var x = 0.0
                    for (c, text) in row.enumerated() {
                        let cell = NSRect(x: x + 12, y: Double(r) * lineHeight + 10, width: widths[c] - 24, height: lineHeight - 14)
                        (text as NSString).draw(in: cell, withAttributes: [.font: r == 0 ? headerFont : font, .foregroundColor: color])
                        x += widths[c]
                    }
                    NSColor.gray.withAlphaComponent(0.18).setFill(); NSRect(x: 0, y: Double(r + 1) * lineHeight - 1, width: width, height: 1).fill()
                }
                return true
            }
            var rect = CGRect(origin: .zero, size: size)
            guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { throw RenderFailure.unavailable }
            return RenderArtifact(image: cg, size: size, baseline: size.height, label: element.label)
        }
}
