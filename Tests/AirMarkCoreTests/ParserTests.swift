import Foundation
import Testing
@testable import AirMarkCore

@Test func markdownSemanticsAndSourceRanges() {
    let source = "# 한글😀\r\n\r\n**굵게** and *em*\n\n[x][ref]\n\n[ref]: https://example.com\n\n    indented code\n"
    let parsed = MarkdownParser.parse(source)
    #expect(parsed.styles.contains { $0.kind == .heading(1) })
    #expect(parsed.styles.contains { $0.kind == .strong && SourceIndex(source).text(in: $0.span) == "**굵게**" })
    #expect(parsed.styles.contains { $0.kind == .link("https://example.com") })
    #expect(parsed.styles.contains { $0.kind == .codeBlock })
    #expect(parsed.source == source)
}
@Test func mathDoesNotInterpretCodeOrCurrency() {
    let source = "cost $20 and $30\n\n`$not$` and $x_1^2$\n\n$$\n\\frac{a}{b}\n$$\n\n```mermaid\ngraph TD; A-->B\n```"
    let result = MarkdownParser.parse(source)
    #expect(result.elements.filter { $0.kind == .math }.count == 2)
    #expect(result.elements.contains { $0.kind == .math && $0.inline && $0.content == "x_1^2" })
    #expect(result.elements.contains { $0.kind == .mermaid })
}
@Test func tablesAndTasks() {
    let source = "| 이름 | Value |\n| --- | --- |\n| 한글 | 2 |\n\n- [ ] todo\n- [x] done"
    let result = MarkdownParser.parse(source)
    #expect(result.elements.contains { $0.kind == .table })
    #expect(result.checkboxes.count == 2)
}
@Test func referenceChangeUpdatesDistantLink() {
    let a = MarkdownParser.parse("[a][id]\n\n[id]: /one")
    let b = MarkdownParser.parse("[a][id]\n\n[id]: /two")
    #expect(a.styles.contains { $0.kind == .link("/one") })
    #expect(b.styles.contains { $0.kind == .link("/two") })
}
@Test func recoveryRejectsOldWrites() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = RecoveryStore(directory: directory), id = UUID()
    try await store.save(RecoveryRecord(id: id, filePath: nil, source: "new", hasBOM: false, revision: 4, selection: SourceSpan(0, 0), scrollY: 0))
    try await store.save(RecoveryRecord(id: id, filePath: nil, source: "old", hasBOM: false, revision: 2, selection: SourceSpan(0, 0), scrollY: 0))
    let records = await store.records()
    #expect(records.first?.source == "new")
}

@Test func listAndFenceMarkers() {
    let source = "- item\n- [ ] todo\n1. one\n\n```swift\nlet x = 1\n```\n\n~~~\nopen\n"
    let result = MarkdownParser.parse(source)
    let index = SourceIndex(source)
    #expect(result.styles.filter { $0.kind == .bullet }.count == 1)
    #expect(result.styles.contains { $0.kind == .list && $0.markers.map { index.text(in: $0) } == ["- "] })
    #expect(result.styles.contains { $0.kind == .checkbox(false) && index.text(in: $0.span) == "[ ]" })
    let fenced = result.styles.first { $0.kind == .codeBlock && index.text(in: $0.span).hasPrefix("```") }
    #expect(fenced?.markers.map { index.text(in: $0) } == ["```swift\n", "\n```\n"])
    let open = result.styles.first { $0.kind == .codeBlock && index.text(in: $0.span).hasPrefix("~~~") }
    #expect(open?.markers.map { index.text(in: $0) } == ["~~~\n"])
}

@Test func terminationRecoveryCannotBeOverwrittenByPendingSave() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = RecoveryStore(directory: directory), id = UUID()
    let old = RecoveryRecord(id: id, filePath: nil, source: "before", hasBOM: true, revision: 3, selection: SourceSpan(0, 0), scrollY: 0)
    var current = old
    current.source = "latest 한😀\r\n"; current.revision = 4
    current.date = old.date.addingTimeInterval(1)
    try store.saveImmediately(current)
    try await store.save(old)
    var staleSelection = current
    staleSelection.date = old.date
    staleSelection.selection = SourceSpan(2, 0)
    try await store.save(staleSelection)
    #expect(await store.records() == [current])
}

