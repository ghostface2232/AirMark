import AppKit
import WebKit
import CryptoKit
import ImageIO
import AirMarkCore

public struct RenderEnvironment: Hashable, Sendable {
    public var width: Double
    public var fontSize: Double
    public var scale: Double
    public var dark: Bool
    /// CSS color painted behind WebKit snapshots. They cannot be captured transparent with public
    /// API, so the editor passes its own text background and the two match exactly.
    public var background: String
    public init(width: Double, fontSize: Double, scale: Double, dark: Bool, background: String = "#ffffff") {
        self.width = width; self.fontSize = fontSize; self.scale = scale; self.dark = dark; self.background = background
    }
}
public struct RenderArtifact: @unchecked Sendable {
    // CGImage is immutable; no NSImage/AppKit objects cross isolation boundaries.
    public let image: CGImage
    public let size: CGSize
    public let baseline: CGFloat
    public let label: String
    public var cost: Int { image.bytesPerRow * image.height }
}
public enum RenderFailure: LocalizedError, Equatable {
    /// The source cannot be rendered. Stays until the element's content changes.
    case invalid(String)
    /// A wait on WebKit exceeded its budget; the page was replaced.
    case timeout
    /// WebKit could not load or answer for a reason unrelated to the source; the page was replaced.
    case unavailable
    /// The page's content process died.
    case processTerminated
    /// The requesting window is minimized or gone. Not a failure of the element; render again later.
    case suspended

    /// Worth one more attempt later: nothing suggests the source itself is at fault.
    public var isTransient: Bool {
        switch self {
        case .invalid: false
        case .timeout, .unavailable, .processTerminated, .suspended: true
        }
    }
    public var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        case .timeout: "Rendering took too long."
        case .unavailable: "Renderer unavailable."
        case .processTerminated: "The renderer stopped unexpectedly."
        case .suspended: "Rendering is postponed while the window is hidden."
        }
    }
}

@MainActor public final class RenderService {
    public static let shared = RenderService()
    let math: WebRenderer, mermaid: WebRenderer
    private var cache: [String: RenderArtifact] = [:]
    private var order: [String] = []
    private var bytes = 0
    private let memoryLimit = 48 * 1024 * 1024
    /// An in-flight render shared by every caller asking for the same key. Each caller waits on its own
    /// continuation, so a cancelled caller stops waiting at once; when no caller is left the work is
    /// cancelled, which drops it from the renderer's queue if it has not started.
    @MainActor private final class Pending {
        let task: Task<RenderArtifact, any Error>
        private var waiters: [UUID: CheckedContinuation<RenderArtifact, any Error>] = [:]
        private var outcome: Result<RenderArtifact, any Error>?
        init(_ task: Task<RenderArtifact, any Error>) { self.task = task }
        var waiterCount: Int { waiters.count }

        func wait() async throws -> RenderArtifact {
            let id = UUID()
            return try await withTaskCancellationHandler {
                // Registered even when this caller is already cancelled: its cancellation hop, which
                // runs after this main-actor stretch, then finds it, resumes it and cancels the work
                // if no one else is waiting.
                try await withCheckedThrowingContinuation { continuation in
                    if let outcome { continuation.resume(with: outcome) } else { waiters[id] = continuation }
                }
            } onCancel: {
                Task { @MainActor in self.cancel(id) }
            }
        }
        private func cancel(_ id: UUID) {
            guard let continuation = waiters.removeValue(forKey: id) else { return }
            continuation.resume(throwing: CancellationError())
            if waiters.isEmpty && outcome == nil { task.cancel() }
        }
        func finish(_ outcome: Result<RenderArtifact, any Error>) {
            self.outcome = outcome
            let waiting = waiters.values
            waiters.removeAll()
            for continuation in waiting { continuation.resume(with: outcome) }
        }
    }
    private var pending: [String: Pending] = [:]
    init(budget: WebRenderer.Budget = .init()) {
        math = WebRenderer(budget: budget)
        mermaid = WebRenderer(budget: budget)
    }
    public private(set) var renderedCount = 0

