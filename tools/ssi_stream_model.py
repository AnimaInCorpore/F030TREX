#!/usr/bin/env python3
"""Executable 16-bit SSI/DMA framing model for the DSP->CPU span-record stream.

This is step 2 of the SSI/DMA plan: freeze the wire format, prove the decode is
exact, and size the buffers.  It deliberately does NOT touch Falcon hardware and
is not imported by any build.  Run it directly:

    python tools/ssi_stream_model.py

WHAT IS AND IS NOT PROVEN HERE
------------------------------
The 18-word *packed record* is not invented by this file.  It is the existing
DSP->host contract (`SPAN_RECORD_WORDS` in `TREX/dsp/trex_dsp.asm`, mirrored at
`DSP_SPAN_RECORD_WORDS` in `TREX/m68030/trex_m68030.s`), already validated
field-for-field over two full revolutions -- 852,390 exact comparisons, zero
mismatches (OPTIMIZATION.md 4.1b/9.2).  This model treats those 18 words as
opaque 24-bit values and proves only the NEW layer:

  * lossless 24-bit -> 16-bit framing for a DMA channel that frames 16-bit
    units,
  * a frame/footer envelope that can tell a complete buffer from a shifted,
    truncated, duplicated or partially-overwritten one,
  * capacity behaviour, including the geometric worst case.

It does NOT prove anything about crossbar setup, DMA ownership, cache
coherency, or achieved bandwidth.  Those are hardware questions and
OPTIMIZATION.md 7.4/8 and roadmap item 14 own them.

NOTE ON A DOCUMENTATION ERROR THIS FILE CORRECTS
------------------------------------------------
OPTIMIZATION.md 9.2 says the record travels "packed at fourteen words" and
lists `uv0pack`/`uv1pack` as w17/w18 on the wire.  Both are stale.  The current
contract is EIGHTEEN packed words, and the sorted UV byte pairs are not sent at
all -- the host rebuilds them from `gpu_texture_meta_buffer` via the two slot
ids in w0.  Both source files agree on 18; this model follows the source.
"""

from __future__ import annotations

import random
import struct
import sys
from dataclasses import dataclass

# ---------------------------------------------------------------------------
# The record contract, transcribed from the two source files.
# ---------------------------------------------------------------------------

SPAN_RECORD_WORDS = 18          # trex_dsp.asm SPAN_RECORD_WORDS
MAX_CHUNK = 32                  # trex_dsp.asm MAX_CHUNK
TREX_PRIMITIVES = 2724          # full-mesh triangle count

# Field names in wire order, for readable diagnostics only.  Every one of them
# is carried as an opaque 24-bit pattern; nothing here interprets them.
RECORD_FIELDS = (
    "w0_key",        # slot_mid<<14 | slot_top<<12 | mid<<11 | shade<<5 | index
    "w1_otkey",      # average-z / Ordering Table key
    "w2_rowsup_sy0",  # rows_up<<12 | (sy0 & $fff)
    "w3_sx0_rowslow",  # (sx0 & $fff)<<12 | rows_low
    "w4_sx1",        # sx1 & $fff
    "w5_sl_long", "w6_sl_up", "w7_sl_low",
    "w8_du_dx", "w9_dv_dx",
    "w10_dul_up", "w11_dvl_up", "w12_dul_low", "w13_dvl_low",
    "w14_lvl_top_mid",  # lvl_top<<12 | lvl_mid
    "w15_dlvl_dx", "w16_dlvl_up", "w17_dlvl_low",
)
assert len(RECORD_FIELDS) == SPAN_RECORD_WORDS

WORD_MASK = 0xFFFFFF            # DSP56001 words are 24-bit
UNIT_MASK = 0xFFFF

# ---------------------------------------------------------------------------
# Framing constants.
# ---------------------------------------------------------------------------

MAGIC_HEAD = 0x5353             # 'SS'
MAGIC_FOOT = 0x5AA5
VERSION = 1

