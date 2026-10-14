#!/usr/bin/env bash
# Print DroneFeed stack info for copy/paste (Teams / DNS handoff).
#
# Usage:
#   ./stack-info.sh
#   ./stack-info.sh -p spectre
#   ./stack-info.sh -p spectre --write    # also refresh handoff.txt / handoff.env
#   ./stack-info.sh -p spectre --secrets  # include admin email + password from tfvars
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
# shellcheck source=aws_profile.inc.sh
source "$ROOT/aws_profile.inc.sh"

AWS_PROFILE_ARG=""
WRITE=false
SECRETS=false

die() { echo "error: $*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: ./stack-info.sh [options]

  Print network handoff + ops summary from terraform outputs (Teams-friendly).

  -p, --aws-profile NAME  AWS shared profile (same as setup.sh)
  -w, --write             Also write handoff.txt + handoff.env
  -s, --secrets           Include admin email/password from local tfvars
  -h, --help              Show this help

Examples:
  ./stack-info.sh -p spectre
  ./stack-info.sh -p spectre --write
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--aws-profile)
      [[ $# -ge 2 ]] || die "$1 requires a profile name"
      AWS_PROFILE_ARG="$2"
      shift 2
      ;;
    -w|--write) WRITE=true; shift ;;
    -s|--secrets) SECRETS=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

aws_profile_export "$AWS_PROFILE_ARG"
command -v terraform >/dev/null 2>&1 || die "missing terraform"
command -v aws >/dev/null 2>&1 || die "missing aws"

[[ -d "$ROOT/.terraform" ]] || die "Terraform not initialized — run ./setup.sh first"
STATE_COUNT="$(terraform state list 2>/dev/null | wc -l | tr -d ' ')"
[[ "${STATE_COUNT:-0}" -gt 0 ]] || die "empty terraform state — apply a stack first"

tf() {
  local v
  v="$(terraform output -raw "$1" 2>/dev/null || true)"
  [[ "$v" == "null" ]] && v=""
  printf '%s' "$v"
}

aws_profile_require "$AWS_PROFILE_ARG" >/dev/null

public_ip="$(tf public_ip)"
app_url="$(tf app_url)"
instance_id="$(tf instance_id)"
private_ip="$(tf instance_private_ip)"
region="$(tf aws_region)"
name_prefix="$(tf name_prefix)"
deploy_user="$(tf deploy_user)"
admin_email="$(tf admin_email)"
vpc_id="$(tf vpc_id)"
sg_id="$(tf security_group_id)"
subnet_id="$(tf subnet_id)"
maint_url="$(tf maintenance_url)"
maint_domain="$(tf maintenance_cloudfront_domain)"
maint_dist="$(tf maintenance_distribution_id)"
maint_bucket="$(tf maintenance_bucket)"
ops_enabled="$(tf ops_alerts_enabled)"
ops_email="$(tf ops_alert_email)"
ops_topic="$(tf ops_alerts_topic_arn)"
dash_name="$(tf ops_dashboard_name)"
log_prefix="$(tf ops_log_group_prefix)"
sched_tz="$(tf schedule_timezone)"
sched_start="$(tf schedule_start_hour)"
sched_stop="$(tf schedule_stop_hour)"
ssh_hint="$(tf ssh_hint)"

account="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)"
instance_type="$(aws ec2 describe-instances --instance-ids "$instance_id" \
  --query 'Reservations[0].Instances[0].InstanceType' --output text 2>/dev/null || echo "?")"
instance_state="$(aws ec2 describe-instances --instance-ids "$instance_id" \
  --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo "?")"

[[ -z "$app_url" && -n "$public_ip" ]] && app_url="http://${public_ip}"

admin_password=""
if [[ "$SECRETS" == true ]]; then
  if [[ -f "$ROOT/secrets.auto.tfvars" ]]; then
    admin_password="$(awk -F'"' '/^admin_password[[:space:]]*=/{print $2; exit}' "$ROOT/secrets.auto.tfvars" || true)"
  fi
fi

generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

