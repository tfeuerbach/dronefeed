# After-hours maintenance page

When the app host (e.g. EC2) is powered off for cost savings, show a static
“down after hours” page on the HTTPS UI via **S3 + CloudFront** and a
**Cloudflare Worker** failover.

Media ports (SRT / RTSP / RTMP) cannot be faked — only the website gets this page.

## Quick start (any self-hoster)

```bash
cd deploy/maintenance
cp config.example.env config.env   # optional; configure.sh can create it
./configure.sh                     # answer prompts (agnostic defaults)
# …S3 + CloudFront come from deploy/terraform (or create manually)…
# setup.sh writes generated/aws.env; otherwise fill it from terraform outputs
./sync.sh                          # upload rendered index.html + brand-mark.svg
```

Then follow `generated/cloudflare-checklist.md` (written by `configure.sh`).

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

### Cloudflare (once)

Step-by-step: **[../terraform/README.md](../terraform/README.md#path-1--cloudflare)**.  
Worker JS: [`../terraform/workers/cloudflare-worker.js`](../terraform/workers/cloudflare-worker.js).

### Route 53 (once)

Step-by-step: **[../terraform/README.md](../terraform/README.md#path-2--route-53-aws)**.  
Lambda@Edge JS: [`../terraform/workers/lambda-edge-viewer-request.js`](../terraform/workers/lambda-edge-viewer-request.js).

### Files

| Path | Role |
|------|------|
| `templates/` | Agnostic HTML + Worker source with `{{PLACEHOLDERS}}` |
| `config.example.env` | Documented defaults |
| `config.env` | Your answers (**gitignored**) |
| `configure.sh` | Interactive renderer |
| `index.html` / `cloudflare-worker.js` | Rendered outputs (**gitignored** — may include your hostname/CDN URL) |
| `generated/` | AWS ids, ACM records, checklist (**gitignored**) |
| `brand-mark.svg` | Uploaded next to `index.html` |

## AWS (Terraform)

`deploy/terraform` creates the private S3 bucket + CloudFront (OAC) and seeds a
default page. After apply:

```bash
# setup.sh writes this automatically; or by hand:
terraform -chdir=../terraform output -raw maintenance_url
```

Write `generated/aws.env` (or let `setup.sh` do it):

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

Optional pretty hostname: ACM DNS validation + `./attach-custom-domain.sh`
(uses `DOWN_HOST` or `down.$SITE_HOST`).
