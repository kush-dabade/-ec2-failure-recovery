#!/usr/bin/env python3
"""Evidence tool: summarize raw/http-probe.csv around the AWS-observed failure window."""
import csv, datetime as dt, sys
rows = list(csv.DictReader(open(sys.argv[1])))
P = dt.datetime.fromisoformat
T_FAIL, T_REC = P(sys.argv[2]), P(sys.argv[3])
FAILED, REPL = sys.argv[4], sys.argv[5]
ok = lambda r: r["http_status"] == "200" and bool(r["instance_id"])

def summ(name, rs):
    good = sum(1 for r in rs if ok(r))
    by = {}
    for r in rs:
        if ok(r):
            by[r["instance_id"]] = by.get(r["instance_id"], 0) + 1
    lat = sorted(int(r["latency_ms"]) for r in rs if ok(r))
    print(f"{name}\n  requests={len(rs)} ok={good} failed={len(rs) - good}\n  served by: {by}\n"
          f"  latency ms: p50={lat[len(lat)//2] if lat else '-'} p95={lat[int(len(lat)*.95)] if lat else '-'} max={lat[-1] if lat else '-'}")

print(f"probe: GET /api/whoami every 0.5 s, 3 s timeout\nwindow: {rows[0]['utc_time']} -> {rows[-1]['utc_time']}\n"
      f"termination requested (AWS activity): {T_FAIL.isoformat()}\n2 healthy targets observed: {T_REC.isoformat()}\n")
summ("ALL", rows)
summ("BEFORE failure", [r for r in rows if P(r["utc_time"]) < T_FAIL])
summ("DURING failure and recovery", [r for r in rows if T_FAIL <= P(r["utc_time"]) < T_REC])
summ("AFTER recovery", [r for r in rows if P(r["utc_time"]) >= T_REC])
fails = [r for r in rows if not ok(r)]
print("\nfailed requests:", [(r["utc_time"], r["http_status"], r["error"]) for r in fails] or "none")
lf = [r["utc_time"] for r in rows if r["instance_id"] == FAILED]
fr = [r["utc_time"] for r in rows if r["instance_id"] == REPL]
print(f"last response from terminated {FAILED}: {lf[-1] if lf else 'none'}")
print(f"first response from replacement {REPL}: {fr[0] if fr else 'none'}")
oks = [P(r["utc_time"]) for r in rows if ok(r)]
gap = max((b - a).total_seconds() for a, b in zip(oks, oks[1:]))
print(f"longest interval between consecutive successful responses: {gap:.3f} s")
