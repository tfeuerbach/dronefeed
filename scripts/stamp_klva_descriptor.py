#!/usr/bin/env python3
"""Patch MPEG-TS PMTs so private-data (0x06) streams are tagged as KLVA.

FFmpeg muxes raw `-f data` KLV as stream_type 0x06 without a registration
descriptor. MediaMTX (and STANAG tools) only treat the track as MISB KLV when
the PMT includes registration_descriptor format_identifier = 'KLVA'.

Rewrites the file in place (or to --output).
"""

from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path

KLVA = b"KLVA"
REG_DESC = bytes([0x05, 0x04]) + KLVA  # registration_descriptor
TS_PKT = 188


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


def packet_pid(pkt: bytes) -> int:
    return ((pkt[1] & 0x1F) << 8) | pkt[2]


def payload_of(pkt: bytes) -> tuple[int, bytes]:
    """Return (payload_offset, payload_bytes)."""
    afc = (pkt[3] >> 4) & 0x3
    off = 4
    if afc in (2, 3):
        afl = pkt[4]
        off = 5 + afl
    return off, pkt[off:]


def find_pmt_pids(data: bytes) -> set[int]:
    pids: set[int] = set()
    for i in range(0, len(data) - TS_PKT + 1, TS_PKT):
        pkt = data[i : i + TS_PKT]
        if pkt[0] != 0x47 or packet_pid(pkt) != 0:
            continue
        if not (pkt[1] & 0x40):
            continue
        off, payload = payload_of(pkt)
        if not payload:
            continue
        pointer = payload[0]
        section = payload[1 + pointer :]
        if len(section) < 8 or section[0] != 0x00:
            continue
        # skip table header to program loop
        section_len = ((section[1] & 0x0F) << 8) | section[2]
        body = section[3 : 3 + section_len]
        # program_number(2) + reserved/version/current(1) + section/last(2) = 5
        # then N × (program_number(2) + PID(2))
        pos = 5
        while pos + 4 <= len(body) - 4:  # leave CRC
            prog_num = (body[pos] << 8) | body[pos + 1]
            pid = ((body[pos + 2] & 0x1F) << 8) | body[pos + 3]
            pos += 4
            if prog_num != 0:
                pids.add(pid)
    return pids


def patch_pmt_section(section: bytes) -> bytes | None:
    """Return patched PMT section (with CRC) or None if unchanged/unusable."""
    if len(section) < 12 or section[0] != 0x02:
        return None

    section_len = ((section[1] & 0x0F) << 8) | section[2]
    # section[3..] includes program info through CRC (section_len bytes)
    if 3 + section_len > len(section):
        return None

    full = bytearray(section[: 3 + section_len])
    # strip CRC for rebuild
    body = full[3:-4]
    if len(body) < 9:
        return None

    # body: program_number(2) flags(1) section(1) last(1) PCR(2) prog_info_len(2) ...
    prog_info_len = ((body[7] & 0x0F) << 8) | body[8]
    pos = 9 + prog_info_len
    streams = bytearray()
    changed = False

    while pos + 5 <= len(body):
        stream_type = body[pos]
        es_pid_hi = body[pos + 1]
        es_pid_lo = body[pos + 2]
        es_info_len = ((body[pos + 3] & 0x0F) << 8) | body[pos + 4]
        es_info = body[pos + 5 : pos + 5 + es_info_len]
        pos += 5 + es_info_len

        if stream_type == 0x06 and KLVA not in es_info:
            # Append KLVA registration descriptor.
            es_info = bytes(es_info) + REG_DESC
            changed = True

        new_es_info_len = len(es_info)
        streams.append(stream_type)
        streams.append(es_pid_hi)
        streams.append(es_pid_lo)
        streams.append(0xF0 | ((new_es_info_len >> 8) & 0x0F))
        streams.append(new_es_info_len & 0xFF)
        streams.extend(es_info)

    if not changed:
        return None

    new_body = bytearray(body[:9])
    # keep program_info as-is (already in body[:9+prog_info_len] but we only copied 9;
    # fix: include program descriptors
    new_body = bytearray(body[: 9 + prog_info_len]) + streams
    new_section_len = len(new_body) + 4  # + CRC
    out = bytearray()
    out.append(0x02)
    out.append(0xB0 | ((new_section_len >> 8) & 0x0F))
    out.append(new_section_len & 0xFF)
    out.extend(new_body)
    crc = mpeg_crc32(bytes(out))
    out.extend(struct.pack(">I", crc))
    return bytes(out)


def patch_file(data: bytes) -> tuple[bytes, int]:
    pmt_pids = find_pmt_pids(data)
    if not pmt_pids:
        return data, 0

    buf = bytearray(data)
    patches = 0

    for i in range(0, len(buf) - TS_PKT + 1, TS_PKT):
        pkt = buf[i : i + TS_PKT]
        if pkt[0] != 0x47:
            continue
        pid = packet_pid(pkt)
        if pid not in pmt_pids or not (pkt[1] & 0x40):
            continue

        off, payload = payload_of(bytes(pkt))
        if not payload:
            continue
        pointer = payload[0]
        section_start = 1 + pointer
        if section_start >= len(payload):
            continue
        section = bytes(payload[section_start:])
        patched = patch_pmt_section(section)
        if not patched:
            continue

        # Write patched section back into this packet (single-packet PMTs only).
        room = TS_PKT - off - 1 - pointer
        if len(patched) > room:
            # Multi-packet PMT — skip rather than corrupt.
            continue

        new_payload = bytearray(payload[:section_start]) + patched
        new_payload.extend(b"\xff" * (TS_PKT - off - len(new_payload)))
        buf[i + off : i + TS_PKT] = new_payload[: TS_PKT - off]
        patches += 1

    return bytes(buf), patches


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument("--output", type=Path, help="defaults to in-place")
    args = parser.parse_args()

    data = args.input.read_bytes()
    if len(data) < TS_PKT or data[0] != 0x47:
        raise SystemExit(f"not an MPEG-TS file: {args.input}")

    out, n = patch_file(data)
    dest = args.output or args.input
    if n == 0:
        print(f"no PMT changes needed for {args.input}", file=sys.stderr)
    else:
        dest.write_bytes(out)
        print(f"stamped KLVA on {n} PMT packet(s) → {dest}", file=sys.stderr)


if __name__ == "__main__":
    main()
