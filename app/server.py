#!/usr/bin/env python3
"""EC2 failure-recovery demo: per-instance web app + read-only AWS state API.

Runs on every instance in the experiment's Auto Scaling Group, behind the ALB.

Endpoints (GET/HEAD only -- there is deliberately no mutating endpoint):
  /              dashboard (static)
  /health        ALB target-group health check
  /api/whoami    identity of the instance that served this request (IMDSv2)
  /api/state     ASG / target-group / EC2 / scaling-activity state, read from AWS

AWS access uses the instance profile's read-only role. Resource names come from
environment variables set at boot; nothing in a request can choose which
resources are described.
"""

import datetime as dt
import json
import os
import socket
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REGION = os.environ.get("AWS_REGION", "ap-south-1")
ASG_NAME = os.environ.get("ASG_NAME", "vmfail-asg")
TG_NAME = os.environ.get("TG_NAME", "vmfail-tg")
ALB_DNS = os.environ.get("ALB_DNS", "")
PORT = int(os.environ.get("PORT", "8080"))
STATE_TTL = float(os.environ.get("STATE_TTL", "2.0"))
STATIC_DIR = os.environ.get(
    "STATIC_DIR", os.path.join(os.path.dirname(os.path.abspath(__file__)), "static")
)

STATIC_FILES = {
    "/": ("index.html", "text/html; charset=utf-8"),
    "/index.html": ("index.html", "text/html; charset=utf-8"),
    "/app.js": ("app.js", "text/javascript; charset=utf-8"),
    "/app.css": ("app.css", "text/css; charset=utf-8"),
}

SECURITY_HEADERS = {
    "Content-Security-Policy": "default-src 'self'; img-src 'self' data:; "
    "style-src 'self' 'unsafe-inline'; script-src 'self'; connect-src 'self'; frame-ancestors 'none'",
    "X-Content-Type-Options": "nosniff",
    "X-Frame-Options": "DENY",
    "Referrer-Policy": "no-referrer",
    "Cross-Origin-Opener-Policy": "same-origin",
    "Cross-Origin-Resource-Policy": "same-origin",
    "Permissions-Policy": "camera=(), microphone=(), geolocation=()",
}

STARTED_AT = time.time()


# --------------------------------------------------------------------------
# Instance identity via IMDSv2
# --------------------------------------------------------------------------
IMDS = "http://169.254.169.254/latest"


