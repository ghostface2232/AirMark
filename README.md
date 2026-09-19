# AirMark

A native Markdown editor for macOS 26+ and Apple Silicon. Swift 6, AppKit, TextKit 2, cmark-gfm (swift-cmark), bundled Mermaid and KaTeX.

## Build and run

```sh
bash Scripts/run.sh
```

`Scripts/build.sh Debug|Release` builds into `~/Library/Developer/Xcode/DerivedData/AirMark` (override with `AIRMARK_DERIVED_DATA`).

The application is ad-hoc signed for local use. Requires Xcode 26 or newer (the current validation host uses Xcode 27). Select Xcode normally or set `DEVELOPER_DIR`. The first build resolves pinned Swift packages. Renderer JS and fonts are included; the app never needs Node or a network connection.

```sh
swift test --disable-sandbox
bash Scripts/test-ui.sh
```

`Scripts/check-parser.sh` checks the parser and its seam with cmark-gfm: the core tests, the same under AddressSanitizer, a long fuzz of partial against whole parses, and the partial-parse benchmarks. Run it after changing the parser and before accepting a swift-cmark upgrade. `Scripts/measure.sh` builds Release and records launch milestones, memory, idle CPU and keystroke cost; it launches the app repeatedly. UI tests synthesize keyboard input and must run on an idle machine; their window captures are attachments in the result bundle (`xcrun xcresulttool export attachments`). `Scripts/generate_project.py` reproducibly generates the thin Xcode host. `Scripts/vendor.sh` rebuilds the offline renderer from the pinned `Tooling/package-lock.json`; Node is needed only for that maintenance step.

## Editing

- Edit `.md` files directly. Recognized Markdown stays formatted while typing and moving the caret. Click a rendered equation/diagram/table to edit its source.
- Cmd-B / Cmd-I / Cmd-E / Cmd-K wrap selections. Cmd-Return toggles tasks.
- Cmd-F finds; Option-Cmd-F replaces. Shift-Cmd-M shows all markers.
- Inline `$…$`, display `$$…$$`, and `math` / `latex` fences use KaTeX.
- `mermaid` fences render offline. Tables and local images render in place.
- Raw HTML and remote images are not executed or downloaded.
- Unsaved drafts are kept under `~/Library/Application Support/AirMark/Recovery`.
- The documents open when AirMark last stopped come back at the next launch, in the order their windows
  stood. A draft you delete at the close panel does not, and neither do documents from earlier sessions.

Set `AIRMARK_STATE_DIR` to isolate recovery data for testing. `--blank` opens a fresh draft; `--open /absolute/path.md` opens a specific file.

## Status

This is an initial implementation undergoing UI validation. Performance budgets in the design are targets, not measured guarantees. See `DEV_LOG.md` for actual checks and remaining limitations. Keep important documents backed up while evaluating the early build.

The latest detailed review, fixes, measurements and follow-up validation plan are in [REVIEW.md](REVIEW.md). Raw before/after parser measurements are in [Validation/2026-09-16-review](Validation/2026-09-16-review). Reproduce the long-paragraph stress case with `swift run -c release --disable-sandbox AirMarkBench --long-lines`.
