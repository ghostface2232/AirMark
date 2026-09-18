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

/// Resolves a launch from whole records. Production reads metadata from disk and loads a source only
/// when it turns out to need one; a test states whole records and what the file system holds, so this
/// stands in for both. `disk` answers for a path the way the file system does, and the size a launch
/// stats is that answer's length.
@discardableResult
func resolve(records: [RecoveryRecord], recent: [String] = [], disk: @escaping (String) -> Data? = { _ in nil }) -> [LaunchPlan] {
    let sources = Dictionary(records.map { ($0.id, DocumentBytes(source: $0.source, hasBOM: $0.hasBOM)) }, uniquingKeysWith: { first, _ in first })
    return LaunchPlan.resolve(records: records.map(\.metadata), recentPaths: recent,
                              storage: LaunchStorage(size: { disk($0)?.count }, data: disk, source: { sources[$0.id] }))
}

/// A record for a document that was open when AirMark stopped, unless `state` says otherwise.
func launchRecord(_ path: String?, _ source: String, state: RecoveryState = .open, unsaved: Bool = true) -> RecoveryRecord {
    RecoveryRecord(id: UUID(), filePath: path, source: source, hasBOM: false, revision: 1, selection: SourceSpan(2, 0), scrollY: 0,
                   state: state, hasUnsavedChanges: unsaved)
}

@Test func launchPlanPrefersRecoveryThenRecent() {
    let matching = launchRecord("/notes/a.md", "same")
    #expect(resolve(records: [matching], recent: [], disk: { _ in Data("same".utf8) }) == [.openFile(path: "/notes/a.md", record: matching.metadata)])
    let newer = launchRecord("/notes/a.md", "edited")
    #expect(resolve(records: [newer], recent: [], disk: { _ in Data("same".utf8) }) == [.recoverDraft(newer)])
    #expect(resolve(records: [newer], recent: [], disk: { _ in nil }) == [.recoverDraft(newer)])
    let untitled = launchRecord(nil, "draft")
    #expect(resolve(records: [untitled], recent: ["/notes/b.md"], disk: { _ in nil }) == [.recoverDraft(untitled)])
    #expect(resolve(records: [launchRecord("/gone.md", "")], recent: [], disk: { _ in nil }) == [.newDocument])
    #expect(resolve(records: [], recent: ["/notes/b.md"], disk: { _ in nil }) == [.openRecent(path: "/notes/b.md")])
    #expect(resolve(records: [], recent: [], disk: { _ in nil }) == [.newDocument])
}

/// Several documents open at once are all restored. Reducing them to the newest record left the other
/// drafts in the recovery directory with no way to reach them.
@Test func launchRestoresEveryDocumentThatWasOpen() {
    let drafts = [launchRecord(nil, "newest draft"), launchRecord(nil, "older draft")]
    let file = launchRecord("/notes/a.md", "same", unsaved: false)
    let disk = ["/notes/a.md": Data("same".utf8)]
    // Newest first, as RecoveryStore returns them.
    let plans = resolve(records: [drafts[0], drafts[1], file], recent: ["/notes/b.md"], disk: { disk[$0] })
    #expect(plans == [.openFile(path: "/notes/a.md", record: file.metadata), .recoverDraft(drafts[1]), .recoverDraft(drafts[0])],
            "one window per open document, oldest first so the newest ends up in front")
    #expect(plans.last?.recordID == drafts[0].id)
}

/// A document closed cleanly is not restored; it is reopened only when nothing was left open, which is
/// what a launch did with the single newest record before.
@Test func launchSkipsClosedDocumentsUnlessNothingWasOpen() {
    let closed = launchRecord("/notes/closed.md", "text", state: .closed, unsaved: false)
    let quit = launchRecord("/notes/quit.md", "text", state: .quit, unsaved: false)
    let disk = ["/notes/closed.md": Data("text".utf8), "/notes/quit.md": Data("text".utf8)]
    #expect(resolve(records: [closed, quit], recent: [], disk: { disk[$0] }) == [.openFile(path: "/notes/quit.md", record: quit.metadata)])
    #expect(resolve(records: [closed], recent: ["/notes/b.md"], disk: { disk[$0] }) == [.openFile(path: "/notes/closed.md", record: closed.metadata)])
    // Only the most recent one, however many were put away before it.
    let older = launchRecord("/notes/older.md", "text", state: .closed, unsaved: false)
    #expect(resolve(records: [closed, older], recent: [], disk: { _ in Data("text".utf8) }) == [.openFile(path: "/notes/closed.md", record: closed.metadata)])
    // An empty untitled document leaves a record with nothing to restore.
    #expect(resolve(records: [launchRecord(nil, "", state: .closed, unsaved: false)], recent: ["/notes/b.md"], disk: { _ in nil }) == [.openRecent(path: "/notes/b.md")])
}