UNITS_PER_WORD = 2              # see design note below
UNITS_PER_RECORD = SPAN_RECORD_WORDS * UNITS_PER_WORD   # 36
BYTES_PER_RECORD = UNITS_PER_RECORD * 2                 # 72

HEADER_UNITS = 8
FOOTER_UNITS = 8
ENVELOPE_UNITS = HEADER_UNITS + FOOTER_UNITS

STATUS_COMPLETE = 0
STATUS_OVERFLOW = 1

# DESIGN NOTE -- why two units per word, and not a width-aware packing.
#
# Several of the 18 words are provably narrower than 24 bits: w0 is exactly 16,
# w4 is 12, and w14's two level fields are 12 each.  A width-aware packing would
# cut the record from 36 to about 31 units, roughly 14%.
#
# It is deliberately not taken.  OPTIMIZATION.md 2.4c measures the entire host
# port at 14.2 ms/frame and shows that deleting it outright is worth +0.06 FPS;
# transport size is simply not where this pipeline's time is.  A width-aware
# packing buys ~14% of a term worth 14 ms and pays for it with a silent
# corruption mode the moment any field outgrows its assumed width -- exactly the
# class of defect the span validator was built to catch.  Two units per word is
# lossless for all 2**24 patterns by construction, needs no per-field range
# assumption, and survives any future change to what the fields mean.
#
# If a later measurement ever makes the wire matter, revisit this constant and
# nothing else: the envelope and the validation below are width-independent.


def crc16_ccitt(data: bytes) -> int:
    """CRC-16/CCITT-FALSE.  Chosen because it is trivial on the 68030 and on
    the DSP, and detects all single-bit, double-bit and odd-count errors plus
    any burst up to 16 bits -- which covers the realistic DMA failure modes
    (a dropped unit, a shifted buffer, a half-overwritten ping-pong half)."""
    crc = 0xFFFF
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


@dataclass
class FrameHeader:
    frame_id: int
    mesh_id: int
    generation: int
    capacity_units: int
    flags: int = 0


class StreamError(Exception):
    """Any reason a buffer must not be handed to the rasterizer."""


# ---------------------------------------------------------------------------
# Encode
# ---------------------------------------------------------------------------

def _units_to_bytes(units: list[int]) -> bytes:
    return struct.pack(">%dH" % len(units), *units)


def encode_word(word: int) -> tuple[int, int]:
    """One 24-bit DSP word -> two big-endian 16-bit units.

    The raw bit pattern travels; no sign extension happens on the wire.  The
    host already knows which fields are signed and sign-extends them exactly
    as it does today when unpacking from the host port, so this framing cannot
    introduce a sign bug that the existing path does not already have."""
    if not 0 <= word <= WORD_MASK:
        raise StreamError("word %#x outside 24-bit range" % word)
    return (word >> 16) & UNIT_MASK, word & UNIT_MASK


def decode_word(hi: int, lo: int) -> int:
    if hi & ~0xFF:
        raise StreamError("high unit %#x has bits above the 24-bit word" % hi)
    return ((hi & 0xFF) << 16) | (lo & UNIT_MASK)


