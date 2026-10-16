"""TEST FIXTURE ONLY: fake boto3 clients that replay a scripted failure scenario.

Used by tests/test_server.py and tests/preview.py to exercise the real server and
dashboard locally without AWS. Never packaged or deployed (build-userdata.sh only
ships app/server.py and app/static/*).
"""

import datetime as dt

T0 = dt.datetime(2026, 10, 16, 6, 0, 0, tzinfo=dt.timezone.utc)
A, B, R = "i-0aaaa1111aaaa1111", "i-0bbbb2222bbbb2222", "i-0cccc3333cccc3333"
AZ = {A: "ap-south-1a", B: "ap-south-1b", R: "ap-south-1a"}

# phase -> {instance: (ec2_state, asg_lifecycle or None, target_state or None)}
PHASES = [
    {A: ("running", "InService", "healthy"), B: ("running", "InService", "healthy")},
    {A: ("running", "Terminating", "draining"), B: ("running", "InService", "healthy")},
    {A: ("shutting-down", "Terminating:Proceed", None), B: ("running", "InService", "healthy")},
    {A: ("terminated", None, None), B: ("running", "InService", "healthy"), R: ("pending", "Pending", None)},
    {A: ("terminated", None, None), B: ("running", "InService", "healthy"), R: ("running", "InService", "initial")},
    {A: ("terminated", None, None), B: ("running", "InService", "healthy"), R: ("running", "InService", "healthy")},
]


class Scenario:
    def __init__(self):
        self.phase = 0

    def snap(self):
        return PHASES[min(self.phase, len(PHASES) - 1)]

    def activities(self):
        acts = []
        if self.phase >= 1:
            acts.append({
                "ActivityId": "act-term", "StartTime": T0,
                "StatusCode": "Successful" if self.phase >= 3 else "WaitingForELBConnectionDraining",
                "Description": f"Terminating EC2 instance: {A}",
                "Cause": f"At 2026-10-16T06:00:00Z instance {A} was taken out of service in response to a user request.",
            })
        if self.phase >= 3:
            acts.append({
                "ActivityId": "act-launch", "StartTime": T0 + dt.timedelta(seconds=40),
                "StatusCode": "Successful" if self.phase >= 5 else "InProgress",
                "Description": f"Launching a new EC2 instance: {R}",
                "Cause": "An instance was started in response to a difference between desired and actual capacity.",
            })
        acts.append({
            "ActivityId": "act-init", "StartTime": T0 - dt.timedelta(hours=1), "EndTime": T0 - dt.timedelta(hours=1),
            "StatusCode": "Successful", "Description": f"Launching a new EC2 instance: {B}", "Cause": "initial",
        })
        return sorted(acts, key=lambda a: a["StartTime"], reverse=True)


class _AutoScaling:
    def __init__(self, sc):
        self.sc = sc

    def describe_auto_scaling_groups(self, AutoScalingGroupNames):
        inst = [
            {"InstanceId": i, "AvailabilityZone": AZ[i], "LifecycleState": lc, "HealthStatus": "Healthy"}
            for i, (_, lc, _) in self.sc.snap().items() if lc
        ]
        return {"AutoScalingGroups": [{
            "AutoScalingGroupName": AutoScalingGroupNames[0], "MinSize": 2, "DesiredCapacity": 2,
            "MaxSize": 3, "HealthCheckType": "ELB", "Instances": inst,
        }]}

    def describe_scaling_activities(self, AutoScalingGroupName, MaxRecords):
        return {"Activities": self.sc.activities()[:MaxRecords]}


class _Elbv2:
    def __init__(self, sc):
        self.sc = sc

    def describe_target_groups(self, Names):
        return {"TargetGroups": [{"TargetGroupArn": "arn:fake:tg"}]}

    def describe_target_health(self, TargetGroupArn):
        out = []
        for i, (_, _, ts) in self.sc.snap().items():
            if ts:
                th = {"State": ts}
                if ts == "draining":
                    th.update(Reason="Target.DeregistrationInProgress", Description="Target deregistration is in progress")
                if ts == "initial":
                    th.update(Reason="Elb.InitialHealthChecking", Description="Initial health checks in progress")
                out.append({"Target": {"Id": i, "Port": 8080}, "TargetHealth": th})
        return {"TargetHealthDescriptions": out}


class _Ec2:
    def __init__(self, sc):
        self.sc = sc

    def describe_instances(self, Filters):
        launch = {A: T0 - dt.timedelta(hours=1), B: T0 - dt.timedelta(hours=1), R: T0 + dt.timedelta(seconds=40)}
        ips = {A: "172.31.40.10", B: "172.31.5.20", R: "172.31.41.30"}
        return {"Reservations": [{"Instances": [{
            "InstanceId": i, "Placement": {"AvailabilityZone": AZ[i]}, "LaunchTime": launch[i],
            "PrivateIpAddress": ips[i], "InstanceType": "t3.micro", "State": {"Name": st},
        } for i, (st, _, _) in self.sc.snap().items()]}]}


def clients(sc):
    return {"autoscaling": _AutoScaling(sc), "elbv2": _Elbv2(sc), "ec2": _Ec2(sc)}
