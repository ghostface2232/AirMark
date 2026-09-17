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

/// A record for a document that was open when AirMark stopped, unless `state` says otherwise.
func launchRecord(_ path: String?, _ source: String, state: RecoveryState = .open, unsaved: Bool = true) -> RecoveryRecord {
    RecoveryRecord(id: UUID(), filePath: path, source: source, hasBOM: false, revision: 1, selection: SourceSpan(2, 0), scrollY: 0,
                   state: state, hasUnsavedChanges: unsaved)
}

@Test func launchPlanPrefersRecoveryThenRecent() {
    let matching = launchRecord("/notes/a.md", "same")
    #expect(LaunchPlan.resolve(records: [matching], recentPaths: [], fileData: { _ in Data("same".utf8) }) == [.openFile(path: "/notes/a.md", record: matching)])
    let newer = launchRecord("/notes/a.md", "edited")
    #expect(LaunchPlan.resolve(records: [newer], recentPaths: [], fileData: { _ in Data("same".utf8) }) == [.recoverDraft(newer)])
    #expect(LaunchPlan.resolve(records: [newer], recentPaths: [], fileData: { _ in nil }) == [.recoverDraft(newer)])
    let untitled = launchRecord(nil, "draft")
    #expect(LaunchPlan.resolve(records: [untitled], recentPaths: ["/notes/b.md"], fileData: { _ in nil }) == [.recoverDraft(untitled)])
    #expect(LaunchPlan.resolve(records: [launchRecord("/gone.md", "")], recentPaths: [], fileData: { _ in nil }) == [.newDocument])
    #expect(LaunchPlan.resolve(records: [], recentPaths: ["/notes/b.md"], fileData: { _ in nil }) == [.openRecent(path: "/notes/b.md")])
    #expect(LaunchPlan.resolve(records: [], recentPaths: [], fileData: { _ in nil }) == [.newDocument])
}

/// Several documents open at once are all restored. Reducing them to the newest record left the other
/// drafts in the recovery directory with no way to reach them.
@Test func launchRestoresEveryDocumentThatWasOpen() {
    let drafts = [launchRecord(nil, "newest draft"), launchRecord(nil, "older draft")]
    let file = launchRecord("/notes/a.md", "same", unsaved: false)
    let disk = ["/notes/a.md": Data("same".utf8)]
    // Newest first, as RecoveryStore returns them.
    let plans = LaunchPlan.resolve(records: [drafts[0], drafts[1], file], recentPaths: ["/notes/b.md"], fileData: { disk[$0] })
    #expect(plans == [.openFile(path: "/notes/a.md", record: file), .recoverDraft(drafts[1]), .recoverDraft(drafts[0])],
            "one window per open document, oldest first so the newest ends up in front")
    #expect(plans.last?.recordID == drafts[0].id)
}

/// A document closed cleanly is not restored; it is reopened only when nothing was left open, which is
/// what a launch did with the single newest record before.
@Test func launchSkipsClosedDocumentsUnlessNothingWasOpen() {
    let closed = launchRecord("/notes/closed.md", "text", state: .closed, unsaved: false)
    let quit = launchRecord("/notes/quit.md", "text", state: .quit, unsaved: false)
    let disk = ["/notes/closed.md": Data("text".utf8), "/notes/quit.md": Data("text".utf8)]
    #expect(LaunchPlan.resolve(records: [closed, quit], recentPaths: [], fileData: { disk[$0] }) == [.openFile(path: "/notes/quit.md", record: quit)])
    #expect(LaunchPlan.resolve(records: [closed], recentPaths: ["/notes/b.md"], fileData: { disk[$0] }) == [.openFile(path: "/notes/closed.md", record: closed)])
    // Only the most recent one, however many were put away before it.
    let older = launchRecord("/notes/older.md", "text", state: .closed, unsaved: false)
    #expect(LaunchPlan.resolve(records: [closed, older], recentPaths: [], fileData: { _ in Data("text".utf8) }) == [.openFile(path: "/notes/closed.md", record: closed)])
    // An empty untitled document leaves a record with nothing to restore.
    #expect(LaunchPlan.resolve(records: [launchRecord(nil, "", state: .closed, unsaved: false)], recentPaths: ["/notes/b.md"], fileData: { _ in nil }) == [.openRecent(path: "/notes/b.md")])
}

