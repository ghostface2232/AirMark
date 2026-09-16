#!/bin/bash
# Measures launch milestones, memory, idle CPU and keystroke cost with a Release build.
# The app is launched repeatedly and takes focus each time; run it on an idle machine.
# Numbers are observations on this machine, not guarantees; record them in DEV_LOG.md with the host.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export AIRMARK_DERIVED_DATA="${AIRMARK_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/AirMark}"
bash Scripts/build.sh Release >/dev/null
APP="$AIRMARK_DERIVED_DATA/Build/Products/Release/AirMark.app"
WORK="$(mktemp -d /tmp/airmark-measure.XXXXXX)"
python3 - "$WORK" <<'GEN'
import sys, shutil, pathlib
work = pathlib.Path(sys.argv[1]); fixtures = pathlib.Path('Fixtures')
showcase = (fixtures / 'Showcase.md').read_text()
shutil.copy(fixtures / 'swatch.png', work / 'swatch.png')
for name, size in [('doc-100k.md', 100_000), ('doc-1m.md', 1_000_000)]:
    text = ''
    while len(text.encode()) < size: text += showcase + '\n'
    (work / name).write_text(text)
GEN
pkill -x AirMark >/dev/null 2>&1 || true
LOG="$WORK/launch.jsonl"; : > "$LOG"
run() {  # file, runs
  for i in $(seq 1 "$2"); do
    open -W --env AIRMARK_LAUNCH_LOG="$LOG" --env AIRMARK_QUIT_AFTER_LAUNCH=1 --env AIRMARK_STATE_DIR="$WORK/state-$1-$i" -a "$APP" --args --open "$WORK/$1"
    sleep 0.5
  done
}
run doc-100k.md "${RUNS_100K:-10}"
run doc-1m.md "${RUNS_1M:-3}"
# Steady state with the 1MB document: RSS and CPU after the page settles.
open --env AIRMARK_STATE_DIR="$WORK/state-idle" -a "$APP" --args --open "$WORK/doc-1m.md"
sleep 10
PID="$(pgrep -x AirMark | head -1)"
RSS_KB="$(ps -o rss= -p "$PID" | tr -d ' ')"
IDLE_CPU="$(top -l 3 -s 2 -stats cpu -pid "$PID" | tail -1 | tr -d ' ')"
pkill -x AirMark || true
if ! swift test -c release --disable-sandbox --filter ScaleTests > "$WORK/scale.log" 2>&1; then
  cat "$WORK/scale.log" >&2
  exit 1
fi
KEYSTROKES="$(grep -E '^(SCALE|DOCUMENT_SCALE)' "$WORK/scale.log" || true)"
python3 - "$LOG" "$RSS_KB" "$IDLE_CPU" "$KEYSTROKES" <<'REPORT'
import json, sys, platform, math
records = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
def pct(values, p):
    values = sorted(values); return values[max(0, min(len(values) - 1, math.ceil(p * len(values)) - 1))]
print(f"host: macOS {platform.mac_ver()[0]}  runs: {len(records)}")
for doc in sorted({r['document'] for r in records}):
    rows = [r for r in records if r['document'] == doc]
    print(f"{doc} ({rows[0]['bytes']} bytes, {len(rows)} runs; OS cache state uncontrolled)")
    for key in ['windowShown', 'editable', 'firstParse', 'firstRender']:
        values = [r[key] for r in rows if key in r]
        if values: print(f"  {key:12s} p50 {pct(values, .5):7.1f} ms  p95 {pct(values, .95):7.1f} ms  first {values[0]:7.1f} ms")
print(f"steady state with doc-1m.md after 10 s: RSS {int(sys.argv[2]) / 1024:.0f} MB, CPU {sys.argv[3]}% (app process only; WebKit content processes are separate)")
print(sys.argv[4] or "keystroke measurement unavailable")
print(f"raw log: {sys.argv[1]}")
REPORT
