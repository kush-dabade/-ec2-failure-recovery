#!/usr/bin/env bash
# Creates the experiment infrastructure (BILLABLE) and deploys the dashboard.
#
#   private S3 bucket (app package) -> read-only IAM role + instance profile ->
#   security groups -> target group -> ALB + listener -> launch template -> ASG (2 instances)
#
# Idempotent: existing resources (found by name) are reused, so a failed run can
# simply be re-run. Requires typing "deploy" unless --yes is passed.
set -euo pipefail
source "$(dirname "$0")/config.sh"

ASSUME_YES=false
[[ "${1:-}" == "--yes" ]] && ASSUME_YES=true

require_aws_session
ACCOUNT_NOW=$(aws sts get-caller-identity --query Account --output text)
[[ "$ACCOUNT_NOW" == "$ACCOUNT_ID" ]] || die "Signed in to account $ACCOUNT_NOW, expected $ACCOUNT_ID"

cat <<EOF

This will create BILLABLE resources in $AWS_REGION (account $ACCOUNT_ID):
  - S3 bucket          $APP_BUCKET (private, app package only)
  - IAM role/profile   $ROLE_NAME / $PROFILE_NAME (read-only describe + read app package)
  - Security groups    $ALB_SG_NAME (80 from $ALLOWED_CIDR), $APP_SG_NAME (8080 from ALB only)
  - Target group       $TG_NAME (HTTP $APP_PORT, /health)
  - Load balancer      $ALB_NAME (internet-facing, PUBLIC endpoint on port 80)
  - Launch template    $LT_NAME ($INSTANCE_TYPE, Amazon Linux 2023, IMDSv2 required)
  - Auto Scaling Group $ASG_NAME (min $ASG_MIN / desired $ASG_DESIRED / max $ASG_MAX)
AWS will also auto-create the service-linked roles AWSServiceRoleForAutoScaling and
AWSServiceRoleForElasticLoadBalancing if they do not exist yet (free; kept after cleanup).
Estimated cost: ~US\$0.069/hour (~US\$1.66/day), charged 24/7 until scripts/cleanup.sh is run.

EOF
if ! $ASSUME_YES; then
  read -r -p 'Type "deploy" to continue: ' answer
  [[ "$answer" == "deploy" ]] || die "Aborted; nothing was created."
fi

TAGS_KV="Key=Project,Value=$PROJECT_TAG"

# ---------------------------------------------------------------- S3 bucket
# --expected-bucket-owner everywhere: a same-named bucket in another account is never
# reused, written to, or read from.
if aws s3api head-bucket --bucket "$APP_BUCKET" --expected-bucket-owner "$ACCOUNT_ID" 2>/dev/null; then
  require_owned "$(aws s3api get-bucket-tagging --bucket "$APP_BUCKET" --expected-bucket-owner "$ACCOUNT_ID" \
    --query "TagSet[?Key=='Project'].Value | [0]" --output text 2>/dev/null || true)" "Bucket $APP_BUCKET"
  log "Bucket $APP_BUCKET exists (owned by this experiment)"
else
  log "Creating private bucket $APP_BUCKET"
  aws s3api create-bucket --bucket "$APP_BUCKET" --object-ownership BucketOwnerEnforced \
    --create-bucket-configuration LocationConstraint="$AWS_REGION" >/dev/null
  aws s3api put-bucket-tagging --bucket "$APP_BUCKET" --expected-bucket-owner "$ACCOUNT_ID" --tagging "TagSet=[{$TAGS_KV}]"
fi
aws s3api put-public-access-block --bucket "$APP_BUCKET" --expected-bucket-owner "$ACCOUNT_ID" \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-bucket-encryption --bucket "$APP_BUCKET" --expected-bucket-owner "$ACCOUNT_ID" \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
aws s3api put-bucket-policy --bucket "$APP_BUCKET" --expected-bucket-owner "$ACCOUNT_ID" --policy "{
  \"Version\": \"2012-10-17\",
  \"Statement\": [{\"Sid\": \"DenyInsecureTransport\", \"Effect\": \"Deny\", \"Principal\": \"*\", \"Action\": \"s3:*\",
    \"Resource\": [\"arn:aws:s3:::$APP_BUCKET\", \"arn:aws:s3:::$APP_BUCKET/*\"],
    \"Condition\": {\"Bool\": {\"aws:SecureTransport\": \"false\"}}}]
}"

