#!/usr/bin/env bash
# Inject a REAL failure: terminate one instance of the experiment's Auto Scaling Group.
# Run from the operator's laptop only. The public dashboard has no equivalent control.
#
# Usage:
#   scripts/fail-instance.sh                 # pick from a list of the group's instances
#   scripts/fail-instance.sh i-0abc123...    # target a specific instance
# Options:
#   --mode asg     (default) ASG-managed termination: deregister + drain, then terminate.
#                  The ASG launches a replacement because desired capacity is kept.
#   --mode crash   Abrupt EC2 TerminateInstances, as if the VM died. The ALB and ASG
#                  must discover the loss themselves, so some requests may fail.
#   --no-watch     Return right after termination instead of following recovery.
#
# Safety checks (all enforced here, never in the browser):
#   * the instance ID is well-formed and is currently a member of $ASG_NAME
#   * the ASG carries Project=$PROJECT_TAG and the instance carries the ASG's tag
#   * at least one OTHER instance is a healthy target, so the last healthy target
#     is never terminated (no override exists)
#   * you must type the full instance ID, then separately type "terminate"
#   * membership and the surviving-target check are re-run immediately before acting
set -euo pipefail
source "$(dirname "$0")/config.sh"

MODE=asg; WATCH=true; TARGET=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="${2:-}"; shift 2 ;;
    --no-watch) WATCH=false; shift ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    i-*) TARGET="$1"; shift ;;
    *) die "Unknown argument: $1" ;;
  esac
done
[[ "$MODE" == asg || "$MODE" == crash ]] || die "--mode must be asg or crash"

require_aws_session

# -------------------------------------------------------------- allowlist checks
asg_tag=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG_NAME" \
  --query "AutoScalingGroups[0].Tags[?Key=='Project'].Value | [0]" --output text)
[[ "$asg_tag" == "$PROJECT_TAG" ]] || die "ASG $ASG_NAME not found or not tagged Project=$PROJECT_TAG; refusing."

TG_ARN=$(aws elbv2 describe-target-groups --names "$TG_NAME" --query 'TargetGroups[0].TargetGroupArn' --output text)

members() {  # id az lifecycle health, sorted by AZ
  aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG_NAME" \
    --query 'AutoScalingGroups[0].Instances[].[InstanceId,AvailabilityZone,LifecycleState,HealthStatus]' \
    --output text | sort -k2,2 -k1,1
}
target_state() {
  aws elbv2 describe-target-health --target-group-arn "$TG_ARN" --targets "Id=$1,Port=$APP_PORT" \
    --query 'TargetHealthDescriptions[0].TargetHealth.State' --output text 2>/dev/null || echo unknown
}
healthy_count() {
  aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
    --query 'length(TargetHealthDescriptions[?TargetHealth.State==`healthy`])' --output text
}
healthy_others() {  # healthy targets other than $1
  aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
    --query "length(TargetHealthDescriptions[?TargetHealth.State=='healthy' && Target.Id!='$1'])" --output text
}
verify_survivor() {
  local others
  others=$(healthy_others "$1")
  [[ "$others" =~ ^[0-9]+$ ]] && (( others >= 1 )) \
    || die "No other healthy target besides $1 (found: $others). Terminating it would take the application down; refusing. Wait for recovery (scripts/status.sh)."
}