/// A file another app changed after a clean exit is not a crashed draft: the text was on disk, so the
/// file is opened at the recorded position instead of reviving a stale copy as unsaved work. A file that
/// is gone is a different matter — the record is then the only copy the app can reach.
@Test func launchSeparatesUnsavedWorkFromAnExternallyChangedFile() {
    let clean = launchRecord("/notes/a.md", "as closed", state: .quit, unsaved: false)
    let dirty = launchRecord("/notes/b.md", "typed but never saved", state: .open, unsaved: true)
    let disk = ["/notes/a.md": Data("changed elsewhere".utf8), "/notes/b.md": Data("on disk".utf8)]
    #expect(resolve(records: [clean], recent: [], disk: { disk[$0] }) == [.openFile(path: "/notes/a.md", record: clean.metadata)])
    #expect(resolve(records: [dirty], recent: [], disk: { disk[$0] }) == [.recoverDraft(dirty)])
    // Deleted, renamed, or on a volume that is not mounted: both come back rather than being dropped.
    #expect(resolve(records: [clean], recent: ["/notes/a.md"], disk: { _ in nil }) == [.recoverDraft(clean)])
    #expect(resolve(records: [dirty], recent: [], disk: { _ in nil }) == [.recoverDraft(dirty)])
    // Nothing to bring back: an empty document whose file is gone opens no window of its own.
    let empty = launchRecord("/notes/c.md", "", state: .quit, unsaved: false)
    #expect(resolve(records: [empty], recent: [], disk: { _ in nil }) == [.newDocument])
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
    #expect(resolve(records: [newest], recent: [], disk: { _ in nil }) == [.recoverDraft(newest)])
    let older = (0..<20).map { legacy("/notes/old\($0).md", "weeks ago") }
    #expect(resolve(records: [newest] + older, recent: [], disk: { _ in nil }) == [.recoverDraft(newest)],
            "every record from an older build opened a window")
    // A record this build wrote takes precedence over any of them.
    let open = launchRecord(nil, "today")
    #expect(resolve(records: [newest] + older + [open], recent: [], disk: { _ in nil }) == [.recoverDraft(open)])
}

/// Only the documents the last session had open come back. A record says a document was open when
/// AirMark stopped, and nothing but that document rewrites it, so a session that restored nothing —
/// one launched on a file from Finder — left the session before it with `.open` records that every
/// later launch restored again.
@Test func launchRestoresOnlyTheLastSessionsDocuments() {
    let old = UUID(), last = UUID()
    var abandoned = launchRecord("/notes/two-sessions-ago.md", "text", state: .quit, unsaved: false)
    abandoned.sessionID = old
    var current = launchRecord("/notes/last.md", "text", state: .quit, unsaved: false)
    current.sessionID = last
    let disk = ["/notes/two-sessions-ago.md": Data("text".utf8), "/notes/last.md": Data("text".utf8),
                "/notes/put-away.md": Data("text".utf8)]
    // `records()` is newest first, so the last session's record leads and names the session.
    #expect(resolve(records: [current, abandoned], recent: [], disk: { disk[$0] })
            == [.openFile(path: "/notes/last.md", record: current.metadata)])
    // Excluded, not dropped: with nothing left open in the last session it is still the one document
    // that comes back, so no work becomes unreachable.
    var closed = launchRecord("/notes/put-away.md", "text", state: .closed, unsaved: false)
    closed.sessionID = last
    #expect(resolve(records: [closed, abandoned], recent: [], disk: { disk[$0] })
            == [.openFile(path: "/notes/put-away.md", record: closed.metadata)])
    #expect(resolve(records: [abandoned], recent: [], disk: { disk[$0] })
            == [.openFile(path: "/notes/two-sessions-ago.md", record: abandoned.metadata)],
            "the last session is whatever session the newest record belongs to")
    // Records from a build that wrote no session at all are still read whole.
    let first = launchRecord("/notes/a.md", "text", state: .quit, unsaved: false)
    let second = launchRecord("/notes/b.md", "text", state: .quit, unsaved: false)
    #expect(resolve(records: [first, second], recent: [], disk: { _ in Data("text".utf8) }).count == 2)
    // A directory holding both: the records with no session join the last session rather than being
    // treated as an older one, which is what the launch before sessions did with them.
    #expect(resolve(records: [current, first], recent: [], disk: { _ in Data("text".utf8) }).count == 2)
}

