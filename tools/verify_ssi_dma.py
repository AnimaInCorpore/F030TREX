#!/usr/bin/env python3
"""Verify the live Falcon SSI -> Crossbar -> DMA-RECORD transport probe.

``trex_ssi_dma.tos`` is the only build that claims the sound channel, routes
DSP transmit to DMA record and starts the record engine.  It writes two
sidecars next to itself:

``ssi_dma.res``
    40 big-endian signed longwords: the claim/route/arm/wait verdicts, the
    raw register images each stage saw, the on-target compare result and the
    DSP's own reply.

``ssi_dcap.res``
    The record window exactly as the DMA engine left it.

This verifier is deliberately independent of the on-target compare.  It
rebuilds the whole expected frame -- envelope, ramp payload and
CRC-16/CCITT-FALSE -- from the sidecar's own declared parameters and checks
the capture against it, so a target-side compare bug cannot pass both.
"""

from __future__ import annotations

import argparse
from pathlib import Path
from struct import unpack

from ssi_stream_model import StreamError, crc16_ccitt

STATUS_LONGS = 40
FRAME_MAGIC = 0x5353
PROBE_FLAGS = 0x4001
FRAME_FOOTER = 0x5AA5
HEADER_WORDS = 8
FOOTER_WORDS = 6

# Field order matches the on-target status block.
FIELDS = (
    "claim_result",
    "claim_stage",
    "route_status",
    "route_source",
    "route_destination",
    "devconnect_source",
    "devconnect_destination",
    "old_ff8901",
    "old_ff8900",
    "armed_ff8901",
    "armed_ff8900",
    "armed_ff8920_word",
    "armed_ff8935",
    "armed_xbar_source",
    "armed_xbar_destination",
    "arm_result",
    "built_words",
    "wait_result",
    "wait_ticks",
    "bytes",
    "verify",
    "bad_index",
    "bad_got",
    "bad_want",
    "cacr",
    "dsp_ack",
    "dsp_status",
)

ACK_SSI_STREAM = 0x700010
XBIOS_NOT_RECORDED = -999

# The two route fields this transport owns, from the Falcon030 Hardware
# Reference Guide.  $FF8930 bits 7..4 are DSP-XMIT, $FF8932 bits 3..0 are
# DMA-RECORD; the other three fields of each register belong to other paths
# and are deliberately not asserted on.
XBAR_SOURCE_MASK = 0x00F0
XBAR_SOURCE_DSP_XMIT = 0x00C0
XBAR_DEST_MASK = 0x000F
XBAR_DEST_DSP_TO_DMA = 0x0002


def read_status(path: Path) -> dict:
    data = path.read_bytes()
    if len(data) != STATUS_LONGS * 4:
        raise StreamError(
            f"status has {len(data)} bytes, expected {STATUS_LONGS * 4}"
        )
    raw = unpack(f">{STATUS_LONGS}l", data)
    status = dict(zip(FIELDS, raw))
    status["xbios"] = list(raw[len(FIELDS) :])
    return status


def read_words(path: Path) -> list[int]:
    data = path.read_bytes()
    if len(data) % 2:
        raise StreamError("capture is not word aligned")
    return list(unpack(f">{len(data) // 2}H", data))


