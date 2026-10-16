"""TEST FIXTURE ONLY: serve the real dashboard against the scripted fake scenario.

    python3 tests/preview.py [port] [seconds-per-phase]

The real server.Handler serves the page and /api/state; /api/whoami answers as a
round-robin over the scenario's currently healthy targets, so the UI's transitions
can be checked without AWS. Not deployed, and never used for the live demo.
"""

import itertools
import json
import os
import sys
import threading
import time
from http.server import ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "app"))
sys.path.insert(0, HERE)

import fake_aws  # noqa: E402
import server  # noqa: E402

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8099
STEP = float(sys.argv[2]) if len(sys.argv) > 2 else 6
SC = fake_aws.Scenario()
server.STATE = server.AwsState(clients=fake_aws.clients(SC))
server.STATE_TTL = 0.5
_rr = itertools.count()


class PreviewHandler(server.Handler):
    def do_GET(self):
        if self.path.startswith("/api/whoami"):
            healthy = [i for i, (_, _, ts) in SC.snap().items() if ts in ("healthy", "draining")]
            serving = [i for i in healthy if SC.snap()[i][2] == "healthy"] or healthy
            if not serving:
                return self._send(503, "no healthy targets\n", "text/plain")
            iid = serving[next(_rr) % len(serving)]
            return self._json(200, {"instance_id": iid, "availability_zone": fake_aws.AZ[iid],
                                    "hostname": "fixture", "source": "test-fixture"})
        return super().do_GET()


def advance():
    time.sleep(STEP * 1.5)
    while SC.phase < len(fake_aws.PHASES) - 1:
        SC.phase += 1
        print("phase", SC.phase, flush=True)
        time.sleep(STEP)


threading.Thread(target=advance, daemon=True).start()
print(f"preview on http://127.0.0.1:{PORT}/", flush=True)
ThreadingHTTPServer(("127.0.0.1", PORT), PreviewHandler).serve_forever()
