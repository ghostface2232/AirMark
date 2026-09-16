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
        #expect(try paragraph(7).string.hasPrefix("- \u{2610}"))
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
        #expect(try paragraph(7).string.hasPrefix("- \u{2611}"))
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
        editor.textView.unmarkText()
        #expect(!editor.textView.hasMarkedText())
    }
}
