#!/usr/bin/env python3
"""Verify the Hatari SSI loopback against the row stream and packet DDA.

The Hatari binary writes ``ssihatri.sta`` after its in-memory consumer
accepts the completed stream.  This verifier checks that sidecar against the
same independent row/packet comparison used by ``verify_ssi_rows.py``.
"""

from __future__ import annotations

import argparse
from pathlib import Path
from struct import unpack

from ssi_stream_model import StreamError, crc16_ccitt, decode_frame
from verify_ssi_rows import (
    compare,
    decode_row_stream,
    load_packet_dump,
    reference_packet,
)


STATUS_MAGIC = 0x48535349  # "HSSI"
STATUS_VERSION = 1
STATUS_LONGS = 23


def read_status(path: Path) -> tuple[int, ...]:
    data = path.read_bytes()
    if len(data) != STATUS_LONGS * 4:
        raise StreamError(
            f"Hatari status has {len(data)} bytes, expected {STATUS_LONGS * 4}"
        )
    return unpack(">23L", data)


def read_stream_words(path: Path) -> list[int]:
    data = path.read_bytes()
    if len(data) % 2:
        raise StreamError("row stream is not word aligned")
    return [int.from_bytes(data[i : i + 2], "big") for i in range(0, len(data), 2)]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("stream", type=Path, help="ssi_rows.res path")
    parser.add_argument("packets", type=Path, help="ssi_rows.pkt path")
    parser.add_argument("status", type=Path, help="ssihatri.sta path")
    args = parser.parse_args()

    status = read_status(args.status)
    if status[0] != STATUS_MAGIC or status[1] != STATUS_VERSION:
        raise SystemExit("Hatari status magic/version mismatch")
    if status[2] != 0:
        raise SystemExit(
            f"Hatari loopback rejected stream: error stage {status[11]}"
        )
    if status[11] != 0:
        raise SystemExit(f"Hatari loopback reported error stage {status[11]}")

    words = read_stream_words(args.stream)
    frame_id, packet_count, packet_refs = load_packet_dump(args.packets)
    stream_frame_id, actual = decode_row_stream(args.stream)
    if frame_id != stream_frame_id:
        raise SystemExit(f"frame id differs: packet dump {frame_id}, stream {stream_frame_id}")
    if packet_count != len(packet_refs):
        raise SystemExit("packet dump count is inconsistent")

    expected = [
        reference
        for packet in packet_refs
        if (reference := reference_packet(packet)) is not None
    ]
    compare(expected, actual)
    decoded = decode_frame(words)

    logical_rows = sum(packet.row_count for packet in actual)
    skipped_rows = sum(
        event[1]
        for packet in actual
        for event in packet.events
        if event[0] == "skip"
    )
    shade_controls = sum(
        1
        for packet in actual
        for event in packet.events
        if event[0] == "shade"
    )
    computed_crc = crc16_ccitt(words[:-6])
    checks = {
        "input words": status[3] == len(words),
        "consumed words": status[4] == len(words),
        "packets": status[5] == len(actual),
        "logical rows": status[6] == logical_rows,
        "skipped rows": status[7] == skipped_rows,
        "shade controls": status[8] == shade_controls,
        "computed CRC": status[9] == computed_crc,
        "footer CRC": status[10] == computed_crc,
        "decoded frame packets": len(decoded.packets) == len(actual),
        "raster feed errors": status[12] == 0,
        "raster feed pixels": status[13] > 0,
        "pending frame matched": status[14] == 1,
        "OT nodes visited": status[15] > 0,
        "mapped packets fed": status[16] > 0,
        "row callbacks": status[17] > 0,
        "status written after feed": status[18] >= 2,
        "resolve completed": status[19] == status[5],
        "visible map entries": status[20] == status[5],
        "missing map entries": status[21] == 0,
        "first missing host packet": status[22] == 0xFFFFFFFF,
    }
    failed = [name for name, passed in checks.items() if not passed]
    if failed:
        raise SystemExit("Hatari loopback sidecar mismatch: " + ", ".join(failed))

    print(
        "ssi_hatari: accepted "
        f"{len(words)} words, {len(actual)} packets, {logical_rows} logical rows, "
        f"{skipped_rows} ROW_SKIP rows, CRC ${computed_crc:04X}; "
        "independent DDA comparison also passed"
    )


if __name__ == "__main__":
    main()
