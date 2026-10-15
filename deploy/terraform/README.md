# DroneFeed AWS Terraform

IP-first host: VPC, EC2, Elastic IP, Docker Compose on plain HTTP, weekday
power schedule (Mon–Fri 8:00–18:00 local), S3 + CloudFront offline page,
CloudWatch logs/dashboard, and optional SNS operator email alerts.
Optional `app_hostname` adds ACM + Lambda@Edge (+ UI CloudFront when enabled)
in this account; Route 53 records stay in the DNS account.

| | |
|--|--|
| App URL | `http://<elastic-ip>` |
| SSH | `dronefeed` + key from setup (passwordless sudo) |
| Schedule | Mon–Fri 8–18; after hours: `./wake.sh 4\|8\|12` (max 12h) |
| Offline page | `terraform output -raw maintenance_url` |
| Ops email | Optional SNS (schedule / budget / disk / swap / OOM) |
| Console | CloudWatch dashboard `*-ops` + log groups `/{name_prefix}/*` |

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
(`dnf-automatic-install` + `releasever=latest`), a **4 GiB swap file** (helps
Docker/Elixir builds avoid OOM), and passwordless sudo for the deploy user.
App/container updates stay manual.

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

Guided flow: tags → workload sizing → SSH → admin → repo → email/EIP (SES
optional + **SNS ops alerts**) → offline page → schedule → init/plan/apply.
Smoke asks separately whether to test ops email. Instance type and disk you
pick are what apply creates. `./setup.sh` loads live `c7i` types and
on-demand/gp3 prices for the region (Pricing API); estimates only — egress not
included.

Writes gitignored `terraform.tfvars` + `secrets.auto.tfvars`, and an SSH key
(`~/.ssh/*.pub` or `keys/`). Defaults: schedule on, EIP on, SES off, SNS ops
alerts on in guided / off in smoke unless you opt in, maintenance page on
(new bucket, same account).

Apply prints operator login plus a copy-pastable **network handoff** block
(public IP, HTTP origin, media ports, offline CloudFront URL) and writes
gitignored `handoff.txt` / `handoff.env`. When ops alerts are enabled, confirm
the AWS SNS subscription email, then setup publishes a bootstrap message
(smoke vs prod wording). Admin credentials also live in `secrets.auto.tfvars`
and `/opt/drone-feed/DEPLOY.txt` on the host.

## After apply

1. Wait for the first Docker build:

   ```bash
   ssh -i <key> dronefeed@<eip> 'tail -f /opt/drone-feed/compose-bootstrap.log'
   ```

2. Open `http://<eip>` and sign in with the setup admin.

3. **Stack / network handoff** (Teams copy/paste — EIP, media ports, offline URL):

   ```bash
   ./stack-info.sh -p spectre
   ./stack-info.sh -p spectre --write     # also refresh handoff.txt / handoff.env
   ./stack-info.sh -p spectre --secrets   # include admin password from local tfvars
   ```

4. Offline page URL (always up; stopping EC2 does not change DNS):

   ```bash
   terraform output -raw maintenance_url
   ```

5. Observability in the AWS console:

   ```bash
   terraform output -raw ops_dashboard_name
   terraform output -raw ops_log_group_prefix
   ```

   Dashboard: EC2 CPU / status checks / network, host mem / swap / disk
   (CloudWatch Agent), and recent `web` / `mediamtx` / `caddy` / `db` /
   bootstrap / system logs.
   Log groups: `/{name_prefix}/{web,caddy,mediamtx,db,bootstrap,system}`
   (14-day retention). Compose uses the `awslogs` driver via
   `docker-compose.logging.yml` on first boot.

## Operator email (SNS)

Optional. Not SES — no SMTP identity required.

| Mail | When |
|------|------|
| AWS “Confirm subscription” | Once, right after apply |
| Bootstrap (from `setup.sh`) | After you Confirm — smoke vs guided text |
| Schedule miss | Weekday ~15m after start; instance not `running` |
| On too long | Weekday ~15m after stop; instance still up |
| Budget | 80% / 100% of monthly USD actual |
| Disk high | Root `disk_used_percent` ≥ `disk_alarm_percent` (default **85**) |
| Swap high | `swap_used_percent` ≥ `swap_alarm_percent` (default **50**) — memory pressure |
| OOM | Kernel OOM lines in `/var/log/messages` (`/{name_prefix}/system`) |

Guided defaults alerts **on**; smoke asks “Test operator email alerts?”
(**off** by default). Set in tfvars: `enable_ops_alerts`, `ops_alert_email`,
`monthly_budget_usd` (optional `disk_alarm_percent` / `swap_alarm_percent`).

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

