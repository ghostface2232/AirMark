# Ten seconds of typing, measured to the draw

Mac17,3, arm64, macOS 27.0, Swift 6.4, Release, `swift test`. 200 keys 50 ms apart at the head, middle and
tail of `ScaleTests.source` (inline math, so renders run) and of a prose document with nothing to render;
every 40th key a Return. Three runs of the elements document at each size, one of prose. The window
reported itself occluded in every run (nobody at the console) and every key was drawn all the same.

```sh
AIRMARK_TYPING_BYTES=10000000 [AIRMARK_TYPING_PROSE=1] [AIRMARK_TYPING_OUT=run.json] \
  swift test -c release --disable-sandbox --filter TypingLatencyBench
```

What each column is, and what it is not, is in `Tests/AirMarkEditorTests/TypingLatencyBench.swift`: keys go
through `insertText` / `insertNewline`, not HID and not an input method; `drawn` is TextKit drawing the
fragment that holds the key in AppKit's own display pass; `committed` is the end of that run loop turn, after
Core Animation's commit, and the window server and the display come after it and are not measured; `stall`
is how long a block posted to the main queue waited. Milliseconds, pooled over the runs.

| document | position | returned p50/p95/p99/max | drawn | committed | styled p50/p95 | stall p99/max (>16.7 ms) |
|---|---|---|---|---|---|---|
| elements 1MB ×3 | head | 4.1 / 6.2 / 6.9 / 12.1 | 6.6 / 9.1 / 10.0 / 17.7 | 7.2 / 10.0 / 11.3 / 29.0 | 109 / 214 | 7.2 / 27.5 (6) |
| | middle | 3.8 / 5.8 / 6.4 / 7.3 | 6.6 / 8.8 / 9.6 / 10.3 | 7.3 / 9.8 / 10.7 / 13.8 | 78 / 212 | 7.5 / 21.3 (1) |
| | tail | 2.8 / 5.0 / 5.4 / 6.3 | 5.4 / 7.9 / 8.7 / 9.2 | 6.1 / 8.8 / 10.0 / 13.0 | 105 / 210 | 6.4 / 12.5 (0) |
| elements 10MB ×3 | head | 2.7 / 4.7 / 6.2 / 14.3 | 3.9 / 6.4 / 8.4 / 24.3 | 4.2 / 7.0 / 9.9 / 26.7 | 98 / 240 | 4.5 / 26.1 (4) |
| | middle | 2.2 / 4.3 / 5.5 / 7.9 | 3.5 / 6.4 / 8.6 / 11.0 | 3.8 / 7.0 / 9.1 / 11.9 | 95 / 231 | 4.4 / 11.1 (0) |
| | tail | 1.4 / 3.0 / 4.2 / 6.0 | 2.7 / 5.9 / 7.3 / 8.4 | 3.2 / 6.8 / 8.3 / 14.1 | 73 / 199 | 5.0 / 13.5 (0) |
| prose 1MB ×1 | head | 4.0 / 6.6 / 7.1 / 12.3 | 6.4 / 9.4 / 9.8 / 17.6 | 7.0 / 10.0 / 14.0 / 24.8 | 112 / 211 | 7.4 / 24.6 (2) |
| | middle | 3.7 / 5.9 / 6.4 / 6.9 | 6.4 / 9.0 / 9.6 / 10.4 | 7.1 / 10.0 / 11.0 / 11.4 | 73 / 210 | 7.7 / 11.0 (0) |
| | tail | 3.9 / 5.0 / 5.4 / 6.0 | 6.5 / 7.9 / 8.6 / 9.3 | 7.2 / 8.8 / 10.2 / 12.7 | 102 / 205 | 6.7 / 11.3 (0) |
| prose 10MB ×1 | head | 2.5 / 4.3 / 7.6 / 14.9 | 3.6 / 6.0 / 9.7 / 19.0 | 3.9 / 6.7 / 11.8 / 23.2 | 92 / 241 | 4.2 / 22.4 (2) |
| | middle | 2.2 / 4.1 / 6.7 / 8.4 | 3.4 / 6.3 / 9.6 / 11.7 | 3.7 / 7.0 / 10.5 / 12.5 | 89 / 230 | 4.5 / 10.7 (0) |
| | tail | 1.3 / 2.9 / 3.8 / 4.4 | 2.5 / 5.5 / 6.5 / 7.0 | 2.9 / 6.1 / 7.2 / 8.0 | 73 / 182 | 4.8 / 8.3 (0) |

## What it shows

- **A key is drawn within one 120 Hz frame at p95 almost everywhere, and within one 60 Hz frame at p99
  everywhere.** `drawn` p95 is 5.5–9.4 ms, p99 6.5–10.0 ms. The worst single key is 24.3 ms (10MB, head).
- **The main thread's longest stall is 21–28 ms, at the head**, where a key moves everything after it and
  where the first key of a run pays for what settled before it. 13 probes of about 85,000 in the elements
  runs waited longer than 16.7 ms; none at the tail.
- **The real input path costs several times what `performEdit` does.** `returned` p50 is 1.3–4.1 ms here;
  `ScaleTests` measures 0.1–1.2 ms for the edit alone. The rest is `NSTextView`: undo, spell checking,
  selection and typing attributes. Not broken down here.
- **1MB is slower per key than 10MB** (returned p50 3.8–4.1 against 2.2–2.7 ms in the middle and at the head).
  Not explained. The two documents are the same block repeated, so it is not the content near the caret.
- **Formatting trails typing by 70–110 ms at p50 and 200–240 ms at p95.** At 50 ms between keys the 45 ms
  parse delay restarts with nearly every key, and the parse starts when the 150 ms staleness limit says
  so. The parse itself is about a millisecond now, so the delay is the whole of it. Not changed here.

## The regression it caught

`regression/` holds the first prose runs. At the tail, after the head and middle runs had edited the
document: 10MB drawn p50 42.4 ms, p95 110 ms, one key 994 ms with a 1,068 ms stall, 161 of 2,048 probes over
16.7 ms; 1MB drawn p50 9.0 ms, one key 56 ms. Until the fourth Return, after which it was 1–2 ms.

Cause: `b7bccdb` on this branch made `scheduleRenders` return early in a document with nothing to render,
to save the layout of a few screens around the viewport on each scroll step. That layout was what kept
`NSTextViewportLayoutController.layoutViewport` short: sampled during the slow stretch, the main thread's
time was in `layoutViewport` → `enumerateTextLayoutFragmentsFromLocation` →
`__NSTextLayoutManagerFillSoftInvalidationToLocation`. Same build with the early return removed, same 200
keys: drawn p50 2.79 ms, max 8.19 ms, longest stall 9.05 ms. The early return is gone and `sourceRange` says
why. The documents with elements never took that return, so their runs above stand.

A 4-second run did not show it; it takes the edits of the earlier positions and enough keys.
