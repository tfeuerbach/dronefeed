#!/usr/bin/env bash
# After ACM DNS is validated, attach an optional pretty hostname to CloudFront.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
AWS_ENV="$DIR/generated/aws.env"
CONFIG="$DIR/config.env"
ACM_JSON="$DIR/generated/acm-validation.json"

# shellcheck disable=SC1091
source "$AWS_ENV"
if [[ -f "$CONFIG" ]]; then
  # shellcheck disable=SC1091
  source "$CONFIG"
fi

DOWN_HOST="${DOWN_HOST:-down.${SITE_HOST:-dronefeed.example.com}}"

: "${DIST_ID:?}"
: "${CERT_ARN:?Set CERT_ARN in generated/aws.env}"
: "${CLOUDFRONT_DOMAIN:?}"

STATUS=$(aws acm describe-certificate --region us-east-1 --certificate-arn "$CERT_ARN" \
  --query 'Certificate.Status' --output text)
echo "ACM status: $STATUS"
if [ "$STATUS" != "ISSUED" ]; then
  echo "Certificate not issued yet. Add the Cloudflare ACM CNAME first."
  [[ -f "$ACM_JSON" ]] && cat "$ACM_JSON"
  exit 1
fi

aws cloudfront get-distribution-config --id "$DIST_ID" > /tmp/df-dist.json
ETAG=$(python3 -c "import json; print(json.load(open('/tmp/df-dist.json'))['ETag'])")

python3 - "$DOWN_HOST" "$CERT_ARN" <<'PY'
import json, sys
down_host, cert_arn = sys.argv[1], sys.argv[2]
raw = json.load(open("/tmp/df-dist.json"))
cfg = raw["DistributionConfig"]
cfg["Aliases"] = {"Quantity": 1, "Items": [down_host]}
cfg["ViewerCertificate"] = {
    "ACMCertificateArn": cert_arn,
    "SSLSupportMethod": "sni-only",
    "MinimumProtocolVersion": "TLSv1.2_2021",
    "Certificate": cert_arn,
    "CertificateSource": "acm",
}
json.dump(cfg, open("/tmp/df-dist-update.json", "w"))
print("aliases", cfg["Aliases"])
PY

aws cloudfront update-distribution --id "$DIST_ID" --if-match "$ETAG" \
  --distribution-config file:///tmp/df-dist-update.json \
  --query 'Distribution.{Id:Id,Status:Status,Domain:DomainName}' --output table

echo
echo "Add Cloudflare DNS (DNS only / grey cloud):"
echo "  CNAME  ${DOWN_HOST%%.*}  →  $CLOUDFRONT_DOMAIN"
echo "  (full host: $DOWN_HOST)"
echo
echo "Then: https://$DOWN_HOST"
