import AppKit
import AirMarkCore
import AirMarkRender
import os

@MainActor public final class EditorController: NSViewController, NSTextViewDelegate, @MainActor NSTextContentStorageDelegate, @MainActor NSTextStorageDelegate {
    public let textView = MarkdownTextView(usingTextLayoutManager: true)
    public let scrollView = NSScrollView()
    public var onChange: (() -> Void)?
    public var onSelectionChange: (() -> Void)?
    /// Called each time a parse result is applied, and once when the first artifact is shown.
    public var onParseApplied: (() -> Void)?
    public var onFirstRender: (() -> Void)?
    public var fileURL: URL?
    public private(set) var revision: UInt64 = 0
    public private(set) var parsed = ParsedDocument(source: "")
    /// The revision of the source the presentation was last parsed from. Ahead of `parsed.revision`
    /// when a parse finished after further typing and was installed moved through those edits.
    public private(set) var presentationRevision: UInt64 = 0
    public private(set) var textKitFallbackCount = 0
    public var showsMarkers = false { didSet { invalidatePresentation(); scheduleRenders() } }
    public var fontSize: CGFloat = 16 { didSet { artifacts.removeAll(); invalidatePresentation(); scheduleRenders() } }
    /// Distances from the visible area, in screen heights. Elements within `nearScreens` are always
    /// rendered and never released. Within `aheadScreens`, renders start before scrolling reaches them
    /// while held pixels are under three quarters of the budget. Beyond `nearScreens`, pixels are released
    /// farthest first while over budget. Measured in points because source length says nothing about
    /// height: a one-line image reference can fill a screen.
    static let nearScreens: CGFloat = 1
    static let aheadScreens: CGFloat = 3
    private var parseTask: Task<Void, Never>?
    /// A parse is at the worker. Keystrokes meanwhile do not queue another: its completion starts
    /// the next one, so at most one parse exists at a time and none waits behind a stale one.
    private var parseRunning = false
    /// Character edits since the last parse started, numbered by `editSequence`, so a parse that
    /// finishes after further typing can be moved through them and installed. Trimmed as each parse
    /// finishes, so it holds at most the edits made during one parse and the wait before it.
    private var editLog: [(sequence: Int, edit: PresentationEdit)] = []
    private(set) var editSequence = 0
    /// Edits numbered at or below this are not in `editLog`: a parse of a source older than it cannot
    /// be moved to the current text and is dropped.
    private var editLogStart = 0
    /// The edit number of the last parse the worker finished, which it can reparse from.
    private var workerSequence: Int?
    /// The edit number of the parse the drawn presentation came from. When it is the parse the worker
    /// reparsed from, the two differ only inside the window the worker reports.
    private var presentationSequence: Int?
    private let parsingWorker = MarkdownParsingWorker()
    private var renderTasks: [SourceSpan: Task<Void, Never>] = [:]
    /// Layout metrics for rendered elements, and their pixels while near the viewport.
    private let artifacts = ArtifactStore()
    /// A render that failed. A transient failure (timeout, lost renderer) gets one more attempt at
    /// `retryAt`; a source error stays until the element's content changes.
    private struct RenderIssue {
        var message: String
        var retryAt: ContinuousClock.Instant?
    }
    /// Keyed like `artifacts` and moved with edits, so typing elsewhere does not resubmit failures.
    /// A sorted span list rather than a dictionary: a document scrolled through with thousands of
    /// broken images or invalid formulas kept one entry each, and rebuilding that dictionary on
    /// every keystroke made a keystroke cost as much as the failures visited so far.
    private var errors = SpanList<RenderIssue>()
    private var editingElement: SourceSpan?
    /// What paragraphs are drawn from. Follows each edit in place until the next parse replaces it.
    private var presentation = PresentationStore()
    /// Paragraph ranges whose presentation changed while they were away from the viewport. TextKit 2
    /// regenerates every paragraph in an edited range at once, so a whole-document invalidation on a
    /// large file stalls for seconds; these are applied as the viewport reaches them.
    private var pendingInvalidation: [NSRange] = []
    /// The text storage's own NSString. `textView.string` bridges a copy of the whole document.
    private var text: NSString { textView.textStorage?.mutableString ?? NSMutableString() }
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
    /// What the last completed parse of this document cost, excluding any wait for the parse before
    /// it. Recorded for measurement; pacing does not follow it. Measured on 1MB and 10MB documents,
    /// a wait of `clamp(lastParseCost, 45ms, 250ms)` delayed a single keystroke's parse by about 200ms
    /// and left slow typing (200–400ms between keys) with no parse applied for the whole burst, while
    /// continuous typing stayed unrefreshed either way (Validation/2026-09-17-parse-latency).
    private(set) var lastParseCost: Duration = .zero
    /// How long a keystroke waits before parsing.
    let parseDelay: Duration = .milliseconds(45)
    /// How long changes may stay unparsed while typing continues before one parse starts anyway.
    let parseStalenessLimit: Duration = .milliseconds(150)
    /// Parses that finished, and those whose source was already stale when they did; test hooks.
    public private(set) var parseCompletedCount = 0
    public private(set) var staleParseCount = 0
    /// Stale parses installed after moving them through the edits made while they ran; a test hook.
    public private(set) var rebasedParseCount = 0
    /// Parses installed by comparing only the window the worker reparsed; a test hook.
    public private(set) var windowedInstallCount = 0
    private let signposter = OSSignposter(subsystem: "com.airmark.AirMark", category: "Editor")
    public var source: String { isViewLoaded ? textView.string : sourceForInitialLoad }
    public var selection: SourceSpan { SourceSpan(textView.selectedRange()) }
    public var scrollY: Double { scrollView.contentView.bounds.origin.y }
    public var renderErrorCount: Int { errors.count }
    /// Rendered elements whose pixels are held.
    public var renderedElementCount: Int { artifacts.residentCount }
    /// Rendered elements whose layout metrics are known, with or without pixels.
    public var measuredElementCount: Int { artifacts.count }
    /// Decoded pixel bytes of the render results this editor holds.
    public var retainedPixelBytes: Int { artifacts.pixelBytes }
    /// The images this editor holds, for tests that stand in for on-screen drawing.
    var heldImages: [CGImage] { artifacts.residentImages }
    public var pendingRenderCount: Int { renderTasks.count }
    /// Render requests this editor has started, including ones answered from the cache.
    public private(set) var renderRequestCount = 0

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
        // Renders are not started while the window is minimized; start them when it comes back.
        observations.append(NotificationCenter.default.addObserver(forName: NSWindow.didDeminiaturizeNotification, object: nil, queue: .main) { [weak self] notification in
            let window = notification.object as? NSWindow
            MainActor.assumeIsolated { if let self, window != nil, window === self.view.window { self.scheduleRenders() } }
        })
        scrollView.contentView.postsBoundsChangedNotifications = true
        observations.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.viewportDidChange(); self?.onSelectionChange?() }
        })
        textView.string = sourceForInitialLoad
        forgetEdits()
        scheduleParse(immediate: true)
    }
    public override func viewDidLayout() {
        super.viewDidLayout()
        let width = scrollView.contentSize.width
        let inset = max(28, (width - 720) / 2)
        if abs(textView.textContainerInset.width - inset) > 0.5 { textView.textContainerInset = NSSize(width: inset, height: 40) }
        textView.minSize = NSSize(width: width, height: scrollView.contentSize.height)
        if textView.frame.width != width { textView.setFrameSize(NSSize(width: width, height: max(textView.frame.height, scrollView.contentSize.height))) }
        applyPendingInvalidation()
        scheduleRenders()
    }
    public func replaceSource(_ source: String, selection: SourceSpan? = nil, scrollY: Double? = nil) {
        sourceForInitialLoad = source
        guard isViewLoaded else { return }
        textView.string = source; revision += 1
        forgetEdits()
        textView.undoManager?.removeAllActions()
        if let selection { textView.setSelectedRange(NSRange(location: min(selection.location, textView.string.utf16.count), length: 0)) }
        scheduleParse(immediate: true)
        if let scrollY { scrollView.contentView.scroll(to: NSPoint(x: 0, y: scrollY)) }
    }
    /// The document moved or lost its file. Image paths resolve relative to the file, so their
    /// artifacts are dropped and rendered again.
    public func fileLocationChanged(to url: URL?) {
        fileURL = url
        let images = Set(parsed.elements.filter { $0.kind == .image }.map(\.span))
        for span in images { artifacts.remove(span); setIssue(nil, at: span); renderTasks[span]?.cancel(); renderTasks[span] = nil; renderTokens[span] = nil }
        invalidatePresentation(spans: Array(images))
        scheduleRenders()
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
        renderTokens.removeAll()
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
    /// Waits `parseDelay` after the last change and then parses the current source. A keystroke
    /// within the wait replaces the pending parse. Changes that stay unparsed for
    /// `parseStalenessLimit` start a parse without waiting. While a parse runs, keystrokes schedule
    /// nothing; when it finishes it is installed, moved through the edits made meanwhile if it is
    /// stale, and the next parse starts at once if the text changed. A running parse cannot be
    /// stopped, so discarding a stale one left continuous typing on a document whose parse outlasts
    /// the gap between keys with no parse installed at all (35 s of typing on a 1MB document).
    private func scheduleParse(immediate: Bool = false) {
        guard !parseRunning else { return }
        parseTask?.cancel()
        let clock = ContinuousClock()
        if firstPendingParse == nil { firstPendingParse = clock.now }
        let overdue = firstPendingParse.map { $0.duration(to: clock.now) > parseStalenessLimit } ?? false
        let delay = parseDelay
        parseTask = Task { [weak self] in
            if !immediate && !overdue { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self else { return }
            await runParse()
        }
    }
    private func runParse() async {
        guard !parseRunning, !textView.hasMarkedText() else { return }
        firstPendingParse = nil
        parseRunning = true
        let source = textView.string, revision = self.revision, sequence = editSequence
        let base = workerSequence.flatMap { $0 >= editLogStart ? $0 : nil }
        let edits = base.map { base in (since: base, edits: editLog.filter { $0.sequence > base }.map(\.edit)) }
        let state = signposter.beginInterval("Parse")
        let finished = try? await parsingWorker.parsePresentation(source, revision: revision, sequence: sequence, edits: edits)
        signposter.endInterval("Parse", state)
        guard let (result, store, cost, changed) = finished else { parseRunning = false; return }
        workerSequence = sequence
        lastParseCost = cost
        parseCompletedCount += 1
        // The window says what differs from the parse the worker started from; it bounds what differs
        // from the drawn presentation only when that came from the same parse.
        let window = base != nil && presentationSequence == base ? changed : nil
        if result.revision == self.revision {
            applyParsedDocument(result, store: store, changed: window, sequence: sequence)
        } else {
            staleParseCount += 1
            if await installStaleParse(store, revision: revision, parsedAtEdit: sequence, changed: window) { rebasedParseCount += 1 }
        }
        // Later parses start from later text, so edits this one saw are no longer needed.
        editLog.removeAll { $0.sequence <= sequence }
        editLogStart = max(editLogStart, sequence)
        parseRunning = false
        if parsed.revision != self.revision { scheduleParse(immediate: true) }
    }
    /// Installs the presentation of a parse whose source is `sequence` edits old, moved through the
    /// edits made since, exactly as the drawn presentation was moved by them. Its structure is newer
    /// than what is drawn everywhere but in the edited ranges, which both leave as the edits left
    /// them. `parsed` stays at its revision, so renders and element lookups still wait for a parse
    /// of the current text. Most of the moving runs off the main actor; edits made during it are
    /// applied here. Returns false when the edits are unknown or composition is in progress.
    @discardableResult func installStaleParse(_ store: PresentationStore, revision parsedRevision: UInt64, parsedAtEdit sequence: Int, changed: SourceSpan? = nil) async -> Bool {
        guard sequence >= editLogStart, !textView.hasMarkedText() else { return false }
        let target = editSequence
        let edits = editLog.filter { $0.sequence > sequence }.map(\.edit)
        var moved = edits.isEmpty ? store : await Task.detached { var store = store; for edit in edits { store.apply(edit) }; return store }.value
        guard sequence >= editLogStart, !textView.hasMarkedText() else { return false }
        for entry in editLog where entry.sequence > target { moved.apply(entry.edit) }
        var window = changed
        for entry in editLog where entry.sequence > sequence {
            window = window.map { entry.edit.enclosing($0) ?? SourceSpan(entry.edit.range.location, 0) }
        }
        EditorPhases.shared.measure(.applyParse) { installPresentation(moved, changed: window) }
        presentationRevision = parsedRevision
        presentationSequence = sequence
        onParseApplied?()
        return true
    }
    private func forgetEdits() {
        editLog.removeAll()
        editLogStart = editSequence
    }
    /// `store` is the presentation built from `result` off the main thread; tests may omit it.
    /// `changed` bounds where it differs from the drawn presentation, when known; `sequence` is the
    /// edit number it was parsed at.
    @discardableResult func applyParsedDocument(_ result: ParsedDocument, store: PresentationStore? = nil, changed: SourceSpan? = nil, sequence: Int? = nil) -> Bool {
        guard result.revision == revision, !textView.hasMarkedText() else { return false }
        EditorPhases.shared.measure(.applyParse) { installParse(result, store: store ?? PresentationStore(result), changed: changed) }
        presentationSequence = sequence
        scheduleRenders()
        onParseApplied?()
        return true
    }
    private func installParse(_ result: ParsedDocument, store next: PresentationStore, changed: SourceSpan?) {
        parsed = result
        presentationRevision = result.revision
        installPresentation(next, changed: changed)
    }
    /// Draws `next` in place of the current presentation. With `changed`, the two are known to differ
    /// only inside it, so only its elements are compared and only its paragraphs are drawn again;
    /// without it, every style and element is compared.
    private func installPresentation(_ next: PresentationStore, changed window: SourceSpan?) {
        let old = presentation
        if let window {
            windowedInstallCount += 1
            let kept = Set(next.elements(intersecting: window))
            for element in old.elements(intersecting: window) where !kept.contains(element) {
                artifacts.remove(element.span); setIssue(nil, at: element.span)
            }
            presentation = next
            invalidatePresentation(spans: [window, SourceSpan(textView.selectedRange())])
            return
        }
        // A distant reference definition can change an image's content without moving its span.
        // Source coordinates alone do not identify a reusable artifact, so elements are compared by
        // value; the ones equal at the same span keep their artifact and their recorded failure,
        // and present exactly as they did, so only the rest are drawn again. Invalidating every
        // element instead made applying a parse cost as much as the document is long, whether or
        // not anything changed.
        let difference = old.elementDiff(comparedTo: next)
        artifacts.retain(difference.unchanged)
        _ = errors.retainAll(in: difference.unchanged)
        presentation = next
        let changed = old.changedStyleSpans(comparedTo: next)
        invalidatePresentation(spans: changed + difference.changed + [SourceSpan(textView.selectedRange())])
    }
    public func textStorage(_ textStorage: NSTextStorage, willProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters), editedRange.location != NSNotFound else { return }
        let previous = NSRange(location: editedRange.location, length: max(0, editedRange.length - delta))
        let replacement = textStorage.mutableString.substring(with: editedRange)
        let edit = PresentationEdit(range: previous, replacement: replacement)
        editSequence += 1
        editLog.append((editSequence, edit))
        EditorPhases.shared.measure(.rebase) { presentation.apply(edit) }
        pendingInvalidation = pendingInvalidation.compactMap { edit.enclosing(SourceSpan($0))?.nsRange }
        EditorPhases.shared.measure(.artifacts) { artifacts.apply(edit); _ = errors.apply(edit) }
        editingElement = editingElement.flatMap(edit.enclosing)
    }
    /// The recorded failure of the element at `span`, if there is one.
    private func issue(at span: SourceSpan) -> RenderIssue? {
        errors.index(of: span).map { errors.payloads[$0] }
    }
    /// Records or clears the failure of the element at `span`. Elements never overlap, so the entry
    /// is found, replaced or inserted by a binary search.
    private func setIssue(_ issue: RenderIssue?, at span: SourceSpan) {
        if let index = errors.index(of: span) {
            if let issue { errors.payloads[index] = issue } else { _ = errors.remove(at: index) }
        } else if let issue {
            _ = errors.insert(issue, at: span)
        }
    }
    private func isEditing(_ span: SourceSpan) -> Bool {
        showsMarkers || editingElement.map { $0.intersects(span) } == true
    }
    private func appearanceChanged() {
        let dark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if dark != themeWasDark { themeWasDark = dark; artifacts.removeAll(); errors.removeAll(); symbolCache.removeAll(); invalidatePresentation(); scheduleRenders() }
    }
    private var environment: RenderEnvironment {
        RenderEnvironment(width: Double(max(100, scrollView.contentSize.width - 2 * textView.textContainerInset.width)), fontSize: Double(fontSize), scale: Double(view.window?.backingScaleFactor ?? 2), dark: view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua, background: backgroundCSS)
    }
    /// The text background resolved in the view's current appearance, as a CSS hex color.
    private var backgroundCSS: String {
        var color = NSColor.textBackgroundColor
        view.effectiveAppearance.performAsCurrentDrawingAppearance { color = NSColor.textBackgroundColor.usingColorSpace(.sRGB) ?? color }
        return String(format: "#%02x%02x%02x", Int(round(color.redComponent * 255)), Int(round(color.greenComponent * 255)), Int(round(color.blueComponent * 255)))
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
        releaseDistantPixels()
        let windows = renderWindows()
        var candidates = Array(elements(intersecting: windows.near))
        if artifacts.pixelBytes < artifacts.pixelBudget / 4 * 3 {
            let near = Set(candidates.map(\.span))
            candidates += elements(intersecting: windows.ahead).filter { !near.contains($0.span) }
        }
        let now = ContinuousClock.now
        for element in candidates where !isEditing(element.span) && artifacts.needsPixels(at: element.span, environment: environment) && renderTasks[element.span] == nil
                && issue(at: element.span).map({ $0.retryAt.map { $0 <= now } ?? false }) ?? true {
            guard renderTasks.count < 12 else { break }
            let token = UUID(); renderTokens[element.span] = token
            renderRequestCount += 1
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
                    artifacts.store(artifact, at: element.span, environment: environment)
                    setIssue(nil, at: element.span)
                    releaseDistantPixels()
                    if let onFirstRender { self.onFirstRender = nil; onFirstRender() }
                } catch {
                    guard !Task.isCancelled, revision == currentRevision else { return }
                    // Not a failure of the element: the window is hidden or the request was dropped.
                    // Rendering resumes when the window returns or the viewport asks again.
                    if error is CancellationError || error as? RenderFailure == .suspended { return }
                    if (error as? RenderFailure)?.isTransient == true, issue(at: element.span) == nil {
                        setIssue(RenderIssue(message: error.localizedDescription, retryAt: .now + .seconds(1)), at: element.span)
                        Task { [weak self] in
                            try? await Task.sleep(for: .seconds(1))
                            self?.scheduleRenders()
                        }
                    } else {
                        setIssue(RenderIssue(message: error.localizedDescription, retryAt: nil), at: element.span)
                        // A render is requested only when the element has no pixels here, so metrics left
                        // from a released render would draw an empty space of the old size for good. Show
                        // the source and the failure, as for an element that never rendered. A first
                        // transient failure keeps the space, so a successful retry moves nothing.
                        artifacts.remove(element.span)
                    }
                }
                // Reached only when the render settled for the current revision and environment; a
                // cancelled or postponed render returns above and leaves scheduling to whoever stopped it.
                if renderTokens[element.span] == token { renderTasks[element.span] = nil; renderTokens[element.span] = nil }
                invalidatePresentation(spans: [element.span])
                // The slot is free: start the next element waiting for one. This runs in the task, never
                // inside `scheduleRenders`, and an element that now has pixels or an error is skipped there.
                scheduleRenders()
            }
        }
    }
    public override func viewDidAppear() { super.viewDidAppear(); scheduleRenders() }

    /// Pixels near the viewport stay; farther ones go, then the farthest while over budget. Layout
    /// metrics stay, so the document does not move, and scrolling back renders them again.
    func releaseDistantPixels() {
        guard let near = sourceRange(screensAroundVisible: Self.nearScreens) else { return }
        EditorPhases.shared.measure(.artifacts) { artifacts.releasePixels(protecting: near) }
    }
    /// Where renders start: `near` always, `ahead` while under budget.
    private func renderWindows() -> (near: NSRange, ahead: NSRange) {
        guard let near = sourceRange(screensAroundVisible: Self.nearScreens),
              let ahead = sourceRange(screensAroundVisible: Self.aheadScreens) else {
            let fallback = viewportWindow(margin: 2000)
            return (fallback, fallback)
        }
        return (near, ahead)
    }
    /// The source range laid out within `screens` screen heights above and below the scroll view's
    /// visible bounds. Lays out that area if needed, never the whole document. Computed from the scroll
    /// position rather than the viewport controller's range, which can briefly fall back to the start of
    /// the document between layout passes; releasing from that dropped pixels on screen and rendered
    /// them again in a loop. Nil when the area cannot be mapped, in which case nothing is released.
    private func sourceRange(screensAroundVisible screens: CGFloat) -> NSRange? {
        guard isViewLoaded, let manager = textView.textLayoutManager, let content = manager.textContentManager else { return nil }
        let bounds = scrollView.contentView.bounds, origin = textView.textContainerOrigin
        let padding = bounds.height * screens
        let area = CGRect(x: 0, y: max(0, bounds.minY - origin.y - padding), width: max(1, bounds.width), height: bounds.height + 2 * padding)
        manager.ensureLayout(for: area)
        let length = content.offset(from: content.documentRange.location, to: content.documentRange.endLocation)
        let used = manager.usageBoundsForTextContainer
        func offset(at y: CGFloat, end: Bool) -> Int? {
            if y >= used.maxY { return length }
            guard let fragment = manager.textLayoutFragment(for: CGPoint(x: 0, y: max(0, y))) else { return nil }
            return content.offset(from: content.documentRange.location, to: end ? fragment.rangeInElement.endLocation : fragment.rangeInElement.location)
        }
        guard let start = offset(at: area.minY, end: false), let end = offset(at: area.maxY - 1, end: true), start >= 0, end >= start else { return nil }
        return NSRange(location: start, length: end - start)
    }
    /// The source range under the scroll view's visible bounds, from the layout fragments at its top
    /// and bottom edges. Releasing pixels uses this rather than the viewport controller's range, which
    /// can briefly fall back to the start of the document between layout passes; releasing from that
    /// dropped pixels on screen and rendered them again in a loop. Nil when either edge is not laid out,
    /// in which case nothing is released.
    private func scrolledSourceRange() -> NSRange? {
        guard isViewLoaded, let manager = textView.textLayoutManager, let content = manager.textContentManager else { return nil }
        let bounds = scrollView.contentView.bounds, origin = textView.textContainerOrigin
        let top = CGPoint(x: 0, y: max(0, bounds.minY - origin.y))
        let bottom = CGPoint(x: 0, y: max(0, bounds.maxY - origin.y))
        guard let first = manager.textLayoutFragment(for: top), let last = manager.textLayoutFragment(for: bottom) else { return nil }
        let start = content.offset(from: content.documentRange.location, to: first.rangeInElement.location)
        let end = content.offset(from: content.documentRange.location, to: last.rangeInElement.endLocation)
        guard start >= 0, end >= start else { return nil }
        return NSRange(location: start, length: end - start)
    }
    /// Releases every held pixel, as scrolling far away would; for tests.
    func releaseAllPixels() {
        artifacts.releasePixels(protecting: NSRange(location: 0, length: 0), budget: 0)
    }
    /// Requests renders for elements near the viewport that lack pixels; for tests.
    func requestRenders() { scheduleRenders() }
    /// Records a permanent failure for every parsed element, as scrolling through a document whose
    /// images are all missing or whose formulas are all invalid leaves behind; for tests of a long
    /// failure history. Elements are in source order, so each entry appends.
    func seedRenderFailures(message: String = "Invalid formula") {
        errors.removeAll()
        for element in parsed.elements { setIssue(RenderIssue(message: message, retryAt: nil), at: element.span) }
    }
    /// Records `artifact` for every parsed element, as if each had been rendered once while scrolling
    /// through the document, then releases pixels beyond the budget; for tests of a long render history.
    func seedArtifactHistory(_ artifact: RenderArtifact) {
        scheduleRenders()
        guard let environment = renderEnvironment else { return }
        for element in parsed.elements { artifacts.store(artifact, at: element.span, environment: environment) }
        releaseDistantPixels()
        invalidatePresentation(spans: parsed.elements.map(\.span))
    }

    /// The laid-out range plus `margin` UTF-16 units on either side, in source coordinates.
    private func viewportWindow(margin: Int) -> NSRange {
        guard let manager = textView.textLayoutManager, let content = manager.textContentManager,
              let viewport = manager.textViewportLayoutController.viewportRange else { return NSRange(location: 0, length: 5000) }
        let a = content.offset(from: content.documentRange.location, to: viewport.location)
        let b = content.offset(from: content.documentRange.location, to: viewport.endLocation)
        guard a >= 0, b >= a else { return NSRange(location: 0, length: 5000) }
        return NSRange(location: max(0, a - margin), length: b - max(0, a - margin) + margin)
    }
    /// Scrolling or resizing moved the viewport: refresh deferred paragraphs there and queue renders.
    func viewportDidChange() {
        textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
        applyPendingInvalidation()
        scheduleRenders()
    }
    public var pendingInvalidationCount: Int { pendingInvalidation.count }
    /// Styles intersecting `range`, in document order.
    private func styles(intersecting range: NSRange) -> [StyleRun] {
        presentation.styles(intersecting: SourceSpan(range))
    }
    /// The drawn presentation's styles intersecting `range`; for tests.
    func presentationStyles(intersecting range: NSRange) -> [StyleRun] {
        styles(intersecting: range)
    }
    private func elements(intersecting range: NSRange) -> ArraySlice<RenderElement> {
        presentation.elements(intersecting: SourceSpan(range))
    }

    private func invalidatePresentation(spans: [SourceSpan]? = nil) {
        guard isViewLoaded, !textView.hasMarkedText(), let storage = textView.textStorage else { return }
        let length = storage.length
        guard length > 0, !invalidating else { return }
        let text = storage.mutableString
        let ranges = (spans ?? [SourceSpan(0, length)]).compactMap { span -> NSRange? in
            guard span.location < length, span.location >= 0 else { return nil }
            return text.paragraphRange(for: NSRange(location: span.location, length: min(span.length, length - span.location)))
        }
        let merged = Self.merge(ranges)
        pendingInvalidation = Self.merge(pendingInvalidation + merged)
        applyPendingInvalidation()
    }
    /// Ranges closer than this are merged. Invalidated ranges are whole paragraphs, so the gap
    /// between two of them is whole paragraphs too; regenerating those few extra paragraphs is cheap,
    /// while keeping every styled paragraph separate left hundreds of thousands of ranges after the
    /// first parse of a 10MB document, all moved on each keystroke.
    static let invalidationMergeGap = 1024
    static func merge(_ ranges: [NSRange]) -> [NSRange] {
        var merged: [NSRange] = []
        for range in ranges.sorted(by: { $0.location < $1.location }) {
            if let last = merged.last, NSMaxRange(last) + invalidationMergeGap >= range.location { merged[merged.count - 1] = NSUnionRange(last, range) } else { merged.append(range) }
        }
        return merged
    }
    /// Regenerates the pending paragraphs that lie within the viewport window and keeps the rest.
    private func applyPendingInvalidation() {
        guard !pendingInvalidation.isEmpty, isViewLoaded, !invalidating, !textView.hasMarkedText(), let storage = textView.textStorage,
              let manager = textView.textLayoutManager, let content = manager.textContentManager as? NSTextContentStorage else { return }
        let length = storage.length
        guard length > 0 else { pendingInvalidation.removeAll(); return }
        let text = storage.mutableString
        var window = viewportWindow(margin: 4000)
        window = NSIntersectionRange(window, NSRange(location: 0, length: length))
        guard window.length > 0 else { return }
        window = text.paragraphRange(for: window)
        var apply: [NSRange] = [], keep: [NSRange] = []
        for range in pendingInvalidation {
            let clipped = NSIntersectionRange(range, NSRange(location: 0, length: length))
            guard clipped.length > 0 || range.length == 0 else { continue }
            let hit = NSIntersectionRange(clipped, window)
            guard hit.length > 0 else { keep.append(clipped); continue }
            apply.append(hit)
            if clipped.location < hit.location { keep.append(NSRange(location: clipped.location, length: hit.location - clipped.location)) }
            if NSMaxRange(clipped) > NSMaxRange(hit) { keep.append(NSRange(location: NSMaxRange(hit), length: NSMaxRange(clipped) - NSMaxRange(hit))) }
        }
        pendingInvalidation = keep
        guard !apply.isEmpty else { return }
        invalidating = true
        let origin = scrollView.contentView.bounds.origin
        content.performEditingTransaction {
            for range in apply { storage.edited(.editedAttributes, range: range, changeInLength: 0) }
        }
        invalidating = false
        scrollView.contentView.scroll(to: origin)
        textView.needsDisplay = true
    }

    public func textContentStorage(_ textContentStorage: NSTextContentStorage, textParagraphWith range: NSRange) -> NSTextParagraph? {
        EditorPhases.shared.measure(.paragraph) { paragraph(textContentStorage, range: range) }
    }
    private func paragraph(_ textContentStorage: NSTextContentStorage, range: NSRange) -> NSTextParagraph? {
        guard let storage = textContentStorage.textStorage, NSMaxRange(range) <= storage.length else { return nil }
        if textView.hasMarkedText(), NSIntersectionRange(range, textView.markedRange()).length > 0 {
            // The input method owns both characters and attributes until composition commits.
            return NSTextParagraph(attributedString: storage.attributedSubstring(from: range))
        }
        let result = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: range))
        let entire = NSRange(location: 0, length: result.length)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.5; paragraph.paragraphSpacing = 5
        result.addAttributes([.font: NSFont.systemFont(ofSize: fontSize), .foregroundColor: NSColor.textColor], range: entire)
        let marked = textView.hasMarkedText() ? SourceSpan(textView.markedRange()) : nil
        let current = SourceSpan(range)
        for run in styles(intersecting: range) {
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
                    let attachment = ArtifactAttachment(image: taskSymbol(checked: checked), label: checked ? "Completed task" : "Task")
                    let side = taskSymbolSide
                    attachment.bounds = NSRect(x: 0, y: -(side - NSFont.systemFont(ofSize: fontSize).capHeight) / 2, width: side, height: side)
                    result.replaceCharacters(in: NSRange(location: local.location, length: 1), with: "\u{FFFC}")
                    result.addAttribute(.attachment, value: attachment, range: NSRange(location: local.location, length: 1))
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
        let environment = environment
        for element in elements(intersecting: range) where !isEditing(element.span) {
            if let (metrics, entry) = artifacts.layout(at: element.span, environment: environment) {
                conceal(element.span, in: result, paragraphRange: range)
                if current.contains(element.span.location) {
                    let local = element.span.location - range.location
                    let width = min(metrics.size.width, environment.width)
                    let factor = element.inline ? 1.0 : min(1, width / metrics.size.width)
                    let height = metrics.size.height * factor
                    // Sized from metrics; pixels are fetched when drawn and may be released meanwhile.
                    let attachment = ArtifactAttachment(size: metrics.size, label: metrics.label, store: artifacts, entry: entry)
                    attachment.bounds = NSRect(x: 0, y: element.inline ? -(height - metrics.baseline) : -4, width: width, height: height)
                    result.replaceCharacters(in: NSRange(location: local, length: 1), with: "\u{FFFC}")
                    result.setAttributes([.attachment: attachment, .font: NSFont.systemFont(ofSize: fontSize), .paragraphStyle: paragraph], range: NSRange(location: local, length: 1))
                } else if !element.inline {
                    let collapsed = NSMutableParagraphStyle(); collapsed.minimumLineHeight = 0.01; collapsed.maximumLineHeight = 0.01
                    result.addAttribute(.paragraphStyle, value: collapsed, range: entire)
                }
            } else if let message = issue(at: element.span)?.message {
                result.addAttributes([.foregroundColor: NSColor.secondaryLabelColor, .toolTip: message], range: entire)
            }
        }
        assert(result.length == range.length)
        return NSTextParagraph(attributedString: result)
    }
    private var symbolCache: [String: NSImage] = [:]
    private var taskSymbolSide: CGFloat { ceil(fontSize * 1.05) }
    /// Task boxes are SF Symbols so both states share one shape; the completed box uses the accent color.
    private func taskSymbol(checked: Bool) -> NSImage {
        let key = "\(checked)|\(fontSize)|\(themeWasDark)"
        if let cached = symbolCache[key] { return cached }
        let side = taskSymbolSide
        let name = checked ? "checkmark.square.fill" : "square"
        let color: NSColor = checked ? .controlAccentColor : .secondaryLabelColor
        let configuration = NSImage.SymbolConfiguration(pointSize: fontSize, weight: .regular)
        let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            guard let symbol else { return false }
            let scale = min(rect.width / symbol.size.width, rect.height / symbol.size.height)
            let drawn = NSSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
            let origin = NSPoint(x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2)
            symbol.draw(in: NSRect(origin: origin, size: drawn), from: .zero, operation: .sourceOver, fraction: 1)
            // Keep only the symbol's alpha and replace its color, so translucent tints stay light.
            color.setFill()
            rect.fill(using: .sourceIn)
            return true
        }
        image.accessibilityDescription = checked ? "Completed task" : "Task"
        symbolCache[key] = image
        return image
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
    func concealUnits(near position: Int) -> [ConcealUnit] {
        guard !showsMarkers, !textView.hasMarkedText() else { return [] }
        let text = self.text
        var units: [ConcealUnit] = []
        // A closing fence marker reaches one line break past its block, two units for CRLF; a caret at
        // the marker's end must still find the block, hence three units of slack before the position.
        let window = NSRange(location: max(0, position - 3), length: 7)
        for run in styles(intersecting: window) {
            if case .checkbox = run.kind, run.span.length == 3, run.span.end < text.length {
                // "☐" stays visible; " ]" is hidden and the following space belongs to the box.
                units.append(ConcealUnit(kind: .opening, range: NSRange(location: run.span.location + 1, length: 3), removal: NSRange(location: run.span.location, length: 4)))
                continue
            }
            for marker in run.markers where marker.length > 0 && marker.end <= text.length {
                let afterBreak = marker.location == 0 || [10, 13, 0x2029].contains(text.character(at: marker.location - 1))
                var kind: ConcealUnit.Kind = marker.location == run.span.location || afterBreak ? .opening : .closing
                var removal = marker.nsRange
                if run.kind == .codeBlock {
                    // A fenced block's markers are its fence lines, not line-start markers. The closing
                    // fence is a closing marker, except in a block with no content line at all: there both
                    // fences are hidden with nothing visible between them, so the caret must not rest
                    // between them, and deleting either fence alone would leave an unterminated fence
                    // that turns the rest of the document into code. Such a block's fences go together.
                    // The block span excludes list prefixes, indentation and the final line break.
                    let empty = Self.isEmptyFencedBlock(run.span, in: text)
                    if marker.location > run.span.location { kind = empty ? .opening : .closing }
                    if empty { removal = run.span.nsRange }
                }
                units.append(ConcealUnit(kind: kind, range: marker.nsRange, removal: removal))
            }
        }
        let environment = environment
        for element in elements(intersecting: window) where element.span.length > 1 && artifacts.layout(at: element.span, environment: environment) != nil && !isEditing(element.span) {
            units.append(ConcealUnit(kind: .element, range: element.span.nsRange, removal: element.span.nsRange))
        }
        return units
    }
    /// True when a fenced block's closing fence line directly follows its opening fence line. The second
    /// line must really be a closing fence (at most three spaces, then at least three of the opening
    /// fence's character, then only whitespace): an unterminated fence's span also reaches its second
    /// line, which is visible content.
    static func isEmptyFencedBlock(_ span: SourceSpan, in text: NSString) -> Bool {
        guard span.length > 0, span.end <= text.length else { return false }
        let firstLineEnd = NSMaxRange(text.lineRange(for: NSRange(location: span.location, length: 0)))
        guard span.end > firstLineEnd else { return false }
        let secondLine = text.lineRange(for: NSRange(location: span.end - 1, length: 0))
        guard secondLine.location == firstLineEnd else { return false }
        let fence = text.character(at: span.location)
        guard fence == 96 || fence == 126 else { return false }                         // ` or ~
        let line = text.substring(with: NSRange(location: secondLine.location, length: span.end - secondLine.location))
        let indentation = line.prefix { $0 == " " }.count
        let rest = line.dropFirst(indentation)
        let run = rest.prefix { $0.utf16.first == fence }.count
        return indentation <= 3 && run >= 3 && rest.dropFirst(run).allSatisfy { $0 == " " || $0 == "\t" }
    }
    /// The nearest position that is not inside concealed source, following the caret's direction.
    public func normalizedCaret(_ position: Int, direction: CaretDirection) -> Int {
        var current = position, direction = direction
        var visited: Set<Int> = []
        for _ in 0..<8 {
            guard let unit = concealUnits(near: current).first(where: { $0.avoids(current) }) else { break }
            // Moving left found no visible position before hidden source at the document's start and
            // came back; settle after it instead of stopping inside it.
            if !visited.insert(current).inserted { direction = .right }
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
        let text = self.text
        guard let unit = concealUnits(near: position).first(where: { NSMaxRange($0.range) == position }) else { return false }
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
        let text = self.text
        guard let unit = concealUnits(near: position).first(where: { $0.range.location == position }) else { return false }
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
        let range = textView.selectedRange(), selected = text.substring(with: range), end = closing ?? marker
        performEdit(range: range, replacement: marker + selected + end, selection: NSRange(location: range.location + marker.utf16.count, length: range.length))
    }
    /// Toggles the task box presented at `location` (the symbol occupies the first source character).
    public func toggleCheckbox(at location: Int) -> Bool {
        guard !showsMarkers, let checkbox = presentation.checkboxes.first(where: { $0.location <= location && location <= $0.location + 1 }) else { return false }
        return toggle(checkbox, selection: textView.selectedRange())
    }
    /// Toggles the task box on the caret's paragraph. Boxes come from the presentation, which follows
    /// edits made since the last parse; a box an edit touched is not toggled until the parse lands.
    public func toggleTask() {
        let paragraph = SourceSpan(text.paragraphRange(for: NSRange(location: textView.selectedRange().location, length: 0)))
        guard let checkbox = presentation.checkboxes.first(where: { $0.intersects(paragraph) }) else { return }
        _ = toggle(checkbox, selection: nil)
    }
    /// `[]`, `[ ]` or `[x]` right before the caret at the start of its line, optionally after a list marker.
    private static let taskShortcut = try! NSRegularExpression(pattern: "^([ \\t]*)(?:(?:[-+*]|[0-9]+[.)])[ \\t]+)?\\[([ xX]?)\\]$")
    /// Called when a space is typed at `location`. If the line so far is brackets, alone or after a
    /// list marker, the most recent input wins: the line becomes a bulleted task `- [ ] ` (or `- [x] `),
    /// replacing any number or other bullet and keeping the indentation. GFM needs the list marker for
    /// a task, so bare brackets get one. One undoable edit; returns false to type the space.
    public func convertToTask(before location: Int) -> Bool {
        let text = self.text
        guard location <= text.length else { return false }
        let line = text.paragraphRange(for: NSRange(location: location, length: 0)).location
        let before = NSRange(location: line, length: location - line)
        guard before.length <= 64,
              !styles(intersecting: NSRange(location: location, length: 0)).contains(where: { $0.kind == .codeBlock || $0.kind == .code }) else { return false }
        // Only the line so far goes to the expression: bridging the storage to a String copies the whole document.
        let prefix = text.substring(with: before) as NSString
        guard let match = Self.taskShortcut.firstMatch(in: prefix as String, range: NSRange(location: 0, length: prefix.length)) else { return false }
        let indent = prefix.substring(with: match.range(at: 1))
        let mark = prefix.substring(with: match.range(at: 2))
        performEdit(range: before, replacement: indent + "- [" + (mark.isEmpty ? " " : mark) + "] ")
        return true
    }
    private func toggle(_ checkbox: SourceSpan, selection: NSRange?) -> Bool {
        guard checkbox.end <= text.length else { return false }
        let replacement: String
        switch text.substring(with: checkbox.nsRange) {
        case "[ ]": replacement = "[x]"
        case "[x]", "[X]": replacement = "[ ]"
        default: return false
        }
        performEdit(range: checkbox.nsRange, replacement: replacement, selection: selection)
        return true
    }
}

