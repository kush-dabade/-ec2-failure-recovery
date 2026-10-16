#!/usr/bin/env python3
"""Evidence tool: polls the live /api/state through the ALB every 2 s and, the first
time each real AWS transition is seen, requests a dashboard screenshot and runs the
matching read-only CLI capture. Writes a transition log (UTC) to raw/transitions.log.

Usage: recovery_watch.py <alb-url> <failed-instance-id> <survivor-instance-id>
"""
import datetime as dt
import json
import os
import subprocess
import sys
import time
import urllib.request

ALB, FAILED, SURVIVOR = sys.argv[1].rstrip("/"), sys.argv[2], sys.argv[3]
EV = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REQ = "/tmp/claude-1000/-home-kush-projects-vm-failure/68519b09-a86b-44f6-92f9-ab4d3d0dbd8f/scratchpad/shotreq"
LOG = open(os.path.join(EV, "raw", "transitions.log"), "a", buffering=1)
TG = subprocess.run(["aws", "elbv2", "describe-target-groups", "--names", "vmfail-tg", "--query",
                     "TargetGroups[0].TargetGroupArn", "--output", "text"], capture_output=True, text=True).stdout.strip()
seen = set()


def now():
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")


def shot(name, selector=None):
    open(os.path.join(REQ, name + (f"@{selector}" if selector else "")), "w").close()
    time.sleep(1.5)


def cap(name, title, *cmd):
    subprocess.run([os.path.join(EV, "tools", "cap.sh"), name, title, *cmd], capture_output=True)


def once(key, msg, actions):
    if key in seen:
        return
    seen.add(key)
    LOG.write(f"{now()}  {msg}\n")
    print(now(), msg, flush=True)
    for a in actions:
        a()


TARGETS = lambda n, t: lambda: cap(n, t, "aws", "elbv2", "describe-target-health", "--target-group-arn", TG, "--query",
                                   "TargetHealthDescriptions[].{Target:Target.Id,State:TargetHealth.State,Reason:TargetHealth.Reason}", "--output", "table")
ACTIVITY = lambda n, t: lambda: cap(n, t, "aws", "autoscaling", "describe-scaling-activities", "--auto-scaling-group-name", "vmfail-asg",
                                    "--max-items", "4", "--query", "Activities[].{Start:StartTime,End:EndTime,Status:StatusCode,Description:Description,Cause:Cause}", "--output", "json")
ASG = lambda n, t: lambda: cap(n, t, "aws", "autoscaling", "describe-auto-scaling-groups", "--auto-scaling-group-names", "vmfail-asg", "--query",
                               "AutoScalingGroups[0].{Desired:DesiredCapacity,Min:MinSize,Max:MaxSize,Instances:Instances[].[InstanceId,AvailabilityZone,LifecycleState,HealthStatus]}", "--output", "json")

replacement = None
deadline = time.time() + 1500
while time.time() < deadline:
    try:
        st = json.load(urllib.request.urlopen(f"{ALB}/api/state?t={time.time()}", timeout=5))
    except Exception as e:
        print(now(), "state fetch failed:", type(e).__name__, flush=True)
        time.sleep(2)
        continue
    if st.get("error"):
        print(now(), "state error:", st["error"], flush=True)
        time.sleep(2)
        continue
    by = {i["instance_id"]: i for i in st["instances"]}
    f = by.get(FAILED, {})
    if f.get("target_state") == "draining" or (f.get("asg_lifecycle") or "").startswith("Terminating"):
        once("draining", f"AWS: {FAILED} leaving service (lifecycle={f.get('asg_lifecycle')}, target={f.get('target_state')})",
             [lambda: shot("07-failure-observed"), TARGETS("07b-targets-draining", "Target health while the failed instance drains"),
              ACTIVITY("07c-asg-activity-terminating", "Auto Scaling activity: termination of the selected instance")])
    if f.get("ec2_state") in ("shutting-down", "terminated"):
        once("ec2-down", f"AWS: {FAILED} EC2 state {f.get('ec2_state')}", [lambda: shot("08-application-after-failure")])
    for iid, i in by.items():
        if iid not in (FAILED, SURVIVOR) and i["in_asg"] and replacement is None:
            replacement = iid
    if replacement:
        r = by[replacement]
        once("repl", f"AWS: replacement {replacement} in {r['availability_zone']} (ec2={r['ec2_state']}, lifecycle={r['asg_lifecycle']})",
             [lambda: shot("09-autoscaling-replacement"), ACTIVITY("09b-asg-activity-launch", "Auto Scaling activity: replacement launch"),
              lambda: cap("10-replacement-instance", "Replacement EC2 instance (new ID)", "aws", "ec2", "describe-instances", "--instance-ids", replacement,
                          "--query", "Reservations[].Instances[].{InstanceId:InstanceId,State:State.Name,AZ:Placement.AvailabilityZone,Launched:LaunchTime,PrivateIP:PrivateIpAddress}", "--output", "table")])
        if r.get("ec2_state") == "running":
            once("repl-running", f"AWS: replacement {replacement} running", [])
        if r.get("target_state") == "initial":
            once("repl-initial", f"AWS: replacement {replacement} registered, health checks in progress",
                 [lambda: shot("10b-dashboard-replacement-health-check"), TARGETS("10c-targets-recovering", "Target health during recovery (replacement in initial health check)")])
        if r.get("target_state") == "healthy":
            once("repl-healthy", f"AWS: replacement {replacement} healthy target", [])
    if replacement and st["overall"] == "HEALTHY" and st["target_group"]["healthy"] >= st["asg"]["desired"] and FAILED not in [i["instance_id"] for i in st["instances"] if i["in_asg"]]:
        once("recovered", f"AWS: recovered: {st['target_group']['healthy']} healthy targets, desired {st['asg']['desired']}", [
            lambda: time.sleep(4), lambda: shot("12-dashboard-recovered"),
            lambda: shot("12b-dashboard-run-result", "#summary-card"),
            lambda: shot("12c-dashboard-timeline", ".timeline-card"),
            TARGETS("11-targets-recovered", "Target group health after recovery"),
            ASG("13-asg-final", "Auto Scaling Group after recovery (desired capacity 2)"),
            ACTIVITY("13b-asg-activity-final", "Auto Scaling activity history after recovery"),
            lambda: open(os.path.join(REQ, "dump"), "w").close()])
        break
    time.sleep(2)
print(now(), "watch finished", flush=True)
