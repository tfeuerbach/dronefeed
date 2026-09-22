#!/usr/bin/env python3
"""Normalize flight assets into a single MPEG-TS with MISB ST 0601 KLV.

Supported inputs:
  - Any container with an in-band data/KLV stream (``.ts``, ``.mpg``, ``.H264``,
    ``.mp4`` that is actually MPEG-TS, etc.) → remux/copy (filename-agnostic)
  - Video + DJI .SRT telemetry sidecar                 → SRT→KLV→mux
  - Video + raw .klv sidecar                           → mux

Consumer DJI .SRT cues typically only carry lat/lon/alt. We still emit those
as sensor position every cue, and derive platform heading + ground/vertical
speed from successive GPS samples over a short lookback window so research
tools can show motion without inventing it from a static pin.

KLV is interleaved into the MPEG-TS with per-cue PTS (90 kHz) matching SRT
time so Public-feed ``ffmpeg -re`` republish paces telemetry with video —
not as a front-loaded burst.

Output is a STANAG-style MPEG-TS research tools can pull over RTSP/SRT.
"""

from __future__ import annotations

import argparse
import math
import re
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

from klvdata.common import ber_encode, datetime_to_bytes, float_to_bytes, packet_checksum

UAS_KEY = bytes.fromhex("060E2B34020B01010E01030101000000")
TS_EXTS = {".ts", ".mts", ".m2ts", ".mpg", ".mpeg"}

# Look back this many seconds (or fewer if the clip just started) when
# estimating speed/heading from GPS deltas.
MOTION_WINDOW_S = 2.0
# Ignore sub-meter jitter when updating heading (carry last heading instead).
MIN_HEADING_MOVE_M = 1.0
EARTH_RADIUS_M = 6_371_000.0


@dataclass(frozen=True)
class GpsCue:
    ts: datetime
    lat: float
    lon: float
    alt: float


@dataclass(frozen=True)
class MotionSample:
    heading_deg: float | None
    ground_speed_mps: float
    vertical_speed_mps: float


