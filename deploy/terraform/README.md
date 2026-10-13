# DroneFeed AWS Terraform

IP-first host: VPC, EC2, Elastic IP, Docker Compose on plain HTTP, weekday
power schedule (Mon–Fri 8:00–18:00 local), and an S3 + CloudFront offline page.
No Route 53, ACM, or domain is created here.

| | |
|--|--|
| App URL | `http://<elastic-ip>` |
| SSH | `dronefeed` + key from setup |
| Schedule | Mon–Fri 8–18; after hours: `./wake.sh 4\|8\|12` (max 12h) |
| Offline page | `terraform output -raw maintenance_url` |
| Email | Off by default |

## Prerequisites

1. AWS credentials for the target account (profile or env):

   ```bash
   aws sts get-caller-identity --profile spectre
   # or pass the profile into setup (see below)
   ```

2. Tools: `terraform`, `aws`, `openssl`, `ssh-keygen`, `python3` (live instance
   prices in `./setup.sh`; falls back to a static table without it).

3. Push the git ref the instance will clone (`master` by default). First boot
   clones that ref — local-only changes are ignored. The ref needs
   `deploy/Caddyfile.http` and runtime `PHX_SCHEME` / `force_ssl` (HTTP mode
   must not force HTTPS at compile time).

First boot also enables Amazon Linux **security-only** auto-updates
(`dnf-automatic-install` + `releasever=latest`). App/container updates stay
manual.

## Setup

```bash
cd deploy/terraform
./setup.sh                    # menu: guided or smoke
./setup.sh -s -p spectre      # smoke in that profile's account
./setup.sh -s -p spectre -y   # same, skip init/plan/apply prompts
```

| Flag | Meaning |
|------|---------|
| `-s` / `--smoke` | Cheapest stack (`dronefeed-smoke`) — Terraform check, not for video |
| `-p` / `--aws-profile NAME` | Use that AWS shared profile (`AWS_PROFILE`) |
| `-y` / `--yes` | Auto-yes to terraform init / plan / apply prompts |
| `-h` / `--help` | Help |

If STS fails with an SSO profile, run `aws sso login --profile <name>` and retry.

