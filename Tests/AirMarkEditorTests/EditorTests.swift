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
