/**
 * DroneFeed after-hours failover — Lambda@Edge (viewer-request)
 *
 * AWS equivalent of workers/cloudflare-worker.js.
 * Deploy to us-east-1, then associate with a CloudFront distribution that sits
 * in front of the EC2 Elastic IP (viewer-request trigger).
 *
 * Before deploy, set the two constants below from terraform outputs:
 *   ORIGIN_BASE     = http://<public_ip>     (or https://… once the app has TLS)
 *   MAINTENANCE_URL = terraform output -raw maintenance_url
 *
 * Prefer CloudFront **origin group failover** (no Lambda) when you can —
 * see deploy/terraform/README.md § "Option B — Route 53 + AWS".
 * Use this Lambda when you want the same short-timeout behavior as Cloudflare.
 *
 * Package: zip this file as index.js (Node.js 18.x), publish a numbered version,
 * then attach that version to the distribution (Lambda@Edge requires published versions).
 */

"use strict";

// --- edit these after terraform apply ---
const ORIGIN_BASE = "http://203.0.113.10"; // Elastic IP from: terraform output -raw public_ip
const MAINTENANCE_URL = "https://dxxxx.cloudfront.net/index.html"; // terraform output -raw maintenance_url
const ORIGIN_TIMEOUT_MS = 2500;
// ---------------------------------------

exports.handler = async (event) => {
  const request = event.Records[0].cf.request;
  const path = request.uri || "/";
  const qs = request.querystring ? `?${request.querystring}` : "";
  const originUrl = `${ORIGIN_BASE}${path}${qs}`;

  try {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), ORIGIN_TIMEOUT_MS);
    const upstream = await fetch(originUrl, {
      method: request.method,
      headers: hopHeaders(request.headers),
      signal: controller.signal,
      redirect: "manual",
    });
    clearTimeout(timer);

    if (upstream.status >= 502 && upstream.status <= 504) {
      return maintenanceResponse(upstream.status);
    }

    return toCfResponse(upstream);
  } catch {
    return maintenanceResponse(522);
  }
};

function hopHeaders(cfHeaders) {
  const out = {};
  for (const [name, values] of Object.entries(cfHeaders || {})) {
    if (name === "host" || name === "connection" || name === "content-length") continue;
    const v = values && values[0] && values[0].value;
    if (v) out[name] = v;
  }
  return out;
}

async function toCfResponse(upstream) {
  const body = await upstream.arrayBuffer();
  const headers = {};
  upstream.headers.forEach((value, key) => {
    if (key.toLowerCase() === "transfer-encoding") return;
    headers[key] = [{ key, value }];
  });
  return {
    status: String(upstream.status),
    statusDescription: upstream.statusText || "OK",
    headers,
    body: Buffer.from(body).toString("base64"),
    bodyEncoding: "base64",
  };
}

async function maintenanceResponse(originStatus) {
  try {
    const page = await fetch(MAINTENANCE_URL, { redirect: "follow" });
    const html = await page.text();
    return {
      status: "503",
      statusDescription: "Service Unavailable",
      headers: {
        "content-type": [{ key: "Content-Type", value: "text/html; charset=utf-8" }],
        "cache-control": [{ key: "Cache-Control", value: "no-store" }],
        "x-dronefeed-origin-status": [
          { key: "X-Dronefeed-Origin-Status", value: String(originStatus) },
        ],
      },
      body: html,
    };
  } catch {
    return {
      status: "503",
      statusDescription: "Service Unavailable",
      headers: {
        "content-type": [{ key: "Content-Type", value: "text/plain; charset=utf-8" }],
        "cache-control": [{ key: "Cache-Control", value: "no-store" }],
      },
      body: "DroneFeed is down after hours",
    };
  }
}
