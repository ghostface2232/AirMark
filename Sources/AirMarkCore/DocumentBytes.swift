import Foundation

public struct DocumentBytes: Sendable, Equatable {
    public var source: String
    public var hasBOM: Bool
    public init(source: String = "", hasBOM: Bool = false) { self.source = source; self.hasBOM = hasBOM }
    public init(data: Data) throws {
        hasBOM = data.starts(with: [0xEF, 0xBB, 0xBF])
        let bytes = hasBOM ? data.dropFirst(3) : data[...]
        guard let text = String(data: bytes, encoding: .utf8) else { throw SourceError.invalidUTF8 }
        source = text
    }
    public var data: Data {
        var result = hasBOM ? Data([0xEF, 0xBB, 0xBF]) : Data()
        result.append(contentsOf: source.utf8)
        return result
    }
}

/// A document's recovery state. Records of one document with the same `revision` carry the same source.
///
/// `state` and `hasUnsavedChanges` are two separate questions a launch has to answer and one record
/// could not: whether the document was still open when AirMark stopped, and whether its text was
/// anywhere but in this record. A document closed cleanly whose file another app has edited since is
/// not the same thing as a draft a crash left behind.
public struct RecoveryRecord: Codable, Sendable, Equatable {
    public var id: UUID
    public var filePath: String?
    public var source: String
    public var hasBOM: Bool
    public var revision: UInt64
    public var selection: SourceSpan
    public var scrollY: Double
    public var date: Date
    /// The moment in the document's life this record was written at.
    public var state: RecoveryState
    /// `source` was not on disk when the record was written, so only the record holds it.
    public var hasUnsavedChanges: Bool
    public init(id: UUID, filePath: String?, source: String, hasBOM: Bool, revision: UInt64, selection: SourceSpan, scrollY: Double,
                state: RecoveryState = .open, hasUnsavedChanges: Bool = true) {
        self.id = id; self.filePath = filePath; self.source = source; self.hasBOM = hasBOM
        self.revision = revision; self.selection = selection; self.scrollY = scrollY; date = Date()
        self.state = state; self.hasUnsavedChanges = hasUnsavedChanges
    }
}

public actor RecoveryStore {
    public let directory: URL
    private nonisolated let writer = RecoveryWriter()
    public init(directory: URL) { self.directory = directory }
    public func save(_ record: RecoveryRecord) throws {
        try saveImmediately(record)
    }
    /// Synchronous write for paths that cannot await, such as application termination, where AppKit
    /// runs a nested event loop that does not drain the main actor.
    public nonisolated func saveImmediately(_ record: RecoveryRecord) throws {
        try writer.save(record, to: directory)
    }
    public func records() -> [RecoveryRecord] {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return urls.filter { $0.pathExtension == "json" }.compactMap { url in
            // A save can replace the source between reading the record and its source; read once more.
            RecoveryWriter.load(url, from: directory) ?? RecoveryWriter.load(url, from: directory)
        }.sorted { $0.date > $1.date }
    }
    public func remove(_ id: UUID) throws {
        try writer.remove(id, from: directory)
    }
}

/// The termination path and actor tasks share one ordering gate. Atomic file replacement alone
/// prevents torn JSON, but does not stop an older asynchronous save replacing a newer quit record.
///
/// A record is two files. `<id>.json` holds everything but the source and names `<id>.<token>.source`,
/// which holds the source's UTF-8 bytes. When a save has the revision this writer last wrote for the id,
/// the source is the same and only the small JSON file is replaced, so moving the caret or scrolling a
/// large document does not write the document again. A new source goes to a new file first, then the
/// JSON naming it, then the previous source files are removed: a crash at any point leaves a JSON file
/// naming a complete source. Records from before this layout carry the source inline and still load.
private final class RecoveryWriter: @unchecked Sendable {
    private struct Stored: Codable {
        var id: UUID
        var filePath: String?
        /// Inline in records written before sources had their own file.
        var source: String?
        var sourceFile: String?
        var hasBOM: Bool
        var revision: UInt64
        var selection: SourceSpan
        var scrollY: Double
        var date: Date
        /// Absent in records written before a record said where in a document's life it came from.
        /// Such a record reads as `.unknown`, which a launch treats the way it treated every record
        /// before: only the most recent one, and only when nothing was left open.
        var state: RecoveryState?
        var hasUnsavedChanges: Bool?
    }
    private let lock = NSLock()
    /// What this writer last wrote per id. A new writer, as after a relaunch, knows nothing and writes the
    /// source it is given.
    private var latest: [UUID: (revision: UInt64, date: Date, sourceFile: String)] = [:]
    func save(_ record: RecoveryRecord, to directory: URL) throws {
        try lock.withLock {
            let saved = latest[record.id]
            if let saved {
                guard record.revision > saved.revision ||
                        (record.revision == saved.revision && record.date >= saved.date) else { return }
            }
            let files = FileManager.default
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
            let sourceFile: String
            var wroteSource = false
            if let saved, saved.revision == record.revision, files.fileExists(atPath: directory.appendingPathComponent(saved.sourceFile).path) {
                sourceFile = saved.sourceFile
            } else {
                sourceFile = "\(record.id.uuidString).\(UUID().uuidString).source"
                try Data(record.source.utf8).write(to: directory.appendingPathComponent(sourceFile), options: .atomic)
                wroteSource = true
            }
            let stored = Stored(id: record.id, filePath: record.filePath, source: nil, sourceFile: sourceFile, hasBOM: record.hasBOM,
                                revision: record.revision, selection: record.selection, scrollY: record.scrollY, date: record.date,
                                state: record.state, hasUnsavedChanges: record.hasUnsavedChanges)
            do {
                try JSONEncoder().encode(stored).write(to: directory.appendingPathComponent(record.id.uuidString + ".json"), options: .atomic)
            } catch {
                if wroteSource { try? files.removeItem(at: directory.appendingPathComponent(sourceFile)) }
                throw error
            }
            latest[record.id] = (record.revision, record.date, sourceFile)
            // Sources no record names any more, including one left by a save that stopped before its JSON.
            if wroteSource { removeSources(of: record.id, in: directory, keeping: sourceFile) }
        }
    }
    func remove(_ id: UUID, from directory: URL) throws {
        try lock.withLock {
            let url = directory.appendingPathComponent(id.uuidString + ".json")
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            removeSources(of: id, in: directory, keeping: nil)
            latest.removeValue(forKey: id)
        }
    }
    private func removeSources(of id: UUID, in directory: URL, keeping kept: String?) {
        let prefix = id.uuidString + "."
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasPrefix(prefix) && name.hasSuffix(".source") && name != kept {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
    /// The record in `url`, or nil when it cannot be read or names a source that is missing.
    static func load(_ url: URL, from directory: URL) -> RecoveryRecord? {
        guard let data = try? Data(contentsOf: url), let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return nil }
        let source: String
        if let inline = stored.source {
            source = inline
        } else if let name = stored.sourceFile, !name.contains("/"),
                  let bytes = try? Data(contentsOf: directory.appendingPathComponent(name)), let text = String(data: bytes, encoding: .utf8) {
            source = text
        } else {
            return nil
        }
        var record = RecoveryRecord(id: stored.id, filePath: stored.filePath, source: source, hasBOM: stored.hasBOM, revision: stored.revision,
                                    selection: stored.selection, scrollY: stored.scrollY,
                                    state: stored.state ?? .unknown, hasUnsavedChanges: stored.hasUnsavedChanges ?? true)
        record.date = stored.date
        return record
    }
}
