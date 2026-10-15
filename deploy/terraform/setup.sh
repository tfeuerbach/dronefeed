#!/usr/bin/env bash
# Interactive DroneFeed AWS spin-up wizard (TUI).
# Writes terraform.tfvars + secrets.auto.tfvars, provisions SSH key, then optional apply.
#
#   ./setup.sh                           # guided or smoke (menu)
#   ./setup.sh --smoke / -s              # minimum-spec Terraform smoke test
#   ./setup.sh -s -p spectre -y          # smoke + profile + skip init/plan/apply prompts
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
# shellcheck source=aws_profile.inc.sh
source "$ROOT/aws_profile.inc.sh"

TFVARS="$ROOT/terraform.tfvars"
SECRETS_TFVARS="$ROOT/secrets.auto.tfvars"
KEYS_DIR="$ROOT/keys"
GENERATED_KEY="$KEYS_DIR/dronefeed_ed25519"
SSH_PRIVATE_KEY_PATH=""
SMOKE=false
YES=false
AWS_PROFILE_ARG=""

# Filled by refresh_ec2_catalog (live AWS) or load_fallback_catalog.
declare -A EC2_USD_HR=()
declare -A EC2_VCPU=()
declare -A EC2_RAM_GB=()
declare -a EC2_TYPES=()
GP3_USD_GB_MO=0.08
PRICES_SOURCE="unset"
HOURS_PER_MONTH_FULL=730
WEEKDAYS_PER_MONTH=21.7

die() { echo "error: $*" >&2; exit 1; }
warn() { echo "  warning: $*" >&2; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing $1 - install it and re-run"
}

usage() {
  cat <<'EOF'
Usage: ./setup.sh [options]

  (no flags)              Menu: guided setup or smoke test
  -s, --smoke             Minimum instance (c7i.large, 40 GiB). Terraform check
                          only — not for video. name_prefix=dronefeed-smoke
  -y, --yes               Skip the "Run terraform init/plan/apply?" prompts
                          (answer yes to all three)
  -p, --aws-profile NAME  AWS shared profile (~/.aws/credentials or config);
                          exported as AWS_PROFILE for aws + Terraform
  -h, --help              Show this help

Examples:
  ./setup.sh -s -p spectre
  ./setup.sh -s -p spectre -y
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -s|--smoke)
      SMOKE=true
      shift
      ;;
    -y|--yes)
      YES=true
      shift
      ;;
    -p|--aws-profile)
      [[ $# -ge 2 ]] || die "$1 requires a profile name"
      AWS_PROFILE_ARG="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1 (try --help)"
      ;;
  esac
done

aws_profile_export "$AWS_PROFILE_ARG"

load_fallback_catalog() {
  EC2_USD_HR=(
    [c7i.large]=0.0892
    [c7i.xlarge]=0.1785
    [c7i.2xlarge]=0.3570
    [c7i.4xlarge]=0.7140
    [c7i.8xlarge]=1.4280
    [c7i.12xlarge]=2.1420
    [c7i.16xlarge]=2.8560
    [c7i.24xlarge]=4.2840
    [c7i.48xlarge]=8.5680
  )
  EC2_VCPU=(
    [c7i.large]=2 [c7i.xlarge]=4 [c7i.2xlarge]=8 [c7i.4xlarge]=16 [c7i.8xlarge]=32
    [c7i.12xlarge]=48 [c7i.16xlarge]=64 [c7i.24xlarge]=96 [c7i.48xlarge]=192
  )
  EC2_RAM_GB=(
    [c7i.large]=4 [c7i.xlarge]=8 [c7i.2xlarge]=16 [c7i.4xlarge]=32 [c7i.8xlarge]=64
    [c7i.12xlarge]=96 [c7i.16xlarge]=128 [c7i.24xlarge]=192 [c7i.48xlarge]=384
  )
  EC2_TYPES=(
    c7i.large c7i.xlarge c7i.2xlarge c7i.4xlarge c7i.8xlarge
    c7i.12xlarge c7i.16xlarge c7i.24xlarge c7i.48xlarge
  )
  GP3_USD_GB_MO=0.08
  PRICES_SOURCE="fallback (static us-east-1 ballpark)"
}

# Populate EC2_TYPES / prices for region via EC2 + Pricing APIs. Falls back on failure.
refresh_ec2_catalog() {
  local region="${1:-us-east-1}"
  EC2_USD_HR=()
  EC2_VCPU=()
  EC2_RAM_GB=()
  EC2_TYPES=()

  if ! command -v aws >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
    load_fallback_catalog
    info "Catalog: $PRICES_SOURCE (need aws + python3 for live prices)"
    return
  fi
  if ! aws sts get-caller-identity >/dev/null 2>&1; then
    load_fallback_catalog
    info "Catalog: $PRICES_SOURCE (AWS creds not working)"
    return
  fi

  info "Fetching c7i instance types in $region..."
  local types_json
  if ! types_json="$(aws ec2 describe-instance-types --region "$region" \
    --filters "Name=instance-type,Values=c7i.*" \
    --query 'InstanceTypes[?!contains(InstanceType, `metal`)].{t:InstanceType,v:VCpuInfo.DefaultVCpus,m:MemoryInfo.SizeInMiB}' \
    --output json 2>/dev/null)"; then
    load_fallback_catalog
    info "Catalog: $PRICES_SOURCE (describe-instance-types failed)"
    return
  fi

  # Sort by vCPU and load vcpu/ram maps.
  local sorted
  sorted="$(
    export TYPE_JSON="$types_json"
    python3 - <<'PY'
import json, os
rows = json.loads(os.environ.get("TYPE_JSON") or "[]")
rows = [r for r in rows if r.get("t") and "metal" not in str(r["t"])]
rows.sort(key=lambda r: (int(r.get("v") or 0), str(r["t"])))
for r in rows:
    t, v, m = r["t"], int(r["v"]), int(r["m"]) // 1024
    print(f"{t}\t{v}\t{m}")
PY
  )" || true

  if [[ -z "$sorted" ]]; then
    load_fallback_catalog
    info "Catalog: $PRICES_SOURCE (no c7i types in $region)"
    return
  fi

  local line t v m
  while IFS=$'\t' read -r t v m; do
    [[ -z "$t" ]] && continue
    EC2_TYPES+=("$t")
    EC2_VCPU[$t]="$v"
    EC2_RAM_GB[$t]="$m"
  done <<<"$sorted"

  info "Fetching on-demand Linux prices for ${#EC2_TYPES[@]} types (Pricing API)..."
  local prices_out=""
  prices_out="$(
    export REGION_CODE="$region"
    export TYPES="$(printf '%s\n' "${EC2_TYPES[@]}")"
    python3 - <<'PY'
import json, os, subprocess, sys

region = os.environ["REGION_CODE"]
types = [t for t in os.environ.get("TYPES", "").splitlines() if t]
out = {}

def price_for(instance_type: str):
    cmd = [
        "aws", "pricing", "get-products",
        "--region", "us-east-1",
        "--service-code", "AmazonEC2",
        "--filters",
        f"Type=TERM_MATCH,Field=instanceType,Value={instance_type}",
        f"Type=TERM_MATCH,Field=regionCode,Value={region}",
        "Type=TERM_MATCH,Field=operatingSystem,Value=Linux",
        "Type=TERM_MATCH,Field=tenancy,Value=Shared",
        "Type=TERM_MATCH,Field=preInstalledSw,Value=NA",
        "Type=TERM_MATCH,Field=capacitystatus,Value=Used",
        "--output", "json",
    ]
    raw = subprocess.check_output(cmd, stderr=subprocess.DEVNULL)
    data = json.loads(raw)
    for item in data.get("PriceList") or []:
        p = json.loads(item)
        attrs = p.get("product", {}).get("attributes", {})
        if attrs.get("operation") not in (None, "", "RunInstances"):
            continue
        for term in p.get("terms", {}).get("OnDemand", {}).values():
            for dim in term.get("priceDimensions", {}).values():
                if dim.get("unit") == "Hrs":
                    usd = dim.get("pricePerUnit", {}).get("USD")
                    if usd is not None:
                        return f"{float(usd):.4f}"
    return None

for t in types:
    try:
        p = price_for(t)
    except Exception:
        p = None
    if p is not None:
        out[t] = p

# gp3 storage
gp3 = None
try:
    cmd = [
        "aws", "pricing", "get-products",
        "--region", "us-east-1",
        "--service-code", "AmazonEC2",
        "--filters",
        "Type=TERM_MATCH,Field=productFamily,Value=Storage",
        "Type=TERM_MATCH,Field=volumeApiName,Value=gp3",
        f"Type=TERM_MATCH,Field=regionCode,Value={region}",
        "--output", "json",
    ]
    data = json.loads(subprocess.check_output(cmd, stderr=subprocess.DEVNULL))
    for item in data.get("PriceList") or []:
        p = json.loads(item)
        for term in p.get("terms", {}).get("OnDemand", {}).values():
            for dim in term.get("priceDimensions", {}).values():
                if dim.get("unit") == "GB-Mo":
                    gp3 = f"{float(dim['pricePerUnit']['USD']):.4f}"
                    break
except Exception:
    pass

print(json.dumps({"ec2": out, "gp3": gp3}))
PY
  )" || {
    load_fallback_catalog
    info "Catalog: $PRICES_SOURCE (pricing fetch failed)"
    return
  }

  local priced_count=0
  while IFS=$'\t' read -r t price; do
    [[ -z "$t" || -z "$price" ]] && continue
    if [[ "$t" == "__gp3__" ]]; then
      GP3_USD_GB_MO="$price"
      continue
    fi
    EC2_USD_HR[$t]="$price"
    priced_count=$((priced_count + 1))
  done < <(
    export PRICES_JSON="$prices_out"
    python3 - <<'PY'
import json, os
d = json.loads(os.environ["PRICES_JSON"])
for t, p in sorted(d.get("ec2", {}).items()):
    print(f"{t}\t{p}")
gp3 = d.get("gp3")
if gp3:
    print(f"__gp3__\t{gp3}")
PY
  )

  if ((priced_count == 0)); then
    load_fallback_catalog
    info "Catalog: $PRICES_SOURCE (no prices returned for $region)"
    return
  fi

  PRICES_SOURCE="live AWS list ($region on-demand Linux)"
  info "Catalog: $PRICES_SOURCE — ${#EC2_TYPES[@]} types, ${priced_count} priced, gp3=\$${GP3_USD_GB_MO}/GB-mo"
}

