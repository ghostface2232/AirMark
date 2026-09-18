import Foundation
import Testing
@testable import AirMarkCore

/// Recovery records survive a crash at any point of a save, whatever changed since the last one.
@Suite struct RecoveryStoreTests {
    static func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("AirMarkRecoveryStore-" + UUID().uuidString)
    }
    static func record(_ id: UUID, _ source: String, revision: UInt64, selection: Int = 0, hasBOM: Bool = false, path: String? = nil) -> RecoveryRecord {
        RecoveryRecord(id: id, filePath: path, source: source, hasBOM: hasBOM, revision: revision, selection: SourceSpan(selection, 0), scrollY: Double(selection))
    }
    static func files(_ directory: URL) -> [String: Int] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return Dictionary(uniqueKeysWithValues: urls.map { ($0.lastPathComponent, ((try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize) ?? 0) })
    }
    static func later(_ record: RecoveryRecord, seconds: Double = 1) -> RecoveryRecord {
        var next = record; next.date = record.date.addingTimeInterval(seconds); return next
    }

    /// Only the selection and scroll position changed: the source is not written again, and reading
    /// back gives the old source with the new position.
    @Test func positionOnlySaveKeepsTheSourceWithoutRewritingIt() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RecoveryStore(directory: directory), id = UUID()
        let source = String(repeating: "# 한글😀 \"quoted\" \\ line\r\n", count: 4_000)
        let first = Self.record(id, source, revision: 3, hasBOM: true, path: "/notes/a.md")
        try await store.save(first)
        let written = Self.files(directory)
        var moved = Self.later(first)
        moved.selection = SourceSpan(12, 3); moved.scrollY = 480
        try await store.save(moved)
        #expect(await store.records() == [moved])
        let after = Self.files(directory)
        let changed = after.filter { written[$0.key] != $0.value }
        print("RECOVERY_STORE position-only save: files before \(written) after \(after)")
        #expect(changed.values.allSatisfy { $0 < 4_096 }, "a position-only save rewrote \(changed)")
    }

    /// A new revision replaces the source, and the previous source file does not linger.
    @Test func newRevisionReplacesTheSource() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RecoveryStore(directory: directory), id = UUID()
        let first = Self.record(id, "first\n", revision: 1)
        try await store.save(first)
        var moved = Self.later(first); moved.selection = SourceSpan(2, 0)
        try await store.save(moved)
        let second = Self.later(Self.record(id, "second 😀\r\n", revision: 2, selection: 4), seconds: 2)
        try await store.save(second)
        #expect(await store.records() == [second])
        let other = Self.record(UUID(), "other", revision: 1)
        try await store.save(other)
        #expect(await store.records().sorted { $0.id.uuidString < $1.id.uuidString } == [second, other].sorted { $0.id.uuidString < $1.id.uuidString })
        print("RECOVERY_STORE files after two ids: \(Self.files(directory).keys.sorted())")
        #expect(Self.files(directory).count <= 4, "old source files remain: \(Self.files(directory))")
    }

    /// Another store instance on the same directory, as after a relaunch, cannot know what was written
    /// for a revision number before; it writes the source it is given.
    @Test func freshStoreWritesTheSourceForARepeatedRevision() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        try await RecoveryStore(directory: directory).save(Self.record(id, "previous session", revision: 5))
        let relaunched = RecoveryStore(directory: directory)
        let current = Self.later(Self.record(id, "this session", revision: 5, selection: 1))
        try await relaunched.save(current)
        #expect(await relaunched.records() == [current])
        #expect(await RecoveryStore(directory: directory).records() == [current])
    }

    /// Records written before sources had their own file keep loading.
    @Test func recordWithInlineSourceStillLoads() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacy = Self.record(UUID(), "legacy \"inline\" 한글\r\n", revision: 9, selection: 3, hasBOM: true, path: "/notes/old.md")
        try JSONEncoder().encode(legacy).write(to: directory.appendingPathComponent(legacy.id.uuidString + ".json"))
        let store = RecoveryStore(directory: directory)
        #expect(await store.records() == [legacy])
        // Saving over it moves to the current layout and still reads back.
        var moved = Self.later(legacy); moved.selection = SourceSpan(5, 0)
        try await store.save(moved)
        #expect(await store.records() == [moved])
    }

    /// Where a record came from, and whether its text was anywhere but in the record, survive the round
    /// trip; several documents keep their own records. A record written before these fields existed
    /// reads as unknown with work to recover, which a launch treats the way it treated every record
    /// before: only the most recent one, and only when nothing was left open.
    /// A launch reads what it needs to decide, not every document it has ever recorded. `records()`
    /// loads every source in full; `metadata()` takes each source's length from the directory listing
    /// and reads only the small JSON beside it. The difference is a whole session's text.
    @Test func metadataReadsTheRecordsWithoutTheirSources() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RecoveryStore(directory: directory)
        // Four documents of about 8 MB, which is what this is about: a small record costs nothing
        // either way.
        let source = String(repeating: "A line of a large document. 한글 😀\n", count: 200_000)
        let documents = directory.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        var written: [RecoveryRecord] = []
        for index in 0..<4 {
            let file = documents.appendingPathComponent("large\(index).md")
            try Data(source.utf8).write(to: file)
            var record = Self.record(UUID(), source, revision: 1, path: file.path)
            record.hasUnsavedChanges = false; record.state = .quit
            try await store.save(record)
            written.append(record)
        }
        let expected = source.utf8.count
        let clock = ContinuousClock()
        let fresh = RecoveryStore(directory: directory)
        let metadataStart = clock.now
        let metadata = await fresh.metadata()
        let metadataCost = metadataStart.duration(to: clock.now)
        let recordsStart = clock.now
        let records = await fresh.records()
        let recordsCost = recordsStart.duration(to: clock.now)
        print("RECOVERY_LAUNCH 4 records of \(expected) source bytes: metadata() \(metadataCost), records() \(recordsCost)")

        #expect(metadata.count == 4)
        #expect(Set(metadata.map(\.id)) == Set(written.map(\.id)))
        #expect(metadata.allSatisfy { $0.sourceBytes == expected }, "the source length has to be right without reading it")
        #expect(metadata.allSatisfy { $0.state == .quit && !$0.hasUnsavedChanges })
        // Newest first, as records() returns them.
        #expect(metadata.map(\.id) == records.map(\.id))
        #expect(metadata == records.map(\.metadata))
        #expect(metadataCost < recordsCost, "metadata() cost \(metadataCost) against records() \(recordsCost)")

        // The source is still there for the one plan that needs it.
        let first = try #require(metadata.first)
        #expect(await fresh.source(of: first)?.source == source)
        // A launch of this directory opens four files and loads no source at all.
        let plans = await fresh.launchPlans(recentPaths: [])
        #expect(plans.count == 4)
        #expect(plans.allSatisfy { if case .openFile = $0 { true } else { false } }, "got \(plans)")
        #expect(Set(plans.compactMap(\.recordID)) == Set(written.map(\.id)))
    }

    /// A source whose length the directory listing did not hand over is measured, not assumed. The
    /// listing used to record an unreadable size as zero, and a record of zero bytes is an empty one:
    /// `LaunchPlan` opens no window for it, and nothing else holds a draft's text, so the draft was
    /// gone. The fix is that an unknown size is left out of the listing instead, and the loader then
    /// stats the file and reads it rather than giving up.
    ///
    /// The stat failure itself cannot be injected — `contentsOfDirectory` caches the value it was asked
    /// for, so it does not fail for a file that is there — so this covers the fallback the fix routes
    /// to and not the failure that reaches it. It is a defensive fix, and the test says so rather than
    /// implying a reproduction.
    @Test func aSourceLengthTheListingDidNotGiveIsFoundNotAssumed() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RecoveryStore(directory: directory)
        let draft = Self.record(UUID(), "DRAFT THAT MUST NOT BE LOST", revision: 1)
        let empty = Self.record(UUID(), "", revision: 1)
        for record in [draft, empty] { try await store.save(record) }
        let json = { (id: UUID) in directory.appendingPathComponent(id.uuidString + ".json") }

        // Asked for a length the listing does not have.
        let found = try #require(RecoveryWriter.loadMetadata(json(draft.id), in: directory, sourceSizes: [:]))
        #expect(found.sourceBytes == draft.source.utf8.count, "the length was assumed, not found")
        #expect(found.id == draft.id, "the record was dropped for want of a length")
        // An empty source is still empty: nothing here may turn zero into something else.
        #expect(RecoveryWriter.loadMetadata(json(empty.id), in: directory, sourceSizes: [:])?.sourceBytes == 0)
        // A source that is really gone still drops the record, as `records()` drops it.
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix(draft.id.uuidString) && $0.hasSuffix(".source") }
            .forEach { try FileManager.default.removeItem(at: directory.appendingPathComponent($0)) }
        #expect(RecoveryWriter.loadMetadata(json(draft.id), in: directory, sourceSizes: [:]) == nil)
    }

    /// The whole path, with the draft offered back and the empty record opening nothing.
    @Test func aNonEmptyRecordIsNeverReadAsEmpty() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RecoveryStore(directory: directory)
        let draft = Self.record(UUID(), "DRAFT THAT MUST NOT BE LOST", revision: 1)
        let empty = Self.record(UUID(), "", revision: 1)
        for record in [draft, empty] { try await store.save(record) }
        let read = await store.metadata()
        #expect(read.first { $0.id == draft.id }?.sourceBytes == draft.source.utf8.count)
        #expect(read.first { $0.id == empty.id }?.sourceBytes == 0)
        let plans = await store.launchPlans(recentPaths: [])
        #expect(plans.contains { $0.recordID == draft.id }, "the draft was not offered back: \(plans)")
        #expect(!plans.contains { $0.recordID == empty.id }, "an empty record opened a window")
    }

    /// Discarding is one operation: the record and its source go, and the replacement is written fresh.
    /// A remove followed by a save was not the same thing — the writer reuses the source it last wrote
    /// for a revision, so a remove that failed left the discarded text on disk under a record claiming
    /// to hold the file's, which a launch would then hand back.
    @Test func discardingReplacesTheRecordInOneOperation() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RecoveryStore(directory: directory)
        let id = UUID()
        var dirty = Self.record(id, "DISCARDED TEXT", revision: 7, path: "/notes/a.md")
        dirty.hasUnsavedChanges = true
        try await store.save(dirty)
        #expect(Self.files(directory).count == 2)

        // Replaced at the same revision, which is the case the old two-step path got wrong.
        var clean = Self.record(id, "on disk\n", revision: 7, path: "/notes/a.md")
        clean.state = .closed; clean.hasUnsavedChanges = false
        clean.date = dirty.date.addingTimeInterval(1)
        try store.discardImmediately(id, replacingWith: clean)

        let read = try #require(await RecoveryStore(directory: directory).records().first { $0.id == id })
        #expect(read.source == "on disk\n", "the record still names the discarded text: \(read.source.debugDescription)")
        #expect(!read.hasUnsavedChanges)
        for (name, _) in Self.files(directory) where name.hasSuffix(".source") {
            let text = (try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)) ?? ""
            #expect(text != "DISCARDED TEXT", "the discarded source is still in \(name)")
        }
        #expect(Self.files(directory).count == 2, "a source was left behind: \(Self.files(directory).keys.sorted())")
    }

    /// An interrupted discard must fail towards having thrown the document away. The JSON goes first,
    /// because it is the only thing that makes a source reachable, and the sources go before anything
    /// new is written — so at no point after the discard begins is the discarded text reachable, and
    /// losing the replacement is the worst a failure can do.
    ///
    /// A crash cannot be injected into the middle of a locked file operation from a test, so what is
    /// checked is the consequence of that order: take the replacement away, as a failed write would
    /// have left it, and there is nothing of the discarded document left to find.
    @Test func anInterruptedDiscardLeavesNothingToRestore() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RecoveryStore(directory: directory)
        let id = UUID()
        var dirty = Self.record(id, "DISCARDED TEXT", revision: 3, path: "/notes/a.md")
        dirty.hasUnsavedChanges = true
        try await store.save(dirty)
        #expect(await store.records().contains { $0.source == "DISCARDED TEXT" })

        var clean = Self.record(id, "on disk\n", revision: 3, path: "/notes/a.md")
        clean.state = .closed; clean.hasUnsavedChanges = false
        try store.discardImmediately(id, replacingWith: clean)

        // As if the replacement had never been written.
        try FileManager.default.removeItem(at: directory.appendingPathComponent(id.uuidString + ".json"))
        let plans = await RecoveryStore(directory: directory).launchPlans(recentPaths: [])
        #expect(!plans.contains { $0.recordID == id }, "the discarded document is still offered: \(plans)")
        #expect(await RecoveryStore(directory: directory).records().isEmpty)
        for (name, _) in Self.files(directory) {
            let text = (try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)) ?? ""
            #expect(!text.contains("DISCARDED TEXT"), "the discarded source survives in \(name)")
        }
    }

    /// A draft is discarded outright, with no replacement, and leaves nothing at all behind.
    @Test func discardingADraftLeavesTheDirectoryEmpty() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RecoveryStore(directory: directory)
        let id = UUID()
        try await store.save(Self.record(id, "DISCARDED DRAFT", revision: 1))
        try store.discardImmediately(id)
        #expect(Self.files(directory).isEmpty, "left behind: \(Self.files(directory).keys.sorted())")
        #expect(await store.records().isEmpty)
    }

    @Test func recordsKeepTheirStateAndUnsavedFlag() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RecoveryStore(directory: directory)
        let session = UUID()
        var quit = Self.record(UUID(), "on disk\n", revision: 2, path: "/notes/a.md")
        quit.state = .quit; quit.hasUnsavedChanges = false; quit.sessionID = session; quit.order = 0
        var draft = Self.record(UUID(), "typed but never saved", revision: 1)
        draft.state = .open; draft.hasUnsavedChanges = true; draft.sessionID = session; draft.order = 1
        var closed = Self.record(UUID(), "put away\n", revision: 5, path: "/notes/b.md")
        closed.state = .closed; closed.hasUnsavedChanges = false; closed.sessionID = session
        for record in [quit, draft, closed] { try await store.save(record) }
        let read = await RecoveryStore(directory: directory).records()
        #expect(Set(read.map(\.id)) == Set([quit.id, draft.id, closed.id]))
        #expect(read.first { $0.id == quit.id } == quit)
        #expect(read.first { $0.id == draft.id } == draft)
        #expect(read.first { $0.id == closed.id } == closed)
        // A record from before the fields existed.
        let legacy = UUID()
        try Data("{\"id\":\"\(legacy.uuidString)\",\"source\":\"old\",\"hasBOM\":false,\"revision\":1,\"selection\":{\"location\":0,\"length\":0},\"scrollY\":0,\"date\":0}".utf8)
            .write(to: directory.appendingPathComponent(legacy.uuidString + ".json"))
        let old = try #require(await RecoveryStore(directory: directory).records().first { $0.id == legacy })
        #expect(old.state == .unknown)
        #expect(old.hasUnsavedChanges)
        #expect(old.sessionID == nil)
        #expect(old.order == nil)
        // Each store is one run of the app, so two of them never claim the same session.
        #expect(store.sessionID != RecoveryStore(directory: directory).sessionID)
    }

    /// A crash can stop a save after the new source is on disk but before the record names it, or leave
    /// a record naming a source that is gone. Neither hides the complete records, and the leftover is
    /// removed by the next save that writes a source.
    @Test func interruptedSavesLeaveCompleteRecords() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RecoveryStore(directory: directory), id = UUID()
        let saved = Self.record(id, "complete", revision: 1)
        try await store.save(saved)
        // Stopped between writing a new source and the record naming it.
        let orphan = directory.appendingPathComponent("\(id.uuidString).\(UUID().uuidString).source")
        try Data("unfinished".utf8).write(to: orphan)
        #expect(await RecoveryStore(directory: directory).records() == [saved])
        // A record whose source file is missing is skipped; the others still load.
        let broken = UUID()
        try Data("{\"id\":\"\(broken.uuidString)\",\"sourceFile\":\"\(broken.uuidString).gone.source\",\"hasBOM\":false,\"revision\":1,\"selection\":{\"location\":0,\"length\":0},\"scrollY\":0,\"date\":0}".utf8)
            .write(to: directory.appendingPathComponent(broken.uuidString + ".json"))
        #expect(await RecoveryStore(directory: directory).records() == [saved])
        let next = Self.later(Self.record(id, "next", revision: 2))
        try await store.save(next)
        #expect(await store.records() == [next])
        #expect(!FileManager.default.fileExists(atPath: orphan.path), "the unfinished source was left behind")
    }
}
