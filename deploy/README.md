# DroneFeed — EC2 / production deploy

## Ports (security group)

| Port | Proto | Service | Who |
|------|-------|---------|-----|
| 80 | TCP | Caddy (ACME HTTP-01 + redirect) | Let's Encrypt + browsers |
| 443 | TCP/UDP | Caddy HTTPS (auto Let's Encrypt) | Researchers (browser) |
| 1935 | TCP | MediaMTX RTMP | Research tools (pull) / phone DJI Custom RTMP / companion ingest |
| 8554 | TCP | MediaMTX RTSP | Research tools / companion |
| 8890 | UDP | MediaMTX SRT | Research tools (MPEG-TS + KLV pull) + VOD republish ingest |
| 8900–8999 | UDP | MediaMTX MPEG-TS ingest | Live drone / encoder UDP feeds |
| 8888 | TCP | MediaMTX HLS (optional direct) | Browser / ops — UI preview uses HTTPS `/hls/…` via Caddy |
| 22 | TCP | SSH (or use SSM only) | Ops |

RTMP/RTSP/SRT share fixed listeners (`/vod/<id>`, `/live/<id>`).

- **Recorded Public feed** loops a **live-style distribution encode** (default
  720p Main H.264 via `PUBLISH_VIDEO_HEIGHT`, IDR ~1s, KLV copied) over **SRT**
  into MediaMTX (`publish:vod/<id>`), then re-serves SRT/RTSP/RTMP/HLS.
  Full-quality source stays on disk; `-c copy` of 4K High into MediaMTX is
  avoided because SRT/HLS remux often yields H264 with no SPS/PPS (`0×0`) and
  players hang on Connecting.
- **Live Drone UDP** uses ports from `UDP_INGEST_PORT_MIN`–`MAX` (default 8900–8999), one port per session.

**Pull access:** capability URLs only (token embedded). Copy from the UI; do not ask tools for a separate username/password.

- RTMP (query auth — required by MediaMTX): `rtmp://MEDIA_IP:1935/vod/<id>?user=drone&pass=<key>`
- RTSP: `rtsp://drone:<key>@MEDIA_IP:8554/vod/<id>`
- SRT (preferred for H.264+KLV; Haivision / MediaMTX URI):  
  `srt://MEDIA_IP:8890?streamid=read:vod/<id>:drone:<key>&latency=2000`  
  (`latency` is milliseconds — default 2s ARQ for WAN. Set `SRT_PULL_LATENCY_MS`
  to 1000 on a clean path or 3000–4000 if pulls still stall. FFmpeg-only extras
  like `pkt_size` / µs latency / huge `rcvbuf` belong on the client CLI, not this
  capability URL.)

Public VOD republish defaults to a **CBR-ish ~2.5 Mbps 720p Main** encode
(`PUBLISH_VIDEO_HEIGHT`, `PUBLISH_VIDEO_BITRATE`, …). Set
`PUBLISH_VIDEO_HEIGHT=1080` (and raise bitrate) for higher quality, or `0` /
`source` to keep source resolution (still re-encodes for IDRs). Toggle Public
feed off/on after changing those env vars so FFmpeg restarts.

**Phone / Mavic live:** Custom RTMP publish uses the same query form on `/live/<id>` (video/AAC only). The Flights UI plays a same-origin HLS preview at `https://PHX_HOST/hls/live/<id>/index.m3u8` (Caddy → MediaMTX `:8888`). Expect a few seconds of delay (phone keyframe interval + HLS); RTSP/SRT pulls are closer to real time.

KLV is carried in-band in the MPEG-TS (MISB ST 0601). SRT re-serves that TS. RTSP exposes KLV as a separate RTP/SMPTE336M track (RFC 6597), not as MPEG-TS-in-RTSP. RTMP/FLV cannot carry KLV.

**Consumer vs enterprise KLV on Public feed**

- **DJI / `.SRT` uploads** — `mux_to_stanag.py` synthesizes ST 0601 from GPS cues (sensor lat/lon/alt every packet) and **derives** heading (tag 5), ground speed (tag 56), and vertical speed (tag 51) from a ~2s GPS lookback. Each packet is **PTS-timed** to its SRT cue and interleaved with video so replay is not a KLV burst. The source `.SRT` typically has no speed/heading fields.
- **Enterprise TS+KLV** — remux/passthrough; existing motion tags are preserved.
- Cached `publish_stanag.ts` rebuilds when the video/sidecar **or** the mux script changes. Toggle Public feed off/on after a mux deploy so FFmpeg picks up the new TS.

Phoenix listens on `:4000` **inside** the Docker network only; Caddy terminates TLS and reverse-proxies.

## Minimum instance (architecture)

Public feed defaults to a ~2.5 Mbps CBR-ish **720p** encode (see `PUBLISH_VIDEO_*`).
That keeps MediaMTX remux / research-tool SRT pulls healthier than peaky VBR while
leaving CPU headroom for several concurrent publishers. Each public feed is a
continuous `libx264` re-encode — **CPU**, not NIC bandwidth, is usually the limit.

`PUBLISH_VIDEO_HEIGHT` controls output height (`720`, `1080`, …). Use `0` or
`source` to keep source resolution (still re-encodes for IDRs); do not expect
`-c copy` 4K to be playable over SRT/HLS on MediaMTX.

| Workload | Minimum | Notes |
|----------|---------|--------|
| 1–2 public feeds @720p, light demos | `c7i.xlarge` (4 vCPU, 8 GB) | Acceptable for light demos |
| **≤4 public feeds @720p** (typical prod) | **`c7i.2xlarge` (8 vCPU, 16 GB)** | Current prod target; leave headroom for UI + MediaMTX |
| **>4 concurrent public feeds**, or several @1080p | **`c7i.4xlarge` (16 vCPU) or larger** | Scale with Σ(encode cost × feeds); prefer this over packing more 1080p encodes onto 2xlarge |
| High fan-out / many SRT readers on fat sources | `c7i.4xlarge`+ | Scale with Σ(bitrate × readers) as well as encode count |

Also:

- **Disk:** 80–200 GB gp3 for ~5 days of retention (see `RETENTION_DAYS`)
- **Network:** Elastic IP (or stable DNS) for `PHX_HOST` / `MEDIA_HOST` / `MEDIA_IP`; ensure SG allows UDP **8890** and **8900–8999**
- **Host UDP buffers** (once per boot / via sysctl.d):

```bash
sudo sysctl -w net.core.rmem_max=268435456 net.core.wmem_max=268435456 \
  net.core.rmem_default=16777216 net.core.wmem_default=16777216
```

`mediamtx.yml` sets `udpReadBufferSize: 16777216` and `writeQueueSize: 65536` (power of two) for high-bitrate SRT. Public VOD uses a distribution encode by design.

Prefer **NLB** (or SG on the instance) for 1935/8554/8890 — ALB is HTTP/HTTPS-oriented and is a poor fit for raw RTMP/RTSP/SRT.

## DNS

1. Buy a domain and create an **A** (and optional **AAAA**) record for `PHX_HOST` → EC2 Elastic IP.
2. Wait for propagation, then start compose — Caddy obtains and auto-renews the certificate.

## Compose deploy

```bash
cd deploy
cp .env.example .env
# fill SECRET_KEY_BASE, PHX_HOST, ACME_EMAIL, POSTGRES_PASSWORD,
# ADMIN_EMAIL / ADMIN_PASSWORD (≥8 chars, first boot), ADMIN_CONTACT,
# MEDIA_IP, MEDIA_HOST, and SMTP_* for outbound mail

# raise host UDP buffers (see above), then:
docker compose --env-file .env up -d --build
```

- Migrations + optional admin bootstrap run via `deploy/entrypoint.sh`
- Certs live in the `caddy_data` volume and renew automatically
- After first successful login, clear `ADMIN_PASSWORD` from `.env` and recreate the web container if desired
- Changing `ADMIN_EMAIL` later does **not** rename an existing user; update the `users.email` row (or bootstrap a new admin) as well

## Auth model

- Public **Request an account** form → admin inbox + email notification
- Admin approves (assigns **user** or **admin** group) → verification email to requester
- After email verification, the user can log in and upload
- Bootstrap admin via `ADMIN_EMAIL` / `ADMIN_PASSWORD` (joined to the admin group)
- Admins manage requests and roles at `/admin`
- Outbound mail via AWS SES SMTP (`SMTP_*`)
- Credential restores: contact `ADMIN_CONTACT`
- Settings: password change only

## Embed in research tools (iframe)

Self-hosters can iframe DroneFeed inside Gladius / other research UIs so users log in,
create live sessions or uploads, and copy pull URLs without leaving the host app.

1. Serve DroneFeed over **HTTPS** (Caddy already does this).
2. In `.env`:

```bash
EMBED_COOKIES=true
FRAME_ANCESTORS=*
# Or restrict: FRAME_ANCESTORS=https://your-research-tool.example
```

`EMBED_COOKIES=true` sets session + remember-me cookies to
`SameSite=None; Secure; Partitioned` so login works in a cross-origin iframe
under Chrome’s third-party cookie restrictions (CHIPS). Without `Partitioned`,
browsers drop the session cookie in embeds → LiveView reconnect loops and
inputs lose focus while typing. `FRAME_ANCESTORS` clears `X-Frame-Options`
and emits `Content-Security-Policy: frame-ancestors …`.

3. Embed:

```html
<iframe
  src="https://PHX_HOST/users/log-in?embed=1"
  title="DroneFeed"
  style="width:100%;height:100%;border:0;min-height:640px"
  allow="clipboard-write"
></iframe>
```

Unauthenticated users hitting `/flights` are redirected to login and returned afterward.
`?embed=1` (or any iframe) keeps compact chrome via `sessionStorage` across that flow.

## Stream URL pattern

- Pull (IP): `rtmp://MEDIA_IP:1935/vod/<flight_id>?user=drone&pass=<key>` / `rtsp://drone:<key>@MEDIA_IP:8554/vod/<flight_id>` / SRT as above
- Alternate (DNS): same paths on `MEDIA_HOST` when it differs from `MEDIA_IP`
- Auth: token inside the URL (UI capability link) — RTMP always uses `?user=&pass=` (MediaMTX ignores URL userinfo for RTMP)
- Live pull: `/live/<session_id>` on the same RTMP/RTSP/SRT hosts/ports
- Live **phone / Mavic**: Custom RTMP publish URL from the UI (`rtmp://MEDIA_IP:1935/live/<id>?user=drone&pass=<key>`, or Server + Stream key fields). Video/AAC only.
- Live **Drone UDP** ingest: `udp://MEDIA_IP:<allocated-port>` (MPEG-TS; port shown in the UI)
- Companion live ingest: RTMP (query) / RTSP publish URLs with stream key (shown in the UI)

## Systemd (non-Compose)

Unit files: `deploy/systemd/drone-feed.service` and `deploy/systemd/mediamtx.service`.
For TLS on bare metal, run Caddy (or nginx) on the host pointing at Phoenix `:4000`, with the same ACME email / hostname env vars.

## Local stack without full release image

1. Start Postgres (compose `db` only, or local on 5434)
2. `cd apps/web && mix setup && mix phx.server`
3. Run MediaMTX: `docker run --rm -p 1935:1935 -p 8554:8554 -p 8890:8890/udp -v $PWD/deploy/mediamtx.yml:/mediamtx.yml bluenviron/mediamtx:1.19.3` with `MTX_AUTHHTTPADDRESS=http://host.docker.internal:4000/api/mediamtx/auth` (Linux: use host gateway IP)

## After-hours (EC2 stopped)

When the instance is powered off for cost savings, a static S3/CloudFront page
(“DroneFeed is down after hours”) can be served via a Cloudflare Worker.
See [maintenance/README.md](./maintenance/README.md).
