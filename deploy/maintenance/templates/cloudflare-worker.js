/**
 * DroneFeed after-hours failover (Cloudflare Worker).
 *
 * DNS: A record for your site → origin Elastic IP, Proxied (orange cloud).
 * Route this Worker to: {{WORKER_ROUTE}}
 *
 * Runtime variable (Settings → Variables):
 *   MAINTENANCE_URL = {{MAINTENANCE_URL}}
 *
 * When the origin host is down, serves the static maintenance page (HTTP 503).
 * Uses a short origin timeout so visitors are not stuck waiting on a powered-off box.
 */
export default {
  async fetch(request, env) {
    try {
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), {{ORIGIN_TIMEOUT_MS}});
      const response = await fetch(request, { signal: controller.signal });
      clearTimeout(timer);

      if ([521, 522, 523, 525, 530].includes(response.status)) {
        return serveMaintenance(env, response.status);
      }
      return response;
    } catch {
      // Origin unreachable / timed out while the app host is stopped
      return serveMaintenance(env, 522);
    }
  },
};

async function serveMaintenance(env, originStatus) {
  const url = env.MAINTENANCE_URL;
  if (!url) {
    return new Response("{{FALLBACK_TEXT}}", {
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
      "<!doctype html><title>{{BRAND_NAME}}</title><p>{{FALLBACK_TEXT}}</p>",
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