/// Only bulleted items become tasks. A number and a checkbox are never active on the same item:
/// the number stays visible and "[ ]" is ordinary text.
@Test func orderedItemsNeverBecomeTasks() {
    for source in ["1. [ ] task\n", "2) [x] done\n", "10. [X] later\n"] {
        let result = MarkdownParser.parse(source)
        #expect(result.checkboxes.isEmpty, "\(source.debugDescription)")
        #expect(!result.styles.contains { if case .checkbox = $0.kind { return true } else { return false } })
        #expect(result.styles.first { $0.kind == .list }?.markers.isEmpty == true, "the number must not be hidden")
    }
    let bullet = MarkdownParser.parse("- [ ] task\n")
    #expect(bullet.checkboxes.count == 1)
}

/// Deeply nested containers must not crash the background parse. swift-markdown converts the tree
/// recursively, and a concurrency-pool thread's stack ended at about 70 nested quotes.
@Test func deepNestingParsesInTheWorkerWithoutCrashing() async throws {
    let worker = MarkdownParsingWorker()
    let quotes = String(repeating: ">", count: 200) + " deep\n"
    let quoted = try await worker.parse(quotes, revision: 1)
    #expect(quoted.styles.filter { $0.kind == .quote }.count == 200)
    let list = (0..<150).map { String(repeating: "  ", count: $0) + "- item **\($0)**\n" }.joined()
    let listed = try await worker.parse(list, revision: 2)
    #expect(listed.styles.contains { $0.kind == .strong })
}

/// Past the nesting limit the document is shown as plain text instead of risking the stack.
@Test func nestingBeyondTheLimitIsPresentedAsPlainText() async throws {
    let worker = MarkdownParsingWorker()
    for source in [String(repeating: "> ", count: 20_000) + "text\n",
                   String(repeating: "- ", count: 20_000) + "text\n",
                   (0..<400).map { String(repeating: "  ", count: $0) + "- item\n" }.joined()] {
        let result = try await worker.parse(source, revision: 3)
        #expect(result.source == source)
        #expect(result.styles.isEmpty && result.elements.isEmpty && result.checkboxes.isEmpty)
    }
    #expect(MarkdownParser.nestingEstimate(String(repeating: "> ", count: 3) + "- 1. text") == 7)
    #expect(MarkdownParser.nestingEstimate("text\n    indented code\n") == 2)
    #expect(MarkdownParser.nestingEstimate(String(repeating: ">", count: 200) + " deep") == 200)
    // An estimate never below the real depth: 40 list levels indented two columns each.
    let nested = (0..<40).map { String(repeating: "  ", count: $0) + "- item\n" }.joined()
    #expect(MarkdownParser.nestingEstimate(nested) >= 40)
}

/// The limit is only safe if the estimate never falls below the depth the parser actually builds.
@Test func nestingEstimateIsNotBelowParsedContainerDepth() {
    let pieces = ["> ", ">", "- ", "* ", "+ ", "1. ", "2) ", "  ", "    ", "\t", " ", "text", "-", "1.", "\n", "\n\n", "\r\n"]
    var state: UInt64 = 5
    func next(_ bound: Int) -> Int { state = state &* 6364136223846793005 &+ 1442695040888963407; return Int((state >> 33) % UInt64(bound)) }
    for round in 0..<20_000 {
        let source = (0..<(1 + next(30))).map { _ in pieces[next(pieces.count)] }.joined()
        let containers = MarkdownParser.parse(source).styles.filter { $0.kind == .quote || $0.kind == .list }.map(\.span)
        let depth = containers.map { inner in containers.filter { $0.location <= inner.location && inner.end <= $0.end }.count }.max() ?? 0
        let estimate = MarkdownParser.nestingEstimate(source)
        #expect(estimate >= depth, "round \(round): \(source.debugDescription) estimate \(estimate) depth \(depth)")
        if estimate < depth { return }
    }
}