    public func key(_ element: RenderElement, environment: RenderEnvironment, baseURL: URL?) -> String {
        var source = "renderer-1|mermaid-11.17.2|katex-0.16.22|\(element.kind.rawValue)|\(element.inline)|\(element.content)|\(environment)"
        if element.kind == .image {
            source += "|\(baseURL?.path ?? "")"
            if let url = localURL(element.content, baseURL: baseURL), let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) {
                source += "|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(values.fileSize ?? 0)"
            }
        }
        return SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public func cached(_ key: String) -> RenderArtifact? { cache[key] }
    /// Callers waiting on the in-flight render for `key`, or nil when none is in flight; for tests.
    func waiterCount(for key: String) -> Int? { pending[key]?.waiterCount }
    public func render(_ element: RenderElement, environment: RenderEnvironment, baseURL: URL?, host: NSView) async throws -> RenderArtifact {
        let identifier = key(element, environment: environment, baseURL: baseURL)
        if let result = cache[identifier] { touch(identifier); return labeled(result, for: element, baseURL: baseURL) }
        let result: RenderArtifact
        do { result = try await sharedRender(identifier, element, environment: environment, baseURL: baseURL, host: host) }
        catch is CancellationError where !Task.isCancelled {
            // This caller joined a render whose earlier callers had all been cancelled, so the work was
            // cancelled before it could start. The entry is settled by now; render afresh.
            if let cached = cache[identifier] { touch(identifier); return labeled(cached, for: element, baseURL: baseURL) }
            result = try await sharedRender(identifier, element, environment: environment, baseURL: baseURL, host: host)
        }
        // Checked for every caller, including those that joined a render another caller started.
        guard result.cost <= memoryLimit else { throw RenderFailure.invalid("This image is too large to display.") }
        return labeled(result, for: element, baseURL: baseURL)
    }
    /// Joins the in-flight render for `identifier`, or starts one.
    private func sharedRender(_ identifier: String, _ element: RenderElement, environment: RenderEnvironment, baseURL: URL?, host: NSView) async throws -> RenderArtifact {
        let entry: Pending
        if let shared = pending[identifier] {
            entry = shared
        } else {
            let task = Task<RenderArtifact, any Error> { [self] in
                if element.kind == .image { return try await loadImage(element, environment: environment, baseURL: baseURL) }
                if element.kind == .table { return try drawTable(element, environment: environment) }
                let renderer = element.kind == .math ? math : mermaid
                return try await renderer.render(element, environment: environment, host: host)
            }
            entry = Pending(task)
            pending[identifier] = entry
            // When the work ends, even if every caller stopped waiting: cache a result, drop the entry so
            // a failure is never handed to a later caller, then wake whoever is still waiting.
            Task { [self] in
                let outcome = await task.result
                settle(identifier, entry, try? outcome.get())
                entry.finish(outcome)
            }
        }
        return try await entry.wait()
    }
    /// Removes a finished entry and caches its result.
    private func settle(_ identifier: String, _ entry: Pending, _ result: RenderArtifact?) {
        guard pending[identifier] === entry else { return }
        pending[identifier] = nil
        guard let result, result.cost <= memoryLimit else { return }
        cache[identifier] = result; bytes += result.cost; touch(identifier); renderedCount += 1
        while bytes > memoryLimit, let oldest = order.first { order.removeFirst(); if let removed = cache.removeValue(forKey: oldest) { bytes -= removed.cost } }
    }
    /// Accessibility belongs to the requesting element, while identical pixels remain shared.
    private func labeled(_ artifact: RenderArtifact, for element: RenderElement, baseURL: URL?) -> RenderArtifact {
        let label: String
        switch element.kind {
        case .image: label = element.label.isEmpty ? localURL(element.content, baseURL: baseURL)?.lastPathComponent ?? "" : element.label
        case .table: label = element.label
        case .math, .mermaid: return artifact
        }
        return RenderArtifact(image: artifact.image, size: artifact.size, baseline: artifact.baseline, label: label)
    }
    private func touch(_ key: String) { order.removeAll { $0 == key }; order.append(key) }
    private func localURL(_ path: String, baseURL: URL?) -> URL? {
        if let url = URL(string: path), url.scheme != nil { return url.isFileURL ? url : nil }
        guard let baseURL else { return nil }
        return URL(fileURLWithPath: path.removingPercentEncoding ?? path, relativeTo: baseURL.deletingLastPathComponent()).standardizedFileURL
    }
    private func loadImage(_ element: RenderElement, environment: RenderEnvironment, baseURL: URL?) async throws -> RenderArtifact {
        guard let url = localURL(element.content, baseURL: baseURL) else { throw RenderFailure.invalid("Only local images are displayed. Save the document to resolve relative paths.") }
        let maximum = min(4096, Int(environment.width * environment.scale))
        return try await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maximum, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
                throw RenderFailure.invalid("Image could not be opened: \(url.lastPathComponent)")
            }
            let width = min(environment.width, Double(image.width) / environment.scale)
            let size = CGSize(width: width, height: width * Double(image.height) / Double(image.width))
            return RenderArtifact(image: image, size: size, baseline: size.height, label: element.label.isEmpty ? url.lastPathComponent : element.label)
        }.value
    }
    private func drawTable(_ element: RenderElement, environment: RenderEnvironment) throws -> RenderArtifact {
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
