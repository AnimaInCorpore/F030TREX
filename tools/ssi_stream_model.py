#!/usr/bin/env python3
"""Offline model for the Falcon SSI -> DMA-RECORD span stream.

This module deliberately has no Falcon or emulator dependencies.  It is the
canonical framing/validation model used before the physical transport exists.
All wire values are 16-bit big-endian words.  The format keeps the CPU-owned
texture lookup and pixel loop out of the stream: the DSP supplies packet
metadata, horizontal U/V gradients, and clipped row starts.
"""

from __future__ import annotations

from dataclasses import dataclass
import argparse
from typing import Iterable, List, Sequence, Tuple


FRAME_MAGIC = 0x5353
FRAME_VERSION = 1
COMPACT_RECORD_FLAG = 0x8000
FRAME_FOOTER_MAGIC = 0x5AA5
PACKET_MAGIC = 0xE000
COMPACT_RECORD_MAGIC = 0xD012
SHADE_MAGIC = 0xF100
ROW_SKIP_MAGIC = 0xF200
RUN_MAGIC = 0xF000
MAX_SCREEN_WIDTH = 240
MAX_SHADE_LEVEL = 15
DSP_SPAN_RECORD_WORDS = 18


class StreamError(ValueError):
    """Raised for a malformed, incomplete, or inconsistent stream."""


@dataclass(frozen=True)
class Row:
    """One clipped row at the first sampled pixel.

    u and v are Q8.8 values carried modulo 16 bits.  shade is the selected
    CLUT level for the row; tint remains packet state.
    """

    x0: int
    count: int
    u: int
    v: int
    shade: int


@dataclass(frozen=True)
class Packet:
    """One packet; y_start anchors the packet's logical row sequence."""

    source_triangle: int
    ot_key: int
    shade_tint: int
    flags: int
    du_dx: int
    dv_dx: int
    rows: Tuple[Row, ...]
    y_start: int = 0


@dataclass(frozen=True)
class Frame:
    frame_id: int
    mesh_id: int
    generation: int
    capacity_words: int
    packets: Tuple[Packet, ...]
    version_flags: int = FRAME_VERSION


@dataclass(frozen=True)
class CompactRecord:
    """One host-shadowed DSP survivor record.

    The DSP values are native 24-bit words.  source_triangle is supplied by
    the host while draining a chunk because the DSP's packed w0 carries only
    the five-bit chunk-local index.
    """

    source_triangle: int
    words: Tuple[int, ...]


@dataclass(frozen=True)
class CompactFrame:
    """A framed mirror of the DSP's packed survivor records."""

    frame_id: int
    mesh_id: int
    generation: int
    capacity_words: int
    records: Tuple[CompactRecord, ...]
    version_flags: int = FRAME_VERSION | COMPACT_RECORD_FLAG


def _u16(value: int, name: str = "word") -> int:
    if not 0 <= value <= 0xFFFF:
        raise StreamError(f"{name} is not a 16-bit value: {value}")
    return value


def _s8(value: int) -> int:
    return value - 0x100 if value & 0x80 else value


def _s16(value: int) -> int:
    return value - 0x10000 if value & 0x8000 else value


def _split_u32(value: int, name: str) -> Tuple[int, int]:
    if not 0 <= value <= 0xFFFFFFFF:
        raise StreamError(f"{name} is not a 32-bit value: {value}")
    return value >> 16, value & 0xFFFF


def _validate_compact_record(record: CompactRecord) -> None:
    if not 0 <= record.source_triangle <= 0xFFFFFFFF:
        raise StreamError("compact source triangle is not a 32-bit value")
    if len(record.words) != DSP_SPAN_RECORD_WORDS:
        raise StreamError(
            "compact record must contain "
            f"{DSP_SPAN_RECORD_WORDS} native DSP words"
        )
    for index, word in enumerate(record.words):
        if not 0 <= word <= 0xFFFFFF:
            raise StreamError(f"compact record word {index} is not 24-bit: {word}")


