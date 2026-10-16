"""Backend tests: state aggregation, status derivation, HTTP surface. No AWS needed.

Run: python3 -m unittest discover -s tests -v
"""

import json
import os
import sys
import threading
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "app"))
sys.path.insert(0, HERE)

import fake_aws  # noqa: E402
import server  # noqa: E402


class StateTests(unittest.TestCase):
    def state_at(self, phase):
        sc = fake_aws.Scenario()
        sc.phase = phase
        return server.collect_state(fake_aws.clients(sc), "arn:fake:tg")

    def test_phases_produce_expected_overall_status(self):
        expected = ["HEALTHY", "DEGRADED", "DEGRADED", "RECOVERING", "RECOVERING", "HEALTHY"]
        self.assertEqual([self.state_at(p)["overall"] for p in range(6)], expected)

    def test_counts_and_separation_of_signals(self):
        st = self.state_at(4)
        self.assertEqual(st["asg"]["desired"], 2)
        self.assertEqual(st["target_group"]["healthy"], 1)
        self.assertEqual(st["asg"]["in_service"], 2)
        by_id = {i["instance_id"]: i for i in st["instances"]}
        self.assertEqual(by_id[fake_aws.A]["ec2_state"], "terminated")
        self.assertFalse(by_id[fake_aws.A]["in_asg"])
        self.assertEqual(by_id[fake_aws.R]["target_state"], "initial")
        self.assertEqual(by_id[fake_aws.R]["asg_lifecycle"], "InService")

    def test_timestamps_are_iso_utc(self):
        st = self.state_at(3)
        self.assertTrue(st["fetched_at"].endswith("Z"))
        self.assertTrue(all(a["start"].endswith("Z") for a in st["activities"]))

    def test_outage_when_no_healthy_targets(self):
        sc = fake_aws.Scenario()
        fake_aws.PHASES.append({fake_aws.B: ("running", "InService", "unhealthy")})
        try:
            sc.phase = len(fake_aws.PHASES) - 1
            st = server.collect_state(fake_aws.clients(sc), "arn:fake:tg")
        finally:
            fake_aws.PHASES.pop()
        self.assertEqual(st["overall"], "OUTAGE")

    def test_aws_errors_are_reported_not_fabricated(self):
        class FakeClientError(Exception):
            response = {"Error": {"Code": "AccessDenied"}}

        class Broken:
            def describe_auto_scaling_groups(self, **_):
                raise FakeClientError(
                    "User: arn:aws:sts::851226124537:assumed-role/x/i-1 is not authorized"
                )

        aws = server.AwsState(clients={"autoscaling": Broken(), "elbv2": None, "ec2": None})
        aws._tg_arn = "arn:fake:tg"
        st = aws.get()
        self.assertIn("AccessDenied", st["error"])
        self.assertNotIn("851226124537", st["error"])
        self.assertNotIn("arn:", st["error"])
        self.assertNotIn("instances", st)


class HttpTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        sc = fake_aws.Scenario()
        server.STATE = server.AwsState(clients=fake_aws.clients(sc))
        cls.httpd = ThreadingHTTPServer(("127.0.0.1", 0), server.Handler)
        cls.base = f"http://127.0.0.1:{cls.httpd.server_address[1]}"
        threading.Thread(target=cls.httpd.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.httpd.shutdown()

    def get(self, path, method="GET"):
        req = urllib.request.Request(self.base + path, method=method)
        try:
            with urllib.request.urlopen(req, timeout=5) as r:
                return r.status, dict(r.headers), r.read()
        except urllib.error.HTTPError as e:
            return e.code, dict(e.headers), e.read()

    def test_health(self):
        status, _, body = self.get("/health")
        self.assertEqual((status, body), (200, b"ok\n"))

    def test_whoami_has_identity_headers_and_never_invents_an_id(self):
        status, headers, body = self.get("/api/whoami")
        self.assertEqual(status, 200)
        j = json.loads(body)
        self.assertIn("X-Instance-Id", headers)
        self.assertIn("X-Availability-Zone", headers)
        self.assertIn("X-Instance-Hostname", headers)
        self.assertEqual(headers["Cache-Control"], "no-store")
        if j["source"] == "not-ec2":
            self.assertIsNone(j["instance_id"])

    def test_state(self):
        status, _, body = self.get("/api/state")
        j = json.loads(body)
        self.assertEqual(status, 200)
        self.assertEqual(j["overall"], "HEALTHY")
        self.assertIn("served_by", j)

    def test_static_and_security_headers(self):
        for path in ("/", "/app.js", "/app.css"):
            status, headers, _ = self.get(path)
            self.assertEqual(status, 200, path)
            self.assertIn("script-src 'self'", headers["Content-Security-Policy"])

    def test_no_mutating_methods_and_no_path_traversal(self):
        for m in ("POST", "PUT", "DELETE", "PATCH"):
            self.assertEqual(self.get("/api/state", m)[0], 405, m)
        self.assertEqual(self.get("/../server.py")[0], 404)
        self.assertEqual(self.get("/static/../server.py")[0], 404)
        self.assertEqual(self.get("/api/terminate?id=i-123")[0], 404)


if __name__ == "__main__":
    unittest.main()
