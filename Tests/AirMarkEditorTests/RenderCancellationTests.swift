import AppKit
import Testing
import AirMarkCore
@testable import AirMarkEditor
@testable import AirMarkRender

/// Whether a render that is already running when its callers stop waiting should keep the renderer
/// busy. Printed timings are observations on the selected build configuration, not budgets.
@Suite(.serialized) @MainActor struct RenderCancellationTests {
    typealias Lifecycle = RenderLifecycleTests
    static let environment = Lifecycle.environment
    static func ms(_ duration: Duration) -> Double { Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15 }
    static func summary(_ samples: [Double]) -> String {
        let sorted = samples.sorted()
        return String(format: "p50=%.0fms max=%.0fms all=%@", sorted[(sorted.count - 1) / 2], sorted.last ?? 0, samples.map { String(format: "%.0f", $0) }.joined(separator: ","))
    }
    static func small(_ salt: Int) -> RenderElement {
        RenderElement(span: SourceSpan(0, 1), kind: .mermaid, content: "graph LR\n  Small\(salt) --> Wanted")
    }
    /// A top-to-bottom diagram whose edges cross between 70 nodes; Mermaid lays it out in over a second.
    static func denseDiagram(salt: Int) -> RenderElement {
        var state: UInt64 = 0x9E3779B97F4A7C15
        func next() -> Int { state = state &* 6364136223846793005 &+ 1442695040888963407; return Int(state >> 33) % 70 }
        let edges = (0..<490).map { _ in "N\(next())[Node \(salt)] --> N\(next())" }.joined(separator: "\n")
        return RenderElement(span: SourceSpan(0, 1), kind: .mermaid, content: "graph TD\n" + edges)
    }
    /// A display formula that takes KaTeX a while: a large matrix.
    static func slowFormula(_ size: Int, salt: Int) -> RenderElement {
        let rows = (0..<size).map { row in (0..<size).map { "x_{\(row),\($0)}^{\(salt)}" }.joined(separator: " & ") }.joined(separator: " \\\\ ")
        return RenderElement(span: SourceSpan(0, 1), kind: .math, content: "\\begin{bmatrix}" + rows + "\\end{bmatrix}", inline: false)
    }
    /// Waits until `renderer` is performing a job, then a further `delay`.
    static func waitUntilRunning(_ renderer: WebRenderer, then delay: Duration = .milliseconds(40)) async throws {
        for _ in 0..<1000 where renderer.current == nil { try await Task.sleep(for: .milliseconds(2)) }
        try #require(renderer.current != nil, "the render never started")
        try await Task.sleep(for: delay)
    }

    /// A left-to-right chain of `nodes`, or the dense diagram for 0.
    static func diagram(_ nodes: Int, salt: Int) -> String {
        nodes == 0 ? denseDiagram(salt: salt).content : Lifecycle.slowDiagram(nodes, salt: salt).content
    }
    /// An editor showing one diagram between two paragraphs, laid out in a visible window.
    static func editor(diagram: String) async throws -> (EditorController, NSWindow) {
        _ = NSApplication.shared
        let source = "Intro paragraph.\n\n```mermaid\n\(diagram)\n```\n\nClosing paragraph.\n"
        let editor = EditorController(source: source)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = editor; window.orderFront(nil)
        editor.view.frame = NSRect(x: 0, y: 0, width: 800, height: 600); editor.view.layoutSubtreeIfNeeded()
        for _ in 0..<250 where editor.parsed.elements.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        try #require(editor.parsed.elements.count == 1)
        return (editor, window)
    }