def crc16_ccitt(words: Iterable[int]) -> int:
    """CRC-16/CCITT-FALSE over the big-endian byte representation."""

    crc = 0xFFFF
    for word in words:
        _u16(word)
        for byte in (word >> 8, word & 0xFF):
            crc ^= byte << 8
            for _ in range(8):
                crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


def _validate_row(row: Row) -> None:
    if not 0 <= row.x0 < MAX_SCREEN_WIDTH:
        raise StreamError(f"row x0 outside render target: {row.x0}")
    if not 1 <= row.count <= 256 or row.x0 + row.count > MAX_SCREEN_WIDTH:
        raise StreamError(f"row span outside render target: x0={row.x0}, count={row.count}")
    _u16(row.u, "row.u")
    _u16(row.v, "row.v")
    if not 0 <= row.shade <= MAX_SHADE_LEVEL:
        raise StreamError(f"row shade outside 0..15: {row.shade}")


def _validate_packet(packet: Packet) -> None:
    if not 0 <= packet.source_triangle <= 0xFFFF:
        raise StreamError("source triangle is not a 16-bit value")
    _u16(packet.shade_tint, "packet.shade_tint")
    _u16(packet.flags, "packet.flags")
    _u16(packet.du_dx & 0xFFFF, "packet.du_dx")
    _u16(packet.dv_dx & 0xFFFF, "packet.dv_dx")
    if not -32768 <= packet.y_start <= 32767:
        raise StreamError("packet.y_start is not a signed 16-bit value")
    if not packet.rows or len(packet.rows) > 0x0FFF:
        raise StreamError("packet must contain 1..4095 rows")
    for row in packet.rows:
        _validate_row(row)


def _encode_row_abs(row: Row) -> List[int]:
    _validate_row(row)
    return [((row.x0 & 0xFF) << 8) | ((row.count - 1) & 0xFF), row.u, row.v]


def _row_delta(a: Row, b: Row) -> Tuple[int, int, int, int] | None:
    dx = b.x0 - a.x0
    dcount = b.count - a.count
    du = _s16((b.u - a.u) & 0xFFFF)
    dv = _s16((b.v - a.v) & 0xFFFF)
    if not -128 <= dx <= 127 or not -128 <= dcount <= 127:
        return None
    return dx, dcount, du, dv


def _shade_groups(rows: Sequence[Row]) -> Iterable[Tuple[int, int]]:
    start = 0
    while start < len(rows):
        end = start + 1
        while end < len(rows) and rows[end].shade == rows[start].shade:
            end += 1
        yield start, end
        start = end


def _encode_packet_body(packet: Packet) -> List[int]:
    words: List[int] = []
    current_shade = packet.shade_tint & 0xF

    for group_start, group_end in _shade_groups(packet.rows):
        group = packet.rows[group_start:group_end]
        if group[0].shade != current_shade:
            words.append(SHADE_MAGIC | group[0].shade)
            current_shade = group[0].shade

        # A RUN16 contains its initial absolute row and at least two following
        # rows.  Extend only while the same constant modulo-16-bit delta holds.
        pos = 0
        while pos < len(group):
            run_end = pos + 1
            delta = _row_delta(group[pos], group[pos + 1]) if pos + 1 < len(group) else None
            if delta is not None:
                while run_end < len(group) and run_end - pos < 256:
                    if _row_delta(group[run_end - 1], group[run_end]) != delta:
                        break
                    run_end += 1
            run_length = run_end - pos
            if run_length >= 3:
                dx, dcount, du, dv = delta  # type: ignore[misc]
                words.append(RUN_MAGIC | (run_length - 1))
                words.extend(_encode_row_abs(group[pos]))
                words.append(((dx & 0xFF) << 8) | (dcount & 0xFF))
                words.extend((du & 0xFFFF, dv & 0xFFFF))
                pos = run_end
            else:
                words.extend(_encode_row_abs(group[pos]))
                pos += 1
    return words