## Domain and HTTPS (optional)

Not needed for IP-first. Pick **Path 1 (Cloudflare)** or **Path 2 (Route 53)**.
Media (SRT/RTSP/RTMP/UDP) always uses the Elastic IP — never an HTTP-only proxy.

### How offline works

Stopping EC2 does not change DNS. Do not point DNS at the S3 bucket. The offline
HTML is always on the maintenance CloudFront (`maintenance_url`). Failover is at
the edge: try the live origin; if EC2 is down, return that HTML.

### On the EC2 box after the hostname works

CloudFront / Cloudflare terminates HTTPS for the UI. Keep the origin on HTTP:

```bash
# /opt/drone-feed/deploy/.env
PHX_HOST=dronefeed.example.com
MEDIA_IP=<EIP>
PHX_SCHEME=https
CADDYFILE=Caddyfile.http
# docker compose --env-file .env up -d --force-recreate web
```

With `app_hostname` set, first-boot user_data stamps `PHX_HOST` + `PHX_SCHEME=https`
automatically (still `Caddyfile.http`). Endpoint `:force_ssl` is not used (compile-env
safe). Optional on-box HTTPS redirect: `PHX_FORCE_SSL=true` only with `CADDYFILE=Caddyfile`.

Do **not** set `PHX_FORCE_SSL` behind CloudFront. Do **not** switch to on-box Let's
Encrypt (`CADDYFILE=Caddyfile`) while the edge origin is HTTP `:80`.

### Path 1 — Cloudflare

Use when DNS is on Cloudflare (no Spectre UI CloudFront / ACM / Lambda@Edge).

| Type | Name | Content | Proxy |
|------|------|---------|-------|
| A | app hostname | `<EIP>` | Proxied (orange) |
| A (optional) | media hostname | `<EIP>` | DNS only (grey) |

1. Terraform still creates the offline S3 + maintenance CloudFront (`maintenance_url`).
2. Create a Worker; paste [`workers/cloudflare-worker.js`](./workers/cloudflare-worker.js).
3. Worker variable `MAINTENANCE_URL` = `terraform output -raw maintenance_url`.
4. Route: `your-hostname/*`.
5. Check: instance up → app; instance stopped → offline HTML.
6. On the box: set `PHX_HOST` / `PHX_SCHEME=https` / `CADDYFILE=Caddyfile.http` (above).

No ACM validation ticket. No alias to CloudFront. Media must stay DNS-only / EIP.

### Path 2 — Route 53 (Spectre owns edge; DNS account owns records)

Use when the hosted zone is in another AWS account (e.g. `ecsdevlabs.com`).

**This account (Spectre) creates:** ACM + Lambda@Edge + UI CloudFront.  
**DNS account creates:** ACM validation CNAMEs + alias A/AAAA → UI CloudFront.

```hcl
app_hostname         = "dronefeed.ecsdevlabs.com"
enable_ui_cloudfront = false   # true after ACM is Issued
```

```bash
cd deploy/terraform
terraform apply                              # ACM + Lambda@Edge
terraform output ui_acm_validation_records   # give to DNS
./stack-info.sh -p spectre                   # full DNS ticket text
# … DNS adds validation CNAMEs; wait until ACM = Issued …
# set enable_ui_cloudfront = true
terraform apply
terraform output -raw ui_cloudfront_domain   # give to DNS for alias
```

**DNS ticket (hosted-zone account only):**

1. Create the ACM validation CNAME(s) from `ui_acm_validation_records`.
2. After Spectre enables UI CloudFront: **Alias A/AAAA** hostname →
   `ui_cloudfront_domain` (not the EIP, not the offline CloudFront).
3. No `media.*` record required (media stays on the EIP).

**Do not:** point DNS at the S3 offline bucket; reuse the offline CloudFront as
the UI distribution; put media behind the UI CloudFront.

Workers / templates: [`workers/README.md`](./workers/README.md).

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

- Domains / DNS records in another account (Path 1 or 2 above)
- SES identity verification (app SMTP is separate from SNS ops alerts)
- Per-container / CVE / ingest email storms
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
one-shots), SNS/budget/schedule-check Lambda, CloudWatch dashboard + log
groups, IAM roles/profiles this stack created, offline S3 + CloudFront if
they were enabled.

**Does not remove:** Route 53 records in another account; local gitignored files (`terraform.tfvars`,
`secrets.auto.tfvars`, `handoff.*`, `keys/`).

Equivalent manual form: `AWS_PROFILE=spectre terraform destroy`.