def haversine_m(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    rlat1, rlon1, rlat2, rlon2 = map(math.radians, (lat1, lon1, lat2, lon2))
    dlat = rlat2 - rlat1
    dlon = rlon2 - rlon1
    a = math.sin(dlat / 2) ** 2 + math.cos(rlat1) * math.cos(rlat2) * math.sin(dlon / 2) ** 2
    return 2 * EARTH_RADIUS_M * math.asin(min(1.0, math.sqrt(a)))


def bearing_deg(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    """Initial bearing from point 1 → 2, degrees clockwise from true north [0, 360)."""
    rlat1, rlat2 = math.radians(lat1), math.radians(lat2)
    dlon = math.radians(lon2 - lon1)
    x = math.sin(dlon) * math.cos(rlat2)
    y = math.cos(rlat1) * math.sin(rlat2) - math.sin(rlat1) * math.cos(rlat2) * math.cos(dlon)
    return (math.degrees(math.atan2(x, y)) + 360.0) % 360.0


def infer_motion(
    cues: list[GpsCue],
    *,
    window_s: float = MOTION_WINDOW_S,
    min_heading_move_m: float = MIN_HEADING_MOVE_M,
) -> list[MotionSample]:
    """Derive heading / ground speed / vertical speed from a GPS cue timeline.

    For each cue, compare against the oldest sample still within ``window_s``
    (or the previous cue if the window is empty). Ground speed is horizontal
    distance / Δt; heading updates only when horizontal travel exceeds
    ``min_heading_move_m`` so hover jitter does not spin the bearing.
    """
    if not cues:
        return []

    out: list[MotionSample] = []
    last_heading: float | None = None
    window_start = 0

    for i, cue in enumerate(cues):
        while window_start < i and (cue.ts - cues[window_start].ts).total_seconds() > window_s:
            window_start += 1

        j = window_start if window_start < i else max(0, i - 1)
        prev = cues[j]
        dt = (cue.ts - prev.ts).total_seconds()

        if i == 0 or dt <= 1e-3:
            out.append(MotionSample(last_heading, 0.0, 0.0))
            continue

        horiz_m = haversine_m(prev.lat, prev.lon, cue.lat, cue.lon)
        ground = min(horiz_m / dt, 255.0)
        vertical = max(-180.0, min(180.0, (cue.alt - prev.alt) / dt))

        if horiz_m >= min_heading_move_m:
            last_heading = bearing_deg(prev.lat, prev.lon, cue.lat, cue.lon)

        out.append(MotionSample(last_heading, ground, vertical))

    return out


def encode_uas_packet(
    lat: float,
    lon: float,
    alt: float,
    ts: datetime,
    *,
    heading_deg: float | None = None,
    ground_speed_mps: float = 0.0,
    vertical_speed_mps: float = 0.0,
) -> bytes:
    items: list[bytes] = []
    items.append(b"\x02" + ber_encode(8) + datetime_to_bytes(ts))

    if heading_deg is not None:
        heading_b = float_to_bytes(heading_deg % 360.0, (0, 2**16 - 1), (0, 360))
        items.append(b"\x05" + ber_encode(len(heading_b)) + heading_b)

    lat_b = float_to_bytes(lat, (-(2**31 - 1), 2**31 - 1), (-90, 90))
    items.append(b"\x0d" + ber_encode(len(lat_b)) + lat_b)

    lon_b = float_to_bytes(lon, (-(2**31 - 1), 2**31 - 1), (-180, 180))
    items.append(b"\x0e" + ber_encode(len(lon_b)) + lon_b)

    alt_b = float_to_bytes(alt, (0, 2**16 - 1), (-900, 19000))
    items.append(b"\x0f" + ber_encode(len(alt_b)) + alt_b)

    vs_b = float_to_bytes(vertical_speed_mps, (-(2**15 - 1), 2**15 - 1), (-180, 180))
    items.append(b"\x33" + ber_encode(len(vs_b)) + vs_b)

    gs = max(0.0, min(255.0, ground_speed_mps))
    gs_b = float_to_bytes(gs, (0, 2**8 - 1), (0, 255))
    items.append(b"\x38" + ber_encode(len(gs_b)) + gs_b)

    # UAS LS version
    items.append(b"\x41" + ber_encode(1) + bytes([9]))

    value = b"".join(items) + b"\x01\x02\x00\x00"
    packet = UAS_KEY + ber_encode(len(value)) + value
    return packet[:-2] + packet_checksum(packet)


def parse_dji_srt(path: Path) -> list[GpsCue]:
    text = path.read_text(errors="ignore")
    blocks = re.split(r"\n\s*\n", text.strip())
    cues: list[GpsCue] = []

    for block in blocks:
        geo = re.search(
            r"latitude:\s*([-\d.]+).*?longitude:\s*([-\d.]+).*?altitude:\s*([-\d.]+)",
            block,
            re.I | re.S,
        )
        if not geo:
            continue
        lat, lon, alt = map(float, geo.groups())

        ts_match = re.search(
            r"(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2})[,.](\d+)",
            block,
        )
        if ts_match:
            base = datetime.strptime(ts_match.group(1), "%Y-%m-%d %H:%M:%S").replace(
                tzinfo=timezone.utc
            )
            frac = ts_match.group(2)[:6].ljust(6, "0")
            ts = base.replace(microsecond=int(frac))
        else:
            # Fall back to synthetic timeline (~30 fps)
            ts = datetime.fromtimestamp(len(cues) / 30.0, tz=timezone.utc)

        cues.append(GpsCue(ts, lat, lon, alt))

    return cues


def probe_has_data_stream(path: Path) -> bool:
    """True when the file carries an in-band data/KLV elementary stream.

    Detection is content-based (ffprobe), not filename — ``Truck.H264`` and
    ``Esri_multiplexer_0.mp4`` are MPEG-TS with KLVA despite their extensions.
    """
    try:
        out = subprocess.check_output(
            [
                "ffprobe",
                "-v",
                "error",
                "-show_entries",
                "stream=codec_type,codec_name",
                "-of",
                "csv=p=0",
                str(path),
            ],
            text=True,
        )
        for line in out.splitlines():
            parts = [p.strip().lower() for p in line.split(",") if p.strip()]
            if not parts:
                continue
            if "data" in parts or "klv" in parts:
                return True
        return False
    except Exception:
        return False


def probe_is_mpegts(path: Path) -> bool:
    """True when ffprobe reports an MPEG-TS container (ignore the file extension)."""
    try:
        out = subprocess.check_output(
            [
                "ffprobe",
                "-v",
                "error",
                "-show_entries",
                "format=format_name",
                "-of",
                "csv=p=0",
                str(path),
            ],
            text=True,
        ).strip().lower()
        return "mpegts" in out
    except Exception:
        return False


TS_PKT = 188
KLV_PID = 0x1F1


def write_klv_from_srt(srt_path: Path, klv_path: Path) -> int:
    """Write concatenated raw UAS packets (no transport timing). Prefer timed mux."""
    timed = timed_klv_from_srt(srt_path)
    with klv_path.open("wb") as fh:
        for _pts, packet in timed:
            fh.write(packet)
    return len(timed)


def timed_klv_from_srt(srt_path: Path) -> list[tuple[int, bytes]]:
    """Return (pts_90khz, uas_packet) aligned to SRT cue times from t0."""
    cues = parse_dji_srt(srt_path)
    if not cues:
        raise SystemExit(f"no GPS telemetry cues found in {srt_path}")

    motion = infer_motion(cues)
    t0 = cues[0].ts
    out: list[tuple[int, bytes]] = []
    for cue, sample in zip(cues, motion):
        pts = int(round((cue.ts - t0).total_seconds() * 90_000))
        packet = encode_uas_packet(
            cue.lat,
            cue.lon,
            cue.alt,
            cue.ts,
            heading_deg=sample.heading_deg,
            ground_speed_mps=sample.ground_speed_mps,
            vertical_speed_mps=sample.vertical_speed_mps,
        )
        out.append((max(0, pts), packet))
    return out


def ber_length(data: bytes, offset: int) -> tuple[int, int]:
    first = data[offset]
    if first < 0x80:
        return first, offset + 1
    n = first & 0x7F
    length = int.from_bytes(data[offset + 1 : offset + 1 + n], "big")
    return length, offset + 1 + n


def split_uas_packets(blob: bytes) -> list[bytes]:
    """Split a concatenated raw .klv blob into individual UAS LS packets."""
    packets: list[bytes] = []
    i = 0
    while i < len(blob):
        idx = blob.find(UAS_KEY, i)
        if idx < 0:
            break
        try:
            length, after = ber_length(blob, idx + 16)
        except Exception:
            break
        end = after + length
        if end > len(blob):
            break
        packets.append(blob[idx:end])
        i = end
    return packets


def probe_duration_s(path: Path) -> float:
    try:
        out = subprocess.check_output(
            [
                "ffprobe",
                "-v",
                "error",
                "-show_entries",
                "format=duration",
                "-of",
                "csv=p=0",
                str(path),
            ],
            text=True,
        ).strip()
        return max(0.0, float(out))
    except Exception:
        return 0.0


def timed_klv_from_raw(klv_path: Path, video: Path) -> list[tuple[int, bytes]]:
    """Space raw KLV packets evenly across the video duration (best-effort)."""
    packets = split_uas_packets(klv_path.read_bytes())
    if not packets:
        raise SystemExit(f"no UAS packets found in {klv_path}")
    duration = probe_duration_s(video)
    if len(packets) == 1 or duration <= 0:
        return [(0, packets[0])]
    last = len(packets) - 1
    return [
        (int(round(i * duration / last * 90_000)), packet) for i, packet in enumerate(packets)
    ]


def mpeg_crc32(data: bytes) -> int:
    crc = 0xFFFFFFFF
    for byte in data:
        crc ^= byte << 24
        for _ in range(8):
            if crc & 0x80000000:
                crc = ((crc << 1) ^ 0x04C11DB7) & 0xFFFFFFFF
            else:
                crc = (crc << 1) & 0xFFFFFFFF
    return crc


def encode_pts_bytes(pts: int) -> bytes:
    pts &= (1 << 33) - 1
    return bytes(
        [
            0x20 | (((pts >> 30) & 0x7) << 1) | 1,
            (pts >> 22) & 0xFF,
            (((pts >> 15) & 0x7F) << 1) | 1,
            (pts >> 7) & 0xFF,
            ((pts & 0x7F) << 1) | 1,
        ]
    )


def make_klv_pes(payload: bytes, pts_90k: int) -> bytes:
    optional = bytes([0x80, 0x80, 0x05]) + encode_pts_bytes(pts_90k)
    plen = len(optional) + len(payload)
    if plen > 0xFFFF:
        raise ValueError("KLV PES payload too large")
    return b"\x00\x00\x01\xbd" + plen.to_bytes(2, "big") + optional + payload


def packetize_pes(pes: bytes, pid: int, cc: int) -> tuple[list[bytes], int]:
    """Fragment a PES into 188-byte TS packets."""
    out: list[bytes] = []
    data = pes
    first = True
    while data:
        payload_unit_start = first
        first = False
        header = bytearray(
            [0x47, (0x40 if payload_unit_start else 0) | ((pid >> 8) & 0x1F), pid & 0xFF, 0]
        )
        adaptation = bytearray()
        avail = TS_PKT - 4
        if len(data) < avail:
            stuff = avail - len(data)
            if stuff == 1:
                adaptation = bytearray([0x00])
            else:
                adaptation = bytearray([stuff - 1, 0x00]) + bytearray([0xFF] * (stuff - 2))
            avail = TS_PKT - 4 - len(adaptation)
        chunk, data = data[:avail], data[avail:]
        if adaptation:
            header[3] = 0x30 | (cc & 0x0F)
            out.append(bytes(header) + bytes(adaptation) + chunk)
        else:
            header[3] = 0x10 | (cc & 0x0F)
            out.append(bytes(header) + chunk)
        cc = (cc + 1) & 0x0F
    return out, cc


def ts_pid(pkt: bytes) -> int:
    return ((pkt[1] & 0x1F) << 8) | pkt[2]


def ts_payload(pkt: bytes) -> tuple[int, bytes]:
    afc = (pkt[3] >> 4) & 0x3
    off = 4
    if afc in (2, 3):
        off = 5 + pkt[4]
    return off, pkt[off:]


def ts_pcr_90k(pkt: bytes) -> int | None:
    afc = (pkt[3] >> 4) & 0x3
    if afc not in (2, 3) or pkt[4] < 1:
        return None
    if not (pkt[5] & 0x10):
        return None
    b = pkt[6:12]
    return (b[0] << 25) | (b[1] << 17) | (b[2] << 9) | (b[3] << 1) | (b[4] >> 7)


def ts_pes_pts_90k(pkt: bytes) -> int | None:
    if not (pkt[1] & 0x40):
        return None
    _off, payload = ts_payload(pkt)
    if len(payload) < 14 or payload[0:3] != b"\x00\x00\x01":
        return None
    if not (payload[7] & 0x80):
        return None
    b = payload[9:14]
    return (
        ((b[0] >> 1) & 7) << 30
        | b[1] << 22
        | ((b[2] >> 1) & 0x7F) << 15
        | b[3] << 7
        | (b[4] >> 1) & 0x7F
    )


def find_pmt_pids(data: bytes) -> set[int]:
    pids: set[int] = set()
    for i in range(0, len(data) - TS_PKT + 1, TS_PKT):
        pkt = data[i : i + TS_PKT]
        if pkt[0] != 0x47 or ts_pid(pkt) != 0 or not (pkt[1] & 0x40):
            continue
        _off, payload = ts_payload(pkt)
        if not payload:
            continue
        section = payload[1 + payload[0] :]
        if len(section) < 8 or section[0] != 0x00:
            continue
        section_len = ((section[1] & 0x0F) << 8) | section[2]
        body = section[3 : 3 + section_len]
        pos = 5
        while pos + 4 <= len(body) - 4:
            prog_num = (body[pos] << 8) | body[pos + 1]
            pid = ((body[pos + 2] & 0x1F) << 8) | body[pos + 3]
            pos += 4
            if prog_num != 0:
                pids.add(pid)
    return pids


def patch_pmt_add_klv(section: bytes, klv_pid: int) -> bytes | None:
    if not section or section[0] != 0x02:
        return None
    section_len = ((section[1] & 0x0F) << 8) | section[2]
    body = bytearray(section[3 : 3 + section_len - 4])
    if len(body) < 9:
        return None
    prog_info_len = ((body[7] & 0x0F) << 8) | body[8]
    pos = 9 + prog_info_len
    while pos + 5 <= len(body):
        es_pid = ((body[pos + 1] & 0x1F) << 8) | body[pos + 2]
        es_info_len = ((body[pos + 3] & 0x0F) << 8) | body[pos + 4]
        if es_pid == klv_pid:
            return None
        pos += 5 + es_info_len
    reg = bytes([0x05, 0x04]) + b"KLVA"
    es = bytes([0x06, 0xE0 | ((klv_pid >> 8) & 0x1F), klv_pid & 0xFF, 0xF0, len(reg)]) + reg
    body.extend(es)
    body[2] = (body[2] & 0xC1) | (((((body[2] >> 1) & 0x1F) + 1) & 0x1F) << 1)
    new_len = len(body) + 4
    sec = bytes([0x02, 0xB0 | ((new_len >> 8) & 0x0F), new_len & 0xFF]) + bytes(body)
    return sec + mpeg_crc32(sec).to_bytes(4, "big")


def rewrite_pmt_add_klv_stream(data: bytes, klv_pid: int = KLV_PID) -> bytes:
    """Insert a KLVA private-data ES into every PMT that lacks ``klv_pid``."""
    pmt_pids = find_pmt_pids(data)
    out = bytearray()
    for i in range(0, len(data) - TS_PKT + 1, TS_PKT):
        pkt = bytearray(data[i : i + TS_PKT])
        if ts_pid(pkt) in pmt_pids and (pkt[1] & 0x40):
            _off, payload = ts_payload(pkt)
            if payload:
                pointer = payload[0]
                section = bytes(payload[1 + pointer :])
                if section and section[0] == 0x02:
                    sl = ((section[1] & 0x0F) << 8) | section[2]
                    section = section[: 3 + sl]
                    patched = patch_pmt_add_klv(section, klv_pid)
                    if patched:
                        new_payload = bytes([0x00]) + patched
                        if len(new_payload) <= 184:
                            new_payload = new_payload + bytes([0xFF] * (184 - len(new_payload)))
                            pkt = bytearray(
                                [0x47, pkt[1], pkt[2], 0x10 | (pkt[3] & 0x0F)]
                            ) + new_payload
        out.extend(pkt)
    return bytes(out)


def run_ffmpeg(args: list[str]) -> None:
    cmd = ["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", *args]
    subprocess.check_call(cmd)


def remux_av_to_ts(video: Path, output: Path) -> None:
    run_ffmpeg(
        [
            "-i",
            str(video),
            "-map",
            "0:v:0?",
            "-map",
            "0:a:0?",
            "-c",
            "copy",
            "-f",
            "mpegts",
            str(output),
        ]
    )


def mux_video_with_timed_klv(
    video: Path, timed_klv: list[tuple[int, bytes]], output: Path
) -> None:
    """Remux A/V then interleave PTS-timed KLV PES into the MPEG-TS.

    FFmpeg's raw ``-f data`` mux (and remux of a separate KLV TS) drops or
    collapses data-stream PTS, which makes research tools see a KLV burst.
    Interleaving ourselves keeps one PTS per MISB packet aligned to cue time
    so ``ffmpeg -re`` Public-feed republish paces telemetry with video.
    """
    if not timed_klv:
        raise SystemExit("no timed KLV packets to mux")

    with tempfile.TemporaryDirectory() as tmp:
        video_ts = Path(tmp) / "av.ts"
        remux_av_to_ts(video, video_ts)
        av = rewrite_pmt_add_klv_stream(video_ts.read_bytes(), KLV_PID)

        klv_cc = 0
        events: list[tuple[int, list[bytes]]] = []
        for pts_90k, payload in timed_klv:
            pes = make_klv_pes(payload, pts_90k)
            pkts, klv_cc = packetize_pes(pes, KLV_PID, klv_cc)
            events.append((pts_90k, pkts))

        out_packets: list[bytes] = []
        last_t = 0
        ki = 0
        for i in range(0, len(av) - TS_PKT + 1, TS_PKT):
            pkt = av[i : i + TS_PKT]
            pts = ts_pes_pts_90k(pkt)
            pcr = ts_pcr_90k(pkt)
            if pts is not None:
                last_t = pts
            elif pcr is not None:
                last_t = pcr
            while ki < len(events) and events[ki][0] <= last_t:
                out_packets.extend(events[ki][1])
                ki += 1
            out_packets.append(pkt)
        while ki < len(events):
            out_packets.extend(events[ki][1])
            ki += 1

        output.write_bytes(b"".join(out_packets))


def remux_ts(video: Path, output: Path) -> None:
    run_ffmpeg(["-i", str(video), "-map", "0", "-c", "copy", "-f", "mpegts", str(output)])


def remux_video_only(video: Path, output: Path) -> None:
    remux_av_to_ts(video, output)


def stamp_klva(path: Path) -> None:
    """Ensure private-data streams carry the KLVA registration descriptor."""
    script = Path(__file__).with_name("stamp_klva_descriptor.py")
    subprocess.check_call([sys.executable, str(script), str(path)])


def build(video: Path, output: Path, srt: Path | None, klv: Path | None) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    ext = video.suffix.lower()
    has_data = probe_has_data_stream(video)
    is_ts = ext in TS_EXTS or probe_is_mpegts(video)

    # In-band KLV/data wins over the filename — remux every stream as-is.
    if has_data and not srt and not klv:
        remux_ts(video, output)
        stamp_klva(output)
        print(f"passthrough TS+data → {output}", file=sys.stderr)
        return

    # Prefer SRT (has cue times) over raw KLV when both are present.
    if srt and srt.exists():
        timed = timed_klv_from_srt(srt)
        mux_video_with_timed_klv(video, timed, output)
        stamp_klva(output)
        print(
            f"muxed video+srt({len(timed)} cues)→timed-klv → {output}",
            file=sys.stderr,
        )
        return

    if klv and klv.exists():
        timed = timed_klv_from_raw(klv, video)
        mux_video_with_timed_klv(video, timed, output)
        stamp_klva(output)
        print(
            f"muxed video+klv({len(timed)} packets)→timed-klv → {output}",
            file=sys.stderr,
        )
        return

    if is_ts:
        remux_ts(video, output)
        stamp_klva(output)
        print(f"remux TS (no extra metadata) → {output}", file=sys.stderr)
        return

    remux_video_only(video, output)
    print(f"video-only TS (no telemetry sidecar) → {output}", file=sys.stderr)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--video", required=True, type=Path)
    parser.add_argument("--srt", type=Path)
    parser.add_argument("--klv", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    if not args.video.exists():
        raise SystemExit(f"video not found: {args.video}")

    build(args.video, args.output, args.srt, args.klv)


if __name__ == "__main__":
    main()
