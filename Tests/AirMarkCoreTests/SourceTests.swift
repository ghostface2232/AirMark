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
    }
}
