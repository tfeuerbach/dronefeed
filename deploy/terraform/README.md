# DroneFeed — AWS Terraform

Terraform uses **HCL** (`.tf` files), not YAML. This stack provisions the same
shape as the reference EC2 deploy:

| Piece | Default |
|-------|---------|
| Compute | `c7i.2xlarge` Amazon Linux 2023, 80 GiB gp3 |
| Network | Dedicated VPC + public subnet + Internet Gateway |
| Address | Elastic IP (`MEDIA_IP` / DNS) |
| Firewall | SG: 22, 80, 443/tcp+udp, 1935, 8554, 8890/udp, 8888, 8900–8999/udp |
| IAM | Instance profile with SSM (+ optional SES send) |
| Host bootstrap | Docker + Compose, UDP sysctl buffers, clone to `/opt/drone-feed` |

App runtime remains **Docker Compose** on the instance (`deploy/docker-compose.yml`:
Phoenix, Postgres, Caddy, MediaMTX). Terraform does **not** put secrets in state —
you finish `.env` on the host after apply.

## Prerequisites

- Terraform ≥ 1.5
- AWS credentials with rights to create VPC/EC2/IAM/EIP
- An SSH public key **or** an existing EC2 key pair name (or use SSM only)

## Quick start

```bash
cd deploy/terraform
cp terraform.tfvars.example terraform.tfvars
# edit: public_key or key_name, region, ssh_ingress_cidrs, git_repo_url

terraform init
terraform plan
terraform apply
```

Outputs include `public_ip` and a `next_steps` checklist.

Then on the instance:

```bash
# SSH or: aws ssm start-session --target <instance_id>
sudo -iu dronefeed
cd /opt/drone-feed/deploy
$EDITOR .env   # PHX_HOST, MEDIA_IP=<public_ip>, secrets, ACME_EMAIL, …
docker compose --env-file .env up -d --build
```

Point your DNS **A** record for `PHX_HOST` at the Elastic IP before (or right after)
the first `compose up` so Caddy can obtain a certificate.

## Sizing

Same guidance as [../README.md](../README.md#minimum-instance-architecture):

- ≤4 public feeds @720p → `c7i.2xlarge` (default)
- \>4 feeds or several @1080p → set `instance_type = "c7i.4xlarge"`

## What this does *not* include

- Cloudflare / after-hours maintenance Worker ([../maintenance](../maintenance))
- SES identity verification / SMTP user creation (role policy alone is not enough)
- Application secrets (`SECRET_KEY_BASE`, DB password, admin bootstrap)
- Automatic `docker compose up` (by design — fill `.env` first)

## Known constraints

- `git_ref` must be a **branch or tag** name (shallow clone uses `--branch`).
- `c7i.*` instance types are not in every region/AZ — change `aws_region` / `availability_zone` / `instance_type` if capacity fails.
- Elastic IP is associated **after** first boot, so user-data cannot reliably stamp `MEDIA_IP`; use the `public_ip` output.
- This module was validated with `terraform validate`; it has **not** been applied end-to-end in CI. Do a `terraform plan` in your account before apply.

## Destroy

```bash
terraform destroy
```

This removes the VPC, instance, EIP, and IAM resources created here. Compose
volumes on the instance die with the instance unless you add external EBS later.
