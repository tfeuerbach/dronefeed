#!/usr/bin/env bash
# Interactive (or --defaults) renderer for after-hours maintenance assets.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE_DIR="$DIR/templates"
OUT_DIR="$DIR/generated"
CONFIG="$DIR/config.env"
EXAMPLE="$DIR/config.example.env"

mkdir -p "$OUT_DIR"

prompt() {
  # prompt VAR "Question" "default"
  local var="$1" question="$2" default="${3:-}"
  local value=""
  if [[ -n "${!var:-}" && "$USE_EXISTING" == "1" ]]; then
    return 0
  fi
  if [[ "$NONINTERACTIVE" == "1" ]]; then
    printf -v "$var" '%s' "$default"
    return 0
  fi
  if [[ -n "$default" ]]; then
    read -r -p "$question [$default]: " value || true
    printf -v "$var" '%s' "${value:-$default}"
  else
    read -r -p "$question: " value || true
    printf -v "$var" '%s' "$value"
  fi
}

load_env_file() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  # shellcheck disable=SC1090
  set -a
  # shellcheck disable=SC1091
  source "$file"
  set +a
}

escape_sed() {
  printf '%s' "$1" | sed -e 's/[\/&]/\\&/g'
}

render() {
  local src="$1" dest="$2"
  local tmp
  tmp="$(mktemp)"
  cp "$src" "$tmp"
  local key val
  for key in \
    SITE_HOST WORKER_ROUTE WORKER_NAME MAINTENANCE_URL ASSET_BASE_URL \
    ORIGIN_TIMEOUT_MS BRAND_NAME PAGE_TITLE PAGE_EYEBROW PAGE_HEADLINE \
    PAGE_LEDE PAGE_META FALLBACK_TEXT
  do
    val="${!key-}"
    # Escape for sed replacement
    val="$(escape_sed "$val")"
    sed -i "s/{{$key}}/$val/g" "$tmp"
  done
  if grep -q '{{' "$tmp"; then
    echo "error: unreplaced placeholders remain in $dest:" >&2
    grep -n '{{' "$tmp" >&2 || true
    rm -f "$tmp"
    exit 1
  fi
  mv "$tmp" "$dest"
}

NONINTERACTIVE=0
USE_EXISTING=0
for arg in "$@"; do
  case "$arg" in
    --defaults|--yes|-y) NONINTERACTIVE=1 ;;
    --from-config) USE_EXISTING=1; NONINTERACTIVE=1 ;;
    -h|--help)
      cat <<EOF
Usage: ./configure.sh [--from-config|--defaults]

  (no flags)     Ask questions; blank keeps the shown default
  --from-config  Re-render from existing config.env (no prompts)
  --defaults     Render using config.example.env values only

Writes:
  config.env
  index.html
  cloudflare-worker.js
  generated/cloudflare-checklist.md
EOF
      exit 0
      ;;
  esac
done

# Seed defaults from example, then overlay existing config
load_env_file "$EXAMPLE"
if [[ -f "$CONFIG" ]]; then
  load_env_file "$CONFIG"
fi

echo "DroneFeed after-hours maintenance — configure"
echo "Leave blank to keep the default in [brackets]."
echo

if [[ "$USE_EXISTING" != "1" ]]; then
  prompt SITE_HOST "Public site hostname" "${SITE_HOST:-dronefeed.example.com}"
  prompt WORKER_ROUTE "Cloudflare Worker route" "${WORKER_ROUTE:-${SITE_HOST}/*}"
  prompt WORKER_NAME "Cloudflare Worker name" "${WORKER_NAME:-dronefeed-after-hours}"
  prompt MAINTENANCE_URL "Static page URL (CloudFront/S3 HTTPS index.html)" \
    "${MAINTENANCE_URL:-https://YOUR_DISTRIBUTION.cloudfront.net/index.html}"

  default_asset="${ASSET_BASE_URL:-}"
  if [[ -z "$default_asset" && -n "${MAINTENANCE_URL:-}" ]]; then
    default_asset="$(dirname "$MAINTENANCE_URL")"
  fi
  prompt ASSET_BASE_URL "Asset base URL for brand-mark.svg" "$default_asset"
  prompt ORIGIN_TIMEOUT_MS "Origin timeout before maintenance page (ms)" \
    "${ORIGIN_TIMEOUT_MS:-2500}"
  prompt BRAND_NAME "Brand / product name" "${BRAND_NAME:-DroneFeed}"
  prompt PAGE_TITLE "HTML <title>" "${PAGE_TITLE:-${BRAND_NAME} is down after hours}"
  prompt PAGE_EYEBROW "Eyebrow label" "${PAGE_EYEBROW:-Service offline}"
  prompt PAGE_HEADLINE "Headline" "${PAGE_HEADLINE:-${BRAND_NAME} is down after hours}"
  prompt PAGE_LEDE "Supporting sentence" \
    "${PAGE_LEDE:-The app server is powered off to save cost. Feeds, uploads, and pull URLs will be back when the host is started again.}"
  prompt PAGE_META "Meta note (HTML allowed)" \
    "${PAGE_META:-<strong>HTTP UI only.</strong> SRT / RTSP / RTMP ingest and pull stay unreachable until the instance is running.}"
  prompt FALLBACK_TEXT "Plain-text fallback if MAINTENANCE_URL is unset" \
    "${FALLBACK_TEXT:-${BRAND_NAME} is down after hours}"
