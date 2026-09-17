import Foundation

/// How a recovery record came to be written. A record alone did not say whether its document was still
/// open when AirMark last stopped, so a launch could not tell a session to restore from work a crash
/// left behind.
public enum RecoveryState: String, Codable, Sendable {
    /// Written while the document was open. A launch that still finds one had no clean exit for that
    /// document: AirMark was force quit or crashed with it open.
    case open
    /// Written for a document that was open when AirMark quit. The next launch restores it.
    case quit
    /// Written when the document was closed. The next launch does not restore it, except as the single
    /// most recent document when nothing was left open.
    case closed
}

/// What AirMark opens at launch when no file was handed to it. Pure so the decision can be tested
/// without AppKit.
public enum LaunchPlan: Equatable, Sendable {
    /// The file on disk holds the record's text, or the record has nothing unsaved to add to it; open
    /// it and restore the record's selection.
    case openFile(path: String, record: RecoveryRecord?)
    /// The record holds text that is on no disk; open it as an unsaved draft.
    case recoverDraft(RecoveryRecord)
    case openRecent(path: String)
    case newDocument

    /// The most documents one launch restores. Beyond this the oldest sessions stay in the recovery
    /// directory instead of opening a window each; unsaved drafts are kept first.
    public static let maximumSessions = 8

    var isDraft: Bool {
        if case .recoverDraft = self { return true }
        return false
    }
    /// The recovery record this plan restores, if any.
    public var recordID: UUID? {
        switch self {
        case .openFile(_, let record): return record?.id
        case .recoverDraft(let record): return record.id
        case .openRecent, .newDocument: return nil
        }
    }

    /// Every document to open at launch, in the order to open them; the last one belongs in front.
    /// `records` is newest first, as `RecoveryStore.records()` returns them.
    ///
    /// Every document that was open when AirMark last stopped is restored, whether it stopped by
    /// quitting or by crashing, so several unsaved drafts are not reduced to the newest one. When
    /// nothing was left open the most recently closed document is reopened, as before, then the most
    /// recent file, then a blank note.
    public static func resolve(records: [RecoveryRecord], recentPaths: [String], fileData: (String) -> Data?) -> [LaunchPlan] {
        var plans = sessions(records.filter { $0.state != .closed }, fileData: fileData)
        if plans.isEmpty, let closed = records.first(where: { $0.state == .closed }) {
            plans = sessions([closed], fileData: fileData)
        }
        guard !plans.isEmpty else {
            if let recent = recentPaths.first { return [.openRecent(path: recent)] }
            return [.newDocument]
        }
        if plans.count > maximumSessions {
            // Unsaved work is why a record exists at all, so those windows come first; among equals the
            // newest are kept. The rest stay on disk rather than opening a window each.
            let ranked = plans.indices.sorted { a, b in
                plans[a].isDraft == plans[b].isDraft ? a < b : plans[a].isDraft
            }
            let kept = Set(ranked.prefix(maximumSessions))
            plans = plans.indices.filter(kept.contains).map { plans[$0] }
        }
        return Array(plans.reversed())
    }

    /// One plan per record, newest first, skipping records with nothing to restore and second records
    /// for the same document or file.
    private static func sessions(_ records: [RecoveryRecord], fileData: (String) -> Data?) -> [LaunchPlan] {
        var plans: [LaunchPlan] = []
        var identities: Set<UUID> = [], paths: Set<String> = []
        for record in records {
            guard identities.insert(record.id).inserted else { continue }
            guard let path = record.filePath else {
                // An untitled document. Only its text can bring it back, and an empty one is nothing.
                if !record.source.isEmpty { plans.append(.recoverDraft(record)) }
                continue
            }
            guard paths.insert(path).inserted else { continue }
            let onDisk = fileData(path)
            if onDisk == DocumentBytes(source: record.source, hasBOM: record.hasBOM).data {
                plans.append(.openFile(path: path, record: record))
            } else if record.hasUnsavedChanges && !record.source.isEmpty {
                // The record is the only copy of this text, whatever the file now holds.
                plans.append(.recoverDraft(record))
            } else if onDisk != nil {
                // The text was on disk when the record was written and the file has changed since, in
                // another app. Open what the file holds now at the recorded position; nothing was lost.
                plans.append(.openFile(path: path, record: record))
            }
            // A file that is gone with nothing unsaved is not resurrected from its record.
        }
        return plans
    }
}
