import AppKit
import Testing
import AirMarkCore
@testable import AirMarkEditor

/// Saving, external-change detection and recovery without XCUIAutomation.
@Suite(.serialized) @MainActor struct DocumentTests {
    static let type = "net.daringfireball.markdown"
    func makeDocument(_ data: Data) throws -> (MarkdownDocument, URL, URL) {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AirMarkDocumentTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Note.md")
        try data.write(to: url)
        MarkdownDocument.recoveryStore = RecoveryStore(directory: directory.appendingPathComponent("Recovery"))
        let document = try MarkdownDocument(contentsOf: url, ofType: Self.type)
        document.makeWindowControllers()
        document.editor?.view.frame = NSRect(x: 0, y: 0, width: 880, height: 760)
        return (document, url, directory)
    }
    func append(_ document: MarkdownDocument, _ text: String) {
        let editor = document.editor!
        editor.performEdit(range: NSRange(location: editor.source.utf16.count, length: 0), replacement: text)
    }
    func settle() async throws { try await Task.sleep(for: .milliseconds(250)) }
    /// NSDocument clears the change count on the main queue after the completion handler.
    func waitUntilClean(_ document: MarkdownDocument) async throws {
        for _ in 0..<40 where document.isDocumentEdited { try await Task.sleep(for: .milliseconds(25)) }
    }

    @Test func repeatedSavesPreserveBytesWithoutFalseConflicts() async throws {
        let prefix = Data([0xEF, 0xBB, 0xBF])
        var source = "## Heading\r\n\r\n**bold** and 한글\n"
        let (document, url, directory) = try makeDocument(prefix + Data(source.utf8))
        defer { document.close(); try? FileManager.default.removeItem(at: directory) }
        for number in 1...5 {
            let addition = "Save \(number). "
            append(document, addition); source += addition
            // Let the text view close its undo group, as happens between real key events;
            // NSDocument marks the change count from that notification.
            try await settle()
            #expect(document.isDocumentEdited)
            try await document.save(to: url, ofType: Self.type, for: .saveOperation)
            #expect(try Data(contentsOf: url) == prefix + Data(source.utf8))
            try await waitUntilClean(document)
            #expect(!document.isDocumentEdited)
            // The file coordinator reports our own write back to us.
            document.presentedItemDidChange()
            try await settle()
            #expect(!document.externalConflict)
            #expect(document.windowControllers.first?.window?.subtitle == "")
        }
        #expect(document.editor?.source == source)
    }

    @Test func externalChangeWhileEditedBlocksOverwriteAndKeepsEdits() async throws {
        let (document, url, directory) = try makeDocument(Data("original\n".utf8))
        defer { document.close(); try? FileManager.default.removeItem(at: directory) }
        append(document, "local edit\n")
        try Data("changed elsewhere\n".utf8).write(to: url)
        document.presentedItemDidChange()
        try await settle()
        #expect(document.externalConflict)
        #expect(document.editor?.source == "original\nlocal edit\n")
        await #expect(throws: (any Error).self) { try await document.save(to: url, ofType: Self.type, for: .saveOperation) }
        #expect(try String(contentsOf: url, encoding: .utf8) == "changed elsewhere\n")
        // Save As to a new file keeps the edits; the conflicting file is untouched.
        let other = directory.appendingPathComponent("Copy.md")
        try await document.save(to: other, ofType: Self.type, for: .saveAsOperation)
        #expect(try String(contentsOf: other, encoding: .utf8) == "original\nlocal edit\n")
        #expect(try String(contentsOf: url, encoding: .utf8) == "changed elsewhere\n")
    }

    @Test func externalChangeWhileCleanReloads() async throws {
        let (document, url, directory) = try makeDocument(Data("original\n".utf8))
        defer { document.close(); try? FileManager.default.removeItem(at: directory) }
        try Data("changed elsewhere\n".utf8).write(to: url)
        document.presentedItemDidChange()
        try await settle()
        #expect(!document.externalConflict)
        #expect(document.editor?.source == "changed elsewhere\n")
        #expect(!document.isDocumentEdited)
    }

    @Test func recoveryRecordFollowsEditsAndClose() async throws {
        let (document, _, directory) = try makeDocument(Data("draft\n".utf8))
        defer { try? FileManager.default.removeItem(at: directory) }
        append(document, "more")
        try await Task.sleep(for: .milliseconds(900))
        let store = try #require(MarkdownDocument.recoveryStore)
        let records = await store.records()
        #expect(records.first?.source == "draft\nmore")
        #expect(records.first?.id == document.identity)
        document.close()
    }
}
