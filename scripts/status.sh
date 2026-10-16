#!/usr/bin/env bash
# Read-only snapshot of the experiment: ASG, target health, recent scaling activity.
set -euo pipefail
source "$(dirname "$0")/config.sh"
require_aws_session

echo "== Auto Scaling Group $ASG_NAME"
aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG_NAME" \
  --query 'AutoScalingGroups[0].[MinSize,DesiredCapacity,MaxSize,HealthCheckType]' --output text \
  | awk '{printf "  min %s  desired %s  max %s  health check %s\n",$1,$2,$3,$4}'
aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG_NAME" \
  --query 'AutoScalingGroups[0].Instances[].[InstanceId,AvailabilityZone,LifecycleState,HealthStatus]' --output table

TG_ARN=$(aws elbv2 describe-target-groups --names "$TG_NAME" --query 'TargetGroups[0].TargetGroupArn' --output text)
echo "== Target group $TG_NAME"
aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
  --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State,TargetHealth.Reason]' --output table

echo "== Recent scaling activity"
aws autoscaling describe-scaling-activities --auto-scaling-group-name "$ASG_NAME" --max-items 6 \
  --query 'Activities[].[StartTime,StatusCode,Description]' --output table

DNS=$(aws elbv2 describe-load-balancers --names "$ALB_NAME" --query 'LoadBalancers[0].DNSName' --output text)
echo "== Endpoint: http://$DNS/"
for _ in 1 2 3 4; do
  curl -s -m 3 -o /dev/null -w '  HTTP %{http_code}  ' "http://$DNS/api/whoami" || true
  curl -s -m 3 "http://$DNS/api/whoami" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["instance_id"], d["availability_zone"])' 2>/dev/null || echo "(no response)"
done
