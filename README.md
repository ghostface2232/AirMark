# AirMark

A native Markdown editor for macOS 26+ and Apple Silicon. Swift 6, AppKit, TextKit 2, swift-markdown, bundled Mermaid and KaTeX.

## Build and run

```sh
bash Scripts/build.sh Debug
open build/Build/Products/Debug/AirMark.app
```

The application is ad-hoc signed for local use. Requires Xcode 26 or newer (the current validation host uses Xcode 27). Select Xcode normally or set `DEVELOPER_DIR`. The first build resolves pinned Swift packages. Renderer JS and fonts are included; the app never needs Node or a network connection.

```sh
swift test --disable-sandbox
xcodebuild -project AirMark.xcodeproj -scheme AirMark -derivedDataPath build -destination 'platform=macOS,arch=arm64' test
```

UI tests synthesize keyboard input and must run on an idle machine; their window captures are attachments in the result bundle (`xcrun xcresulttool export attachments`). `Scripts/generate_project.py` reproducibly generates the thin Xcode host. `Scripts/vendor.sh` rebuilds the offline renderer from the pinned `Tooling/package-lock.json`; Node is needed only for that maintenance step.

## Editing

- Edit `.md` files directly. Recognized Markdown stays formatted while typing and moving the caret. Click a rendered equation/diagram/table to edit its source.
- Cmd-B / Cmd-I / Cmd-E / Cmd-K wrap selections. Cmd-Return toggles tasks.
- Cmd-F finds; Option-Cmd-F replaces. Shift-Cmd-M shows all markers.
- Inline `$…$`, display `$$…$$`, and `math` / `latex` fences use KaTeX.
- `mermaid` fences render offline. Tables and local images render in place.
- Raw HTML and remote images are not executed or downloaded.
- Unsaved drafts are kept under `~/Library/Application Support/AirMark/Recovery`.

Set `AIRMARK_STATE_DIR` to isolate recovery data for testing. `--blank` opens a fresh draft; `--open /absolute/path.md` opens a specific file.

## Status

This is an initial implementation undergoing UI validation. Performance budgets in the design are targets, not measured guarantees. See `DEV_LOG.md` for actual checks and remaining limitations. Keep important documents backed up while evaluating the early build.
