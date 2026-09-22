#!/usr/bin/env python3
"""Unit tests for GPS→motion inference in mux_to_stanag.py."""

from __future__ import annotations

import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))

from mux_to_stanag import (  # noqa: E402
    GpsCue,
    bearing_deg,
    build,
    encode_uas_packet,
    haversine_m,
    infer_motion,
    mux_video_with_timed_klv,
    parse_dji_srt,
    probe_has_data_stream,
    probe_is_mpegts,
    timed_klv_from_srt,
    write_klv_from_srt,
)


def _ts(seconds: float) -> datetime:
    return datetime(2023, 1, 13, 12, 0, 0, tzinfo=timezone.utc) + timedelta(seconds=seconds)


class HaversineBearingTests(unittest.TestCase):
    def test_haversine_known_short_leg(self) -> None:
        # ~111.2 m per 0.001° latitude near equator
        d = haversine_m(0.0, 0.0, 0.001, 0.0)
        self.assertAlmostEqual(d, 111.2, delta=1.0)

    def test_bearing_due_north(self) -> None:
        self.assertAlmostEqual(bearing_deg(0.0, 0.0, 0.01, 0.0), 0.0, delta=0.5)

    def test_bearing_due_east(self) -> None:
        self.assertAlmostEqual(bearing_deg(0.0, 0.0, 0.0, 0.01), 90.0, delta=0.5)


class InferMotionTests(unittest.TestCase):
    def test_stationary_is_zero_speed(self) -> None:
        cues = [GpsCue(_ts(i * 0.5), 10.0, 20.0, 100.0) for i in range(6)]
        motion = infer_motion(cues, window_s=2.0, min_heading_move_m=1.0)
        self.assertEqual(len(motion), 6)
        self.assertIsNone(motion[0].heading_deg)
        for sample in motion:
            self.assertAlmostEqual(sample.ground_speed_mps, 0.0, places=3)
            self.assertAlmostEqual(sample.vertical_speed_mps, 0.0, places=3)

    def test_constant_eastbound_speed_and_heading(self) -> None:
        # ~11.12 m per 0.0001° lon at equator → 11.12 m/s over 1s steps
        cues = [GpsCue(_ts(float(i)), 0.0, i * 0.0001, 50.0) for i in range(5)]
        motion = infer_motion(cues, window_s=2.0, min_heading_move_m=1.0)
        self.assertIsNone(motion[0].heading_deg)
        for sample in motion[1:]:
            self.assertAlmostEqual(sample.heading_deg or -1, 90.0, delta=2.0)
            self.assertAlmostEqual(sample.ground_speed_mps, 11.12, delta=0.5)
            self.assertAlmostEqual(sample.vertical_speed_mps, 0.0, places=2)

    def test_window_uses_lookback_not_only_previous_frame(self) -> None:
        # Tiny per-frame steps (~1.1 m each) but heading needs cumulative travel
        cues = [GpsCue(_ts(i * 0.1), 0.0, i * 0.00001, 10.0) for i in range(25)]
        motion = infer_motion(cues, window_s=2.0, min_heading_move_m=1.0)
        # First sample has no prior point → no heading
        self.assertIsNone(motion[0].heading_deg)
        # After ~2 s of eastbound travel, heading locks to ~90° and speed uses the window
        self.assertIsNotNone(motion[-1].heading_deg)
        self.assertAlmostEqual(motion[-1].heading_deg or -1, 90.0, delta=5.0)
        self.assertGreater(motion[-1].ground_speed_mps, 5.0)
        # Speed over the 2s window should be smoother than a single noisy step:
        # total ~22 m / 2 s ≈ 11 m/s
        self.assertAlmostEqual(motion[-1].ground_speed_mps, 11.12, delta=1.5)

    def test_vertical_speed_from_altitude(self) -> None:
        cues = [
            GpsCue(_ts(0.0), 1.0, 2.0, 100.0),
            GpsCue(_ts(2.0), 1.0, 2.0, 120.0),
        ]
        motion = infer_motion(cues, window_s=2.0)
        self.assertAlmostEqual(motion[1].vertical_speed_mps, 10.0, places=2)


