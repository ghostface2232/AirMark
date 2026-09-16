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

public struct RecoveryRecord: Codable, Sendable, Equatable {
    public var id: UUID
    public var filePath: String?
    public var source: String
    public var hasBOM: Bool
    public var revision: UInt64
    public var selection: SourceSpan
    public var scrollY: Double
    public var date: Date
    public init(id: UUID, filePath: String?, source: String, hasBOM: Bool, revision: UInt64, selection: SourceSpan, scrollY: Double) {
        self.id = id; self.filePath = filePath; self.source = source; self.hasBOM = hasBOM
        self.revision = revision; self.selection = selection; self.scrollY = scrollY; date = Date()
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
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(RecoveryRecord.self, from: data)
        }.sorted { $0.date > $1.date }
    }
    public func remove(_ id: UUID) throws {
        try writer.remove(id, from: directory)
    }
}

/// The termination path and actor tasks share one ordering gate. Atomic file replacement alone
/// prevents torn JSON, but does not stop an older asynchronous save replacing a newer quit record.
private final class RecoveryWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: [UUID: (revision: UInt64, date: Date)] = [:]
    func save(_ record: RecoveryRecord, to directory: URL) throws {
        try lock.withLock {
            if let saved = latest[record.id] {
                guard record.revision > saved.revision ||
                        (record.revision == saved.revision && record.date >= saved.date) else { return }
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(record)
            try data.write(to: directory.appendingPathComponent(record.id.uuidString + ".json"), options: .atomic)
            latest[record.id] = (record.revision, record.date)
        }
    }
    func remove(_ id: UUID, from directory: URL) throws {
        try lock.withLock {
            let url = directory.appendingPathComponent(id.uuidString + ".json")
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            latest.removeValue(forKey: id)
        }
    }
}
