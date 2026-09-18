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
