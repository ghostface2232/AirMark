import AppKit
func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
let refuse = CommandLine.arguments.contains("refuse")
final class Doc: NSDocument {
    override class var autosavesInPlace: Bool { true }
    override class var autosavesDrafts: Bool { false }
    override func data(ofType t: String) throws -> Data { Data() }
    override func read(from d: Data, ofType t: String) throws {}
    override func canClose(withDelegate delegate: Any, shouldClose sel: Selector?, contextInfo: UnsafeMutableRawPointer?) {
        log("canClose(refuse=\(refuse))")
        if true {
            // report "no" to the delegate the way a Cancel click would
            typealias F = @convention(c) (AnyObject, Selector, AnyObject, Bool, UnsafeMutableRawPointer?) -> Void
            let o = delegate as AnyObject
            let imp = o.method(for: sel!)!
            unsafeBitCast(imp, to: F.self)(o, sel!, self, !refuse, contextInfo)
        } else { super.canClose(withDelegate: delegate, shouldClose: sel, contextInfo: contextInfo) }
    }
    override func makeWindowControllers() {
        let w = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 200), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        addWindowController(NSWindowController(window: w))
    }
    override func close() { log("Doc.close \(displayName ?? "")"); super.close() }
}
final class DC: NSDocumentController {
    override func reviewUnsavedDocuments(withAlertTitle title: String?, cancellable: Bool, delegate: Any?, didReviewAllSelector sel: Selector?, contextInfo: UnsafeMutableRawPointer?) {
        log("reviewUnsavedDocuments cancellable=\(cancellable) delegate=\(String(describing: delegate)) sel=\(String(describing: sel))")
        super.reviewUnsavedDocuments(withAlertTitle: title, cancellable: cancellable, delegate: delegate, didReviewAllSelector: sel, contextInfo: contextInfo)
    }
    override func closeAllDocuments(withDelegate delegate: Any?, didCloseAllSelector sel: Selector?, contextInfo: UnsafeMutableRawPointer?) {
        log("closeAllDocuments delegate=\(String(describing: delegate)) sel=\(String(describing: sel))")
        super.closeAllDocuments(withDelegate: delegate, didCloseAllSelector: sel, contextInfo: contextInfo)
    }
    override var hasEditedDocuments: Bool { let v = super.hasEditedDocuments; log("hasEditedDocuments=\(v)"); return v }
}
final class Del: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        let args = CommandLine.arguments
        let d = Doc(); DC.shared.addDocument(d); d.displayName = "A"
        if args.contains("titled") {
            let u = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("probe-\(getpid()).txt")
            try? Data().write(to: u); d.fileURL = u; d.fileType = "public.plain-text"; d.fileModificationDate = (try? FileManager.default.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date
        }
        if args.contains("windows") { d.makeWindowControllers(); d.showWindows() }
        if !args.contains("clean") { d.updateChangeCount(.changeDone) }
        if args.contains("mixed") { let e = Doc(); e.displayName = "B-clean"; DC.shared.addDocument(e); if args.contains("windows") { e.makeWindowControllers(); e.showWindows() } }
        log("launched; controller=\(type(of: NSDocumentController.shared))")
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in log("willTerminate notification") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { log("-> terminate")
            if args.contains("logout") {
                // the event loginwindow sends: kAEQuitApplication with keyAEQuitReason = kAELogOut
                var psn = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: UInt32(kCurrentProcess))
                let target = NSAppleEventDescriptor(descriptorType: typeProcessSerialNumber, bytes: &psn, length: MemoryLayout<ProcessSerialNumber>.size)!
                let ev = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEQuitApplication), targetDescriptor: target, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
                ev.setParam(NSAppleEventDescriptor(enumCode: OSType(kAELogOut)), forKeyword: AEKeyword(kAEQuitReason))
                _ = try? ev.sendEvent(options: [.noReply], timeout: 5)
                if args.contains("gapedit") { log("gap: editing A after the delegate said Now"); d.updateChangeCount(.changeDone) }
            } else { NSApp.terminate(nil) }; log("<- terminate returned (quit cancelled)") ; DispatchQueue.main.asyncAfter(deadline: .now()+3) { log("still running"); exit(0) } }
    }
    func applicationShouldTerminate(_ s: NSApplication) -> NSApplication.TerminateReply {
        let ae = NSAppleEventManager.shared().currentAppleEvent
        let reason = ae?.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)) ?? ae?.paramDescriptor(forKeyword: AEKeyword(kAEQuitReason))
        log("applicationShouldTerminate docs=\(DC.shared.documents.map { $0.displayName ?? "" }) ae=\(ae.map { String(format: "%08x", $0.eventID) } ?? "nil") reason=\(reason.map { String(format: "%08x", $0.enumCodeValue) } ?? "nil") -> .terminateNow"); return .terminateNow }
    var gate: Bool = false
    func applicationWillTerminate(_ n: Notification) { log("applicationWillTerminate") }
}
final class App: NSApplication {
    override func terminate(_ sender: Any?) {
        log("App.terminate enter sender=\(String(describing: sender).prefix(40))")
        super.terminate(sender)
        log("App.terminate RETURNED -> quit was cancelled")
    }
}
_ = DC()
let app = App.shared; let del = Del(); app.delegate = del; app.setActivationPolicy(.accessory); app.run()
