import AppKit
import AirMarkCore
import AirMarkRender
import os

@MainActor public final class EditorController: NSViewController, NSTextViewDelegate, @MainActor NSTextContentStorageDelegate, @MainActor NSTextStorageDelegate {
    public let textView = MarkdownTextView(usingTextLayoutManager: true)
    public let scrollView = NSScrollView()
    public var onChange: (() -> Void)?
    public var onSelectionChange: (() -> Void)?
    public var fileURL: URL?
    public private(set) var revision: UInt64 = 0
    public private(set) var parsed = ParsedDocument(source: "")
    public private(set) var textKitFallbackCount = 0
    public var showsMarkers = false { didSet { invalidatePresentation(); scheduleRenders() } }
    public var fontSize: CGFloat = 16 { didSet { artifacts.removeAll(); invalidatePresentation(); scheduleRenders() } }
    private var parseTask: Task<Void, Never>?
    private let parsingWorker = MarkdownParsingWorker()
    private var renderTasks: [SourceSpan: Task<Void, Never>] = [:]
    private var artifacts: [SourceSpan: RenderArtifact] = [:]
    private var errors: [SourceSpan: String] = [:]
    private var editingElement: SourceSpan?
    private var presentation = ParsedDocument(source: "")
    private var renderEnvironment: RenderEnvironment?
    private var renderTokens: [SourceSpan: UUID] = [:]
    private var invalidating = false
    private var themeWasDark = false
    private var observations: [NSObjectProtocol] = []
    private var sourceForInitialLoad = ""
    private var normalizingSelection = false
    private var lastSelection = NSRange(location: 0, length: 0)
    /// Set by the text view around keyboard movement so selection changes know which way the caret went.
    var caretDirection = CaretDirection.none
    private var firstPendingParse: ContinuousClock.Instant?
    private let signposter = OSSignposter(subsystem: "com.airmark.AirMark", category: "Editor")
    public var source: String { isViewLoaded ? textView.string : sourceForInitialLoad }
    public var selection: SourceSpan { SourceSpan(textView.selectedRange()) }
    public var scrollY: Double { scrollView.contentView.bounds.origin.y }
    public var renderErrorCount: Int { errors.count }
    public var renderedElementCount: Int { artifacts.count }

