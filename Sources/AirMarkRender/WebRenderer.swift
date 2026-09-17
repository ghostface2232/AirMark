import AppKit
import WebKit
import AirMarkCore

/// One offline WebKit page that renders formulas or diagrams, one job at a time.
///
/// Every wait on WebKit (page load, script, snapshot) has a budget. A page that exceeds one, or whose
/// content process dies, is discarded: its generation ends, every wait on it fails at once, and
/// callbacks that still arrive from it are ignored because they name a web view that is no longer
/// current. Jobs run in arrival order; a queued job whose caller is cancelled is removed, while a
/// running job finishes so its result can still be cached.
@MainActor final class WebRenderer: NSObject, WKNavigationDelegate {
    struct Budget: Sendable {
        var load: Duration = .seconds(10)
        var script: Duration = .seconds(8)
        var snapshot: Duration = .seconds(5)
    }
    let budget: Budget
    private var web: WKWebView?
    private var ready = false
    /// Incremented whenever the page is discarded; a wait started in an older generation is stale.
    private var generation = 0
    private var navigation: OneShot<Void>?
    /// Failure handlers for waits on the current page, so discarding it ends them immediately.
    private var waits: [UUID: (RenderFailure) -> Void] = [:]
    private var queue: [Job] = []
    private var running = false
    /// Page loads started; a test hook for telling a reused page from a replaced one.
    private(set) var loadCount = 0

    init(budget: Budget = Budget()) { self.budget = budget }

    @MainActor final class Job {
        let element: RenderElement
        let environment: RenderEnvironment
        weak var host: NSView?
        var continuation: CheckedContinuation<RenderArtifact, any Error>?
        init(element: RenderElement, environment: RenderEnvironment, host: NSView) {
            self.element = element; self.environment = environment; self.host = host
        }
        func finish(_ result: Result<RenderArtifact, any Error>) {
            let pending = continuation
            continuation = nil
            pending?.resume(with: result)
        }
    }

