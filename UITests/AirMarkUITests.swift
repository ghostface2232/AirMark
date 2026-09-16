import XCTest

@MainActor final class AirMarkUITests: XCTestCase {
    /// Fixtures are bundled with the runner; reading them from the source tree would trigger the
    /// Documents-folder permission dialog and block the run.
    static var fixtures: URL { Bundle(for: AirMarkUITests.self).resourceURL!.appendingPathComponent("Fixtures") }
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
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        for number in 1...5 {
            editor.click()
            app.typeKey(.downArrow, modifierFlags: .command)
            let addition = "Save \(number). "
            editor.typeText(addition)
            source += addition
            app.typeKey("s", modifierFlags: .command)
            let expected = prefix + Data(source.utf8)
            let saved = NSPredicate { _, _ in (try? Data(contentsOf: file)) == expected }
            expectation(for: saved, evaluatedWith: nil)
            waitForExpectations(timeout: 10)
            // A save that AirMark mistook for an external change used to show an error sheet here.
            XCTAssertNotEqual(app.state, .notRunning)
            XCTAssertEqual(app.sheets.count, 0, app.sheets.firstMatch.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " / "))
            XCTAssertEqual(app.dialogs.count, 0, app.dialogs.firstMatch.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " / "))
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
    }

    /// Typing, undo, and Replace All through the find bar. Needs an idle machine: keys go to the app.
    func testTypingUndoAndReplaceAll() {
        let app = XCUIApplication()
        app.launchArguments = ["--blank"]
        app.launchEnvironment["AIRMARK_STATE_DIR"] = NSTemporaryDirectory() + "AirMarkUITests-" + UUID().uuidString
        app.launch()
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.click(); editor.typeText("# A note\n\nalpha **beta** alpha\n")
        XCTAssertTrue((editor.value as? String)?.contains("**beta**") == true)
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
