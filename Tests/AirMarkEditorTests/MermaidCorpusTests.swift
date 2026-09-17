import AppKit
import Testing
import AirMarkCore
@testable import AirMarkRender

/// The bundled Mermaid against a fixed corpus: every diagram type the editor may meet, malformed
/// sources and hostile ones. Each entry states the outcome the bundled version must keep. Printed
/// sizes and times are observations for comparing library versions, not assertions.
@Suite(.serialized) @MainActor struct MermaidCorpusTests {
    enum Expected { case renders, invalid }
    struct Entry {
        let name: String
        let source: String
        let expected: Expected
    }

    static let wellFormed: [Entry] = [
        Entry(name: "flowchart", source: "flowchart LR\n    A[An idea] --> B[Plain text]\n    B --> C[A clear document]", expected: .renders),
        Entry(name: "flowchart-shapes-subgraph", source: """
            flowchart TD
                subgraph Inputs
                    A([Start]) --> B{Decide}
                end
                B -->|yes| C[(Store)]
                B -->|no| D((Stop))
                C -.-> E>Flag] ==> F{{Hex}}
                classDef hot fill:#f96,stroke:#333
                class C hot
                style D stroke-width:4px
            """, expected: .renders),
        Entry(name: "flowchart-hangul", source: "graph TD\n  가[시작] --> 나[한글 라벨 😀]\n  나 --> 다[끝]", expected: .renders),
        Entry(name: "sequence", source: """
            sequenceDiagram
                autonumber
                participant A as Alice
                participant B as Bob
                A->>+B: Hello
                loop Every minute
                    B-->>A: Still here
                end
                alt ok
                    B->>A: Fine
                else not ok
                    B-xA: Error
                end
                Note over A,B: A note
                B-->>-A: Bye
            """, expected: .renders),
        Entry(name: "class", source: "classDiagram\n    Animal <|-- Duck\n    Animal : +int age\n    Animal : +isMammal() bool\n    class Duck{\n      +String beakColor\n      +swim()\n    }", expected: .renders),
        Entry(name: "state", source: "stateDiagram-v2\n    [*] --> Still\n    Still --> Moving\n    state Moving {\n      [*] --> Slow\n      Slow --> Fast\n    }\n    Moving --> [*]", expected: .renders),
        Entry(name: "er", source: "erDiagram\n    CUSTOMER ||--o{ ORDER : places\n    ORDER ||--|{ LINE-ITEM : contains\n    CUSTOMER {\n      string name\n      int id PK\n    }", expected: .renders),
        Entry(name: "gantt", source: "gantt\n    title Plan\n    dateFormat YYYY-MM-DD\n    section A\n    Task one :a1, 2026-01-01, 30d\n    Task two :after a1, 20d", expected: .renders),
        Entry(name: "pie", source: "pie title Pets\n    \"Dogs\" : 386\n    \"Cats\" : 85\n    \"Rats\" : 15", expected: .renders),
        Entry(name: "journey", source: "journey\n    title My day\n    section Go to work\n      Make tea: 5: Me\n      Go upstairs: 3: Me, Cat", expected: .renders),
        Entry(name: "gitgraph", source: "gitGraph\n    commit\n    branch develop\n    checkout develop\n    commit\n    checkout main\n    merge develop", expected: .renders),
        Entry(name: "mindmap", source: "mindmap\n  root((AirMark))\n    Editing\n      Markers\n    Rendering\n      KaTeX\n      Mermaid", expected: .renders),
        Entry(name: "timeline", source: "timeline\n    title History\n    2024 : Idea\n    2025 : Prototype : Tests\n    2026 : Release", expected: .renders),
        Entry(name: "quadrant", source: "quadrantChart\n    title Reach\n    x-axis Low --> High\n    y-axis Low --> High\n    quadrant-1 Expand\n    Campaign A: [0.3, 0.6]\n    Campaign B: [0.45, 0.23]", expected: .renders),
        Entry(name: "xychart", source: "xychart-beta\n    title \"Sales\"\n    x-axis [jan, feb, mar]\n    y-axis \"Revenue\" 0 --> 100\n    bar [20, 50, 80]\n    line [20, 50, 80]", expected: .renders),
        Entry(name: "sankey", source: "sankey-beta\n\nA,B,10\nA,C,5\nB,D,7", expected: .renders),
        Entry(name: "block", source: "block-beta\n  columns 3\n  a b c\n  d[\"Wide\"]:2 e", expected: .renders),
        Entry(name: "requirement", source: "requirementDiagram\n    requirement test_req {\n    id: 1\n    text: the test text.\n    risk: high\n    verifymethod: test\n    }\n    element test_entity {\n    type: simulation\n    }\n    test_entity - satisfies -> test_req", expected: .renders),
        Entry(name: "c4", source: "C4Context\n    title System Context\n    Person(user, \"User\")\n    System(app, \"AirMark\")\n    Rel(user, app, \"Writes\")", expected: .renders),
        Entry(name: "packet", source: "packet-beta\n    0-15: \"Source Port\"\n    16-31: \"Destination Port\"", expected: .renders),
        Entry(name: "architecture", source: "architecture-beta\n    group api(cloud)[API]\n    service db(database)[Database] in api\n    service server(server)[Server] in api\n    db:L -- R:server", expected: .renders),
        Entry(name: "kanban", source: "kanban\n  todo[Todo]\n    a[Write tests]\n  done[Done]\n    b[Ship]", expected: .renders),
        Entry(name: "radar", source: "radar-beta\n  axis A, B, C\n  curve c1{1, 2, 3}", expected: .renders),
        Entry(name: "treemap", source: "treemap-beta\n\"Root\"\n    \"A\": 10\n    \"B\": 20", expected: .renders),
    ]

