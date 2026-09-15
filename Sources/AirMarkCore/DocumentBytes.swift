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

public struct RecoveryRecord: Codable, Sendable {
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
    private var revisions: [UUID: UInt64] = [:]
    public init(directory: URL) { self.directory = directory }
    public func save(_ record: RecoveryRecord) throws {
        guard record.revision >= revisions[record.id, default: 0] else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(record)
        try data.write(to: directory.appendingPathComponent(record.id.uuidString + ".json"), options: .atomic)
        revisions[record.id] = record.revision
    }
    public func records() -> [RecoveryRecord] {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return urls.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(RecoveryRecord.self, from: data)
        }.sorted { $0.date > $1.date }
    }
    public func remove(_ id: UUID) throws {
        let url = directory.appendingPathComponent(id.uuidString + ".json")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        revisions.removeValue(forKey: id)
    }
}
