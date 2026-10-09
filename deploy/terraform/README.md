# DroneFeed AWS Terraform

Provisions an IP-first DroneFeed host: VPC, EC2 (`c7i.2xlarge`), Elastic IP,
Docker Compose on plain HTTP, weekday power schedule (Mon–Fri 8:00–18:00 local),
and an S3 + CloudFront offline page. No Route 53, ACM, or domain is created.

| | |
|--|--|
| App URL | `http://<elastic-ip>` |
| SSH | `dronefeed` + key from setup |
| Schedule | Mon–Fri 8–18; after hours: `./wake.sh 4\|8\|12\|24` |
| Offline page | CloudFront URL in terraform outputs |
| Email | Off by default |

## Prerequisites

1. AWS credentials for the target account only:

   ```bash
   export AWS_PROFILE=<profile>
   aws sts get-caller-identity
   ```

2. Tools: `terraform`, `aws`, `openssl`, `ssh-keygen`.

3. Push the git ref the instance will clone (`master` by default). Local-only
   changes are not used on first boot. The ref must include:

   - `deploy/Caddyfile.http`
   - runtime `PHX_SCHEME` / `force_ssl` (`force_ssl` only when `PHX_SCHEME=https`)

## Setup

```bash
cd deploy/terraform
./setup.sh
```

The wizard writes `terraform.tfvars` and `secrets.auto.tfvars`, provisions an
SSH key (your `~/.ssh/*.pub` or a new key under `keys/`), asks about the
offline-page bucket, then optionally runs plan/apply.

Defaults you can accept: weekday schedule on, Elastic IP on, SES/email off,
maintenance page on (new bucket, same account).

When apply finishes it prints:

```text
App URL:   http://x.x.x.x
Admin:     …
Password:  …
SSH:       ssh -i … dronefeed@x.x.x.x
```

Credentials are also in `secrets.auto.tfvars` (gitignored) and on the host at
`/opt/drone-feed/DEPLOY.txt`.

## After apply

1. Wait for the first Docker build (several minutes). Progress on the host:

   ```bash
   ssh -i <key> dronefeed@<eip> 'tail -f /opt/drone-feed/compose-bootstrap.log'
   ```

2. Open `http://<eip>` and sign in with the admin credentials from setup.

3. Offline page (EC2 stopped does not change DNS; this URL is always available):

   ```bash
   terraform output -raw maintenance_url
   ```

## After-hours wake

Weekday schedules stay enabled. To run the box outside 8–18:

```bash
./wake.sh 4          # or 8, 12, 24
./wake.sh --status
./wake.sh --restore-schedule
```

`wake.sh` starts the instance and sets a one-shot stop. It only briefly pauses
the weekday stop schedule if that stop would cut the wake window short.

## Domain and HTTPS (optional, often another account)

Not required for IP-first. Collect:

```bash
terraform output -raw public_ip
terraform output -raw maintenance_url
```

Media ports (SRT/RTSP/RTMP) must use the EIP or a DNS-only hostname, not a
proxied Cloudflare hostname.

On the instance after DNS exists:

```bash
# /opt/drone-feed/deploy/.env
PHX_HOST=dronefeed.example.com
MEDIA_IP=<EIP>
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
2. Set variable `MAINTENANCE_URL` to `terraform output -raw maintenance_url`.
3. Route: `feeds.example.com/*`.

### Path 2 — Route 53

1. ACM in `us-east-1`: cert for the hostname; validate in Route 53; wait until Issued.
2. Lambda@Edge (Node 18, `us-east-1`): paste
   [`workers/lambda-edge-viewer-request.js`](./workers/lambda-edge-viewer-request.js);
   set `ORIGIN_BASE=http://<EIP>` and `MAINTENANCE_URL=<maintenance_url>`; publish a version.
3. CloudFront (new distribution, not the Terraform maintenance one): origin EIP:80;
   caching disabled; viewer-request Lambda@Edge; alternate domain + ACM cert.
4. DNS: Alias A/AAAA for the hostname to that CloudFront; optional `media` A to EIP.

For locked-down EC2 accounts: run only `./setup.sh` here. Hand the EIP and
`maintenance_url` to the DNS account when ready.

## Schedule and sizing

```hcl
enable_business_hours_schedule = true
schedule_timezone              = "America/New_York"
schedule_start_hour            = 8
schedule_stop_hour             = 18
```

- Up to about 4 public feeds at 720p: `c7i.2xlarge` (default)
- More feeds or several at 1080p: `c7i.4xlarge`

## Not included

- Domains / Route 53 / ACM (Path 1 or Path 2 above, after DNS exists)
- SES identity verification
- Remote Terraform state (keep local `terraform.tfstate` safe)

## Constraints

- `git_ref` must be pushed before apply (see Prerequisites).
- Clone URL must be reachable from the instance (public HTTPS unless you add auth).
- `c7i.*` may be missing in some AZs.
- First `compose up --build` can take several minutes.

## Destroy

```bash
cd deploy/terraform
terraform destroy
```

Removes EC2 and the maintenance S3/CloudFront stack. Delete any manual
CloudFront / Lambda@Edge / DNS records yourself.
