# DroneFeed — EC2 / production deploy

## Ports (security group)

| Port | Proto | Service | Who |
|------|-------|---------|-----|
| 80 | TCP | Caddy (ACME HTTP-01 + redirect) | Let's Encrypt + browsers |
| 443 | TCP/UDP | Caddy HTTPS (auto Let's Encrypt) | Researchers (browser) |
| 1935 | TCP | MediaMTX RTMP | Research tools (pull) / companion ingest |
| 8554 | TCP | MediaMTX RTSP | Research tools / companion |
| 8890 | UDP | MediaMTX SRT | Research tools (MPEG-TS + KLV pull) |
| 8900–8999 | UDP | MediaMTX MPEG-TS ingest | Drone / encoder UDP feeds |
| 8888 | TCP | MediaMTX HLS (optional) | Browser / ops |
| 22 | TCP | SSH (or use SSM only) | Ops |

RTMP/RTSP/SRT share fixed listeners (`/vod/<id>`, `/live/<id>`). **UDP MPEG-TS** ports from `UDP_INGEST_PORT_MIN`–`MAX` (default 8900–8999) are used for:

- Live **Drone UDP** ingest sessions (one port each)
- Recorded **Public feed** republish (FFmpeg → MediaMTX over UDP, full TS + KLV)

**Pull auth:** username `drone`, password = stream key.

- RTMP: `rtmp://MEDIA_IP:1935/vod/<id>` (or `rtmp://drone:<key>@MEDIA_IP:1935/vod/<id>`)
- RTSP: `rtsp://MEDIA_IP:8554/vod/<id>` (or embed `drone:<key>@`)
- SRT (preferred for H.264+KLV): `srt://MEDIA_IP:8890?streamid=read:vod/<id>:drone:<key>`

KLV is carried in-band in the MPEG-TS (MISB ST 0601). SRT re-serves that TS. RTSP exposes KLV as a separate RTP/SMPTE336M track (RFC 6597), not as MPEG-TS-in-RTSP. RTMP/FLV cannot carry KLV.

Phoenix listens on `:4000` **inside** the Docker network only; Caddy terminates TLS and reverse-proxies.

## DNS

1. Buy a domain and create an **A** (and optional **AAAA**) record for `PHX_HOST` → EC2 Elastic IP.
2. Wait for propagation, then start compose — Caddy obtains and auto-renews the certificate.

## Compose deploy

```bash
cd deploy
cp .env.example .env
# fill SECRET_KEY_BASE, PHX_HOST, ACME_EMAIL, POSTGRES_PASSWORD,
# ADMIN_EMAIL / ADMIN_PASSWORD (≥8 chars, first boot), ADMIN_CONTACT,
# and SMTP_HOST / SMTP_USER / SMTP_PASSWORD for dronefeed@tfeuerbach.dev

docker compose --env-file .env up -d --build
```

- Migrations + optional admin bootstrap run via `deploy/entrypoint.sh`
- Certs live in the `caddy_data` volume and renew automatically
- After first successful login, clear `ADMIN_PASSWORD` from `.env` and recreate the web container if desired

## Suggested instance

- Start: `c6i.xlarge` / `c7i.xlarge` (4 vCPU), 50–200 GB gp3 for ~5 days of HD footage
- Elastic IP or stable DNS for `PHX_HOST` / `MEDIA_HOST`
- Prefer remux (`-c copy`); re-encode only when codecs are not RTMP-friendly
- Prefer **NLB** (or SG on the instance) for 1935/8554 — ALB is HTTP/HTTPS-oriented and is a poor fit for raw RTMP/RTSP

## Auth model

- Public **Request an account** form → admin inbox + email notification
- Admin approves (assigns **user** or **admin** group) → verification email to requester
- After email verification, the user can log in and upload
- Bootstrap admin via `ADMIN_EMAIL` / `ADMIN_PASSWORD` (joined to the admin group)
- Admins manage requests and roles at `/admin`
- Outbound mail via AWS SES SMTP (`SMTP_*`, from `dronefeed@tfeuerbach.dev`)
- Credential restores: contact `ADMIN_CONTACT`
- Settings: password change only

## Stream URL pattern

- Pull (IP): `rtmp://MEDIA_IP:1935/vod/<flight_id>` / `rtsp://MEDIA_IP:8554/vod/<flight_id>`
- Alternate (DNS): same paths on `MEDIA_HOST` when it differs from `MEDIA_IP`
- Auth: user `drone` / password = stream key
- Live pull: `/live/<session_id>` on the same RTMP/RTSP hosts/ports
- Live **Drone UDP** ingest: `udp://MEDIA_IP:<allocated-port>` (MPEG-TS; port shown in the UI)
- Companion live ingest: RTMP/RTSP publish URLs with stream key (shown in the UI)

## Systemd (non-Compose)

Unit files: `deploy/systemd/drone-feed.service` and `deploy/systemd/mediamtx.service`.
For TLS on bare metal, run Caddy (or nginx) on the host pointing at Phoenix `:4000`, with the same ACME email / hostname env vars.

## Local stack without full release image

1. Start Postgres (compose `db` only, or local on 5434)
2. `cd apps/web && mix setup && mix phx.server`
3. Run MediaMTX: `docker run --rm -p 1935:1935 -p 8554:8554 -v $PWD/deploy/mediamtx.yml:/mediamtx.yml bluenviron/mediamtx:1.15.6` with `MTX_AUTHHTTPADDRESS=http://host.docker.internal:4000/api/mediamtx/auth` (Linux: use host gateway IP)