# ---------------------------------------------------------------- IAM (new role only)
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  require_owned "$(aws iam list-role-tags --role-name "$ROLE_NAME" --query "Tags[?Key=='Project'].Value | [0]" --output text)" "IAM role $ROLE_NAME"
  log "IAM role $ROLE_NAME exists (owned by this experiment)"
else
  log "Creating read-only IAM role $ROLE_NAME"
  aws iam create-role --role-name "$ROLE_NAME" \
    --assume-role-policy-document "file://$PROJECT_DIR/iam/ec2-trust-policy.json" \
    --description "vm-failure-demo dashboard: read-only experiment state" \
    --tags "$TAGS_KV" >/dev/null
fi
POLICY_DOC="$BUILD_DIR/dashboard-readonly-policy.json"
mkdir -p "$BUILD_DIR"
sed "s/__APP_BUCKET__/$APP_BUCKET/" "$PROJECT_DIR/iam/dashboard-readonly-policy.json" > "$POLICY_DOC"
aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name "$POLICY_NAME" \
  --policy-document "file://$POLICY_DOC"
if ! aws iam get-instance-profile --instance-profile-name "$PROFILE_NAME" >/dev/null 2>&1; then
  log "Creating instance profile $PROFILE_NAME"
  aws iam create-instance-profile --instance-profile-name "$PROFILE_NAME" --tags "$TAGS_KV" >/dev/null
  aws iam add-role-to-instance-profile --instance-profile-name "$PROFILE_NAME" --role-name "$ROLE_NAME"
  log "Waiting for IAM propagation"
  aws iam wait instance-profile-exists --instance-profile-name "$PROFILE_NAME"
  sleep 15
fi

# ---------------------------------------------------------------- security groups
sg_id() {
  aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=$1" \
    --query 'SecurityGroups[0].GroupId' --output text
}
sg_tag() {
  aws ec2 describe-security-groups --group-ids "$1" --query "SecurityGroups[0].Tags[?Key=='Project'].Value | [0]" --output text
}
ALB_SG=$(sg_id "$ALB_SG_NAME")
nonempty "$ALB_SG" && require_owned "$(sg_tag "$ALB_SG")" "Security group $ALB_SG_NAME"
if ! nonempty "$ALB_SG"; then
  log "Creating security group $ALB_SG_NAME"
  ALB_SG=$(aws ec2 create-security-group --vpc-id "$VPC_ID" --group-name "$ALB_SG_NAME" \
    --description "vm-failure-demo ALB: HTTP in" \
    --tag-specifications "ResourceType=security-group,Tags=[{$TAGS_KV},{Key=Name,Value=$ALB_SG_NAME}]" \
    --query GroupId --output text)
  aws ec2 authorize-security-group-ingress --group-id "$ALB_SG" --protocol tcp --port 80 --cidr "$ALLOWED_CIDR" >/dev/null
  ALB_SG_NEW=true
fi
APP_SG=$(sg_id "$APP_SG_NAME")
nonempty "$APP_SG" && require_owned "$(sg_tag "$APP_SG")" "Security group $APP_SG_NAME"
if ! nonempty "$APP_SG"; then
  log "Creating security group $APP_SG_NAME"
  APP_SG=$(aws ec2 create-security-group --vpc-id "$VPC_ID" --group-name "$APP_SG_NAME" \
    --description "vm-failure-demo instances: app port from ALB only, no SSH" \
    --tag-specifications "ResourceType=security-group,Tags=[{$TAGS_KV},{Key=Name,Value=$APP_SG_NAME}]" \
    --query GroupId --output text)
  aws ec2 authorize-security-group-ingress --group-id "$APP_SG" --protocol tcp --port "$APP_PORT" \
    --source-group "$ALB_SG" >/dev/null
  # Instances need outbound HTTPS only (S3, AWS APIs, dnf repos, PyPI).
  aws ec2 revoke-security-group-egress --group-id "$APP_SG" --protocol -1 --cidr 0.0.0.0/0 >/dev/null
  aws ec2 authorize-security-group-egress --group-id "$APP_SG" --protocol tcp --port 443 --cidr 0.0.0.0/0 >/dev/null
