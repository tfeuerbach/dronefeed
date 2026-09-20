#!/usr/bin/env bash
# Re-upload the after-hours page to S3 and invalidate CloudFront.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
AWS_ENV="$DIR/generated/aws.env"
CONFIG="$DIR/config.env"

if [[ ! -f "$DIR/index.html" ]]; then
  echo "No index.html — run ./configure.sh first." >&2
  exit 1
fi

if [[ ! -f "$AWS_ENV" ]]; then
  cat >&2 <<EOF
Missing $AWS_ENV

Create it after you provision S3 + CloudFront, for example:

  BUCKET=your-bucket-name
  DIST_ID=E1234567890
  CLOUDFRONT_DOMAIN=dxxxx.cloudfront.net
  MAINTENANCE_URL=https://dxxxx.cloudfront.net/index.html

Or copy generated values from your AWS setup. See README.md.
EOF
  exit 1
fi

# shellcheck disable=SC1091
source "$AWS_ENV"

# Prefer MAINTENANCE_URL from config.env when present
if [[ -f "$CONFIG" ]]; then
  # shellcheck disable=SC1091
  source "$CONFIG"
fi

: "${BUCKET:?BUCKET required in generated/aws.env}"
: "${DIST_ID:?DIST_ID required in generated/aws.env}"
MAINTENANCE_URL="${MAINTENANCE_URL:-https://${CLOUDFRONT_DOMAIN}/index.html}"

aws s3 cp "$DIR/index.html" "s3://$BUCKET/index.html" \
  --content-type "text/html; charset=utf-8" \
  --cache-control "public, max-age=60"
aws s3 cp "$DIR/brand-mark.svg" "s3://$BUCKET/brand-mark.svg" \
  --content-type "image/svg+xml" \
  --cache-control "public, max-age=86400"

aws cloudfront create-invalidation --distribution-id "$DIST_ID" --paths "/*" \
  --query 'Invalidation.Id' --output text

echo "MAINTENANCE_URL=$MAINTENANCE_URL"
curl -sI "$MAINTENANCE_URL" | head -8
