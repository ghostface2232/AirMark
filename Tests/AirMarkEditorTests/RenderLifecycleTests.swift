import AppKit
import WebKit
import Testing
import AirMarkCore
@testable import AirMarkEditor
@testable import AirMarkRender

/// What happens to rendering when WebKit misbehaves: a content process dies, a window closes or
/// minimizes mid-render, or many requests arrive at once. Every wait must end, a failure must stay
/// with the element that caused it, and the next request must work.
@Suite(.serialized) @MainActor struct RenderLifecycleTests {
    /// The outcome of `operation`, or nil if it had not finished after `seconds`. The operation keeps
    /// running in the background; the test only stops waiting for it.
    static func within<T: Sendable>(_ seconds: Double, _ operation: @escaping @MainActor () async throws -> T) async -> Result<T, any Error>? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Result<T, any Error>?, Never>) in
            var finished = false
            Task { @MainActor in
                let result: Result<T, any Error>
                do { result = .success(try await operation()) } catch { result = .failure(error) }
                guard !finished else { return }
                finished = true; continuation.resume(returning: result)
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                guard !finished else { return }
                finished = true; continuation.resume(returning: nil)
            }
        }
    }
    static func window() -> (NSWindow, NSView) {
        _ = NSApplication.shared
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host; window.orderFront(nil)
        return (window, host)
    }
    static let environment = RenderEnvironment(width: 680, fontSize: 16, scale: 2, dark: false)
    static func math(_ content: String, at location: Int = 0) -> RenderElement {
        RenderElement(span: SourceSpan(location, 1), kind: .math, content: content, inline: true)
    }
    /// A diagram that takes WebKit a noticeable time to lay out. Left to right, so it is scaled to the
    /// column width and stays within the display limit.
    static func slowDiagram(_ nodes: Int = 400, salt: Int = 0) -> RenderElement {
        let edges = (0..<nodes).map { "N\($0)[Node \($0) \(salt)] --> N\($0 + 1)" }.joined(separator: "\n")
        return RenderElement(span: SourceSpan(0, 1), kind: .mermaid, content: "graph LR\n" + edges)
    }
    static func webContentProcesses() -> Set<Int32> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", "com.apple.WebKit.WebContent"]
        let pipe = Pipe(); process.standardOutput = pipe
        try? process.run(); process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return Set(output.split(separator: "\n").compactMap { Int32($0) })
    }

    /// Delegate callbacks name their web view. One from a page the renderer already replaced must
    /// not discard or resume the current page.
    @Test func callbacksFromAReplacedPageAreIgnored() async throws {
        let (window, host) = Self.window()
        defer { window.close() }
        let service = RenderService()
        _ = try await service.render(Self.math("a"), environment: Self.environment, baseURL: nil, host: host)
        #expect(service.math.loadCount == 1)
        service.math.webViewWebContentProcessDidTerminate(WKWebView())
        _ = try await service.render(Self.math("b"), environment: Self.environment, baseURL: nil, host: host)
        print("LIFECYCLE stale termination callback: loads \(service.math.loadCount)")
        #expect(service.math.loadCount == 1, "a termination reported for another web view replaced the page")
    }

    /// A content process killed mid-render: the render ends promptly and the renderer recovers.
    @Test func killedContentProcessEndsTheRenderAndRecovers() async throws {
        let (window, host) = Self.window()
        defer { window.close() }
        let service = RenderService()
        let before = Self.webContentProcesses()
        let warm = await Self.within(20) { try await service.render(RenderElement(span: SourceSpan(0, 1), kind: .mermaid, content: "graph LR\nA-->B"), environment: Self.environment, baseURL: nil, host: host) }
        guard case .success = warm else { Issue.record("warm-up render: \(String(describing: warm))"); return }
        let spawned = Self.webContentProcesses().subtracting(before)
        let pid = try #require(spawned.count == 1 ? spawned.first : nil, "expected one new WebContent process, got \(spawned)")
        let clock = ContinuousClock()
        // The same size of diagram without interference, to show the kill lands mid-render.
        let unhindered = clock.now
        _ = await Self.within(30) { try await service.render(Self.slowDiagram(salt: 9), environment: Self.environment, baseURL: nil, host: host) }
        print("LIFECYCLE slow diagram alone: \(unhindered.duration(to: clock.now))")
        let started = clock.now
        let slow = Task { @MainActor in await Self.within(30) { try await service.render(Self.slowDiagram(), environment: Self.environment, baseURL: nil, host: host) } }
        try await Task.sleep(for: .milliseconds(150))
        kill(pid, SIGKILL)
        let outcome = await slow.value
        print("LIFECYCLE killed: \(String(describing: outcome.map { $0.map(\.size) })) after \(started.duration(to: clock.now))")
        #expect(outcome != nil, "render after the content process died never finished")
        if case .failure(let error) = outcome {
            #expect((error as? RenderFailure)?.isTransient == true, "a dead content process is not a source error: \(error)")
        }
        let next = await Self.within(15) { try await service.render(Self.slowDiagram(3, salt: 1), environment: Self.environment, baseURL: nil, host: host) }
        print("LIFECYCLE after kill: \(String(describing: next.map { $0.map(\.size) })) loads \(service.mermaid.loadCount)")
        #expect(service.mermaid.loadCount == 2, "the killed page should have been replaced exactly once")
        guard case .success = next else { Issue.record("render after recovery: \(String(describing: next))"); return }
    }

    /// The window hosting the renderer closes mid-render; a render for another window still works.
    @Test func closingTheHostWindowMidRenderDoesNotStallOthers() async throws {
        let (first, firstHost) = Self.window()
        let (second, secondHost) = Self.window()
        defer { second.close() }
        let service = RenderService()
        let slow = Task { @MainActor in await Self.within(30) { try await service.render(Self.slowDiagram(salt: 2), environment: Self.environment, baseURL: nil, host: firstHost) } }
        try await Task.sleep(for: .milliseconds(300))
        first.close()
        let outcome = await slow.value
        print("LIFECYCLE closed host: \(String(describing: outcome.map { $0.map(\.size) }))")
        #expect(outcome != nil, "render in a closed window never finished")
        if case .failure(let error) = outcome {
            #expect(error as? RenderFailure == .suspended, "a closed window is not a source error: \(error)")
        }
        let other = await Self.within(15) { try await service.render(Self.slowDiagram(3, salt: 3), environment: Self.environment, baseURL: nil, host: secondHost) }
        print("LIFECYCLE other window: \(String(describing: other.map { $0.map(\.size) }))")
        guard case .success = other else { Issue.record("render in the remaining window: \(String(describing: other))"); return }
    }

    /// A script over budget fails with a timeout, and its page is replaced so the script cannot
    /// overwrite the next job's output.
    @Test func timedOutScriptReplacesThePage() async throws {
        let (window, host) = Self.window()
        defer { window.close() }
        let service = RenderService(budget: .init(script: .milliseconds(150)))
        _ = await Self.within(20) { try await service.render(RenderElement(span: SourceSpan(0, 1), kind: .mermaid, content: "graph LR\nA-->B"), environment: Self.environment, baseURL: nil, host: host) }
        let loads = service.mermaid.loadCount
        let slow = await Self.within(20) { try await service.render(Self.slowDiagram(450, salt: 4), environment: Self.environment, baseURL: nil, host: host) }
        print("LIFECYCLE timeout: \(String(describing: slow.map { $0.map(\.size) })) loads \(loads) -> \(service.mermaid.loadCount)")
        guard case .failure(let error) = slow else { Issue.record("expected a timeout, got \(String(describing: slow))"); return }
        #expect(error as? RenderFailure == .timeout)
        let next = await Self.within(20) { try await service.render(RenderElement(span: SourceSpan(0, 1), kind: .mermaid, content: "graph LR\nC-->D"), environment: Self.environment, baseURL: nil, host: host) }
        guard case .success(let artifact) = next else { Issue.record("render after a timeout: \(String(describing: next))"); return }
        #expect(artifact.size.width < 400, "the replaced page's output leaked into the next job: \(artifact.size)")
        #expect(service.mermaid.loadCount > loads)
    }

    /// A caller that stops waiting removes its queued job, so typing through a formula does not leave
    /// a backlog of stale renders ahead of the current one.
    @Test func cancelledQueuedRequestsDoNotRun() async throws {
        let (window, host) = Self.window()
        defer { window.close() }
        let service = RenderService()
        _ = try await service.render(Self.math("w"), environment: Self.environment, baseURL: nil, host: host)
        let blocker = Task { @MainActor in try await service.render(Self.slowDiagram(200, salt: 5), environment: Self.environment, baseURL: nil, host: host) }
        let queued = (0..<10).map { index in Task { @MainActor in try await service.render(Self.slowDiagram(200, salt: 100 + index), environment: Self.environment, baseURL: nil, host: host) } }
        try await Task.sleep(for: .milliseconds(20))
        for task in queued { task.cancel() }
        var cancelled = 0
        for task in queued { if case .failure(let error) = await task.result, error is CancellationError { cancelled += 1 } }
        _ = await blocker.result
        print("LIFECYCLE cancelled queued: \(cancelled) of 10")
        #expect(cancelled == 10)
    }

    /// Callers sharing one in-flight render: when all of them are cancelled while it is still queued,
    /// the render is dropped instead of running ahead of work that is still wanted.
    @Test func cancellingEverySharingCallerDropsTheQueuedRender() async throws {
        let (window, host) = Self.window()
        defer { window.close() }
        let service = RenderService()
        let blocker = Task { @MainActor in try await service.render(Self.slowDiagram(200, salt: 20), environment: Self.environment, baseURL: nil, host: host) }
        let shared = RenderElement(span: SourceSpan(0, 1), kind: .mermaid, content: "graph LR\nShared-->Twice")
        let first = Task { @MainActor in try await service.render(shared, environment: Self.environment, baseURL: nil, host: host) }
        let second = Task { @MainActor in try await service.render(shared, environment: Self.environment, baseURL: nil, host: host) }
        try await Task.sleep(for: .milliseconds(20))
        first.cancel(); second.cancel()
        var outcomes: [String] = []
        for task in [first, second] {
            let result = await Self.within(5) { await task.result }
            switch result { case .success(.failure(let error)) where error is CancellationError: outcomes.append("cancelled"); default: outcomes.append(String(describing: result)) }
        }
        _ = await blocker.result
        try await Task.sleep(for: .milliseconds(500))
        let key = service.key(shared, environment: Self.environment, baseURL: nil)
        print("LIFECYCLE shared cancel: \(outcomes) rendered \(service.renderedCount) cached \(service.cached(key) != nil)")
        #expect(outcomes == ["cancelled", "cancelled"])
        #expect(service.cached(key) == nil, "the dropped render ran anyway")
    }

    /// A caller whose task is already cancelled when it reaches the render still cancels it: an
    /// environment change cancels render tasks that may not have started waiting yet.
    @Test func alreadyCancelledCallerDropsTheQueuedRender() async throws {
        let (window, host) = Self.window()
        defer { window.close() }
        let service = RenderService()
        let blocker = Task { @MainActor in try await service.render(Self.slowDiagram(200, salt: 22), environment: Self.environment, baseURL: nil, host: host) }
        let element = RenderElement(span: SourceSpan(0, 1), kind: .mermaid, content: "graph LR\nAlready-->Cancelled")
        let caller = Task { @MainActor in try await service.render(element, environment: Self.environment, baseURL: nil, host: host) }
        caller.cancel()
        let outcome = await caller.result
        _ = await blocker.result
        let key = service.key(element, environment: Self.environment, baseURL: nil)
        for _ in 0..<50 where service.cached(key) == nil { try await Task.sleep(for: .milliseconds(20)) }
        print("LIFECYCLE already cancelled: \(String(describing: outcome.map(\.size))) cached \(service.cached(key) != nil)")
        #expect(service.cached(key) == nil, "the render of an already cancelled caller ran anyway")
    }

    /// A caller arriving just after an earlier request for the same content was cancelled must get a
    /// render, not the earlier caller's cancellation.
    @Test func requestAfterACancelledShareStillRenders() async throws {
        let (window, host) = Self.window()
        defer { window.close() }
        let service = RenderService()
        let blocker = Task { @MainActor in try await service.render(Self.slowDiagram(200, salt: 21), environment: Self.environment, baseURL: nil, host: host) }
        let shared = RenderElement(span: SourceSpan(0, 1), kind: .mermaid, content: "graph LR\nLate-->Joiner")
        let early = Task { @MainActor in try await service.render(shared, environment: Self.environment, baseURL: nil, host: host) }
        try await Task.sleep(for: .milliseconds(20))
        let key = service.key(shared, environment: Self.environment, baseURL: nil)
        #expect(service.waiterCount(for: key) == 1)
        early.cancel()
        // Wait until the cancellation has been processed: the entry is still pending, its work cancelled,
        // and no one is waiting. The later request then joins that entry and must still get a render.
        for _ in 0..<100 where service.waiterCount(for: key) != 0 { await Task.yield() }
        #expect(service.waiterCount(for: key) == 0)
        let rendered = service.renderedCount
        let late = await Self.within(20) { try await service.render(shared, environment: Self.environment, baseURL: nil, host: host) }
        _ = await blocker.result
        print("LIFECYCLE late joiner: \(String(describing: late.map { $0.map(\.size) })) renders \(service.renderedCount - rendered)")
        guard case .success = late else { Issue.record("the later request failed: \(String(describing: late))"); return }
    }

    /// Many distinct formulas at once, as a long document scrolled quickly produces.
    @Test func manyConcurrentRequestsAllComplete() async throws {
        let (window, host) = Self.window()
        defer { window.close() }
        let service = RenderService()
        let tasks = (0..<40).map { index in
            Task { @MainActor in (try? await service.render(Self.math("x_{\(index)}"), environment: Self.environment, baseURL: nil, host: host)) != nil }
        }
        let results = await Self.within(60) {
            var succeeded = 0
            for task in tasks where await task.value { succeeded += 1 }
            return succeeded
        }
        print("LIFECYCLE concurrent: \(String(describing: results.map { $0.map { "\($0) of 40" } }))")
        guard case .success(let succeeded) = results else { Issue.record("concurrent renders did not finish"); return }
        #expect(succeeded == 40)
    }

    /// More elements on screen than the editor renders at once: each finished render frees a slot for the
    /// next, so every element renders without scrolling or another layout pass, each exactly once.
    @Test func elementsBeyondTheInFlightLimitRenderWithoutScrolling() async throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let count = 30
        // One paragraph, so the whole run lies within the fragment at the top of the viewport.
        let source = (0..<count).map { "![swatch \($0)](swatch.png)" }.joined(separator: "\n") + "\n"
        let editor = EditorController(source: source)
        editor.fileURL = repository.appendingPathComponent("Fixtures/Showcase.md")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = editor; window.orderFront(nil)
        defer { window.orderOut(nil) }
        editor.view.frame = NSRect(x: 0, y: 0, width: 800, height: 600); editor.view.layoutSubtreeIfNeeded()
        for _ in 0..<250 where editor.parsed.elements.count < count { try await Task.sleep(for: .milliseconds(20)) }
        try #require(editor.parsed.elements.count == count)
        editor.viewDidAppear()
        for _ in 0..<250 where editor.renderedElementCount + editor.renderErrorCount < count { try await Task.sleep(for: .milliseconds(20)) }
        print("LIFECYCLE beyond in-flight limit: rendered \(editor.renderedElementCount) of \(count), requests \(editor.renderRequestCount), errors \(editor.renderErrorCount)")
        #expect(editor.renderedElementCount == count)
        #expect(editor.renderErrorCount == 0)
        #expect(editor.renderRequestCount == count, "each element is requested once")
        #expect(editor.pendingRenderCount == 0)
        // Again from a known start: one request fills the slots, and completions drain the rest in turn.
        editor.releaseAllPixels()
        editor.requestRenders()
        #expect(editor.pendingRenderCount == 12)
        var inFlight = editor.pendingRenderCount
        for _ in 0..<250 where editor.renderedElementCount < count {
            await Task.yield()
            inFlight = max(inFlight, editor.pendingRenderCount)
        }
        for _ in 0..<50 where editor.renderedElementCount < count { try await Task.sleep(for: .milliseconds(20)) }
        print("LIFECYCLE refill after release: rendered \(editor.renderedElementCount) of \(count), requests \(editor.renderRequestCount - count), max in flight \(inFlight)")
        #expect(editor.renderedElementCount == count)
        #expect(editor.renderRequestCount == 2 * count, "each element is requested once more")
        #expect(inFlight <= 12)
        #expect(editor.pendingRenderCount == 0)
    }

    /// A render that starts while its window is minimized is postponed, not recorded as a failure.
    @Test func minimizedWindowPostponesInsteadOfFailing() async throws {
        let (window, host) = Self.window()
        defer { window.close() }
        let service = RenderService()
        window.miniaturize(nil)
        for _ in 0..<50 where !window.isMiniaturized { try await Task.sleep(for: .milliseconds(20)) }
        try #require(window.isMiniaturized, "this environment cannot minimize a window")
        let outcome = await Self.within(15) { try await service.render(Self.math("y^2"), environment: Self.environment, baseURL: nil, host: host) }
        print("LIFECYCLE minimized: \(String(describing: outcome.map { $0.map(\.size) }))")
        guard case .failure(let error) = outcome else { Issue.record("expected the render to be postponed, got \(String(describing: outcome))"); return }
        #expect(error as? RenderFailure == .suspended, "a minimized window is not a rendering error: \(error)")
        window.deminiaturize(nil)
        for _ in 0..<50 where window.isMiniaturized { try await Task.sleep(for: .milliseconds(20)) }
        let restored = await Self.within(15) { try await service.render(Self.math("y^2"), environment: Self.environment, baseURL: nil, host: host) }
        guard case .success = restored else { Issue.record("render after restoring the window: \(String(describing: restored))"); return }
    }

    /// Typing elsewhere must not resubmit a formula that already failed to parse.
    @Test func failedElementIsNotRetriedByUnrelatedEdits() async throws {
        let source = "$\\frac{$ bad\n\ntext\n"
        let editor = EditorController(source: source)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = editor; window.orderFront(nil)
        defer { window.orderOut(nil) }
        editor.view.frame = NSRect(x: 0, y: 0, width: 800, height: 600); editor.view.layoutSubtreeIfNeeded(); editor.viewDidAppear()
        for _ in 0..<250 where editor.renderErrorCount == 0 { try await Task.sleep(for: .milliseconds(20)) }
        try #require(editor.renderErrorCount == 1)
        // Counted on this editor: other suites share RenderService.shared and run in parallel.
        let attempts = editor.renderRequestCount
        for index in 0..<3 {
            editor.performEdit(range: NSRange(location: editor.source.utf16.count, length: 0), replacement: "z\(index)")
            for _ in 0..<100 where editor.parsed.revision != editor.revision { try await Task.sleep(for: .milliseconds(20)) }
            try await Task.sleep(for: .milliseconds(300))
        }
        print("LIFECYCLE failed element requests: \(editor.renderRequestCount - attempts), errors \(editor.renderErrorCount)")
        #expect(editor.renderRequestCount == attempts)
        #expect(editor.renderErrorCount == 1)
    }
}