def encode_frame(frame: Frame) -> List[int]:
    """Encode a frame and return its complete stream as 16-bit words."""

    frame_hi, frame_lo = _split_u32(frame.frame_id, "frame_id")
    if not 0 <= frame.mesh_id <= 0xFFFF or not 0 <= frame.generation <= 0xFFFF:
        raise StreamError("mesh_id and generation must be 16-bit values")
    if not 1 <= frame.capacity_words <= 0xFFFF:
        raise StreamError("capacity_words must be in 1..65535")

    words = [
        FRAME_MAGIC,
        frame.version_flags,
        frame_hi,
        frame_lo,
        frame.mesh_id,
        frame.generation,
        frame.capacity_words,
        0,
    ]
    for packet in frame.packets:
        _validate_packet(packet)
        key_hi, key_lo = _split_u32(packet.ot_key, "packet.ot_key")
        words.extend(
            [
                PACKET_MAGIC | len(packet.rows),
                packet.source_triangle,
                key_hi,
                key_lo,
                packet.shade_tint,
                packet.flags,
                packet.du_dx & 0xFFFF,
                packet.dv_dx & 0xFFFF,
                packet.y_start & 0xFFFF,
            ]
        )
        words.extend(_encode_packet_body(packet))

    payload_crc = crc16_ccitt(words)
    total_words = len(words) + 6
    if total_words > frame.capacity_words:
        raise StreamError(
            f"frame requires {total_words} words, capacity is {frame.capacity_words}"
        )
    words.extend(
        [
            FRAME_FOOTER_MAGIC,
            frame_hi,
            frame_lo,
            len(frame.packets),
            total_words,
            payload_crc,
        ]
    )
    return words


def encode_compact_frame(frame: CompactFrame) -> List[int]:
    """Encode the deterministic 24-bit DSP-record shadow stream.

    Each native DSP word is represented by two SSI words: a zero-extended
    high byte followed by the low 16 bits.  This wastes eight bits per native
    word, but keeps the stream word-aligned and makes the physical DMA
    capture directly comparable with the host-port source.
    """

    frame_hi, frame_lo = _split_u32(frame.frame_id, "frame_id")
    if not 0 <= frame.mesh_id <= 0xFFFF or not 0 <= frame.generation <= 0xFFFF:
        raise StreamError("mesh_id and generation must be 16-bit values")
    if not 1 <= frame.capacity_words <= 0xFFFF:
        raise StreamError("capacity_words must be in 1..65535")
    if not frame.version_flags & COMPACT_RECORD_FLAG:
        raise StreamError("compact frame is missing COMPACT_RECORD_FLAG")

    words = [
        FRAME_MAGIC,
        frame.version_flags,
        frame_hi,
        frame_lo,
        frame.mesh_id,
        frame.generation,
        frame.capacity_words,
        0,
    ]
    for record in frame.records:
        _validate_compact_record(record)
        source_hi, source_lo = _split_u32(record.source_triangle, "source_triangle")
        words.extend([COMPACT_RECORD_MAGIC, source_hi, source_lo])
        for native_word in record.words:
            words.extend([(native_word >> 16) & 0xFF, native_word & 0xFFFF])

    payload_crc = crc16_ccitt(words)
    total_words = len(words) + 6
    if total_words > frame.capacity_words:
        raise StreamError(
            f"compact frame requires {total_words} words, capacity is {frame.capacity_words}"
        )
    words.extend(
        [
            FRAME_FOOTER_MAGIC,
            frame_hi,
            frame_lo,
            len(frame.records),
            total_words,
            payload_crc,
        ]
    )
    return words


def _read(words: Sequence[int], index: int, name: str) -> int:
    if index >= len(words):
        raise StreamError(f"truncated stream while reading {name}")
    return _u16(words[index], name)


def _decode_row_abs(words: Sequence[int], index: int, shade: int) -> Tuple[Row, int]:
    packed = _read(words, index, "ROW_ABS header")
    if packed >= 0xF000:
        raise StreamError("ROW_ABS collides with a control word")
    row = Row(
        x0=packed >> 8,
        count=(packed & 0xFF) + 1,
        u=_read(words, index + 1, "ROW_ABS U"),
        v=_read(words, index + 2, "ROW_ABS V"),
        shade=shade,
    )
    _validate_row(row)
    return row, index + 3


