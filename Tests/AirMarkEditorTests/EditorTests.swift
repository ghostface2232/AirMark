import AppKit
import Testing
import AirMarkCore
@testable import AirMarkEditor

/// Concealed markers keep their source characters; only their presentation attributes hide them.
@MainActor func isConcealed(_ text: NSAttributedString, _ needle: String) -> Bool {
    let range = (text.string as NSString).range(of: needle)
    guard range.location != NSNotFound else { return false }
    var hidden = true
    text.enumerateAttribute(.font, in: range) { value, _, _ in
        if let font = value as? NSFont, font.pointSize > 0.02 { hidden = false }
    }
    return hidden
}

@Suite(.serialized) @MainActor struct EditorTests {
    func make(_ source: String) async throws -> EditorController {
        _ = NSApplication.shared
        let editor = EditorController(source: source)
        editor.loadViewIfNeeded()
        for _ in 0..<100 {
            if editor.parsed.source == source { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        return editor
    }
    @Test func presentationDoesNotChangeSource() async throws {
        let source = "# Heading\r\n\r\n**한글😀** and *italic*\n\nlast"
        let editor = try await make(source)
        editor.textView.setSelectedRange(NSRange(location: source.utf16.count, length: 0))
        let storage = try #require(editor.textView.textLayoutManager?.textContentManager as? NSTextContentStorage)
        let paragraph = try #require(editor.textContentStorage(storage, textParagraphWith: NSRange(location: 13, length: 26)))
        #expect(paragraph.attributedString.length == 26)
        #expect(editor.source == source)
        #expect(editor.textKitFallbackCount == 0)
    }
    @Test func editsKeepMarkdownAndUndo() async throws {
        let editor = try await make("hello")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = editor
        window.makeFirstResponder(editor.textView)
        editor.textView.setSelectedRange(NSRange(location: 0, length: 5))
        editor.wrapSelection("**")
        #expect(editor.source == "**hello**")
        editor.textView.undoManager?.undo()
        #expect(editor.source == "hello")
        window.orderOut(nil)
    }
    @Test func movingCaretNeverChangesPresentation() async throws {
        let editor = try await make("## Heading **bold**\n\nBody")
        let storage = try #require(editor.textView.textLayoutManager?.textContentManager as? NSTextContentStorage)
        let range = (editor.source as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
        let before = try #require(editor.textContentStorage(storage, textParagraphWith: range)).attributedString
        for position in [0, 3, 7, 13, 19, editor.source.utf16.count] {
            editor.textView.setSelectedRange(NSRange(location: position, length: 0))
            let after = try #require(editor.textContentStorage(storage, textParagraphWith: range)).attributedString
            #expect(before.isEqual(to: after))
        }
        #expect(isConcealed(before, "## "))
        #expect(isConcealed(before, "**"))
        let body = (before.string as NSString).range(of: "Heading")
        #expect((before.attribute(.font, at: body.location, effectiveRange: nil) as? NSFont)?.pointSize == 24)
    }
    @Test func headingKeepsFontBeforeBackgroundParse() async throws {
        let editor = try await make("## Heading")
        editor.textView.setSelectedRange(NSRange(location: 10, length: 0))
        editor.performEdit(range: NSRange(location: 10, length: 0), replacement: " continued")
        let storage = try #require(editor.textView.textLayoutManager?.textContentManager as? NSTextContentStorage)
        let range = NSRange(location: 0, length: editor.source.utf16.count)
        let paragraph = try #require(editor.textContentStorage(storage, textParagraphWith: range)).attributedString
        let font = try #require(paragraph.attribute(.font, at: 14, effectiveRange: nil) as? NSFont)
        #expect(font.pointSize == 24)
        #expect(isConcealed(paragraph, "## "))
        #expect(editor.source == "## Heading continued")
    }
    @Test func listsAndFencesArePresentedAsSymbols() async throws {
        let source = "- item\n- [ ] todo\n\n```swift\nlet x = 1\n```\n"
        let editor = try await make(source)
        let storage = try #require(editor.textView.textLayoutManager?.textContentManager as? NSTextContentStorage)
        func paragraph(_ location: Int) throws -> NSAttributedString {
            let range = (editor.source as NSString).paragraphRange(for: NSRange(location: location, length: 0))
            return try #require(editor.textContentStorage(storage, textParagraphWith: range)).attributedString
        }
        #expect(try paragraph(0).string == "\u{2022} item\n")
        func taskLabel() throws -> String? {
            let shown = try paragraph(7)
            #expect(shown.string.hasPrefix("- \u{FFFC}"))
            return (shown.attribute(.attachment, at: 2, effectiveRange: nil) as? NSTextAttachment)?.image?.accessibilityDescription
        }
        #expect(try taskLabel() == "Task")
        #expect(isConcealed(try paragraph(7), "- "))
        #expect(isConcealed(try paragraph(7), " ] todo") == false)
        let fence = try paragraph(19)
        #expect(fence.string == "```swift\n")
        #expect(isConcealed(fence, "```swift"))
        #expect(isConcealed(try paragraph(28), "let") == false)
        #expect(isConcealed(try paragraph(38), "```\n"))
        // Clicking the box toggles the source and the symbol follows the next parse.
        #expect(editor.toggleCheckbox(at: 9))
        #expect(editor.source == "- item\n- [x] todo\n\n```swift\nlet x = 1\n```\n")
        for _ in 0..<100 where editor.parsed.source != editor.source { try await Task.sleep(for: .milliseconds(20)) }
        #expect(try taskLabel() == "Completed task")
        #expect(!editor.toggleCheckbox(at: 0))
    }
    @Test func caretStaysOutsideConcealedMarkers() async throws {
        // "## Heading" 0..<10, "\n" 10, "\n" 11, "**" 12..<14, "bold" 14..<18, "**" 18..<20, " more" 20..<25
        let editor = try await make("## Heading\n\n**bold** more\n")
        let view = editor.textView
        func caret() -> Int { view.selectedRange().location }
        view.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(caret() == 3)
        view.moveLeft(nil)
        #expect(caret() == 3)
        view.setSelectedRange(NSRange(location: 13, length: 0))
        #expect(caret() == 14)
        view.moveLeft(nil)
        #expect(caret() == 11)
        view.setSelectedRange(NSRange(location: 18, length: 0))
        #expect(caret() == 18)
        view.moveRight(nil)
        #expect(caret() == 20)
        view.moveRight(nil)
        #expect(caret() == 21)
        view.moveLeft(nil)
        #expect(caret() == 20)
        view.moveLeft(nil)
        #expect(caret() == 18)
        view.setSelectedRange(NSRange(location: 19, length: 0))
        #expect(caret() == 18)
        view.setSelectedRange(NSRange(location: 14, length: 0))
        for _ in 0..<5 { view.moveRightAndModifySelection(nil) }
        #expect(view.selectedRange() == NSRange(location: 14, length: 6))
        editor.showsMarkers = true
        view.setSelectedRange(NSRange(location: 13, length: 0))
        #expect(caret() == 13)
        #expect(editor.source == "## Heading\n\n**bold** more\n")
    }
    @Test func deletingAtMarkerEdgesEditsSourceUnits() async throws {
        let editor = try await make("## Heading\n\n**bold** more\n- [ ] task\n")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = editor
        window.makeFirstResponder(editor.textView)
        defer { window.orderOut(nil) }
        let view = editor.textView
        view.setSelectedRange(NSRange(location: 3, length: 0))
        view.deleteBackward(nil)
        #expect(editor.source == "Heading\n\n**bold** more\n- [ ] task\n")
        #expect(view.selectedRange().location == 0)
        // "**bold**" is now 9..<16; Backspace after the hidden closing marker deletes the "d".
        view.setSelectedRange(NSRange(location: 17, length: 0))
        view.deleteBackward(nil)
        #expect(editor.source == "Heading\n\n**bol** more\n- [ ] task\n")
        // Forward delete before the hidden closing marker deletes the space after it.
        view.setSelectedRange(NSRange(location: 14, length: 0))
        view.deleteForward(nil)
        #expect(editor.source == "Heading\n\n**bol**more\n- [ ] task\n")
        for _ in 0..<100 where editor.parsed.source != editor.source { try await Task.sleep(for: .milliseconds(20)) }
        // Backspace at the start of task text removes the box, leaving a bullet item.
        view.setSelectedRange(NSRange(location: 27, length: 0))
        view.deleteBackward(nil)
        #expect(editor.source == "Heading\n\n**bol**more\n- task\n")
        view.undoManager?.undo()
        #expect(editor.source == "Heading\n\n**bol**more\n- [ ] task\n")
    }
    /// A two-set Korean composition inside a bold run: syllables grow through marked text, commit,
    /// and the next composition starts. Source, caret and concealment must survive every step.
    @Test func koreanCompositionSequenceInsideBold() async throws {
        let editor = try await make("**굵게**\n")
        let view = editor.textView
        let storage = try #require(view.textLayoutManager?.textContentManager as? NSTextContentStorage)
        func paragraph() throws -> NSAttributedString {
            try #require(editor.textContentStorage(storage, textParagraphWith: NSRange(location: 0, length: editor.source.utf16.count))).attributedString
        }
        let none = NSRange(location: NSNotFound, length: 0)
        view.setSelectedRange(NSRange(location: 4, length: 0))
        for (step, syllable) in ["ㅎ", "하", "한"].enumerated() {
            view.setMarkedText(syllable, selectedRange: NSRange(location: 1, length: 0), replacementRange: none)
            #expect(view.hasMarkedText())
            #expect(editor.source == "**굵게\(syllable)**\n", "step \(step)")
            let shown = try paragraph()
            #expect(shown.length == editor.source.utf16.count)
            #expect((shown.string as NSString).substring(with: view.markedRange()) == syllable)
        }
        view.insertText("한", replacementRange: none)
        #expect(!view.hasMarkedText())
        #expect(editor.source == "**굵게한**\n")
        #expect(view.selectedRange() == NSRange(location: 5, length: 0))
        for syllable in ["ㄱ", "글"] { view.setMarkedText(syllable, selectedRange: NSRange(location: 1, length: 0), replacementRange: none) }
        #expect(editor.source == "**굵게한ㄱ**\n".replacingOccurrences(of: "ㄱ", with: "글"))
        view.insertText("글", replacementRange: none)
        #expect(editor.source == "**굵게한글**\n")
        #expect(view.selectedRange() == NSRange(location: 6, length: 0))
        for _ in 0..<100 where editor.parsed.source != editor.source { try await Task.sleep(for: .milliseconds(20)) }
        let final = try paragraph()
        #expect(isConcealed(final, "**"))
        let font = try #require(final.attribute(.font, at: 5, effectiveRange: nil) as? NSFont)
        #expect(font.fontDescriptor.symbolicTraits.contains(.bold))
        // Moving left from after 글 stays inside the run; moving right steps over the hidden closing marker.
        view.moveRight(nil)
        #expect(view.selectedRange().location == 8)
        view.moveLeft(nil)
        #expect(view.selectedRange().location == 6)
    }
    /// Find goes through NSTextFinder, which reads the system find pasteboard when the text view
    /// is created. Replacing the selection is a normal edit: Markdown around the match survives and undo restores it.
    @Test func findSelectsMatchesAndReplacingKeepsMarkdown() async throws {
        let pasteboard = NSPasteboard(name: .find)
        let previous = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString("this", forType: .string)
        defer { pasteboard.clearContents(); if let previous { pasteboard.setString(previous, forType: .string) } }
        let editor = try await make("# Title\n\nfind **this** and this\n")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = editor
        window.makeFirstResponder(editor.textView)
        defer { window.orderOut(nil) }
        // NSTextFinder re-reads the find pasteboard when the application becomes active.
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApplication.shared)
        let next = NSMenuItem(); next.tag = NSTextFinder.Action.nextMatch.rawValue
        editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
        editor.textView.performFindPanelAction(next)
        #expect(editor.textView.selectedRange() == NSRange(location: 16, length: 4))
        editor.textView.insertText("that", replacementRange: editor.textView.selectedRange())
        #expect(editor.source == "# Title\n\nfind **that** and this\n")
        editor.textView.performFindPanelAction(next)
        #expect(editor.textView.selectedRange() == NSRange(location: 27, length: 4))
        editor.textView.undoManager?.undo()
        #expect(editor.source == "# Title\n\nfind **this** and this\n")
    }
    /// What assistive technology can read: the view's label, and descriptions on rendered elements.
    @Test func accessibilityExposesLabelsAndElementDescriptions() async throws {
        let editor = try await make("- [x] done\n\n| a | b |\n| - | - |\n| 1 | 2 |\n")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = editor; window.orderFront(nil)
        editor.view.frame = NSRect(x: 0, y: 0, width: 800, height: 600); editor.view.layoutSubtreeIfNeeded(); editor.viewDidAppear()
        defer { window.orderOut(nil) }
        #expect(editor.textView.accessibilityLabel() == "Markdown editor")
        #expect(editor.textView.accessibilityIdentifier() == "markdown-editor")
        #expect(editor.textView.accessibilityValue() == editor.source)
        for _ in 0..<100 where editor.renderedElementCount == 0 { try await Task.sleep(for: .milliseconds(20)) }
        let storage = try #require(editor.textView.textLayoutManager?.textContentManager as? NSTextContentStorage)
        let task = try #require(editor.textContentStorage(storage, textParagraphWith: NSRange(location: 0, length: 11))).attributedString
        #expect((task.attribute(.attachment, at: 2, effectiveRange: nil) as? NSTextAttachment)?.image?.accessibilityDescription == "Completed task")
        let table = try #require(editor.textContentStorage(storage, textParagraphWith: NSRange(location: 12, length: 10))).attributedString
        let attachment = try #require(table.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)
        #expect(attachment.image?.accessibilityDescription == "Table, 2 rows")
    }
    @Test func markedTextIsNotConcealed() async throws {
        let editor = try await make("**hello**\n")
        editor.textView.setSelectedRange(NSRange(location: 2, length: 0))
        editor.textView.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.textView.hasMarkedText())
        let storage = try #require(editor.textView.textLayoutManager?.textContentManager as? NSTextContentStorage)
        let range = NSRange(location: 0, length: editor.source.utf16.count)
        let paragraph = try #require(editor.textContentStorage(storage, textParagraphWith: range))
        #expect((paragraph.attributedString.string as NSString).substring(with: editor.textView.markedRange()) == "ㅎ")
        #expect(editor.source == "**ㅎhello**\n")
        #expect(paragraph.attributedString.length == editor.source.utf16.count)
        let marked = editor.textView.markedRange()
        let native = try #require(editor.textView.textStorage).attributedSubstring(from: marked)
        #expect(paragraph.attributedString.attributedSubstring(from: marked).isEqual(to: native), "composition attributes must remain owned by the input method")
        editor.textView.unmarkText()
        #expect(!editor.textView.hasMarkedText())
    }

    @Test func staleParseAndCompositionCannotApplyPresentation() async throws {
        let editor = try await make("**old**\n")
        let old = editor.parsed
        editor.performEdit(range: NSRange(location: 2, length: 3), replacement: "한😀")
        #expect(!editor.applyParsedDocument(old))
        #expect(Data(editor.source.utf8) == Data("**한😀**\n".utf8))
        let latest = MarkdownParser.parse(editor.source, revision: editor.revision)
        #expect(editor.applyParsedDocument(latest))
        editor.textView.setSelectedRange(NSRange(location: 2, length: 0))
        editor.textView.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let composing = MarkdownParser.parse(editor.source, revision: editor.revision)
        #expect(!editor.applyParsedDocument(composing))
        editor.textView.unmarkText()
    }

    /// Cmd-Return right after typing, before the next parse lands, must toggle the box on the
    /// caret's line at its current position, never at the previous parse's coordinates.
    @Test func toggleTaskBeforeReparseUsesCurrentCoordinates() async throws {
        let editor = try await make("- [ ] a\n- [ ] b\n")
        editor.performEdit(range: NSRange(location: 0, length: 0), replacement: "xx")
        #expect(editor.parsed.revision != editor.revision, "the parse must still be pending")
        editor.textView.setSelectedRange(NSRange(location: 14, length: 0))
        editor.toggleTask()
        #expect(editor.source == "xx- [ ] a\n- [x] b\n")
        // A box the edit itself touched has no trustworthy position until the parse; leave it alone.
        editor.performEdit(range: NSRange(location: 13, length: 1), replacement: "")
        editor.textView.setSelectedRange(NSRange(location: 15, length: 0))
        editor.toggleTask()
        #expect(editor.source == "xx- [ ] a\n- [] b\n")
    }

    /// Return continues a list item with the same kind of marker. Brackets after a marker carry
    /// over empty: a bulleted task stays a task, and an ordered item keeps its bracket text.
    @Test func newlineContinuesTaskItems() async throws {
        for (source, expected) in [("1. [ ] task", "1. [ ] task\n2. [ ] "),
                                   ("  3) [x] done", "  3) [x] done\n  4) [ ] "),
                                   ("- [X] done", "- [X] done\n- [ ] "),
                                   ("1. plain", "1. plain\n2. ")] {
            let editor = try await make(source)
            editor.textView.setSelectedRange(NSRange(location: source.utf16.count, length: 0))
            editor.textView.insertNewline(nil)
            #expect(editor.source == expected, "from \(source.debugDescription)")
        }
    }

    /// An ordered item shows its number and literal brackets; clicking or Cmd-Return changes nothing.
    @Test func orderedItemBracketsAreText() async throws {
        let source = "1. [ ] task\n"
        let editor = try await make(source)
        let storage = try #require(editor.textView.textLayoutManager?.textContentManager as? NSTextContentStorage)
        let shown = try #require(editor.textContentStorage(storage, textParagraphWith: NSRange(location: 0, length: source.utf16.count))).attributedString
        #expect(shown.string == source)
        #expect(!isConcealed(shown, "1. "))
        #expect(shown.attribute(.attachment, at: 3, effectiveRange: nil) == nil)
        #expect(!editor.toggleCheckbox(at: 3))
        editor.textView.setSelectedRange(NSRange(location: 8, length: 0))
        editor.toggleTask()
        #expect(editor.source == source)
    }

    /// Typing brackets at the start of a line, with or without a list marker before them, and then a
    /// space makes the line a task; the latest input wins, so a number or another bullet is replaced.
    @Test func bracketsThenSpaceAfterListMarkerMakeATask() async throws {
        let none = NSRange(location: NSNotFound, length: 0)
        for (typed, expected) in [("1. []", "- [ ] "), ("12) [ ]", "- [ ] "), ("* []", "- [ ] "), ("- []", "- [ ] "),
                                  ("+ [x]", "- [x] "), ("  3. []", "  - [ ] "), ("para\n\n1. []", "para\n\n- [ ] "),
                                  ("[]", "- [ ] "), ("  [ ]", "  - [ ] "), ("[x]", "- [x] "), ("para\n[]", "para\n- [ ] ")] {
            let editor = try await make(typed)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentViewController = editor
            window.makeFirstResponder(editor.textView)
            defer { window.orderOut(nil) }
            editor.textView.setSelectedRange(NSRange(location: typed.utf16.count, length: 0))
            editor.textView.insertText(" ", replacementRange: none)
            #expect(editor.source == expected, "from \(typed.debugDescription)")
            #expect(editor.textView.selectedRange() == NSRange(location: expected.utf16.count, length: 0))
            editor.textView.undoManager?.undo()
            #expect(editor.source == typed, "undo from \(typed.debugDescription)")
        }
        // Not a list marker, not at the brackets, or inside code: the space is only a space.
        for (typed, caret) in [("a []", 4), ("1.[]", 4), ("1. [] x", 7), ("[y]", 3), ("[  ]", 4), ("```\n- []\n```\n", 8), ("```\n[]\n```\n", 6)] {
            let editor = try await make(typed)
            editor.textView.setSelectedRange(NSRange(location: caret, length: 0))
            editor.textView.insertText(" ", replacementRange: none)
            let expected = (typed as NSString).replacingCharacters(in: NSRange(location: caret, length: 0), with: " ")
            #expect(editor.source == expected, "from \(typed.debugDescription)")
        }
    }

    /// Backspace after an empty fenced block, whose fences are both hidden, removes the fences and keeps
    /// the line structure around them: list prefixes and indentation stay, and so does the line break
    /// after the block. It must never delete only one fence, which turned the rest of the document into
    /// code, nor a visible line.
    @Test func backspaceAfterEmptyFencedBlockRemovesTheFences() async throws {
        let cases: [(source: String, caret: Int, expected: String)] = [
            ("a\n```\n```\nb", 10, "a\n\nb"),
            ("```swift\n```", 12, ""),
            ("a\n```\r\n```\r\nb", 12, "a\n\r\nb"),
            ("- ```\n  ```\n- c", 12, "- \n- c"),
            ("- x\n  ```\n  ```\n- c", 16, "- x\n  \n- c"),
            ("~~~\n~~~\nb", 8, "\nb"),
            // A block whose last content line is blank: Backspace deletes that line, like any last character.
            ("```\n\n\n```\nb", 10, "```\n\n```\nb"),
        ]
        for (source, caret, expected) in cases {
            let editor = try await make(source)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentViewController = editor
            window.makeFirstResponder(editor.textView)
            defer { window.orderOut(nil) }
            editor.textView.setSelectedRange(NSRange(location: caret, length: 0))
            editor.textView.deleteBackward(nil)
            #expect(editor.source == expected, "from \(source.debugDescription)")
            editor.textView.undoManager?.undo()
            #expect(editor.source == source)
        }
        let editor = try await make("```\nxy\n```\n")
        editor.textView.setSelectedRange(NSRange(location: 11, length: 0))
        editor.textView.deleteBackward(nil)
        #expect(editor.source == "```\nx\n```\n")
    }

    /// With an empty block at the start of the document there is no visible position before it; moving
    /// left from after it must settle after it rather than inside a hidden fence.
    @Test func leftFromAfterAnEmptyBlockAtTheStartStaysOutsideTheFences() async throws {
        let editor = try await make("~~~\n~~~\nb")
        editor.textView.setSelectedRange(NSRange(location: 8, length: 0))
        editor.textView.moveLeft(nil)
        #expect([0, 8].contains(editor.textView.selectedRange().location), "caret at \(editor.textView.selectedRange().location)")
    }

    @Test func referenceImageChangeDropsArtifactAtUnchangedSpan() async throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = "![picture][id]\n\n[id]: swatch.png\n"
        let editor = try await make(source)
        editor.fileURL = repository.appendingPathComponent("Fixtures/Showcase.md")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = editor; window.orderFront(nil)
        editor.view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        editor.view.layoutSubtreeIfNeeded(); editor.viewDidAppear()
        defer { window.orderOut(nil) }
        for _ in 0..<100 where editor.renderedElementCount == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(editor.renderedElementCount == 1)
        let span = try #require(editor.parsed.elements.first?.span)
        editor.performEdit(range: (source as NSString).range(of: "swatch.png"), replacement: "missing-image.png")
        for _ in 0..<100 where editor.parsed.revision != editor.revision { try await Task.sleep(for: .milliseconds(20)) }
        #expect(editor.parsed.elements.first?.span == span)
        #expect(editor.renderedElementCount == 0, "old pixels must not survive a changed reference target")
    }
}
