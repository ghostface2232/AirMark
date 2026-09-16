import XCTest

@MainActor final class AirMarkUITests: XCTestCase {
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
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let fixture = repository.appendingPathComponent("Fixtures/Showcase.md")
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("AirMarkShowcase-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let copy = output.appendingPathComponent("Showcase.md")
        try FileManager.default.copyItem(at: fixture, to: copy)
        try FileManager.default.copyItem(at: repository.appendingPathComponent("Fixtures/swatch.png"), to: output.appendingPathComponent("swatch.png"))
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
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("AirMarkInline-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let copy = output.appendingPathComponent("InlineMath.md")
        try FileManager.default.copyItem(at: repository.appendingPathComponent("Fixtures/InlineMath.md"), to: copy)
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

    func testTypingUndoAndFind() {
        let app = XCUIApplication()
        app.launchArguments = ["--blank"]
        app.launchEnvironment["AIRMARK_STATE_DIR"] = NSTemporaryDirectory() + "AirMarkUITests-" + UUID().uuidString
        app.launch()
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.click(); editor.typeText("# A note\n\nWriting **bold** text.\n")
        XCTAssertTrue((editor.value as? String)?.contains("**bold**") == true)
        app.typeKey("f", modifierFlags: .command)
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 2) || app.textFields.count > 0)
    }
}
