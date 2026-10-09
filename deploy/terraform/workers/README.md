# Edge workers (post-apply, not managed by Terraform)

| File | Use with |
|------|----------|
| [`cloudflare-worker.js`](./cloudflare-worker.js) | [Path 1 — Cloudflare](../README.md#path-1--cloudflare) |
| [`lambda-edge-viewer-request.js`](./lambda-edge-viewer-request.js) | [Path 2 — Route 53](../README.md#path-2--route-53) |

Both serve `maintenance_url` (S3 via CloudFront) when EC2 is down. DNS still
resolves to the EIP/CloudFront — the worker returns the offline HTML; it does
not repoint DNS at the bucket.

Terraform seeds the offline objects; `./setup.sh` writes `deploy/maintenance/generated/aws.env`.