def encode_frame(header: FrameHeader, records: list[list[int]]) -> tuple[bytes, int]:
    """Build one complete DMA buffer.

    Returns (buffer_bytes, status).  If the records do not fit in
    `header.capacity_units`, as many as fit are emitted and the footer carries
    STATUS_OVERFLOW -- the host must then discard the buffer and fall back to
    the host-port path, exactly as OPTIMIZATION.md 7.4 requires.  The DSP must
    reserve the footer space up front, which is why the usable capacity below
    subtracts ENVELOPE_UNITS before dividing."""
    usable = header.capacity_units - ENVELOPE_UNITS
    if usable < 0:
        raise StreamError("capacity smaller than the envelope")
    max_records = usable // UNITS_PER_RECORD

    status = STATUS_COMPLETE
    emitted = records
    if len(records) > max_records:
        status = STATUS_OVERFLOW
        emitted = records[:max_records]

    units: list[int] = [
        MAGIC_HEAD,
        (VERSION << 8) | (header.flags & 0xFF),
        (header.frame_id >> 16) & UNIT_MASK,
        header.frame_id & UNIT_MASK,
        header.mesh_id & UNIT_MASK,
        header.generation & UNIT_MASK,
        (header.capacity_units >> 16) & UNIT_MASK,
        header.capacity_units & UNIT_MASK,
    ]

    for rec in emitted:
        if len(rec) != SPAN_RECORD_WORDS:
            raise StreamError("record has %d words, expected %d"
                              % (len(rec), SPAN_RECORD_WORDS))
        for word in rec:
            units.extend(encode_word(word))

    body = _units_to_bytes(units)
    total_units = len(units) + FOOTER_UNITS

    footer = [
        MAGIC_FOOT,
        status,
        (header.frame_id >> 16) & UNIT_MASK,
        header.frame_id & UNIT_MASK,
        len(emitted) & UNIT_MASK,
        (total_units >> 16) & UNIT_MASK,
        total_units & UNIT_MASK,
    ]
    # CRC covers header + records + every footer unit before the CRC itself.
    footer.append(crc16_ccitt(body + _units_to_bytes(footer)))
    return body + _units_to_bytes(footer), status


# ---------------------------------------------------------------------------
# Decode
# ---------------------------------------------------------------------------