    static let malformed: [Entry] = [
        Entry(name: "empty", source: "", expected: .invalid),
        Entry(name: "unknown-type", source: "notADiagram\n  A --> B", expected: .invalid),
        Entry(name: "dangling-edge", source: "graph LR\n  A -->", expected: .invalid),
        Entry(name: "unclosed-label", source: "flowchart LR\n  A[unclosed --> B", expected: .invalid),
        Entry(name: "sequence-incomplete", source: "sequenceDiagram\n  Alice->>", expected: .invalid),
        Entry(name: "class-unclosed-body", source: "classDiagram\n  class A {\n    +int x", expected: .invalid),
        Entry(name: "pie-bad-value", source: "pie\n  \"A\" : not-a-number", expected: .invalid),
        Entry(name: "state-bad-arrow", source: "stateDiagram-v2\n  A -> -> B", expected: .invalid),
    ]

    /// Inputs meant to exceed limits, inject script or reach the network. Outcomes are those Mermaid
    /// 11.12.0 produced when the corpus was written (two exceed the editor's display limit rather than
    /// Mermaid's); `airmarkInjected` must never become defined.
    static let adversarial: [Entry] = [
        Entry(name: "edges-over-limit", source: "graph LR\n" + (0..<600).map { "  N\($0) --> N\($0 + 1)" }.joined(separator: "\n"), expected: .invalid),
        // Mermaid draws its own "maximum text size" message instead of throwing.
        Entry(name: "text-over-limit", source: "graph LR\n  A[" + String(repeating: "x", count: 60_000) + "] --> B", expected: .renders),
        Entry(name: "init-raises-limits", source: "%%{init: {\"maxTextSize\": 999999999, \"maxEdges\": 999999, \"securityLevel\": \"loose\"}}%%\ngraph LR\n" + (0..<600).map { "  N\($0) --> N\($0 + 1)" }.joined(separator: "\n"), expected: .invalid),
        Entry(name: "label-html-onerror", source: "graph LR\n  A[\"<img src=x onerror='window.airmarkInjected=1'>\"] --> B", expected: .renders),
        Entry(name: "click-callback", source: "graph LR\n  A --> B\n  click A call eval(\"window.airmarkInjected=2\")\n  click B href \"javascript:window.airmarkInjected=3\"", expected: .renders),
        Entry(name: "init-loose-html", source: "%%{init: {\"securityLevel\": \"loose\", \"flowchart\": {\"htmlLabels\": true}}}%%\ngraph LR\n  A[\"<script>window.airmarkInjected=4</script><b>bold</b>\"] --> B", expected: .renders),
        Entry(name: "sequence-script-note", source: "sequenceDiagram\n  A->>B: <img src=x onerror=\"window.airmarkInjected=5\">\n  Note over A: <script>window.airmarkInjected=6</script>", expected: .renders),
        Entry(name: "remote-image-and-icon", source: "graph LR\n  A[\"<img src='https://example.org/x.png'>\"] --> B[fa:fa-car Car]", expected: .renders),
        Entry(name: "style-remote-url", source: "graph LR\n  A --> B\n  style A fill:url(https://example.org/p.svg)", expected: .invalid),
        Entry(name: "css-injection-classdef", source: "graph LR\n  A --> B\n  classDef x fill:#f00;}</style><script>window.airmarkInjected=7</script><style>\n  class A x", expected: .invalid),
        Entry(name: "nested-subgraphs-60", source: "graph TD\n" + (0..<60).map { "subgraph S\($0)\n" }.joined() + "  A --> B\n" + String(repeating: "end\n", count: 60), expected: .invalid),
        Entry(name: "long-label-10k", source: "graph LR\n  A[\"" + String(repeating: "word ", count: 2_000) + "\"] --> B", expected: .invalid),
        Entry(name: "bidi-and-control", source: "graph LR\n  A[\"\u{202E}evil\u{202C} \u{0007}\"] --> B[\"zero\u{200B}width\"]", expected: .renders),
    ]

