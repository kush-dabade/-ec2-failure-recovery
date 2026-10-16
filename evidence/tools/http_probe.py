#!/usr/bin/env python3
"""Independent HTTP probe for the failure experiment (evidence tool).

Sends GET /api/whoami to the ALB every INTERVAL seconds and appends one CSV row per
request: UTC timestamp, sequence, HTTP status (or error), serving instance ID, AZ,
latency. Runs until SIGTERM/SIGINT. Nothing is synthesized: a failed request is
recorded as a failure.

Usage: http_probe.py <base-url> <out.csv> [interval-seconds]
"""
import csv
import datetime as dt
import json
import signal
import sys
import time
import urllib.error
import urllib.request

base, out = sys.argv[1].rstrip("/"), sys.argv[2]
interval = float(sys.argv[3]) if len(sys.argv) > 3 else 0.5
running = True


def stop(*_):
    global running
    running = False


signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)

with open(out, "a", newline="") as f:
    w = csv.writer(f)
    if f.tell() == 0:
        w.writerow(["utc_time", "seq", "http_status", "instance_id", "availability_zone", "latency_ms", "error"])
    seq = 0
    while running:
        seq += 1
        t0 = time.monotonic()
        ts = dt.datetime.now(dt.timezone.utc).isoformat(timespec="milliseconds")
        status, iid, az, err = "", "", "", ""
        try:
            req = urllib.request.Request(f"{base}/api/whoami?probe={seq}", headers={"Cache-Control": "no-store"})
            with urllib.request.urlopen(req, timeout=3) as r:
                status = r.status
                body = json.loads(r.read())
                iid, az = body.get("instance_id") or "", body.get("availability_zone") or ""
        except urllib.error.HTTPError as e:
            status, err = e.code, "http-error"
        except Exception as e:  # timeout, connection refused, DNS ...
            err = type(e).__name__
        w.writerow([ts, seq, status, iid, az, round((time.monotonic() - t0) * 1000), err])
        f.flush()
        time.sleep(max(0.0, interval - (time.monotonic() - t0)))