    /// Service level. A diagram or formula starts rendering, its only caller gives up, and a different
    /// element is requested at once. Reports how long the wanted element takes, next to the running
    /// job's time alone and a fresh page's first render (the cost of replacing a page).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AIRMARK_RENDER_CANCEL_MEASURE"] == "1"))
    func obsoleteRunningJobDelaysTheNextRender() async throws {
        let (window, host) = Lifecycle.window()
        defer { window.close() }
        let clock = ContinuousClock()
        var fresh: [Double] = [], warm: [Double] = []
        for index in 0..<5 {
            let service = RenderService()
            var start = clock.now
            _ = try await service.render(Self.small(1000 + index), environment: Self.environment, baseURL: nil, host: host)
            fresh.append(Self.ms(start.duration(to: clock.now)))
            start = clock.now
            _ = try await service.render(Self.small(2000 + index), environment: Self.environment, baseURL: nil, host: host)
            warm.append(Self.ms(start.duration(to: clock.now)))
        }
        print("CANCEL_MEASURE page mermaid first=\(Self.summary(fresh)) warm=\(Self.summary(warm))")

        var salt = 10_000
        for (label, slow) in [("mermaid-100", { Lifecycle.slowDiagram(100, salt: $0) }), ("mermaid-250", { Lifecycle.slowDiagram(250, salt: $0) }),
                              ("mermaid-480", { Lifecycle.slowDiagram(480, salt: $0) }), ("mermaid-dense", { Self.denseDiagram(salt: $0) }), ("katex-12", { Self.slowFormula(12, salt: $0) }),
                              ("katex-30", { Self.slowFormula(30, salt: $0) })] as [(String, (Int) -> RenderElement)] {
            let service = RenderService()
            let isMath = label.hasPrefix("katex")
            let renderer = isMath ? service.math : service.mermaid
            let wanted: (Int) -> RenderElement = isMath ? { Lifecycle.math("w_{\($0)}") } : { Self.small($0) }
            _ = try await service.render(wanted(salt), environment: Self.environment, baseURL: nil, host: host); salt += 1
            var alone: [Double] = [], next: [Double] = [], nextIdle: [Double] = [], wasted = 0, loads = 0
            for _ in 0..<5 {
                var start = clock.now
                let artifact = try await service.render(slow(salt), environment: Self.environment, baseURL: nil, host: host); salt += 1
                alone.append(Self.ms(start.duration(to: clock.now)))
                start = clock.now
                _ = try await service.render(wanted(salt), environment: Self.environment, baseURL: nil, host: host); salt += 1
                nextIdle.append(Self.ms(start.duration(to: clock.now)))
                #expect(artifact.size.width > 0)

                let obsolete = slow(salt); salt += 1
                let caller = Task { @MainActor in try await service.render(obsolete, environment: Self.environment, baseURL: nil, host: host) }
                try await Self.waitUntilRunning(renderer, then: .milliseconds(isMath ? 1 : 40))
                let loadsBefore = renderer.loadCount
                caller.cancel()
                start = clock.now
                let outcome = await Lifecycle.within(20) { try await service.render(wanted(salt), environment: Self.environment, baseURL: nil, host: host) }
                salt += 1
                next.append(Self.ms(start.duration(to: clock.now)))
                guard case .success = outcome else { Issue.record("\(label) wanted render: \(String(describing: outcome))"); return }
                for _ in 0..<100 where renderer.current != nil { try await Task.sleep(for: .milliseconds(20)) }
                if service.cached(service.key(obsolete, environment: Self.environment, baseURL: nil)) != nil { wasted += 1 }
                loads += renderer.loadCount - loadsBefore
            }
            print("CANCEL_MEASURE \(label) alone=\(Self.summary(alone)) next_idle=\(Self.summary(nextIdle)) next_after_obsolete=\(Self.summary(next)) obsolete_finished=\(wasted)/5 page_loads=\(loads)")
        }
    }