    static func window() -> (NSWindow, NSView) {
        _ = NSApplication.shared
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host; window.orderFront(nil)
        return (window, host)
    }

    /// One page for the whole corpus, so it starts one WebContent process rather than one per group.
    static let service = RenderService()

    func run(_ entries: [Entry], group: String) async throws {
        let (window, host) = Self.window()
        defer { window.close() }
        let service = Self.service
        let environment = RenderEnvironment(width: 680, fontSize: 16, scale: 2, dark: false)
        let clock = ContinuousClock()
        for entry in entries {
            let element = RenderElement(span: SourceSpan(0, 1), kind: .mermaid, content: entry.source)
            let start = clock.now
            let outcome: Result<RenderArtifact, any Error>
            do { outcome = .success(try await service.render(element, environment: environment, baseURL: nil, host: host)) } catch { outcome = .failure(error) }
            let elapsed = start.duration(to: clock.now)
            let milliseconds = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
            let injected = try await service.mermaid.evaluateOnCurrentPage("return typeof window.airmarkInjected;").map { String(decoding: $0, as: UTF8.self) } ?? "no page"
            switch outcome {
            case .success(let artifact):
                print(String(format: "MERMAID_CORPUS %@ %@ renders size=%.0fx%.0f ink=%.3f ms=%.0f injected=%@", group, entry.name, artifact.size.width, artifact.size.height, inkCoverage(artifact.image), milliseconds, injected))
                #expect(entry.expected == .renders, "\(entry.name) rendered")
                #expect(inkCoverage(artifact.image) > 0.002, "\(entry.name) has no visible ink")
            case .failure(let error):
                let message = (error as? RenderFailure)?.errorDescription ?? String(describing: error)
                print("MERMAID_CORPUS \(group) \(entry.name) fails \(String(describing: error).prefix(24)) ms=\(Int(milliseconds)) injected=\(injected) message=\(message.prefix(160).replacingOccurrences(of: "\n", with: " "))")
                #expect(entry.expected == .invalid, "\(entry.name) failed: \(message)")
                if case .invalid = error as? RenderFailure {} else { Issue.record("\(entry.name) failed without a source error: \(error)") }
            }
            #expect(injected == "\"undefined\"", "\(entry.name) ran injected script: \(injected)")
        }
        // Handlers such as an image's onerror fire after the snapshot; look again once they had time to run.
        try await Task.sleep(for: .milliseconds(300))
        let late = try await service.mermaid.evaluateOnCurrentPage("return typeof window.airmarkInjected;").map { String(decoding: $0, as: UTF8.self) }
        #expect(late == "\"undefined\"", "injected script ran after rendering: \(String(describing: late))")
        // The page still renders after the corpus.
        let after = try await service.render(RenderElement(span: SourceSpan(0, 1), kind: .mermaid, content: "graph LR\n  After --> Corpus"), environment: environment, baseURL: nil, host: host)
        #expect(inkCoverage(after.image) > 0.002)
    }

    /// The first diagram or formula on a fresh page includes loading the bundled libraries, whose size
    /// changes with the Mermaid version; formulas load the same bundle. Ten fresh pages each; prints
    /// nearest-rank p50 and max. Each page starts a WebContent process, which would disturb
    /// `RenderLifecycleTests`' process accounting in a parallel run, so this runs only when
    /// AIRMARK_MERMAID_MEASURE=1.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AIRMARK_MERMAID_MEASURE"] == "1"))
    func firstRenderOnAFreshPage() async throws {
        let (window, host) = Self.window()
        defer { window.close() }
        let environment = RenderEnvironment(width: 680, fontSize: 16, scale: 2, dark: false)
        let clock = ContinuousClock()
        for kind in [ElementKind.mermaid, .math] {
            var samples: [Double] = []
            for index in 0..<10 {
                let service = RenderService()
                let content = kind == .mermaid ? "graph LR\n  Fresh\(index) --> Page" : "x_{\(index)}^2"
                let start = clock.now
                let artifact = try await service.render(RenderElement(span: SourceSpan(0, 1), kind: kind, content: content, inline: kind == .math), environment: environment, baseURL: nil, host: host)
                let elapsed = start.duration(to: clock.now)
                samples.append(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
                #expect(inkCoverage(artifact.image) > 0.002)
            }
            let sorted = samples.sorted()
            print(String(format: "FIRST_RENDER kind=%@ samples=%d p50=%.1fms max=%.1fms all=%@", kind.rawValue, sorted.count, sorted[4], sorted[9], samples.map { String(format: "%.0f", $0) }.joined(separator: ",")))
        }
    }

    @Test func everyDiagramTypeRenders() async throws { try await run(Self.wellFormed, group: "well-formed") }
    @Test func malformedSourcesAreSourceErrors() async throws { try await run(Self.malformed, group: "malformed") }
    @Test func adversarialSourcesStayContained() async throws { try await run(Self.adversarial, group: "adversarial") }
}
