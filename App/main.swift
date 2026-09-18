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
            for (index, plan) in plans.enumerated() {
                // A document opened from a file gets its window through an asynchronous completion, so
                // the order the windows appear in does not say which document is newest. The last plan
                // asks for the front itself, wherever its window turns up.
                let front = index == plans.count - 1
                switch plan {
                case .openFile(let path, let record): open(URL(fileURLWithPath: path), recovery: record, bringToFront: front)
                case .openRecent(let path): open(URL(fileURLWithPath: path), bringToFront: front)
                case .newDocument: newDocument(nil)
                case .recoverDraft(let record): recoverDraft(record, bringToFront: front)
                }
            }
            NSApp.activate()
        }
    }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        openedFile = true
        for filename in filenames { open(URL(fileURLWithPath: filename)) }
        sender.reply(toOpenOrPrint: .success)
    }
    func open(_ url: URL, recovery: RecoveryMetadata? = nil, bringToFront: Bool = false) {
        openedFile = true
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { document, _, error in
            if let error { NSApp.presentError(error); if NSDocumentController.shared.documents.isEmpty { self.newDocument(nil) } }
            if let document = document as? MarkdownDocument {
                if let recovery {
                    document.identity = recovery.id; document.editor?.restore(selection: recovery.selection, scrollY: recovery.scrollY)
                }
                if bringToFront { document.windowControllers.first?.window?.makeKeyAndOrderFront(nil) }
            }
            NSApp.activate()
        }
    }
    /// Opens a record whose text is on no disk as an unsaved draft.
    func recoverDraft(_ record: RecoveryRecord, bringToFront: Bool = false) {
        let document = MarkdownDocument(); document.identity = record.id
        document.snapshot.set(DocumentBytes(source: record.source, hasBOM: record.hasBOM))
        document.restoredSelection = record.selection; document.restoredScroll = record.scrollY
        NSDocumentController.shared.addDocument(document); document.makeWindowControllers(); document.showWindows()
        if let path = record.filePath { document.displayName = "Recovered \u{2014} " + URL(fileURLWithPath: path).lastPathComponent }
        if !record.source.isEmpty { document.updateChangeCount(.changeDone) }
        if bringToFront { document.windowControllers.first?.window?.makeKeyAndOrderFront(nil) }
    }
    @objc func newDocument(_ sender: Any?) {
        let document = MarkdownDocument()
        NSDocumentController.shared.addDocument(document)
        document.makeWindowControllers(); document.showWindows()
    }
    @objc func openRecent(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { open(url) }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Written synchronously: after `.terminateLater` AppKit waits in a nested event loop that
        // never runs a main-actor Task, so an asynchronous reply would hang the quit.
        //
        // The flag stays set for the rest of a quit that goes through. AppKit closes the documents
        // after this returns, and `close()` would write `.closed` over the `.quit` records written
        // here; nothing clears the flag on a timer, because that is a race the quit does not decide.
        // A logout cancelled after this returns leaves it set on a process that keeps running, and a
        // document closed then comes back at the next launch — a window to close again, against a
        // session that never returns. No callback reports that cancellation; it is the one case left.
        MarkdownDocument.isTerminating = true
        for document in NSDocumentController.shared.documents.compactMap({ $0 as? MarkdownDocument }) {
            // Recorded as open at the quit, so the next launch restores every one of these windows.
            // The one path that really does cancel the quit is the one that clears the flag.
            do { try Self.recovery.saveImmediately(document.record(state: .quit)) }
            catch { MarkdownDocument.isTerminating = false; NSApp.presentError(error); return .terminateCancel }
        }
        return .terminateNow
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