# Map a preferred type to something present in EC2_TYPES (by vCPU).
resolve_instance_type() {
  local want="$1" t
  for t in "${EC2_TYPES[@]}"; do
    [[ "$t" == "$want" ]] && { echo "$want"; return; }
  done
  local want_v="${EC2_VCPU[$want]:-0}"
  if ((want_v == 0)); then
    case "$want" in
      c7i.large) want_v=2 ;;
      c7i.xlarge) want_v=4 ;;
      c7i.2xlarge) want_v=8 ;;
      c7i.4xlarge) want_v=16 ;;
      c7i.8xlarge) want_v=32 ;;
      c7i.12xlarge) want_v=48 ;;
      c7i.16xlarge) want_v=64 ;;
      c7i.24xlarge) want_v=96 ;;
      c7i.48xlarge) want_v=192 ;;
      *) want_v=8 ;;
    esac
  fi
  local best="" best_v=9999 v
  for t in "${EC2_TYPES[@]}"; do
    v="${EC2_VCPU[$t]:-0}"
    if ((v >= want_v && v < best_v)); then
      best="$t"
      best_v=$v
    fi
  done
  if [[ -n "$best" ]]; then
    echo "$best"
    return
  fi
  # nothing larger — pick biggest available
  if ((${#EC2_TYPES[@]} > 0)); then
    echo "${EC2_TYPES[-1]}"
  else
    echo "$want"
  fi
}

smallest_instance_type() {
  if ((${#EC2_TYPES[@]} > 0)); then
    echo "${EC2_TYPES[0]}"
  else
    echo "c7i.large"
  fi
}

# Fill all wizard variables for a cheapest-possible Terraform smoke stack.
# Not sized for video encode / real traffic — services up only.
apply_smoke_defaults() {
  section "Smoke test defaults (Terraform validation only)"
  info "Smallest c7i + thin disk. Do not push video through this box."
  info "Destroy when done:  cd deploy/terraform && terraform destroy"
  echo

  PROJECT="dronefeed"
  ENVIRONMENT="test"
  OWNER=""
  COST_CENTER=""
  EXTRA_KEYS=()
  EXTRA_VALS=()
  NAME_PREFIX="dronefeed-smoke"

  AWS_REGION="us-east-1"
  AZ=""
  FEEDS=0
  HEIGHT="720"
  UI_USERS=0
  PULLERS=0
  FANOUT="n"
  RETENTION_DAYS=1
  REC_VCPU_NEED=0
  refresh_ec2_catalog "$AWS_REGION"
  INSTANCE_TYPE="$(smallest_instance_type)"
  ROOT_GB=40
  info "Smoke instance: $INSTANCE_TYPE (smallest c7i in catalog)"

  PUBLIC_KEY=""
  KEY_NAME=""
  ENABLE_SSM="true"
  DEFAULT_PUB=""
  for cand in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub"; do
    if [[ -f "$cand" ]]; then DEFAULT_PUB="$cand"; break; fi
  done
  if [[ -n "$DEFAULT_PUB" ]]; then
    PUBLIC_KEY="$(tr -d '\n' <"$DEFAULT_PUB")"
    SSH_PRIVATE_KEY_PATH="${DEFAULT_PUB%.pub}"
    info "SSH: existing key $DEFAULT_PUB"
  else
    mkdir -p "$KEYS_DIR"
    if [[ ! -f "$GENERATED_KEY" ]]; then
      ssh-keygen -t ed25519 -N "" -f "$GENERATED_KEY" -C "dronefeed-smoke" >/dev/null
      chmod 600 "$GENERATED_KEY"
    fi
    PUBLIC_KEY="$(tr -d '\n' <"${GENERATED_KEY}.pub")"
    SSH_PRIVATE_KEY_PATH="$GENERATED_KEY"
    info "SSH: generated $GENERATED_KEY"
  fi

  MY_IP="$(curl -4 -fsS --max-time 3 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]' || true)"
  if [[ -n "$MY_IP" ]]; then
    SSH_CIDR="${MY_IP}/32"
  else
    SSH_CIDR="0.0.0.0/0"
  fi
  MEDIA_CIDR="0.0.0.0/0"
  info "SSH allow: $SSH_CIDR"

  ADMIN_EMAIL="admin@dronefeed.local"
  ADMIN_PASSWORD="$(gen_admin_password)"
  info "Admin: $ADMIN_EMAIL / $ADMIN_PASSWORD"

  GIT_REPO="https://github.com/tfeuerbach/dronefeed.git"
  GIT_REF="master"
  DEPLOY_USER="dronefeed"

  ENABLE_SES="false"
  ASSOCIATE_EIP="true"
  ENABLE_MAINTENANCE="true"
  MAINT_CREATE="true"
  MAINT_BUCKET=""
  MAINT_SAME_ACCOUNT="true"
  MAINT_BUCKET_REGION=""
  MAINT_ACCESS_KEY=""
  MAINT_SECRET_KEY=""
  MAINT_SESSION_TOKEN=""
  APP_HOSTNAME=""
  ENABLE_UI_CLOUDFRONT="false"

  ENABLE_SCHEDULE="true"
  SCHEDULE_TZ="America/New_York"
  SCHEDULE_START=8
  SCHEDULE_STOP=18

  ENABLE_OPS_ALERTS="false"
  OPS_ALERT_EMAIL=""
  MONTHLY_BUDGET_USD=50

  info "Instance: $INSTANCE_TYPE + ${ROOT_GB} GiB @ $AWS_REGION (name_prefix=$NAME_PREFIX)"
}

hr() { printf '%s\n' "========================================================"; }
hr_soft() { printf '%s\n' "--------------------------------------------------------"; }

# Major wizard step (1/8 … Summary). Extra blank lines so steps don't run together.
section() {
  echo
  echo
  hr
  echo " $1"
  hr
  echo
}

# Break inside a long section (e.g. region vs sizing questions).
subsection() {
  echo
  echo
  hr_soft
  echo " $1"
  hr_soft
  echo
}

info() { printf '  %s\n' "$@"; }

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
  local q="$1" def="${2:-y}" ans other=n
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

# menu_pick PROMPT DEFAULT_INDEX OPT1 OPT2 ...
# Prints the full selected label to stdout (* marks default on the menu).
menu_pick() {
  local q="$1" def="$2"
  shift 2
  local -a opts=("$@")
  local i ans mark
  echo >&2
  echo "$q" >&2
  echo >&2
  for i in "${!opts[@]}"; do
    mark=" "
    [[ $((i + 1)) -eq "$def" ]] && mark="*"
    printf '  %s%d) %s\n' "$mark" "$((i + 1))" "${opts[$i]}" >&2
  done
  echo >&2
  while true; do
    read -r -p "  Choice [$def]: " ans || true
    ans="${ans:-$def}"
    if [[ "$ans" =~ ^[0-9]+$ ]] && ((ans >= 1 && ans <= ${#opts[@]})); then
      echo "${opts[$((ans - 1))]}"
      return
    fi
    echo "  Enter a number 1-${#opts[@]}" >&2
  done
}

# First token before " - " (ASCII), used as the value from a menu label.
menu_value() {
  local label="$1"
  if [[ "$label" == *" - "* ]]; then
    echo "${label%% - *}"
  else
    echo "$label"
  fi
}

# pick DEFAULT_INDEX PROMPT OPT1 OPT2 ...  -> menu_value of selection
pick() {
  local def="$1" q="$2" label
  shift 2
  label="$(menu_pick "$q" "$def" "$@")"
  menu_value "$label"
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

# S3 bucket naming (AWS rules, simplified). Empty string = caller will auto-name.
valid_s3_bucket_name() {
  local b="$1" n
  [[ -z "$b" ]] && return 0
  n=${#b}
  ((n >= 3 && n <= 63)) || return 1
  [[ "$b" =~ ^[a-z0-9][a-z0-9.-]*[a-z0-9]$ ]] || return 1
  [[ "$b" != *..* && "$b" != *.-* && "$b" != *-.* ]] || return 1
  # Reject looking like an IP address.
  [[ ! "$b" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  # Common footgun: pasting a region as the bucket name.
  [[ "$b" != us-east-1 && "$b" != us-east-2 && "$b" != us-west-2 && "$b" != eu-west-1 ]] || return 1
  return 0
}

prompt_s3_bucket_name() {
  local q="$1" def="${2-}" ans
  while true; do
    ans="$(prompt "$q" "$def")"
    if valid_s3_bucket_name "$ans"; then
      echo "$ans"
      return
    fi
    warn "Invalid S3 bucket name '$ans'."
    info "Use 3-63 chars: lowercase letters, numbers, dots, hyphens (e.g. dronefeed-after-hours-123)."
    info "Leave blank for the auto name. Do not use a region code like us-east-1."
    def=""
  done
}

confirm_continue() {
  local q="$1"
  prompt_yn "$q" n || die "Aborted."
}

gen_admin_password() {
  local base
  base="$(openssl rand -base64 12 | tr -d '\n=/+' | cut -c1-10)"
  echo "${base}1!"
}

ec2_hr() {
  local t="$1"
  if [[ -n "${EC2_USD_HR[$t]+x}" ]]; then
    echo "${EC2_USD_HR[$t]}"
  else
    echo ""
  fi
}

# Estimate vCPUs for DroneFeed: continuous libx264 public encodes dominate;
# MediaMTX pull fan-out and Phoenix UI are lighter but real.
# Heuristic (not a bench) — calibrated so ~4×720p + light pullers → c7i.4xlarge,
# and large encode fleets climb the full c7i catalog (12xlarge+).
estimate_workload_vcpu() {
  local feeds="$1" height="$2" users="$3" pullers="$4"
  local per_feed=2 platform=2 need pull_v ui_v
  case "$height" in
    1080) per_feed=4 ;;
    source) per_feed=6 ;;
  esac
  need=$((platform + feeds * per_feed))
  # Remux/packet path: ~1 vCPU per 20 pullers, plus steps at demo-scale fan-out
  pull_v=$(((pullers + 19) / 20))
  ((pullers > 50)) && pull_v=$((pull_v + 2))
  ((pullers > 200)) && pull_v=$((pull_v + 4))
  ((pullers > 500)) && pull_v=$((pull_v + 8))
  need=$((need + pull_v))
  # Website viewers are cheap vs encodes
  ui_v=$(((users + 49) / 50))
  need=$((need + ui_v))
  # ~20% headroom for spikes / OS / compose leftovers
  need=$(((need * 6 + 4) / 5))
  ((need < 2)) && need=2
  echo "$need"
}

# Smallest catalog type with enough vCPU (and RAM >= ~1.5 GiB/vCPU soft floor via c7i ratio).
pick_instance_for_vcpu() {
  local need_v="$1" t v best="" best_v=999999
  for t in "${EC2_TYPES[@]}"; do
    v="${EC2_VCPU[$t]:-0}"
    ((v <= 0)) && continue
    if ((v >= need_v && v < best_v)); then
      best="$t"
      best_v=$v
    fi
  done
  if [[ -n "$best" ]]; then
    echo "$best"
    return
  fi
  # Need exceeds catalog — return largest and let caller warn.
  if ((${#EC2_TYPES[@]} > 0)); then
    echo "${EC2_TYPES[-1]}"
  else
    echo "c7i.8xlarge"
  fi
}

recommend_instance() {
  local feeds="$1" height="$2" users="$3" pullers="$4"
  local need
  need="$(estimate_workload_vcpu "$feeds" "$height" "$users" "$pullers")"
  pick_instance_for_vcpu "$need"
}

recommend_root_gb() {
  local feeds="$1" height="$2" retention_days="$3" hours_per_day="$4"
  local gb_per_hr=1.1 need s
  case "$height" in
    1080) gb_per_hr=2.2 ;;
    source) gb_per_hr=4.0 ;;
  esac
  need="$(awk -v f="$feeds" -v d="$retention_days" -v h="$hours_per_day" -v r="$gb_per_hr" \
    'BEGIN { printf "%.0f", 40 + f * d * h * r }')"
  for s in 80 100 120 150 200 250 300 400 500; do
    if ((need <= s)); then
      echo "$s"
      return
    fi
  done
  echo "$need"
}

fmt_money() {
  awk -v n="$1" 'BEGIN { printf "%.0f", n+0.5 }'
}

cost_lines() {
  local hr ebs_mo compute_sched compute_full hours_sched day_h
  hr="$(ec2_hr "$INSTANCE_TYPE")"
  ebs_mo="$(awk -v gb="$ROOT_GB" -v p="$GP3_USD_GB_MO" 'BEGIN { printf "%.2f", gb * p }')"

  echo "  Rough cost (USD — $PRICES_SOURCE; not a quote)"
  if [[ -z "$hr" ]]; then
    info "EC2 $INSTANCE_TYPE: (no rate in catalog - check AWS calculator)"
  else
    compute_full="$(awk -v h="$hr" -v m="$HOURS_PER_MONTH_FULL" 'BEGIN { printf "%.2f", h * m }')"
    info "EC2 $INSTANCE_TYPE: \$${hr}/hr  ->  ~\$$(fmt_money "$compute_full")/mo if 24x7"
    if [[ "${ENABLE_SCHEDULE:-false}" == true ]]; then
      day_h=$((SCHEDULE_STOP - SCHEDULE_START))
      if ((day_h <= 0)); then day_h=10; fi
      hours_sched="$(awk -v d="$day_h" -v w="$WEEKDAYS_PER_MONTH" 'BEGIN { printf "%.0f", d * w }')"
      compute_sched="$(awk -v h="$hr" -v m="$hours_sched" 'BEGIN { printf "%.2f", h * m }')"
      info "With Mon-Fri ${SCHEDULE_START}:00-${SCHEDULE_STOP}:00 (~${hours_sched} h/mo): ~\$$(fmt_money "$compute_sched")/mo compute"
    fi
  fi
  info "EBS gp3 ${ROOT_GB} GiB: ~\$${ebs_mo}/mo (always, even when stopped)"
  if [[ "${ASSOCIATE_EIP:-true}" == true ]]; then
    info "Elastic IP: free while attached to the instance"
  fi
  if [[ "${ENABLE_MAINTENANCE:-false}" == true ]]; then
    info "Offline page (S3+CloudFront): usually under a few USD/mo"
  fi
  info "Data transfer / SRT pull egress not included - can dominate with heavy viewers"
}

# ─── start ───────────────────────────────────────────────────────────────────

echo
echo
hr
echo " DroneFeed - AWS setup wizard"
hr
echo
info "IP-first stack (HTTP on Elastic IP). DNS/HTTPS optional later."
info "Writes gitignored terraform.tfvars + secrets.auto.tfvars."
if [[ -n "${AWS_PROFILE:-}" ]]; then
  info "AWS_PROFILE:  $AWS_PROFILE"
fi
echo
echo

need_cmd terraform
need_cmd openssl
need_cmd awk

if command -v aws >/dev/null 2>&1; then
  # aws_profile_require prints identity lines; rephrase with info() for consistency.
  if aws sts get-caller-identity >/dev/null 2>&1; then
    info "AWS identity: $(aws sts get-caller-identity --query Arn --output text 2>/dev/null)"
    info "Account:      $(aws sts get-caller-identity --query Account --output text 2>/dev/null)"
  else
    if [[ -n "$AWS_PROFILE_ARG" ]]; then
      echo "error: AWS profile '${AWS_PROFILE}' failed sts get-caller-identity." >&2
      echo "  If this is SSO, run:  aws sso login --profile ${AWS_PROFILE}" >&2
      echo "  Then retry." >&2
      exit 1
    fi
    echo "warning: aws sts get-caller-identity failed - check credentials before apply."
  fi
else
  if [[ -n "$AWS_PROFILE_ARG" ]]; then
    die "aws CLI not found but --aws-profile was set"
  fi
  info "aws CLI not found - OK if credentials are configured for Terraform."
fi

# Half-applied stacks + a fresh wizard = pain. Detect before rewriting tfvars.
if [[ -d "$ROOT/.terraform" ]]; then
  STATE_COUNT="$(terraform state list 2>/dev/null | wc -l | tr -d ' ' || true)"
  if [[ "${STATE_COUNT:-0}" -gt 0 ]]; then
    echo
    warn "Terraform state already has ${STATE_COUNT} resources in:"
    info "$ROOT"
    info "If the last apply failed mid-way, prefer:  ./destroy.sh -p ${AWS_PROFILE:-<profile>}"
    info "Or finish with:  terraform apply"
    confirm_continue "Continue wizard anyway (may overwrite tfvars while state still exists)?"
  fi
fi

if [[ "$SMOKE" != true ]]; then
  MODE="$(pick 1 "What do you want to run?" \
    "guided - full setup (pick size, keys, schedule, ...)" \
    "smoke - cheapest box, defaults only (Terraform test, no video)")"
  [[ "$MODE" == "smoke" ]] && SMOKE=true
fi

declare -a EXTRA_KEYS=()
declare -a EXTRA_VALS=()

if [[ "$SMOKE" == true ]]; then
  apply_smoke_defaults
  section "Smoke — operator email (optional)"
  info "SNS: schedule / budget / disk / swap / OOM + one bootstrap mail after apply."
  info "You must Confirm the AWS subscription email before the bootstrap message arrives."
  ENABLE_OPS_ALERTS="false"
  OPS_ALERT_EMAIL=""
  MONTHLY_BUDGET_USD=50
  if prompt_yn "Test operator email alerts on this smoke stack?" n; then
    ENABLE_OPS_ALERTS="true"
    OPS_ALERT_EMAIL="$(prompt "Alert email inbox" "${ADMIN_EMAIL}")"
    [[ -n "$OPS_ALERT_EMAIL" ]] || die "alert email required when testing ops alerts"
    MONTHLY_BUDGET_USD="$(prompt "Monthly budget USD (smoke default 50)" "50")"
    [[ "$MONTHLY_BUDGET_USD" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "monthly budget must be a number"
  fi
else

# ── 1 tags ───────────────────────────────────────────────────────────────────
section "1/8  Project identity (tags - editable later via tfvars + apply)"
PROJECT="$(prompt "Project tag" "spectre")"
ENVIRONMENT="$(pick 1 "Environment tag" "prod" "staging" "test" "dev")"
OWNER=""
COST_CENTER=""
if prompt_yn "Add Owner / CostCenter / extra tags?" n; then
  OWNER="$(prompt "Owner tag (team or email, blank to skip)" "")"
  COST_CENTER="$(prompt "CostCenter tag (blank to skip)" "")"
fi

if prompt_yn "Add more custom tags?" n; then
  echo "  Blank key when done."
  while true; do
    k="$(prompt "  Extra tag key (blank to finish)" "")"
    [[ -z "$k" ]] && break
    if [[ "$k" == "ManagedBy" ]]; then
      info "skipping ManagedBy (reserved)"
      continue
    fi
    v="$(prompt "  Value for $k" "")"
    EXTRA_KEYS+=("$k")
    EXTRA_VALS+=("$v")
  done
fi

NAME_PREFIX="$(slugify "$(prompt "Resource name_prefix" "$PROJECT")")"
[[ -n "$NAME_PREFIX" ]] || NAME_PREFIX="dronefeed"

# ── 2 region + workload ──────────────────────────────────────────────────────
section "2/8  Region + workload sizing"

subsection "Region"
AWS_REGION="$(pick 1 "AWS region" \
  "us-east-1 - N. Virginia (pricing table below)" \
  "us-east-2 - Ohio" \
  "us-west-2 - Oregon" \
  "eu-west-1 - Ireland" \
  "custom - type a region code")"
if [[ "$AWS_REGION" == "custom" ]]; then
  AWS_REGION="$(prompt "AWS region code" "us-east-1")"
fi

echo
refresh_ec2_catalog "$AWS_REGION"

subsection "Public feeds (CPU encodes)"
info "Each public feed is a continuous CPU encode."
info "Website viewers and external players are asked next — they are lighter but counted separately."
echo
FEEDS="$(prompt "Peak concurrent public feeds (live sessions + VOD republishes encoding at once)" "2")"
[[ "$FEEDS" =~ ^[0-9]+$ ]] && ((FEEDS >= 1)) || die "feeds must be a positive integer"

echo
HEIGHT="$(pick 1 "Typical public output resolution" \
  "720 - default CBR-ish encode (recommended)" \
  "1080 - heavier CPU per feed" \
  "source - keep source resolution (highest CPU)")"

subsection "Website viewers"
info "People with DroneFeed open in a browser (watching in the web UI)."
info "Do not count VLC / ffplay / SRT tools here — those are the next block."
echo
UI_USERS="$(prompt "Peak concurrent website viewers" "5")"
[[ "$UI_USERS" =~ ^[0-9]+$ ]] || die "website viewers must be an integer"

subsection "External pullers"
info "Separate apps opening a stream URL (VLC, ffplay, research SRT/RTSP/RTMP tools)."
info "Count each open stream connection. Website tabs are already counted above."
info "Leave 0 if nobody pulls outside the browser."
echo
PULLERS="$(prompt "Peak concurrent external pullers" "10")"
[[ "$PULLERS" =~ ^[0-9]+$ ]] || die "external pullers must be an integer"
FANOUT="n"
((PULLERS >= 20)) && FANOUT="y"

subsection "Recording disk"
RETENTION_DAYS="$(prompt "Recording retention days to size disk for" "5")"
[[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]] && ((RETENTION_DAYS >= 1)) || die "retention days must be a positive integer"

REC_HOURS_HINT=10
REC_VCPU_NEED="$(estimate_workload_vcpu "$FEEDS" "$HEIGHT" "$UI_USERS" "$PULLERS")"
REC_INSTANCE="$(pick_instance_for_vcpu "$REC_VCPU_NEED")"
REC_ROOT="$(recommend_root_gb "$FEEDS" "$HEIGHT" "$RETENTION_DAYS" "$REC_HOURS_HINT")"

subsection "Recommendation"
info "Workload estimate (~heuristic, not a bench):"
info "  ${FEEDS} encodes @${HEIGHT}, ${UI_USERS} website viewers, ${PULLERS} external pullers"
info "  Target >= ${REC_VCPU_NEED} vCPU (platform + encodes + pullers + viewers + 25% headroom)"
echo
info "From catalog:"
info "  Instance: ${REC_INSTANCE}  (${EC2_VCPU[$REC_INSTANCE]:-?} vCPU / ${EC2_RAM_GB[$REC_INSTANCE]:-?} GiB)"
if [[ -n "${EC2_USD_HR[$REC_INSTANCE]+x}" ]]; then
  info "  On-demand: \$${EC2_USD_HR[$REC_INSTANCE]}/hr"
fi
info "  Root disk: ${REC_ROOT} GiB gp3 (${RETENTION_DAYS}-day retention hint)"
if ((${EC2_VCPU[$REC_INSTANCE]:-0} < REC_VCPU_NEED)); then
  warn "Largest catalog type is still under the estimate — consider custom / contact AWS for bigger."
fi

subsection "Choose instance + disk + AZ"
declare -a INST_OPTS=()
INST_OPTS+=("${REC_INSTANCE} - recommended (>=${REC_VCPU_NEED} vCPU target)")
local_note_for() {
  case "$1" in
    c7i.large) echo "smoke / idle only" ;;
    c7i.xlarge) echo "light demos (1-2 @720p)" ;;
    c7i.2xlarge) echo "typical prod (<=4 @720p)" ;;
    c7i.4xlarge) echo "more feeds / 1080p headroom" ;;
    c7i.8xlarge) echo "heavy encode load" ;;
    c7i.12xlarge) echo "very heavy / many 720p encodes" ;;
    c7i.16xlarge) echo "large fleet of encodes" ;;
    c7i.24xlarge|c7i.48xlarge) echo "extreme concurrent encodes" ;;
    *) echo "${EC2_VCPU[$1]:-?} vCPU / ${EC2_RAM_GB[$1]:-?} GiB" ;;
  esac
}
for t in "${EC2_TYPES[@]}"; do
  [[ "$t" == "$REC_INSTANCE" ]] && continue
  note="$(local_note_for "$t")"
  if [[ -n "${EC2_USD_HR[$t]+x}" ]]; then
    INST_OPTS+=("${t} - ${note}; \$${EC2_USD_HR[$t]}/hr")
  else
    INST_OPTS+=("${t} - ${note}")
  fi
done
INST_OPTS+=("custom - type any instance type")

INSTANCE_TYPE="$(pick 1 "Choose instance type (live catalog for $AWS_REGION)" "${INST_OPTS[@]}")"
if [[ "$INSTANCE_TYPE" == "custom" ]]; then
  INSTANCE_TYPE="$(prompt "Instance type" "$REC_INSTANCE")"
fi

PICK_V="${EC2_VCPU[$INSTANCE_TYPE]:-0}"
if ((PICK_V > 0 && PICK_V < REC_VCPU_NEED)); then
  echo
  warn "Instance $INSTANCE_TYPE has ${PICK_V} vCPU; workload estimate wants >= ${REC_VCPU_NEED} vCPU."
  info "Recommended was ${REC_INSTANCE}. Undersizing causes choppy encodes / dropped pulls."
  confirm_continue "Keep undersized $INSTANCE_TYPE anyway?"
elif [[ "$INSTANCE_TYPE" == c7i.large || "$INSTANCE_TYPE" == c7i.xlarge ]]; then
  if ((FEEDS >= 2)) || ((PULLERS >= 20)); then
    echo
    warn "Instance $INSTANCE_TYPE is usually too small for video demos with real feeds/pullers."
    confirm_continue "Keep $INSTANCE_TYPE anyway?"
  fi
fi

echo
declare -a DISK_OPTS=("${REC_ROOT} - recommended")
for s in 80 120 200 300 500; do
  [[ "$s" == "$REC_ROOT" ]] && continue
  DISK_OPTS+=("${s} - GiB gp3")
done
DISK_OPTS+=("custom - type GiB")

ROOT_GB="$(pick 1 "Root volume size (EBS gp3 - what you pick is provisioned)" "${DISK_OPTS[@]}")"
if [[ "$ROOT_GB" == "custom" ]]; then
  ROOT_GB="$(prompt "Root volume GiB" "$REC_ROOT")"
fi
[[ "$ROOT_GB" =~ ^[0-9]+$ ]] && ((ROOT_GB >= 30)) || die "root volume must be an integer >= 30"

if ((ROOT_GB < REC_ROOT)); then
  echo
  warn "Root disk ${ROOT_GB} GiB is below the recommended ${REC_ROOT} GiB for your workload/retention."
  info "You can grow EBS later, but recordings may fill the disk sooner."
  confirm_continue "Keep ${ROOT_GB} GiB anyway?"
fi

echo
# AZ must be blank (Terraform picks first) or a real zone letter, never the region alone.
AZ=""
while true; do
  AZ="$(prompt "Availability zone (blank = first in region; e.g. ${AWS_REGION}a — not ${AWS_REGION})" "")"
  if [[ -z "$AZ" ]]; then
    break
  fi
  if [[ "$AZ" == "$AWS_REGION" ]]; then
    warn "'$AZ' is the region, not an AZ. Use ${AWS_REGION}a / ${AWS_REGION}b / … or leave blank."
    continue
  fi
  if [[ ! "$AZ" =~ ^[a-z0-9]+-[a-z]+-[0-9]+[a-z]$ ]]; then
    warn "Expected form like ${AWS_REGION}a (region name + letter). Got: $AZ"
    continue
  fi
  if [[ "$AZ" != "$AWS_REGION"* ]]; then
    warn "AZ '$AZ' does not start with region '$AWS_REGION'."
    continue
  fi
  if command -v aws >/dev/null 2>&1; then
    if ! aws ec2 describe-availability-zones \
      --region "$AWS_REGION" \
      --zone-names "$AZ" \
      --query 'AvailabilityZones[0].ZoneName' \
      --output text 2>/dev/null | grep -qx "$AZ"; then
      warn "AWS does not list '$AZ' as an availability zone in $AWS_REGION."
      continue
    fi
  fi
  break
done

echo
info "Selected: $INSTANCE_TYPE + ${ROOT_GB} GiB in ${AWS_REGION}${AZ:+/$AZ}"

# ── 3 SSH ────────────────────────────────────────────────────────────────────
section "3/8  How you log into the server"
info "This installs a login key so you can shell in as user 'dronefeed'."
info "If you already have a key on this laptop, choose option 1."
echo

PUBLIC_KEY=""
KEY_NAME=""
ENABLE_SSM="true"

subsection "SSH key"

DEFAULT_PUB=""
for cand in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub"; do
  if [[ -f "$cand" ]]; then DEFAULT_PUB="$cand"; break; fi
done

if [[ -n "$DEFAULT_PUB" ]]; then
  SSH_OPT_SYSTEM="laptop - use my existing key ($DEFAULT_PUB)"
  SSH_KEY_DEFAULT=1
else
  SSH_OPT_SYSTEM="laptop - (no key found here; pick create or paste)"
  SSH_KEY_DEFAULT=2
fi

SSH_MODE="$(pick "$SSH_KEY_DEFAULT" "How should you log in over SSH?" \
  "$SSH_OPT_SYSTEM" \
  "create - make a new key under deploy/terraform/keys/ (saved on this machine)" \
  "paste - I have a public key to paste")"

case "$SSH_MODE" in
  laptop)
    [[ -n "$DEFAULT_PUB" ]] || die "no key found on this laptop - pick create or paste"
    PUBLIC_KEY="$(tr -d '\n' <"$DEFAULT_PUB")"
    SSH_PRIVATE_KEY_PATH="${DEFAULT_PUB%.pub}"
    ;;
  create)
    mkdir -p "$KEYS_DIR"
    if [[ ! -f "$GENERATED_KEY" ]]; then
      ssh-keygen -t ed25519 -N "" -f "$GENERATED_KEY" -C "dronefeed-${NAME_PREFIX}" >/dev/null
      chmod 600 "$GENERATED_KEY"
    fi
    PUBLIC_KEY="$(tr -d '\n' <"${GENERATED_KEY}.pub")"
    SSH_PRIVATE_KEY_PATH="$GENERATED_KEY"
    info "Created $GENERATED_KEY (gitignored - keep this file; you need it to log in)"
    ;;
  paste)
    PUBLIC_KEY="$(prompt "Paste your public key (one line starting with ssh-ed25519 or ssh-rsa)" "")"
    SSH_PRIVATE_KEY_PATH="$(prompt "Path to the matching private key on this machine" "")"
    ;;
  *)
    die "unexpected SSH key choice: $SSH_MODE"
    ;;