mapfile -t ROWS < <(members)
[[ ${#ROWS[@]} -gt 0 ]] || die "ASG $ASG_NAME has no instances."

echo
echo "Instances in Auto Scaling Group $ASG_NAME ($AWS_REGION):"
printf '  %-3s %-21s %-12s %-12s %-9s %s\n' "#" "INSTANCE" "AZ" "LIFECYCLE" "ASG" "TARGET"
n=0
for row in "${ROWS[@]}"; do
  read -r id az lc hs <<<"$row"
  n=$((n + 1))
  printf '  %-3s %-21s %-12s %-12s %-9s %s\n' "$n)" "$id" "$az" "$lc" "$hs" "$(target_state "$id")"
done
echo

if [[ -z "$TARGET" ]]; then
  read -r -p "Select instance number to terminate (or q to quit): " pick
  [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= ${#ROWS[@]} )) || die "Aborted."
  read -r TARGET _ <<<"${ROWS[$((pick - 1))]}"
fi

[[ "$TARGET" =~ ^i-[0-9a-f]{8,17}$ ]] || die "Not a valid instance ID: $TARGET"

verify_member() {
  local lc tag
  lc=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG_NAME" \
    --query "AutoScalingGroups[0].Instances[?InstanceId=='$1'].LifecycleState | [0]" --output text)
  [[ "$lc" == "InService" ]] || die "$1 is not an InService member of $ASG_NAME (state: $lc); refusing."
  tag=$(aws ec2 describe-instances --instance-ids "$1" \
    --query "Reservations[0].Instances[0].Tags[?Key=='aws:autoscaling:groupName'].Value | [0]" --output text)
  [[ "$tag" == "$ASG_NAME" ]] || die "$1 is not tagged as part of $ASG_NAME; refusing."
}
verify_member "$TARGET"

verify_survivor "$TARGET"
HEALTHY=$(healthy_count)

AZ=$(aws ec2 describe-instances --instance-ids "$TARGET" --query 'Reservations[0].Instances[0].Placement.AvailabilityZone' --output text)
cat <<EOF
About to TERMINATE a real EC2 instance:
  instance      $TARGET  ($AZ)
  group         $ASG_NAME
  mode          $MODE $( [[ $MODE == asg ]] && echo "(drain from ALB, then terminate; ASG replaces it)" || echo "(abrupt EC2 termination; ALB/ASG must detect it)")
  healthy now   $HEALTHY target(s)
This cannot be undone. Auto Scaling will launch a NEW instance with a different ID.

EOF
read -r -p "Type the instance ID to confirm: " confirm
[[ "$confirm" == "$TARGET" ]] || die "Instance ID did not match; nothing was terminated."
read -r -p 'Type "terminate" to proceed: ' confirm2
[[ "$confirm2" == "terminate" ]] || die "Not confirmed; nothing was terminated."

verify_member "$TARGET"     # re-check membership right before acting
verify_survivor "$TARGET"   # and that another healthy target remains
START=$(date +%s)
if [[ "$MODE" == asg ]]; then
  aws autoscaling terminate-instance-in-auto-scaling-group --instance-id "$TARGET" \
    --no-should-decrement-desired-capacity \
    --query 'Activity.[ActivityId,Description]' --output text
else
  aws ec2 terminate-instances --instance-ids "$TARGET" \
    --query 'TerminatingInstances[0].[InstanceId,PreviousState.Name,CurrentState.Name]' --output text
fi
log "Termination requested at $(date '+%H:%M:%S'). Watch the dashboard, or follow here."

$WATCH || exit 0

DESIRED=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG_NAME" --query 'AutoScalingGroups[0].DesiredCapacity' --output text)
log "Following recovery (Ctrl-C to stop watching; recovery continues regardless)"
for _ in $(seq 1 120); do
  sleep 10
  T=$(( $(date +%s) - START ))
  STATE=$(aws ec2 describe-instances --instance-ids "$TARGET" --query 'Reservations[0].Instances[0].State.Name' --output text)
  HEALTHY=$(healthy_count)
  INSVC=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG_NAME" \
    --query "length(AutoScalingGroups[0].Instances[?LifecycleState=='InService'])" --output text)
  NEW=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG_NAME" \
    --query "AutoScalingGroups[0].Instances[?InstanceId!='$TARGET'].[InstanceId,LifecycleState]" --output text | tr '\t\n' ': ')
  printf '  +%3ss  failed=%s  healthy targets=%s/%s  ASG: %s\n' "$T" "$STATE" "$HEALTHY" "$DESIRED" "$NEW"
  STILL_MEMBER=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG_NAME" \
    --query "length(AutoScalingGroups[0].Instances[?InstanceId=='$TARGET'])" --output text)
  if (( HEALTHY >= DESIRED && INSVC >= DESIRED && STILL_MEMBER == 0 )); then
    log "Recovered: $HEALTHY healthy targets ${T}s after termination was requested."
    exit 0
  fi
done
warn "Not recovered within 20 minutes; inspect scripts/status.sh and the ASG activity history."
