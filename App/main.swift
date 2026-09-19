import AppKit
import AirMarkCore
import AirMarkEditor
import os

@MainActor final class AirMarkApplication: NSApplication {
    // AirMark restores the last active document from its source recovery records.
    override func restoreWindow(withIdentifier identifier: NSUserInterfaceItemIdentifier, state: NSCoder, completionHandler: @escaping (NSWindow?, Error?) -> Void) -> Bool {
        completionHandler(nil, nil)
        return true
    }
}

@MainActor final class AirMarkDocumentController: NSDocumentController {
    override func reopenDocument(for urlOrNil: URL?, withContentsOf contentsURL: URL, display displayDocument: Bool, completionHandler: @escaping (NSDocument?, Bool, Error?) -> Void) {
        // Draft and last-document recovery is owned by RecoveryStore. AppKit's
        // independent autosaved-document reopening would create duplicate windows.
        completionHandler(nil, false, CocoaError(.userCancelled))
    }
    /// Records every open document as open at the quit, and marks the quit begun so the closes AppKit
    /// performs for it say the same. A record that cannot be written cancels the quit with the error
    /// shown: a quit that went ahead would leave nothing to restore.
    func beginQuit() -> Bool {
        MarkdownDocument.isTerminating = true
        for document in documents.compactMap({ $0 as? MarkdownDocument }) {
            do { try AppDelegate.recovery.saveImmediately(document.quitRecord()) }
            catch { MarkdownDocument.isTerminating = false; NSApp.presentError(error); return false }
        }
        return true
    }
    /// The original receiver of the quit's review answer, while the review runs.
    private var review: (delegate: NSObject?, selector: Selector?, contextInfo: UnsafeMutableRawPointer?)?
    /// AppKit calls this when AirMark quits — Cmd-Q or a logout — with any document edited, and closes
    /// every document inside it, clean ones included, before `applicationShouldTerminate` is asked.
    /// So the quit begins here: a flag set only in the delegate came after the closes, each close wrote
    /// `.closed`, and the delegate found no documents left to record. This is also the one place a quit
    /// can still be called off once begun, with the review panel's Cancel, and AppKit says so in the
    /// answer passed back; that answer, and nothing on a timer, is what clears the flag.
    override func reviewUnsavedDocuments(withAlertTitle title: String?, cancellable: Bool, delegate: Any?,
                                         didReviewAllSelector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
        let original = (delegate: delegate as? NSObject, selector: didReviewAllSelector, contextInfo: contextInfo)
        guard beginQuit() else { answer(original, didReviewAll: false); return }
        review = original
        super.reviewUnsavedDocuments(withAlertTitle: title, cancellable: cancellable, delegate: self,
                                     didReviewAllSelector: #selector(quitReview(_:didReviewAll:contextInfo:)), contextInfo: nil)
    }
    @objc private func quitReview(_ controller: NSDocumentController, didReviewAll: Bool, contextInfo: UnsafeMutableRawPointer?) {
        // Documents closed before a Cancel keep their `.quit` records: AppKit closed them for the quit,
        // not the user, so the next launch brings them back with the rest of the session.
        if !didReviewAll { MarkdownDocument.isTerminating = false }
        let original = review; review = nil
        if let original { answer(original, didReviewAll: didReviewAll) }
    }
    /// Passes the answer on in the shape AppKit documents for the review's callback:
    /// `documentController:didReviewAll:contextInfo:`.
    private func answer(_ to: (delegate: NSObject?, selector: Selector?, contextInfo: UnsafeMutableRawPointer?), didReviewAll: Bool) {
        guard let delegate = to.delegate, let selector = to.selector, delegate.responds(to: selector) else { return }
        typealias Callback = @convention(c) (NSObject, Selector, NSDocumentController, Bool, UnsafeMutableRawPointer?) -> Void
        unsafeBitCast(delegate.method(for: selector), to: Callback.self)(delegate, selector, self, didReviewAll, to.contextInfo)
    }
}

/// Where a launch collects the documents it is opening, so their windows can be stacked once they all
/// exist. The opens run together and finish in no particular order; each reports its place, and the
/// last one to land hands over the windows back to front.
@MainActor final class OpenedDocuments {
    private var documents: [MarkdownDocument?]
    private var outstanding: Int
    private let stack: ([NSWindow]) -> Void
    init(count: Int, stack: @escaping ([NSWindow]) -> Void) {
        documents = Array(repeating: nil, count: count); outstanding = count; self.stack = stack
        if count == 0 { stack([]) }
    }
    func record(_ document: MarkdownDocument?, at index: Int) {
        documents[index] = document
        outstanding -= 1
        guard outstanding == 0 else { return }
        stack(documents.compactMap { $0?.windowControllers.first?.window })
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    static let recovery: RecoveryStore = {
        let root: URL
        if let path = ProcessInfo.processInfo.environment["AIRMARK_STATE_DIR"] { root = URL(fileURLWithPath: path) }
        else { root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AirMark/Recovery", isDirectory: true) }
        return RecoveryStore(directory: root)
    }()
    var openedFile = false
    private var documents: AirMarkDocumentController?
    func applicationWillFinishLaunching(_ notification: Notification) {
        documents = AirMarkDocumentController()
        MarkdownDocument.recoveryStore = Self.recovery
        MarkdownDocument.launchTimeline = LaunchTimeline()
        buildMenu()
    }
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
    func applicationDidFinishLaunching(_ notification: Notification) {
        // `--appearance dark|light` pins the appearance; used by screenshot tests, harmless otherwise.
        if let flag = CommandLine.arguments.firstIndex(of: "--appearance"), CommandLine.arguments.indices.contains(flag + 1) {
            NSApp.appearance = NSAppearance(named: CommandLine.arguments[flag + 1] == "dark" ? .darkAqua : .aqua)
        }
        Task { @MainActor in
            if CommandLine.arguments.contains("--blank") { newDocument(nil); return }
            if let flag = CommandLine.arguments.firstIndex(of: "--open"), CommandLine.arguments.indices.contains(flag + 1) {
                open(URL(fileURLWithPath: CommandLine.arguments[flag + 1])); return
            }
            let recent = NSDocumentController.shared.recentDocumentURLs.map(\.path)
            // Every document the last session had open comes back, not only the newest record and not
            // the documents an earlier session left behind. The plans arrive in the order to open them,
            // back to front; the last one belongs in front.
            //
            // Resolved inside the store, which is not the main actor: deciding this reads recovery
            // records and, for a document that may hold unsaved text, that document's file. None of
            // that belongs on the thread that has a window to put up.
            let plans = await Self.recovery.launchPlans(recentPaths: recent)
            guard !openedFile, NSDocumentController.shared.documents.isEmpty else { return }
            // Opened together, then stacked. A document opened from a file gets its window through an
            // asynchronous completion, so the order the windows turn up in says nothing about the order
            // they should be in. The session recorded which window was in front; that is applied here,
            // once every window exists, rather than left to whichever completion ran last.
            let opened = OpenedDocuments(count: plans.count) { windows in
                // Plans arrive back to front, so ordering each window in turn leaves the last on top.
                for window in windows { window.orderFront(nil) }
                windows.last?.makeKeyAndOrderFront(nil)
                NSApp.activate()
            }
            for (index, plan) in plans.enumerated() {
                switch plan {
                case .openFile(let path, let record):
                    open(URL(fileURLWithPath: path), recovery: record) { opened.record($0, at: index) }
                case .openRecent(let path):
                    open(URL(fileURLWithPath: path)) { opened.record($0, at: index) }
                case .newDocument:
                    opened.record(makeBlankDocument(), at: index)
                case .recoverDraft(let record):
                    opened.record(recoverDraft(record), at: index)
                }
            }
        }
    }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        openedFile = true
        for filename in filenames { open(URL(fileURLWithPath: filename)) }
        sender.reply(toOpenOrPrint: .success)
    }
    /// Opens `url`, and reports the document so a launch can stack the windows once they all exist.
    /// AppKit calls the completion on the main thread, which is what the body here has always assumed.
    func open(_ url: URL, recovery: RecoveryMetadata? = nil, completion: ((MarkdownDocument?) -> Void)? = nil) {
        openedFile = true
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { document, _, error in
            if let error { NSApp.presentError(error); if NSDocumentController.shared.documents.isEmpty { self.newDocument(nil) } }
            let opened = document as? MarkdownDocument
            if let opened, let recovery {
                opened.identity = recovery.id; opened.editor?.restore(selection: recovery.selection, scrollY: recovery.scrollY)
            }
            NSApp.activate()
            completion?(opened)
        }
    }
    /// Opens a record whose text is on no disk as an unsaved draft.
    @discardableResult
    func recoverDraft(_ record: RecoveryRecord) -> MarkdownDocument {
        let document = MarkdownDocument(); document.identity = record.id
        document.snapshot.set(DocumentBytes(source: record.source, hasBOM: record.hasBOM))
        document.restoredSelection = record.selection; document.restoredScroll = record.scrollY
        NSDocumentController.shared.addDocument(document); document.makeWindowControllers(); document.showWindows()
        if let path = record.filePath { document.displayName = "Recovered \u{2014} " + URL(fileURLWithPath: path).lastPathComponent }
        if !record.source.isEmpty { document.updateChangeCount(.changeDone) }
        return document
    }
    @discardableResult
    func makeBlankDocument() -> MarkdownDocument {
        let document = MarkdownDocument()
        NSDocumentController.shared.addDocument(document)
        document.makeWindowControllers(); document.showWindows()
        return document
    }
    @objc func newDocument(_ sender: Any?) { makeBlankDocument() }
    @objc func openRecent(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { open(url) }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Written synchronously: after `.terminateLater` AppKit waits in a nested event loop that
        // never runs a main-actor Task, so an asynchronous reply would hang the quit.
        //
        // With a document edited, the quit began in the controller's review, which closed every
        // document; this finds none left. With none edited it begins here, and AppKit closes the
        // documents only after `applicationWillTerminate`. Nothing after this can call the quit off:
        // the review and a document refusing to close both come before it, for Cmd-Q and for a logout
        // alike, and after `.terminateNow` AppKit goes straight to `applicationWillTerminate` and exits.
        // So the flag cannot outlive a quit on a process that keeps running.
        documents?.beginQuit() == false ? .terminateCancel : .terminateNow
    }
    func buildMenu() {
        let main = NSMenu()
        func menu(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: ""); let submenu = NSMenu(title: title)
            item.submenu = submenu; main.addItem(item); return submenu
        }
        func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.keyEquivalentModifierMask = modifiers; item.target = target; menu.addItem(item)
        }
        let app = menu("AirMark")
        add(app, "About AirMark", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        app.addItem(.separator()); add(app, "Hide AirMark", #selector(NSApplication.hide(_:)), "h")
        add(app, "Quit AirMark", #selector(NSApplication.terminate(_:)), "q")
        let file = menu("File")
        add(file, "New", #selector(newDocument(_:)), "n", target: self)
        add(file, "Open…", #selector(NSDocumentController.openDocument(_:)), "o", target: NSDocumentController.shared)
        let recent = NSMenu(title: "Open Recent")
        for url in NSDocumentController.shared.recentDocumentURLs.prefix(12) {
            let item = NSMenuItem(title: url.lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.representedObject = url; item.target = self; recent.addItem(item)
        }
        let recentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: ""); recentItem.submenu = recent; file.addItem(recentItem)
        add(recent, "Clear Menu", #selector(NSDocumentController.clearRecentDocuments(_:)), target: NSDocumentController.shared)
        file.addItem(.separator()); add(file, "Close", #selector(NSWindow.performClose(_:)), "w")
        add(file, "Save", #selector(NSDocument.save(_:)), "s")
        add(file, "Save As…", #selector(NSDocument.saveAs(_:)), "s", [.command, .shift])
        add(file, "Revert to Saved…", #selector(NSDocument.revertToSaved(_:)))
        let edit = menu("Edit")
        add(edit, "Undo", Selector(("undo:")), "z"); add(edit, "Redo", Selector(("redo:")), "z", [.command, .shift])
        edit.addItem(.separator())
        add(edit, "Cut", #selector(NSText.cut(_:)), "x"); add(edit, "Copy", #selector(NSText.copy(_:)), "c")
        add(edit, "Paste", #selector(NSText.paste(_:)), "v"); add(edit, "Select All", #selector(NSText.selectAll(_:)), "a")
        let find = NSMenuItem(title: "Find…", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f"); find.tag = NSTextFinder.Action.showFindInterface.rawValue; edit.addItem(find)
        let replace = NSMenuItem(title: "Find and Replace…", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f"); replace.tag = NSTextFinder.Action.showReplaceInterface.rawValue; replace.keyEquivalentModifierMask = [.command, .option]; edit.addItem(replace)
        let format = menu("Format")
        add(format, "Bold", #selector(MarkdownTextView.boldMarkdown(_:)), "b"); add(format, "Italic", #selector(MarkdownTextView.italicMarkdown(_:)), "i")
        add(format, "Code", #selector(MarkdownTextView.codeMarkdown(_:)), "e"); add(format, "Link", #selector(MarkdownTextView.linkMarkdown(_:)), "k")
        add(format, "Toggle Task", #selector(MarkdownTextView.taskMarkdown(_:)), "\r")
        let view = menu("View")
        add(view, "Show Markdown Markers", #selector(MarkdownTextView.toggleMarkers(_:)), "m", [.command, .shift])
        add(view, "Larger Text", #selector(MarkdownTextView.increaseFont(_:)), "+"); add(view, "Smaller Text", #selector(MarkdownTextView.decreaseFont(_:)), "-")
        let window = menu("Window"); NSApp.windowsMenu = window
        add(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        NSApp.mainMenu = main
    }
}

let application = AirMarkApplication.shared
application.setActivationPolicy(.regular)
let delegate = AppDelegate()
application.delegate = delegate
application.run()
