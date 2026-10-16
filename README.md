# EC2 High Availability & Failure Recovery

A live experiment showing that an application behind an **Application Load Balancer**
keeps serving traffic when an EC2 instance fails, and that an **Auto Scaling Group**
automatically replaces it. A dashboard served through the ALB shows the real AWS
state as it changes.

```
Browser ──HTTP──▶ ALB (vmfail-alb) ──▶ target group (vmfail-tg, /health) ──▶ EC2-1 (ap-south-1a)
                                                                         └──▶ EC2-2 (ap-south-1b)
                                         Auto Scaling Group vmfail-asg (min 2 / desired 2 / max 3)

Each instance runs app/server.py:
  /            dashboard
  /api/whoami  "which instance answered" (IMDSv2: instance ID, hostname, AZ)
  /api/state   ASG + target health + EC2 state + scaling activities (read-only IAM role)

Operator laptop (WSL) ──AWS CLI──▶ scripts/fail-instance.sh ──▶ terminates ONE ASG member
```

## Project layout

| Path | Purpose |
|---|---|
| `app/server.py` | Per-instance web app + read-only state API (Python stdlib + boto3). GET/HEAD only. |
| `app/static/` | Dashboard (HTML/CSS/JS, no external dependencies). |
| `scripts/config.sh` | Region, VPC/subnets, resource names (the experiment allowlist). |
| `scripts/deploy.sh` | Creates all infrastructure (**billable**, asks for confirmation). |
| `scripts/fail-instance.sh` | Laptop-only failure injection with allowlist checks + typed confirmation. |
| `scripts/status.sh` | Read-only snapshot of ASG, targets, activities, endpoint. |
| `scripts/update-app.sh` | Roll out changed dashboard code via instance refresh. |
| `scripts/cleanup.sh` | Deletes everything `deploy.sh` created. |
| `scripts/build-userdata.sh` | Packages the app and generates EC2 user data (used by deploy/update). |
| `iam/` | Trust policy, the instances' read-only policy, optional least-privilege operator policy. |
| `tests/` | Backend tests and a **test-only** fixture for previewing the UI without AWS. |

## Prerequisites

- AWS CLI v2, signed in (`aws login`), region `ap-south-1`
- Python 3 on the laptop (used only to write JSON during deploy)
- Account `851226124537`, default VPC `vpc-0bbf56888f5140e56`

## Validate locally (no AWS, no cost)

```bash
python3 -m unittest discover -s tests -v      # backend: state logic, HTTP surface, no mutating routes, no ARN leaks
bash tests/test_fail_instance.sh              # failure-script safety checks against a stub `aws` (16 cases)
node --check app/static/app.js                # frontend syntax
python3 tests/preview.py 8099 6               # open http://127.0.0.1:8099/ ; replays a scripted failure
```

`tests/preview.py` drives the real dashboard with **fake fixture data** so you can check the
UI. It is never deployed and must not be used for the actual demonstration.

## Deploy

```bash
./scripts/deploy.sh          # shows what will be created, then asks you to type "deploy"
```

It creates the S3 bucket, IAM role/profile, two security groups, target group, ALB,
launch template and ASG, then waits until 2 targets are healthy (about 3–5 minutes) and
prints the URL:

```
Dashboard: http://vmfail-alb-<id>.ap-south-1.elb.amazonaws.com/
```

`./scripts/status.sh` prints the URL again at any time. To restrict who can open the
dashboard, deploy with `ALLOWED_CIDR=<your-ip>/32 ./scripts/deploy.sh`.

## Demo procedure (college practical)

1. **Open the dashboard** at the ALB URL. Status should be **HEALTHY**, with EC2-1 and EC2-2 in different AZs and 2/2 healthy targets.
2. **Click "Start normal operation".** The page sends a real request through the ALB every 0.7 s. The request log and routing diagram show both instances answering in turn.
3. **Fail EC2-1** from the WSL terminal (the dashboard shows the exact command with the current instance ID):
   ```bash
   ./scripts/fail-instance.sh i-0123456789abcdef0      # or run with no argument to pick from a list
   ```
   The script lists the group's instances and checks that the target is an InService member of
   `vmfail-asg` and that **another** instance is a healthy target. You then **type the full instance ID**
   and, separately, **`terminate`**. Both checks run again immediately before it acts. It never
   terminates the last healthy target, and there is no override.
