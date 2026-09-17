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

    /// Relative image paths resolve against the document's location, which Save As changes
    /// without any edit or file-presenter callback.
    @Test func saveAsResolvesRelativeImagesFromTheNewLocation() async throws {
        let (document, _, directory) = try makeDocument(Data("![Two color swatches](swatch.png)\n".utf8))
        defer { document.close(); try? FileManager.default.removeItem(at: directory) }
        let editor = try #require(document.editor)
        let window = try #require(document.windowControllers.first?.window)
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        editor.view.layoutSubtreeIfNeeded(); editor.viewDidAppear()
        // The image exists only beside the new location.
        for _ in 0..<100 where editor.renderErrorCount == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(editor.renderErrorCount == 1)
        let elsewhere = directory.appendingPathComponent("Elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try FileManager.default.copyItem(at: repository.appendingPathComponent("Fixtures/swatch.png"), to: elsewhere.appendingPathComponent("swatch.png"))
        let moved = elsewhere.appendingPathComponent("Note.md")
        try await document.save(to: moved, ofType: Self.type, for: .saveAsOperation)
        #expect(editor.fileURL == moved)
        for _ in 0..<100 where editor.renderedElementCount == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(editor.renderedElementCount == 1)
        #expect(editor.renderErrorCount == 0)
    }

    @Test func forceQuitRecoveryReopensUnsavedEdits() async throws {
        let (document, url, directory) = try makeDocument(Data("saved\n".utf8))
        defer { try? FileManager.default.removeItem(at: directory) }
        append(document, "unsaved")
        // A force quit never reaches close(); the record written after the edit is what survives. It is
        // written 600ms after the edit, later under load, so wait for it rather than a fixed delay.
        var records: [RecoveryRecord] = []
        for _ in 0..<100 {
            records = await MarkdownDocument.recoveryStore!.records().filter { $0.id == document.identity && $0.source == "saved\nunsaved" }
            if !records.isEmpty { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let plans = LaunchPlan.resolve(records: records, recentPaths: [url.path], fileData: { try? Data(contentsOf: URL(fileURLWithPath: $0)) })
        guard case .recoverDraft(let record)? = plans.last else { Issue.record("expected a draft, got \(plans)"); return }
        #expect(record.source == "saved\nunsaved")
        #expect(record.filePath == url.path)
        #expect(record.selection.location == "saved\nunsaved".utf16.count)
        document.close()
    }

    /// Two documents edited at once are both recovered. A launch used to take the newest record alone,
    /// so the other draft stayed in the recovery directory with no way to reach it.
    @Test func everyUnsavedDocumentOpenAtOnceIsRecovered() async throws {
        let (first, firstURL, directory) = try makeDocument(Data("first saved\n".utf8))
        let secondURL = directory.appendingPathComponent("Second.md")
        try Data("second saved\n".utf8).write(to: secondURL)
        let second = try MarkdownDocument(contentsOf: secondURL, ofType: Self.type)
        // Closed here, not at the end: a failed expectation must not leave documents behind for the
        // suites that run after this one.
        defer { first.close(); second.close(); try? FileManager.default.removeItem(at: directory) }
        second.makeWindowControllers()
        second.editor?.view.frame = NSRect(x: 0, y: 0, width: 880, height: 760)
        append(first, "one")
        append(second, "two")
        var records: [RecoveryRecord] = []
        for _ in 0..<100 {
            records = await MarkdownDocument.recoveryStore!.records()
            if records.contains(where: { $0.id == first.identity && $0.source.hasSuffix("one") }),
               records.contains(where: { $0.id == second.identity && $0.source.hasSuffix("two") }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let plans = LaunchPlan.resolve(records: records, recentPaths: [], fileData: { try? Data(contentsOf: URL(fileURLWithPath: $0)) })
        // Other suites run in parallel and write to the same store; select this test's two documents.
        let mine: Set<UUID> = [first.identity, second.identity]
        let drafts = plans.compactMap { plan -> RecoveryRecord? in
            if case .recoverDraft(let record) = plan, mine.contains(record.id) { return record }
            return nil
        }
        #expect(drafts.count == 2, "both open documents are restored, not only the newest record")
        #expect(drafts.contains { $0.id == first.identity && $0.source == "first saved\none" && $0.filePath == firstURL.path })
        #expect(drafts.contains { $0.id == second.identity && $0.source == "second saved\ntwo" && $0.filePath == secondURL.path })
        // Both were open, so both records say so and both hold text that is on no disk.
        #expect(drafts.allSatisfy { $0.state == .open && $0.hasUnsavedChanges })
    }

    /// Closing a document records that the user put it away, so the next launch does not reopen every
    /// document ever closed; the most recent one still comes back when nothing was left open.
    @Test func closingADocumentRecordsItAsClosed() async throws {
        let (document, url, directory) = try makeDocument(Data("saved\n".utf8))
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = document.identity
        _ = try #require(try await recoveryRecord(document) { $0.state == .open })
        document.close()
        var closed: RecoveryRecord?
        for _ in 0..<100 {
            closed = await MarkdownDocument.recoveryStore!.records().first { $0.id == identity }
            if closed?.state == .closed { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let record = try #require(closed)
        #expect(record.state == .closed)
        #expect(!record.hasUnsavedChanges, "the text was on disk when it was closed")
        let plans = LaunchPlan.resolve(records: [record], recentPaths: [], fileData: { try? Data(contentsOf: URL(fileURLWithPath: $0)) })
        #expect(plans == [.openFile(path: url.path, record: record)], "the last document still reopens when nothing was left open")
    }

    /// Waits for this document's recovery record to satisfy `condition`.
    func recoveryRecord(_ document: MarkdownDocument, where condition: (RecoveryRecord) -> Bool) async throws -> RecoveryRecord? {
        for _ in 0..<100 {
            if let record = await MarkdownDocument.recoveryStore!.records().first(where: { $0.id == document.identity }), condition(record) { return record }
            try await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    /// Moving the caret after an edit records the new position with the edited source.
    @Test func caretMoveAfterEditKeepsRecoveredSource() async throws {
        let (document, _, directory) = try makeDocument(Data("saved\n".utf8))
        defer { document.close(); try? FileManager.default.removeItem(at: directory) }
        append(document, "한글😀\r\n")
        let edited = try #require(try await recoveryRecord(document) { $0.source == "saved\n한글😀\r\n" })
        document.editor?.textView.setSelectedRange(NSRange(location: 2, length: 3))
        let moved = try #require(try await recoveryRecord(document) { $0.selection == SourceSpan(2, 3) })
        #expect(moved.source == edited.source)
        #expect(moved.hasBOM == edited.hasBOM)
        append(document, "more")
        let later = try #require(try await recoveryRecord(document) { $0.source.hasSuffix("more") })
        #expect(later.source == "saved\n한글😀\r\nmore")
    }

    /// The source can change without an editor revision: a document with no window reads its file again.
    /// Its record must carry the new source even when nothing else about the record changed.
    @Test func rereadSourceWithoutEditorReachesRecovery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AirMarkDocumentTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Note.md")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("first\n".utf8).write(to: url)
        let store = RecoveryStore(directory: directory.appendingPathComponent("Recovery"))
        let document = try MarkdownDocument(contentsOf: url, ofType: Self.type)
        try await store.save(document.record())
        try document.read(from: Data("second\n".utf8), ofType: Self.type)
        var reread = document.record()
        reread.date = Date().addingTimeInterval(1)
        try await store.save(reread)
        #expect(await store.records().first?.source == "second\n")
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