    func render(_ element: RenderElement, environment: RenderEnvironment, host: NSView) async throws -> RenderArtifact {
        try Task.checkCancellation()
        let job = Job(element: element, environment: environment, host: host)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                job.continuation = continuation
                queue.append(job)
                pump()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(job) }
        }
    }

    private func cancel(_ job: Job) {
        guard let index = queue.firstIndex(where: { $0 === job }) else { return }
        queue.remove(at: index)
        job.finish(.failure(CancellationError()))
    }

    private func pump() {
        guard !running, !queue.isEmpty else { return }
        running = true
        Task { @MainActor in
            while !queue.isEmpty {
                let job = queue.removeFirst()
                do { job.finish(.success(try await performRetryingOnce(job))) }
                catch { job.finish(.failure(error)) }
            }
            running = false
        }
    }

    /// A page lost to its process or to a WebKit failure is replaced and the job tried once more.
    private func performRetryingOnce(_ job: Job) async throws -> RenderArtifact {
        do { return try await perform(job) }
        catch RenderFailure.processTerminated { return try await perform(job) }
        catch RenderFailure.unavailable { return try await perform(job) }
    }

    private func perform(_ job: Job) async throws -> RenderArtifact {
        // The requester's window is gone, closed or minimized; nothing is wrong with the element.
        guard let host = job.host, Self.isShowing(host) else { throw RenderFailure.suspended }
        let environment = job.environment, element = job.element
        let web = try await prepare(host: host)
        // Measure in a viewport wider than any result. A frame left small by the previous
        // snapshot let display-mode KaTeX report a box thousands of points wide.
        web.setFrameSize(NSSize(width: max(1024, ceil(environment.width) + 64), height: 2048))
        let result = try await javascript(web, body: "return await window.renderAirMark(source, kind, display, fontSize, dark, width, background);", arguments: ["source": element.content, "kind": element.kind.rawValue, "display": !element.inline, "fontSize": environment.fontSize, "dark": environment.dark, "width": environment.width, "background": environment.background])
        // A window closed during the script leaves a page whose measurements mean nothing.
        guard Self.isShowing(host) else { throw RenderFailure.suspended }
        guard let metrics = try? JSONSerialization.jsonObject(with: result) as? [String: Any], let width = metrics["width"] as? Double, let height = metrics["height"] as? Double,
              width.isFinite, height.isFinite, width > 0, height > 0 else { throw RenderFailure.invalid("The renderer returned no size.") }
        guard width * height * environment.scale * environment.scale <= 12_000_000 else { throw RenderFailure.invalid("Rendered content exceeds the display limit.") }
        let size = CGSize(width: ceil(width), height: ceil(height))
        web.setFrameSize(size)
        // Occluded WebViews may suspend animation frames. Force DOM layout without
        // waiting for a display refresh; takeSnapshot handles the drawing update.
        _ = try await javascript(web, body: "return document.getElementById('output').getBoundingClientRect().width;", arguments: [:])
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(origin: .zero, size: size)
        configuration.snapshotWidth = NSNumber(value: size.width)
        let snapshot: RenderArtifact = try await wait(budget.snapshot) { shot in
            web.takeSnapshot(with: configuration) { image, error in
                MainActor.assumeIsolated {
                    var bounds = CGRect(origin: .zero, size: size)
                    if let image = image?.cgImage(forProposedRect: &bounds, context: nil, hints: nil) {
                        shot.resume(.success(RenderArtifact(image: image, size: size, baseline: 0, label: "")))
                    } else {
                        shot.resume(.failure(self.classify(error, from: web)))
                    }
                }
            }
        }
        return RenderArtifact(image: snapshot.image, size: size, baseline: metrics["baseline"] as? Double ?? size.height, label: element.kind == .math ? element.content : "Mermaid diagram. \(element.content.prefix(300))")
    }

    /// A closed window keeps its views, so `window != nil` is not enough; it is no longer visible.
    /// A minimized window is not visible either.
    private static func isShowing(_ host: NSView) -> Bool {
        guard let window = host.window else { return false }
        return window.isVisible && !window.isMiniaturized
    }

    private static var offlineRules: WKContentRuleList?

    private func prepare(host: NSView) async throws -> WKWebView {
        if let web, ready {
            if web.superview !== host { web.removeFromSuperview(); host.addSubview(web, positioned: .below, relativeTo: host.subviews.first) }
            return web
        }
        discard(.unavailable)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        if Self.offlineRules == nil {
            Self.offlineRules = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "AirMarkOffline", encodedContentRuleList: "[{\"trigger\":{\"url-filter\":\"^https?://\"},\"action\":{\"type\":\"block\"}}]")
        }
        if let rules = Self.offlineRules { configuration.userContentController.add(rules) }
        guard let resource = Bundle.module.url(forResource: "renderer", withExtension: "html", subdirectory: "Resources") else { throw RenderFailure.invalid("The renderer resources are missing.") }
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 720, height: 512), configuration: configuration)
        view.navigationDelegate = self
        view.setAccessibilityElement(false)
        host.addSubview(view, positioned: .below, relativeTo: host.subviews.first)
        web = view
        loadCount += 1
        try await wait(budget.load) { shot in
            navigation = shot
            view.loadFileURL(resource, allowingReadAccessTo: resource.deletingLastPathComponent())
        }
        navigation = nil
        ready = true
        return view
    }

    private func javascript(_ web: WKWebView, body: String, arguments: [String: Any]) async throws -> Data {
        try await wait(budget.script) { shot in
            web.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { result in
                switch result {
                case .success(let value):
                    if let data = try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed) { shot.resume(.success(data)) }
                    else { shot.resume(.failure(self.classify(nil, from: web))) }
                case .failure(let error):
                    shot.resume(.failure(self.classify(error, from: web)))
                }
            }
        }
    }

    /// A script exception is a problem with the source. Anything else from WebKit, including a
    /// malformed result from a page whose process just died, is a problem with the page: discard it.
    private func classify(_ error: (any Error)?, from view: WKWebView) -> RenderFailure {
        if let error = error as? WKError, error.code == .javaScriptExceptionOccurred {
            return .invalid(error.userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription)
        }
        guard view === web else { return .processTerminated }
        let failure: RenderFailure = (error as? WKError)?.code == .webContentProcessTerminated ? .processTerminated : .unavailable
        discard(failure)
        return failure
    }

    /// Waits for one callback on the current page, failing with `.timeout` after `budget`, or at once
    /// if the page is discarded first. A timeout discards the page: its script may still be running
    /// and would otherwise overwrite the next job's output.
    private func wait<Value: Sendable>(_ budget: Duration, _ start: (OneShot<Value>) -> Void) async throws -> Value {
        let id = UUID(), started = generation
        let shot = OneShot<Value>()
        waits[id] = { shot.resume(.failure($0)) }
        let timer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: budget)
            guard !Task.isCancelled, let self, !shot.isResolved else { return }
            shot.resume(.failure(RenderFailure.timeout))
            if generation == started { discard(.timeout) }
        }
        defer { timer.cancel(); waits[id] = nil }
        return try await shot.value(start)
    }

    private func discard(_ reason: RenderFailure) {
        guard web != nil || !waits.isEmpty else { return }
        generation += 1
        web?.stopLoading()
        web?.navigationDelegate = nil
        web?.removeFromSuperview()
        web = nil
        ready = false
        navigation = nil
        let pending = waits.values
        waits.removeAll()
        for fail in pending { fail(reason) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === web else { return }
        self.navigation?.resume(.success(()))
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        guard webView === web else { return }
        self.navigation?.resume(.failure(RenderFailure.unavailable))
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        guard webView === web else { return }
        self.navigation?.resume(.failure(RenderFailure.unavailable))
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === web else { return }
        discard(.processTerminated)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        navigationAction.request.url?.isFileURL == true ? .allow : .cancel
    }
}

/// A continuation that can be resumed at most once, by whichever of a callback, a timer or a
/// discarded page gets there first.
@MainActor final class OneShot<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, any Error>?
    private var early: Result<Value, any Error>?
    private(set) var isResolved = false

    func value(_ start: (OneShot<Value>) -> Void) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            start(self)
            if let early { self.early = nil; self.continuation = nil; continuation.resume(with: early) }
        }
    }

    func resume(_ result: Result<Value, any Error>) {
        guard !isResolved else { return }
        isResolved = true
        if let continuation { self.continuation = nil; continuation.resume(with: result) }
        else { early = result }
    }
}