fi
if [[ "${ALB_SG_NEW:-false}" == true ]]; then
  # The ALB only needs to reach the instances' app port.
  aws ec2 revoke-security-group-egress --group-id "$ALB_SG" --protocol -1 --cidr 0.0.0.0/0 >/dev/null
  aws ec2 authorize-security-group-egress --group-id "$ALB_SG" \
    --ip-permissions "IpProtocol=tcp,FromPort=$APP_PORT,ToPort=$APP_PORT,UserIdGroupPairs=[{GroupId=$APP_SG}]" >/dev/null
fi
log "Security groups: ALB $ALB_SG, app $APP_SG"

# ---------------------------------------------------------------- target group
TG_ARN=$(aws elbv2 describe-target-groups --names "$TG_NAME" --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || true)
nonempty "$TG_ARN" && require_owned "$(elb_project_tag "$TG_ARN")" "Target group $TG_NAME"
if ! nonempty "$TG_ARN"; then
  log "Creating target group $TG_NAME"
  TG_ARN=$(aws elbv2 create-target-group --name "$TG_NAME" --protocol HTTP --port "$APP_PORT" \
    --vpc-id "$VPC_ID" --target-type instance \
    --health-check-protocol HTTP --health-check-path /health --matcher HttpCode=200 \
    --health-check-interval-seconds 10 --health-check-timeout-seconds 5 \
    --healthy-threshold-count 2 --unhealthy-threshold-count 2 \
    --tags "$TAGS_KV" --query 'TargetGroups[0].TargetGroupArn' --output text)
fi
aws elbv2 modify-target-group-attributes --target-group-arn "$TG_ARN" \
  --attributes Key=deregistration_delay.timeout_seconds,Value=20 >/dev/null

# ---------------------------------------------------------------- load balancer
ALB_ARN=$(aws elbv2 describe-load-balancers --names "$ALB_NAME" --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || true)
nonempty "$ALB_ARN" && require_owned "$(elb_project_tag "$ALB_ARN")" "Load balancer $ALB_NAME"
if ! nonempty "$ALB_ARN"; then
  log "Creating load balancer $ALB_NAME"
  ALB_ARN=$(aws elbv2 create-load-balancer --name "$ALB_NAME" --type application --scheme internet-facing \
    --subnets "$SUBNET_A" "$SUBNET_B" --security-groups "$ALB_SG" --tags "$TAGS_KV" \
    --query 'LoadBalancers[0].LoadBalancerArn' --output text)
fi
ALB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" --query 'LoadBalancers[0].DNSName' --output text)
aws elbv2 modify-load-balancer-attributes --load-balancer-arn "$ALB_ARN" \
  --attributes Key=routing.http.drop_invalid_header_fields.enabled,Value=true >/dev/null