def expected_frame(words: list[int]) -> list[int]:
    """Rebuild the frame the DSP should have produced, from its own header.

    Only the header's self-description is trusted as input: everything that
    follows -- the payload length, every ramp value, the footer counts and
    the CRC -- is re-derived here.  The seed comes from the first payload
    word because it is the one parameter the header does not carry; a shifted
    or truncated stream still fails, because the ramp then does not run to
    the declared length and the CRC does not close.
    """
    if len(words) < HEADER_WORDS + FOOTER_WORDS:
        raise StreamError("capture is shorter than one empty frame")
    magic, flags, id_hi, id_lo, mesh, generation, capacity, reserved = words[
        :HEADER_WORDS
    ]
    if magic != FRAME_MAGIC:
        raise StreamError(f"header magic ${magic:04x}, expected ${FRAME_MAGIC:04x}")
    if flags != PROBE_FLAGS:
        raise StreamError(
            f"header flags ${flags:04x}, expected the probe's ${PROBE_FLAGS:04x}"
        )
    if reserved != 0:
        raise StreamError(f"header reserved word is ${reserved:04x}, expected 0")
    if capacity != len(words):
        raise StreamError(
            f"header declares {capacity} words, capture holds {len(words)}"
        )

    payload = capacity - HEADER_WORDS - FOOTER_WORDS
    seed = words[HEADER_WORDS]
    frame = list(words[:HEADER_WORDS])
    frame += [(seed + i) & 0xFFFF for i in range(payload)]
    crc = crc16_ccitt(frame)
    frame += [
        FRAME_FOOTER,
        id_hi,
        id_lo,
        payload,
        capacity,
        crc,
    ]
    return frame


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("status", type=Path, help="ssi_dma.res path")
    parser.add_argument("capture", type=Path, help="ssi_dcap.res path")
    args = parser.parse_args()

    status = read_status(args.status)

    if status["claim_result"] != 0:
        raise SystemExit(
            f"claim refused at stage {status['claim_stage']}; "
            f"XBIOS returns {status['xbios']}"
        )
    if status["route_status"] != 0:
        raise SystemExit(
            "route read-back rejected: "
            f"$FF8930=${status['route_source'] & 0xFFFF:04x} "
            f"$FF8932=${status['route_destination'] & 0xFFFF:04x}"
        )

    source = status["route_source"] & 0xFFFF
    destination = status["route_destination"] & 0xFFFF
    if source & XBAR_SOURCE_MASK != XBAR_SOURCE_DSP_XMIT:
        raise SystemExit(f"$FF8930 DSP-XMIT field is not $C: ${source:04x}")
    if destination & XBAR_DEST_MASK != XBAR_DEST_DSP_TO_DMA:
        raise SystemExit(f"$FF8932 DMA-RECORD field is not $2: ${destination:04x}")

    if status["arm_result"] != 0:
        raise SystemExit("record channel refused to arm")
    if status["armed_ff8901"] & 0x10 == 0:
        raise SystemExit(
            f"$FF8901 record enable was clear after arming: "
            f"${status['armed_ff8901'] & 0xFF:02x}"
        )
    if status["wait_result"] != 0:
        raise SystemExit(
            f"transfer did not complete: {status['bytes']} bytes moved "
            f"in {status['wait_ticks']} ticks"
        )
    if status["dsp_ack"] != ACK_SSI_STREAM:
        raise SystemExit(f"DSP replied ${status['dsp_ack'] & 0xFFFFFFFF:08x}")
    if status["dsp_status"] != 0:
        raise SystemExit("DSP reported a stalled transmitter")

    words = read_words(args.capture)
    if status["bytes"] != len(words) * 2:
        raise SystemExit(
            f"hardware moved {status['bytes']} bytes, capture holds "
            f"{len(words) * 2}"
        )

    frame = expected_frame(words)
    bad = [i for i, (got, want) in enumerate(zip(words, frame)) if got != want]
    if bad:
        i = bad[0]
        raise SystemExit(
            f"{len(bad)} word(s) differ, first at index {i}: "
            f"got ${words[i]:04x}, expected ${frame[i]:04x}"
        )
    if status["verify"] != 0:
        raise SystemExit("target-side compare failed but the capture matches")

    payload = len(words) - HEADER_WORDS - FOOTER_WORDS
    ms = status["wait_ticks"] * 5
    rate = (status["bytes"] / ms * 1000 / 1024) if ms else float("nan")
    forced = (
        "no"
        if (
            status["devconnect_source"] & 0xFFFF == source
            and status["devconnect_destination"] & 0xFFFF == destination
        )
        else "yes"
    )

    print(f"claim            : stage {status['claim_stage']}, route validated")
    print(
        f"route            : $FF8930=${source:04x} $FF8932=${destination:04x}"
        f"  (raw write needed: {forced})"
    )
    print(
        f"pre-claim state  : $FF8901=${status['old_ff8901'] & 0xFF:02x} "
        f"$FF8900=${status['old_ff8900'] & 0xFF:02x}"
    )
    print(
        f"armed state      : $FF8901=${status['armed_ff8901'] & 0xFF:02x} "
        f"$FF8935=${status['armed_ff8935'] & 0xFF:02x} "
        f"$FF8920/21=${status['armed_ff8920_word'] & 0xFFFF:04x}"
    )
    print(f"CACR at transfer : ${status['cacr'] & 0xFFFFFFFF:08x}")
    print(
        f"transfer         : {status['bytes']} bytes in {ms} ms "
        f"({rate:.1f} KB/s)"
    )
    print(
        f"frame            : {len(words)} words = 8 header + {payload} ramp "
        f"+ 6 footer, CRC ${frame[-1]:04x}"
    )
    print("verdict          : capture matches an independently rebuilt frame")


if __name__ == "__main__":
    main()