def decode_frame(words: Sequence[int]) -> Frame:
    """Decode and validate a complete stream."""

    if len(words) < 8 + 6:
        raise StreamError("stream is shorter than header plus footer")
    normalized = [_u16(word, "stream word") for word in words]
    if normalized[0] != FRAME_MAGIC:
        raise StreamError("bad frame magic")

    frame_id = (normalized[2] << 16) | normalized[3]
    capacity = normalized[6]
    footer = normalized[-6:]
    if footer[0] != FRAME_FOOTER_MAGIC:
        raise StreamError("bad frame footer magic")
    footer_frame_id = (footer[1] << 16) | footer[2]
    if footer_frame_id != frame_id:
        raise StreamError("footer frame id does not match header")
    if footer[4] != len(normalized):
        raise StreamError("footer word count does not match stream length")
    if len(normalized) > capacity:
        raise StreamError("stream exceeds declared DMA capacity")
    if crc16_ccitt(normalized[:-6]) != footer[5]:
        raise StreamError("stream CRC mismatch")

    packets: List[Packet] = []
    index = 8
    body_end = len(normalized) - 6
    while index < body_end:
        marker = _read(normalized, index, "packet marker")
        if marker < PACKET_MAGIC or marker >= 0xF000:
            raise StreamError(f"expected packet marker at word {index}")
        row_count = marker & 0x0FFF
        if row_count == 0:
            raise StreamError("packet contains zero rows")
        source = _read(normalized, index + 1, "packet source")
        ot_key = (_read(normalized, index + 2, "OT key high") << 16) | _read(
            normalized, index + 3, "OT key low"
        )
        shade_tint = _read(normalized, index + 4, "packet shade/tint")
        flags = _read(normalized, index + 5, "packet flags")
        du_dx = _read(normalized, index + 6, "packet du/dx")
        dv_dx = _read(normalized, index + 7, "packet dv/dx")
        y_start = _s16(_read(normalized, index + 8, "packet y start"))
        index += 9

        rows: List[Row] = []
        shade = shade_tint & 0xF
        logical_rows = 0
        while logical_rows < row_count:
            control = _read(normalized, index, "row/control word")
            if control & 0xFF00 == SHADE_MAGIC:
                shade = control & 0xF
                if control & 0xFFF0 != SHADE_MAGIC:
                    raise StreamError("invalid SET_SHADE control word")
                index += 1
                continue
            if control & 0xFF00 == ROW_SKIP_MAGIC:
                skipped = (control & 0xFF) + 1
                if logical_rows + skipped > row_count:
                    raise StreamError("ROW_SKIP exceeds packet row count")
                logical_rows += skipped
                index += 1
                continue
            if control & 0xFF00 == RUN_MAGIC:
                run_length = (control & 0xFF) + 1
                if run_length < 3:
                    raise StreamError("RUN16 is shorter than three rows")
                if logical_rows + run_length > row_count:
                    raise StreamError("RUN16 exceeds packet row count")
                first, index = _decode_row_abs(normalized, index + 1, shade)
                packed_delta = _read(normalized, index, "RUN16 x/count delta")
                dx = _s8(packed_delta >> 8)
                dcount = _s8(packed_delta & 0xFF)
                du = _s16(_read(normalized, index + 1, "RUN16 du"))
                dv = _s16(_read(normalized, index + 2, "RUN16 dv"))
                index += 3
                rows.append(first)
                previous = first
                for _ in range(run_length - 1):
                    current = Row(
                        x0=previous.x0 + dx,
                        count=previous.count + dcount,
                        u=(previous.u + du) & 0xFFFF,
                        v=(previous.v + dv) & 0xFFFF,
                        shade=shade,
                    )
                    _validate_row(current)
                    rows.append(current)
                    previous = current
                logical_rows += run_length
                continue
            row, index = _decode_row_abs(normalized, index, shade)
            rows.append(row)
            logical_rows += 1

        packets.append(
            Packet(
                source_triangle=source,
                ot_key=ot_key,
                shade_tint=shade_tint,
                flags=flags,
                du_dx=du_dx,
                dv_dx=dv_dx,
                rows=tuple(rows),
                y_start=y_start,
            )
        )

    if index != body_end:
        raise StreamError("decoder did not consume the complete frame body")
    if len(packets) != footer[3]:
        raise StreamError("footer packet count does not match stream")
    return Frame(
        frame_id=frame_id,
        mesh_id=normalized[4],
        generation=normalized[5],
        capacity_words=capacity,
        packets=tuple(packets),
        version_flags=normalized[1],
    )


