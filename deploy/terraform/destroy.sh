#!/usr/bin/env bash
# Tear down the Terraform stack in this directory (EC2, VPC, EIP, schedules,
# maintenance S3 + CloudFront, IAM pieces created by apply).
#
# Usage:
#   ./destroy.sh
#   ./destroy.sh -p spectre
#   ./destroy.sh -p spectre -y
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
# shellcheck source=aws_profile.inc.sh
source "$ROOT/aws_profile.inc.sh"

YES=false
AWS_PROFILE_ARG=""

die() { echo "error: $*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: ./destroy.sh [options]

  -p, --aws-profile NAME  AWS shared profile (same as setup.sh / wake.sh)
  -y, --yes               Pass -auto-approve to terraform destroy (no prompt)
  -h, --help              Show this help

What this removes (everything in local terraform state):
  - EC2 instance, ENI, Elastic IP, security group, subnet, VPC, IGW
  - Weekday EventBridge Scheduler start/stop (+ wake one-shots if present)
  - IAM roles/profiles created for the instance / scheduler / optional SES
  - Offline-page S3 bucket + CloudFront distribution (if enabled at apply)

What this does NOT remove:
  - Manual DNS / UI CloudFront / Lambda@Edge / ACM in another account
  - Local files: terraform.tfvars, secrets.auto.tfvars, handoff.*, keys/

Examples:
  ./destroy.sh -p spectre
  ./destroy.sh -p spectre -y
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes) YES=true; shift ;;
    -p|--aws-profile)
      [[ $# -ge 2 ]] || die "$1 requires a profile name"
      AWS_PROFILE_ARG="$2"
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

aws_profile_export "$AWS_PROFILE_ARG"
command -v terraform >/dev/null 2>&1 || die "missing terraform"
command -v aws >/dev/null 2>&1 || die "missing aws"

echo
echo "DroneFeed — terraform destroy"
echo "--------------------------------------------------------"
aws_profile_require "$AWS_PROFILE_ARG"

if [[ ! -d "$ROOT/.terraform" ]]; then
  die "Terraform not initialized here — run ./setup.sh first (or terraform init)"
fi

STATE_COUNT="$(terraform state list 2>/dev/null | wc -l | tr -d ' ')"
if [[ "${STATE_COUNT:-0}" -eq 0 ]]; then
  echo
  echo "  State dir:     $ROOT"
  echo "  Resources:     0"
  echo
  echo "Nothing to destroy (empty state). If resources still exist in AWS, they"
  echo "were created outside this state or the state file was lost."
  exit 0
fi

NAME_PREFIX="$(terraform output -raw name_prefix 2>/dev/null || true)"
PUBLIC_IP="$(terraform output -raw public_ip 2>/dev/null || true)"
INSTANCE_ID="$(terraform output -raw instance_id 2>/dev/null || true)"
echo
echo "  State dir:     $ROOT"
echo "  Resources:     $STATE_COUNT"
[[ -n "$NAME_PREFIX" && "$NAME_PREFIX" != "null" ]] && echo "  name_prefix:   $NAME_PREFIX"
[[ -n "$INSTANCE_ID" && "$INSTANCE_ID" != "null" ]] && echo "  instance_id:   $INSTANCE_ID"
[[ -n "$PUBLIC_IP" && "$PUBLIC_IP" != "null" ]] && echo "  public_ip:     $PUBLIC_IP"
echo
echo "This permanently deletes the stack resources listed in --help."
echo

if [[ "$YES" == true ]]; then
  echo "Running: terraform destroy -auto-approve"
  echo
  terraform destroy -auto-approve
else
  echo "Running: terraform destroy"
  echo "(Terraform will ask you to type yes)"
  echo
  terraform destroy
fi

echo
echo "Destroy finished."
echo "Local tfvars / secrets / handoff / keys were left in place (gitignored)."
echo "If you created DNS or edge resources outside this state, remove those separately."
echo
