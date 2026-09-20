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
# …provision S3 + CloudFront, write generated/aws.env…
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

1. DNS **A** for your site → Elastic IP, **Proxied** (orange cloud).  
   Grey-cloud DNS bypasses Workers and will hang when the origin is off.
2. Create a Worker, paste generated `cloudflare-worker.js`.
3. Variable: `MAINTENANCE_URL` = your static `index.html` URL.
4. Route: `your.site/*`.

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

## AWS sketch

1. S3 bucket (private) + CloudFront OAC in front of it.  
2. Upload via `./sync.sh` after `generated/aws.env` exists:

```bash
BUCKET=…
DIST_ID=…
CLOUDFRONT_DOMAIN=dxxxx.cloudfront.net
MAINTENANCE_URL=https://dxxxx.cloudfront.net/index.html
```

3. Optional pretty hostname: ACM DNS validation + `./attach-custom-domain.sh`
   (uses `DOWN_HOST` or `down.$SITE_HOST`).
