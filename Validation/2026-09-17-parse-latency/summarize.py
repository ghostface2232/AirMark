"""Summarizes ParsePacingBench JSON output: python3 summarize.py <directory>."""
import json, glob, math, os, sys
S = sys.argv[1] if len(sys.argv) > 1 else "."
def pct(v, p):
    s = sorted(v); return s[max(0, math.ceil(len(s) * p) - 1)] if s else float('nan')
def fmt(v): return f"{pct(v,.5):7.0f} {pct(v,.95):7.0f} {max(v):7.0f}" if v else "      -       -       -"
runs = {}
for f in sorted(glob.glob(f"{S}/*-r[0-9].json")):
    d = json.load(open(f)); v, size, rep = os.path.basename(f)[:-5].split('-')
    runs.setdefault((int(size), v), []).append((rep, d))
sizes = sorted({k[0] for k in runs})
print("latency/settle columns: p50 p95 max (ms), pooled over runs; per-run max in brackets")
for size in sizes:
    print(f"\n### {size//1000}KB")
    for v in ("main", "pr"):
        rs = runs.get((size, v), [])
        if not rs: continue
        parse = [x for _, d in rs for x in d["standalone_parse_ms"]]
        print(f"[{v}] runs={len(rs)} standalone parse p50={pct(parse,.5):.0f}ms")
        if all("idle" in d for _, d in rs):
            lat = [s["latency_ms"][0] for _, d in rs for s in d["idle"]]
            per = [max(s["latency_ms"][0] for s in d["idle"]) for _, d in rs]
            print(f"  idle 1-key -> applied   {fmt(lat)}  per-run max {[round(x) for x in per]}  parses/sample max={max(s['parses'] for _, d in rs for s in d['idle'])}")
        for key, name in (("slow", "slow 200-400ms 35s"), ("sustained", "fast 80ms 35s")):
            if not all(key in d for _, d in rs): continue
            lat = [x for _, d in rs for x in d[key]["latency_ms"]]
            per = [max(d[key]["latency_ms"]) for _, d in rs]
            gaps = [max(d[key]["apply_gaps_ms"]) for _, d in rs]
            print(f"  {name:22} key latency {fmt(lat)}  per-run max {[round(x) for x in per]}  settle {[round(d[key]['settle_ms']) for _, d in rs]}"
                  f"  parses {[d[key]['parses'] for _, d in rs]} stale {[d[key]['stale'] for _, d in rs]} applied {[d[key]['applied'] for _, d in rs]} max_apply_gap {[round(x) for x in gaps]}"
                  f" keys {[d[key]['keys'] for _, d in rs]} key_gap_max {[round(d[key]['key_gap_max_ms']) for _, d in rs]}")
        if all("bursts" in d for _, d in rs):
            b = [x for _, d in rs for x in d["bursts"]]
            settle = [x["settle_ms"] for x in b]; lat = [y for x in b for y in x["latency_ms"]]
            print(f"  bursts 15x80ms settle   {fmt(settle)}  key latency {fmt(lat)}  parses/burst {sorted(set(x['parses'] for x in b))} (mean {sum(x['parses'] for x in b)/len(b):.2f}) stale/burst {sorted(set(x['stale'] for x in b))} (mean {sum(x['stale'] for x in b)/len(b):.2f}) n={len(b)}")