    public init(source: String = "") { sourceForInitialLoad = source; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    public override func loadView() {
        let root = EditorRootView()
        root.onAppearanceChange = { [weak self] in self?.appearanceChanged() }
        view = root
        scrollView.drawsBackground = true; scrollView.backgroundColor = .textBackgroundColor
        scrollView.hasVerticalScroller = true; scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder; scrollView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scrollView)
        NSLayoutConstraint.activate([scrollView.topAnchor.constraint(equalTo: root.topAnchor), scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor), scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor), scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor)])
        textView.editor = self; textView.delegate = self
        textView.isRichText = false; textView.isEditable = true; textView.isSelectable = true
        textView.allowsUndo = true; textView.usesFindBar = true; textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false; textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false; textView.isAutomaticLinkDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.isVerticallyResizable = true; textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]; textView.minSize = NSSize(width: 0, height: 300)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true; textView.textContainer?.lineFragmentPadding = 0
        textView.font = .systemFont(ofSize: fontSize); textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 40, height: 40)
        textView.setAccessibilityIdentifier("markdown-editor")
        textView.setAccessibilityLabel("Markdown editor")
        scrollView.documentView = textView
        guard let manager = textView.textLayoutManager, let content = manager.textContentManager as? NSTextContentStorage else { fatalError("TextKit 2 is required") }
        content.delegate = self
        textView.textStorage?.delegate = self
        observations.append(NotificationCenter.default.addObserver(forName: NSTextView.willSwitchToNSLayoutManagerNotification, object: textView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.textKitFallbackCount += 1; assertionFailure("Unexpected TextKit 1 fallback") }
        })
        scrollView.contentView.postsBoundsChangedNotifications = true
        observations.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRenders(); self?.onSelectionChange?() }
        })
        textView.string = sourceForInitialLoad
        scheduleParse(immediate: true)
    }
    public override func viewDidLayout() {
        super.viewDidLayout()
        let width = scrollView.contentSize.width
        let inset = max(28, (width - 720) / 2)
        if abs(textView.textContainerInset.width - inset) > 0.5 { textView.textContainerInset = NSSize(width: inset, height: 40) }
        textView.minSize = NSSize(width: width, height: scrollView.contentSize.height)
        if textView.frame.width != width { textView.setFrameSize(NSSize(width: width, height: max(textView.frame.height, scrollView.contentSize.height))) }
        scheduleRenders()
    }
    public func replaceSource(_ source: String, selection: SourceSpan? = nil, scrollY: Double? = nil) {
        sourceForInitialLoad = source
        guard isViewLoaded else { return }
        textView.string = source; revision += 1
        textView.undoManager?.removeAllActions()
        if let selection { textView.setSelectedRange(NSRange(location: min(selection.location, textView.string.utf16.count), length: 0)) }
        scheduleParse(immediate: true)
        if let scrollY { scrollView.contentView.scroll(to: NSPoint(x: 0, y: scrollY)) }
    }
    public func restore(selection: SourceSpan, scrollY: Double) {
        loadViewIfNeeded()
        let count = textView.string.utf16.count
        let location = min(selection.location, count)
        textView.setSelectedRange(NSRange(location: location, length: min(selection.length, count - location)))
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, scrollY)))
    }
    public func textDidChange(_ notification: Notification) {
        guard !invalidating else { return }
        revision += 1
        // Discard old coordinates immediately. Unedited paragraphs can retain their native layout until the next parse.
        for task in renderTasks.values { task.cancel() }; renderTasks.removeAll()
        errors.removeAll(); renderTokens.removeAll()
        onChange?()
        if !textView.hasMarkedText() { scheduleParse() }
    }
    public func textViewDidChangeSelection(_ notification: Notification) {
        guard !invalidating else { return }
        onSelectionChange?()
        guard !textView.hasMarkedText() else { return }
        if !normalizingSelection, let adjusted = normalizedSelection(textView.selectedRange(), previous: lastSelection, direction: caretDirection) {
            normalizingSelection = true
            textView.setSelectedRange(adjusted)
            normalizingSelection = false
        }
        lastSelection = textView.selectedRange()
        if let editing = editingElement {
            let selected = textView.selectedRange()
            if selected.location < editing.location || selected.location > editing.end {
                editingElement = nil
                invalidatePresentation(spans: [editing]); scheduleRenders()
            }
        }
        if parsed.revision != revision { scheduleParse() }
    }
    public func compositionEnded() { scheduleParse() }
    private func scheduleParse(immediate: Bool = false) {
        parseTask?.cancel()
        let clock = ContinuousClock()
        if firstPendingParse == nil { firstPendingParse = clock.now }
        let overdue = firstPendingParse.map { $0.duration(to: clock.now) > .milliseconds(150) } ?? false
        parseTask = Task { [weak self] in
            if !immediate && !overdue { try? await Task.sleep(for: .milliseconds(45)) }
            guard !Task.isCancelled, let self, !textView.hasMarkedText() else { return }
            firstPendingParse = nil
            let source = textView.string, revision = self.revision
            let state = signposter.beginInterval("Parse")
            guard let result = try? await parsingWorker.parse(source, revision: revision) else { return }
            signposter.endInterval("Parse", state)
            guard !Task.isCancelled, self.revision == revision, !textView.hasMarkedText() else { return }
            let old = presentation
            parsed = result; presentation = result
            let changed = Array(Set(old.styles).symmetricDifference(Set(result.styles))).map(\.span)
            invalidatePresentation(spans: changed + old.elements.map(\.span) + result.elements.map(\.span) + [SourceSpan(textView.selectedRange())])
            scheduleRenders()
        }
    }
    public func textStorage(_ textStorage: NSTextStorage, willProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters), editedRange.location != NSNotFound else { return }
        let previous = NSRange(location: editedRange.location, length: max(0, editedRange.length - delta))
        let replacement = (textStorage.string as NSString).substring(with: editedRange)
        let edit = PresentationEdit(range: previous, replacement: replacement)
        presentation = presentation.rebased(for: edit)
        artifacts = Dictionary(uniqueKeysWithValues: artifacts.compactMap { span, artifact in
            edit.unchanged(span).map { ($0, artifact) }
        })
        editingElement = editingElement.flatMap(edit.enclosing)
    }
    private func isEditing(_ span: SourceSpan) -> Bool {
        showsMarkers || editingElement.map { $0.intersects(span) } == true
    }
    private func appearanceChanged() {
        let dark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if dark != themeWasDark { themeWasDark = dark; artifacts.removeAll(); errors.removeAll(); invalidatePresentation(); scheduleRenders() }
    }
    private var environment: RenderEnvironment {
        RenderEnvironment(width: Double(max(100, scrollView.contentSize.width - 2 * textView.textContainerInset.width)), fontSize: Double(fontSize), scale: Double(view.window?.backingScaleFactor ?? 2), dark: view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
    }
    private func scheduleRenders() {
        guard isViewLoaded, view.window != nil, view.window?.isMiniaturized != true, parsed.revision == revision else { return }
        let environment = environment
        if renderEnvironment != environment {
            renderEnvironment = environment
            for task in renderTasks.values { task.cancel() }
            renderTasks.removeAll(); renderTokens.removeAll(); artifacts.removeAll(); errors.removeAll()
            invalidatePresentation(spans: parsed.elements.map(\.span))
        }
        let currentRevision = revision
        let viewport = textView.textLayoutManager?.textViewportLayoutController.viewportRange
        let content = textView.textLayoutManager?.textContentManager
        let visible: SourceSpan?
        if let viewport, let content {
            let a = content.offset(from: content.documentRange.location, to: viewport.location)
            let b = content.offset(from: content.documentRange.location, to: viewport.endLocation)
            visible = SourceSpan(max(0, a - 2000), b - a + 4000)
        } else { visible = SourceSpan(0, 5000) }
        for element in parsed.elements where !isEditing(element.span) && artifacts[element.span] == nil && errors[element.span] == nil && renderTasks[element.span] == nil {
            guard visible?.intersects(element.span) != false, renderTasks.count < 12 else { continue }
            let token = UUID(); renderTokens[element.span] = token
            renderTasks[element.span] = Task { [weak self] in
                guard let self else { return }
                defer {
                    if renderTokens[element.span] == token {
                        renderTasks[element.span] = nil; renderTokens[element.span] = nil
                    }
                }
                do {
                    let artifact = try await RenderService.shared.render(element, environment: environment, baseURL: fileURL, host: view)
                    guard !Task.isCancelled, revision == currentRevision, self.environment == environment else { return }
                    artifacts[element.span] = artifact
                } catch {
                    guard !Task.isCancelled, revision == currentRevision else { return }
                    errors[element.span] = error.localizedDescription
                }
                renderTasks[element.span] = nil
                invalidatePresentation(spans: [element.span])
            }
        }
    }
    public override func viewDidAppear() { super.viewDidAppear(); scheduleRenders() }

    private func invalidatePresentation(spans: [SourceSpan]? = nil) {
        guard isViewLoaded, !textView.hasMarkedText(), let storage = textView.textStorage,
              let manager = textView.textLayoutManager, let content = manager.textContentManager as? NSTextContentStorage else { return }
        let length = storage.length
        guard length > 0, !invalidating else { return }
        var ranges = (spans ?? [SourceSpan(0, length)]).compactMap { span -> NSRange? in
            guard span.location < length, span.location >= 0 else { return nil }
            return (storage.string as NSString).paragraphRange(for: NSRange(location: span.location, length: min(span.length, length - span.location)))
        }.sorted { $0.location < $1.location }
        var merged: [NSRange] = []
        for range in ranges {
            if let last = merged.last, NSMaxRange(last) >= range.location { merged[merged.count - 1] = NSUnionRange(last, range) } else { merged.append(range) }
        }
        ranges = merged
        invalidating = true
        let origin = scrollView.contentView.bounds.origin
        content.performEditingTransaction {
            for range in ranges { storage.edited(.editedAttributes, range: range, changeInLength: 0) }
        }
        invalidating = false
        scrollView.contentView.scroll(to: origin)
        textView.needsDisplay = true
    }

    public func textContentStorage(_ textContentStorage: NSTextContentStorage, textParagraphWith range: NSRange) -> NSTextParagraph? {
        guard let storage = textContentStorage.textStorage, NSMaxRange(range) <= storage.length else { return nil }
        let result = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: range))
        let entire = NSRange(location: 0, length: result.length)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.5; paragraph.paragraphSpacing = 5
        result.addAttributes([.font: NSFont.systemFont(ofSize: fontSize), .foregroundColor: NSColor.textColor], range: entire)
        let marked = textView.hasMarkedText() ? SourceSpan(textView.markedRange()) : nil
        let current = SourceSpan(range)
        for run in presentation.styles where run.span.intersects(current) {
            let absolute = NSIntersectionRange(range, run.span.nsRange)
            let local = NSRange(location: absolute.location - range.location, length: absolute.length)
            switch run.kind {
            case .heading(let level):
                result.addAttribute(.font, value: NSFont.systemFont(ofSize: fontSize * [1.9, 1.5, 1.25, 1.1, 1.0, 1.0][min(5, level - 1)], weight: .semibold), range: local)
                paragraph.paragraphSpacingBefore = 14; paragraph.paragraphSpacing = 10
            case .strong, .emphasis:
                let trait: NSFontTraitMask = run.kind == .strong ? .boldFontMask : .italicFontMask
                result.enumerateAttribute(.font, in: local) { value, r, _ in
                    if let font = value as? NSFont { result.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: trait), range: r) }
                }
            case .strike: result.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: local)
            case .code, .codeBlock:
                result.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: fontSize * 0.88, weight: .regular), .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.12)], range: local)
            case .quote: paragraph.headIndent = 18; paragraph.firstLineHeadIndent = 18; result.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: local)
            case .list: paragraph.headIndent = 22
            case .bullet:
                if !showsMarkers && local.length == 1 && marked?.intersects(run.span) != true { result.replaceCharacters(in: local, with: "\u{2022}") }
            case .checkbox(let checked):
                if !showsMarkers && local.length == 3 && marked?.intersects(run.span) != true {
                    result.replaceCharacters(in: NSRange(location: local.location, length: 1), with: checked ? "\u{2611}" : "\u{2610}")
                    result.addAttribute(.foregroundColor, value: checked ? NSColor.controlAccentColor : NSColor.secondaryLabelColor, range: NSRange(location: local.location, length: 1))
                    conceal(SourceSpan(run.span.location + 1, 2), in: result, paragraphRange: range)
                }
            case .link(let target): result.addAttributes([.foregroundColor: NSColor.controlAccentColor, .link: target], range: local)
            case .rule: result.addAttribute(.foregroundColor, value: NSColor.separatorColor, range: local)
            }
            if !showsMarkers {
                for marker in run.markers where marked?.intersects(marker) != true { conceal(marker, in: result, paragraphRange: range) }
            }
        }
        result.addAttribute(.paragraphStyle, value: paragraph.copy(), range: entire)
        for element in presentation.elements where element.span.intersects(current) && !isEditing(element.span) {
            if let artifact = artifacts[element.span] {
                conceal(element.span, in: result, paragraphRange: range)
                if current.contains(element.span.location) {
                    let local = element.span.location - range.location
                    let width = min(artifact.size.width, environment.width)
                    let factor = element.inline ? 1.0 : min(1, width / artifact.size.width)
                    let height = artifact.size.height * factor
                    let attachment = ArtifactAttachment(image: NSImage(cgImage: artifact.image, size: artifact.size), label: artifact.label)
                    attachment.bounds = NSRect(x: 0, y: element.inline ? -(height - artifact.baseline) : -4, width: width, height: height)
                    result.replaceCharacters(in: NSRange(location: local, length: 1), with: "\u{FFFC}")
                    result.setAttributes([.attachment: attachment, .font: NSFont.systemFont(ofSize: fontSize), .paragraphStyle: paragraph], range: NSRange(location: local, length: 1))
                } else if !element.inline {
                    let collapsed = NSMutableParagraphStyle(); collapsed.minimumLineHeight = 0.01; collapsed.maximumLineHeight = 0.01
                    result.addAttribute(.paragraphStyle, value: collapsed, range: entire)
                }
            } else if let message = errors[element.span] {
                result.addAttributes([.foregroundColor: NSColor.secondaryLabelColor, .toolTip: message], range: entire)
            }
        }
        assert(result.length == range.length)
        return NSTextParagraph(attributedString: result)
    }
    private func conceal(_ span: SourceSpan, in result: NSMutableAttributedString, paragraphRange: NSRange) {
        let overlap = NSIntersectionRange(span.nsRange, paragraphRange)
        guard overlap.length > 0 else { return }
        let local = NSRange(location: overlap.location - paragraphRange.location, length: overlap.length)
        // Presentation-only: the source characters stay in place at a negligible size. Replacing them
        // with U+200B made TextKit 2 drop the height of any attachment sharing the line.
        result.addAttributes([.font: NSFont.systemFont(ofSize: 0.01), .foregroundColor: NSColor.clear], range: local)
    }
    // MARK: Caret placement around concealed source

    /// Concealed source the caret should not rest inside. `range` is the hidden text; `removal`
    /// is what a deletion at its edge removes.
    struct ConcealUnit {
        enum Kind { case opening, closing, element }
        var kind: Kind
        var range: NSRange
        var removal: NSRange
        func avoids(_ position: Int) -> Bool {
            switch kind {
            case .opening: return range.location <= position && position < NSMaxRange(range)
            case .closing, .element: return range.location < position && position < NSMaxRange(range)
            }
        }
    }
    func concealUnits() -> [ConcealUnit] {
        guard !showsMarkers, !textView.hasMarkedText() else { return [] }
        let text = source as NSString
        var units: [ConcealUnit] = []
        for run in presentation.styles {
            if case .checkbox = run.kind, run.span.length == 3, run.span.end < text.length {
                // "☐" stays visible; " ]" is hidden and the following space belongs to the box.
                units.append(ConcealUnit(kind: .opening, range: NSRange(location: run.span.location + 1, length: 3), removal: NSRange(location: run.span.location, length: 4)))
                continue
            }
            for marker in run.markers where marker.length > 0 && marker.end <= text.length {
                let afterBreak = marker.location == 0 || [10, 13, 0x2029].contains(text.character(at: marker.location - 1))
                let kind: ConcealUnit.Kind = marker.location == run.span.location || afterBreak ? .opening : .closing
                units.append(ConcealUnit(kind: kind, range: marker.nsRange, removal: marker.nsRange))
            }
        }
        for element in presentation.elements where element.span.length > 1 && artifacts[element.span] != nil && !isEditing(element.span) {
            units.append(ConcealUnit(kind: .element, range: element.span.nsRange, removal: element.span.nsRange))
        }
        return units
    }
    /// The nearest position that is not inside concealed source, following the caret's direction.
    public func normalizedCaret(_ position: Int, direction: CaretDirection) -> Int {
        let units = concealUnits()
        guard !units.isEmpty else { return position }
        var current = position
        for _ in 0..<8 {
            guard let unit = units.first(where: { $0.avoids(current) }) else { break }
            let end = NSMaxRange(unit.range)
            switch (unit.kind, direction) {
            case (.opening, .left): current = unit.range.location > 0 ? unit.range.location - 1 : end
            case (.opening, _): current = end
            case (.closing, .right), (.element, .right): current = end
            case (.closing, _), (.element, .left): current = unit.range.location
            case (.element, .none): current = (current - unit.range.location) * 2 < unit.range.length ? unit.range.location : end
            }
        }
        return current
    }
    private func normalizedSelection(_ selection: NSRange, previous: NSRange, direction: CaretDirection) -> NSRange? {
        if selection.length == 0 {
            let target = normalizedCaret(selection.location, direction: direction)
            return target == selection.location ? nil : NSRange(location: target, length: 0)
        }
        guard direction != .none else { return nil }
        // Keyboard extension: only the end that moved is adjusted.
        var start = selection.location, end = NSMaxRange(selection)
        if start != previous.location { start = normalizedCaret(start, direction: direction) }
        if end != NSMaxRange(previous) { end = normalizedCaret(end, direction: direction) }
        guard start != selection.location || end != NSMaxRange(selection) else { return nil }
        return end >= start ? NSRange(location: start, length: end - start) : NSRange(location: direction == .left ? start : end, length: 0)
    }
    /// Backspace at the edge of concealed source. Returns false when the default behaviour applies.
    public func deleteBackwardAcrossMarkers(at position: Int) -> Bool {
        let text = source as NSString
        guard let unit = concealUnits().first(where: { NSMaxRange($0.range) == position }) else { return false }
        switch unit.kind {
        case .opening:
            performEdit(range: unit.removal, replacement: "", selection: NSRange(location: unit.removal.location, length: 0))
        case .closing:
            guard unit.range.location > 0 else { return true }
            let victim = text.rangeOfComposedCharacterSequence(at: unit.range.location - 1)
            performEdit(range: victim, replacement: "", selection: NSRange(location: victim.location, length: 0))
        case .element:
            if enterElement(at: unit.range.location) { textView.setSelectedRange(NSRange(location: position, length: 0)) }
        }
        return true
    }
    /// Forward delete at the edge of concealed source. Returns false when the default behaviour applies.
    public func deleteForwardAcrossMarkers(at position: Int) -> Bool {
        let text = source as NSString
        guard let unit = concealUnits().first(where: { $0.range.location == position }) else { return false }
        switch unit.kind {
        case .opening:
            performEdit(range: unit.removal, replacement: "", selection: NSRange(location: unit.removal.location, length: 0))
        case .closing:
            let end = NSMaxRange(unit.range)
            guard end < text.length else { return true }
            let victim = text.rangeOfComposedCharacterSequence(at: end)
            performEdit(range: victim, replacement: "", selection: NSRange(location: position, length: 0))
        case .element:
            _ = enterElement(at: position)
        }
        return true
    }

    public func enterElement(at location: Int) -> Bool {
        guard parsed.revision == revision, let element = parsed.elements.first(where: { $0.span.contains(location) }), !isEditing(element.span) else { return false }
        editingElement = element.span
        textView.setSelectedRange(NSRange(location: element.span.location, length: 0))
        invalidatePresentation(spans: [element.span])
        return true
    }
    public func performEdit(range: NSRange, replacement: String, selection: NSRange? = nil) {
        guard textView.shouldChangeText(in: range, replacementString: replacement) else { return }
        textView.textStorage?.replaceCharacters(in: range, with: replacement)
        textView.didChangeText()
        textView.setSelectedRange(selection ?? NSRange(location: range.location + replacement.utf16.count, length: 0))
    }
    public func wrapSelection(_ marker: String, closing: String? = nil) {
        let range = textView.selectedRange(), selected = (source as NSString).substring(with: range), end = closing ?? marker
        performEdit(range: range, replacement: marker + selected + end, selection: NSRange(location: range.location + marker.utf16.count, length: range.length))
    }
    /// Toggles the task box presented at `location` (the symbol occupies the first source character).
    public func toggleCheckbox(at location: Int) -> Bool {
        guard !showsMarkers, parsed.revision == revision,
              let checkbox = parsed.checkboxes.first(where: { $0.location <= location && location <= $0.location + 1 }) else { return false }
        let old = (source as NSString).substring(with: checkbox.nsRange)
        performEdit(range: checkbox.nsRange, replacement: old == "[ ]" ? "[x]" : "[ ]", selection: textView.selectedRange())
        return true
    }
    public func toggleTask() {
        let paragraph = SourceIndex(source).paragraph(at: textView.selectedRange().location)
        guard let checkbox = parsed.checkboxes.first(where: { $0.intersects(paragraph) }) else { return }
        let old = (source as NSString).substring(with: checkbox.nsRange)
        performEdit(range: checkbox.nsRange, replacement: old == "[ ]" ? "[x]" : "[ ]")
    }
}

public enum CaretDirection: Sendable { case left, right, none }

/// TextKit 2 measures line height from `attachmentBounds(for:…)`, not from `bounds`.
/// Drawing the image directly avoids per-paragraph attachment views that outlive re-created paragraphs.
final class ArtifactAttachment: NSTextAttachment {
    init(image: NSImage, label: String) {
        super.init(data: nil, ofType: nil)
        self.image = image
        image.accessibilityDescription = label
        allowsTextAttachmentView = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation, textContainer: NSTextContainer?, proposedLineFragment: CGRect, position: CGPoint) -> CGRect { bounds }
}

@MainActor private final class EditorRootView: NSView {
    var onAppearanceChange: (() -> Void)?
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) { NSColor.textBackgroundColor.setFill(); dirtyRect.fill() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); onAppearanceChange?() }
}
