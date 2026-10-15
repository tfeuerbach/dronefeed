# Edge workers

| File | Path | Role |
|------|------|------|
| [`lambda-edge-viewer-request.js.tftpl`](./lambda-edge-viewer-request.js.tftpl) | [README Path 2](../README.md#path-2--route-53-spectre-owns-edge-dns-account-owns-records) | Deployed by Terraform (`ui_edge.tf`) when `app_hostname` is set |
| [`lambda-edge-viewer-request.js`](./lambda-edge-viewer-request.js) | same | Reference copy only — prefer Terraform |
| [`cloudflare-worker.js`](./cloudflare-worker.js) | [README Path 1](../README.md#path-1--cloudflare) | Cloudflare Worker (not Terraform) |

## Path 1 — Cloudflare

DNS/proxied hostname on Cloudflare. Worker fetches the live origin; on failure
returns `MAINTENANCE_URL` (Terraform `maintenance_url`). Media stays DNS-only → EIP.

## Path 2 — Route 53

Spectre Terraform owns ACM + Lambda@Edge + UI CloudFront. The DNS account only:

1. ACM validation CNAMEs (`terraform output ui_acm_validation_records`)
2. Alias A/AAAA hostname → `ui_cloudfront_domain`

Do not hand-create Lambda@Edge in the DNS account when using Path 2.

After apply, `./setup.sh` / `./stack-info.sh` write handoff files and may write
`deploy/maintenance/generated/aws.env`.