esac
[[ -n "$PUBLIC_KEY" ]] || die "a login key is required so you can reach the server"

subsection "Backup login (SSM)"
info "AWS Session Manager is a backup way to open a shell in the AWS console"
info "if SSH is blocked (no extra key needed). Recommended: yes."
echo
prompt_yn "Enable that backup login (SSM)?" y || ENABLE_SSM="false"

subsection "Who can reach the server"
info "Who is allowed to SSH (terminal login) to the server?"
info "Recommended: only your current internet connection."
echo
SSH_WHO="$(pick 1 "Who can SSH in?" \
  "only-me - just my current public IP (safer)" \
  "anyone - any address on the internet (ok for a short lab test)" \
  "custom - I will type an IP or range")"
case "$SSH_WHO" in
  only-me)
    MY_IP="$(curl -4 -fsS --max-time 3 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ -n "$MY_IP" ]]; then
      SSH_CIDR="${MY_IP}/32"
      info "SSH locked to your current IP: $SSH_CIDR"
      info "(If your home/office IP changes later, SSH may stop working until you update this.)"
    else
      echo "warning: could not detect your IP"
      SSH_CIDR="$(prompt "Type your public IP with /32 (example: 203.0.113.10/32)" "0.0.0.0/0")"
    fi
    ;;
  anyone) SSH_CIDR="0.0.0.0/0" ;;
  custom) SSH_CIDR="$(prompt "IP or range that may SSH (examples: 203.0.113.10/32 or 10.0.0.0/8)" "0.0.0.0/0")" ;;
  *) SSH_CIDR="0.0.0.0/0" ;;
