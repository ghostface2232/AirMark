import AppKit
import Testing
import AirMarkCore
@testable import AirMarkEditor

/// Saving, external-change detection and recovery without XCUIAutomation.
/// Other suites run in parallel and their documents also write to `MarkdownDocument.recoveryStore`,
/// so recovery assertions select this test's record by document identity.
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
        #expect(!document.externalConflict)
        append(document, "after Save As\n")
        try await document.save(to: other, ofType: Self.type, for: .saveOperation)
        #expect(try String(contentsOf: other, encoding: .utf8) == "original\nlocal edit\nafter Save As\n")
    }

    @Test func externalRestoreOfPreviouslySavedBytesIsNotIgnored() async throws {
        let original = Data("original\n".utf8)
        let (document, url, directory) = try makeDocument(original)
        defer { document.close(); try? FileManager.default.removeItem(at: directory) }
        append(document, "saved edit\n")
        try await settle()
        try await document.save(to: url, ofType: Self.type, for: .saveOperation)
        try await waitUntilClean(document)
        try original.write(to: url, options: .atomic)
        document.presentedItemDidChange()
        try await settle()
        #expect(document.editor?.source == "original\n")
        #expect(!document.isDocumentEdited)
    }

    @Test func failedSaveDoesNotAdvancePersistedSnapshot() async throws {
        let (document, _, directory) = try makeDocument(Data("saved\n".utf8))
        defer { document.close(); try? FileManager.default.removeItem(at: directory) }
        append(document, "pending\n")
        try await settle()
        let before = document.snapshot.persistedData()
        let blocker = directory.appendingPathComponent("not-a-directory")
        try Data().write(to: blocker)
        await #expect(throws: (any Error).self) {
            try await document.save(to: blocker.appendingPathComponent("Fail.md"), ofType: Self.type, for: .saveAsOperation)
        }
        #expect(document.snapshot.persistedData() == before)
        #expect(!document.snapshot.isWriting())
        #expect(document.isDocumentEdited)
        #expect(document.editor?.source == "saved\npending\n")
    }

    @Test func exportingCopyDoesNotChangeOriginalSaveBaseline() async throws {
        let original = Data("original\n".utf8)
        let (document, url, directory) = try makeDocument(original)
        defer { document.close(); try? FileManager.default.removeItem(at: directory) }
        append(document, "local edit\n")
        try await settle()
        let copy = directory.appendingPathComponent("Export.md")
        try await document.save(to: copy, ofType: Self.type, for: .saveToOperation)
        #expect(document.snapshot.persistedData() == original)
        #expect(try Data(contentsOf: url) == original)
        #expect(try String(contentsOf: copy, encoding: .utf8) == "original\nlocal edit\n")
        try await document.save(to: url, ofType: Self.type, for: .saveOperation)
        #expect(try Data(contentsOf: url) == Data("original\nlocal edit\n".utf8))
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

    @Test func movedFileUpdatesEditorPathAndRecovery() async throws {
        let (document, url, directory) = try makeDocument(Data("![pic](pic.png)\n".utf8))
        defer { document.close(); try? FileManager.default.removeItem(at: directory) }
        let moved = directory.appendingPathComponent("Renamed.md")
        try FileManager.default.moveItem(at: url, to: moved)
        document.presentedItemDidMove(to: moved)
        try await settle()
        #expect(document.fileURL == moved)
        #expect(document.editor?.fileURL == moved)
        try await Task.sleep(for: .milliseconds(700))
        let records = await MarkdownDocument.recoveryStore!.records().filter { $0.id == document.identity }
        #expect(records.first?.filePath == moved.path)
    }

    @Test func deletedFileKeepsTextAsUntitledDocument() async throws {
        let (document, url, directory) = try makeDocument(Data("keep me\n".utf8))
        defer { document.close(); try? FileManager.default.removeItem(at: directory) }
        // The coordinator deletes the file once the completion handler runs, so the document must
        // already have let go of the path by then.
        // The handler is read on the main actor, where both the test and the document run.
        nonisolated(unsafe) let observed = document
        let urlAtCompletion: URL?? = await withCheckedContinuation { continuation in
            document.accommodatePresentedItemDeletion { _ in
                continuation.resume(returning: MainActor.assumeIsolated { observed.fileURL })
            }
        }
        #expect(urlAtCompletion == .some(nil), "fileURL at completion: \(String(describing: urlAtCompletion))")
        try FileManager.default.removeItem(at: url)
        try await settle()
        #expect(document.fileURL == nil)
        #expect(document.isDocumentEdited)
        #expect(document.editor?.source == "keep me\n")
        #expect(document.displayName.contains("Note.md"))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        try await Task.sleep(for: .milliseconds(700))
        let records = await MarkdownDocument.recoveryStore!.records().filter { $0.id == document.identity }
        #expect(records.first?.source == "keep me\n")
        #expect(records.first?.filePath == nil)
        // Save As restores a file; the old path stays deleted.
        let other = directory.appendingPathComponent("Restored.md")
        try await document.save(to: other, ofType: Self.type, for: .saveAsOperation)
        #expect(try String(contentsOf: other, encoding: .utf8) == "keep me\n")
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func forceQuitRecoveryReopensUnsavedEdits() async throws {
        let (document, url, directory) = try makeDocument(Data("saved\n".utf8))
        defer { try? FileManager.default.removeItem(at: directory) }
        append(document, "unsaved")
        try await Task.sleep(for: .milliseconds(900))
        // A force quit never reaches close(); the record written after the edit is what survives.
        let records = await MarkdownDocument.recoveryStore!.records().filter { $0.id == document.identity }
        let plan = LaunchPlan.resolve(records: records, recentPaths: [url.path], fileData: { try? Data(contentsOf: URL(fileURLWithPath: $0)) })
        guard case .recoverDraft(let record) = plan else { Issue.record("expected a draft, got \(plan)"); return }
        #expect(record.source == "saved\nunsaved")
        #expect(record.filePath == url.path)
        #expect(record.selection.location == "saved\nunsaved".utf16.count)
        document.close()
    }

    @Test func recoveryRecordFollowsEditsAndClose() async throws {
        let (document, _, directory) = try makeDocument(Data("draft\n".utf8))
        defer { try? FileManager.default.removeItem(at: directory) }
        append(document, "more")
        try await Task.sleep(for: .milliseconds(900))
        let store = try #require(MarkdownDocument.recoveryStore)
        let records = await store.records().filter { $0.id == document.identity }
        #expect(records.count == 1)
        #expect(records.first?.source == "draft\nmore")
        document.close()
    }
}
