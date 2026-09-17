import AppKit
import Darwin
import Testing
import AirMarkCore
@testable import AirMarkEditor

/// What recovery writes to disk for a large document while it is edited, while only the caret or the
/// scroll position changes, and while nothing happens. Slow to set up, so it runs only when
/// AIRMARK_RECOVERY_IO=1. Byte counts are this process's disk writes (`proc_pid_rusage`), which other
/// suites would add to; run it on its own.
@Suite(.serialized) @MainActor struct RecoveryIOTests {
    static func diskBytesWritten() -> UInt64 {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        return status == 0 ? info.ri_diskio_byteswritten : 0
    }
    static func ms(_ duration: Duration) -> Double { Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15 }
    static func megabytes(_ bytes: UInt64) -> String { String(format: "%.2fMB", Double(bytes) / 1_048_576) }
    /// Identity and size of every file in `directory`; an atomic replacement changes the identity.
    static func files(in directory: URL) -> [String: String] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileResourceIdentifierKey, .fileSizeKey])) ?? []
        return Dictionary(uniqueKeysWithValues: urls.map { url in
            let values = try? url.resourceValues(forKeys: [.fileResourceIdentifierKey, .fileSizeKey])
            return (url.lastPathComponent, "\(values?.fileResourceIdentifier.map { "\($0)" } ?? "")|\(values?.fileSize ?? 0)")
        })
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AIRMARK_RECOVERY_IO"] == "1"))
    func tenMegabyteRecoveryWrites() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AirMarkRecoveryIO-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recovery = directory.appendingPathComponent("Recovery")
        let store = RecoveryStore(directory: recovery)
        MarkdownDocument.recoveryStore = store
        let source = ScaleTests.source(bytes: 10_000_000)
        let document = MarkdownDocument()
        document.snapshot.set(DocumentBytes(source: source, hasBOM: false))
        document.makeWindowControllers()
        let editor = try #require(document.editor)
        let window = try #require(document.windowControllers.first?.window)
        window.orderFront(nil)
        defer { document.close() }
        editor.view.frame = NSRect(x: 0, y: 0, width: 880, height: 760); editor.view.layoutSubtreeIfNeeded()
        let clock = ContinuousClock()
        for _ in 0..<2400 where editor.parsed.revision != editor.revision || editor.parsed.styles.isEmpty { try await Task.sleep(for: .milliseconds(25)) }
        try #require(editor.parsed.revision == editor.revision)

        /// Runs `action`, then waits until recovery files stop changing for 1.2s (the debounce is 600ms),
        /// and reports the process's disk writes and how many recovery files were replaced.
        func observe(_ action: () async -> Void) async throws -> (bytes: UInt64, replaced: Int) {
            let before = Self.files(in: recovery), bytes = Self.diskBytesWritten()
            await action()
            var last = before, stable = clock.now
            let deadline = clock.now + .seconds(20)
            while clock.now < deadline {
                try await Task.sleep(for: .milliseconds(50))
                let now = Self.files(in: recovery)
                if now != last { last = now; stable = clock.now }
                if stable.duration(to: clock.now) >= .milliseconds(1200) { break }
            }
            let replaced = last.filter { before[$0.key] != $0.value }.count
            return (Self.diskBytesWritten() - bytes, replaced)
        }
        func line(_ name: String, _ samples: [(bytes: UInt64, replaced: Int)]) -> String {
            let bytes = samples.map(\.bytes).sorted()
            return "\(name) per_step_bytes p50=\(Self.megabytes(bytes[(bytes.count - 1) / 2])) max=\(Self.megabytes(bytes.last!)) total=\(Self.megabytes(bytes.reduce(0, +))) files_replaced=\(samples.map { String($0.replaced) }.joined(separator: ","))"
        }
        // Let the write scheduled when the window opened land first.
        _ = try await observe {}
        let text = editor.textView.textStorage!.mutableString
        let middle = text.paragraphRange(for: NSRange(location: text.length / 2, length: 0)).location

        var edits: [(bytes: UInt64, replaced: Int)] = []
        for number in 0..<5 {
            edits.append(try await observe { editor.performEdit(range: NSRange(location: middle + number, length: 0), replacement: "x") })
        }
        var carets: [(bytes: UInt64, replaced: Int)] = []
        for number in 0..<5 {
            carets.append(try await observe { editor.textView.setSelectedRange(NSRange(location: middle + 40 + number * 7, length: 0)) })
        }
        var scrolls: [(bytes: UInt64, replaced: Int)] = []
        for number in 1...5 {
            scrolls.append(try await observe { editor.scrollView.contentView.scroll(to: NSPoint(x: 0, y: Double(number) * 900)) })
        }
        // A continuous scroll: 60 small steps a frame apart, then a pause.
        let continuous = try await observe {
            for step in 0..<60 { editor.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 5_000 + Double(step) * 40)) }
        }
        // A reading session: scroll a screen, pause 1.5s, ten times.
        let reading = try await observe {
            for step in 0..<10 {
                editor.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 10_000 + Double(step) * 700))
                try? await Task.sleep(for: .milliseconds(1500))
            }
        }
        let idleBytes = Self.diskBytesWritten()
        let idleFiles = Self.files(in: recovery)
        try await Task.sleep(for: .seconds(5))
        let idle = (bytes: Self.diskBytesWritten() - idleBytes, replaced: Self.files(in: recovery).filter { idleFiles[$0.key] != $0.value }.count)

        // The store alone. The document's own record after an edit, whose source is bridged from the text
        // view, and then with only the selection changed; then native records whose source changed.
        var documentChanged: [Double] = [], documentSelection: [Double] = []
        for number in 0..<5 {
            editor.performEdit(range: NSRange(location: middle + 100 + number, length: 0), replacement: "z")
            document.recoveryTask?.cancel()
            var start = clock.now
            try await store.save(document.record())
            documentChanged.append(Self.ms(start.duration(to: clock.now)))
            editor.textView.setSelectedRange(NSRange(location: middle + 200 + number, length: 0))
            document.recoveryTask?.cancel()
            start = clock.now
            try await store.save(document.record())
            documentSelection.append(Self.ms(start.duration(to: clock.now)))
        }
        var changed: [Double] = [], selectionOnly: [Double] = []
        var record = document.record()
        for number in 0..<5 {
            record.revision += 1; record.source += "y"; record.date = Date()
            var start = clock.now
            try await store.save(record)
            changed.append(Self.ms(start.duration(to: clock.now)))
            record.selection = SourceSpan(number, 0); record.date = Date()
            start = clock.now
            try await store.save(record)
            selectionOnly.append(Self.ms(start.duration(to: clock.now)))
        }
        func summary(_ samples: [Double]) -> String {
            let sorted = samples.sorted()
            return String(format: "p50=%.1fms max=%.1fms", sorted[(sorted.count - 1) / 2], sorted.last!)
        }
        let loadStart = clock.now
        let records = await store.records()
        let loaded = Self.ms(loadStart.duration(to: clock.now))
        #expect(records.first?.source == record.source)
        #expect(records.first?.selection == record.selection)

        let size = Self.files(in: recovery).values.compactMap { Int($0.split(separator: "|").last ?? "") }.reduce(0, +)
        print("RECOVERY_IO source=\(Self.megabytes(UInt64(source.utf8.count))) recovery_dir=\(Self.megabytes(UInt64(size))) files=\(Self.files(in: recovery).keys.sorted())")
        print("RECOVERY_IO " + line("edit", edits))
        print("RECOVERY_IO " + line("caret", carets))
        print("RECOVERY_IO " + line("scroll_pause", scrolls))
        print("RECOVERY_IO " + line("scroll_continuous_60_steps", [continuous]))
        print("RECOVERY_IO " + line("reading_10_scrolls_1500ms_apart", [reading]))
        print("RECOVERY_IO " + line("idle_5s", [idle]))
        print("RECOVERY_IO store_save document_record source_changed \(summary(documentChanged)) selection_only \(summary(documentSelection))")
        print("RECOVERY_IO store_save native source_changed \(summary(changed)) selection_only \(summary(selectionOnly)) records_load=\(String(format: "%.1fms", loaded))")
    }
}
