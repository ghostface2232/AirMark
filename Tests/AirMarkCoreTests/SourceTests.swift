import Foundation
import Testing
@testable import AirMarkCore

@Test func byteRoundTrip() throws {
    let data = Data([0xEF, 0xBB, 0xBF]) + Data("한글 👩🏽‍💻\r\nB\nC\rD\u{2028}E\u{2029}F".utf8)
    #expect(try DocumentBytes(data: data).data == data)
}

@Test func sourceCoordinates() {
    let index = SourceIndex("한😀\r\nB\u{2028}C\u{2029}D")
    #expect(index.lines.count == 2)
    #expect(index.offset(line: 1, utf8Column: 4) == 1)
    #expect(index.offset(line: 1, utf8Column: 8) == 3)
    #expect(index.offset(line: 1, utf8Column: 2) == nil)
    #expect(index.offset(line: 2, utf8Column: 1) == 5)
}

@Test func randomEditsPreserveIndex() throws {
    var state: UInt64 = 42
    func random(_ count: Int) -> Int { state = state &* 6364136223846793005 &+ 1; return Int((state >> 32) % UInt64(count)) }
    var index = SourceIndex("# 한글\r\n\r\n**hello** 😀\nend")
    let inserts = ["가", "😀", "\r\n", "\n", "*", "\u{2029}", "", "```"]
    for _ in 0..<400 {
        let boundaries = index.source.indices.map { $0.utf16Offset(in: index.source) } + [index.utf16Count]
        let a = random(boundaries.count), b = min(a + random(3), boundaries.count - 1)
        try index.apply(NSRange(location: boundaries[a], length: boundaries[b] - boundaries[a]), replacement: inserts[random(inserts.count)])
        #expect(index.lines == SourceIndex(index.source).lines)
        checkColumns(index)
    }
}

/// Compare every byte column (including invalid scalar interiors) with independent decoding.
private func checkColumns(_ index: SourceIndex) {
    for (line, span) in index.lines.enumerated() {
        let bytes = Array(index.text(in: span).utf8)
        for column in 0...bytes.count {
            let expected = String(bytes: bytes.prefix(column), encoding: .utf8).map { span.location + $0.utf16.count }
            #expect(index.offset(line: line + 1, utf8Column: column + 1) == expected)
        }
        #expect(index.offset(line: line + 1, utf8Column: bytes.count + 2) == nil)
    }
}

@Test func sparseColumnsPreserveScalarBoundariesAndLineEndings() {
    for source in ["", "\r\n", "\r", "\n", String(repeating: "a", count: 63) + "😀한e\u{301}\r\n",
                   String(repeating: "한😀e\u{301}\u{2028}\u{2029}", count: 100) + "\rnext\nend"] {
        let index = SourceIndex(source)
        checkColumns(index)
        #expect(index.offset(line: 0, utf8Column: 1) == nil)
        #expect(index.offset(line: 1, utf8Column: 0) == nil)
        #expect(index.offset(line: 1, utf8Column: Int.max) == nil)
    }
}

@Test func launchPlanPrefersRecoveryThenRecent() {
    func record(_ path: String?, _ source: String) -> RecoveryRecord {
        RecoveryRecord(id: UUID(), filePath: path, source: source, hasBOM: false, revision: 1, selection: SourceSpan(2, 0), scrollY: 0)
    }
    let matching = record("/notes/a.md", "same")
    #expect(LaunchPlan.resolve(records: [matching], recentPaths: [], fileData: { _ in Data("same".utf8) }) == .openFile(path: "/notes/a.md", record: matching))
    let newer = record("/notes/a.md", "edited")
    #expect(LaunchPlan.resolve(records: [newer], recentPaths: [], fileData: { _ in Data("same".utf8) }) == .recoverDraft(newer))
    #expect(LaunchPlan.resolve(records: [newer], recentPaths: [], fileData: { _ in nil }) == .recoverDraft(newer))
    let untitled = record(nil, "draft")
    #expect(LaunchPlan.resolve(records: [untitled], recentPaths: ["/notes/b.md"], fileData: { _ in nil }) == .recoverDraft(untitled))
    #expect(LaunchPlan.resolve(records: [record("/gone.md", "")], recentPaths: [], fileData: { _ in nil }) == .newDocument)
    #expect(LaunchPlan.resolve(records: [], recentPaths: ["/notes/b.md"], fileData: { _ in nil }) == .openRecent(path: "/notes/b.md"))
    #expect(LaunchPlan.resolve(records: [], recentPaths: [], fileData: { _ in nil }) == .newDocument)
}