fi

# Normalize
ASSET_BASE_URL="${ASSET_BASE_URL%/}"
MAINTENANCE_URL="${MAINTENANCE_URL%/}"
[[ "$MAINTENANCE_URL" == *.html ]] || MAINTENANCE_URL="${MAINTENANCE_URL%/}/index.html"
if [[ -z "${ASSET_BASE_URL:-}" ]]; then
  ASSET_BASE_URL="$(dirname "$MAINTENANCE_URL")"
fi
WORKER_ROUTE="${WORKER_ROUTE:-${SITE_HOST}/*}"
ORIGIN_TIMEOUT_MS="${ORIGIN_TIMEOUT_MS:-2500}"

export SITE_HOST WORKER_ROUTE WORKER_NAME MAINTENANCE_URL ASSET_BASE_URL
export ORIGIN_TIMEOUT_MS BRAND_NAME PAGE_TITLE PAGE_EYEBROW PAGE_HEADLINE
export PAGE_LEDE PAGE_META FALLBACK_TEXT

# Persist config.env (quote values — PAGE_META may contain HTML)
python3 - "$CONFIG" <<'PY'
import os, shlex, sys

path = sys.argv[1]
keys = [
    "SITE_HOST", "WORKER_ROUTE", "WORKER_NAME", "MAINTENANCE_URL", "ASSET_BASE_URL",
    "ORIGIN_TIMEOUT_MS", "BRAND_NAME", "PAGE_TITLE", "PAGE_EYEBROW", "PAGE_HEADLINE",
    "PAGE_LEDE", "PAGE_META", "FALLBACK_TEXT",
]
lines = ["# Generated by configure.sh — safe to edit and re-run: ./configure.sh --from-config"]
for key in keys:
    lines.append(f"{key}={shlex.quote(os.environ.get(key, ''))}")
open(path, "w", encoding="utf-8").write("\n".join(lines) + "\n")
print(f"wrote {path}")
PY

render "$TEMPLATE_DIR/index.html" "$DIR/index.html"
render "$TEMPLATE_DIR/cloudflare-worker.js" "$DIR/cloudflare-worker.js"
cp "$DIR/index.html" "$OUT_DIR/index.html"
cp "$DIR/cloudflare-worker.js" "$OUT_DIR/cloudflare-worker.js"

cat > "$OUT_DIR/cloudflare-checklist.md" <<EOF
# Cloudflare checklist (generated)

## DNS
| Type | Name | Content | Proxy |
|------|------|---------|--------|
| A | (host of \`$SITE_HOST\`) | your Elastic IP | **Proxied** (orange) |

## Worker
1. Create Worker named **\`$WORKER_NAME\`**
2. Paste code from \`deploy/maintenance/cloudflare-worker.js\`
3. Settings → Variables → \`MAINTENANCE_URL\` = \`$MAINTENANCE_URL\`
4. Domains / Routes → \`$WORKER_ROUTE\`

## Preview static page
$MAINTENANCE_URL

## Wrangler vars snippet
\`\`\`jsonc
{
  "name": "$WORKER_NAME",
  "main": "cloudflare-worker.js",
  "compatibility_date": "2024-01-01",
  "vars": {
    "MAINTENANCE_URL": "$MAINTENANCE_URL"
  }
}
\`\`\`
EOF

echo
echo "Wrote:"
echo "  $CONFIG"
echo "  $DIR/index.html"
echo "  $DIR/cloudflare-worker.js"
echo "  $OUT_DIR/cloudflare-checklist.md"
echo
echo "Next: upload with ./sync.sh (needs generated/aws.env), then paste the Worker in Cloudflare."
echo "Checklist: $OUT_DIR/cloudflare-checklist.md"