/// The session records where each window stood, so the document in front at the quit is the document
/// in front at the launch, whichever one happened to write its record last.
@Test func launchRestoresTheSessionsWindowOrder() {
    let session = UUID()
    func window(_ name: String, order: Int) -> RecoveryRecord {
        var record = launchRecord("/notes/\(name).md", "text", state: .quit, unsaved: false)
        record.sessionID = session; record.order = order
        return record
    }
    // Newest first, as the store returns them: the back window was recorded last.
    let back = window("back", order: 2), middle = window("middle", order: 1), front = window("front", order: 0)
    let plans = resolve(records: [back, middle, front], recent: [], disk: { _ in Data("text".utf8) })
    #expect(plans == [.openFile(path: "/notes/back.md", record: back.metadata),
                      .openFile(path: "/notes/middle.md", record: middle.metadata),
                      .openFile(path: "/notes/front.md", record: front.metadata)],
            "back to front, so the frontmost document is opened last")
    #expect(plans.last?.recordID == front.id)
    // Without a recorded order the newest record is taken as the frontmost, as before.
    var a = front, b = back
    a.order = nil; b.order = nil
    #expect(resolve(records: [a, b], recent: [], disk: { _ in Data("text".utf8) }).last?.recordID == a.id)
}

/// What a launch reads, counted. A record whose text was on disk when it was written cannot be the
/// only copy of anything, and both answers a comparison could give it open the file, so it is never
/// compared: a launch restoring a session of saved documents reads no document bytes and no record
/// sources at all. It used to read every file and every source in full.
@Test func launchReadsNothingForDocumentsWhoseTextIsOnDisk() {
    var sized: [String] = [], read: [String] = [], loaded: [UUID] = []
    let files = (0..<8).map { launchRecord("/notes/file\($0).md", String(repeating: "saved\n", count: 20_000), state: .quit, unsaved: false) }
    let storage = LaunchStorage(size: { sized.append($0); return 4 }, data: { read.append($0); return Data("x".utf8) },
                                source: { loaded.append($0.id); return DocumentBytes(source: "unused") })
    let plans = LaunchPlan.resolve(records: files.map(\.metadata), recentPaths: [], storage: storage)
    #expect(plans.count == 8)
    #expect(plans.allSatisfy { if case .openFile = $0 { true } else { false } })
    #expect(sized.count == 8, "one stat per document and nothing more")
    #expect(read.isEmpty, "a clean record was compared byte for byte: \(read)")
    #expect(loaded.isEmpty, "a clean record's source was loaded: \(loaded)")
    print("LAUNCH_IO clean session of 8: stats=\(sized.count) files read=\(read.count) sources loaded=\(loaded.count)")
}

