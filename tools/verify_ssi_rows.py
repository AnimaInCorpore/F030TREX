#!/usr/bin/env python3
"""Independently verify a full-row SSI shadow stream.

The row binary writes two host-side artifacts:

* ``ssi_rows.res``: framed 16-bit row stream;
* ``ssi_rows.pkt``: source index plus the 26 canonical packet longwords.

This verifier intentionally reimplements the packet DDA in Python instead of
trusting the assembly row walker.  It compares packet headers and the complete
logical event sequence, including shade changes and empty-row skips.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import argparse
from typing import Iterable, List, Sequence, Tuple

from ssi_stream_model import (
    FRAME_FOOTER_MAGIC,
    PACKET_MAGIC,
    ROW_SKIP_MAGIC,
    RUN_MAGIC,
    SHADE_MAGIC,
    StreamError,
    decode_frame,
)


SCREEN_WIDTH = 240
SCREEN_HEIGHT = 224
PACKET_DUMP_MAGIC = 0x52505731  # "RPW1"
PACKET_DUMP_HEADER_WORDS = 4
PACKET_DUMP_RECORD_WORDS = 27  # source index + 26 packet longwords


def s16(value: int) -> int:
    return value - 0x10000 if value & 0x8000 else value


def s8(value: int) -> int:
    return value - 0x100 if value & 0x80 else value


def s32(value: int) -> int:
    value &= 0xFFFFFFFF
    return value - 0x100000000 if value & 0x80000000 else value


def add32(left: int, right: int) -> int:
    return s32(left + right)


def mul32(left: int, right: int) -> int:
    # M68030 MULS.L keeps the low 32 bits used by the subsequent ASR/add path.
    return s32(left * right)


def asr32(value: int, bits: int) -> int:
    return s32(value) >> bits


def q12_product(left: int, right: int) -> int:
    return asr32(mul32(left, right), 12)


def ceil_12(value: int) -> int:
    return asr32(add32(value, 4095), 12)


def unpack_uv(value: int) -> Tuple[int, int]:
    return ((value & 0xFF) << 8, ((value >> 8) & 0xFF) << 8)


def read_be_longs(path: Path) -> List[int]:
    data = path.read_bytes()
    if len(data) % 4:
        raise StreamError(f"{path} is not longword aligned")
    return [int.from_bytes(data[i : i + 4], "big") for i in range(0, len(data), 4)]


@dataclass(frozen=True)
class PacketRef:
    source: int
    words: Tuple[int, ...]


@dataclass(frozen=True)
class StreamPacket:
    source: int
    ot_key: int
    shade_tint: int
    flags: int
    du_dx: int
    dv_dx: int
    row_count: int
    y_start: int
    events: Tuple[Tuple[object, ...], ...]


def load_packet_dump(path: Path) -> Tuple[int, int, Tuple[PacketRef, ...]]:
    values = read_be_longs(path)
    if len(values) < PACKET_DUMP_HEADER_WORDS:
        raise StreamError("packet dump is shorter than its header")
    if values[0] != PACKET_DUMP_MAGIC:
        raise StreamError("bad packet dump magic")
    packet_count = values[2]
    if values[3] != PACKET_DUMP_RECORD_WORDS:
        raise StreamError("unexpected packet dump record size")
    expected = PACKET_DUMP_HEADER_WORDS + packet_count * PACKET_DUMP_RECORD_WORDS
    if len(values) != expected:
        raise StreamError(
            f"packet dump length is {len(values)} longs, expected {expected}"
        )
    packets: List[PacketRef] = []
    index = PACKET_DUMP_HEADER_WORDS
    for _ in range(packet_count):
        source = values[index]
        packets.append(
            PacketRef(
                source=source,
                words=tuple(values[index + 1 : index + PACKET_DUMP_RECORD_WORDS]),
            )
        )
        index += PACKET_DUMP_RECORD_WORDS
    return values[1], packet_count, tuple(packets)


def decode_row_stream(path: Path) -> Tuple[int, Tuple[StreamPacket, ...]]:
    data = path.read_bytes()
    if len(data) % 2:
        raise StreamError("row stream is not word aligned")
    words = [int.from_bytes(data[i : i + 2], "big") for i in range(0, len(data), 2)]
    frame = decode_frame(words)
    if words[-6] != FRAME_FOOTER_MAGIC:
        raise StreamError("row stream footer was not preserved")

    packets: List[StreamPacket] = []
    index = 8
    body_end = len(words) - 6
    while index < body_end:
        marker = words[index]
        if marker < PACKET_MAGIC or marker >= 0xF000:
            raise StreamError(f"expected packet marker at word {index}")
        row_count = marker & 0x0FFF
        source = words[index + 1]
        ot_key = (words[index + 2] << 16) | words[index + 3]
        shade_tint = words[index + 4]
        flags = words[index + 5]
        du_dx = words[index + 6]
        dv_dx = words[index + 7]
        y_start = s16(words[index + 8])
        index += 9

        logical_rows = 0
        y = y_start
        shade = shade_tint & 0xF
        events: List[Tuple[object, ...]] = []
        while logical_rows < row_count:
            control = words[index]
            if control & 0xFF00 == SHADE_MAGIC:
                shade = control & 0xF
                events.append(("shade", shade))
                index += 1
                continue
            if control & 0xFF00 == ROW_SKIP_MAGIC:
                skipped = (control & 0xFF) + 1
                if logical_rows + skipped > row_count:
                    raise StreamError("ROW_SKIP exceeds packet row count")
                events.append(("skip", skipped))
                logical_rows += skipped
                y += skipped
                index += 1
                continue
            if control & 0xFF00 == RUN_MAGIC:
                run_length = (control & 0xFF) + 1
                if run_length < 3 or logical_rows + run_length > row_count:
                    raise StreamError("invalid RUN16 length")
                packed = words[index + 1]
                x0 = packed >> 8
                count = (packed & 0xFF) + 1
                u = words[index + 2]
                v = words[index + 3]
                delta = words[index + 4]
                dx = s8(delta >> 8)
                dcount = s8(delta & 0xFF)
                du = s16(words[index + 5])
                dv = s16(words[index + 6])
                for _ in range(run_length):
                    events.append(("row", y, x0, count, u, v, shade))
                    x0 += dx
                    count += dcount
                    u = (u + du) & 0xFFFF
                    v = (v + dv) & 0xFFFF
                    y += 1
                logical_rows += run_length
                index += 7
                continue

            packed = control
            events.append(("row", y, packed >> 8, (packed & 0xFF) + 1,
                           words[index + 1], words[index + 2], shade))
            logical_rows += 1
            y += 1
            index += 3

        packets.append(
            StreamPacket(
                source=source,
                ot_key=ot_key,
                shade_tint=shade_tint,
                flags=flags,
                du_dx=du_dx,
                dv_dx=dv_dx,
                row_count=row_count,
                y_start=y_start,
                events=tuple(events),
            )
        )

    if index != body_end or len(packets) != len(frame.packets):
        raise StreamError("row stream packet count/body length mismatch")
    return frame.frame_id, tuple(packets)


def walk_half(
    state: List[int],
    rows: int,
    sl: int,
    sr: int,
    dul: int,
    dvl: int,
    dlvl: int,
    du_dx: int,
    dv_dx: int,
    current_shade: List[int],
    events: List[Tuple[object, ...]],
) -> None:
    y, xl, xr, ul, vl, level = state

    if y < 0:
        catchup = min(rows, -y)
        rows -= catchup
        y = add32(y, catchup)
        xl = add32(xl, mul32(sl, catchup))
        xr = add32(xr, mul32(sr, catchup))
        ul = add32(ul, mul32(dul, catchup))
        vl = add32(vl, mul32(dvl, catchup))
        level = add32(level, mul32(dlvl, catchup))

    if y + rows > SCREEN_HEIGHT:
        rows = SCREEN_HEIGHT - y
    if rows <= 0:
        state[:] = [y, xl, xr, ul, vl, level]
        return

    for _ in range(rows):
        x0 = ceil_12(xl)
        x1 = ceil_12(xr) - 1
        u = ul
        v = vl
        fraction = (~add32(xl, 4095)) & 0xFFF
        if fraction:
            u = add32(u, q12_product(du_dx, fraction))
            v = add32(v, q12_product(dv_dx, fraction))

        if x0 < 0:
            clipped = -x0
            u = add32(u, mul32(du_dx, clipped))
            v = add32(v, mul32(dv_dx, clipped))
            x0 = 0
        if x1 > SCREEN_WIDTH - 1:
            x1 = SCREEN_WIDTH - 1

        if x0 > x1:
            events.append(("skip", 1))
        else:
            selected = asr32(level, 8)
            selected = max(0, min(15, selected))
            if selected != current_shade[0]:
                events.append(("shade", selected))
                current_shade[0] = selected
            events.append(("row", y, x0, x1 - x0 + 1,
                           u & 0xFFFF, v & 0xFFFF, current_shade[0]))

        xl = add32(xl, sl)
        xr = add32(xr, sr)
        ul = add32(ul, dul)
        vl = add32(vl, dvl)
        level = add32(level, dlvl)
        y += 1

    state[:] = [y, xl, xr, ul, vl, level]


def reference_packet(packet: PacketRef) -> StreamPacket | None:
    w = packet.words
    if len(w) != 26:
        raise StreamError("packet sidecar record does not contain 26 longwords")

    sy0 = s32(w[4])
    rows_up = s32(w[5])
    rows_low = s32(w[6])
    total_rows = rows_up + rows_low
    y_end = sy0 + total_rows
    y_start = max(0, sy0)
    y_stop = min(SCREEN_HEIGHT, y_end)
    visible_rows = y_stop - y_start
    if visible_rows <= 0:
        return None

    du_dx = s32(w[13])
    dv_dx = s32(w[14])
    state = [
        sy0,
        s32(w[8]),
        s32(w[8]),
        unpack_uv(w[19])[0],
        unpack_uv(w[19])[1],
        s32(w[21]),
    ]
    current_shade = [w[0] & 0xF]
    events: List[Tuple[object, ...]] = []

    mid_left = w[7] != 0
    if not mid_left:
        walk_half(state, rows_up, s32(w[9]), s32(w[10]),
                  s32(w[15]), s32(w[16]), s32(w[24]),
                  du_dx, dv_dx, current_shade, events)
        if rows_low:
            state[2] = s32(w[12])
            walk_half(state, rows_low, s32(w[9]), s32(w[11]),
                      s32(w[15]), s32(w[16]), s32(w[25]),
                      du_dx, dv_dx, current_shade, events)
    else:
        walk_half(state, rows_up, s32(w[10]), s32(w[9]),
                  s32(w[15]), s32(w[16]), s32(w[24]),
                  du_dx, dv_dx, current_shade, events)
        if rows_low:
            state[1] = s32(w[12])
            state[3], state[4] = unpack_uv(w[20])
            state[5] = s32(w[22])
            walk_half(state, rows_low, s32(w[11]), s32(w[9]),
                      s32(w[17]), s32(w[18]), s32(w[25]),
                      du_dx, dv_dx, current_shade, events)

    return StreamPacket(
        source=packet.source & 0xFFFF,
        ot_key=w[2],
        shade_tint=w[0] & 0xFFFF,
        flags=0,
        du_dx=du_dx & 0xFFFF,
        dv_dx=dv_dx & 0xFFFF,
        row_count=visible_rows,
        y_start=y_start,
        events=tuple(events),
    )


def compare(expected: Sequence[StreamPacket], actual: Sequence[StreamPacket]) -> None:
    if len(expected) != len(actual):
        raise StreamError(f"visible packet count differs: expected {len(expected)}, got {len(actual)}")
    for packet_index, (want, got) in enumerate(zip(expected, actual)):
        for field in ("source", "ot_key", "shade_tint", "flags", "du_dx", "dv_dx", "row_count", "y_start"):
            expected_value = getattr(want, field)
            actual_value = getattr(got, field)
            if expected_value != actual_value:
                raise StreamError(
                    f"packet {packet_index} {field} differs: "
                    f"expected {expected_value!r}, got {actual_value!r}"
                )
        if want.events != got.events:
            for event_index, (expected_event, actual_event) in enumerate(zip(want.events, got.events)):
                if expected_event != actual_event:
                    raise StreamError(
                        f"packet {packet_index} event {event_index} differs: "
                        f"expected {expected_event!r}, got {actual_event!r}"
                    )
            raise StreamError(
                f"packet {packet_index} event count differs: "
                f"expected {len(want.events)}, got {len(got.events)}"
            )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("stream", type=Path, help="ssi_rows.res path")
    parser.add_argument("packets", type=Path, help="ssi_rows.pkt path")
    args = parser.parse_args()

    frame_id, packet_count, packet_refs = load_packet_dump(args.packets)
    stream_frame_id, actual = decode_row_stream(args.stream)
    if frame_id != stream_frame_id:
        raise SystemExit(f"frame id differs: packet dump {frame_id}, stream {stream_frame_id}")
    if packet_count != len(packet_refs):
        raise SystemExit("packet dump count is inconsistent")

    expected = [reference for packet in packet_refs if (reference := reference_packet(packet)) is not None]
    compare(expected, actual)

    logical_rows = sum(packet.row_count for packet in actual)
    nonempty_rows = sum(1 for packet in actual for event in packet.events if event[0] == "row")
    skipped_rows = sum(event[1] for packet in actual for event in packet.events if event[0] == "skip")
    shade_controls = sum(1 for packet in actual for event in packet.events if event[0] == "shade")
    print(
        "ssi_rows: verified "
        f"{len(actual)} packets, {logical_rows} logical rows, "
        f"{nonempty_rows} ROW_ABS rows, {skipped_rows} ROW_SKIP rows, "
        f"{shade_controls} SET_SHADE controls"
    )


if __name__ == "__main__":
    main()
