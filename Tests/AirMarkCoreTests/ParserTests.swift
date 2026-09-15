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
