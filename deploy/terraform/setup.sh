#!/usr/bin/env bash
# Interactive DroneFeed AWS spin-up helper.
# Writes terraform.tfvars + secrets.auto.tfvars, provisions SSH key, then optional apply.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

TFVARS="$ROOT/terraform.tfvars"
SECRETS_TFVARS="$ROOT/secrets.auto.tfvars"
KEYS_DIR="$ROOT/keys"
GENERATED_KEY="$KEYS_DIR/dronefeed_ed25519"
SSH_PRIVATE_KEY_PATH=""

die() { echo "error: $*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing '$1' — install it and re-run"
}

prompt() {
  local q="$1" def="${2-}" ans
  if [[ -n "$def" ]]; then
    read -r -p "$q [$def]: " ans || true
    echo "${ans:-$def}"
  else
    read -r -p "$q: " ans || true
    echo "$ans"
  fi
}

prompt_yn() {
  local q="$1" def="${2:-y}" ans
  local other=n
  [[ "$def" == n ]] && other=y
  read -r -p "$q [$def/$other]: " ans || true
  ans="$(echo "${ans:-$def}" | tr '[:upper:]' '[:lower:]')"
  [[ "$ans" == y || "$ans" == yes ]]
}

prompt_secret() {
  local q="$1" ans
  read -r -s -p "$q: " ans || true
  echo >&2
  echo "$ans"
}

hcl_str() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  printf '"%s"' "$s"
}

hcl_list() {
  local out="[" first=1 item
  for item in "$@"; do
    [[ -z "$item" ]] && continue
    if [[ $first -eq 1 ]]; then first=0; else out+=", "; fi
    out+=$(hcl_str "$item")
  done
  out+="]"
  printf '%s' "$out"
}

slugify() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]+/-/g; s/^-+//; s/-+$//; s/-+/-/g'
}

gen_admin_password() {
  # ≥8 chars, digit + symbol (app password rules)
  local base sym
  base="$(openssl rand -base64 12 | tr -d '\n=/+' | cut -c1-10)"
  sym='!'
  echo "${base}1${sym}"
}

echo
echo "DroneFeed — Terraform spin-up wizard"
echo "===================================="
echo "IP-first stack (HTTP on Elastic IP). DNS/HTTPS later in another account if needed."
echo "Writes $TFVARS (gitignored) and can run terraform for you."
echo

need_cmd terraform
need_cmd openssl

if command -v aws >/dev/null 2>&1; then
  if aws sts get-caller-identity >/dev/null 2>&1; then
    echo "AWS identity: $(aws sts get-caller-identity --query Arn --output text 2>/dev/null)"
  else
    echo "warning: aws sts get-caller-identity failed — check credentials before apply."
  fi
else
  echo "note: aws CLI not found — OK if credentials are configured for Terraform."
fi
echo

echo "── Project identity (tags on all resources) ──"
PROJECT="$(prompt "Project tag" "dronefeed")"
ENVIRONMENT="$(prompt "Environment tag" "prod")"
OWNER="$(prompt "Owner tag (team or email, blank to skip)" "")"
COST_CENTER="$(prompt "CostCenter tag (blank to skip)" "")"

declare -a EXTRA_KEYS=()
declare -a EXTRA_VALS=()
echo
echo "Add more custom tags (key, then value). Blank key when done."
while true; do
  k="$(prompt "  Extra tag key (blank to finish)" "")"
  [[ -z "$k" ]] && break
  if [[ "$k" == "ManagedBy" ]]; then
    echo "  skipping ManagedBy (reserved)"
    continue
  fi
  v="$(prompt "  Value for $k" "")"
  EXTRA_KEYS+=("$k")
  EXTRA_VALS+=("$v")
done

NAME_PREFIX="$(slugify "$(prompt "Resource name_prefix" "$PROJECT")")"
[[ -n "$NAME_PREFIX" ]] || NAME_PREFIX="dronefeed"

