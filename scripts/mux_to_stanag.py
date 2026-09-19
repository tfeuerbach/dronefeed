#!/usr/bin/env python3
"""Normalize flight assets into a single MPEG-TS with MISB ST 0601 KLV.

Supported inputs:
  - MPEG-TS / MPG that already has a data/KLV stream  → remux/copy
  - Video + DJI .SRT telemetry sidecar                 → SRT→KLV→mux
  - Video + raw .klv sidecar                           → mux

Consumer DJI .SRT cues typically only carry lat/lon/alt. We still emit those
as sensor position every cue, and derive platform heading + ground/vertical
speed from successive GPS samples over a short lookback window so research
tools can show motion without inventing it from a static pin.

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
    try:
        out = subprocess.check_output(
            [
                "ffprobe",
                "-v",
                "error",
                "-show_entries",
                "stream=codec_type",
                "-of",
                "csv=p=0",
                str(path),
            ],
            text=True,
        )
        return any(line.strip() == "data" for line in out.splitlines())
    except Exception:
        return False


def write_klv_from_srt(srt_path: Path, klv_path: Path) -> int:
    cues = parse_dji_srt(srt_path)
    if not cues:
        raise SystemExit(f"no GPS telemetry cues found in {srt_path}")

    motion = infer_motion(cues)
    with klv_path.open("wb") as fh:
        for cue, sample in zip(cues, motion):
            fh.write(
                encode_uas_packet(
                    cue.lat,
                    cue.lon,
                    cue.alt,
                    cue.ts,
                    heading_deg=sample.heading_deg,
                    ground_speed_mps=sample.ground_speed_mps,
                    vertical_speed_mps=sample.vertical_speed_mps,
                )
            )
    return len(cues)


def run_ffmpeg(args: list[str]) -> None:
    cmd = ["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", *args]
    subprocess.check_call(cmd)


def mux_video_and_klv(video: Path, klv: Path, output: Path) -> None:
    run_ffmpeg(
        [
            "-i",
            str(video),
            "-f",
            "data",
            "-i",
            str(klv),
            "-map",
            "0:v:0?",
            "-map",
            "0:a:0?",
            "-map",
            "1",
            "-c",
            "copy",
            "-f",
            "mpegts",
            str(output),
        ]
    )


def remux_ts(video: Path, output: Path) -> None:
    run_ffmpeg(["-i", str(video), "-map", "0", "-c", "copy", "-f", "mpegts", str(output)])


def remux_video_only(video: Path, output: Path) -> None:
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


def stamp_klva(path: Path) -> None:
    """Ensure private-data streams carry the KLVA registration descriptor."""
    script = Path(__file__).with_name("stamp_klva_descriptor.py")
    subprocess.check_call([sys.executable, str(script), str(path)])


def build(video: Path, output: Path, srt: Path | None, klv: Path | None) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    ext = video.suffix.lower()

    if ext in TS_EXTS and probe_has_data_stream(video) and not srt and not klv:
        remux_ts(video, output)
        stamp_klva(output)
        print(f"passthrough TS+data → {output}", file=sys.stderr)
        return

    if klv and klv.exists():
        mux_video_and_klv(video, klv, output)
        stamp_klva(output)
        print(f"muxed video+klv → {output}", file=sys.stderr)
        return

    if srt and srt.exists():
        with tempfile.TemporaryDirectory() as tmp:
            klv_tmp = Path(tmp) / "telemetry.klv"
            n = write_klv_from_srt(srt, klv_tmp)
            mux_video_and_klv(video, klv_tmp, output)
            stamp_klva(output)
            print(f"muxed video+srt({n} cues)→klv → {output}", file=sys.stderr)
        return

    if ext in TS_EXTS:
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
