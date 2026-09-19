import AppKit
import Testing
import AirMarkCore
@testable import AirMarkEditor

/// Sustained typing in a large document, measured to the point the typed text is drawn, which the
/// other benchmarks stop short of: `ScaleTests` times `performEdit` alone, and `ParsePacingBench`
/// ends at the parse being installed. Enabled by `AIRMARK_TYPING_BYTES`:
///
///     AIRMARK_TYPING_BYTES=1000000 swift test -c release --disable-sandbox --filter TypingLatencyBench
///
/// `AIRMARK_TYPING_SECONDS` (10), `AIRMARK_TYPING_INTERVAL_MS` (50), `AIRMARK_TYPING_PROSE=1` for a
/// document with nothing to render, `AIRMARK_TYPING_OUT` for the samples as JSON.
///
/// Keys go through `NSTextView.insertText` and `insertNewline`, the path a key event takes after the
/// input context, so undo grouping, spell checking and the document's change callbacks all run. It is
/// not HID input and no input method composes. Between keys the test sleeps, which hands the main
/// thread back to its run loop, so AppKit lays out, draws and commits as it does in the app. (Running
/// the run loop from inside the test does not work: the test is itself a block on the main queue, and
/// nothing else on that queue, a finished parse included, runs until it returns.) Per key, from just
/// before the key is handed over:
///
/// - `returned`: the insert call came back; the synchronous cost `ScaleTests` measures.
/// - `drawn`: TextKit drew the layout fragment that holds the key. Seen from the fragment itself, which
///   the text view draws through, so it is the real display pass and not a layout forced by the test.
/// - `committed`: the run loop turn that drew it reached its end, after Core Animation's commit. What
///   remains to the glass is the window server and the display, which a process cannot time.
/// - `styled`: a parse of text that includes the key was installed.
///
/// `stall` is how long a block posted to the main queue waited, posted again a millisecond after each
/// one ran: the delay an event arriving at that moment would have seen. Its maximum is the longest the
/// main thread went without taking anything new, whatever held it.
///
/// A window that is occluded, as on a locked or unattended screen, is not drawn; the run then reports
/// how many keys were drawn and the figures for the rest are missing, not zero.
@Suite(.serialized) @MainActor struct TypingLatencyBench {
    enum Env {
        static let values = ProcessInfo.processInfo.environment
        static let bytes = Int(values["AIRMARK_TYPING_BYTES"] ?? "") ?? 0
        static let seconds = Double(values["AIRMARK_TYPING_SECONDS"] ?? "") ?? 10
        static let interval = Double(values["AIRMARK_TYPING_INTERVAL_MS"] ?? "") ?? 50
        static let prose = values["AIRMARK_TYPING_PROSE"] == "1"
        static let out = values["AIRMARK_TYPING_OUT"]
    }

    /// Draws as the fragment it replaces does, and says so.
    final class ObservedFragment: NSTextLayoutFragment {
        nonisolated(unsafe) static var onDraw: ((NSTextLayoutFragment) -> Void)?
        override func draw(at point: CGPoint, in context: CGContext) {
            super.draw(at: point, in: context)
            Self.onDraw?(self)
        }
    }
    final class FragmentObserver: NSObject, NSTextLayoutManagerDelegate {
        func textLayoutManager(_ manager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation, in element: NSTextElement) -> NSTextLayoutFragment {
            ObservedFragment(textElement: element, range: element.elementRange)
        }
    }