echo
echo "── AWS / instance ──"
AWS_REGION="$(prompt "AWS region" "us-east-1")"
INSTANCE_TYPE="$(prompt "Instance type (c7i.4xlarge+ if >4 public feeds)" "c7i.2xlarge")"
ROOT_GB="$(prompt "Root volume GiB" "80")"
AZ="$(prompt "Availability zone (blank = first in region)" "")"

echo
echo "── SSH access (dronefeed user) ──"
PUBLIC_KEY=""
KEY_NAME=""
ENABLE_SSM="true"

DEFAULT_PUB=""
for cand in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub"; do
  if [[ -f "$cand" ]]; then DEFAULT_PUB="$cand"; break; fi
done

if [[ -n "$DEFAULT_PUB" ]] && prompt_yn "Use public key from $DEFAULT_PUB for dronefeed SSH?" y; then
  PUBLIC_KEY="$(tr -d '\n' <"$DEFAULT_PUB")"
  SSH_PRIVATE_KEY_PATH="${DEFAULT_PUB%.pub}"
elif prompt_yn "Generate a new ed25519 key under deploy/terraform/keys/?" y; then
  mkdir -p "$KEYS_DIR"
  if [[ ! -f "$GENERATED_KEY" ]]; then
    ssh-keygen -t ed25519 -N "" -f "$GENERATED_KEY" -C "dronefeed-${NAME_PREFIX}" >/dev/null
    chmod 600 "$GENERATED_KEY"
  fi
  PUBLIC_KEY="$(tr -d '\n' <"${GENERATED_KEY}.pub")"
  SSH_PRIVATE_KEY_PATH="$GENERATED_KEY"
  echo "  Generated $GENERATED_KEY (gitignored)"
else
  PUBLIC_KEY="$(prompt "Paste SSH public key line" "")"
  SSH_PRIVATE_KEY_PATH="$(prompt "Path to matching private key (for the summary SSH command)" "")"
fi
[[ -n "$PUBLIC_KEY" ]] || die "SSH public key is required so you can log in as dronefeed"

if prompt_yn "Also enable SSM Session Manager (backup access)?" y; then
  ENABLE_SSM="true"
else
  ENABLE_SSM="false"
fi

SSH_CIDR="$(prompt "SSH allow CIDR (port 22)" "0.0.0.0/0")"
MEDIA_CIDR="$(prompt "Media/UI allow CIDR (80/443/RTMP/…)" "0.0.0.0/0")"

echo
echo "── Admin login (printed after apply) ──"
ADMIN_EMAIL="$(prompt "Admin email" "admin@dronefeed.local")"
DEFAULT_ADMIN_PW="$(gen_admin_password)"
echo "Generated admin password: $DEFAULT_ADMIN_PW"
if prompt_yn "Use this generated password?" y; then
  ADMIN_PASSWORD="$DEFAULT_ADMIN_PW"
else
  ADMIN_PASSWORD="$(prompt_secret "Admin password (≥8 chars, include a digit and a symbol)")"
