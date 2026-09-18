# A real edge drag, and quitting without Cmd-Q

Mac17,3, arm64, macOS 27.0 (26A428), Xcode 27.0 (27A266a), Swift 6.4. Release UI tests at the console.

## 1. `view.inLiveResize == true`, covered at last

**Problem.** Every resize test drove frame changes, which AppKit does not call a live resize, so the
branch that arms no wait during a drag and adopts the width on `didEndLiveResize` had never run under
test. Earlier routes to a real drag all failed: XCUITest's own press-and-drag resizes nothing, and HID
events and the accessibility API both need the test runner trusted for Accessibility, which it was not.

**Change.** `testLiveResizeByDraggingTheWindowEdge` grabs one point inside the window's right edge and
drags it 240 points left with HID `CGEvent`s — press, forty drags a frame apart, release — the events a
person's drag produces. It starts from a pinned frame, 880 points wide, passed in the argument domain:
the document window autosaves its frame, and a second run that started where the first one's drag left
it (470 points, against a minimum of 440) had nothing left to drag and failed. Without Accessibility it
**skips**, rather than failing a suite that has nothing wrong with it.

**Result.** Three consecutive runs, `drag-runs.txt`:

```
window 880.0 -> 640.0  passed
window 880.0 -> 640.0  passed
window 880.0 -> 640.0  passed
```

The captures show the behaviour the code intends. `before.png` / `during.png` / `after.png` are from
that run; `wide-element-*.png` are from an earlier run of the same drag that started narrower, where a
Mermaid diagram is on screen:

- **During the drag** the text reflows to the new width, and no rendered element falls back to its
  Markdown source — the formulas stay formulas. A diagram wider than the new width is **not scaled**: it
  keeps its old size and the window clips it. The paragraphs are not rebuilt during a drag, which is the
  point — nothing is rendered for a width the drag is only passing through.
- **After the release** the diagram is rendered once more for the width there is, and fits.

That clipping is new information. `ResizeTests.draggingAWindowKeepsRenderedElementsInPlace` said the
elements were "scaled into the width available" during the drag; its fixture is 32 points wide and never
met the case. The comment now says what the real drag showed. `adoptEnvironment`'s comment, which says
elements are scaled until their new pixels arrive, is about the moment after the drag and is correct.

## 2. Quitting through the menu, not Cmd-Q

**Problem.** In a full run three tests failed with "Cmd-Q did not quit the app" —
`testInlineMathFixtureScreenshot`, `testQuitRecordsAnOpenDocumentAsQuitNotClosed`,
`testQuitRestoresTheDocumentThatWasOpen` — and failed again run alone, with no product change since the
last time they passed. The failure recording shows the app in front with nothing over it, and the menu
bar reading `한`: the Korean input method `com.apple.inputmethod.Korean.2SetKorean` was selected. A
synthesized Cmd-Q arrives as Cmd-ㅂ and matches no menu item.

The run was its own control:

| test using Cmd-Q | pins an ASCII input source first | result |
|---|---|---|
| `testDiscardedDraft…`, `testEditingASavedFile…` | yes | passed |
| `testInlineMath…`, `testQuitRecords…`, `testQuitRestores…` | no | failed |

**Change.** Every Cmd-Q in the UI tests — five — goes through one `quit(_:)` helper that clicks
AirMark ▸ Quit AirMark. It ends in the same `NSApplication.terminate` and `applicationShouldTerminate`,
and it does not care what the keyboard layout is.

**Result.** The three tests pass with the Korean input method **still selected**. The whole file, Release,
`ui-release-final.txt`: 11 passed, 0 failed, and the drag test skipped because the rebuild that brought in
the helper dropped the runner's Accessibility grant — see below. The drag test's code did not change in
that rebuild; it uses `app.terminate()`, not the helper.

## Running the drag test

The runner is ad-hoc signed, so its Accessibility grant belongs to one build of it: **any change to the
UI tests drops it.** After a rebuild:

```sh
xcodebuild -project AirMark.xcodeproj -scheme AirMark -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath ~/Library/Developer/Xcode/DerivedData/AirMark \
  build-for-testing
```

then in System Settings ▸ Privacy & Security ▸ Accessibility, **remove** `AirMarkUITests-Runner` with − and
**add** the one under `…/Build/Products/Release/` with +. Toggling the existing entry was not enough:
it kept pointing at the previous build. Run with `test-without-building` so the build is not replaced.
`TEST_RUNNER_AIRMARK_REQUEST_ACCESSIBILITY=1` makes the test ask macOS to prompt, which names the app it
wants. Signing the runner with a stable identity would make the grant survive rebuilds; that is a
project setting and was not changed here.
