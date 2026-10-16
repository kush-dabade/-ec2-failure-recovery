#!/usr/bin/env bash
# shellcheck disable=SC2034  # variables are consumed by the scripts that source this file
# Shared configuration for the EC2 failure-recovery experiment.
# Every script sources this file; resource names below form the allowlist the
# failure script enforces. Override any value with an environment variable.

export AWS_REGION="${AWS_REGION:-ap-south-1}"
export AWS_PAGER=""

PROJECT_TAG="${PROJECT_TAG:-vm-failure-demo}"
PREFIX="${PREFIX:-vmfail}"

# Network: the account's default VPC, two public subnets in different AZs.
VPC_ID="${VPC_ID:-vpc-0bbf56888f5140e56}"
SUBNET_A="${SUBNET_A:-subnet-0e785dde39bd48372}"   # ap-south-1a
SUBNET_B="${SUBNET_B:-subnet-0dc42e44ded524d9d}"   # ap-south-1b

# Who may open the dashboard (ALB port 80). Read-only page; narrow if you like,
# e.g. ALLOWED_CIDR=203.0.113.7/32
ALLOWED_CIDR="${ALLOWED_CIDR:-0.0.0.0/0}"

INSTANCE_TYPE="${INSTANCE_TYPE:-t3.micro}"
AMI_PARAM="/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
APP_PORT=8080

# Resource names (the experiment allowlist).
ALB_NAME="${PREFIX}-alb"
TG_NAME="${PREFIX}-tg"
LT_NAME="${PREFIX}-lt"
ASG_NAME="${PREFIX}-asg"
ALB_SG_NAME="${PREFIX}-alb-sg"
APP_SG_NAME="${PREFIX}-app-sg"
ROLE_NAME="${PREFIX}-dashboard-readonly-role"
PROFILE_NAME="${PREFIX}-dashboard-readonly-profile"
POLICY_NAME="${PREFIX}-dashboard-readonly"

ASG_MIN=2
ASG_DESIRED=2
ASG_MAX=3

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '\033[1;33m[%s] WARN:\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die()  { printf '\033[1;31m[%s] ERROR:\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

# Treat AWS CLI "None" / empty output as missing.
nonempty() { [[ -n "$1" && "$1" != "None" ]]; }

require_aws_session() {
  aws sts get-caller-identity --query Account --output text >/dev/null 2>&1 \
    || die "AWS credentials missing or expired. Run: aws login"
}

# Private bucket holding the versioned app tarball (instances download it at boot).
ACCOUNT_ID="${ACCOUNT_ID:-851226124537}"
APP_BUCKET="${APP_BUCKET:-${PREFIX}-app-${ACCOUNT_ID}-${AWS_REGION}}"

# Ownership guard: an existing resource with an experiment name is reused, modified
# or deleted only if it carries Project=$PROJECT_TAG.
require_owned() {
  [[ "$1" == "$PROJECT_TAG" ]] || die "$2 exists but is not tagged Project=$PROJECT_TAG (found: '$1'); refusing to touch it."
}
elb_project_tag() {
  aws elbv2 describe-tags --resource-arns "$1" --query "TagDescriptions[0].Tags[?Key=='Project'].Value | [0]" --output text
}
