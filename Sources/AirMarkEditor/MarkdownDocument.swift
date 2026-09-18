import AppKit
import AirMarkCore

public final class DocumentSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var value = DocumentBytes()
    /// Incremented whenever `value` is replaced, so equal versions mean equal bytes.
    private var version: UInt64 = 0
    private var conflict = false
    private var diskData: Data?
    private var writingData: Data?
    public func get() -> DocumentBytes { lock.withLock { value } }
    /// The bytes together with their version, read at once.
    public func versioned() -> (bytes: DocumentBytes, version: UInt64) { lock.withLock { (value, version) } }
    public func set(_ value: DocumentBytes) { lock.withLock { self.value = value; version += 1 } }
    public func hasConflict() -> Bool { lock.withLock { conflict } }
    public func setConflict(_ value: Bool) { lock.withLock { conflict = value } }
    public func didRead(_ value: DocumentBytes) { lock.withLock { self.value = value; version += 1; diskData = value.data } }
    public func persistedData() -> Data? { lock.withLock { diskData } }
    public func dataForWriting() -> Data { lock.withLock { writingData ?? value.data } }
    public func isWriting() -> Bool { lock.withLock { writingData != nil } }
    public func beginWrite() { lock.withLock { writingData = value.data } }
    public func finishWrite(success: Bool) {
        lock.withLock {
            if success, let written = writingData { diskData = written }
            writingData = nil
        }
    }
}