public enum CaretDirection: Sendable { case left, right, none }

/// TextKit 2 measures line height from `attachmentBounds(for:…)`, not from `bounds`.
/// Drawing the image directly avoids per-paragraph attachment views that outlive re-created paragraphs.
final class ArtifactAttachment: NSTextAttachment {
    private weak var store: ArtifactStore?
    private var entry: Int?
    init(image: NSImage, label: String) {
        super.init(data: nil, ofType: nil)
        self.image = image
        image.accessibilityDescription = label
        allowsTextAttachmentView = false
    }
    /// A rendered element: `image` is an empty placeholder carrying the label, and drawing asks the
    /// store for the pixels, which draw as nothing while released.
    init(size: CGSize, label: String, store: ArtifactStore, entry: Int) {
        super.init(data: nil, ofType: nil)
        let placeholder = NSImage(size: size)
        placeholder.accessibilityDescription = label
        image = placeholder
        self.store = store
        self.entry = entry
        allowsTextAttachmentView = false
    }
    override func image(for bounds: CGRect, attributes: [NSAttributedString.Key: Any], location: any NSTextLocation, textContainer: NSTextContainer?) -> NSImage? {
        guard let entry, Thread.isMainThread else { return super.image(for: bounds, attributes: attributes, location: location, textContainer: textContainer) }
        // TextKit draws on the main thread; the store is main-actor state.
        let store = self.store
        nonisolated(unsafe) var drawable: NSImage?
        MainActor.assumeIsolated { drawable = store?.drawable(for: entry) }
        return drawable ?? image
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