handoff_body() {
  cat <<EOF
DroneFeed host — network handoff
Generated: ${generated_at}

Compute account:     ${account:-unknown}
Region:              ${region:-unknown}
Name prefix:         ${name_prefix:-unknown}
Instance ID:         ${instance_id:-unknown}
Instance type:       ${instance_type} (${instance_state})
Private IP:          ${private_ip:-unknown}
VPC / subnet / SG:   ${vpc_id:-?} / ${subnet_id:-?} / ${sg_id:-?}

--- Live origin ---
Public IPv4:         ${public_ip}
HTTP origin URL:     ${app_url}
HTTP port:           80
TLS on origin today: no (http:// only until a hostname is configured on the box)

--- Media (same IPv4; keep off HTTP-only proxies) ---
Media IPv4:          ${public_ip}
TCP:                 1935 (RTMP), 8554 (RTSP)
UDP:                 8890 (SRT), 8900-8999 (MPEG-TS ingest)

--- Offline page (up when EC2 is stopped) ---
EOF
  if [[ -n "$maint_url" ]]; then
    cat <<EOF
Offline page URL:    ${maint_url}
CloudFront domain:   ${maint_domain}
CloudFront ID:       ${maint_dist}
S3 bucket:           ${maint_bucket}
EOF
  else
    echo "Offline page:        (not provisioned)"
  fi
  cat <<EOF

--- Record targets (hostname chosen by DNS owner) ---
App hostname     →  ${public_ip}   (or edge in front of ${app_url})
Media hostname   →  ${public_ip}   (DNS-only / non-proxied; UDP+TCP media ports)
EOF
  if [[ -n "$maint_url" ]]; then
    echo "When origin down  →  ${maint_url}"
  fi
}

ops_body() {
  cat <<EOF
--- Ops (this account) ---
CloudWatch dashboard: ${dash_name:-n/a}
Log groups:           ${log_prefix:-n/a}/{web,caddy,mediamtx,db,bootstrap,system}
EOF
  if [[ "$ops_enabled" == "true" ]]; then
    cat <<EOF
SNS ops alerts:       enabled → ${ops_email}
SNS topic:            ${ops_topic}
Alerts cover:         schedule miss / on-too-long / budget 80%+100% / disk / swap / OOM
EOF
  else
    echo "SNS ops alerts:       disabled"
  fi
  if [[ -n "$sched_tz" ]]; then
    echo "Weekday schedule:     Mon–Fri ${sched_start}:00→${sched_stop}:00 ${sched_tz}"
  else
    echo "Weekday schedule:     disabled"
  fi
  echo "SSH:                  ${ssh_hint:-ssh ${deploy_user}@${public_ip}}"
}

echo
echo "========================================================"
echo " DroneFeed stack info (copy below into Teams)"
echo "========================================================"
echo
handoff_body
echo
ops_body
echo

if [[ "$SECRETS" == true ]]; then
  echo "--- Operator login (sensitive) ---"
  echo "Admin email:         ${admin_email:-n/a}"
  if [[ -n "$admin_password" ]]; then
    echo "Admin password:      ${admin_password}"
  else
    echo "Admin password:      (not found in secrets.auto.tfvars)"
  fi
  echo "App URL:             ${app_url}"
  echo
fi

echo "========================================================"
echo

if [[ "$WRITE" == true ]]; then
  handoff_txt="$ROOT/handoff.txt"
  handoff_env="$ROOT/handoff.env"
  {
    handoff_body
    echo
    ops_body
  } >"$handoff_txt"

  cat >"$handoff_env" <<EOF
# Generated by stack-info.sh — ${generated_at}
AWS_ACCOUNT_ID=${account}
AWS_REGION=${region}
NAME_PREFIX=${name_prefix}
INSTANCE_ID=${instance_id}
INSTANCE_TYPE=${instance_type}
PUBLIC_IPV4=${public_ip}
ORIGIN_HTTP_URL=${app_url}
ORIGIN_HTTP_PORT=80
ORIGIN_SCHEME=http
MEDIA_IPV4=${public_ip}
MEDIA_TCP_PORTS=1935,8554
MEDIA_UDP_PORTS=8890,8900-8999
OFFLINE_PAGE_URL=${maint_url}
OFFLINE_CLOUDFRONT_DOMAIN=${maint_domain}
OFFLINE_CLOUDFRONT_DISTRIBUTION_ID=${maint_dist}
OFFLINE_S3_BUCKET=${maint_bucket}
OPS_DASHBOARD=${dash_name}
OPS_LOG_PREFIX=${log_prefix}
EOF

  if [[ -n "$maint_url" ]]; then
    GEN_DIR="$(cd "$ROOT/../maintenance" && pwd)/generated"
    mkdir -p "$GEN_DIR"
    cat >"$GEN_DIR/aws.env" <<EOF
# Written by stack-info.sh — ${generated_at}
BUCKET=${maint_bucket}
DIST_ID=${maint_dist}
CLOUDFRONT_DOMAIN=${maint_domain}
MAINTENANCE_URL=${maint_url}
EOF
    echo "Also wrote: $GEN_DIR/aws.env"
  fi

  echo "Wrote: $handoff_txt"
  echo "Wrote: $handoff_env"
  echo
fi
