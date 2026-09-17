import AppKit
import Testing
import AirMarkCore
@testable import AirMarkEditor

/// Parse pacing benchmark, identical on both branches under comparison. Runs only when
/// PACING_BYTES is set. Every keystroke goes through `performEdit` on a `MarkdownDocument` whose
/// window is on screen, so the document snapshot, viewport restyle and parse application all run
/// as in the app. A key's latency is the time from the key to the first applied parse whose
/// revision includes it (an applied parse always carries the editor's current revision).
@Suite(.serialized) @MainActor struct ParsePacingBench {
    struct Env {
        static let values = ProcessInfo.processInfo.environment
        static var bytes: Int { Int(values["PACING_BYTES"] ?? "") ?? 0 }
        static var scenarios: Set<String> { Set((values["PACING_SCENARIOS"] ?? "idle,slow,bursts,sustained").split(separator: ",").map(String.init)) }
        static var out: String? { values["PACING_OUT"] }
        static var runLabel: String { values["PACING_LABEL"] ?? "run" }
    }

    /// Deterministic 200–400ms gaps, the same sequence on every branch.
    struct LCG { var state: UInt64; mutating func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state >> 33 } }

    final class Log {
        var applies: [(at: ContinuousClock.Instant, revision: UInt64)] = []
    }

    static func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
    static func pct(_ v: [Double], _ p: Double) -> Double {
        guard !v.isEmpty else { return .nan }
        let s = v.sorted(); return s[max(0, Int(ceil(Double(s.count) * p)) - 1)]
    }
    static func summary(_ v: [Double]) -> String { String(format: "n=%d p50=%.0f p95=%.0f max=%.0f", v.count, pct(v, 0.5), pct(v, 0.95), v.max() ?? .nan) }

    @Test(.enabled(if: Env.bytes > 0)) func parsePacing() async throws {
        _ = NSApplication.shared
        let bytes = Env.bytes
        let large = bytes >= 5_000_000
        let source = ScaleTests.source(bytes: bytes)
        let clock = ContinuousClock()

        // Standalone parse + presentation cost of this fixture, off the main actor.
        var parseCosts: [Double] = []
        for _ in 0..<(large ? 3 : 5) {
            let d = await Task.detached { () -> Duration in
                let c = ContinuousClock(); let t = c.now
                let doc = MarkdownParser.parse(source, revision: 1); _ = PresentationStore(doc)
                return t.duration(to: c.now)
            }.value
            parseCosts.append(Self.ms(d))
        }

        let document = MarkdownDocument()
        document.snapshot.set(DocumentBytes(source: source, hasBOM: false))
        document.makeWindowControllers()
        let window = try #require(document.windowControllers.first?.window)
        window.orderFront(nil)
        defer { document.close() }
        let editor = try #require(document.editor)
        let log = Log()
        let previous = editor.onParseApplied
        editor.onParseApplied = { [editor] in previous?(); log.applies.append((clock.now, editor.presentationRevision)) }
        for _ in 0..<4800 where editor.parsed.revision != editor.revision || editor.parsed.styles.isEmpty {
            try await Task.sleep(for: .milliseconds(25))
        }
        try #require(editor.parsed.revision == editor.revision)
        let text = editor.textView.textStorage!.mutableString
        var results: [String: Any] = [
            "label": Env.runLabel, "bytes": source.utf8.count,
            "standalone_parse_ms": parseCosts,
        ]
        print(String(format: "PACING %@ bytes=%d standalone_parse %@", Env.runLabel, source.utf8.count, Self.summary(parseCosts)))

        func settle(timeout: Duration = .seconds(90)) async throws -> Duration {
            let start = clock.now
            while editor.parsed.revision != editor.revision, start.duration(to: clock.now) < timeout {
                try await Task.sleep(for: .milliseconds(1))
            }
            #expect(editor.parsed.revision == editor.revision)
            return start.duration(to: clock.now)
        }
        func idle(_ d: Duration) async throws { _ = try await settle(); try await Task.sleep(for: d) }
        /// Types one key per gap (the first key at once), waits for the parse of the final text, and
        /// returns per-key latencies and pacing counts.
        func type(gaps: [Duration], at paragraphOffset: Int) async throws -> [String: Any] {
            let parsesBefore = editor.parseCompletedCount, staleBefore = editor.staleParseCount
            let appliesBefore = log.applies.count
            var keys: [(at: ContinuousClock.Instant, revision: UInt64)] = []
            var deadline = clock.now
            for (n, gap) in gaps.enumerated() {
                deadline = deadline + gap
                if n > 0 { try await clock.sleep(until: deadline) }
                editor.performEdit(range: NSRange(location: paragraphOffset + n, length: 0), replacement: "x")
                keys.append((clock.now, editor.revision))
            }
            let last = keys.last!.at
            let settleTime = try await settle()
            let applies = Array(log.applies[appliesBefore...])
            let latencies = keys.map { key -> Double in
                let hit = applies.first { $0.revision >= key.revision }
                return hit.map { Self.ms(key.at.duration(to: $0.at)) } ?? -1
            }
            // Longest time with at least one typed key not yet shown by an applied parse.
            let settleMs = Self.ms(settleTime)
            let appliedGaps = zip([keys.first!.at] + applies.map(\.at), applies.map(\.at)).map { Self.ms($0.duration(to: $1)) }
            let actualGaps = zip(keys.dropLast(), keys.dropFirst()).map { Self.ms($0.at.duration(to: $1.at)) }
            return [
                "keys": keys.count, "latency_ms": latencies, "settle_ms": settleMs,
                "since_last_key_ms": Self.ms(last.duration(to: clock.now)),
                "parses": editor.parseCompletedCount - parsesBefore, "stale": editor.staleParseCount - staleBefore,
                "applied": applies.count, "apply_gaps_ms": appliedGaps,
                "key_gap_p50_ms": actualGaps.isEmpty ? 0 : Self.pct(actualGaps, 0.5), "key_gap_max_ms": actualGaps.max() ?? 0,
            ]
        }
        func middleOffset() -> Int { text.paragraphRange(for: NSRange(location: text.length / 2, length: 0)).location }
        var gapSeed = LCG(state: 0x5EED)

        if Env.scenarios.contains("idle") {
            var samples: [[String: Any]] = []
            for _ in 0..<(large ? 10 : 20) {
                try await idle(large ? .milliseconds(1500) : .milliseconds(1000))
                samples.append(try await type(gaps: [.zero], at: middleOffset()))
            }
            let lat = samples.map { ($0["latency_ms"] as! [Double])[0] }
            results["idle"] = samples
            print("PACING \(Env.runLabel) idle latency \(Self.summary(lat)) parses=\(samples.map { $0["parses"] as! Int }) stale=\(samples.map { $0["stale"] as! Int })")
        }
        if Env.scenarios.contains("slow") {
            try await idle(.seconds(1))
            var gaps: [Duration] = [.zero], total: Duration = .zero
            while total < .seconds(35) { let g = Duration.milliseconds(200 + Int(gapSeed.next() % 201)); gaps.append(g); total += g }
            let r = try await type(gaps: gaps, at: middleOffset())
            results["slow"] = r
            print(String(format: "PACING %@ slow(200-400ms, 35s) keys=%d latency %@ settle=%.0fms parses=%d stale=%d applied=%d max_apply_gap=%.0fms",
                         Env.runLabel, r["keys"] as! Int, Self.summary(r["latency_ms"] as! [Double]), r["settle_ms"] as! Double,
                         r["parses"] as! Int, r["stale"] as! Int, r["applied"] as! Int, (r["apply_gaps_ms"] as! [Double]).max() ?? 0))
        }
        if Env.scenarios.contains("bursts") {
            var bursts: [[String: Any]] = []
            for _ in 0..<(large ? 6 : 12) {
                try await idle(large ? .milliseconds(1500) : .milliseconds(1000))
                bursts.append(try await type(gaps: [.zero] + Array(repeating: .milliseconds(80), count: 14), at: middleOffset()))
            }
            results["bursts"] = bursts
            let settles = bursts.map { $0["settle_ms"] as! Double }
            let lat = bursts.flatMap { $0["latency_ms"] as! [Double] }
            print("PACING \(Env.runLabel) bursts(15x80ms) settle_after_last_key \(Self.summary(settles)) key_latency \(Self.summary(lat)) parses=\(bursts.map { $0["parses"] as! Int }) stale=\(bursts.map { $0["stale"] as! Int })")
        }
        if Env.scenarios.contains("sustained") {
            try await idle(.seconds(1))
            let count = 35_000 / 80 + 1
            let r = try await type(gaps: [.zero] + Array(repeating: .milliseconds(80), count: count - 1), at: middleOffset())
            results["sustained"] = r
            print(String(format: "PACING %@ sustained(80ms, 35s) keys=%d latency %@ settle=%.0fms parses=%d stale=%d applied=%d max_apply_gap=%.0fms key_gap_max=%.0fms",
                         Env.runLabel, r["keys"] as! Int, Self.summary(r["latency_ms"] as! [Double]), r["settle_ms"] as! Double,
                         r["parses"] as! Int, r["stale"] as! Int, r["applied"] as! Int, (r["apply_gaps_ms"] as! [Double]).max() ?? 0, r["key_gap_max_ms"] as! Double))
        }
        #expect(editor.textKitFallbackCount == 0)
        if let out = Env.out {
            let data = try JSONSerialization.data(withJSONObject: results.mapValues { value -> Any in value }, options: [.sortedKeys])
            try data.write(to: URL(fileURLWithPath: out))
        }
    }
}
