import AppKit
import CoreText

/// Native tables, measured with CoreText and drawn with CoreGraphics so the work can run off the main
/// thread. Layout, colors, limits and failure messages are those of the AppKit drawing it replaced:
/// columns 70–300pt wide from each column's widest cell, rows `fontSize × 1.7 + 14` tall, a shaded
/// header and alternate rows, and pixels in a 16-bit float bitmap at the screen's scale.
///
/// Every limit that a table's row and column counts alone can decide is checked before any cell is
/// measured, so a table far over the limit costs its decoding and nothing more.
enum TableRenderer {
    struct Raster: @unchecked Sendable {
        // CGColorSpace is immutable.
        let scale: Double
        let colorSpace: CGColorSpace
        /// Where cell text starts. AppKit's natural alignment follows the user's language direction,
        /// not each cell's script, so a Hebrew cell is left-aligned in a left-to-right locale.
        var alignment = CTTextAlignment.left
    }

    static let minimumColumnWidth = 70.0
    static let maximumColumnWidth = 300.0
    /// Points squared times scale squared.
    static let displayLimit = 12_000_000.0
    static let tooLargeToRender = RenderFailure.invalid("Table is too large to render.")
    /// The message `RenderService` gives any result over its memory limit.
    static let tooLargeToDisplay = RenderFailure.invalid("This image is too large to display.")

    static func lineHeight(_ environment: RenderEnvironment) -> Double { environment.fontSize * 1.7 + 14 }

    /// Bytes of the bitmap for a table of `size` points: 16 bits per component, four components.
    static func cost(_ size: CGSize, raster: Raster) -> Int {
        Int(ceil(size.width * raster.scale)) * 8 * Int(ceil(size.height * raster.scale))
    }

    /// The failure a table with these counts must end in whatever its cells contain, or nil when that
    /// depends on the cells. Its height is known exactly, and its width lies between every column at
    /// the minimum and every column at the maximum.
    static func preflight(rows: Int, columns: Int, environment: RenderEnvironment, raster: Raster, memoryLimit: Int) -> RenderFailure? {
        let height = Double(rows) * lineHeight(environment)
        let narrowest = max(environment.width, Double(columns) * minimumColumnWidth)
        let widest = max(environment.width, Double(columns) * maximumColumnWidth)
        let scale2 = environment.scale * environment.scale
        if narrowest * height * scale2 >= displayLimit { return tooLargeToRender }
        // Only certain when the widest table still passes the display limit: otherwise the cells decide
        // which of the two failures, or success, it is.
        if widest * height * scale2 < displayLimit, cost(CGSize(width: narrowest, height: height), raster: raster) > memoryLimit { return tooLargeToDisplay }
        return nil
    }

    static func render(_ content: String, label: String, environment: RenderEnvironment, raster: Raster, memoryLimit: Int) throws -> RenderArtifact {
        let rows = try JSONDecoder().decode([[String]].self, from: Data(content.utf8))
        guard !rows.isEmpty else { throw RenderFailure.unavailable }
        let columns = rows.map(\.count).max() ?? 1
        if let failure = preflight(rows: rows.count, columns: columns, environment: environment, raster: raster, memoryLimit: memoryLimit) { throw failure }

        let font = CTFontCreateUIFontForLanguage(.system, environment.fontSize, nil)!
        let headerFont = CTFontCreateUIFontForLanguage(.emphasizedSystem, environment.fontSize, nil)!
        var widths = Array(repeating: minimumColumnWidth, count: columns)
        for (r, row) in rows.enumerated() {
            for (column, text) in row.enumerated() {
                let measured = width(of: text, font: r == 0 ? headerFont : font)
                widths[column] = min(maximumColumnWidth, max(widths[column], ceil(measured) + 28))
            }
        }
        let natural = widths.reduce(0, +), width = max(environment.width, natural)
        let lineHeight = lineHeight(environment)
        let size = CGSize(width: width, height: Double(rows.count) * lineHeight)
        guard size.width * size.height * environment.scale * environment.scale < displayLimit else { throw tooLargeToRender }
        guard cost(size, raster: raster) <= memoryLimit else { throw tooLargeToDisplay }

        let pixelWidth = Int(ceil(size.width * raster.scale)), pixelHeight = Int(ceil(size.height * raster.scale))
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
        guard let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 16, bytesPerRow: 0, space: raster.colorSpace, bitmapInfo: info) else { throw RenderFailure.unavailable }
        // Points, with the origin at the top left like the table's rows.
        context.scaleBy(x: raster.scale, y: raster.scale)
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        let text = (environment.dark ? NSColor(white: 0.87, alpha: 1) : NSColor(white: 0.16, alpha: 1)).cgColor
        let header = NSColor.gray.withAlphaComponent(0.12).cgColor
        let stripe = NSColor.gray.withAlphaComponent(0.04).cgColor
        let rule = NSColor.gray.withAlphaComponent(0.18).cgColor
        for (r, row) in rows.enumerated() {
            let top = Double(r) * lineHeight
            if r == 0 || r % 2 == 0 {
                context.setFillColor(r == 0 ? header : stripe)
                context.fill(CGRect(x: 0, y: top, width: width, height: lineHeight))
            }
            var x = 0.0
            for (c, cell) in row.enumerated() {
                draw(cell, in: CGRect(x: x + 12, y: top + 10, width: widths[c] - 24, height: lineHeight - 14), font: r == 0 ? headerFont : font, color: text, alignment: raster.alignment, context: context)
                x += widths[c]
            }
            context.setFillColor(rule)
            context.fill(CGRect(x: 0, y: Double(r + 1) * lineHeight - 1, width: width, height: 1))
        }
        guard let image = context.makeImage() else { throw RenderFailure.unavailable }
        return RenderArtifact(image: image, size: size, baseline: size.height, label: label)
    }

    /// Width of the widest line of `text` set in `font`, including trailing whitespace, as AppKit's
    /// string measurement counts it.
    static func width(of text: String, font: CTFont) -> Double {
        text.split(separator: "\n", omittingEmptySubsequences: false).reduce(0) { widest, line in
            let typeset = CTLineCreateWithAttributedString(NSAttributedString(string: String(line), attributes: [.font: font]))
            return max(widest, CTLineGetTypographicBounds(typeset, nil, nil, nil))
        }
    }

    /// Sets `text` from the top of `rect` (top-left coordinates), wrapping at its width and drawing only
    /// the lines that fit in its height.
    static func draw(_ text: String, in rect: CGRect, font: CTFont, color: CGColor, alignment: CTTextAlignment, context: CGContext) {
        guard !text.isEmpty, rect.width > 0, rect.height > 0 else { return }
        var aligned = alignment
        let paragraph = withUnsafePointer(to: &aligned) { pointer in
            CTParagraphStyleCreate([CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: pointer)], 1)
        }
        let string = NSAttributedString(string: text, attributes: [.font: font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): color, NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph])
        let framesetter = CTFramesetterCreateWithAttributedString(string)
        // CoreText lays out upward from the bottom of its path; flip this cell back to that orientation.
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), CGPath(rect: CGRect(origin: .zero, size: rect.size), transform: nil), nil)
        CTFrameDraw(frame, context)
        context.restoreGState()
    }
}
