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
  )
  EC2_VCPU=([c7i.large]=2 [c7i.xlarge]=4 [c7i.2xlarge]=8 [c7i.4xlarge]=16 [c7i.8xlarge]=32)
  EC2_RAM_GB=([c7i.large]=4 [c7i.xlarge]=8 [c7i.2xlarge]=16 [c7i.4xlarge]=32 [c7i.8xlarge]=64)
  EC2_TYPES=(c7i.large c7i.xlarge c7i.2xlarge c7i.4xlarge c7i.8xlarge)
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
  FANOUT="n"
  RETENTION_DAYS=1
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

  ENABLE_SCHEDULE="true"
  SCHEDULE_TZ="America/New_York"
  SCHEDULE_START=8
  SCHEDULE_STOP=18

  info "Instance: $INSTANCE_TYPE + ${ROOT_GB} GiB @ $AWS_REGION (name_prefix=$NAME_PREFIX)"
}

hr() { printf '%s\n' "--------------------------------------------------------"; }

section() {
  echo
  hr
  echo " $1"
  hr
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
  echo "$q" >&2
  for i in "${!opts[@]}"; do
    mark=" "
    [[ $((i + 1)) -eq "$def" ]] && mark="*"
    printf '  %s%d) %s\n' "$mark" "$((i + 1))" "${opts[$i]}" >&2
  done
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

recommend_instance() {
  local feeds="$1" height="$2" users="$3" fanout="$4"
  local weight="$feeds"
  case "$height" in
    1080) weight=$((feeds * 2)) ;;
    source) weight=$((feeds * 3)) ;;
  esac
  [[ "$fanout" == y ]] && weight=$((weight + 2))
  ((users > 25)) && weight=$((weight + 1))
  if ((weight <= 2)); then
    echo "c7i.xlarge"
  elif ((weight <= 4)); then
    echo "c7i.2xlarge"
  elif ((weight <= 8)); then
    echo "c7i.4xlarge"
  else
    echo "c7i.8xlarge"
  fi
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
hr
echo " DroneFeed - AWS setup wizard"
hr
info "IP-first stack (HTTP on Elastic IP). DNS/HTTPS optional later."
info "Writes gitignored terraform.tfvars + secrets.auto.tfvars."
if [[ -n "${AWS_PROFILE:-}" ]]; then
  info "AWS_PROFILE:  $AWS_PROFILE"
fi
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
else

# ── 1 tags ───────────────────────────────────────────────────────────────────
section "1/8  Project identity (tags - editable later via tfvars + apply)"
PROJECT="$(prompt "Project tag" "dronefeed")"
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
echo
info "Public feeds are continuous CPU encodes (libx264). CPU is usually the limit."
info "Typical prod: <=4 feeds @720p -> c7i.2xlarge. More / 1080p -> c7i.4xlarge+."
echo

FEEDS="$(prompt "Peak concurrent public feeds (live + VOD republish)" "2")"
[[ "$FEEDS" =~ ^[0-9]+$ ]] && ((FEEDS >= 1)) || die "feeds must be a positive integer"

HEIGHT="$(pick 1 "Typical public output resolution" \
  "720 - default CBR-ish encode (recommended)" \
  "1080 - heavier CPU per feed" \
  "source - keep source resolution (highest CPU)")"

UI_USERS="$(prompt "Peak concurrent UI users (browsers, not SRT viewers)" "5")"
[[ "$UI_USERS" =~ ^[0-9]+$ ]] || die "UI users must be an integer"

FANOUT="n"
prompt_yn "Heavy fan-out? (many simultaneous SRT/RTSP/RTMP pullers on fat streams)" n && FANOUT="y"

RETENTION_DAYS="$(prompt "Recording retention days to size disk for" "5")"
[[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]] && ((RETENTION_DAYS >= 1)) || die "retention days must be a positive integer"

REC_HOURS_HINT=10
REC_INSTANCE="$(resolve_instance_type "$(recommend_instance "$FEEDS" "$HEIGHT" "$UI_USERS" "$FANOUT")")"
REC_ROOT="$(recommend_root_gb "$FEEDS" "$HEIGHT" "$RETENTION_DAYS" "$REC_HOURS_HINT")"

