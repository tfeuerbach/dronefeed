# After-hours maintenance page

When the app host (e.g. EC2) is powered off for cost savings, show a static
“down after hours” page on the HTTPS UI via **S3 + CloudFront** and edge
failover (Cloudflare Worker **or** Spectre Lambda@Edge on the UI CloudFront).

Media ports (SRT / RTSP / RTMP) cannot be faked — only the website gets this page.
Do not point DNS at the S3 bucket.

## Quick start (any self-hoster)

```bash
cd deploy/maintenance
cp config.example.env config.env   # optional; configure.sh can create it
./configure.sh                     # answer prompts (agnostic defaults)
# …S3 + CloudFront come from deploy/terraform (or create manually)…
# setup.sh writes generated/aws.env; otherwise fill it from terraform outputs
./sync.sh                          # upload rendered index.html + brand-mark.svg
```

Then wire edge failover (Path 1 or Path 2 below).

### `./configure.sh` prompts

| Prompt | Default idea |
|--------|----------------|
| Public site hostname | `dronefeed.example.com` |
| Worker route | `hostname/*` |
| Static page URL | your CloudFront `…/index.html` |
| Asset base URL | directory of that URL (for `brand-mark.svg`) |
| Origin timeout (ms) | `2500` |
| Brand / copy | `DroneFeed` + after-hours wording |

Re-render anytime without prompts:

```bash
./configure.sh --from-config
```

### Path 1 — Cloudflare

Step-by-step: **[../terraform/README.md](../terraform/README.md#path-1--cloudflare)**.  
Worker JS: [`../terraform/workers/cloudflare-worker.js`](../terraform/workers/cloudflare-worker.js).

Proxied A → EIP; Worker `MAINTENANCE_URL` = Terraform `maintenance_url`.

### Path 2 — Route 53

Step-by-step: **[../terraform/README.md](../terraform/README.md#path-2--route-53-spectre-owns-edge-dns-account-owns-records)**.

Spectre Terraform creates ACM + Lambda@Edge + UI CloudFront. DNS account only
adds ACM validation CNAMEs and an alias to `ui_cloudfront_domain`.  
Lambda source is managed by Terraform ([`../terraform/workers/`](../terraform/workers/)).

### Files

| Path | Role |
|------|------|
| `templates/` | Agnostic HTML + Worker source with `{{PLACEHOLDERS}}` |
| `config.example.env` | Documented defaults |
| `config.env` | Your answers (**gitignored**) |
| `configure.sh` | Interactive renderer |
| `index.html` / `cloudflare-worker.js` | Rendered outputs (**gitignored**) |
| `generated/` | AWS ids, checklist (**gitignored**) |
| `brand-mark.svg` | Uploaded next to `index.html` |

## AWS (Terraform)

`deploy/terraform` creates the private S3 bucket + CloudFront (OAC) and seeds a
default page. After apply:

```bash
# setup.sh writes this automatically; or by hand:
terraform -chdir=../terraform output -raw maintenance_url
```

Write `generated/aws.env` (or let `setup.sh` / `stack-info.sh` do it):

```bash
BUCKET=…
DIST_ID=…
CLOUDFRONT_DOMAIN=dxxxx.cloudfront.net
MAINTENANCE_URL=https://dxxxx.cloudfront.net/index.html
```

Then customize + re-upload:

```bash
./configure.sh   # optional branding
./sync.sh
```

Optional pretty hostname on the **offline** distribution only:
ACM DNS validation + `./attach-custom-domain.sh` (uses `DOWN_HOST` or
`down.$SITE_HOST`). That is separate from the UI hostname Path 2 above.