def decode_frame(buf: bytes, expect_frame_id: int | None = None,
                 expect_generation: int | None = None) -> tuple[FrameHeader, list[list[int]], int]:
    """Validate and decode one DMA buffer.

    Every failure raises.  There is no partial success and no resynchronisation:
    a buffer is consumable or it is discarded and the host-port path runs.  That
    is the whole point of the ping-pong ownership model -- a half-good buffer
    silently feeding the rasterizer is the failure this envelope exists to make
    impossible."""
    if len(buf) % 2:
        raise StreamError("buffer length %d is not a whole number of units" % len(buf))
    units = list(struct.unpack(">%dH" % (len(buf) // 2), buf))

    if len(units) < ENVELOPE_UNITS:
        raise StreamError("buffer shorter than the envelope")
    if units[0] != MAGIC_HEAD:
        raise StreamError("bad head magic %#06x" % units[0])

    version = units[1] >> 8
    if version != VERSION:
        raise StreamError("unsupported version %d" % version)

    header = FrameHeader(
        frame_id=(units[2] << 16) | units[3],
        mesh_id=units[4],
        generation=units[5],
        capacity_units=(units[6] << 16) | units[7],
        flags=units[1] & 0xFF,
    )

    # The footer is at a declared offset, so find it via the declared length
    # rather than by scanning for the magic -- scanning would happily lock onto
    # a stale footer left in the buffer by the previous frame.
    foot = units[-FOOTER_UNITS:]
    if foot[0] != MAGIC_FOOT:
        raise StreamError("bad foot magic %#06x" % foot[0])

    status = foot[1]
    if status not in (STATUS_COMPLETE, STATUS_OVERFLOW):
        raise StreamError("unknown status %d" % status)

    foot_frame_id = (foot[2] << 16) | foot[3]
    if foot_frame_id != header.frame_id:
        raise StreamError("frame id mismatch: header %d, footer %d"
                          % (header.frame_id, foot_frame_id))

    count = foot[4]
    declared_units = (foot[5] << 16) | foot[6]
    if declared_units != len(units):
        raise StreamError("declared %d units, buffer holds %d"
                          % (declared_units, len(units)))

    expected_units = ENVELOPE_UNITS + count * UNITS_PER_RECORD
    if expected_units != len(units):
        raise StreamError("record count %d implies %d units, buffer holds %d"
                          % (count, expected_units, len(units)))

    crc_seen = foot[7]
    crc_calc = crc16_ccitt(buf[:-2])
    if crc_seen != crc_calc:
        raise StreamError("CRC mismatch: got %#06x, computed %#06x" % (crc_seen, crc_calc))

    if status == STATUS_OVERFLOW:
        raise StreamError("DSP reported overflow after %d records; use the "
                          "host-port fallback" % count)

    # Cross-frame ownership: a structurally perfect buffer from the WRONG frame
    # is the ping-pong failure mode, and only the caller knows what it asked
    # for.  Checked after the structural checks so diagnostics stay useful.
    if expect_frame_id is not None and header.frame_id != expect_frame_id:
        raise StreamError("stale buffer: frame %d, expected %d"
                          % (header.frame_id, expect_frame_id))
    if expect_generation is not None and header.generation != expect_generation:
        raise StreamError("stale buffer: generation %d, expected %d"
                          % (header.generation, expect_generation))

    records = []
    pos = HEADER_UNITS
    for _ in range(count):
        rec = [decode_word(units[pos + 2 * i], units[pos + 2 * i + 1])
               for i in range(SPAN_RECORD_WORDS)]
        records.append(rec)
        pos += UNITS_PER_RECORD
    return header, records, status


# ---------------------------------------------------------------------------
# Buffer sizing and cost model
# ---------------------------------------------------------------------------

def buffer_report() -> str:
    """Size the ping-pong buffers and state the transfer cost honestly.

    Survivor counts are OPTIMIZATION.md 8.2a's recorded full-mesh averages; the
    timing window is the 2.4c corrected baseline, not the retired stock one."""
    avg_survivors = 1149          # 8.2a, recorded full-mesh average
    prepass_cap = 1335            # 2.3f PREPASS_MAX, the armed-path ceiling
    geometric_max = TREX_PRIMITIVES  # every triangle survives

    def size(n):
        return ENVELOPE_UNITS * 2 + n * BYTES_PER_RECORD

    avg_b, cap_b, max_b = size(avg_survivors), size(prepass_cap), size(geometric_max)
    kib = 1024
    buf = 192 * kib

    # Atari's specified ceiling for DSP-SSI / DMA-record, 32 MHz / 4.
    rate = 1_000_000.0            # bytes per second
    window_ms = 535.7 - 260.4     # 2.4c: frame minus the packet stage

    lines = [
        "Buffer sizing (record stream, %d words x %d units = %d bytes/record)"
        % (SPAN_RECORD_WORDS, UNITS_PER_WORD, BYTES_PER_RECORD),
        "",
        "  %-34s %8d records  %9d B  %7.1f KiB" % ("average frame (8.2a)", avg_survivors, avg_b, avg_b / kib),
        "  %-34s %8d records  %9d B  %7.1f KiB" % ("armed prepass capacity (2.3f)", prepass_cap, cap_b, cap_b / kib),
        "  %-34s %8d records  %9d B  %7.1f KiB" % ("GEOMETRIC MAXIMUM (all survive)", geometric_max, max_b, max_b / kib),
        "",
        "  Chosen buffer: %d KiB each, %d KiB for the ping-pong pair." % (buf // kib, 2 * buf // kib),
    ]

    slack = buf - max_b
    per_word = TREX_PRIMITIVES * UNITS_PER_WORD * 2   # cost of one more record word
    if max_b <= buf:
        lines += [
            "",
            "  *** The geometric maximum FITS -- but only just. ***",
            "  %d B of %d B, %.1f%% full at the worst case the mesh can produce,"
            % (max_b, buf, 100.0 * max_b / buf),
            "  leaving %d B of slack." % slack,
            "",
            "  This is a stronger result in KIND than OPTIMIZATION.md 7.4 could",
            "  state for the ROW stream, where 192 KiB was an observed-corpus",
            "  bound and an adversarial mesh could always overflow it.  A record",
            "  stream is bounded by TRIANGLE COUNT, not by coverage, so the worst",
            "  case is a fixed number the mesh cannot exceed.",
            "",
            "  It is NOT a comfortable fit, and 192 KiB should not be copied over",
            "  from 7.4 as if it were.  Sensitivity:",
            "    - one more 24-bit word in the record costs %d B and OVERFLOWS" % per_word,
            "      (a 19-word record needs %d B, %.1f KiB)."
            % (max_b + per_word, (max_b + per_word) / kib),
            "    - the current margin is %d B, i.e. %.1f%% of one buffer."
            % (slack, 100.0 * slack / buf),
            "  Recommendation: size the pair at 2 x 256 KiB if the memory map can",
            "  afford it.  That restores headroom for a record-format change,",
            "  which this pipeline has made repeatedly (17 -> 18 words for the",
            "  Gouraud level fields alone).  At 192 KiB the overflow path is",
            "  unreachable by geometry TODAY and one field away from reachable.",
            "",
            "  Either way the overflow path stays implemented and tested below: a",
            "  wedged DSP or a capacity field corrupted in transit must fail",
            "  closed rather than silently.",
        ]
    else:
        lines += ["", "  Geometric maximum does NOT fit -- overflow is reachable; keep the fallback hot."]

    lines += [
        "",
        "Transfer cost at Atari's specified 1 MB/s SSI/DMA ceiling",
        "  (a wire limit, NOT achieved bandwidth -- handshaking preserves data by",
        "   stretching the transfer, not by creating bandwidth):",
        "",
        "  %-34s %7.1f ms" % ("average frame", avg_b / rate * 1000.0),
        "  %-34s %7.1f ms" % ("geometric maximum", max_b / rate * 1000.0),
        "",
        "  Window it must hide inside (2.4c: 535.7 ms frame - 260.4 ms packet",
        "  stage) = %.1f ms." % window_ms,
        "  Average duty cycle %.0f%%, worst case %.0f%% of that window."
        % (100.0 * (avg_b / rate * 1000.0) / window_ms,
           100.0 * (max_b / rate * 1000.0) / window_ms),
        "",
        "  READ THIS BEFORE COSTING THE PROJECT ON THOSE NUMBERS:",
        "  the transfer this replaces is worth 14.2 ms/frame (2.4c, measured by",
        "  wait-state sweep), and a completely free host port measures 519.7 ms",
        "  against 535.7 -- i.e. +0.06 FPS.  The case for this stream is the",
        "  ~173 ms of exposed DSP time it lets the CPU overlap, not the PIO it",
        "  deletes.  A design that wins the transfer and loses the overlap is a",
        "  net loss, and OPTIMIZATION.md roadmap item 12 stage 2 already measured",
        "  one such attempt at 278.0 ms against 263.8.",
    ]
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Self-tests
# ---------------------------------------------------------------------------

def _rec(seed_words):
    return list(seed_words)


def _make_records(n, rng):
    return [[rng.randrange(0, WORD_MASK + 1) for _ in range(SPAN_RECORD_WORDS)]
            for _ in range(n)]


def _expect_error(fn, what):
    try:
        fn()
    except StreamError:
        return True
    raise AssertionError("%s was accepted but must be rejected" % what)


def run_tests(verbose=True):
    rng = random.Random(0x5350414E)     # fixed seed: reproducible
    checks = 0

    # 1. Word codec is lossless over the whole 24-bit domain.  Exhaustive over
    #    every boundary and every single-bit pattern, plus a large random draw.
    patterns = {0, WORD_MASK, 0x800000, 0x7FFFFF, 0xFFFF, 0x10000}
    patterns |= {1 << b for b in range(24)}
    patterns |= {(1 << b) - 1 for b in range(1, 25)}
    patterns |= {rng.randrange(0, WORD_MASK + 1) for _ in range(200_000)}
    for w in patterns:
        assert decode_word(*encode_word(w)) == w, "word codec lost %#x" % w
        checks += 1

    # 2. Round-trip whole frames, including the empty and the maximal one.
    cap = (192 * 1024) // 2
    for n in (0, 1, 2, 31, 32, 33, 1149, 1335, TREX_PRIMITIVES):
        recs = _make_records(n, rng)
        hdr = FrameHeader(frame_id=0x00ABCDEF, mesh_id=1, generation=n & 0xFFFF,
                          capacity_units=cap)
        buf, status = encode_frame(hdr, recs)
        assert status == STATUS_COMPLETE, "n=%d unexpectedly overflowed" % n
        got_hdr, got_recs, got_status = decode_frame(
            buf, expect_frame_id=hdr.frame_id, expect_generation=hdr.generation)
        assert got_recs == recs, "record mismatch at n=%d" % n
        assert got_hdr.frame_id == hdr.frame_id
        assert got_status == STATUS_COMPLETE
        checks += 1

    # 3. Every corruption mode the DMA path can actually produce is rejected.
    recs = _make_records(64, rng)
    hdr = FrameHeader(frame_id=42, mesh_id=1, generation=7, capacity_units=cap)
    good, _ = encode_frame(hdr, recs)

    _expect_error(lambda: decode_frame(good[:-2]), "truncated buffer")
    _expect_error(lambda: decode_frame(good[2:]), "buffer shifted by one unit")
    _expect_error(lambda: decode_frame(good + b"\0\0"), "buffer with trailing unit")
    _expect_error(lambda: decode_frame(good[:1]), "odd-length buffer")
    _expect_error(lambda: decode_frame(b""), "empty buffer")
    checks += 5

    for pos in (0, 1, 5, len(good) // 2, len(good) - 3, len(good) - 1):
        bad = bytearray(good)
        bad[pos] ^= 0x01                       # single-bit flip anywhere
        _expect_error(lambda: decode_frame(bytes(bad)), "single-bit flip at byte %d" % pos)
        checks += 1

    _expect_error(lambda: decode_frame(good, expect_frame_id=43), "stale frame id")
    _expect_error(lambda: decode_frame(good, expect_generation=8), "stale generation")
    checks += 2

    # A whole record dropped: count and length disagree, caught before the CRC.
    dropped = good[:HEADER_UNITS * 2] + good[HEADER_UNITS * 2 + BYTES_PER_RECORD:]
    _expect_error(lambda: decode_frame(dropped), "buffer with one record dropped")
    checks += 1

    # Two halves of different frames, the ping-pong tearing mode.
    other, _ = encode_frame(FrameHeader(frame_id=43, mesh_id=1, generation=8,
                                        capacity_units=cap),
                            _make_records(64, rng))
    torn = good[:len(good) // 2] + other[len(other) // 2:]
    _expect_error(lambda: decode_frame(torn), "torn ping-pong buffer")
    checks += 1

    # A stale footer left behind by a shorter previous frame must not be found.
    stale = bytearray(encode_frame(hdr, _make_records(80, rng))[0])
    stale[:len(good)] = good
    _expect_error(lambda: decode_frame(bytes(stale)), "buffer with a stale trailing footer")
    checks += 1

    # 4. Overflow fails closed rather than delivering a short frame.
    small = ENVELOPE_UNITS + 10 * UNITS_PER_RECORD
    buf, status = encode_frame(
        FrameHeader(frame_id=1, mesh_id=1, generation=0, capacity_units=small),
        _make_records(40, rng))
    assert status == STATUS_OVERFLOW, "overflow not reported by the encoder"
    _expect_error(lambda: decode_frame(buf), "overflow buffer")
    checks += 2

    # 5. Malformed input to the encoder is refused rather than silently padded.
    _expect_error(lambda: encode_frame(hdr, [[0] * (SPAN_RECORD_WORDS - 1)]), "short record")
    _expect_error(lambda: encode_frame(hdr, [[WORD_MASK + 1] * SPAN_RECORD_WORDS]),
                  "word above 24 bits")
    _expect_error(lambda: encode_frame(
        FrameHeader(frame_id=1, mesh_id=1, generation=0, capacity_units=4), []),
        "capacity below the envelope")
    checks += 3

    if verbose:
        print("self-tests: %d checks, all passed" % checks)
    return checks


def main(argv):
    print(__doc__.strip().split("\n")[0])
    print()
    run_tests()
    print()
    print(buffer_report())
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