echo
info "Recommendation for ~${FEEDS} feeds @${HEIGHT}, ${UI_USERS} UI users, ${RETENTION_DAYS}-day retention:"
info "  Instance: ${REC_INSTANCE}  (${EC2_VCPU[$REC_INSTANCE]:-?} vCPU / ${EC2_RAM_GB[$REC_INSTANCE]:-?} GiB)"
if [[ -n "${EC2_USD_HR[$REC_INSTANCE]+x}" ]]; then
  info "  On-demand: \$${EC2_USD_HR[$REC_INSTANCE]}/hr"
fi
info "  Root disk: ${REC_ROOT} GiB gp3"
echo

declare -a INST_OPTS=()
INST_OPTS+=("${REC_INSTANCE} - recommended")
local_note_for() {
  case "$1" in
    c7i.large) echo "smoke / idle only" ;;
    c7i.xlarge) echo "light demos (1-2 @720p)" ;;
    c7i.2xlarge) echo "typical prod (<=4 @720p)" ;;
    c7i.4xlarge) echo ">4 feeds or several @1080p" ;;
    c7i.8xlarge) echo "heavy / many encodes" ;;
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

AZ="$(prompt "Availability zone (blank = first in region)" "")"

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

echo
info "AWS Session Manager is a backup way to open a shell in the AWS console"
info "if SSH is blocked (no extra key needed). Recommended: yes."
prompt_yn "Enable that backup login (SSM)?" y || ENABLE_SSM="false"

echo
info "Who is allowed to SSH (terminal login) to the server?"
info "Recommended: only your current internet connection."
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
if prompt_yn "Allow the website and video ports from the whole internet?" y; then
  MEDIA_CIDR="0.0.0.0/0"
else
  MEDIA_CIDR="$(prompt "IP or range allowed for web/video" "0.0.0.0/0")"
fi

# ── 4 admin ──────────────────────────────────────────────────────────────────
section "4/8  Admin login (printed after apply)"
ADMIN_EMAIL="$(prompt "Admin email" "admin@dronefeed.local")"
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
GIT_REPO="$(prompt "Git clone URL" "https://github.com/tfeuerbach/dronefeed.git")"
GIT_REF="$(prompt "Git branch or tag (needs Caddyfile.http + runtime PHX_SCHEME/force_ssl)" "master")"
DEPLOY_USER="$(prompt "Linux deploy user" "dronefeed")"

# ── 6 email / EIP ────────────────────────────────────────────────────────────
section "6/8  Email + Elastic IP"
ENABLE_SES="false"
prompt_yn "Attach SES send policy / plan to use outbound email later?" n && ENABLE_SES="true"

ASSOCIATE_EIP="true"
prompt_yn "Allocate Elastic IP (recommended for IP-first)?" y || ASSOCIATE_EIP="false"

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
  info "Offline HTML lives in S3; CloudFront serves it when you wire DNS failover later."
  if prompt_yn "Create a new S3 bucket for the offline page?" y; then
    MAINT_CREATE="true"
    MAINT_BUCKET="$(prompt "New bucket name (blank = ${NAME_PREFIX}-after-hours-<account_id>)" "")"
  else
    MAINT_CREATE="false"
    MAINT_BUCKET="$(prompt "Existing S3 bucket name" "")"
    [[ -n "$MAINT_BUCKET" ]] || die "existing bucket name is required"
    info "Terraform will set this buckets policy for CloudFront OAC (replaces bucket policy)."
  fi

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
  SCHEDULE_TZ="$(prompt "Timezone (IANA)" "America/New_York")"
  SCHEDULE_START="$(prompt "Start hour Mon-Fri (0-23, local)" "8")"
  SCHEDULE_STOP="$(prompt "Stop hour Mon-Fri (0-23, local)" "18")"
  [[ "$SCHEDULE_START" =~ ^[0-9]+$ && "$SCHEDULE_STOP" =~ ^[0-9]+$ ]] || die "hours must be integers"
  ((SCHEDULE_START >= 0 && SCHEDULE_START <= 23)) || die "start hour out of range"
  ((SCHEDULE_STOP >= 0 && SCHEDULE_STOP <= 23)) || die "stop hour out of range"
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
info "Workload: ${FEEDS} feeds @${HEIGHT}, ${UI_USERS} UI users, retain ${RETENTION_DAYS}d"
info "Compute:  $INSTANCE_TYPE + ${ROOT_GB} GiB gp3 @ $AWS_REGION"
info "Admin:    $ADMIN_EMAIL"
info "SES/email: $ENABLE_SES"
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

