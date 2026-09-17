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