esac

echo
info "Who can open the website and pull video (ports 80/443 and media)?"
info "For research viewers on the internet, leave this open."
echo
if prompt_yn "Allow the website and video ports from the whole internet?" y; then
  MEDIA_CIDR="0.0.0.0/0"
else
  MEDIA_CIDR="$(prompt "IP or range allowed for web/video" "0.0.0.0/0")"
fi

# ── 4 admin ──────────────────────────────────────────────────────────────────
section "4/8  Admin login (printed after apply)"
ADMIN_EMAIL="$(prompt "Admin email" "admin@dronefeed.local")"
echo
DEFAULT_ADMIN_PW="$(gen_admin_password)"
info "Generated admin password: $DEFAULT_ADMIN_PW"
if prompt_yn "Use this generated password?" y; then
  ADMIN_PASSWORD="$DEFAULT_ADMIN_PW"
else
  ADMIN_PASSWORD="$(prompt_secret "Admin password (>=8 chars, digit + symbol)")"
fi
[[ -n "$ADMIN_PASSWORD" ]] || die "admin password required"
if [[ ${#ADMIN_PASSWORD} -lt 8 ]]; then
  die "admin password must be at least 8 characters"
fi

# ── 5 repo ───────────────────────────────────────────────────────────────────
section "5/8  Repo bootstrap on the instance"
info "Instance clones this ref on first boot - push your changes before apply."
echo
GIT_REPO="$(prompt "Git clone URL" "https://github.com/tfeuerbach/dronefeed.git")"
echo
GIT_REF="$(prompt "Git branch or tag (needs Caddyfile.http + runtime PHX_SCHEME/force_ssl)" "master")"
echo
DEPLOY_USER="$(prompt "Linux deploy user" "dronefeed")"

# ── 6 email / EIP ────────────────────────────────────────────────────────────
section "6/8  Email + Elastic IP"

subsection "App email (SES)"
ENABLE_SES="false"
prompt_yn "Attach SES send policy / plan to use outbound email later (app SMTP)?" n && ENABLE_SES="true"

subsection "Operator alerts (SNS)"
ENABLE_OPS_ALERTS="false"
OPS_ALERT_EMAIL=""
MONTHLY_BUDGET_USD=500
info "Operator alerts use SNS (no SES): schedule, budget, disk, swap pressure, OOM."
echo
if prompt_yn "Enable operator email alerts (SNS)?" y; then
  ENABLE_OPS_ALERTS="true"
  OPS_ALERT_EMAIL="$(prompt "Alert email inbox" "$ADMIN_EMAIL")"
  [[ -n "$OPS_ALERT_EMAIL" ]] || die "alert email required when ops alerts are enabled"
  MONTHLY_BUDGET_USD="$(prompt "Monthly AWS budget USD" "500")"
  [[ "$MONTHLY_BUDGET_USD" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "monthly budget must be a number"
  info "After apply: Confirm the AWS SNS subscription email, then setup sends a bootstrap mail."
fi

subsection "Elastic IP"
ASSOCIATE_EIP="true"
prompt_yn "Allocate Elastic IP (recommended for IP-first)?" y || ASSOCIATE_EIP="false"

subsection "UI hostname (Spectre ACM + Lambda@Edge)"
APP_HOSTNAME=""
ENABLE_UI_CLOUDFRONT="false"
info "Optional. This account creates ACM + Lambda@Edge; DNS account only adds validation CNAMEs + alias."
echo
if prompt_yn "Configure a public UI hostname now (e.g. dronefeed.ecsdevlabs.com)?" n; then
  APP_HOSTNAME="$(prompt "UI hostname (FQDN)" "dronefeed.ecsdevlabs.com")"
  [[ -n "$APP_HOSTNAME" ]] || die "hostname required when UI hostname is enabled"
  info "Leave enable_ui_cloudfront=false until ACM validation CNAMEs exist; then set true and re-apply."
fi

# ── 7 maintenance ────────────────────────────────────────────────────────────
section "7/8  After-hours offline page (S3 + CloudFront)"
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
  info "Offline HTML lives in S3; CloudFront serves it when you wire DNS failover later."
  echo
  if prompt_yn "Create a new S3 bucket for the offline page?" y; then
    MAINT_CREATE="true"
    MAINT_BUCKET="$(prompt_s3_bucket_name "New bucket name (blank = ${NAME_PREFIX}-after-hours-<account_id>)" "")"
  else
    MAINT_CREATE="false"
    MAINT_BUCKET="$(prompt_s3_bucket_name "Existing S3 bucket name" "")"
    [[ -n "$MAINT_BUCKET" ]] || die "existing bucket name is required"
    info "Terraform will set this buckets policy for CloudFront OAC (replaces bucket policy)."
  fi

  echo
  if prompt_yn "Is that bucket in the same AWS account as this EC2 stack?" y; then
    MAINT_SAME_ACCOUNT="true"
    MAINT_BUCKET_REGION="$(prompt "Bucket region (blank = same as EC2 region $AWS_REGION)" "")"
  else
    MAINT_SAME_ACCOUNT="false"
    info "Cross-account: credentials that can read/write the bucket and put bucket policy."
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

# ── 8 schedule ───────────────────────────────────────────────────────────────
section "8/8  Business hours (auto start/stop)"
ENABLE_SCHEDULE="true"
SCHEDULE_TZ="America/New_York"
SCHEDULE_START=8
SCHEDULE_STOP=18
if prompt_yn "Auto start/stop EC2 on weekdays (saves money off-hours)?" y; then
  ENABLE_SCHEDULE="true"
  echo
  SCHEDULE_TZ="$(prompt "Timezone (IANA)" "America/New_York")"
  echo
  SCHEDULE_START="$(prompt "Start hour Mon-Fri (0-23, local)" "8")"
  echo
  SCHEDULE_STOP="$(prompt "Stop hour Mon-Fri (0-23, local)" "18")"
  [[ "$SCHEDULE_START" =~ ^[0-9]+$ && "$SCHEDULE_STOP" =~ ^[0-9]+$ ]] || die "hours must be integers"
  ((SCHEDULE_START >= 0 && SCHEDULE_START <= 23)) || die "start hour out of range"
  ((SCHEDULE_STOP >= 0 && SCHEDULE_STOP <= 23)) || die "stop hour out of range"
  if ((SCHEDULE_STOP == SCHEDULE_START)); then
    die "stop hour must differ from start hour"
  fi
  if ((SCHEDULE_STOP < SCHEDULE_START)); then
    echo
    warn "Stop hour (${SCHEDULE_STOP}) is before start (${SCHEDULE_START}) — overnight window (crosses midnight)."
    info "Weekday cron still fires both times; confirm that is what you want."
    confirm_continue "Keep overnight schedule ${SCHEDULE_START}:00 -> ${SCHEDULE_STOP}:00?"
  fi
else
  ENABLE_SCHEDULE="false"
fi

fi # end guided (non-smoke) path

# ── write tfvars ─────────────────────────────────────────────────────────────
if [[ -f "$TFVARS" ]]; then
  BACKUP="$TFVARS.bak.$(date +%Y%m%d%H%M%S)"
  cp "$TFVARS" "$BACKUP"
  echo
  info "Backed up existing tfvars -> $BACKUP"
fi

{
  echo "# Generated by setup.sh - $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "# Do not commit this file."
  if [[ "$SMOKE" == true ]]; then
    echo "# Mode: smoke test (minimum spec — not for video)"
  fi
  echo "# Workload hint: feeds=$FEEDS height=$HEIGHT ui_users=$UI_USERS retention_days=$RETENTION_DAYS"
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
  echo "enable_ssm                      = $ENABLE_SSM"
  echo "enable_ses_send                 = $ENABLE_SES"
  echo "associate_elastic_ip            = $ASSOCIATE_EIP"
  echo "enable_maintenance_static       = $ENABLE_MAINTENANCE"
  echo "maintenance_create_bucket       = $MAINT_CREATE"
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
  echo "enable_ops_alerts  = $ENABLE_OPS_ALERTS"
  if [[ "$ENABLE_OPS_ALERTS" == true ]]; then
    echo "ops_alert_email    = $(hcl_str "$OPS_ALERT_EMAIL")"
    echo "monthly_budget_usd = $MONTHLY_BUDGET_USD"
  fi
  echo
  if [[ -n "$APP_HOSTNAME" ]]; then
    echo "app_hostname         = $(hcl_str "$APP_HOSTNAME")"
    echo "enable_ui_cloudfront = $ENABLE_UI_CLOUDFRONT"
    echo
  fi
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
  echo "# Generated by setup.sh - secrets (gitignored via *.auto.tfvars)"
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

# ── summary + cost ───────────────────────────────────────────────────────────
section "Summary"
info "Wrote $TFVARS"
info "Wrote $SECRETS_TFVARS (secrets; gitignored)"
echo
info "Project=$PROJECT  Environment=$ENVIRONMENT  name_prefix=$NAME_PREFIX"
info "Workload: ${FEEDS} feeds @${HEIGHT}, ${UI_USERS} website viewers, ${PULLERS} external pullers, retain ${RETENTION_DAYS}d"
info "Compute:  $INSTANCE_TYPE + ${ROOT_GB} GiB gp3 @ $AWS_REGION"
info "Admin:    $ADMIN_EMAIL"
info "SES (app SMTP policy): $ENABLE_SES"
if [[ "$ENABLE_OPS_ALERTS" == true ]]; then
  info "Ops alerts (SNS): $OPS_ALERT_EMAIL  budget=${MONTHLY_BUDGET_USD} USD/mo"
else
  info "Ops alerts (SNS): disabled"
fi
if [[ "$ENABLE_SCHEDULE" == true ]]; then
  info "Schedule: Mon-Fri ${SCHEDULE_START}:00->${SCHEDULE_STOP}:00 $SCHEDULE_TZ"
else
  info "Schedule: disabled (instance left to you / 24x7 unless you stop it)"
fi
if [[ "$ENABLE_MAINTENANCE" == true ]]; then
  if [[ "$MAINT_CREATE" == true ]]; then
    info "After-hours: create bucket ${MAINT_BUCKET:-auto-name} + CloudFront"
  else
    info "After-hours: existing bucket $MAINT_BUCKET + CloudFront"
  fi
else
  info "After-hours: disabled"
fi
echo
cost_lines
echo
if [[ "$SMOKE" == true ]]; then
  info "Smoke stack: confirm the app loads, then terraform destroy."
else
  info "Yes: the instance type and root volume you chose are exactly what apply creates."
fi
echo

INIT_DEF=y
PLAN_DEF=y
APPLY_DEF=n
[[ "$SMOKE" == true || "$YES" == true ]] && APPLY_DEF=y

run_tf_init() {
  echo
  info "OK — starting terraform init..."
  info "First run downloads AWS provider plugins (often 30-90s). Wait for it."
  echo
  terraform init
  echo
  info "Done: terraform init."
}

run_tf_plan() {
  echo
  info "OK — starting terraform plan (writes ./tfplan)..."
  info "Talks to AWS and diffs state (often 20-60s)."
  echo
  terraform plan -out=tfplan
  echo
  info "Done: terraform plan."
}

# Wait for SNS email subscription Confirm, then publish a one-shot bootstrap message.
publish_ops_bootstrap_email() {
  local topic_arn sub_arn pending deadline now state subject body
  local public_ip app_url instance_id region name_prefix dash_name log_prefix
  local instance_state instance_type schedule_line

  [[ "${ENABLE_OPS_ALERTS:-false}" == true ]] || return 0

  topic_arn="$(terraform output -raw ops_alerts_topic_arn 2>/dev/null || true)"
  [[ -n "$topic_arn" && "$topic_arn" != "null" ]] || {
    warn "ops alerts enabled but ops_alerts_topic_arn missing — skip bootstrap email"
    return 0
  }

  section "Ops alert email — confirm SNS subscription"
  info "AWS sent a Confirm subscription email to: ${OPS_ALERT_EMAIL}"
  info "Open that mail and click Confirm before the bootstrap message can be delivered."
  echo

  deadline=$((SECONDS + 600))
  pending=true
  while ((SECONDS < deadline)); do
    state="$(aws sns list-subscriptions-by-topic --topic-arn "$topic_arn" \
      --query "Subscriptions[?Endpoint=='${OPS_ALERT_EMAIL}'].SubscriptionArn | [0]" \
      --output text 2>/dev/null || true)"
    if [[ -n "$state" && "$state" != "None" && "$state" != "PendingConfirmation" && "$state" != "null" ]]; then
      pending=false
      sub_arn="$state"
      break
    fi
    if [[ "$YES" == true ]]; then
      sleep 10
      continue
    fi
    if prompt_yn "Confirmed the SNS subscription email? (re-check now)" n; then
      sleep 2
      continue
    fi
    if prompt_yn "Skip bootstrap email for now?" n; then
      warn "Skipped bootstrap email — subscription still pending or not confirmed."
      info "After Confirm: aws sns publish --topic-arn ${topic_arn} --subject 'DroneFeed ops alerts' --message 'Subscription confirmed.'"
      return 0
    fi
    sleep 5
  done

  if [[ "$pending" == true ]]; then
    warn "SNS subscription still pending — bootstrap email not sent."
    info "After you Confirm, publish manually:"
    info "  aws sns publish --topic-arn ${topic_arn} --subject 'DroneFeed ops alerts' --message 'Subscription confirmed.'"
    return 0
  fi

  public_ip="$(terraform output -raw public_ip 2>/dev/null || true)"
  app_url="$(terraform output -raw app_url 2>/dev/null || true)"
  instance_id="$(terraform output -raw instance_id 2>/dev/null || true)"
  region="$(terraform output -raw aws_region 2>/dev/null || true)"
  name_prefix="$(terraform output -raw name_prefix 2>/dev/null || true)"
  dash_name="$(terraform output -raw ops_dashboard_name 2>/dev/null || true)"
  log_prefix="$(terraform output -raw ops_log_group_prefix 2>/dev/null || true)"

  instance_state="$(aws ec2 describe-instances --instance-ids "$instance_id" \
    --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo unknown)"
  instance_type="$(aws ec2 describe-instances --instance-ids "$instance_id" \
    --query 'Reservations[0].Instances[0].InstanceType' --output text 2>/dev/null || echo unknown)"

  if [[ "${ENABLE_SCHEDULE:-false}" == true ]]; then
    schedule_line="Weekday power: Mon–Fri ${SCHEDULE_START}:00→${SCHEDULE_STOP}:00 ${SCHEDULE_TZ} (checks ~15m after start/stop)."
  else
    schedule_line="Weekday power schedule: disabled (no schedule-miss emails)."
  fi

  if [[ "$SMOKE" == true ]]; then
    subject="[${name_prefix}] Smoke stack alerts wired"
    body="$(cat <<EOF
DroneFeed smoke-test bootstrap (ops email path works).

Stack:       ${name_prefix}
Region:      ${region}
Instance:    ${instance_id} (${instance_type}) state=${instance_state}
Public IP:   ${public_ip}
App URL:     ${app_url}

This is a smoke stack — tear down when done:
  cd deploy/terraform && ./destroy.sh

You should only receive further mail if a schedule check or budget threshold fires
during the smoke window (usually none). Console (not emailed): CloudWatch dashboard
${dash_name}, log groups under ${log_prefix}/
EOF
)"
  else
    subject="[${name_prefix}] Ops alerts active"
    body="$(cat <<EOF
DroneFeed ops alerts are active for this stack.

EC2 / heartbeat (at apply time)
  Instance:  ${instance_id} (${instance_type})
  State:     ${instance_state}
  Public IP: ${public_ip}
  App URL:   ${app_url}
  Region:    ${region}

${schedule_line}
Monthly budget: ${MONTHLY_BUDGET_USD} USD (SNS at 80% and 100% actual).

Going forward you will get email ONLY for:
  • Weekday start miss (instance not running ~15m after start)
  • Weekday stop miss / on too long (still running ~15m after stop)
  • Monthly budget thresholds (80% / 100%)
  • Root disk high (default >= 85% used)
  • Swap high (default >= 50% used — memory pressure / OOM risk)
  • Kernel OOM killer lines

Not emailed (console only):
  CloudWatch dashboard: ${dash_name}
  Log groups:           ${log_prefix}/{web,caddy,mediamtx,db,bootstrap,system}
EOF
)"
  fi

  info "Publishing bootstrap email to SNS…"
  aws sns publish \
    --topic-arn "$topic_arn" \
    --subject "$(printf '%s' "$subject" | cut -c1-100)" \
    --message "$body" >/dev/null
  info "Bootstrap email published (check ${OPS_ALERT_EMAIL})."
  echo
}

# Print + write copy-pastable values for whoever owns DNS in front of this box.
print_handoff() {
  local public_ip app_url instance_id region account name_prefix
  local maint_url maint_domain maint_dist maint_bucket
  local app_hostname ui_cf_domain ui_cf_id ui_cf_enabled
  local handoff_env="$ROOT/handoff.env"
  local handoff_txt="$ROOT/handoff.txt"
  local generated_at
  local acm_json acm_line

  public_ip="$(terraform output -raw public_ip 2>/dev/null || true)"
  app_url="$(terraform output -raw app_url 2>/dev/null || true)"
  instance_id="$(terraform output -raw instance_id 2>/dev/null || true)"
  region="$(terraform output -raw aws_region 2>/dev/null || true)"
  name_prefix="$(terraform output -raw name_prefix 2>/dev/null || true)"
  account="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)"
  generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  maint_url="$(terraform output -raw maintenance_url 2>/dev/null || true)"
  maint_domain="$(terraform output -raw maintenance_cloudfront_domain 2>/dev/null || true)"
  maint_dist="$(terraform output -raw maintenance_distribution_id 2>/dev/null || true)"
  maint_bucket="$(terraform output -raw maintenance_bucket 2>/dev/null || true)"
  app_hostname="$(terraform output -raw app_hostname 2>/dev/null || true)"
  ui_cf_domain="$(terraform output -raw ui_cloudfront_domain 2>/dev/null || true)"
  ui_cf_id="$(terraform output -raw ui_cloudfront_distribution_id 2>/dev/null || true)"
  ui_cf_enabled="$(terraform output -raw ui_cloudfront_enabled 2>/dev/null || true)"
  [[ "$maint_url" == "null" ]] && maint_url=""
  [[ "$maint_domain" == "null" ]] && maint_domain=""
  [[ "$maint_dist" == "null" ]] && maint_dist=""
  [[ "$maint_bucket" == "null" ]] && maint_bucket=""
  [[ "$app_hostname" == "null" ]] && app_hostname=""
  [[ "$ui_cf_domain" == "null" ]] && ui_cf_domain=""
  [[ "$ui_cf_id" == "null" ]] && ui_cf_id=""
  [[ "$ui_cf_enabled" == "null" ]] && ui_cf_enabled="false"

  [[ -z "$app_url" && -n "$public_ip" ]] && app_url="http://${public_ip}"

  cat >"$handoff_env" <<EOF
# Generated by setup.sh — ${generated_at}
# Gitignored. Safe to forward to whoever owns public DNS for this host.

AWS_ACCOUNT_ID=${account}
AWS_REGION=${region}
NAME_PREFIX=${name_prefix}
INSTANCE_ID=${instance_id}

# Live origin (HTTP; UI TLS terminates at CloudFront when hostname is wired)
PUBLIC_IPV4=${public_ip}
ORIGIN_HTTP_URL=${app_url}
ORIGIN_HTTP_PORT=80
ORIGIN_SCHEME=http

# Same address for media (SRT/RTSP/RTMP/UDP). Keep off UI CloudFront.
MEDIA_IPV4=${public_ip}
MEDIA_TCP_PORTS=1935,8554
MEDIA_UDP_PORTS=8890,8900-8999

# Always-on offline HTML (CloudFront → private S3). Used by Lambda@Edge when origin is down.
OFFLINE_PAGE_URL=${maint_url}
OFFLINE_CLOUDFRONT_DOMAIN=${maint_domain}
OFFLINE_CLOUDFRONT_DISTRIBUTION_ID=${maint_dist}
OFFLINE_S3_BUCKET=${maint_bucket}

APP_HOSTNAME=${app_hostname}
UI_CLOUDFRONT_DOMAIN=${ui_cf_domain}
UI_CLOUDFRONT_DISTRIBUTION_ID=${ui_cf_id}
UI_CLOUDFRONT_ENABLED=${ui_cf_enabled}
EOF

  {
    echo "DroneFeed host — DNS handoff (validation + alias only)"
    echo "Generated: ${generated_at}"
    echo
    echo "Compute account:     ${account:-unknown}"
    echo "Region:              ${region:-unknown}"
    echo "Name prefix:         ${name_prefix:-unknown}"
    echo "Instance ID:         ${instance_id:-unknown}"
    echo
    echo "--- Live origin (Spectre) ---"
    echo "Public IPv4:         ${public_ip}"
    echo "HTTP origin URL:     ${app_url}"
    echo "HTTP port:           80"
    echo
    echo "--- Media (EIP only; not CloudFront) ---"
    echo "Media IPv4:          ${public_ip}"
    echo "TCP:                 1935 (RTMP), 8554 (RTSP)"
    echo "UDP:                 8890 (SRT), 8900-8999 (MPEG-TS ingest)"
    echo
    echo "--- Offline page (already in Spectre) ---"
    if [[ -n "$maint_url" ]]; then
      echo "Offline page URL:    ${maint_url}"
      echo "CloudFront domain:   ${maint_domain}"
      echo "CloudFront ID:       ${maint_dist}"
      echo "S3 bucket:           ${maint_bucket}"
    else
      echo "Offline page:        (not provisioned)"
    fi
    echo
    if [[ -n "$app_hostname" ]]; then
      echo "--- DNS ticket (hosted-zone account) ---"
      echo "Hostname:            ${app_hostname}"
      echo "1) ACM validation CNAMEs (create these first):"
      acm_json="$(terraform output -json ui_acm_validation_records 2>/dev/null || echo '[]')"
      if command -v python3 >/dev/null 2>&1; then
        python3 - "$acm_json" <<'PY' || true
import json, sys
rows = json.loads(sys.argv[1] or "[]")
if not rows:
    print("   (none yet — terraform apply with app_hostname first)")
for r in rows:
    print(f"   {r.get('type','CNAME')}  {r.get('name','')}  →  {r.get('value','')}")
PY
      else
        echo "   (run: terraform output ui_acm_validation_records)"
      fi
      echo "2) After cert Issued in Spectre: owner sets enable_ui_cloudfront=true and re-applies."
      if [[ -n "$ui_cf_domain" ]]; then
        echo "3) Alias A/AAAA ${app_hostname} → ${ui_cf_domain} (CloudFront ${ui_cf_id})"
      else
        echo "3) Alias A/AAAA ${app_hostname} → UI CloudFront domain (from terraform output ui_cloudfront_domain after step 2)"
      fi
      echo "Do not point DNS at the S3 offline bucket. Do not reuse the offline CloudFront as the UI distribution."
    else
      echo "--- DNS ---"
      echo "No app_hostname set (IP-first). Media/publish use EIP ${public_ip}."
    fi
  } >"$handoff_txt"

  section "Operator login"
  echo "  App URL:   ${app_url}"
  echo "  Public IP: ${public_ip}"
  echo "  Admin:     ${ADMIN_EMAIL}"
  echo "  Password:  ${ADMIN_PASSWORD}"
  if [[ -n "$SSH_PRIVATE_KEY_PATH" ]]; then
    echo "  SSH:       ssh -i ${SSH_PRIVATE_KEY_PATH} ${DEPLOY_USER}@${public_ip}"
  else
    echo "  SSH:       ssh -i <private-key> ${DEPLOY_USER}@${public_ip}"
  fi
  echo

  section "Network handoff (copy/paste)"
  echo
  cat "$handoff_txt"
  echo
  info "Also wrote:"
  info "  $handoff_txt"
  info "  $handoff_env"
  echo

  if [[ -n "$maint_url" ]]; then
    GEN_DIR="$(cd "$ROOT/../maintenance" && pwd)/generated"
    mkdir -p "$GEN_DIR"
    cat >"$GEN_DIR/aws.env" <<EOF
# Written by setup.sh from terraform outputs — ${generated_at}
BUCKET=${maint_bucket}
DIST_ID=${maint_dist}
CLOUDFRONT_DOMAIN=${maint_domain}
MAINTENANCE_URL=${maint_url}
EOF
    info "Wrote $GEN_DIR/aws.env"
  fi
}

run_tf_apply() {
  echo
  info "OK — starting terraform apply..."
  info "Creates VPC/EC2/S3/CloudFront (often 2-5 min). Do not Ctrl-C."
  echo
  if [[ -f tfplan ]]; then
    terraform apply tfplan
  else
    terraform apply
  fi
  echo
  info "Done: terraform apply."
  echo
  print_handoff
  publish_ops_bootstrap_email
  if [[ "$SMOKE" == true ]]; then
    echo "Smoke test: wait for Docker build, open App URL, then destroy:"
    echo "  cd $ROOT && ./destroy.sh"
  else
    echo "Wait a few minutes for the first Docker build, then open the App URL."
    echo "CloudWatch dashboard: terraform output -raw ops_dashboard_name"
    echo "After-hours test window: ./wake.sh 4|8|12"
  fi
  echo
}

if [[ "$YES" == true ]]; then
  run_tf_init
  run_tf_plan
  run_tf_apply
else
  if prompt_yn "Run terraform init?" "$INIT_DEF"; then
    run_tf_init
  else
    echo
    info "Skipped terraform init."
    echo "Review $TFVARS then run:  cd $ROOT && terraform init && terraform plan && terraform apply"
    exit 0
  fi

  if prompt_yn "Run terraform plan?" "$PLAN_DEF"; then
    run_tf_plan
  else
    echo
    info "Skipped terraform plan. You can run:  terraform plan -out=tfplan"
  fi

  if prompt_yn "Run terraform apply now?" "$APPLY_DEF"; then
    run_tf_apply
  else
    echo
    info "Skipped terraform apply."
    echo "When ready:  cd $ROOT && terraform apply"
    if [[ -f tfplan ]]; then
      echo "  # or: terraform apply tfplan"
    fi
    echo
    echo "Admin (saved in secrets.auto.tfvars): $ADMIN_EMAIL / (see secrets file)"
  fi
fi
