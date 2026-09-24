# DroneFeed — AWS Terraform

Terraform uses **HCL** (`.tf` files), not YAML. This stack provisions compute and
network, then **auto-starts** the Docker Compose app on first boot as plain
**HTTP** on the Elastic IP — **no Route 53, no domain, no TLS**. It also creates
the **after-hours S3 + CloudFront** static page (private bucket + OAC) used when
the instance is stopped.

| Piece | Default |
|-------|---------|
| Compute | `c7i.2xlarge` Amazon Linux 2023, 80 GiB gp3 |
| Network | Dedicated VPC + public subnet + Internet Gateway |
| Address | Elastic IP on primary ENI (stable before first boot) |
| Firewall | SG: 22, 80, 443/tcp+udp, 1935, 8554, 8890/udp, 8888, 8900–8999/udp |
| IAM | Instance profile with SSM (+ optional SES send) |
| Host bootstrap | Docker + Compose, UDP sysctl, clone, stamp `.env`, `compose up` |
| After-hours | Private S3 + CloudFront OAC, seeded `index.html` + `brand-mark.svg` |
| Optional schedule | EventBridge Scheduler: start/stop Mon–Fri (e.g. 8:00–18:00 local) |

After `terraform apply`, open **`http://<public_ip>`** (not HTTPS). Admin login
is written to `/opt/drone-feed/DEPLOY.txt` on the instance. Offline page URL is
`terraform output -raw maintenance_url` (HTTPS via CloudFront’s default cert —
no domain required for that URL alone).

