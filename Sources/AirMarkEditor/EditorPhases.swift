import Foundation
import os

/// Main-thread phases of editing, as signpost intervals for Instruments. When a test turns on
/// recording, their durations are also kept so one keystroke's cost can be split without a trace.
@MainActor public final class EditorPhases {
    public enum Phase: CaseIterable, Sendable {
        /// Moving styles and elements with an edit, including the style index update.
        case rebase
        /// Building one `NSTextParagraph` for TextKit.
        case paragraph
        /// Copying the editor's text into the document's snapshot.
        case snapshot
        /// Comparing and installing a finished parse.
        case applyParse
        /// Moving held artifacts and recorded render failures with an edit, and releasing pixels
        /// after a render or scroll.
        case artifacts
    }
    public static let shared = EditorPhases()
    public var isRecording = false
    public private(set) var durations: [Phase: [Duration]] = [:]
    private let signposter = OSSignposter(subsystem: "com.airmark.AirMark", category: "Editor")
    private let clock = ContinuousClock()

    public func measure<Result>(_ phase: Phase, _ body: () throws -> Result) rethrows -> Result {
        let state = signposter.beginInterval(Self.name(phase))
        let start = isRecording ? clock.now : nil
        defer {
            signposter.endInterval(Self.name(phase), state)
            if let start { durations[phase, default: []].append(start.duration(to: clock.now)) }
        }
        return try body()
    }

    /// Total recorded time for a phase since the last reset.
    public func total(_ phase: Phase) -> Duration { durations[phase, default: []].reduce(.zero, +) }
    public func reset() { durations.removeAll() }

    private static func name(_ phase: Phase) -> StaticString {
        switch phase {
        case .rebase: "Rebase"
        case .paragraph: "Paragraph"
        case .snapshot: "Snapshot"
        case .applyParse: "ApplyParse"
        case .artifacts: "Artifacts"
        }
    }
}