    /// Posts a block to the main queue, waits for it to run, rests a millisecond, and again.
    final class StallProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var waits: [Double] = [], running = true
        func start() {
            let thread = Thread { [self] in
                let clock = ContinuousClock(), ran = DispatchSemaphore(value: 0)
                while lock.withLock({ running }) {
                    let posted = clock.now
                    DispatchQueue.main.async { ran.signal() }
                    ran.wait()
                    let waited = TypingLatencyBench.ms(posted.duration(to: clock.now))
                    lock.withLock { waits.append(waited) }
                    Thread.sleep(forTimeInterval: 0.001)
                }
            }
            thread.qualityOfService = .userInteractive
            thread.start()
        }
        /// The waits since the last call.
        func take() -> [Double] { lock.withLock { defer { waits.removeAll() }; return waits } }
        func stop() { lock.withLock { running = false } }
    }

    static func ms(_ value: Duration) -> Double { Double(value.components.seconds) * 1000 + Double(value.components.attoseconds) / 1e15 }
    /// Nearest-rank percentiles and the maximum; "-" when nothing was measured.
    static func summary(_ values: [Double]) -> String {
        guard !values.isEmpty else { return "-" }
        let sorted = values.sorted()
        func rank(_ fraction: Double) -> Double { sorted[max(0, Int(ceil(Double(sorted.count) * fraction)) - 1)] }
        return String(format: "p50=%.2f p95=%.2f p99=%.2f max=%.2f", rank(0.5), rank(0.95), rank(0.99), sorted.last!)
    }
    static func proseSource(bytes: Int) -> String {
        let block = "## Heading\n\nA paragraph with **bold**, *emphasis*, [link](https://example.org) and 한글. Plain words follow it here.\n\n- [ ] Task\n\n"
        return String(repeating: block, count: bytes / block.utf8.count + 1)
    }

    @Test(.enabled(if: Env.bytes > 0)) func sustainedTyping() async throws {
        _ = NSApplication.shared
        let source = Env.prose ? Self.proseSource(bytes: Env.bytes) : ScaleTests.source(bytes: Env.bytes)
        let document = MarkdownDocument()
        document.snapshot.set(DocumentBytes(source: source, hasBOM: false))
        document.makeWindowControllers()
        defer { document.close() }
        let editor = try #require(document.editor), view = editor.textView
        let window = try #require(view.window)
        window.setFrame(NSRect(x: 80, y: 80, width: 880, height: 760), display: false)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        let manager = try #require(view.textLayoutManager), content = try #require(manager.textContentManager)
        let observer = FragmentObserver()
        manager.delegate = observer
        defer { manager.delegate = nil; ObservedFragment.onDraw = nil }

        let clock = ContinuousClock()
        func settle() async throws {
            for _ in 0..<4_000 where editor.parsed.revision != editor.revision || editor.parsed.styles.isEmpty { try await Task.sleep(for: .milliseconds(25)) }
            try await Task.sleep(for: .seconds(2))
        }

        struct Key { var at: ContinuousClock.Instant; var location: Int; var revision: UInt64; var returned = 0.0; var drawn: Double?; var committed: Double?; var styled: Double? }
        var keys: [Key] = []
        var undrawn = 0, uncommitted = 0, unstyled = 0
        ObservedFragment.onDraw = { fragment in
            MainActor.assumeIsolated {
                guard undrawn < keys.count else { return }
                let now = clock.now, start = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
                let end = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.endLocation)
                // Keys are in order and typed at one caret, so the ones this fragment shows are a prefix of those waiting.
                while undrawn < keys.count, keys[undrawn].location >= start, keys[undrawn].location <= end {
                    keys[undrawn].drawn = Self.ms(keys[undrawn].at.duration(to: now)); undrawn += 1
                }
            }
        }
        // After Core Animation's own observer (order 2,000,000), so the turn's commit is behind it.
        let commits = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 3_000_000) { _, _ in
            MainActor.assumeIsolated {
                let now = clock.now
                while uncommitted < undrawn { keys[uncommitted].committed = Self.ms(keys[uncommitted].at.duration(to: now)); uncommitted += 1 }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), commits, .commonModes)
        defer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), commits, .commonModes) }
        editor.onParseApplied = {
            let now = clock.now
            while unstyled < keys.count, keys[unstyled].revision <= editor.presentationRevision {
                keys[unstyled].styled = Self.ms(keys[unstyled].at.duration(to: now)); unstyled += 1
            }
        }
        let probe = StallProbe()
        probe.start()
        defer { probe.stop() }

        let words = Array("plain words typed at a steady pace into one paragraph ")
        var samples: [[String: Any]] = []
        for (name, fraction) in [("head", 0.0), ("middle", 0.5), ("tail", 1.0)] {
            try await settle()
            let text = view.textStorage!.mutableString
            let target = min(text.length - 1, Int(Double(text.length) * fraction))
            let search = fraction == 1 ? NSRange(location: 0, length: text.length) : NSRange(location: target, length: text.length - target)
            let paragraph = text.range(of: "A paragraph with", options: fraction == 1 ? .backwards : [], range: search)
            let caret = paragraph.location + 11
            view.setSelectedRange(NSRange(location: caret, length: 0))
            view.scrollRangeToVisible(NSRange(location: caret, length: 0))
            editor.viewportDidChange()
            try await settle()
            keys.removeAll(); undrawn = 0; uncommitted = 0; unstyled = 0
            _ = probe.take()
            let lengthBefore = text.length

            let count = Int(Env.seconds * 1000 / Env.interval)
            var deadline = clock.now
            for number in 0..<count {
                try await clock.sleep(until: deadline)
                deadline = deadline + .milliseconds(Env.interval)
                let location = view.selectedRange().location
                let started = clock.now
                keys.append(Key(at: started, location: location, revision: 0))
                // A Return now and then: it splits the paragraph, which a letter never does.
                if number % 40 == 39 { view.insertNewline(nil) } else { view.insertText(String(words[number % words.count]), replacementRange: NSRange(location: NSNotFound, length: 0)) }
                keys[keys.count - 1].returned = Self.ms(started.duration(to: clock.now))
                keys[keys.count - 1].revision = editor.revision
            }
            // Let the last keys reach the screen and their parse land.
            try await settle()
            let stalls = probe.take()
            // Every key arrived, as one character each.
            #expect(keys.count == count && text.length == lengthBefore + count)
            let drawn = keys.compactMap(\.drawn), committed = keys.compactMap(\.committed), styled = keys.compactMap(\.styled)
            let occluded = !window.occlusionState.contains(.visible)
            print(String(format: "TYPING bytes=%d %@ position=%@ keys=%d interval=%.0fms drawn=%d%@", source.utf8.count, Env.prose ? "prose" : "elements", name, keys.count, Env.interval, drawn.count, occluded ? " WINDOW-OCCLUDED" : ""))
            print("TYPING   returned  \(Self.summary(keys.map(\.returned)))")
            print("TYPING   drawn     \(Self.summary(drawn))")
            print("TYPING   committed \(Self.summary(committed))")
            print("TYPING   styled    \(Self.summary(styled))")
            print("TYPING   stall     \(Self.summary(stalls)) over8.3ms=\(stalls.filter { $0 > 8.3 }.count) over16.7ms=\(stalls.filter { $0 > 16.7 }.count) probes=\(stalls.count)")
            samples.append(["position": name, "bytes": source.utf8.count, "prose": Env.prose, "interval_ms": Env.interval, "occluded": occluded,
                            "returned_ms": keys.map(\.returned), "drawn_ms": keys.map { $0.drawn ?? -1 }, "committed_ms": keys.map { $0.committed ?? -1 },
                            "styled_ms": keys.map { $0.styled ?? -1 }, "stall_ms": stalls])
        }
        #expect(editor.textKitFallbackCount == 0)
        if let out = Env.out { try JSONSerialization.data(withJSONObject: samples, options: [.sortedKeys]).write(to: URL(fileURLWithPath: out)) }
    }
}