Smoke uses `name_prefix=dronefeed-smoke`. Tear down with [`./destroy.sh`](#destroy) when done.

Guided flow: tags → workload sizing → SSH → admin → repo → email/EIP → offline
page → schedule → init/plan/apply. Instance type and disk you pick are what
apply creates. `./setup.sh` loads live `c7i` types and on-demand/gp3 prices for
the region (Pricing API); estimates only — egress not included.

Writes gitignored `terraform.tfvars` + `secrets.auto.tfvars`, and an SSH key
(`~/.ssh/*.pub` or `keys/`). Defaults: schedule on, EIP on, SES off, maintenance
page on (new bucket, same account).

Apply prints operator login plus a copy-pastable **network handoff** block
(public IP, HTTP origin, media ports, offline CloudFront URL) and writes
gitignored `handoff.txt` / `handoff.env`. Admin credentials also live in
`secrets.auto.tfvars` and `/opt/drone-feed/DEPLOY.txt` on the host.

## After apply

1. Wait for the first Docker build:

   ```bash
   ssh -i <key> dronefeed@<eip> 'tail -f /opt/drone-feed/compose-bootstrap.log'
   ```

2. Open `http://<eip>` and sign in with the setup admin.

3. Offline page URL (always up; stopping EC2 does not change DNS):

   ```bash
   terraform output -raw maintenance_url
   ```

## After-hours wake

Use the same `-p` profile as apply. Hours are **1–12** (no 24h wakes):

```bash
./wake.sh -p spectre 4
./wake.sh -p spectre 12
./wake.sh -p spectre --status
./wake.sh -p spectre --restore-schedule
```

Behavior:

- **Weekend / pure after-hours:** start now, one-shot stop after N hours.
- **Wake overlaps a weekday start** (e.g. 6am for 4h with 8:00 business start),
  **or you wake during business hours:** no wake timer. Weekday schedule takes
  over — instance stays up until the normal weekday stop (e.g. 18:00), not N
  hours after the wake command.

## Domain and HTTPS (optional, often another account)

Not needed for IP-first. For `https://dronefeed.example.com`, configure DNS in
the account that owns the hosted zone.

### How offline works

Stopping EC2 does not change DNS. Do not point DNS at the S3 bucket. The offline
HTML is on CloudFront (`maintenance_url`). Failover is at the edge (Cloudflare
Worker or Lambda@Edge): try the live app; if EC2 is down, return that HTML.

Media (SRT/RTSP/RTMP) must use the Elastic IP or a DNS-only hostname — not a
proxied Cloudflare / UI-CloudFront hostname (HTTP(S) only).

### Handoff (EC2 account → DNS admin)

```bash
cd deploy/terraform
terraform output -raw public_ip
terraform output -raw maintenance_url
```

Also give them the hostname (e.g. `dronefeed.ecsdevlabs.com`).

### On the EC2 box after the hostname works

```bash
# /opt/drone-feed/deploy/.env
PHX_HOST=dronefeed.example.com
MEDIA_IP=<EIP>
MEDIA_HOST=media.dronefeed.example.com   # optional DNS-only → EIP
PHX_SCHEME=https
CADDYFILE=Caddyfile
ACME_EMAIL=you@example.com
# docker compose --env-file .env up -d --force-recreate caddy web
```

### Path 1 — Cloudflare

| Type | Name | Content | Proxy |
|------|------|---------|-------|
| A | `feeds` (or `@`) | `<EIP>` | Proxied |
| A (optional) | `media` | `<EIP>` | DNS only |

1. Create a Worker; paste [`workers/cloudflare-worker.js`](./workers/cloudflare-worker.js).
2. Variable `MAINTENANCE_URL` = `maintenance_url` from Terraform.
3. Route: `feeds.example.com/*`.

### Path 2 — Route 53 (other AWS account)

In the DNS account:

1. **ACM** in `us-east-1`: cert for the hostname; validate in Route 53; wait until Issued.
2. **Lambda@Edge** (Node 18, `us-east-1`): paste
   [`workers/lambda-edge-viewer-request.js`](./workers/lambda-edge-viewer-request.js);
   set `ORIGIN_BASE=http://<public_ip>` and `MAINTENANCE_URL=<maintenance_url>`;
   publish a version (not `$LATEST`).
3. **CloudFront** (new UI distribution — not the Terraform maintenance one): origin
   EIP:80; caching off; viewer-request → that Lambda version; alternate domain + ACM cert.
4. **Route 53**: Alias A/AAAA hostname → that CloudFront; optional `media` A → EIP.
5. Check: instance up → app; instance stopped → offline HTML; `maintenance_url` still works.
6. Switch the box to HTTPS (`.env` above) once DNS resolves.

Route 53 health-check failover to S3 is a worse fit here (certs + media still on
the EIP). Edge failover matches the private S3 + CloudFront OAC offline page.

Workers: [`workers/README.md`](./workers/README.md).

## Schedule and sizing

```hcl
enable_business_hours_schedule = true
schedule_timezone              = "America/New_York"
schedule_start_hour            = 8
schedule_stop_hour             = 18
```

| Workload | Instance |
|----------|----------|
| Smoke / idle only | `c7i.large` |
| 1–2 feeds @720p | `c7i.xlarge` |
| ≤4 @720p (typical) | `c7i.2xlarge` |
| More feeds or several @1080p | `c7i.4xlarge`+ |

Disk: 80–200+ GiB gp3 from retention (wizard estimates from feeds × hours × days).

## Not included

- Domains / Route 53 / ACM (Path 1 or 2 above)
- SES identity verification
- Remote Terraform state (keep `terraform.tfstate` safe)

## Constraints

- `git_ref` must be pushed before apply.
- Clone URL must be reachable from the instance.
- `c7i.*` may be missing in some AZs.
- First `compose up --build` can take several minutes.

## Destroy

Tear down everything in **this directory’s Terraform state** (the stack you
applied from here):

```bash
cd deploy/terraform
./destroy.sh -p spectre        # prompts for “yes”
./destroy.sh -p spectre -y     # terraform destroy -auto-approve
```

`./destroy.sh` will:

1. Export `-p` / `--aws-profile` (same as setup/wake)
2. Show account identity + `name_prefix` / instance / IP from state
3. Run `terraform destroy` (with `-auto-approve` if `-y`)

**Removes:** EC2, ENI, EIP, VPC/subnet/SG/IGW, weekday schedulers (and wake
one-shots), IAM roles/profiles this stack created, offline S3 + CloudFront if
they were enabled.

**Does not remove:** DNS / UI CloudFront / Lambda@Edge / ACM you created in
another account; local gitignored files (`terraform.tfvars`,
`secrets.auto.tfvars`, `handoff.*`, `keys/`).

Equivalent manual form: `AWS_PROFILE=spectre terraform destroy`.