/// The document class is registered in Info.plist by its Objective-C name.
@objc(AirMarkMarkdownDocument)
@MainActor public final class MarkdownDocument: NSDocument {
    /// Where drafts and the last active document are recorded. The app sets this at launch.
    public static var recoveryStore: RecoveryStore?
    /// Launch milestones for Scripts/measure.sh; nil unless AIRMARK_LAUNCH_LOG is set.
    public static var launchTimeline: LaunchTimeline?
    /// Set while AirMark is quitting, so a document closed by the quit keeps the record the quit wrote.
    public static var isTerminating = false
    public nonisolated let snapshot = DocumentSnapshot()
    public var editor: EditorController?
    public var identity = UUID()
    var recoveryTask: Task<Void, Never>?
    public nonisolated var externalConflict: Bool {
        get { snapshot.hasConflict() }
        set { snapshot.setConflict(newValue) }
    }
    public var restoredSelection = SourceSpan(0, 0)
    public var restoredScroll = 0.0
    // AppKit queries these policies on its background document-saving queue.
    public nonisolated override class var autosavesInPlace: Bool { true }
    public nonisolated override class var autosavesDrafts: Bool { false }
    public nonisolated override class var preservesVersions: Bool { true }
    public override init() { super.init(); hasUndoManager = true }
    public override func makeWindowControllers() {
        let controller = EditorController(source: snapshot.get().source)
        editor = controller; controller.fileURL = fileURL
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 440, height: 320)
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .textBackgroundColor
        window.contentViewController = controller
        window.tabbingMode = .disallowed
        window.center(); window.setFrameAutosaveName("AirMarkDocument")
        // Two documents open at once must not stack their windows exactly, and a launch that restores a
        // whole session would otherwise put every window in the same place. A second or later window
        // steps down from the one before it instead of staying centred. Only the first window holds the
        // autosave name — the others' `setFrameAutosaveName` call fails because the name is taken — so
        // the stepped positions are never written back and the remembered frame does not drift.
        let others = NSDocumentController.shared.documents.compactMap { ($0 as? MarkdownDocument)?.windowControllers.first?.window }
        if let last = others.last(where: { $0 !== window }) {
            window.setFrameTopLeftPoint(NSPoint(x: last.frame.minX + 24, y: last.frame.maxY - 24))
        }
        addWindowController(NSWindowController(window: window))
        window.isRestorable = false
        controller.onChange = { [weak self] in
            guard let self, let editor = self.editor else { return }
            let old = snapshot.get()
            editor.fileURL = fileURL
            EditorPhases.shared.measure(.snapshot) { snapshot.set(DocumentBytes(source: editor.source, hasBOM: old.hasBOM)) }
            updateChangeCount(.changeDone)
            scheduleRecovery()
        }
        controller.onSelectionChange = { [weak self] in self?.scheduleRecovery() }
        controller.onParseApplied = { Self.launchTimeline?.mark("firstParse") }
        controller.onFirstRender = { Self.launchTimeline?.mark("firstRender") }
        controller.loadViewIfNeeded()
        controller.restore(selection: restoredSelection, scrollY: restoredScroll)
        window.makeFirstResponder(controller.textView)
        Self.launchTimeline?.mark("editable")
        scheduleRecovery()
    }
    public override func showWindows() {
        super.showWindows()
        Self.launchTimeline?.mark("windowShown")
    }
    public nonisolated override func read(from data: Data, ofType typeName: String) throws { snapshot.didRead(try DocumentBytes(data: data)) }
    public nonisolated override func data(ofType typeName: String) throws -> Data { snapshot.dataForWriting() }
    public nonisolated override func canAsynchronouslyWrite(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType) -> Bool { true }
    public override func writeSafely(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType) throws {
        if url == fileURL, let expected = snapshot.persistedData(), let disk = try? Data(contentsOf: url), disk != expected { externalConflict = true }
        if externalConflict && url == fileURL { throw NSError(domain: "AirMark", code: 1, userInfo: [NSLocalizedDescriptionKey: "The file changed in another app. Use Save As to keep your edits, or Revert to read the external version."]) }
        snapshot.beginWrite()
        do {
            try super.writeSafely(to: url, ofType: typeName, for: saveOperation)
            // Save To exports a copy; the original document's disk baseline is unchanged.
            snapshot.finishWrite(success: saveOperation != .saveToOperation)
            if saveOperation == .saveAsOperation { externalConflict = false }
        } catch {
            snapshot.finishWrite(success: false)
            throw error
        }
    }
    /// Save As, and the first save of an untitled document, give the document a new location without
    /// an edit or a presenter callback. Relative image paths resolve against it, so tell the editor
    /// before reporting completion.
    public override func save(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType, completionHandler: @escaping ((any Error)?) -> Void) {
        // AppKit calls this handler on the main thread; the fallback hop exists only for safety.
        nonisolated(unsafe) let handler = completionHandler
        super.save(to: url, ofType: typeName, for: saveOperation) { [weak self] error in
            let finish: @MainActor @Sendable () -> Void = {
                self?.followFileLocation()
                handler(error)
            }
            if Thread.isMainThread { MainActor.assumeIsolated(finish) } else { Task { @MainActor in finish() } }
        }
    }
    private func followFileLocation() {
        guard let editor, editor.fileURL != fileURL else { return }
        editor.fileLocationChanged(to: fileURL)
        scheduleRecovery()
    }
    public override func revert(toContentsOf url: URL, ofType typeName: String) throws {
        let selection = editor?.selection, y = editor?.scrollY
        try super.revert(toContentsOf: url, ofType: typeName)
        externalConflict = false
        editor?.replaceSource(snapshot.get().source, selection: selection, scrollY: y)
    }
    /// Finder moved or renamed the file: relative image paths and the recovery record follow it.
    public nonisolated override func presentedItemDidMove(to newURL: URL) {
        super.presentedItemDidMove(to: newURL)
        Task { @MainActor [weak self] in
            guard let self else { return }
            if fileURL != newURL { fileURL = newURL }
            editor?.fileLocationChanged(to: newURL)
            scheduleRecovery()
        }
    }
    /// The file was deleted underneath the document. Keep the text as an untitled, edited document
    /// so Save asks where to put it; nothing is written back to the old path on its own.
    /// The coordinator deletes the file as soon as `completionHandler` runs, so the handler is called
    /// only after the document has detached from the path on the main actor.
    public nonisolated override func accommodatePresentedItemDeletion(completionHandler: @escaping @Sendable ((any Error)?) -> Void) {
        Task { @MainActor [weak self] in
            defer { completionHandler(nil) }
            guard let self else { return }
            let name = fileURL?.lastPathComponent ?? displayName ?? "Untitled"
            fileURL = nil
            displayName = "Deleted \u{2014} " + name
            editor?.fileLocationChanged(to: nil)
            externalConflict = false
            updateChangeCount(.changeDone)
            windowControllers.first?.window?.subtitle = "The file was deleted. Save As to keep this text."
            scheduleRecovery()
        }
    }
    public nonisolated override func presentedItemDidChange() {
        Task { @MainActor [weak self] in
            guard let self, let url = fileURL, !snapshot.isWriting() else { return }
            let expected = snapshot.persistedData()
            let data = try? await Task.detached { try Data(contentsOf: url) }.value
            // The read can finish after a save or move. Reject that stale observation;
            // only the current persisted bytes identify our own write, never historical content.
            guard let data, fileURL == url, !snapshot.isWriting(),
                  snapshot.persistedData() == expected, data != expected else { return }
            if isDocumentEdited {
                externalConflict = true; scheduleRecovery()
                if let window = windowControllers.first?.window { window.subtitle = "File changed externally — edits preserved" }
            } else {
                do { try revert(toContentsOf: url, ofType: fileType ?? "net.daringfireball.markdown") }
                catch { presentError(error) }
            }
        }
    }
    /// The record's revision is the snapshot's version, not the editor's: the recovery store writes the
    /// source again only when the revision changes, and the snapshot also changes without an editor
    /// edit, as when the file is read again.
    ///
    /// `state` says where in the document's life the record is written; a launch restores the documents
    /// that were still open when AirMark stopped. Whether the text is anywhere but in the record is a
    /// separate question, and `isDocumentEdited` already answers it: it is what the window's dirty mark
    /// shows, it survives a failed save, and reading it costs nothing. Comparing the source with the
    /// bytes on disk instead would encode the whole document on every caret move.
    /// `sessionID` is the recovery store's, so every record this run writes names this run and a launch
    /// restores the last session rather than every session that ever ended with a document open.
    /// `order` is the document's place in the window order, front first, recorded with each record so
    /// the session's stacking survives the quit; a document with no window in the order has none.
    public func record(state: RecoveryState = .open) -> RecoveryRecord {
        let (bytes, version) = snapshot.versioned()
        return record(state: state, bytes: bytes, revision: version, hasUnsavedChanges: isDocumentEdited)
    }
    private func record(state: RecoveryState, bytes: DocumentBytes, revision: UInt64, hasUnsavedChanges: Bool) -> RecoveryRecord {
        RecoveryRecord(id: identity, filePath: fileURL?.path, source: bytes.source, hasBOM: bytes.hasBOM, revision: revision,
                       selection: editor?.selection ?? restoredSelection, scrollY: editor?.scrollY ?? restoredScroll,
                       state: state, hasUnsavedChanges: hasUnsavedChanges,
                       sessionID: Self.recoveryStore?.sessionID,
                       order: NSApplication.shared.orderedDocuments.firstIndex { $0 === self })
    }
    public func scheduleRecovery() {
        recoveryTask?.cancel()
        recoveryTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self else { return }
            guard let store = Self.recoveryStore else { return }
            do { try await store.save(record()) }
            catch { windowControllers.first?.window?.subtitle = "Recovery could not be saved" }
        }
    }
    public override func close() {
        recoveryTask?.cancel()
        // Skipped while quitting: the quit writes every open document's record itself and AppKit closes
        // the documents afterwards, so a close record written then would say the user had put them away.
        //
        // Synchronous, not a Task: closing a document and quitting straight after left a detached save
        // unrun, and the record still said the document was open. The cancelled debounced save cannot
        // undo this one — same revision, earlier date, which the writer's ordering gate rejects. The
        // error goes nowhere because the window is going: a failed write here costs a reopened document.
        if !Self.isTerminating, let store = Self.recoveryStore {
            if isDocumentEdited { discardRecovery(in: store) } else { try? store.saveImmediately(record(state: .closed)) }
        }
        super.close()
    }
    /// The document is closing with changes still on it, so they are not being kept: the user chose
    /// Delete in the close panel of an unsaved draft, or Don't Save where that is offered. Recording
    /// them would hand back at the next launch exactly what was just thrown away.
    ///
    /// An untitled draft was never anywhere but in its record, so the record goes with it. A document
    /// with a file is replaced by a record of the file — the next launch opens what is on disk, at the
    /// position it was left at.
    ///
    /// One store operation, not a remove and then a write: a failed remove followed by a write would
    /// have left the discarded source on disk under a record claiming to hold the file's text, because
    /// the writer reuses the source it last wrote for a revision. `discardImmediately` drops the record
    /// and writes the replacement fresh under one lock, and if it fails part way it fails towards
    /// having thrown the document away rather than towards bringing it back.
    private func discardRecovery(in store: RecoveryStore) {
        var replacement: RecoveryRecord?
        if fileURL != nil {
            let onDisk = snapshot.persistedData().flatMap { try? DocumentBytes(data: $0) } ?? DocumentBytes()
            replacement = record(state: .closed, bytes: onDisk, revision: snapshot.versioned().version, hasUnsavedChanges: false)
        }
        try? store.discardImmediately(identity, replacingWith: replacement)
    }
}