def decode_compact_frame(words: Sequence[int]) -> CompactFrame:
    """Decode and validate a compact DSP-record shadow stream."""

    if len(words) < 8 + 6:
        raise StreamError("compact stream is shorter than header plus footer")
    normalized = [_u16(word, "stream word") for word in words]
    if normalized[0] != FRAME_MAGIC:
        raise StreamError("bad compact frame magic")
    if not normalized[1] & COMPACT_RECORD_FLAG:
        raise StreamError("stream is not marked as a compact record frame")

    frame_id = (normalized[2] << 16) | normalized[3]
    capacity = normalized[6]
    footer = normalized[-6:]
    if footer[0] != FRAME_FOOTER_MAGIC:
        raise StreamError("bad compact frame footer magic")
    if ((footer[1] << 16) | footer[2]) != frame_id:
        raise StreamError("compact footer frame id does not match header")
    if footer[4] != len(normalized):
        raise StreamError("compact footer word count does not match stream length")
    if len(normalized) > capacity:
        raise StreamError("compact stream exceeds declared DMA capacity")
    if crc16_ccitt(normalized[:-6]) != footer[5]:
        raise StreamError("compact stream CRC mismatch")

    records: List[CompactRecord] = []
    index = 8
    body_end = len(normalized) - 6
    while index < body_end:
        if _read(normalized, index, "compact record marker") != COMPACT_RECORD_MAGIC:
            raise StreamError(f"expected compact record marker at word {index}")
        source = (_read(normalized, index + 1, "compact source high") << 16) | _read(
            normalized, index + 2, "compact source low"
        )
        index += 3
        native_words: List[int] = []
        for native_index in range(DSP_SPAN_RECORD_WORDS):
            high = _read(normalized, index, f"compact word {native_index} high")
            if high & 0xFF00:
                raise StreamError(f"compact word {native_index} high byte is not zero-extended")
            low = _read(normalized, index + 1, f"compact word {native_index} low")
            native_words.append((high << 16) | low)
            index += 2
        record = CompactRecord(source_triangle=source, words=tuple(native_words))
        _validate_compact_record(record)
        records.append(record)

    if index != body_end:
        raise StreamError("compact decoder did not consume the complete frame body")
    if len(records) != footer[3]:
        raise StreamError("compact footer record count does not match stream")
    return CompactFrame(
        frame_id=frame_id,
        mesh_id=normalized[4],
        generation=normalized[5],
        capacity_words=capacity,
        records=tuple(records),
        version_flags=normalized[1],
    )


def _sample_frame() -> Frame:
    rows = (
        Row(12, 8, 0xFFF0, 0x0100, 3),
        Row(13, 8, 0x0000, 0x0110, 3),
        Row(14, 8, 0x0010, 0x0120, 3),
        Row(15, 8, 0x0020, 0x0130, 5),
        Row(16, 8, 0x0030, 0x0140, 5),
        Row(17, 8, 0x0040, 0x0150, 5),
    )
    return Frame(
        frame_id=0x12345678,
        mesh_id=0x42,
        generation=7,
        capacity_words=256,
        packets=(
            Packet(
                source_triangle=1723,
                ot_key=0x000ABCDE,
                shade_tint=0x0023,
                flags=0x0005,
                du_dx=0xFFF0,
                dv_dx=0x0010,
                rows=rows,
            ),
        ),
    )


def _sample_compact_frame() -> CompactFrame:
    return CompactFrame(
        frame_id=0x89ABCDEF,
        mesh_id=0x42,
        generation=8,
        capacity_words=256,
        records=(
            CompactRecord(
                source_triangle=0x00001234,
                words=(
                    0x000001,
                    0xFFFFFF,
                    0x123456,
                    0x800000,
                    0x00FF00,
                    0x000000,
                    0x654321,
                    0xFEDCBA,
                    0x000080,
                    0xABCDEF,
                    0x010203,
                    0x102030,
                    0xF00000,
                    0x0F0F0F,
                    0x00AA55,
                    0x7FFFFF,
                    0x800001,
                    0xFFFFFF,
                ),
            ),
        ),
    )


