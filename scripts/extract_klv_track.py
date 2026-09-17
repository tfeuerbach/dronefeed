#!/usr/bin/env python3
"""Extract lat/lon/alt samples from a MPEG-TS/KLV file or raw .klv into JSON."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path

from klvdata import StreamParser


def extract_raw_klv(path: Path, out: Path) -> None:
    ext = path.suffix.lower()
    if ext == ".klv":
        out.write_bytes(path.read_bytes())
        return

    # Demux data PID(s) to raw KLV bytes
    subprocess.check_call(
        [
            "ffmpeg",
            "-y",
            "-hide_banner",
            "-loglevel",
            "error",
            "-i",
            str(path),
            "-map",
            "0:d:0?",
            "-c",
            "copy",
            "-f",
            "data",
            str(out),
        ]
    )


def packet_items(packet) -> dict:
    items = packet.items
    if callable(items):
        items = items()
    return items


def as_float(element) -> float | None:
    value = getattr(element, "value", None)
    if value is None:
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        inner = getattr(value, "value", None)
        if inner is None:
            return None
        try:
            return float(inner)
        except (TypeError, ValueError):
            return None


def as_timestamp_ms(element) -> int | None:
    value = getattr(element, "value", None)
    if value is None:
        return None
    candidate = getattr(value, "value", value)
    try:
        if hasattr(candidate, "timestamp"):
            return int(candidate.timestamp() * 1000)
    except Exception:
        return None
    return None


def decode_points(klv_bytes: bytes, limit: int = 2000) -> list[dict]:
    points: list[dict] = []
    idx = 0
    t0: int | None = None

    for packet in StreamParser(klv_bytes):
        try:
            items = packet_items(packet)
        except Exception:
            continue

        lat = lon = alt = None
        abs_ms: int | None = None

        for _key, element in items.items():
            name = getattr(element, "name", "") or element.__class__.__name__
            lname = name.lower().replace(" ", "")

            if lname in {"sensorlatitude", "platformlatitude"} or (
                "latitude" in lname
                and "corner" not in lname
                and "frame" not in lname
                and "target" not in lname
            ):
                lat = as_float(element)
            elif lname in {"sensorlongitude", "platformlongitude"} or (
                "longitude" in lname
                and "corner" not in lname
                and "frame" not in lname
                and "target" not in lname
            ):
                lon = as_float(element)
            elif lname in {
                "sensortruealtitude",
                "sensoraltitude",
                "platformaltitude",
                "ellipsoidheight",
            } or ("altitude" in lname and "target" not in lname and "frame" not in lname):
                alt = as_float(element)
            elif "precisiontime" in lname or lname.endswith("timestamp"):
                abs_ms = as_timestamp_ms(element)

        if lat is None or lon is None:
            continue

        if abs_ms is not None:
            if t0 is None:
                t0 = abs_ms
            t_ms = max(abs_ms - t0, 0)
        else:
            t_ms = idx * 33

        points.append(
            {
                "t_ms": t_ms,
                "lat": lat,
                "lon": lon,
                "alt": alt,
                "raw": f"lat={lat:.6f} lon={lon:.6f} alt={alt if alt is not None else '—'}",
            }
        )
        idx += 1
        if len(points) >= limit:
            break

    return points


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    if not args.input.exists():
        raise SystemExit(f"missing input: {args.input}")

    with tempfile.TemporaryDirectory() as tmp:
        raw = Path(tmp) / "raw.klv"
        try:
            extract_raw_klv(args.input, raw)
        except subprocess.CalledProcessError as exc:
            raise SystemExit(f"ffmpeg demux failed: {exc}") from exc

        data = raw.read_bytes()
        if not data:
            raise SystemExit("no KLV/data stream found")

        points = decode_points(data)
        if not points:
            raise SystemExit("KLV present but no lat/lon samples decoded")

        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(points))
        print(f"wrote {len(points)} points → {args.output}", file=sys.stderr)


if __name__ == "__main__":
    main()