    /// Editor level. While a diagram renders, (a) its source is edited, so the running render is for
    /// content that no longer exists; (b) text elsewhere is typed, so the running render is still
    /// wanted and every keystroke cancels and re-requests it. (a) reports time from the edit to the
    /// new diagram's pixels; (b) time from the first keystroke to the unchanged diagram's pixels.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AIRMARK_RENDER_CANCEL_MEASURE"] == "1"))
    func editorEditsDuringARunningRender() async throws {
        let clock = ContinuousClock()
        let renderer = RenderService.shared.mermaid
        var salt = 50_000
        for nodes in [250, 480, 0] {
            var edited: [Double] = [], typedSlow: [Double] = [], typedFast: [Double] = []
            var editLoads = 0, slowLoads = 0, fastLoads = 0
            for _ in 0..<5 {
                // (a) Edit inside the diagram 40ms into its render.
                do {
                    let (editor, window) = try await Self.editor(diagram: Self.diagram(nodes, salt: salt)); salt += 1
                    defer { window.orderOut(nil) }
                    editor.viewDidAppear()
                    try await Self.waitUntilRunning(renderer)
                    let loads = renderer.loadCount
                    let label = (editor.source as NSString).range(of: "[Node ")
                    let start = clock.now
                    editor.performEdit(range: NSRange(location: label.location + 1, length: 0), replacement: "Edited ")
                    for _ in 0..<1000 where editor.renderedElementCount == 0 { try await Task.sleep(for: .milliseconds(2)) }
                    edited.append(Self.ms(start.duration(to: clock.now)))
                    #expect(editor.renderedElementCount == 1)
                    editLoads += renderer.loadCount - loads
                }
                // (b) Type at the end every `interval` from 40ms into the render until the diagram shows.
                for interval in [100, 30] {
                    let (editor, window) = try await Self.editor(diagram: Self.diagram(nodes, salt: salt)); salt += 1
                    defer { window.orderOut(nil) }
                    editor.viewDidAppear()
                    try await Self.waitUntilRunning(renderer)
                    let loads = renderer.loadCount
                    let start = clock.now
                    for _ in 0..<(8000 / interval) where editor.renderedElementCount == 0 {
                        editor.performEdit(range: NSRange(location: editor.textView.textStorage!.length, length: 0), replacement: "x")
                        let next = clock.now + .milliseconds(interval)
                        while clock.now < next && editor.renderedElementCount == 0 { try await Task.sleep(for: .milliseconds(2)) }
                    }
                    let elapsed = Self.ms(start.duration(to: clock.now))
                    #expect(editor.renderedElementCount == 1, "the unchanged diagram never showed while typing every \(interval)ms")
                    if interval == 100 { typedSlow.append(elapsed); slowLoads += renderer.loadCount - loads } else { typedFast.append(elapsed); fastLoads += renderer.loadCount - loads }
                }
            }
            print("CANCEL_MEASURE editor diagram=\(nodes == 0 ? "dense" : "lr-\(nodes)") edit_diagram=\(Self.summary(edited)) loads=\(editLoads) | type_elsewhere_100ms=\(Self.summary(typedSlow)) loads=\(slowLoads) | type_elsewhere_30ms=\(Self.summary(typedFast)) loads=\(fastLoads)")
        }
    }
}

/// Part of the lifecycle suite so these renders, which start content processes, never run alongside its
/// process accounting.
extension RenderLifecycleTests {
    typealias C = RenderCancellationTests

    /// A long render whose only caller left gives way to a job that is waiting: its page is replaced and
    /// the waiting job starts at once instead of after the obsolete render.
    @Test func obsoleteRunningRenderYieldsToAWaitingJob() async throws {
        let (window, host) = Self.window()
        defer { window.close() }
        let service = RenderService()
        _ = try await service.render(C.small(1), environment: Self.environment, baseURL: nil, host: host)
        let loads = service.mermaid.loadCount
        let obsolete = C.denseDiagram(salt: 1)
        let caller = Task { @MainActor in try await service.render(obsolete, environment: Self.environment, baseURL: nil, host: host) }
        try await C.waitUntilRunning(service.mermaid, then: .milliseconds(200))
        caller.cancel()
        let clock = ContinuousClock(), start = clock.now
        let wanted = await Self.within(20) { try await service.render(C.small(2), environment: Self.environment, baseURL: nil, host: host) }
        let elapsed = start.duration(to: clock.now)
        guard case .success = wanted else { Issue.record("wanted render: \(String(describing: wanted))"); return }
        let cancelled = await caller.result
        for _ in 0..<100 where service.mermaid.current != nil { try await Task.sleep(for: .milliseconds(20)) }
        print("CANCEL obsolete yields: wanted after \(elapsed), loads \(service.mermaid.loadCount - loads), obsolete cached \(service.cached(service.key(obsolete, environment: Self.environment, baseURL: nil)) != nil)")
        #expect((try? cancelled.get()) == nil)
        #expect(service.cached(service.key(obsolete, environment: Self.environment, baseURL: nil)) == nil, "the obsolete render ran to completion")
        #expect(service.mermaid.loadCount == loads + 1, "the page running the obsolete render should have been replaced once")
        // Asked for again later, the abandoned element renders from scratch.
        let again = await Self.within(20) { try await service.render(obsolete, environment: Self.environment, baseURL: nil, host: host) }
        guard case .success = again else { Issue.record("abandoned element asked again: \(String(describing: again))"); return }
    }

