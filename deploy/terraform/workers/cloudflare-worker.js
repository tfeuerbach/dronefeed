/**
 * DroneFeed after-hours failover — Cloudflare Worker
 *
 * Paste into Cloudflare → Workers → Create → Quick edit.
 * Attach a route: feeds.example.com/*
 *
 * Worker → Settings → Variables:
 *   MAINTENANCE_URL = https://<maintenance_cloudfront_domain>/index.html
 *   (from: terraform output -raw maintenance_url)
 *
 * DNS (must be Proxied / orange cloud or this Worker never runs):
 *   Type  Name    Content              Proxy
 *   A     feeds   <Elastic IP>         Proxied
 *
 * See deploy/terraform/README.md § "Subdomain + offline failover".
 */

const ORIGIN_TIMEOUT_MS = 2500;

export default {
  async fetch(request, env) {
    try {
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), ORIGIN_TIMEOUT_MS);
      const response = await fetch(request, { signal: controller.signal });
      clearTimeout(timer);

      // Cloudflare origin errors when the EC2 box is powered off / unreachable
      if ([521, 522, 523, 525, 530].includes(response.status)) {
        return serveMaintenance(env, response.status);
      }
      return response;
    } catch {
      return serveMaintenance(env, 522);
    }
  },
};

async function serveMaintenance(env, originStatus) {
  const url = env.MAINTENANCE_URL;
  if (!url) {
    return new Response("DroneFeed is down after hours", {
      status: 503,
      headers: {
        "content-type": "text/plain; charset=utf-8",
        "cache-control": "no-store",
        "x-dronefeed-origin-status": String(originStatus),
      },
    });
  }

  try {
    const page = await fetch(url, {
      cf: { cacheTtl: 60, cacheEverything: true },
    });
    const html = await page.text();
    return new Response(html, {
      status: 503,
      headers: {
        "content-type": "text/html; charset=utf-8",
        "cache-control": "no-store",
        "x-dronefeed-origin-status": String(originStatus),
      },
    });
  } catch {
    return new Response(
      "<!doctype html><title>DroneFeed</title><p>DroneFeed is down after hours</p>",
      {
        status: 503,
        headers: {
          "content-type": "text/html; charset=utf-8",
          "cache-control": "no-store",
        },
      }
    );
  }
}