/// A file another app changed after a clean exit is not a crashed draft: the text was on disk, so the
/// file is opened at the recorded position instead of reviving a stale copy as unsaved work. A file that
/// is gone is a different matter — the record is then the only copy the app can reach.
@Test func launchSeparatesUnsavedWorkFromAnExternallyChangedFile() {
    let clean = launchRecord("/notes/a.md", "as closed", state: .quit, unsaved: false)
    let dirty = launchRecord("/notes/b.md", "typed but never saved", state: .open, unsaved: true)
    let disk = ["/notes/a.md": Data("changed elsewhere".utf8), "/notes/b.md": Data("on disk".utf8)]
    #expect(LaunchPlan.resolve(records: [clean], recentPaths: [], fileData: { disk[$0] }) == [.openFile(path: "/notes/a.md", record: clean)])
    #expect(LaunchPlan.resolve(records: [dirty], recentPaths: [], fileData: { disk[$0] }) == [.recoverDraft(dirty)])
    // Deleted, renamed, or on a volume that is not mounted: both come back rather than being dropped.
    #expect(LaunchPlan.resolve(records: [clean], recentPaths: ["/notes/a.md"], fileData: { _ in nil }) == [.recoverDraft(clean)])
    #expect(LaunchPlan.resolve(records: [dirty], recentPaths: [], fileData: { _ in nil }) == [.recoverDraft(dirty)])
    // Nothing to bring back: an empty document whose file is gone opens no window of its own.
    let empty = launchRecord("/notes/c.md", "", state: .quit, unsaved: false)
    #expect(LaunchPlan.resolve(records: [empty], recentPaths: [], fileData: { _ in nil }) == [.newDocument])
}

/// A directory of records written before records carried a state is read the way a launch read it
/// before: the most recent one decides, and the rest open nothing. They cannot be told apart — one may
/// be a draft a crash left behind and the next a document put away weeks ago — so restoring them all
/// would open a window for every document the user had ever opened.
@Test func launchUsesOnlyTheNewestRecordWrittenBeforeStatesExisted() {
    // What `RecoveryWriter.load` produces for a stored record with no `state` field, which
    // `RecoveryStoreTests.recordsKeepTheirStateAndUnsavedFlag` decodes from such a file. The
    // initialiser's default is `.open`, the state a document records while it is running.
    func legacy(_ path: String?, _ source: String) -> RecoveryRecord {
        RecoveryRecord(id: UUID(), filePath: path, source: source, hasBOM: false, revision: 1, selection: SourceSpan(0, 0), scrollY: 0,
                       state: .unknown, hasUnsavedChanges: true)
    }
    let newest = legacy(nil, "draft")
    #expect(newest.state == .unknown)
    #expect(newest.hasUnsavedChanges)
    #expect(LaunchPlan.resolve(records: [newest], recentPaths: [], fileData: { _ in nil }) == [.recoverDraft(newest)])
    let older = (0..<20).map { legacy("/notes/old\($0).md", "weeks ago") }
    #expect(LaunchPlan.resolve(records: [newest] + older, recentPaths: [], fileData: { _ in nil }) == [.recoverDraft(newest)],
            "every record from an older build opened a window")
    // A record this build wrote takes precedence over any of them.
    let open = launchRecord(nil, "today")
    #expect(LaunchPlan.resolve(records: [newest] + older + [open], recentPaths: [], fileData: { _ in nil }) == [.recoverDraft(open)])
}

/// There is no limit on how many documents a launch restores. A record left unrestored would be work
/// the app can no longer reach, and the same records would be left out at every later launch.
@Test func launchRestoresEveryOpenDocumentWithoutALimit() {
    let files = (0..<8).map { launchRecord("/notes/file\($0).md", "same", state: .quit, unsaved: false) }
    let drafts = (0..<3).map { launchRecord(nil, "draft \($0)") }
    let plans = LaunchPlan.resolve(records: files + drafts, recentPaths: [], fileData: { _ in Data("same".utf8) })
    #expect(plans.count == 11)
    #expect(plans.filter(\.isDraft).count == 3)
    // Oldest first, the newest record in front.
    #expect(plans.last == .openFile(path: "/notes/file0.md", record: files[0]))
    #expect(plans.first == .recoverDraft(drafts[2]))
}

/// Two records naming one file, or two carrying one document's identity, open one window.
@Test func launchOpensOneWindowPerDocument() {
    let newest = launchRecord("/notes/a.md", "same", unsaved: false)
    let otherDocument = launchRecord("/notes/a.md", "same", unsaved: false)
    #expect(LaunchPlan.resolve(records: [newest, otherDocument], recentPaths: [], fileData: { _ in Data("same".utf8) })
            == [.openFile(path: "/notes/a.md", record: newest)])
    // The same document recorded twice under different paths: one window, from the newer record.
    var stale = newest
    stale.filePath = "/notes/before-save-as.md"
    stale.source = "an older revision of the same document"
    #expect(LaunchPlan.resolve(records: [newest, stale], recentPaths: [], fileData: { _ in Data("same".utf8) })
            == [.openFile(path: "/notes/a.md", record: newest)])
}
