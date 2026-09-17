# Running render cancellation, recovery writes

Host: Mac17,3, 24 GiB RAM, arm64, macOS 27.0 (26A428), Xcode 27.0 (27A266a), Swift 6.4. Release builds. OS cache state uncontrolled; load averages were 1.6–3.0 during the runs. These are observations on this machine, not PLAN.md budget certifications.

## 1. Running WebRenderer jobs whose callers left

### Problem

Each keystroke cancels every render task in the editor. `WebRenderer` removed a cancelled job that was still queued, but let a running job run to the end so its result could be cached. JavaScript cannot be interrupted, so a running Mermaid or KaTeX job for content that no longer exists kept the page, and every job queued behind it on that page waited.

### Measurement

`AIRMARK_RENDER_CANCEL_MEASURE=1 swift test -c release --disable-sandbox --filter RenderCancellationTests`. Five samples each, p50 shown.

- `obsoleteRunningJobDelaysTheNextRender`: on a warm page, a slow element starts rendering, its only caller is cancelled (40 ms in for diagrams, 1 ms for formulas), and a small element of the same kind is requested at once. `alone` is the slow element on its own, `next_idle` the small element on an idle page, `next_after_obsolete` the small element after cancellation. `page mermaid first` is the first render on a fresh page, which is what replacing a page costs.
- `editorEditsDuringARunningRender`: an `EditorController` showing one diagram. (a) 40 ms into the render, text is inserted into a node label: time until the new diagram's pixels are stored. (b) From 40 ms into the render, a character is typed at the end of the document every 100 ms or 30 ms: time until the unchanged diagram's pixels are stored, and page loads meanwhile.

