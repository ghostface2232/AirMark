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
    /// trip; several documents keep their own records. A record written before these fields reads as a
    /// document that was open with work to recover, which is how a launch treated every record before.
    @Test func recordsKeepTheirStateAndUnsavedFlag() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RecoveryStore(directory: directory)
        var quit = Self.record(UUID(), "on disk\n", revision: 2, path: "/notes/a.md")
        quit.state = .quit; quit.hasUnsavedChanges = false
        var draft = Self.record(UUID(), "typed but never saved", revision: 1)
        draft.state = .open; draft.hasUnsavedChanges = true
        var closed = Self.record(UUID(), "put away\n", revision: 5, path: "/notes/b.md")
        closed.state = .closed; closed.hasUnsavedChanges = false
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
        #expect(old.state == .open)
        #expect(old.hasUnsavedChanges)
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
