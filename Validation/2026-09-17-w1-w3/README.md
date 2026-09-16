# W1–W3 validation evidence

Host: Mac17,3, 24 GiB RAM, arm64, macOS 27.0 (26A428), Xcode 27.0 (27A266a), Swift 6.4. Release builds. OS cache state uncontrolled. These are observations on this machine, not PLAN.md budget certifications (the reference machine is an M1 8GB on macOS 26).

## W1 — input path

- `scale-before-1.txt`: `swift test -c release --disable-sandbox --filter ScaleTests` at `4a019d0`, before the presentation store.
- `scale-10mb-store-only.txt`: `AIRMARK_SCALE_10MB=1 swift test -c release --disable-sandbox --filter tenMegabyteDocumentKeystrokeCosts` after `76c5187` (store), before `51f0304` (pending-range merge). The tail keystroke still cost 3.2ms with rebase and snapshot at zero; this is what led to splitting the edit and finding 230,665 pending invalidation ranges.
- `scale-w1-after.txt`: `AIRMARK_SCALE_10MB=1 swift test -c release --disable-sandbox --filter ScaleTests` after `51f0304`.

Keystroke durations are synchronous main-thread time of one `performEdit`. The document-backed test then lays out the edited paragraph and reports that separately (`layout`). The `_PHASES` lines are per-keystroke sums of `EditorPhases` intervals. Neither is key-to-display latency.

## W3 — adversarial inputs

- `adversarial-before.txt`: `swift run -c release --disable-sandbox AirMarkBench --adversarial` before the W3 changes. `query2000` is 2,000 caret-sized (6-unit) style queries at deterministic random positions on the presentation store.