Diagrams: left-to-right chains of 100/250/480 edges, and a top-to-bottom graph of 490 crossing edges over 70 nodes ("dense"; Mermaid's `maxEdges` is 500). While probing for slow diagrams in the valid range, that graph took 1.36 s; 480-message sequence, 400-task Gantt and 200-class diagrams failed the display limit in 0.11–0.38 s.

| | before (`render-cancel-before.txt`) | after (`render-cancel-after.txt`) |
|---|---:|---:|
| fresh page first render / warm | 125 / 9 ms | 130 / 9 ms |
| mermaid-100: alone → next after obsolete | 76 → 38 ms, page loads 0 | 77 → 41 ms, loads 0 |
| mermaid-250 | 182 → **140 ms**, loads 0 | 213 → **234 ms**, loads 5 |
| mermaid-480 | 378 → **342 ms**, loads 0 | 446 → **250 ms**, loads 5 |
| mermaid-dense | 1,075 → **1,035 ms**, loads 0 | 1,235 → **250 ms**, loads 5 |
| katex 12×12 / 30×30 matrix | 20 → 18 / 122 → 143 ms | 24 → 21 / 143 → 136 ms, loads 0 |
| editor, edit diagram: lr-250 / lr-480 / dense | 355 / 866 / 2,270 ms | 447 / 689 / 1,490 ms |
| editor, typing elsewhere every 100 ms: lr-250 / lr-480 / dense | 161 / 398 / 1,085 ms, loads 0 | 161 / 374 / 1,024 ms, loads 0 |
| editor, typing elsewhere every 30 ms | 175 / 569 / 1,146 ms, loads 0 | 172 / 371 / 1,149 ms, loads 0 |

Before, the obsolete render always finished (5/5 cached) and the wanted element waited for the rest of it. That wait is bounded only by the script and snapshot budgets (8 s + 5 s).

### Change

A running job is abandoned only when all of these hold: no caller still waits for it, another job is queued, and it has run for 150 ms. Abandoning ends the job with a cancellation and discards the page, as a timeout does, so the queued job starts on a fresh page. The check runs when a job is queued, when the running job's caller cancels (both one main-actor turn later) and when a job reaches 150 ms.

- **The 150 ms threshold** is the measured cost of a fresh page (125–135 ms). A job that would finish before a new page could load is not worth abandoning. Waiting that long before switching bounds the extra wait at about one page load, whatever the job's length.
- **Shared renders.** `RenderService` hands the renderer `isWanted`, which reads the shared entry's current waiters. A render that one caller left but another still waits for keeps running. So does a render that every caller left and a caller then rejoined. That is what typing elsewhere does: each keystroke cancels, and the parse 45 ms later asks for the same unchanged element again. Deciding one turn later lets callers started in the same turn rejoin first.
- Queued cancellation is unchanged. An abandoned job is not retried the way a page lost to WebKit is.

### What the numbers say

- Long obsolete jobs no longer hold the page. The wanted element waits about 150 ms plus a page load (250 ms) instead of the rest of the job (342 ms for 480 edges, 1,035 ms for the dense graph). Editing a diagram while it renders shows the new one 177 ms (lr-480) and 780 ms (dense) sooner.
- **Mid-sized jobs pay.** A 250-edge chain (about 180–210 ms) is abandoned just before it would have finished, so the wanted element waits 234 ms instead of 140 ms, and editing that diagram takes 447 ms instead of 355 ms. This is the cost of not knowing a job's length in advance. It is bounded by about one page load.
- The first renders on a replaced page are slower until WebKit warms up: the `alone` samples after an abandonment are 12–17% slower than before.
- Jobs under 150 ms, which covers the formulas and the small and mid-sized diagrams measured here, never lose their page (`page_loads=0`).
- Typing elsewhere during a render caused no page loads and no delay, at 100 ms and at 30 ms per keystroke.

### Tests

- `render-cancel-tests-before.txt`: the four new tests against the unchanged renderer. `obsoleteRunningRenderYieldsToAWaitingJob` fails: the obsolete render was cached and no page was replaced, and the wanted element took 0.94 s. The three guards pass: a render still shared with another caller, a render rejoined before another job arrives, and a formula that has run only briefly.
- `render-cancel-tests-after.txt`: the four tests and `RenderLifecycleTests` after the change. The wanted element takes 0.15 s. The guards still pass without page loads.
- The four tests are in an extension of the serialized `RenderLifecycleTests`. As a separate suite, they started WebContent processes in parallel with `killedContentProcessEndsTheRenderAndRecovers`, which counts new processes, and made it fail during a full run.
- `task1-swift-release-tests.txt`: full `swift test -c release --disable-sandbox`, 78 editor/integration and 33 core tests passed.

## 2. Recovery write amplification

### Problem

`MarkdownDocument` schedules a recovery save 600 ms after any edit, selection change or scroll, including a scroll that only moves the viewport. Each save JSON-encoded the whole `RecoveryRecord`, source included, and atomically replaced `<id>.json`. With a 10 MB document, moving the caret or pausing while reading rewrote the whole document.

### Measurement

`AIRMARK_RECOVERY_IO=1 swift test -c release --disable-sandbox --filter RecoveryIOTests`. A `MarkdownDocument` with a 9.54 MB source (`ScaleTests.source`, formulas included) in a visible window, after its first parse. Bytes are this process's disk writes from `proc_pid_rusage` (`ri_diskio_byteswritten`), taken from the action until recovery files have been stable for 1.2 s. "Files replaced" counts recovery files whose identity or size changed. Store timings call `RecoveryStore.save` directly: `document_record` uses `document.record()`, whose source is bridged from the text view, and `native` uses a record whose source is a Swift string.

| | before (`recovery-io-before.txt`) | after (`recovery-io-after.txt`) |
|---|---:|---:|
| one edit, then pause (×5) | 10.12 MB each, 1 file | 9.54 MB each, 2 files (source + record) |
| one caret move, then pause (×5) | 10.12 MB each | about 4 KB each (0.02 MB for five), 1 file |
| one scroll by 900 pt, then pause (×5) | 10.12 MB each | about 4 KB each (0.02 MB for five), 1 file |
| 60 scroll steps, then pause | 10.12 MB | 0.00 MB, 1 file |
| 10 screens scrolled 1.5 s apart | 101.25 MB | 0.04 MB |
| idle 5 s | 0 | 0 |
| save `document.record()`: source changed / selection only | 163.8 / 166.5 ms | 17.5 / 0.3 ms |
| save native record: source changed / selection only | 17.4 / 17.6 ms | 2.0 / 0.2 ms |
| `records()` | 33.4 ms | 3.6 ms |
| recovery directory | 10.12 MB | 9.54 MB |

Nothing was written while idle before or after, so idle needed no change. An edit still writes the whole source; this change leaves that alone.

### Change

- **Two files per record.** `<id>.json` holds the metadata and the name of `<id>.<token>.source`, which holds the source as raw UTF-8. A save whose revision equals the last one this store wrote for that id, and whose source file still exists, replaces only the JSON file. `RecoveryRecord`, `RecoveryStore`'s API and `LaunchPlan` are unchanged.
- **Crash ordering.** A new source is written atomically to a new file, then the JSON naming it, and only then are the id's other source files removed. A crash at any point leaves a JSON file naming a complete source. If the JSON write fails, the new source file is removed. A JSON file naming a missing source is skipped when reading, and `records()` reads each record a second time if its source was replaced between the two reads.
- **Old records.** Records with the source inline in the JSON, as written before, still load. The next save converts them.
- **Revision.** `RecoveryRecord.revision` was the editor's revision, which does not change when a document without an editor reads its file again. Deduplicating on it would have kept a stale source (`rereadSourceWithoutEditorReachesRecovery` fails with it). The revision is now a version kept by `DocumentSnapshot` and bumped whenever its bytes are replaced (`set`, `didRead`), and read together with the bytes. The only code that reads a record's revision is the store's in-process ordering gate. A new store instance, as after a relaunch, knows nothing and writes the source it is given.
- Raw UTF-8 instead of a JSON string also removes escaping, which is most of the 164 → 17.5 ms for a bridged source.

### Tests

- `recovery-store-tests-before.txt`: the new `RecoveryStoreTests` and `DocumentTests` against the old store. Two fail: a position-only save rewrote the 140 KB record, and a source left by an interrupted save was not removed. The others pass before and after: reading back after a position-only save, a new revision, a fresh store with a repeated revision, a record with its source inline, a record naming a missing source, caret moves after edits in a real document, and a document without an editor reading its file again.
- `recovery-store-tests-after.txt`: all pass, together with `recoveryRejectsOldWrites`, `terminationRecoveryCannotBeOverwrittenByPendingSave`, `launchPlanPrefersRecoveryThenRecent`, and the existing `forceQuitRecoveryReopensUnsavedEdits` and `recoveryRecordFollowsEditsAndClose`.
- `task2-swift-release-tests.txt`: full `swift test -c release --disable-sandbox`, 81 editor/integration and 38 core tests passed.
- `ui-release.txt`: `Scripts/test-ui.sh` (xcodebuild, Debug app). `testInlineMathFixtureScreenshot` passed; it presses Cmd-Q and checks that a recovery record exists. The dark-appearance and showcase tests passed. `testRepeatedAsynchronousSavesPreserveSource` and `testTypingUndoAndReplaceAll` failed because synthesized keys arrived through the Korean input method ("Save" became "ㄴㅁㅍㄷ"), although selecting the ASCII-capable source returned `noErr`. They failed the same way on rerun (`ui-release-typing-rerun.txt`), and `testTypingUndoAndReplaceAll` failed identically at `6aef17b`, before either change, in a separate worktree. This is an environment failure that these changes neither cause nor fix. Those two tests did not validate typing on this run.