def _imds_token(timeout=1.0):
    req = urllib.request.Request(
        f"{IMDS}/api/token",
        method="PUT",
        headers={"X-aws-ec2-metadata-token-ttl-seconds": "21600"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read().decode()


def _imds_get(path, token, timeout=1.0):
    req = urllib.request.Request(
        f"{IMDS}/meta-data/{path}", headers={"X-aws-ec2-metadata-token": token}
    )
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read().decode()


def load_identity():
    """Read identity once at startup; it cannot change for a running instance."""
    try:
        token = _imds_token()
        return {
            "instance_id": _imds_get("instance-id", token),
            "availability_zone": _imds_get("placement/availability-zone", token),
            "hostname": _imds_get("local-hostname", token),
            "private_ip": _imds_get("local-ipv4", token),
            "instance_type": _imds_get("instance-type", token),
            "source": "imdsv2",
        }
    except Exception:
        # Not on EC2 (local development). Never invent an instance ID.
        return {
            "instance_id": None,
            "availability_zone": None,
            "hostname": socket.gethostname(),
            "private_ip": None,
            "instance_type": None,
            "source": "not-ec2",
        }


IDENTITY = load_identity()


# --------------------------------------------------------------------------
# AWS state (read-only)
# --------------------------------------------------------------------------
class AwsState:
    def __init__(self, clients=None):
        self._clients = clients
        self._lock = threading.Lock()
        self._cache = None
        self._cache_at = 0.0
        self._tg_arn = None

    def clients(self):
        if self._clients is None:
            import boto3  # imported lazily so tests run without boto3

            self._clients = {
                "autoscaling": boto3.client("autoscaling", region_name=REGION),
                "elbv2": boto3.client("elbv2", region_name=REGION),
                "ec2": boto3.client("ec2", region_name=REGION),
            }
        return self._clients

    def tg_arn(self):
        if self._tg_arn is None:
            tgs = self.clients()["elbv2"].describe_target_groups(Names=[TG_NAME])
            self._tg_arn = tgs["TargetGroups"][0]["TargetGroupArn"]
        return self._tg_arn

    def get(self):
        with self._lock:
            now = time.time()
            if self._cache is None or now - self._cache_at >= STATE_TTL:
                try:
                    self._cache = collect_state(self.clients(), self.tg_arn())
                except Exception as e:  # report, never fabricate
                    # Only the error code reaches the public page: botocore messages can
                    # contain the role ARN / account ID. Full detail goes to the journal.
                    code = getattr(e, "response", {}).get("Error", {}).get("Code")
                    sys.stderr.write(f"state error: {type(e).__name__}: {e}\n")
                    self._cache = {
                        "error": f"AWS state unavailable ({code or type(e).__name__})",
                        "fetched_at": iso(dt.datetime.now(dt.timezone.utc)),
                    }
                self._cache_at = now
            return self._cache


def iso(value):
    if isinstance(value, dt.datetime):
        if value.tzinfo is None:
            value = value.replace(tzinfo=dt.timezone.utc)
        return value.astimezone(dt.timezone.utc).isoformat().replace("+00:00", "Z")
    return value


def collect_state(c, tg_arn):
    fetched_at = dt.datetime.now(dt.timezone.utc)

    groups = c["autoscaling"].describe_auto_scaling_groups(
        AutoScalingGroupNames=[ASG_NAME]
    )["AutoScalingGroups"]
    if not groups:
        raise RuntimeError(f"Auto Scaling Group {ASG_NAME} not found")
    asg = groups[0]

    targets = c["elbv2"].describe_target_health(TargetGroupArn=tg_arn)[
        "TargetHealthDescriptions"
    ]
    activities = c["autoscaling"].describe_scaling_activities(
        AutoScalingGroupName=ASG_NAME, MaxRecords=15
    )["Activities"]

    # EC2 view of every instance this group has owned recently (terminated
    # instances stay visible for about an hour), plus anything registered.
    ec2_by_id = {}
    resp = c["ec2"].describe_instances(
        Filters=[{"Name": "tag:aws:autoscaling:groupName", "Values": [ASG_NAME]}]
    )
    for res in resp.get("Reservations", []):
        for inst in res["Instances"]:
            ec2_by_id[inst["InstanceId"]] = inst

    asg_by_id = {i["InstanceId"]: i for i in asg.get("Instances", [])}
    tgt_by_id = {t["Target"]["Id"]: t for t in targets}

    instances = []
    for iid in set(ec2_by_id) | set(asg_by_id) | set(tgt_by_id):
        e, a, t = ec2_by_id.get(iid, {}), asg_by_id.get(iid), tgt_by_id.get(iid)
        th = (t or {}).get("TargetHealth", {})
        instances.append(
            {
                "instance_id": iid,
                "availability_zone": e.get("Placement", {}).get("AvailabilityZone")
                or (a or {}).get("AvailabilityZone"),
                "launch_time": iso(e.get("LaunchTime")),
                "private_ip": e.get("PrivateIpAddress"),
                "private_dns": e.get("PrivateDnsName"),
                "instance_type": e.get("InstanceType"),
                "ec2_state": e.get("State", {}).get("Name"),
                "state_reason": e.get("StateReason", {}).get("Message"),
                "in_asg": a is not None,
                "asg_lifecycle": (a or {}).get("LifecycleState"),
                "asg_health": (a or {}).get("HealthStatus"),
                "target_state": th.get("State"),  # None == not registered
                "target_reason": th.get("Reason"),
                "target_description": th.get("Description"),
            }
        )
    instances.sort(key=lambda i: (i["launch_time"] or "", i["instance_id"]))

    desired = asg["DesiredCapacity"]
    healthy_targets = sum(1 for i in instances if i["target_state"] == "healthy")
    in_service = sum(1 for i in instances if i["asg_lifecycle"] == "InService")
    activity_in_progress = any(
        a["StatusCode"] not in ("Successful", "Failed", "Cancelled") for a in activities
    )
    replacing = any(
        i["in_asg"]
        and i["target_state"] != "healthy"
        and (i["asg_lifecycle"] or "").startswith(("Pending", "InService"))
        for i in instances
    )

    if healthy_targets == 0:
        overall = "OUTAGE"
    elif healthy_targets >= desired and in_service >= desired and not activity_in_progress:
        overall = "HEALTHY"
    elif replacing:
        overall = "RECOVERING"
    else:
        overall = "DEGRADED"

    return {
        "fetched_at": iso(fetched_at),
        "region": REGION,
        "overall": overall,
        "asg": {
            "name": asg["AutoScalingGroupName"],
            "min": asg["MinSize"],
            "desired": desired,
            "max": asg["MaxSize"],
            "health_check_type": asg.get("HealthCheckType"),
            "in_service": in_service,
        },
        "target_group": {"name": TG_NAME, "healthy": healthy_targets},
        "instances": instances,
        "activities": [
            {
                "id": a["ActivityId"],
                "status": a["StatusCode"],
                "progress": a.get("Progress"),
                "start": iso(a.get("StartTime")),
                "end": iso(a.get("EndTime")),
                "description": a.get("Description"),
                "cause": a.get("Cause"),
            }
            for a in activities
        ],
    }


STATE = AwsState()


# --------------------------------------------------------------------------
# HTTP
# --------------------------------------------------------------------------
class Handler(BaseHTTPRequestHandler):
    server_version = "vmfail-demo/1.0"
    sys_version = ""

    def _send(self, status, body, ctype, extra=None):
        data = body if isinstance(body, bytes) else body.encode()
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Instance-Id", IDENTITY["instance_id"] or "not-ec2")
        self.send_header("X-Availability-Zone", IDENTITY["availability_zone"] or "unknown")
        self.send_header("X-Instance-Hostname", IDENTITY["hostname"] or "unknown")
        for k, v in {**SECURITY_HEADERS, **(extra or {})}.items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def _json(self, status, obj):
        self._send(status, json.dumps(obj), "application/json")

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/health":
            return self._send(200, "ok\n", "text/plain")
        if path == "/api/whoami":
            return self._json(
                200,
                {
                    **IDENTITY,
                    "served_at": iso(dt.datetime.now(dt.timezone.utc)),
                    "app_uptime_s": round(time.time() - STARTED_AT, 1),
                },
            )
        if path == "/api/state":
            state = STATE.get()
            return self._json(200, {**state, "served_by": IDENTITY, "alb_dns": ALB_DNS})
        if path in STATIC_FILES:
            name, ctype = STATIC_FILES[path]
            try:
                with open(os.path.join(STATIC_DIR, name), "rb") as f:
                    return self._send(200, f.read(), ctype)
            except FileNotFoundError:
                return self._send(404, "not found\n", "text/plain")
        return self._send(404, "not found\n", "text/plain")

    do_HEAD = do_GET

    def _method_not_allowed(self):
        self._send(405, "method not allowed\n", "text/plain", {"Allow": "GET, HEAD"})

    do_POST = do_PUT = do_DELETE = do_PATCH = _method_not_allowed

    def log_message(self, fmt, *args):
        if "/health" not in (self.path or "") and "/api/" not in (self.path or ""):
            sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))


def main():
    httpd = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    httpd.daemon_threads = True
    print(
        f"demo app on :{PORT} instance={IDENTITY['instance_id']} "
        f"az={IDENTITY['availability_zone']} asg={ASG_NAME} tg={TG_NAME}",
        flush=True,
    )
    httpd.serve_forever()


if __name__ == "__main__":
    main()