# Print + write copy-pastable values for whoever owns DNS / edge in front of this box.
print_handoff() {
  local public_ip app_url instance_id region account name_prefix
  local maint_url maint_domain maint_dist maint_bucket
  local handoff_env="$ROOT/handoff.env"
  local handoff_txt="$ROOT/handoff.txt"
  local generated_at

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
  [[ "$maint_url" == "null" ]] && maint_url=""
  [[ "$maint_domain" == "null" ]] && maint_domain=""
  [[ "$maint_dist" == "null" ]] && maint_dist=""
  [[ "$maint_bucket" == "null" ]] && maint_bucket=""

  [[ -z "$app_url" && -n "$public_ip" ]] && app_url="http://${public_ip}"

  cat >"$handoff_env" <<EOF
# Generated by setup.sh — ${generated_at}
# Gitignored. Safe to forward to whoever owns public DNS / edge for this host.

AWS_ACCOUNT_ID=${account}
AWS_REGION=${region}
NAME_PREFIX=${name_prefix}
INSTANCE_ID=${instance_id}

# Live origin (plain HTTP today; TLS only after a hostname is attached on-box)
PUBLIC_IPV4=${public_ip}
ORIGIN_HTTP_URL=${app_url}
ORIGIN_HTTP_PORT=80
ORIGIN_SCHEME=http

# Same address for media (SRT/RTSP/RTMP/UDP). Prefer a separate DNS-only name.
MEDIA_IPV4=${public_ip}
MEDIA_TCP_PORTS=1935,8554
MEDIA_UDP_PORTS=8890,8900-8999

# Always-on offline HTML (CloudFront → private S3). Use when origin is unreachable.
OFFLINE_PAGE_URL=${maint_url}
OFFLINE_CLOUDFRONT_DOMAIN=${maint_domain}
OFFLINE_CLOUDFRONT_DISTRIBUTION_ID=${maint_dist}
OFFLINE_S3_BUCKET=${maint_bucket}
EOF

  {
    echo "DroneFeed host — network handoff"
    echo "Generated: ${generated_at}"
    echo
    echo "Compute account:     ${account:-unknown}"
    echo "Region:              ${region:-unknown}"
    echo "Name prefix:         ${name_prefix:-unknown}"
    echo "Instance ID:         ${instance_id:-unknown}"
    echo
    echo "--- Live origin ---"
    echo "Public IPv4:         ${public_ip}"
    echo "HTTP origin URL:     ${app_url}"
    echo "HTTP port:           80"
    echo "TLS on origin today: no (http:// only until a hostname is configured on the box)"
    echo
    echo "--- Media (same IPv4; keep off HTTP-only proxies) ---"
    echo "Media IPv4:          ${public_ip}"
    echo "TCP:                 1935 (RTMP), 8554 (RTSP)"
    echo "UDP:                 8890 (SRT), 8900-8999 (MPEG-TS ingest)"
    echo
    echo "--- Offline page (up when EC2 is stopped) ---"
    if [[ -n "$maint_url" ]]; then
      echo "Offline page URL:    ${maint_url}"
      echo "CloudFront domain:   ${maint_domain}"
      echo "CloudFront ID:       ${maint_dist}"
      echo "S3 bucket:           ${maint_bucket}"
    else
      echo "Offline page:        (not provisioned)"
    fi
    echo
    echo "--- Record targets (hostname chosen by DNS owner) ---"
    echo "App hostname     →  ${public_ip}   (or edge in front of ${app_url})"
    echo "Media hostname   →  ${public_ip}   (DNS-only / non-proxied; UDP+TCP media ports)"
    if [[ -n "$maint_url" ]]; then
      echo "When origin down  →  ${maint_url}"
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
  if [[ "$SMOKE" == true ]]; then
    echo "Smoke test: wait for Docker build, open App URL, then destroy:"
    echo "  cd $ROOT && terraform destroy"
  else
    echo "Wait a few minutes for the first Docker build, then open the App URL."
    echo "After-hours test window: ./wake.sh 4|8|12|24"
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