/// A record that may hold text no file has is compared, but the recorded length settles most of them
/// first: a file of another length cannot be that text, so neither side is read.
@Test func launchComparesOnlyWhatTheLengthsLeaveOpen() {
    func counted(_ disk: [String: Data], _ sources: [UUID: DocumentBytes]) -> (LaunchStorage, () -> (data: Int, source: Int)) {
        var read = 0, loaded = 0
        let storage = LaunchStorage(size: { disk[$0]?.count }, data: { read += 1; return disk[$0] },
                                    source: { loaded += 1; return sources[$0.id] })
        return (storage, { (read, loaded) })
    }
    // Dirty, and the file is a different length: decided without reading either side. Its source is
    // still loaded once, because the draft it becomes is the text.
    let edited = launchRecord("/notes/a.md", "typed but never saved")
    var (storage, counts) = counted(["/notes/a.md": Data("something else entirely".utf8)],
                                    [edited.id: DocumentBytes(source: edited.source)])
    #expect(LaunchPlan.resolve(records: [edited.metadata], recentPaths: [], storage: storage) == [.recoverDraft(edited)])
    #expect(counts() == (data: 0, source: 1), "the file was read although its length ruled it out")

    // Dirty, and the file is exactly as long as the record's text: only here is it read and compared.
    let matching = launchRecord("/notes/b.md", "same text")
    (storage, counts) = counted(["/notes/b.md": Data("same text".utf8)], [matching.id: DocumentBytes(source: matching.source)])
    #expect(LaunchPlan.resolve(records: [matching.metadata], recentPaths: [], storage: storage) == [.openFile(path: "/notes/b.md", record: matching.metadata)])
    #expect(counts().data == 1, "an exact comparison has to read the file")

    // Same length, different text: compared, and it loses.
    let collision = launchRecord("/notes/c.md", "same text")
    (storage, counts) = counted(["/notes/c.md": Data("SAME TEXT".utf8)], [collision.id: DocumentBytes(source: collision.source)])
    #expect(LaunchPlan.resolve(records: [collision.metadata], recentPaths: [], storage: storage) == [.recoverDraft(collision)])
    #expect(counts().data == 1)

    // The BOM counts toward the file's length, so a record with one is not ruled out by three bytes.
    var withBOM = launchRecord("/notes/d.md", "same text"); withBOM.hasBOM = true
    #expect(withBOM.metadata.documentBytes == 9 + 3)
    (storage, counts) = counted(["/notes/d.md": DocumentBytes(source: "same text", hasBOM: true).data],
                                [withBOM.id: DocumentBytes(source: withBOM.source, hasBOM: true)])
    #expect(LaunchPlan.resolve(records: [withBOM.metadata], recentPaths: [], storage: storage) == [.openFile(path: "/notes/d.md", record: withBOM.metadata)])
    #expect(counts().data == 1)

    // An empty record opens no window of its own, and its source is never loaded to find that out.
    let empty = launchRecord("/notes/e.md", "", state: .quit, unsaved: false)
    (storage, counts) = counted([:], [:])
    #expect(LaunchPlan.resolve(records: [empty.metadata], recentPaths: [], storage: storage) == [.newDocument])
    #expect(counts() == (data: 0, source: 0))
}

/// There is no limit on how many documents a launch restores. A record left unrestored would be work
/// the app can no longer reach, and the same records would be left out at every later launch.
@Test func launchRestoresEveryOpenDocumentWithoutALimit() {
    let files = (0..<8).map { launchRecord("/notes/file\($0).md", "same", state: .quit, unsaved: false) }
    let drafts = (0..<3).map { launchRecord(nil, "draft \($0)") }
    let plans = resolve(records: files + drafts, recent: [], disk: { _ in Data("same".utf8) })
    #expect(plans.count == 11)
    #expect(plans.filter(\.isDraft).count == 3)
    // Oldest first, the newest record in front.
    #expect(plans.last == .openFile(path: "/notes/file0.md", record: files[0].metadata))
    #expect(plans.first == .recoverDraft(drafts[2]))
}

/// Two records naming one file, or two carrying one document's identity, open one window.
@Test func launchOpensOneWindowPerDocument() {
    let newest = launchRecord("/notes/a.md", "same", unsaved: false)
    let otherDocument = launchRecord("/notes/a.md", "same", unsaved: false)
    #expect(resolve(records: [newest, otherDocument], recent: [], disk: { _ in Data("same".utf8) })
            == [.openFile(path: "/notes/a.md", record: newest.metadata)])
    // The same document recorded twice under different paths: one window, from the newer record.
    var stale = newest
    stale.filePath = "/notes/before-save-as.md"
    stale.source = "an older revision of the same document"
    #expect(resolve(records: [newest, stale], recent: [], disk: { _ in Data("same".utf8) })
            == [.openFile(path: "/notes/a.md", record: newest.metadata)])
}