4. **Watch the dashboard** (all from real AWS state):
   - ASG activity *"Terminating EC2 instance"* (tagged *Operator request*)
   - EC2-1: HEALTHY → DRAINING → TERMINATING → TERMINATED
   - healthy targets 2 → 1, status **DEGRADED**, every request now served by **EC2-2**
   - Auto Scaling launches a **Replacement** card with a new instance ID and AZ, PENDING → HEALTH CHECK → HEALTHY
   - status **RECOVERING** → **HEALTHY**, "2 healthy targets restored"
5. **Read the Run result card**: whether the app stayed accessible, request success/failure counts, which instance served traffic after the failure, the replacement ID, time to restore, and any observed downtime.
6. **Fail EC2-2** the same way (the dashboard's command list updates to the current instances, including replacements).
7. **Run again**: "Refresh state & start new run" re-reads AWS and makes the *current* instances the new baseline. Terminated instances never return; Auto Scaling has created new ones.

Typical timings: failure confirmed within ~2 s, draining ~20 s, replacement launched within
~30–60 s, replacement healthy ~2–4 min after launch.

**Variant: abrupt crash.** `./scripts/fail-instance.sh --mode crash <id>` calls EC2 `TerminateInstances` directly, as if the VM died, instead of the ASG's graceful deregister-then-terminate. The ALB and ASG must detect the loss themselves, so some requests may fail. The dashboard counts them and reports the measured gap.

## How the measurements work

- **Instance identity** comes from each instance's own IMDSv2 metadata, returned in the JSON and in `X-Instance-Id`, `X-Availability-Zone` and `X-Instance-Hostname` headers.
- The dashboard shows these separately: **EC2 state** (pending/running/shutting-down/terminated), **ASG lifecycle** (Pending/InService/Terminating), **target health** (initial/healthy/draining/unhealthy), **HTTP availability** (real request results), **desired capacity**, and **healthy serving instances**.
- **Timeline** entries are tagged *AWS observed* (state changes between polls), *ASG activity* (AWS scaling activity records with AWS timestamps), *Operator request* (an ASG activity caused by a user request), *HTTP observed* (real responses), or *Dashboard* (actions in this page).
- **Downtime** is the longest run of consecutive failed requests, measured from the first failure to the next success. If no request fails, the page says *"none observed at a 700 ms sampling interval"*, not "zero downtime", because gaps shorter than the interval cannot be ruled out.
- Durations use the browser's clock and the 2 s state poll, so they are accurate to about ±2 s.

## Security

- **The public site is read-only.** The server implements GET/HEAD only (POST/PUT/DELETE return 405) and has no endpoint that accepts an instance ID or AWS command. Requests cannot choose which resources are described; names are fixed at boot.
- **No credentials reach the browser.** Instances use the instance profile `vmfail-dashboard-readonly-role`, which allows only `autoscaling:Describe{AutoScalingGroups,ScalingActivities}`, `elasticloadbalancing:Describe{TargetGroups,TargetHealth}`, `ec2:DescribeInstances`, and `s3:GetObject` on `vmfail-app-…/app/*`. It cannot modify or terminate anything. Access Analyzer reports no findings for it.
- **Failure injection happens only on the laptop**, using your local AWS CLI session. `fail-instance.sh` checks the ASG's `Project` tag, the instance's ASG membership and `aws:autoscaling:groupName` tag, and that another healthy target exists. It requires the full instance ID and then `terminate`, and re-runs the membership and survivor checks immediately before acting.
- **Ownership guard:** `deploy.sh` and `cleanup.sh` reuse, modify or delete a resource only if its exact experiment name matches *and* it carries `Project=vm-failure-demo`. S3 calls pin `--expected-bucket-owner`, so a same-named bucket in another account is never used.
- **Network:** the ALB security group allows 80 in from `ALLOWED_CIDR` and only 8080 out to the instance group. The instance security group allows 8080 in from the ALB group only and 443 out only. There is no SSH and no key pair. The ALB drops invalid header fields.
- **Instances:** IMDSv2 required (hop limit 1), encrypted gp3 root volume, T3 `standard` credits, and the app runs as an unprivileged systemd user with `ProtectSystem=strict`.
- **S3:** all Block Public Access settings on, ACLs disabled (bucket-owner-enforced), SSE-S3 encryption, and a bucket policy denying non-TLS access.
- **Response headers:** CSP (`script-src 'self'`, `frame-ancestors 'none'`), `X-Frame-Options: DENY`, `nosniff`, `no-referrer`, COOP/CORP `same-origin`, Permissions-Policy. AWS errors are shown publicly as an error code only; the full message, which may contain the role ARN, goes to the instance journal.

**Limitations**
- **Not verified until deployment:** boot-time install on real Amazon Linux 2023. The app bundle passes a Python 3.9 parse check, `boto3==1.42.97` is the newest release that supports Python 3.9, and the launch settings pass an EC2 `--dry-run`. The AL2023 package repo is only reachable from inside AWS, though, so the first `deploy.sh` run (it waits for 2 healthy targets) is the real test.
- The dashboard CSP allows inline *styles* (`'unsafe-inline'` for per-instance colors). Scripts are `'self'` only, and all AWS-sourced text is HTML-escaped.
- At boot, instances install `python3-pip` from the AL2023 repos and `boto3` from PyPI over HTTPS. There is no hash pinning, so this depends on PyPI being available and trustworthy at boot time.
- The dashboard uses plain HTTP (no certificate or domain) and is public unless you set `ALLOWED_CIDR`. It exposes only instance IDs, AZs and private IPs of this experiment.
- Your laptop CLI currently signs in as the **account root user**, so the client-side checks in `fail-instance.sh` are the main guard. For least privilege, create an IAM user or role from `iam/operator-failure-policy.json`; it can terminate only instances tagged as members of `vmfail-asg`. This was not created because it needs your approval.
- Instances have public IPs (default VPC, no NAT) so they can reach PyPI and the AWS APIs. Inbound access is still restricted to the ALB.

## AWS costs (ap-south-1, approximate)

Rates from the AWS Price List API for ap-south-1 (checked 2026-10-16):

| Item | Unit price | Hourly |
|---|---|---|
| ALB | $0.0239/h | $0.0239 |
| ALB LCU | $0.008/LCU-h; ~0.1 LCU at demo traffic, ~0 idle | ≤ $0.001 |
| 2 × t3.micro (Linux, on-demand) | $0.0112/h each | $0.0224 |
| 4 public IPv4 (2 instances + ALB in 2 AZs) | $0.005/h each | $0.0200 |
| 2 × 8 GB gp3 | $0.0912/GB-month | $0.0020 |
| S3 (one ~21 KB object), IAM, launch template, ASG, service-linked roles | n/a | ~$0 |
| **Total** | | **≈ $0.069/h ≈ $1.66/day ≈ $50/month** |

- **All of this accrues 24/7 while the stack exists, including when you are not testing.** Only `cleanup.sh` stops it.
- Each failure run briefly adds a third instance and public IP (a few cents at most).
- T3 `standard` credit mode means no surplus-credit charges ($0.05/vCPU-h in unlimited mode).
- This account is on the AWS **Free plan** ($139.77 credits remaining, plan expires 2027-01-24). Charges are taken from those credits, so leaving the stack up for about 12 weeks would use them all.

## Cleanup

```bash
./scripts/cleanup.sh       # type "delete vmfail" to confirm
```

This deletes the ASG (and its instances), ALB, target group, launch template, both security
groups, the IAM role/instance profile and the S3 bucket. It looks up resources only by the
experiment names in `scripts/config.sh`.

## Updating the dashboard code

```bash
./scripts/update-app.sh    # new package + launch-template version + instance refresh (replaces instances)
```