    /// Another caller still waits on the running render: one caller leaving must not abandon it, even
    /// with a job waiting behind it.
    @Test func runningRenderSharedWithAnotherCallerKeepsRunning() async throws {
        let (window, host) = Self.window()
        defer { window.close() }
        let service = RenderService()
        _ = try await service.render(C.small(3), environment: Self.environment, baseURL: nil, host: host)
        let loads = service.mermaid.loadCount
        let shared = C.denseDiagram(salt: 3)
        let leaving = Task { @MainActor in try await service.render(shared, environment: Self.environment, baseURL: nil, host: host) }
        let staying = Task { @MainActor in try await service.render(shared, environment: Self.environment, baseURL: nil, host: host) }
        try await C.waitUntilRunning(service.mermaid, then: .milliseconds(200))
        leaving.cancel()
        let key = service.key(shared, environment: Self.environment, baseURL: nil)
        for _ in 0..<100 where service.waiterCount(for: key) != 1 { await Task.yield() }
        let behind = Task { @MainActor in try await service.render(C.small(4), environment: Self.environment, baseURL: nil, host: host) }
        let outcome = await Self.within(20) { try await staying.value }
        let next = await Self.within(20) { try await behind.value }
        print("CANCEL shared: staying \(String(describing: outcome.map { $0.map(\.size) })), behind \(String(describing: next.map { $0.map(\.size) })), loads \(service.mermaid.loadCount - loads)")
        guard case .success = outcome else { Issue.record("the remaining caller lost the shared render: \(String(describing: outcome))"); return }
        guard case .success = next else { Issue.record("the job behind it: \(String(describing: next))"); return }
        #expect(service.mermaid.loadCount == loads)
        #expect(service.cached(key) != nil)
    }

    /// Typing elsewhere cancels every render and asks for the unchanged ones again once the parse lands.
    /// A caller that rejoins a running render before another job arrives keeps it running.
    @Test func runningRenderRejoinedBeforeAnotherJobKeepsRunning() async throws {
        let (window, host) = Self.window()
        defer { window.close() }
        let service = RenderService()
        _ = try await service.render(C.small(5), environment: Self.environment, baseURL: nil, host: host)
        let loads = service.mermaid.loadCount
        let element = C.denseDiagram(salt: 5)
        let key = service.key(element, environment: Self.environment, baseURL: nil)
        let first = Task { @MainActor in try await service.render(element, environment: Self.environment, baseURL: nil, host: host) }
        try await C.waitUntilRunning(service.mermaid, then: .milliseconds(200))
        first.cancel()
        _ = await first.result
        for _ in 0..<100 where service.waiterCount(for: key) != 0 { await Task.yield() }
        try #require(service.waiterCount(for: key) == 0)
        // Longer than a parse takes to land after a keystroke.
        try await Task.sleep(for: .milliseconds(60))
        let rejoined = Task { @MainActor in try await service.render(element, environment: Self.environment, baseURL: nil, host: host) }
        await Task.yield()
        let other = Task { @MainActor in try await service.render(C.small(6), environment: Self.environment, baseURL: nil, host: host) }
        let outcome = await Self.within(20) { try await rejoined.value }
        let next = await Self.within(20) { try await other.value }
        print("CANCEL rejoined: \(String(describing: outcome.map { $0.map(\.size) })), other \(String(describing: next.map { $0.map(\.size) })), loads \(service.mermaid.loadCount - loads)")
        guard case .success = outcome else { Issue.record("the rejoined render: \(String(describing: outcome))"); return }
        guard case .success = next else { Issue.record("the job behind it: \(String(describing: next))"); return }
        #expect(service.mermaid.loadCount == loads, "the rejoined render was abandoned and its page replaced")
    }

    /// Replacing a page costs about as much as a small render, so a render that has run only briefly
    /// finishes even when its caller left and another job waits.
    @Test func briefRunningRenderFinishes() async throws {
        let (window, host) = Self.window()
        defer { window.close() }
        let service = RenderService()
        _ = try await service.render(Self.math("warm"), environment: Self.environment, baseURL: nil, host: host)
        let loads = service.math.loadCount
        let element = C.slowFormula(6, salt: 7)
        let caller = Task { @MainActor in try await service.render(element, environment: Self.environment, baseURL: nil, host: host) }
        try await C.waitUntilRunning(service.math, then: .zero)
        caller.cancel()
        let next = await Self.within(20) { try await service.render(Self.math("n_7"), environment: Self.environment, baseURL: nil, host: host) }
        guard case .success = next else { Issue.record("the next formula: \(String(describing: next))"); return }
        let key = service.key(element, environment: Self.environment, baseURL: nil)
        for _ in 0..<50 where service.cached(key) == nil { try await Task.sleep(for: .milliseconds(20)) }
        print("CANCEL brief: loads \(service.math.loadCount - loads), cached \(service.cached(key) != nil)")
        #expect(service.math.loadCount == loads)
        #expect(service.cached(key) != nil, "a brief render was abandoned")
    }
}
