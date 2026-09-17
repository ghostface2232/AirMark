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
    /// Written before records said any of this. Such a record may be a draft a crash left behind or a
    /// document put away weeks ago, and nothing in it tells the two apart. A directory of them would
    /// open a window each, most of them unwanted, so they are read the way a launch read them before:
    /// only the most recent one is considered, and only when nothing else was left open.
    case unknown
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
    /// quitting or by crashing, so several unsaved drafts are not reduced to the newest one. There is no
    /// limit on how many: the windows restored are the windows there were, and a record left unrestored
    /// would be work with nothing in the app that could reach it, which is the whole point of this. When
    /// nothing was left open the most recently put away document is reopened, as before, then the most
    /// recent file, then a blank note.
    ///
    /// Only the last session's documents come back. `state` alone says a document was open when AirMark
    /// stopped, but not at which stop, and a record is rewritten only by the document it belongs to: a
    /// session that opened a file from Finder, or that could not reopen one, left the session before it
    /// with `.open` and `.quit` records nothing had touched, and every later launch restored them again.
    /// A record excluded that way is not dropped — it joins the closed records as a candidate for the
    /// single most recently put away document, so nothing becomes unreachable.
    public static func resolve(records: [RecoveryRecord], recentPaths: [String], fileData: (String) -> Data?) -> [LaunchPlan] {
        // The newest record belongs to the last session, so it names it. Records written before sessions
        // were identified carry none; a directory of only those is read whole, as it was before.
        let lastSession = records.first?.sessionID
        func inLastSession(_ record: RecoveryRecord) -> Bool { record.sessionID == nil || record.sessionID == lastSession }
        let left = records.filter { inLastSession($0) && ($0.state == .open || $0.state == .quit) }
        var plans = sessions(frontToBack(left), fileData: fileData)
        if plans.isEmpty, let last = records.first(where: { !inLastSession($0) || $0.state == .closed || $0.state == .unknown }) {
            plans = sessions([last], fileData: fileData)
        }
        guard !plans.isEmpty else {
            if let recent = recentPaths.first { return [.openRecent(path: recent)] }
            return [.newDocument]
        }
        return Array(plans.reversed())
    }

    /// One session's records in the order their windows stood, front first. The session records that
    /// order as it writes each record, so which window ends up in front does not depend on which
    /// document happened to be recorded last. Records from a build that did not record it keep the order
    /// `RecoveryStore` returns them in, newest first, where the newest record is taken as the frontmost.
    private static func frontToBack(_ records: [RecoveryRecord]) -> [RecoveryRecord] {
        guard records.allSatisfy({ $0.order != nil }) else { return records }
        // Two records can name one position when one of them was written before the windows were
        // restacked; the newer of the two is the better guess at which was in front.
        return records.sorted { $0.order == $1.order ? $0.date > $1.date : $0.order! < $1.order! }
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
            } else if onDisk == nil {
                // The file is gone, or its volume is not mounted. Whether the text was on disk once says
                // nothing about where it is now: this record is the only copy the app can still reach,
                // so it comes back as a draft rather than being dropped.
                if !record.source.isEmpty { plans.append(.recoverDraft(record)) }
            } else if record.hasUnsavedChanges && !record.source.isEmpty {
                // The record is the only copy of this text, whatever the file now holds.
                plans.append(.recoverDraft(record))
            } else {
                // The text was on disk when the record was written and the file has changed since, in
                // another app. Open what the file holds now at the recorded position; nothing was lost.
                plans.append(.openFile(path: path, record: record))
            }
        }
        return plans
    }
}
