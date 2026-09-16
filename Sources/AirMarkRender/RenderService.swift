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
public enum RenderFailure: LocalizedError {
    case invalid(String), timeout, unavailable
    public var errorDescription: String? {
        switch self { case .invalid(let message): return message; case .timeout: return "Rendering took too long. Edit the source to retry."; case .unavailable: return "Renderer unavailable." }
    }
}

@MainActor public final class RenderService {
    public static let shared = RenderService()
    private var math = WebRenderer(), mermaid = WebRenderer()
    private var cache: [String: RenderArtifact] = [:]
    private var order: [String] = []
    private var bytes = 0
    private let memoryLimit = 48 * 1024 * 1024
    private var pending: [String: Task<RenderArtifact, Error>] = [:]
    public private(set) var renderedCount = 0

    public func key(_ element: RenderElement, environment: RenderEnvironment, baseURL: URL?) -> String {
        var source = "renderer-1|mermaid-11.12.0|katex-0.16.22|\(element.kind.rawValue)|\(element.inline)|\(element.content)|\(environment)"
        if element.kind == .image {
            source += "|\(baseURL?.path ?? "")"
            if let url = localURL(element.content, baseURL: baseURL), let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) {
                source += "|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(values.fileSize ?? 0)"
            }
        }
        return SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public func cached(_ key: String) -> RenderArtifact? { cache[key] }
    public func render(_ element: RenderElement, environment: RenderEnvironment, baseURL: URL?, host: NSView) async throws -> RenderArtifact {
        let identifier = key(element, environment: environment, baseURL: baseURL)
        if let result = cache[identifier] { touch(identifier); return labeled(result, for: element, baseURL: baseURL) }
        if let task = pending[identifier] { return labeled(try await task.value, for: element, baseURL: baseURL) }
        guard pending.count < 32 else { throw RenderFailure.unavailable }
        let task = Task<RenderArtifact, Error> { [self] in
            if element.kind == .image { return try await loadImage(element, environment: environment, baseURL: baseURL) }
            if element.kind == .table { return try drawTable(element, environment: environment) }
            let renderer = element.kind == .math ? math : mermaid
            return try await renderer.render(element, environment: environment, host: host)
        }
        pending[identifier] = task
        defer { pending[identifier] = nil }
        let result = try await task.value
        guard result.cost <= memoryLimit else { throw RenderFailure.invalid("This image is too large to display.") }
        cache[identifier] = result; bytes += result.cost; touch(identifier); renderedCount += 1
        while bytes > memoryLimit, let oldest = order.first { order.removeFirst(); if let removed = cache.removeValue(forKey: oldest) { bytes -= removed.cost } }
        return labeled(result, for: element, baseURL: baseURL)
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

@MainActor private final class WebRenderer: NSObject, WKNavigationDelegate {
    private var web: WKWebView?
    private var loaded = false
    private var navigation: CheckedContinuation<Void, Error>?
    private var tail: Task<RenderArtifact, Error>?
    func render(_ element: RenderElement, environment: RenderEnvironment, host: NSView) async throws -> RenderArtifact {
        let previous = tail
        let task = Task { @MainActor in
            _ = try? await previous?.value
            try Task.checkCancellation()
            return try await self.perform(element, environment: environment, host: host)
        }
        tail = task
        return try await task.value
    }
    private func prepare(host: NSView) async throws -> WKWebView {
        if let web, loaded {
            if web.superview !== host { web.removeFromSuperview(); host.addSubview(web, positioned: .below, relativeTo: host.subviews.first) }
            return web
        }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let rules = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "AirMarkOffline", encodedContentRuleList: "[{\"trigger\":{\"url-filter\":\"^https?://\"},\"action\":{\"type\":\"block\"}}]")
        if let rules { config.userContentController.add(rules) }
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 720, height: 512), configuration: config)
        view.navigationDelegate = self
        view.setAccessibilityElement(false)
        host.addSubview(view, positioned: .below, relativeTo: host.subviews.first)
        self.web = view
        guard let resource = Bundle.module.url(forResource: "renderer", withExtension: "html", subdirectory: "Resources") else { throw RenderFailure.unavailable }
        try await withCheckedThrowingContinuation { continuation in
            navigation = continuation
            view.loadFileURL(resource, allowingReadAccessTo: resource.deletingLastPathComponent())
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard let self, let pending = self.navigation else { return }
                self.navigation = nil; pending.resume(throwing: RenderFailure.timeout)
            }
        }
        loaded = true
        return view
    }
    private func perform(_ element: RenderElement, environment: RenderEnvironment, host: NSView) async throws -> RenderArtifact {
        guard host.window?.isMiniaturized != true else { throw RenderFailure.unavailable }
        do {
            let web = try await prepare(host: host)
            // Measure in a viewport wider than any result. A frame left small by the previous
            // snapshot let display-mode KaTeX report a box thousands of points wide.
            web.setFrameSize(NSSize(width: max(1024, ceil(environment.width) + 64), height: 2048))
            let result = try await javascript(web, body: "return await window.renderAirMark(source, kind, display, fontSize, dark, width, background);", arguments: ["source": element.content, "kind": element.kind.rawValue, "display": !element.inline, "fontSize": environment.fontSize, "dark": environment.dark, "width": environment.width, "background": environment.background])
            guard let metrics = try JSONSerialization.jsonObject(with: result) as? [String: Any], let width = metrics["width"] as? Double, let height = metrics["height"] as? Double,
                  width.isFinite, height.isFinite, width > 0, height > 0,
                  width * height * environment.scale * environment.scale <= 12_000_000 else { throw RenderFailure.invalid("Rendered content exceeds the display limit.") }
            let size = CGSize(width: ceil(width), height: ceil(height))
            web.setFrameSize(size)
            // Occluded WebViews may suspend animation frames. Force DOM layout without
            // waiting for a display refresh; takeSnapshot handles the drawing update.
            _ = try await javascript(web, body: "return document.getElementById('output').getBoundingClientRect().width;", arguments: [:])
            let config = WKSnapshotConfiguration()
            config.rect = CGRect(origin: .zero, size: size)
            config.snapshotWidth = NSNumber(value: size.width)
            let snapshot = try await web.takeSnapshot(configuration: config)
            var bounds = CGRect(origin: .zero, size: size)
            guard let image = snapshot.cgImage(forProposedRect: &bounds, context: nil, hints: nil) else { throw RenderFailure.unavailable }
            return RenderArtifact(image: image, size: size, baseline: metrics["baseline"] as? Double ?? size.height, label: element.kind == .math ? element.content : "Mermaid diagram. \(element.content.prefix(300))")
        } catch {
            if case RenderFailure.timeout = error { web?.stopLoading(); web?.removeFromSuperview(); web = nil; loaded = false }
            throw error
        }
    }
    private func javascript(_ web: WKWebView, body: String, arguments: [String: Any]) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            var completed = false
            web.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { result in
                guard !completed else { return }; completed = true
                switch result {
                case .success(let value):
                    do { continuation.resume(returning: try JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed)) }
                    catch { continuation.resume(throwing: error) }
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(8))
                guard !completed else { return }; completed = true
                continuation.resume(throwing: RenderFailure.timeout)
            }
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { let pending = self.navigation; self.navigation = nil; pending?.resume() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { let pending = self.navigation; self.navigation = nil; pending?.resume(throwing: error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { let pending = self.navigation; self.navigation = nil; pending?.resume(throwing: error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { loaded = false; web?.removeFromSuperview(); web = nil }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        navigationAction.request.url?.isFileURL == true ? .allow : .cancel
    }
}
