#!/usr/bin/env bash
# Roll out changed dashboard code: upload a new package, add a launch-template version,
# and start an ASG instance refresh (replaces instances one at a time, >=50% healthy).
# This REPLACES running instances; requires typing "update".
set -euo pipefail
source "$(dirname "$0")/config.sh"
require_aws_session

ALB_DNS=$(aws elbv2 describe-load-balancers --names "$ALB_NAME" --query 'LoadBalancers[0].DNSName' --output text)
"$PROJECT_DIR/scripts/build-userdata.sh" "$ALB_DNS"
read -r -p 'This replaces the running instances one by one. Type "update" to continue: ' a
[[ "$a" == update ]] || die "Aborted."

APP_KEY=$(cat "$BUILD_DIR/app-key.txt")
aws s3api put-object --bucket "$APP_BUCKET" --key "$APP_KEY" --body "$BUILD_DIR/$(basename "$APP_KEY")" \
  --expected-bucket-owner "$ACCOUNT_ID" --server-side-encryption AES256 >/dev/null
LT_ID=$(aws ec2 describe-launch-templates --launch-template-names "$LT_NAME" --query 'LaunchTemplates[0].LaunchTemplateId' --output text)
python3 - "$BUILD_DIR/lt-update.json" "$BUILD_DIR/user-data.b64" <<'PY'
import json, sys
json.dump({"UserData": open(sys.argv[2]).read().strip()}, open(sys.argv[1], "w"))
PY
VER=$(aws ec2 create-launch-template-version --launch-template-id "$LT_ID" --source-version '$Default' \
  --launch-template-data "file://$BUILD_DIR/lt-update.json" --query 'LaunchTemplateVersion.VersionNumber' --output text)
aws ec2 modify-launch-template --launch-template-id "$LT_ID" --default-version "$VER" >/dev/null
aws autoscaling start-instance-refresh --auto-scaling-group-name "$ASG_NAME" \
  --preferences '{"MinHealthyPercentage":50,"InstanceWarmup":120}' --query InstanceRefreshId --output text
log "Launch template version $VER is default; instance refresh started (about 10 minutes)."
