import Foundation

/// What AirMark opens at launch when no file was handed to it. Pure so the decision can be tested
/// without AppKit: the newest recovery record wins, then the most recent document, then a blank note.
public enum LaunchPlan: Equatable, Sendable {
    /// The file on disk still matches the record; open it and restore the record's selection.
    case openFile(path: String, record: RecoveryRecord?)
    /// The record's source is newer than, or has no, file on disk; open it as an unsaved draft.
    case recoverDraft(RecoveryRecord)
    case openRecent(path: String)
    case newDocument

    public static func resolve(records: [RecoveryRecord], recentPaths: [String], fileData: (String) -> Data?) -> LaunchPlan {
        guard let record = records.first else {
            if let recent = recentPaths.first { return .openRecent(path: recent) }
            return .newDocument
        }
        if let path = record.filePath {
            let onDisk = fileData(path)
            if onDisk == DocumentBytes(source: record.source, hasBOM: record.hasBOM).data { return .openFile(path: path, record: record) }
            if onDisk == nil && record.source.isEmpty { return .newDocument }
            return .recoverDraft(record)
        }
        return .recoverDraft(record)
    }
}