fi
[[ -n "$ADMIN_PASSWORD" ]] || die "admin password required"
if [[ ${#ADMIN_PASSWORD} -lt 8 ]]; then
  die "admin password must be at least 8 characters"
fi

echo
echo "── Repo bootstrap on the instance ──"
GIT_REPO="$(prompt "Git clone URL" "https://github.com/tfeuerbach/dronefeed.git")"
GIT_REF="$(prompt "Git branch or tag (must include Caddyfile.http + runtime PHX_SCHEME/force_ssl)" "master")"
DEPLOY_USER="$(prompt "Linux deploy user" "dronefeed")"

echo
echo "── Email / SES (optional) ──"
ENABLE_SES="false"
prompt_yn "Attach SES send policy / plan to use outbound email later?" n && ENABLE_SES="true"

ASSOCIATE_EIP="true"
prompt_yn "Allocate Elastic IP (recommended for IP-first)?" y || ASSOCIATE_EIP="false"

echo
echo "── After-hours offline page (S3 + CloudFront) ──"
ENABLE_MAINTENANCE="true"
MAINT_CREATE="true"
MAINT_BUCKET=""
MAINT_SAME_ACCOUNT="true"
MAINT_BUCKET_REGION=""
MAINT_ACCESS_KEY=""
MAINT_SECRET_KEY=""
MAINT_SESSION_TOKEN=""

if prompt_yn "Set up the offline/maintenance page (S3 + CloudFront)?" y; then
  ENABLE_MAINTENANCE="true"
  echo
  echo "  Offline HTML lives in S3; CloudFront (this account) serves it."
  if prompt_yn "Create a new S3 bucket for the offline page?" y; then
    MAINT_CREATE="true"
    MAINT_BUCKET="$(prompt "New bucket name (blank = ${NAME_PREFIX}-after-hours-<account_id>)" "")"
  else
    MAINT_CREATE="false"
    MAINT_BUCKET="$(prompt "Existing S3 bucket name" "")"
    [[ -n "$MAINT_BUCKET" ]] || die "existing bucket name is required"
    echo "  Note: Terraform will set this bucket's policy for CloudFront OAC (replaces bucket policy)."
  fi

  if prompt_yn "Is that bucket in the same AWS account as this EC2 stack?" y; then
    MAINT_SAME_ACCOUNT="true"
    MAINT_BUCKET_REGION="$(prompt "Bucket region (blank = same as EC2 region $AWS_REGION)" "")"
  else
    MAINT_SAME_ACCOUNT="false"
    echo "  Cross-account: credentials that can read/write the bucket and put bucket policy."
    MAINT_BUCKET_REGION="$(prompt "Bucket AWS region" "$AWS_REGION")"
    [[ -n "$MAINT_BUCKET_REGION" ]] || die "bucket region is required for cross-account"
    MAINT_ACCESS_KEY="$(prompt "Bucket account AWS access key ID" "")"
    [[ -n "$MAINT_ACCESS_KEY" ]] || die "access key required for cross-account bucket"
    MAINT_SECRET_KEY="$(prompt_secret "Bucket account AWS secret access key")"
    [[ -n "$MAINT_SECRET_KEY" ]] || die "secret key required for cross-account bucket"
    MAINT_SESSION_TOKEN="$(prompt_secret "Session token (blank if none)")"
  fi
else
  ENABLE_MAINTENANCE="false"
fi

echo
echo "── Business hours (auto start/stop) ──"
ENABLE_SCHEDULE="true"
SCHEDULE_TZ="America/New_York"
SCHEDULE_START=8
SCHEDULE_STOP=18
if prompt_yn "Auto start/stop EC2 on weekdays (default 8:00–18:00 local)?" y; then
  ENABLE_SCHEDULE="true"
  SCHEDULE_TZ="$(prompt "Timezone (IANA)" "America/New_York")"
  SCHEDULE_START="$(prompt "Start hour Mon–Fri (0–23, local)" "8")"
  SCHEDULE_STOP="$(prompt "Stop hour Mon–Fri (0–23, local)" "18")"
else
  ENABLE_SCHEDULE="false"
fi

if [[ -f "$TFVARS" ]]; then
  BACKUP="$TFVARS.bak.$(date +%Y%m%d%H%M%S)"
  cp "$TFVARS" "$BACKUP"
  echo
  echo "Backed up existing tfvars → $BACKUP"
fi

{
  echo "# Generated by setup.sh — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "# Do not commit this file."
  echo
  echo "aws_region     = $(hcl_str "$AWS_REGION")"
  echo "name_prefix    = $(hcl_str "$NAME_PREFIX")"
  echo "instance_type  = $(hcl_str "$INSTANCE_TYPE")"
  echo "root_volume_gb = $ROOT_GB"
  if [[ -n "$AZ" ]]; then
    echo "availability_zone = $(hcl_str "$AZ")"
  fi
  echo
  echo "ssh_ingress_cidrs   = $(hcl_list "$SSH_CIDR")"
  echo "media_ingress_cidrs = $(hcl_list "$MEDIA_CIDR")"
  echo
  echo "public_key         = $(hcl_str "$PUBLIC_KEY")"
  echo "ssh_authorized_key = $(hcl_str "$PUBLIC_KEY")"
  if [[ -n "$KEY_NAME" ]]; then
    echo "key_name = $(hcl_str "$KEY_NAME")"
  fi
  echo
  echo "git_repo_url = $(hcl_str "$GIT_REPO")"
  echo "git_ref      = $(hcl_str "$GIT_REF")"
  echo "deploy_user  = $(hcl_str "$DEPLOY_USER")"
  echo
  echo "admin_email = $(hcl_str "$ADMIN_EMAIL")"
  echo
  echo "enable_ssm                 = $ENABLE_SSM"
  echo "enable_ses_send            = $ENABLE_SES"
  echo "associate_elastic_ip       = $ASSOCIATE_EIP"
  echo "enable_maintenance_static  = $ENABLE_MAINTENANCE"
  echo "maintenance_create_bucket  = $MAINT_CREATE"
  echo "maintenance_bucket_same_account = $MAINT_SAME_ACCOUNT"
  if [[ -n "$MAINT_BUCKET" ]]; then
    echo "maintenance_bucket_name = $(hcl_str "$MAINT_BUCKET")"
  fi
  if [[ -n "$MAINT_BUCKET_REGION" ]]; then
    echo "maintenance_bucket_region = $(hcl_str "$MAINT_BUCKET_REGION")"
  fi
  echo
  echo "enable_business_hours_schedule = $ENABLE_SCHEDULE"
  echo "schedule_timezone              = $(hcl_str "$SCHEDULE_TZ")"
  echo "schedule_start_hour            = $SCHEDULE_START"
  echo "schedule_stop_hour             = $SCHEDULE_STOP"
  echo
  echo "tags = {"
  echo "  Project     = $(hcl_str "$PROJECT")"
  echo "  Environment = $(hcl_str "$ENVIRONMENT")"
  if [[ -n "$OWNER" ]]; then
    echo "  Owner       = $(hcl_str "$OWNER")"
  fi
  if [[ -n "$COST_CENTER" ]]; then
    echo "  CostCenter  = $(hcl_str "$COST_CENTER")"
  fi
  idx=0
  while [[ $idx -lt ${#EXTRA_KEYS[@]} ]]; do
    k="${EXTRA_KEYS[$idx]}"
    v="${EXTRA_VALS[$idx]}"
    idx=$((idx + 1))
    case "$k" in
      Project|Environment|Owner|CostCenter|ManagedBy) continue ;;
    esac
    if [[ "$k" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      printf '  %s = %s\n' "$k" "$(hcl_str "$v")"
    else
      printf '  %s = %s\n' "$(hcl_str "$k")" "$(hcl_str "$v")"
    fi
  done
  echo "}"
} >"$TFVARS"

{
  echo "# Generated by setup.sh — secrets (gitignored via *.auto.tfvars)"
  echo "admin_password = $(hcl_str "$ADMIN_PASSWORD")"
  if [[ "$ENABLE_MAINTENANCE" == true && "$MAINT_SAME_ACCOUNT" == false ]]; then
    echo "maintenance_bucket_access_key    = $(hcl_str "$MAINT_ACCESS_KEY")"
    echo "maintenance_bucket_secret_key    = $(hcl_str "$MAINT_SECRET_KEY")"
    if [[ -n "$MAINT_SESSION_TOKEN" ]]; then
      echo "maintenance_bucket_session_token = $(hcl_str "$MAINT_SESSION_TOKEN")"
    fi
  fi
} >"$SECRETS_TFVARS"
chmod 600 "$SECRETS_TFVARS"

echo
echo "Wrote $TFVARS"
echo "Wrote $SECRETS_TFVARS (secrets; gitignored)"
echo
echo "── Summary ──"
echo "  Project=$PROJECT  Environment=$ENVIRONMENT  name_prefix=$NAME_PREFIX"
echo "  region=$AWS_REGION  instance=$INSTANCE_TYPE"
echo "  admin_email=$ADMIN_EMAIL"
echo "  SES/email: $ENABLE_SES"
if [[ "$ENABLE_SCHEDULE" == true ]]; then
  echo "  schedule: Mon–Fri ${SCHEDULE_START}:00→${SCHEDULE_STOP}:00 $SCHEDULE_TZ"
else
  echo "  schedule: disabled"
fi
if [[ "$ENABLE_MAINTENANCE" == true ]]; then
  if [[ "$MAINT_CREATE" == true ]]; then
    echo "  after-hours: create bucket ${MAINT_BUCKET:-auto-name} + CloudFront"
  else
    echo "  after-hours: existing bucket $MAINT_BUCKET + CloudFront"
  fi
else
  echo "  after-hours: disabled"
fi
echo

if ! prompt_yn "Run terraform init?" y; then
  echo "Stopped before terraform. Review $TFVARS then run:"
  echo "  cd $ROOT && terraform init && terraform plan && terraform apply"
  exit 0
fi

terraform init

if prompt_yn "Run terraform plan?" y; then
  terraform plan -out=tfplan
fi

if prompt_yn "Run terraform apply now?" n; then
  if [[ -f tfplan ]]; then
    terraform apply tfplan
  else
    terraform apply
  fi
  echo
  echo "── Outputs ──"
  terraform output
  echo
  APP_URL="$(terraform output -raw app_url 2>/dev/null || true)"
  PUBLIC_IP="$(terraform output -raw public_ip 2>/dev/null || true)"
  echo "════════════════════════════════════════"
  echo "  App URL:   ${APP_URL:-http://$PUBLIC_IP}"
  echo "  Public IP: $PUBLIC_IP"
  echo "  Admin:     $ADMIN_EMAIL"
  echo "  Password:  $ADMIN_PASSWORD"
  if [[ -n "$SSH_PRIVATE_KEY_PATH" ]]; then
    echo "  SSH:       ssh -i $SSH_PRIVATE_KEY_PATH $DEPLOY_USER@$PUBLIC_IP"
  else
    echo "  SSH:       ssh -i <private-key> $DEPLOY_USER@$PUBLIC_IP"
  fi
  echo "════════════════════════════════════════"
  echo "Wait a few minutes for the first Docker build, then open the App URL."
  echo "After-hours test window: ./wake.sh 4|8|12|24"
  echo

  MAINT_URL="$(terraform output -raw maintenance_url 2>/dev/null || true)"
  if [[ -n "$MAINT_URL" && "$MAINT_URL" != "null" ]]; then
    GEN_DIR="$(cd "$ROOT/../maintenance" && pwd)/generated"
    mkdir -p "$GEN_DIR"
    cat >"$GEN_DIR/aws.env" <<EOF
# Written by setup.sh from terraform outputs — $(date -u +%Y-%m-%dT%H:%M:%SZ)
BUCKET=$(terraform output -raw maintenance_bucket)
DIST_ID=$(terraform output -raw maintenance_distribution_id)
CLOUDFRONT_DOMAIN=$(terraform output -raw maintenance_cloudfront_domain)
MAINTENANCE_URL=$MAINT_URL
EOF
    echo "Offline page: $MAINT_URL"
    echo "Wrote $GEN_DIR/aws.env for deploy/maintenance/sync.sh"
    echo "Hostname failover (Cloudflare / Route 53): see README Path 1 / Path 2"
  fi
else
  echo
  echo "Skipped apply. When ready:"
  echo "  cd $ROOT && terraform apply"
  if [[ -f tfplan ]]; then
    echo "  # or: terraform apply tfplan"
  fi
  echo
  echo "Admin (saved in secrets.auto.tfvars): $ADMIN_EMAIL / (see secrets file)"
fi
