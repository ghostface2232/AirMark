# AirMark development

- Implement PLAN.md and the accepted implementation plan in this conversation. macOS 26+, arm64, Swift 6.
- Preserve Markdown source exactly. Never serialize the AST back into a user's file.
- TextKit 2 only. Do not access NSTextView.layoutManager or force layout of the entire document.
- Keep parsing, file IO, and WebKit rendering out of paragraph/layout delegate callbacks.
- Native edits and format commands share the text view's undo manager. Presentation edits must not alter source, undo, or document dirty state.
- No styling/reprojection of marked text during IME composition.
- Public macOS 26 APIs only in the base path. No private selectors.
- Swift Testing for core/integration tests; XCTest/XCUIAutomation for real UI workflows.
- Tests must cover source round trips, UTF-16 ranges, stale results, and saving failures.
- Record actual validation and limitations in DEV_LOG.md. Never describe performance budgets as measured results.
