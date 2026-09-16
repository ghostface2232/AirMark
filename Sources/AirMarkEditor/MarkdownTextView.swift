import AppKit
import AirMarkCore

@MainActor public final class MarkdownTextView: NSTextView {
    weak var editor: EditorController?
    public override func unmarkText() { super.unmarkText(); editor?.compositionEnded() }
    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let offset = characterIndexForInsertion(at: point)
        if editor?.enterElement(at: offset) == true { window?.makeFirstResponder(self); return }
        if event.clickCount == 1, event.modifierFlags.intersection([.shift, .command, .option]).isEmpty, editor?.toggleCheckbox(at: offset) == true { return }
        super.mouseDown(with: event)
    }
    public override func insertNewline(_ sender: Any?) {
        guard !hasMarkedText(), selectedRange().length == 0 else { super.insertNewline(sender); return }
        let selected = selectedRange(), paragraph = (string as NSString).paragraphRange(for: selected)
        let before = (string as NSString).substring(with: NSRange(location: paragraph.location, length: selected.location - paragraph.location))
        if let regex = try? NSRegularExpression(pattern: "^([ \\t]*)([-+*]|[0-9]+[.)]|>)([ \\t]+)(\\[[ xX]\\][ \\t]+)?"),
           let match = regex.firstMatch(in: before, range: NSRange(location: 0, length: before.utf16.count)) {
            let ns = before as NSString
            var prefix = ns.substring(with: match.range)
            let content = ns.substring(from: NSMaxRange(match.range))
            if content.isEmpty { editor?.performEdit(range: NSRange(location: paragraph.location, length: before.utf16.count), replacement: ""); return }
            let marker = ns.substring(with: match.range(at: 2))
            if let number = Int(marker.dropLast()) {
                prefix = ns.substring(with: match.range(at: 1)) + String(number + 1) + String(marker.suffix(1)) + " "
            } else { prefix = prefix.replacingOccurrences(of: "[x]", with: "[ ]").replacingOccurrences(of: "[X]", with: "[ ]") }
            let newline = string.contains("\r\n") ? "\r\n" : "\n"
            editor?.performEdit(range: selected, replacement: newline + prefix)
        } else { super.insertNewline(sender) }
    }
    public override func insertTab(_ sender: Any?) {
        guard !hasMarkedText() else { super.insertTab(sender); return }
        editor?.performEdit(range: selectedRange(), replacement: "    ")
    }
    @objc public func boldMarkdown(_ sender: Any?) { editor?.wrapSelection("**") }
    @objc public func italicMarkdown(_ sender: Any?) { editor?.wrapSelection("*") }
    @objc public func codeMarkdown(_ sender: Any?) { editor?.wrapSelection("`") }
    @objc public func linkMarkdown(_ sender: Any?) { editor?.wrapSelection("[", closing: "](https://)") }
    @objc public func taskMarkdown(_ sender: Any?) { editor?.toggleTask() }
    @objc public func toggleMarkers(_ sender: Any?) { editor?.showsMarkers.toggle() }
    @objc public func increaseFont(_ sender: Any?) { guard let editor else { return }; editor.fontSize = min(32, editor.fontSize + 1) }
    @objc public func decreaseFont(_ sender: Any?) { guard let editor else { return }; editor.fontSize = max(12, editor.fontSize - 1) }
}