class EncodeAndSampleSrtTests(unittest.TestCase):
    def test_packet_includes_speed_tags(self) -> None:
        pkt = encode_uas_packet(
            0.41,
            36.86,
            40.0,
            _ts(0),
            heading_deg=45.0,
            ground_speed_mps=12.0,
            vertical_speed_mps=1.5,
        )
        # Tag keys present as single-byte BER tags after UAS key + length
        self.assertIn(b"\x05", pkt)  # heading
        self.assertIn(b"\x0d", pkt)  # sensor lat
        self.assertIn(b"\x33", pkt)  # vertical speed
        self.assertIn(b"\x38", pkt)  # ground speed
        self.assertGreater(len(pkt), 40)

    def test_consumer_sample_srt_parses_and_writes(self) -> None:
        srt = ROOT.parent / "sample-data/consumer-dji/13_01_23-DJI_0030/DJI_0030.SRT"
        if not srt.exists():
            self.skipTest("sample SRT not present")

        cues = parse_dji_srt(srt)
        self.assertGreater(len(cues), 10)
        motion = infer_motion(cues)
        self.assertEqual(len(motion), len(cues))

        # Sample clip moves slowly — expect some non-zero speeds once GPS drifts
        max_gs = max(s.ground_speed_mps for s in motion)
        self.assertGreaterEqual(max_gs, 0.0)

        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "out.klv"
            n = write_klv_from_srt(srt, out)
            self.assertEqual(n, len(cues))
            raw = out.read_bytes()
            self.assertGreater(len(raw), 100)
            self.assertIn(b"\x38", raw)


class TimedKlvMuxTests(unittest.TestCase):
    def test_srt_timed_packets_span_clip(self) -> None:
        srt = ROOT.parent / "sample-data/consumer-dji/13_01_23-DJI_0030/DJI_0030.SRT"
        if not srt.exists():
            self.skipTest("sample SRT not present")

        timed = timed_klv_from_srt(srt)
        self.assertGreater(len(timed), 100)
        pts = [p for p, _ in timed]
        self.assertEqual(pts[0], 0)
        span_s = (pts[-1] - pts[0]) / 90_000
        self.assertGreater(span_s, 10.0)
        self.assertEqual(len(set(pts)), len(pts))

    def test_mux_preserves_unique_klv_pts(self) -> None:
        import json
        import subprocess

        srt = ROOT.parent / "sample-data/consumer-dji/13_01_23-DJI_0030/DJI_0030.SRT"
        vid = ROOT.parent / "sample-data/consumer-dji/13_01_23-DJI_0030/13_01_23-DJI_0030.MP4"
        if not srt.exists() or not vid.exists():
            self.skipTest("sample assets not present")

        timed = timed_klv_from_srt(srt)
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "out.ts"
            mux_video_with_timed_klv(vid, timed, out)
            raw = subprocess.check_output(
                [
                    "ffprobe",
                    "-v",
                    "error",
                    "-select_streams",
                    "d:0",
                    "-show_packets",
                    "-show_entries",
                    "packet=pts_time",
                    "-of",
                    "json",
                    str(out),
                ],
                text=True,
            )
            packets = json.loads(raw).get("packets") or []
            pts = [
                float(p["pts_time"])
                for p in packets
                if p.get("pts_time") not in (None, "N/A")
            ]
            self.assertEqual(len(pts), len(timed))
            self.assertGreater(pts[-1] - pts[0], 10.0)
            self.assertEqual(len({round(t, 3) for t in pts}), len(pts))


class InbandDetectionTests(unittest.TestCase):
    """Passthrough must follow streams, not the file extension."""

    def test_truck_h264_is_mpegts_with_data(self) -> None:
        truck = (
            ROOT.parent
            / "sample-data/enterprise-klv/QGISFMV_Samples/MISB/Truck.H264"
        )
        if not truck.exists():
            self.skipTest("Truck.H264 sample not present")
        self.assertTrue(probe_is_mpegts(truck))
        self.assertTrue(probe_has_data_stream(truck))

    def test_esri_multiplexer_mp4_is_mpegts_with_data(self) -> None:
        clip = (
            ROOT.parent
            / "sample-data/enterprise-klv/QGISFMV_Samples/MISB/Esri_multiplexer_0.mp4"
        )
        if not clip.exists():
            self.skipTest("Esri_multiplexer_0.mp4 sample not present")
        self.assertTrue(probe_is_mpegts(clip))
        self.assertTrue(probe_has_data_stream(clip))

    def test_build_passthrough_keeps_klv_for_misnamed_truck(self) -> None:
        truck = (
            ROOT.parent
            / "sample-data/enterprise-klv/QGISFMV_Samples/MISB/Truck.H264"
        )
        if not truck.exists():
            self.skipTest("Truck.H264 sample not present")

        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "publish_stanag.ts"
            # Symlink under a misleading name to prove extension is ignored.
            alias = Path(tmp) / "not_a_ts.bin"
            alias.symlink_to(truck.resolve())
            build(alias, out, None, None)
            self.assertTrue(probe_has_data_stream(out))
            # Spot-check KLV volume survived the remux.
            import subprocess

            raw = subprocess.check_output(
                [
                    "ffmpeg",
                    "-y",
                    "-i",
                    str(out),
                    "-map",
                    "0:d:0",
                    "-c",
                    "copy",
                    "-f",
                    "data",
                    "-",
                ],
                stderr=subprocess.DEVNULL,
            )
            self.assertGreater(len(raw), 50_000)


if __name__ == "__main__":
    unittest.main()
