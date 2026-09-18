import XCTest
import Carbon

@MainActor final class AirMarkUITests: XCTestCase {
    /// Fixtures are bundled with the runner; reading them from the source tree would trigger the
    /// Documents-folder permission dialog and block the run.
    static var fixtures: URL { Bundle(for: AirMarkUITests.self).resourceURL!.appendingPathComponent("Fixtures") }
    /// XCUIAutomation types key events through the active input method. Pin an ASCII source for
    /// these English keyboard fixtures, then restore the user's original source after each test.
    private func useASCIIInputSource() {
        let previous = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let ascii = TISCopyCurrentASCIICapableKeyboardInputSource().takeRetainedValue()
        XCTAssertEqual(TISSelectInputSource(ascii), noErr)
        addTeardownBlock { XCTAssertEqual(TISSelectInputSource(previous), noErr) }
    }
    func testRepeatedAsynchronousSavesPreserveSource() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AirMarkSaveTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("Save.md")
        let prefix = Data([0xEF, 0xBB, 0xBF])
        var source = "## Heading\r\n\r\n**bold** and 한글\n"
        try (prefix + Data(source.utf8)).write(to: file)
        let app = XCUIApplication()
        app.launchArguments = ["--open", file.path]
        app.launchEnvironment["AIRMARK_STATE_DIR"] = directory.appendingPathComponent("Recovery").path
        app.launch()
        useASCIIInputSource()
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        for number in 1...5 {
            // The editor is the launch first responder. Stay on the keyboard: clicking each
            // time races macOS's transient input-source indicator beside the insertion point.
            app.typeKey(.downArrow, modifierFlags: .command)
            let addition = "Save \(number). "
            app.typeText(addition)
            source += addition
            app.typeKey("s", modifierFlags: .command)
            let expected = prefix + Data(source.utf8)
            let saved = NSPredicate { _, _ in (try? Data(contentsOf: file)) == expected }
            expectation(for: saved, evaluatedWith: nil)
            waitForExpectations(timeout: 10)
            // A save that AirMark mistook for an external change used to show an error sheet here.
            XCTAssertNotEqual(app.state, .notRunning)
            XCTAssertEqual(app.sheets.count, 0, app.sheets.firstMatch.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " / "))
            // macOS exposes its temporary input-source indicator as a dialog with an
            // InputSource button. Only that identified system indicator is allowed;
            // error sheets and all other dialogs still fail this test.
            for dialog in app.dialogs.allElementsBoundByIndex {
                XCTAssertTrue(dialog.buttons["InputSource"].exists, dialog.debugDescription)
            }
        }
        app.terminate()
        app.launch()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, source)
    }

    /// Attaches window captures of the showcase fixture so rendering can be inspected without screen-recording access.
    /// Export them with: xcrun xcresulttool export attachments --path <result bundle> --output-path <dir>
    func testShowcaseRendersSpecialContent() throws {
        let fixture = Self.fixtures.appendingPathComponent("Showcase.md")
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("AirMarkShowcase-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let copy = output.appendingPathComponent("Showcase.md")
        try FileManager.default.copyItem(at: fixture, to: copy)
        try FileManager.default.copyItem(at: Self.fixtures.appendingPathComponent("swatch.png"), to: output.appendingPathComponent("swatch.png"))
        let app = XCUIApplication()
        app.launchArguments = ["--open", copy.path]
        app.launchEnvironment["AIRMARK_STATE_DIR"] = output.appendingPathComponent("Recovery").path
        app.launch()
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        func capture(_ name: String) {
            let attachment = XCTAttachment(screenshot: window.screenshot())
            attachment.name = name; attachment.lifetime = .keepAlways
            add(attachment)
        }
        // Renderers are created lazily; give KaTeX and Mermaid time to produce their first artifacts.
        sleep(5)
        capture("showcase-top")
        editor.click()
        app.typeKey(.downArrow, modifierFlags: .command)
        sleep(3)
        capture("showcase-bottom")
        app.typeKey(.upArrow, modifierFlags: .command)
        for _ in 0..<10 { app.typeKey(.downArrow, modifierFlags: []) }
        sleep(1)
        capture("showcase-caret-in-body")
        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), try String(contentsOf: fixture, encoding: .utf8))
    }

    /// The showcase document in dark appearance. No input is synthesized.
    func testShowcaseDarkAppearanceScreenshot() throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("AirMarkDark-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for name in ["Showcase.md", "swatch.png"] {
            try FileManager.default.copyItem(at: Self.fixtures.appendingPathComponent(name), to: output.appendingPathComponent(name))
        }
        let app = XCUIApplication()
        app.launchArguments = ["--open", output.appendingPathComponent("Showcase.md").path, "--appearance", "dark"]
        app.launchEnvironment["AIRMARK_STATE_DIR"] = output.appendingPathComponent("Recovery").path
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        sleep(5)
        for (name, key) in [("dark-top", nil), ("dark-bottom", XCUIKeyboardKey.downArrow)] {
            if let key { app.textViews["markdown-editor"].click(); app.typeKey(key, modifierFlags: .command); sleep(3) }
            let attachment = XCTAttachment(screenshot: window.screenshot())
            attachment.name = name; attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    /// Launches the app on a fixture and attaches one window capture. No input is synthesized.
    func testInlineMathFixtureScreenshot() throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("AirMarkInline-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let copy = output.appendingPathComponent("InlineMath.md")
        try FileManager.default.copyItem(at: Self.fixtures.appendingPathComponent("InlineMath.md"), to: copy)
        let app = XCUIApplication()
        app.launchArguments = ["--open", copy.path]
        app.launchEnvironment["AIRMARK_STATE_DIR"] = output.appendingPathComponent("Recovery").path
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        sleep(5)
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = "inline-math"; attachment.lifetime = .keepAlways
        add(attachment)
        // Quit goes through applicationShouldTerminate and must actually end the process.
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10), "Cmd-Q did not quit the app")
        let recovery = try FileManager.default.contentsOfDirectory(atPath: output.appendingPathComponent("Recovery").path)
        XCTAssertFalse(recovery.filter { $0.hasSuffix(".json") }.isEmpty, "quit should leave a recovery record")
    }

    /// A document open at a Cmd-Q is recorded as `.quit`, not `.closed`. AppKit closes the documents
    /// around the quit, and `MarkdownDocument.close()` writes a `.closed` record for a document the user
    /// put away; `isTerminating` is what tells the two apart. It used to be cleared on the next turn of
    /// the run loop, so whether the session survived a quit depended on which ran first. Nothing but a
    /// real quit exercises that ordering, so this is a UI test. No input beyond Cmd-Q is synthesized.
    func testQuitRecordsAnOpenDocumentAsQuitNotClosed() throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("AirMarkQuit-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let copy = output.appendingPathComponent("InlineMath.md")
        try FileManager.default.copyItem(at: Self.fixtures.appendingPathComponent("InlineMath.md"), to: copy)
        let recovery = output.appendingPathComponent("Recovery")
        let app = XCUIApplication()
        app.launchArguments = ["--open", copy.path]
        app.launchEnvironment["AIRMARK_STATE_DIR"] = recovery.path
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10), "Cmd-Q did not quit the app")

        let names = try FileManager.default.contentsOfDirectory(atPath: recovery.path).filter { $0.hasSuffix(".json") }
        XCTAssertEqual(names.count, 1, "one document was open: \(names)")
        let name = try XCTUnwrap(names.first)
        let stored = try XCTUnwrap(JSONSerialization.jsonObject(with: try Data(contentsOf: recovery.appendingPathComponent(name))) as? [String: Any])
        XCTAssertEqual(stored["state"] as? String, "quit", "the quit record was overwritten by a close record")
        XCTAssertEqual(stored["filePath"] as? String, copy.path)
        XCTAssertNotNil(stored["sessionID"] as? String, "the record does not name the run that wrote it")
    }

    /// The close panel of an unsaved draft, and what each of its three buttons leaves for the next
    /// launch. Needs an idle machine: these type into the app.
    ///
    /// The panel appears for a draft because `autosavesDrafts` is false. macOS labels its discard
    /// button **Delete**, not Don't Save, which is the wording for a document that has a file.
    private func draftCloseScenario(_ output: URL, type text: String) -> (XCUIApplication, XCUIElement) {
        let app = XCUIApplication()
        app.launchArguments = ["--blank"]
        app.launchEnvironment["AIRMARK_STATE_DIR"] = output.appendingPathComponent("Recovery").path
        app.launch()
        useASCIIInputSource()
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.click(); editor.typeText(text)
        XCTAssertEqual(editor.value as? String, text)
        app.typeKey("w", modifierFlags: .command)
        return (app, editor)
    }
    /// Relaunches into the same recovery directory, with no file and no `--blank`, so the launch
    /// decides from the recovery records alone.
    private func relaunch(_ app: XCUIApplication, _ output: URL) -> XCUIElement {
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15), "the app did not quit")
        app.launchArguments = []
        app.launchEnvironment["AIRMARK_STATE_DIR"] = output.appendingPathComponent("Recovery").path
        app.launch()
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        return editor
    }
    private func temporaryOutput(_ name: String) throws -> URL {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(name + "-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        return output
    }

    /// Delete throws the draft away, so the next launch must not offer it back. The record used to be
    /// written as closed with the discarded text still in it, and a launch with nothing else to open
    /// revived it as a "Recovered" window.
    func testDiscardedDraftIsNotRestoredAfterRelaunch() throws {
        let output = try temporaryOutput("AirMarkDiscard")
        let (app, _) = draftCloseScenario(output, type: "DISCARD ME")
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "closing an edited draft did not ask")
        XCTAssertTrue(sheet.buttons["Delete"].exists, "buttons: \(sheet.buttons.allElementsBoundByIndex.map { $0.title })")
        sheet.buttons["Delete"].click()
        let recovery = output.appendingPathComponent("Recovery")
        var records: [String] = []
        for _ in 0..<40 {
            records = ((try? FileManager.default.contentsOfDirectory(atPath: recovery.path)) ?? []).filter { $0.hasSuffix(".json") }
            if records.isEmpty { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertTrue(records.isEmpty, "the discarded draft is still recorded: \(records)")
        app.typeKey("q", modifierFlags: .command)

        let editor = relaunch(app, output)
        let restored = (editor.value as? String) ?? ""
        XCTAssertFalse(restored.contains("DISCARD ME"), "the discarded draft came back: \(restored.debugDescription)")
        for window in app.windows.allElementsBoundByIndex {
            XCTAssertFalse(window.title.contains("Recovered"), "a recovered window for a discarded draft: \(window.title)")
        }
        app.terminate()
    }

    /// Cancel is not a close. The draft stays open and its recovery stands, so quitting and coming back
    /// brings it with it.
    func testCancelledCloseKeepsTheDraftAfterRelaunch() throws {
        let output = try temporaryOutput("AirMarkCancel")
        let (app, editor) = draftCloseScenario(output, type: "KEEP ME")
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        sheet.buttons["Cancel"].click()
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "Cancel closed the window")
        XCTAssertEqual(editor.value as? String, "KEEP ME", "Cancel lost the draft's text")
        // The record still holds the draft: Cancel is not a close, so nothing discarded it.
        let recovery = output.appendingPathComponent("Recovery")
        var kept = false
        for _ in 0..<40 where !kept {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: recovery.path)) ?? []
            kept = names.filter { $0.hasSuffix(".source") }.contains {
                ((try? String(contentsOf: recovery.appendingPathComponent($0), encoding: .utf8)) ?? "").contains("KEEP ME")
            }
            if !kept { Thread.sleep(forTimeInterval: 0.25) }
        }
        XCTAssertTrue(kept, "Cancel dropped the draft's recovery")
        // Force quit rather than Cmd-Q: a clean quit asks about the unsaved draft all over again, and
        // an unsaved draft surviving a stop that never asked is the whole point of recovery.
        app.terminate()

        let restored = relaunch(app, output)
        XCTAssertEqual(restored.value as? String, "KEEP ME", "the draft kept by Cancel was not restored")
        app.terminate()
    }

    // The close panel's third button, Save, is not driven from here. The app is sandboxed, so the save
    // panel it opens for an untitled draft belongs to the system's powerbox and not to this app, and
    // automating it is fragile in a way that would say more about the panel than about AirMark. What
    // Save leads to — the draft gets a file, its record is clean and names it, and the next launch
    // opens the file — is covered at the document level by
    // `DocumentTests.savingADraftOnCloseLeavesItsFileToOpen`.

    /// A document with a file is never asked about: `autosavesInPlace` writes the edit and closes. This
    /// pins that, because it is why the panel above says Delete and why there is no Don't Save to test
    /// for a saved file — the edit is kept, and the next launch opens the file holding it.
    func testEditingASavedFileIsKeptOnCloseAndRelaunch() throws {
        let output = try temporaryOutput("AirMarkSavedFile")
        let file = output.appendingPathComponent("Note.md")
        try Data("original\n".utf8).write(to: file)
        let app = XCUIApplication()
        app.launchArguments = ["--open", file.path]
        app.launchEnvironment["AIRMARK_STATE_DIR"] = output.appendingPathComponent("Recovery").path
        app.launch()
        useASCIIInputSource()
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.click()
        app.typeKey(.downArrow, modifierFlags: .command)
        editor.typeText("EDITED")
        app.typeKey("w", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(app.sheets.count, 0, "a saved file was asked about; autosavesInPlace should have kept it")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "original\nEDITED", "the close did not keep the edit")
        app.typeKey("q", modifierFlags: .command)

        let restored = relaunch(app, output)
        XCTAssertEqual(restored.value as? String, "original\nEDITED", "the file's content did not come back")
        app.terminate()
    }

    /// Writes a recovery record the way `RecoveryStore` writes one: the metadata as `<id>.json` and the
    /// source in its own file beside it. Used to hand a launch the directory a previous session would
    /// have left, which is the only way to put several documents and two sessions in front of it
    /// without driving several windows open by hand.
    @discardableResult
    private func seedRecord(in directory: URL, file: URL?, source: String, session: UUID, order: Int,
                            state: String = "quit", unsaved: Bool = false, age: TimeInterval = 0) throws -> UUID {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID(), sourceName = "\(id.uuidString).\(UUID().uuidString).source"
        try Data(source.utf8).write(to: directory.appendingPathComponent(sourceName))
        var record: [String: Any] = [
            "id": id.uuidString, "sourceFile": sourceName, "hasBOM": false, "revision": 1,
            "selection": ["location": 0, "length": 0], "scrollY": 0,
            "date": Date().timeIntervalSinceReferenceDate - age,
            "state": state, "hasUnsavedChanges": unsaved,
            "sessionID": session.uuidString, "order": order,
        ]
        if let file { record["filePath"] = file.path }
        try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            .write(to: directory.appendingPathComponent(id.uuidString + ".json"))
        return id
    }

    /// Every document the last session had open comes back, and the session before it stays where it
    /// is. Taking `records.first` opened one window and left the rest unreachable; restoring every
    /// `.quit` record whatever session wrote it opened windows the user had not seen in two launches.
    func testRelaunchRestoresTheLastSessionAndNotTheOneBefore() throws {
        let output = try temporaryOutput("AirMarkSession")
        let recovery = output.appendingPathComponent("Recovery")
        func write(_ name: String, _ text: String) throws -> URL {
            let url = output.appendingPathComponent(name)
            try Data(text.utf8).write(to: url)
            return url
        }
        let last = UUID(), previous = UUID()
        // Two documents open when the last session stopped, and one left by the session before it.
        let front_ = try write("Front.md", "FRONT DOCUMENT\n")
        let back = try write("Back.md", "BACK DOCUMENT\n")
        let stale = try write("Stale.md", "STALE DOCUMENT\n")
        try seedRecord(in: recovery, file: stale, source: "STALE DOCUMENT\n", session: previous, order: 0, age: 7200)
        try seedRecord(in: recovery, file: back, source: "BACK DOCUMENT\n", session: last, order: 1, age: 20)
        try seedRecord(in: recovery, file: front_, source: "FRONT DOCUMENT\n", session: last, order: 0, age: 10)

        let app = XCUIApplication()
        app.launchArguments = []
        app.launchEnvironment["AIRMARK_STATE_DIR"] = recovery.path
        app.launch()
        XCTAssertTrue(app.textViews["markdown-editor"].firstMatch.waitForExistence(timeout: 15))
        // Both windows, and only those two.
        var editors: [String] = []
        for _ in 0..<40 {
            editors = app.textViews.matching(identifier: "markdown-editor").allElementsBoundByIndex.compactMap { $0.value as? String }
            if editors.count >= 2 { break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertEqual(editors.count, 2, "the last session had two documents open, got \(editors)")
        XCTAssertTrue(editors.contains { $0.contains("FRONT DOCUMENT") }, "got \(editors)")
        XCTAssertTrue(editors.contains { $0.contains("BACK DOCUMENT") }, "got \(editors)")
        XCTAssertFalse(editors.contains { $0.contains("STALE DOCUMENT") }, "a document from an older session came back: \(editors)")

        // Which document is actually in front, not just how many came back. The session recorded
        // Front.md at order 0, and the opens finish in whatever order they finish in, so this is the
        // part that depends on the stacking being re-applied rather than inherited from a completion.
        //
        // NOT YET RUN. This assertion was added after UI tests stopped being able to activate the app on
        // the development machine — reproduced with the change it covers reverted, so it is the machine
        // and not the code, but it does mean nobody has watched this assertion pass or fail. Run
        // `Scripts/test-ui.sh` on a machine that can, before trusting it.
        let titles = app.windows.allElementsBoundByIndex.map(\.title)
        print("RELAUNCH_SESSION window titles, front to back: \(titles)")
        XCTAssertTrue(titles.first?.contains("Front") == true,
                      "the frontmost window is not the document the session had in front: \(titles)")
        // The files are untouched by a restore.
        XCTAssertEqual(try String(contentsOf: front_, encoding: .utf8), "FRONT DOCUMENT\n")
        XCTAssertEqual(try String(contentsOf: back, encoding: .utf8), "BACK DOCUMENT\n")
        app.terminate()
    }

    /// Quitting with a document open records it as open at the quit, and the next launch brings it
    /// back. The writing half is `testQuitRecordsAnOpenDocumentAsQuitNotClosed`; this is the round trip.
    func testQuitRestoresTheDocumentThatWasOpen() throws {
        let output = try temporaryOutput("AirMarkQuitRestore")
        let file = output.appendingPathComponent("Note.md")
        try Data("QUIT AND COME BACK\n".utf8).write(to: file)
        let app = XCUIApplication()
        app.launchArguments = ["--open", file.path]
        app.launchEnvironment["AIRMARK_STATE_DIR"] = output.appendingPathComponent("Recovery").path
        app.launch()
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertEqual(editor.value as? String, "QUIT AND COME BACK\n")
        // Let the launch settle before the quit: the first parse and render land after the window, and
        // a Cmd-Q that arrives before the app is ready for keys is not the thing under test.
        sleep(3)
        app.typeKey("q", modifierFlags: .command)

        let restored = relaunch(app, output)
        XCTAssertEqual(restored.value as? String, "QUIT AND COME BACK\n", "the document open at the quit did not come back")
        app.terminate()
    }

    // There is no UI test for a window resize, and not for want of trying. Four ways were measured on
    // this machine and none of them both resizes the window and leaves the suite usable:
    //
    //   - `XCUICoordinate.press(forDuration:thenDragTo:)` across the whole resize margin, and on the
    //     title bar: the window neither moved nor resized, for any grab point.
    //   - HID `CGEvent`s posted to `.cghidEventTap`: `NSEvent.mouseLocation` was unchanged afterwards,
    //     so the runner does not get to post them here.
    //   - The accessibility API, to set the window's size directly: `kAXErrorAPIDisabled`.
    //   - Double-clicking the title bar to zoom: harmless, and it does not zoom this window.
    //
    // The full-screen button does work and does resize the window, dramatically — and terminating out
    // of the space it creates left the next test failing with "Cmd-Q did not quit the app", twice,
    // including a test that passes on its own. A resize test that breaks the tests after it is worse
    // than no resize test.
    //
    // What resize coverage there is lives elsewhere: `ResizeTests` for the behaviour and
    // `RecoveryResizeTableBench.liveResizeCost` for the numbers, both driving frame changes on a real
    // window in process. Neither puts `view.inLiveResize` true, so the one line that arms no wait
    // during a drag is still uncovered.

    /// Typing, keyboard-only formatting, undo, and Replace All through the find bar. Needs an idle machine: keys go to the app.
    func testTypingUndoAndReplaceAll() {
        let app = XCUIApplication()
        app.launchArguments = ["--blank"]
        app.launchEnvironment["AIRMARK_STATE_DIR"] = NSTemporaryDirectory() + "AirMarkUITests-" + UUID().uuidString
        app.launch()
        useASCIIInputSource()
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.label, "Markdown editor")
        editor.click(); editor.typeText("# A note\n\nalpha **beta** alpha\n")
        XCTAssertTrue((editor.value as? String)?.contains("**beta**") == true)
        // Keyboard-only formatting: select the last word with Option-Shift-Left, then Cmd-I.
        app.typeKey(.upArrow, modifierFlags: [])
        app.typeKey(.rightArrow, modifierFlags: .command)
        app.typeKey(.leftArrow, modifierFlags: [.option, .shift])
        app.typeKey("i", modifierFlags: .command)
        XCTAssertTrue((editor.value as? String)?.contains("alpha **beta** *alpha*") == true, editor.value as? String ?? "")
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue((editor.value as? String)?.contains("alpha **beta** alpha\n") == true)
        app.typeKey(.downArrow, modifierFlags: .command)
        app.typeKey("z", modifierFlags: .command)
        XCTAssertNotEqual(editor.value as? String, "# A note\n\nalpha **beta** alpha\n")
        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertEqual(editor.value as? String, "# A note\n\nalpha **beta** alpha\n")
        app.typeKey("f", modifierFlags: [.command, .option])
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        // The bar starts with the system find pasteboard's last search; replace it.
        search.click(); app.typeKey("a", modifierFlags: .command); search.typeText("alpha")
        let replaceField = app.textFields.firstMatch
        XCTAssertTrue(replaceField.waitForExistence(timeout: 3))
        replaceField.click(); app.typeKey("a", modifierFlags: .command); replaceField.typeText("gamma")
        let all = app.buttons["All"].exists ? app.buttons["All"] : app.buttons["Replace All"]
        XCTAssertTrue(all.waitForExistence(timeout: 3), app.debugDescription)
        all.click()
        let replaced = NSPredicate { _, _ in (editor.value as? String) == "# A note\n\ngamma **beta** gamma\n" }
        expectation(for: replaced, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(app.sheets.count, 0)
    }
}