DNS, TLS on a hostname, and the edge worker for the offline page are **manual** —
see [Point a domain at the box + offline page](#point-a-domain-at-the-box--offline-page-post-apply).

## Quick start

**Interactive (recommended):**

```bash
cd deploy/terraform
./setup.sh
```

**Manual:**

```bash
cd deploy/terraform
cp terraform.tfvars.example terraform.tfvars
# edit: public_key or key_name, tags, git_repo_url / git_ref, …
terraform init && terraform plan && terraform apply
```

Then:

```bash
terraform output -raw app_url
# wait a few minutes for the first Docker image build
# SSH/SSM → cat /opt/drone-feed/DEPLOY.txt   # admin email + password
```

Open the URL in a browser. First boot builds images; check
`/opt/drone-feed/compose-bootstrap.log` if the page is not up yet.

## After-hours offline page (S3 + CloudFront)

Enabled by default via `./setup.sh`, which asks:

1. Create a **new** bucket or use an **existing** one?
2. Is that bucket in the **same AWS account** as EC2?
3. If **not** — bucket region + access key / secret (and optional session token),
   written to gitignored `secrets.auto.tfvars`.

CloudFront always runs in the EC2 account. S3 create/policy/objects use the
`aws.maintenance` provider (same creds or cross-account keys).

Outputs: `maintenance_url`, `maintenance_bucket`, `maintenance_distribution_id`.

`./setup.sh` also writes `deploy/maintenance/generated/aws.env` after apply.
Worker / Lambda source copies: [`workers/`](./workers/).

---

## Point a domain at the box + offline page (post-apply)

After Terraform finishes you have:

| Output | What it is |
|--------|------------|
| `public_ip` | Elastic IP of the EC2 app |
| `maintenance_url` | Offline HTML on S3/CloudFront (`https://d….cloudfront.net/index.html`) |

Pick **one** DNS path below. Both end the same way: browsers open your hostname,
hit the running app, and see the offline page when EC2 is stopped.

```bash
cd deploy/terraform
terraform output -raw public_ip          # → use as <EIP>
terraform output -raw maintenance_url    # → use as <MAINTENANCE_URL>
```

Examples below use `feeds.example.com`. For an apex domain (`example.com`), use
`@` as the Cloudflare name, or the zone apex in Route 53.

**Media note:** SRT / RTSP / RTMP must talk to the Elastic IP (or a separate
grey-cloud / non-CDN hostname). Only the **browser UI** goes through the worker.

When DNS works, update the app on the instance:

```bash
# /opt/drone-feed/deploy/.env
PHX_HOST=feeds.example.com
MEDIA_IP=<EIP>
PHX_SCHEME=https
CADDYFILE=Caddyfile
ACME_EMAIL=you@example.com
# docker compose --env-file .env up -d --force-recreate caddy web
```

---

### Path 1 — Cloudflare

Use this if the domain already uses Cloudflare nameservers.

#### 1. DNS

Cloudflare → your zone → **DNS** → Add record:

| Type | Name | Content | Proxy |
|------|------|---------|-------|
| A | `feeds` (or `@` for apex) | `<EIP>` | **Proxied** (orange) |

Optional second record for drones / pull tools (skips the Worker):

| Type | Name | Content | Proxy |
|------|------|---------|-------|
| A | `media` | `<EIP>` | **DNS only** (grey) |

SSL/TLS mode: **Flexible** while the origin is still plain HTTP; switch to
**Full** after Caddy has a Let’s Encrypt cert.

#### 2. Worker (offline routing → S3 page)

1. **Workers & Pages** → Create Worker.
2. Paste the contents of [`workers/cloudflare-worker.js`](./workers/cloudflare-worker.js).
3. **Settings → Variables** → add `MAINTENANCE_URL` = `<MAINTENANCE_URL>`.
4. **Triggers → Routes** → `feeds.example.com/*` (same hostname as the A record).
5. Deploy.

When EC2 is up, the Worker proxies to it. When EC2 is stopped, it serves the
S3/CloudFront offline page (503).

#### 3. Check

- EC2 **on**: `https://feeds.example.com` → login page.
- EC2 **off**: same URL → “down after hours” page.

---

### Path 2 — Route 53 (AWS)

Use this if DNS is in Route 53. Offline routing uses **Lambda@Edge** (same job as
the Cloudflare Worker) plus a small CloudFront distribution in front of the EIP.
Terraform does **not** create these — do them once in the console after apply.

#### 1. Certificate (ACM, must be `us-east-1`)

1. ACM → **us-east-1** → Request public certificate for `feeds.example.com`.
2. Choose DNS validation. ACM shows a CNAME — create that record in Route 53.
3. Wait until the cert status is **Issued**.

#### 2. Lambda@Edge worker (offline routing → S3 page)

1. Lambda → **us-east-1** → Create function (Node.js 18.x).
2. Open [`workers/lambda-edge-viewer-request.js`](./workers/lambda-edge-viewer-request.js).
   Set:
   - `ORIGIN_BASE` = `http://<EIP>`
   - `MAINTENANCE_URL` = `<MAINTENANCE_URL>`
3. Paste as the function code (filename `index.js`), **Deploy**, then
   **Actions → Publish new version**.
4. Role trust must allow `lambda.amazonaws.com` and `edgelambda.amazonaws.com`.

#### 3. CloudFront (sits in front of EC2)

Create a **new** distribution (not the Terraform maintenance one):

1. **Origin**: custom origin = `<EIP>`, HTTP port 80 (HTTPS later if Caddy has TLS).
2. **Default behavior**: Redirect HTTP→HTTPS; **CachingDisabled** (do not cache the app).
3. **Lambda@Edge**: Event type **viewer-request** → select the **published version** ARN.
4. **Alternate domain name (CNAME)**: `feeds.example.com`.
5. **Custom SSL certificate**: the ACM cert from step 1.
6. Create distribution; wait until **Deployed** (can take 10–15+ minutes).

#### 4. DNS

Route 53 → hosted zone → Create records:

| Type | Name | Value | Purpose |
|------|------|-------|---------|
| **A** (Alias) | `feeds.example.com` | Alias → the CloudFront distribution from step 3 | UI + offline page |
| **A** (optional) | `media.example.com` | `<EIP>` (not an alias) | SRT/RTSP/RTMP |

Also keep the ACM validation CNAME from step 1.

#### 5. Check

- EC2 **on**: `https://feeds.example.com` → login page.
- EC2 **off**: same URL → “down after hours” page.

---

## Business hours schedule

```hcl
enable_business_hours_schedule = true
schedule_timezone              = "America/New_York"
schedule_start_hour            = 8
schedule_stop_hour             = 18
```

Mon–Fri only. `./setup.sh` can enable this. Stopping the instance stops Compose;
Docker brings it back on start (`restart: unless-stopped`). Use Path 1 or 2 so
browsers get the offline page instead of a hang.

## Sizing

- ≤4 public feeds @720p → `c7i.2xlarge` (default)
- \>4 feeds or several @1080p → `c7i.4xlarge`

## What this does *not* include

- Domains / Route 53 records / ACM / Workers (manual — see Path 1 / Path 2 above)
- SES identity verification (role policy alone is not enough)

## Known constraints

- `git_ref` must be a branch or tag that includes `deploy/Caddyfile.http` and `PHX_SCHEME` support.
- `c7i.*` may be missing in some AZs — change region/AZ/type if needed.
- First `compose up --build` can take several minutes after apply.
- Validated with `terraform validate`; run `plan` in your account before apply.

## Destroy

```bash
terraform destroy
```

Destroy removes the maintenance S3/CloudFront stack as well. Delete any manual UI
CloudFront distribution, Lambda@Edge associations, and DNS records yourself.