def self_test() -> None:
    frame = _sample_frame()
    encoded = encode_frame(frame)
    decoded = decode_frame(encoded)
    assert decoded == frame, (decoded, frame)
    assert any(word & 0xFF00 == RUN_MAGIC for word in encoded)
    assert any(word & 0xFF00 == SHADE_MAGIC for word in encoded)

    # A thin triangle may have a visible Y row with no clipped X span.  The
    # stream keeps that logical row with a one-word skip control, so the
    # packet remains aligned without inventing a zero-width ROW_ABS record.
    skipped = list(encoded)
    skipped[8] += 1
    skipped.insert(17, ROW_SKIP_MAGIC)
    skipped[-2] = len(skipped)
    skipped[-1] = crc16_ccitt(skipped[:-6])
    skipped_decoded = decode_frame(skipped)
    assert skipped_decoded.packets[0].y_start == 0
    assert skipped_decoded.packets[0].rows == frame.packets[0].rows

    corrupted = list(encoded)
    corrupted[10] ^= 1
    try:
        decode_frame(corrupted)
    except StreamError:
        pass
    else:
        raise AssertionError("CRC corruption was accepted")

    too_small = Frame(
        frame_id=frame.frame_id,
        mesh_id=frame.mesh_id,
        generation=frame.generation,
        capacity_words=len(encoded) - 1,
        packets=frame.packets,
    )
    try:
        encode_frame(too_small)
    except StreamError:
        pass
    else:
        raise AssertionError("capacity overflow was accepted")

    try:
        decode_frame(encoded[:-1])
    except StreamError:
        pass
    else:
        raise AssertionError("truncated footer was accepted")

    compact = _sample_compact_frame()
    compact_encoded = encode_compact_frame(compact)
    compact_decoded = decode_compact_frame(compact_encoded)
    assert compact_decoded == compact, (compact_decoded, compact)
    assert len(compact_encoded) == 8 + 3 + (DSP_SPAN_RECORD_WORDS * 2) + 6

    compact_corrupted = list(compact_encoded)
    compact_corrupted[10] |= 0x100
    try:
        decode_compact_frame(compact_corrupted)
    except StreamError:
        pass
    else:
        raise AssertionError("non-zero compact high-byte padding was accepted")

    compact_too_small = CompactFrame(
        frame_id=compact.frame_id,
        mesh_id=compact.mesh_id,
        generation=compact.generation,
        capacity_words=len(compact_encoded) - 1,
        records=compact.records,
    )
    try:
        encode_compact_frame(compact_too_small)
    except StreamError:
        pass
    else:
        raise AssertionError("compact capacity overflow was accepted")


def _print_cost() -> None:
    rows = 12_439.35
    packets = 1_018.96
    uv_only = rows * 4
    # The packet header is nine words: the last two carry du/dx and dv/dx,
    # and the ninth anchors the packet's first visible Y row.
    abs_stream = rows * 6 + packets * 18
    shade_bound = rows * 8 + packets * 18
    compact_records = packets * (1 + 2 + (DSP_SPAN_RECORD_WORDS * 2)) * 2 + 28
    print(f"rows/frame: {rows:.2f}")
    print(f"packets/frame: {packets:.2f}")
    print(f"U/V-only bytes/frame: {uv_only:.0f}")
    print(f"ABS span bytes/frame: {abs_stream:.0f}")
    print(f"shade-change bound bytes/frame: {shade_bound:.0f}")
    print(f"compact-record shadow bytes/frame: {compact_records:.0f}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true", help="run protocol fixtures")
    parser.add_argument("--cost", action="store_true", help="print the documented full-mesh cost model")
    args = parser.parse_args()
    if not args.self_test and not args.cost:
        parser.error("select --self-test or --cost")
    if args.self_test:
        self_test()
        print("ssi_stream_model: self-test passed")
    if args.cost:
        _print_cost()


if __name__ == "__main__":
    main()
