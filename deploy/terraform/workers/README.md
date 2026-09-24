# Edge workers (post-apply, not managed by Terraform)

| File | Use with |
|------|----------|
| [`cloudflare-worker.js`](./cloudflare-worker.js) | [Path 1 — Cloudflare](../README.md#path-1--cloudflare) |
| [`lambda-edge-viewer-request.js`](./lambda-edge-viewer-request.js) | [Path 2 — Route 53](../README.md#path-2--route-53-aws) |

Both serve `maintenance_url` (S3 via CloudFront) when EC2 is down.