LISTENER=$(aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" --query 'Listeners[?Port==`80`].ListenerArn | [0]' --output text)
if ! nonempty "$LISTENER"; then
  log "Creating HTTP listener"
  aws elbv2 create-listener --load-balancer-arn "$ALB_ARN" --protocol HTTP --port 80 \
    --default-actions "Type=forward,TargetGroupArn=$TG_ARN" --tags "$TAGS_KV" >/dev/null
fi

# ---------------------------------------------------------------- app package + launch template
"$PROJECT_DIR/scripts/build-userdata.sh" "$ALB_DNS"
APP_KEY=$(cat "$BUILD_DIR/app-key.txt")
aws s3api put-object --bucket "$APP_BUCKET" --key "$APP_KEY" --body "$BUILD_DIR/$(basename "$APP_KEY")" \
  --expected-bucket-owner "$ACCOUNT_ID" --server-side-encryption AES256 >/dev/null

AMI_ID=$(aws ssm get-parameter --name "$AMI_PARAM" --query Parameter.Value --output text)
LT_DATA="$BUILD_DIR/launch-template-data.json"
python3 - "$LT_DATA" <<PY
import json, sys
data = {
    "ImageId": "$AMI_ID",
    "InstanceType": "$INSTANCE_TYPE",
    "IamInstanceProfile": {"Name": "$PROFILE_NAME"},
    "SecurityGroupIds": ["$APP_SG"],
    "MetadataOptions": {"HttpTokens": "required", "HttpEndpoint": "enabled", "HttpPutResponseHopLimit": 1},
    "CreditSpecification": {"CpuCredits": "standard"},
    "BlockDeviceMappings": [{"DeviceName": "/dev/xvda", "Ebs": {"VolumeSize": 8, "VolumeType": "gp3", "Encrypted": True, "DeleteOnTermination": True}}],
    "UserData": open("$BUILD_DIR/user-data.b64").read().strip(),
    "TagSpecifications": [
        {"ResourceType": "instance", "Tags": [{"Key": "Name", "Value": "$PREFIX-instance"}, {"Key": "Project", "Value": "$PROJECT_TAG"}]},
        {"ResourceType": "volume", "Tags": [{"Key": "Project", "Value": "$PROJECT_TAG"}]},
    ],
}
json.dump(data, open(sys.argv[1], "w"))
PY

LT_ID=$(aws ec2 describe-launch-templates --launch-template-names "$LT_NAME" --query 'LaunchTemplates[0].LaunchTemplateId' --output text 2>/dev/null || true)
nonempty "$LT_ID" && require_owned "$(aws ec2 describe-launch-templates --launch-template-ids "$LT_ID" \
  --query "LaunchTemplates[0].Tags[?Key=='Project'].Value | [0]" --output text)" "Launch template $LT_NAME"
if ! nonempty "$LT_ID"; then
  log "Creating launch template $LT_NAME"
  LT_ID=$(aws ec2 create-launch-template --launch-template-name "$LT_NAME" \
    --launch-template-data "file://$LT_DATA" \
    --tag-specifications "ResourceType=launch-template,Tags=[{$TAGS_KV}]" \
    --query 'LaunchTemplate.LaunchTemplateId' --output text)
else
  log "Launch template $LT_NAME exists; adding a version for this build"
  VER=$(aws ec2 create-launch-template-version --launch-template-id "$LT_ID" \
    --launch-template-data "file://$LT_DATA" --query 'LaunchTemplateVersion.VersionNumber' --output text)
  aws ec2 modify-launch-template --launch-template-id "$LT_ID" --default-version "$VER" >/dev/null
fi

# ---------------------------------------------------------------- auto scaling group
EXISTING_ASG=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG_NAME" --query 'AutoScalingGroups[0].AutoScalingGroupName' --output text)
nonempty "$EXISTING_ASG" && require_owned "$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG_NAME" \
  --query "AutoScalingGroups[0].Tags[?Key=='Project'].Value | [0]" --output text)" "Auto Scaling Group $ASG_NAME"
if ! nonempty "$EXISTING_ASG"; then
  log "Creating Auto Scaling Group $ASG_NAME"
  aws autoscaling create-auto-scaling-group --auto-scaling-group-name "$ASG_NAME" \
    --launch-template "LaunchTemplateId=$LT_ID,Version=\$Default" \
    --min-size "$ASG_MIN" --desired-capacity "$ASG_DESIRED" --max-size "$ASG_MAX" \
    --vpc-zone-identifier "$SUBNET_A,$SUBNET_B" \
    --target-group-arns "$TG_ARN" \
    --health-check-type ELB --health-check-grace-period 300 \
    --tags "ResourceId=$ASG_NAME,ResourceType=auto-scaling-group,Key=Project,Value=$PROJECT_TAG,PropagateAtLaunch=true"
else
  log "Auto Scaling Group $ASG_NAME exists (use scripts/update-app.sh to roll out new code)"
fi

# ---------------------------------------------------------------- wait for health
cat > "$BUILD_DIR/outputs.env" <<EOF
ALB_DNS=$ALB_DNS
ALB_ARN=$ALB_ARN
TG_ARN=$TG_ARN
LT_ID=$LT_ID
ALB_SG=$ALB_SG
APP_SG=$APP_SG
EOF

log "Waiting for $ASG_DESIRED healthy targets (typically 3-5 minutes)"
for _ in $(seq 1 80); do
  HEALTHY=$(aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
    --query 'length(TargetHealthDescriptions[?TargetHealth.State==`healthy`])' --output text)
  printf '\r  healthy targets: %s/%s ' "$HEALTHY" "$ASG_DESIRED"
  [[ "$HEALTHY" -ge "$ASG_DESIRED" ]] && break
  sleep 10
done
echo
[[ "$HEALTHY" -ge "$ASG_DESIRED" ]] || warn "Targets not healthy yet; check scripts/status.sh"

log "Dashboard: http://$ALB_DNS/"
