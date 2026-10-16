#!/usr/bin/env bash
# Deletes EVERYTHING deploy.sh created (and nothing else: lookups are by experiment name).
# Order: ASG -> ALB -> target group -> launch template -> security groups -> IAM -> S3.
set -euo pipefail
source "$(dirname "$0")/config.sh"
require_aws_session

cat <<MSG
This permanently deletes: $ASG_NAME (and its instances), $ALB_NAME, $TG_NAME, $LT_NAME,
$ALB_SG_NAME, $APP_SG_NAME, IAM $ROLE_NAME/$PROFILE_NAME, and bucket $APP_BUCKET.
MSG
read -r -p "Type \"delete $PREFIX\" to continue: " a
[[ "$a" == "delete $PREFIX" ]] || die "Aborted; nothing deleted."

if nonempty "$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG_NAME" --query 'AutoScalingGroups[0].AutoScalingGroupName' --output text)"; then
  require_owned "$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG_NAME" \
    --query "AutoScalingGroups[0].Tags[?Key=='Project'].Value | [0]" --output text)" "Auto Scaling Group $ASG_NAME"
  log "Deleting Auto Scaling Group (terminates its instances)"
  aws autoscaling delete-auto-scaling-group --auto-scaling-group-name "$ASG_NAME" --force-delete
  for _ in $(seq 1 60); do
    nonempty "$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG_NAME" --query 'AutoScalingGroups[0].AutoScalingGroupName' --output text)" || break
    sleep 10
  done
fi

ALB_ARN=$(aws elbv2 describe-load-balancers --names "$ALB_NAME" --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || true)
if nonempty "$ALB_ARN"; then
  require_owned "$(elb_project_tag "$ALB_ARN")" "Load balancer $ALB_NAME"
  log "Deleting load balancer"
  aws elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN"
  aws elbv2 wait load-balancers-deleted --load-balancer-arns "$ALB_ARN"
fi

TG_ARN=$(aws elbv2 describe-target-groups --names "$TG_NAME" --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || true)
if nonempty "$TG_ARN"; then
  require_owned "$(elb_project_tag "$TG_ARN")" "Target group $TG_NAME"
  log "Deleting target group"
  # The listener reference can outlive the ALB deletion by a few seconds (ResourceInUse).
  for attempt in $(seq 1 12); do
    aws elbv2 delete-target-group --target-group-arn "$TG_ARN" 2>/dev/null && break
    (( attempt == 12 )) && die "Target group still in use after 2 minutes; re-run cleanup.sh"
    sleep 10
  done
fi

LT_TAG=$(aws ec2 describe-launch-templates --launch-template-names "$LT_NAME" \
  --query "LaunchTemplates[0].Tags[?Key=='Project'].Value | [0]" --output text 2>/dev/null || echo ABSENT)
if [[ "$LT_TAG" != ABSENT ]]; then
  require_owned "$LT_TAG" "Launch template $LT_NAME"
  log "Deleting launch template"; aws ec2 delete-launch-template --launch-template-name "$LT_NAME" >/dev/null
fi

declare -A SG_IDS=()
for name in "$APP_SG_NAME" "$ALB_SG_NAME"; do
  SG=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=$name" --query 'SecurityGroups[0].GroupId' --output text)
  nonempty "$SG" || continue
  require_owned "$(aws ec2 describe-security-groups --group-ids "$SG" --query "SecurityGroups[0].Tags[?Key=='Project'].Value | [0]" --output text)" "Security group $name"
  SG_IDS[$name]=$SG
done
# The two experiment groups reference each other (ALB egress -> app SG, app ingress -> ALB SG),
# which blocks deleting either. Revoke only those cross-references, then delete.
for SG in "${SG_IDS[@]}"; do
  for OTHER in "${SG_IDS[@]}"; do
    [[ "$SG" == "$OTHER" ]] && continue
    RULES=$(aws ec2 describe-security-group-rules --filters "Name=group-id,Values=$SG" \
      --query "SecurityGroupRules[?ReferencedGroupInfo.GroupId=='$OTHER'].[SecurityGroupRuleId,IsEgress]" --output text)
    while read -r rule egress; do
      nonempty "$rule" || continue
      log "Revoking rule $rule on $SG (references $OTHER)"
      if [[ "$egress" == True ]]; then
        aws ec2 revoke-security-group-egress --group-id "$SG" --security-group-rule-ids "$rule" >/dev/null
      else
        aws ec2 revoke-security-group-ingress --group-id "$SG" --security-group-rule-ids "$rule" >/dev/null
      fi
    done <<< "$RULES"
  done
done
for name in "$APP_SG_NAME" "$ALB_SG_NAME"; do
  SG="${SG_IDS[$name]:-}"
  nonempty "$SG" || continue
  log "Deleting security group $name ($SG)"
  # The ALB's network interfaces can take several minutes to release after deletion.
  for attempt in $(seq 1 60); do
    aws ec2 delete-security-group --group-id "$SG" 2>/dev/null && break
    (( attempt == 60 )) && die "Security group $name ($SG) still in use after 10 minutes; re-run cleanup.sh"
    sleep 10
  done
done

if aws iam get-instance-profile --instance-profile-name "$PROFILE_NAME" >/dev/null 2>&1; then
  require_owned "$(aws iam list-instance-profile-tags --instance-profile-name "$PROFILE_NAME" --query "Tags[?Key=='Project'].Value | [0]" --output text)" "Instance profile $PROFILE_NAME"
  log "Deleting instance profile"
  aws iam remove-role-from-instance-profile --instance-profile-name "$PROFILE_NAME" --role-name "$ROLE_NAME" 2>/dev/null || true
  aws iam delete-instance-profile --instance-profile-name "$PROFILE_NAME"
fi
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  require_owned "$(aws iam list-role-tags --role-name "$ROLE_NAME" --query "Tags[?Key=='Project'].Value | [0]" --output text)" "IAM role $ROLE_NAME"
  log "Deleting IAM role"
  aws iam delete-role-policy --role-name "$ROLE_NAME" --policy-name "$POLICY_NAME" 2>/dev/null || true
  aws iam delete-role --role-name "$ROLE_NAME"
fi

if aws s3api head-bucket --bucket "$APP_BUCKET" --expected-bucket-owner "$ACCOUNT_ID" 2>/dev/null; then
  require_owned "$(aws s3api get-bucket-tagging --bucket "$APP_BUCKET" --expected-bucket-owner "$ACCOUNT_ID" \
    --query "TagSet[?Key=='Project'].Value | [0]" --output text 2>/dev/null || true)" "Bucket $APP_BUCKET"
  log "Emptying and deleting bucket $APP_BUCKET"
  for key in $(aws s3api list-objects-v2 --bucket "$APP_BUCKET" --expected-bucket-owner "$ACCOUNT_ID" --query 'Contents[].Key' --output text); do
    [[ "$key" == None ]] || aws s3api delete-object --bucket "$APP_BUCKET" --key "$key" --expected-bucket-owner "$ACCOUNT_ID" >/dev/null
  done
  aws s3api delete-bucket --bucket "$APP_BUCKET" --expected-bucket-owner "$ACCOUNT_ID"
fi

log "Cleanup finished. Verify with: scripts/status.sh (should report the ASG missing)"
