/**
 * Reference copy — deployed from lambda-edge-viewer-request.js.tftpl via Terraform.
 * When origin is up, return the CloudFront request (pass-through). When down, 503 HTML.
 */

"use strict";

const ORIGIN_BASE = "http://203.0.113.10";
const MAINTENANCE_URL = "https://dxxxx.cloudfront.net/index.html";
const ORIGIN_TIMEOUT_MS = 2500;

exports.handler = async (event) => {
  const request = event.Records[0].cf.request;
  const method = (request.method || "GET").toUpperCase();

  if (method !== "GET" && method !== "HEAD") {
    return request;
  }

  const path = request.uri || "/";
  const qs = request.querystring ? `?${request.querystring}` : "";
  const originUrl = `${ORIGIN_BASE}${path}${qs}`;

  try {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), ORIGIN_TIMEOUT_MS);
    const upstream = await fetch(originUrl, {
      method: "HEAD",
      headers: { accept: "*/*" },
      signal: controller.signal,
      redirect: "manual",
    });
    clearTimeout(timer);

    if (upstream.status >= 502 && upstream.status <= 504) {
      return maintenanceResponse(upstream.status);
    }

    return request;
  } catch {
    return maintenanceResponse(522);
  }
};

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
