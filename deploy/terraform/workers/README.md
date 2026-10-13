# Edge workers (not managed by Terraform)

| File | Path |
|------|------|
| [`cloudflare-worker.js`](./cloudflare-worker.js) | [README Path 1](../README.md#path-1--cloudflare) |
| [`lambda-edge-viewer-request.js`](./lambda-edge-viewer-request.js) | [README Path 2](../README.md#path-2--route-53-other-aws-account) |

Serve `maintenance_url` when EC2 is down. DNS stays on the EIP (Cloudflare) or
the UI CloudFront (Route 53) — workers do not point DNS at S3.

After apply, `./setup.sh` may write `deploy/maintenance/generated/aws.env`.
