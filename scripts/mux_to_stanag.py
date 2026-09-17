#!/usr/bin/env python3
"""Normalize flight assets into a single MPEG-TS with MISB ST 0601 KLV.

Supported inputs:
  - MPEG-TS / MPG that already has a data/KLV stream  → remux/copy
  - Video + DJI .SRT telemetry sidecar                 → SRT→KLV→mux
  - Video + raw .klv sidecar                           → mux

Output is a STANAG-style MPEG-TS research tools can pull over RTSP.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

from klvdata.common import ber_encode, datetime_to_bytes, float_to_bytes, packet_checksum

UAS_KEY = bytes.fromhex("060E2B34020B01010E01030101000000")
TS_EXTS = {".ts", ".mts", ".m2ts", ".mpg", ".mpeg"}


def encode_uas_packet(lat: float, lon: float, alt: float, ts: datetime) -> bytes:
    items: list[bytes] = []
    items.append(b"\x02" + ber_encode(8) + datetime_to_bytes(ts))

    lat_b = float_to_bytes(lat, (-(2**31 - 1), 2**31 - 1), (-90, 90))
    items.append(b"\x0d" + ber_encode(len(lat_b)) + lat_b)

    lon_b = float_to_bytes(lon, (-(2**31 - 1), 2**31 - 1), (-180, 180))
    items.append(b"\x0e" + ber_encode(len(lon_b)) + lon_b)

    alt_b = float_to_bytes(alt, (0, 2**16 - 1), (-900, 19000))
    items.append(b"\x0f" + ber_encode(len(alt_b)) + alt_b)

    # UAS LS version
    items.append(b"\x41" + ber_encode(1) + bytes([9]))

    value = b"".join(items) + b"\x01\x02\x00\x00"
    packet = UAS_KEY + ber_encode(len(value)) + value
    return packet[:-2] + packet_checksum(packet)


def parse_dji_srt(path: Path) -> list[tuple[datetime, float, float, float]]:
    text = path.read_text(errors="ignore")
    blocks = re.split(r"\n\s*\n", text.strip())
    cues: list[tuple[datetime, float, float, float]] = []

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

        cues.append((ts, lat, lon, alt))

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

    with klv_path.open("wb") as fh:
        for ts, lat, lon, alt in cues:
            fh.write(encode_uas_packet(lat, lon, alt, ts))
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


def build(video: Path, output: Path, srt: Path | None, klv: Path | None) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    ext = video.suffix.lower()

    if ext in TS_EXTS and probe_has_data_stream(video) and not srt and not klv:
        remux_ts(video, output)
        print(f"passthrough TS+data → {output}", file=sys.stderr)
        return

    if klv and klv.exists():
        mux_video_and_klv(video, klv, output)
        print(f"muxed video+klv → {output}", file=sys.stderr)
        return

    if srt and srt.exists():
        with tempfile.TemporaryDirectory() as tmp:
            klv_tmp = Path(tmp) / "telemetry.klv"
            n = write_klv_from_srt(srt, klv_tmp)
            mux_video_and_klv(video, klv_tmp, output)
            print(f"muxed video+srt({n} cues)→klv → {output}", file=sys.stderr)
        return

    if ext in TS_EXTS:
        remux_ts(video, output)
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
