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

/// What a launch may read while it decides, and nothing more. The three are separate because they
/// cost three different amounts: `size` is a stat, `data` is a whole document, and `source` is a whole
/// record. A document whose text was on disk when its record was written costs one `size` and nothing
/// else — the record cannot be the only copy of anything, so there is nothing to compare.
public struct LaunchStorage {
    /// Bytes of the file at this path; nil when it is gone or cannot be read.
    public var size: (String) -> Int?
    /// The file's bytes, for the one comparison that needs them.
    public var data: (String) -> Data?
    /// The record's text, loaded when a launch has decided it needs it.
    public var source: (RecoveryMetadata) -> DocumentBytes?
    public init(size: @escaping (String) -> Int?, data: @escaping (String) -> Data?, source: @escaping (RecoveryMetadata) -> DocumentBytes?) {
        self.size = size; self.data = data; self.source = source
    }
}

/// What AirMark opens at launch when no file was handed to it. Pure so the decision can be tested
/// without AppKit.
public enum LaunchPlan: Equatable, Sendable {
    /// The file on disk holds the record's text, or the record has nothing unsaved to add to it; open
    /// it and restore the record's position. Carries metadata, not a record: the file is the text, so
    /// the record's source is never read for this.
    case openFile(path: String, record: RecoveryMetadata?)
    /// The record holds text that is on no disk; open it as an unsaved draft. The only plan whose
    /// source a launch loads.
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
    public static func resolve(records: [RecoveryMetadata], recentPaths: [String], storage: LaunchStorage) -> [LaunchPlan] {
        // The newest record belongs to the last session, so it names it. Records written before sessions
        // were identified carry none; a directory of only those is read whole, as it was before.
        let lastSession = records.first?.sessionID
        func inLastSession(_ record: RecoveryMetadata) -> Bool { record.sessionID == nil || record.sessionID == lastSession }
        let left = records.filter { inLastSession($0) && ($0.state == .open || $0.state == .quit) }
        var plans = sessions(frontToBack(left), storage: storage)
        if plans.isEmpty, let last = records.first(where: { !inLastSession($0) || $0.state == .closed || $0.state == .unknown }) {
            plans = sessions([last], storage: storage)
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
    private static func frontToBack(_ records: [RecoveryMetadata]) -> [RecoveryMetadata] {
        guard records.allSatisfy({ $0.order != nil }) else { return records }
        // Two records can name one position when one of them was written before the windows were
        // restacked; the newer of the two is the better guess at which was in front.
        return records.sorted { $0.order == $1.order ? $0.date > $1.date : $0.order! < $1.order! }
    }

    /// One plan per record, newest first, skipping records with nothing to restore and second records
    /// for the same document or file.
    ///
    /// What each record costs is the point of the order these are asked in. A record whose text was on
    /// disk when it was written cannot be the only copy of anything, and both answers a comparison
    /// could give it — the file matches, or another app has changed it since — open the file at the
    /// recorded position. So it is never compared: one stat says whether the file is still there, and
    /// that is the whole decision. Only a record that may hold text no file has is compared, and even
    /// then the recorded length rules out most files without reading either side.
    private static func sessions(_ records: [RecoveryMetadata], storage: LaunchStorage) -> [LaunchPlan] {
        var plans: [LaunchPlan] = []
        var identities: Set<UUID> = [], paths: Set<String> = []
        func draft(_ record: RecoveryMetadata) -> LaunchPlan? {
            // An empty record is nothing to bring back, and its source is not read to find that out.
            guard record.sourceBytes > 0, let bytes = storage.source(record) else { return nil }
            var full = RecoveryRecord(id: record.id, filePath: record.filePath, source: bytes.source, hasBOM: bytes.hasBOM,
                                      revision: record.revision, selection: record.selection, scrollY: record.scrollY,
                                      state: record.state, hasUnsavedChanges: record.hasUnsavedChanges,
                                      sessionID: record.sessionID, order: record.order)
            full.date = record.date
            return .recoverDraft(full)
        }
        for record in records {
            guard identities.insert(record.id).inserted else { continue }
            guard let path = record.filePath else {
                // An untitled document. Only its text can bring it back.
                if let plan = draft(record) { plans.append(plan) }
                continue
            }
            guard paths.insert(path).inserted else { continue }
            guard let onDiskSize = storage.size(path) else {
                // The file is gone, or its volume is not mounted. Whether the text was on disk once says
                // nothing about where it is now: this record is the only copy the app can still reach,
                // so it comes back as a draft rather than being dropped.
                if let plan = draft(record) { plans.append(plan) }
                continue
            }
            guard record.hasUnsavedChanges else {
                // The text was on disk when the record was written, so the file holds it or holds what
                // another app has made of it since. Either way the file is opened at the recorded
                // position and nothing is lost. No bytes are read on this path.
                plans.append(.openFile(path: path, record: record))
                continue
            }
            // The record may hold the only copy. A file of a different length cannot be that text, so
            // the exact comparison runs only when the lengths leave it open.
            if onDiskSize == record.documentBytes, let disk = storage.data(path), let bytes = storage.source(record),
               disk == bytes.data {
                plans.append(.openFile(path: path, record: record))
            } else if let plan = draft(record) {
                plans.append(plan)
            } else {
                // Edited to nothing, with a file that holds something else: the file is all there is.
                plans.append(.openFile(path: path, record: record))
            }
        }
        return plans
    }
}
