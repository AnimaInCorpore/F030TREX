#!/usr/bin/env python3
"""Decode and compare span-and-offset streams (OPTIMIZATION.md 7.4g).

A stream is big-endian sixteen-bit units.  Per triangle, in draw order:

    per span   (tint << 4 | level) << 8 | length - 1
               y << 8 | x of the first pixel
               one unit per pixel: V integer << 8 | U integer
    then       $FFFF

`spanstrm.res` is one frame's stream.  The offset probe (TREX_OFFSET_PROBE)
writes the stream the 68030 span walker records; the span-stream build
(TREX_SPAN_STREAM) writes what the DSP sent into its DMA record window.  With
one argument the stream is checked for structure and summarized; with two the
streams are compared unit for unit and the first difference is reported with
its triangle, span and pixel.
"""

import argparse
from pathlib import Path
import struct
import sys

SCREEN_WIDTH = 240
SCREEN_HEIGHT = 224


def units(path):
    data = Path(path).read_bytes()
    if len(data) % 2:
        raise SystemExit(f"{path}: odd length {len(data)}")
    return struct.unpack(f">{len(data) // 2}H", data)


def decode(stream, name):
    """Yield (triangle, span, first unit index, header, position, texels)."""
    index = 0
    triangle = 0
    span = 0
    while index < len(stream):
        head = stream[index]
        if head & 0x8000:
            if head != 0xFFFF:
                raise SystemExit(f"{name}: unit {index}: terminator ${head:04X}")
            yield triangle, None, index, head, None, ()
            triangle += 1
            span = 0
            index += 1
            continue
        length = (head & 0xFF) + 1
        if index + 2 + length > len(stream):
            raise SystemExit(f"{name}: unit {index}: span runs past the end")
        position = stream[index + 1]
        x, y = position & 0xFF, position >> 8
        if y >= SCREEN_HEIGHT or x + length > SCREEN_WIDTH:
            raise SystemExit(f"{name}: unit {index}: span x={x} y={y} "
                             f"length={length} leaves the screen")
        yield (triangle, span, index, head, position,
               stream[index + 2:index + 2 + length])
        span += 1
        index += 2 + length


def summarize(stream, name):
    triangles = spans = pixels = empty = 0
    in_triangle = 0
    for _, span, _, _, _, texels in decode(stream, name):
        if span is None:
            triangles += 1
            empty += in_triangle == 0
            in_triangle = 0
        else:
            spans += 1
            pixels += len(texels)
            in_triangle += 1
    if in_triangle:
        raise SystemExit(f"{name}: the last triangle has no terminator")
    print(f"{name}: {len(stream) * 2} bytes, {triangles} triangles "
          f"({empty} without a span), {spans} spans, {pixels} pixels")


def describe(stream, name, at):
    last = None
    for item in decode(stream[:at + 1] + (0xFFFF,) * 300, name):
        if item[2] > at:
            break
        last = item
    triangle, span, start, head, position, _ = last
    if span is None:
        return f"triangle {triangle}: terminator"
    where = at - start
    part = ("header" if where == 0 else "position" if where == 1
            else f"pixel {where - 2}")
    return (f"triangle {triangle}, span {span} (x={position & 0xFF} "
            f"y={position >> 8}, length {(head & 0xFF) + 1}, "
            f"tint/level ${head >> 8:02X}): {part}")


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawTextHelpFormatter)
    parser.add_argument("stream", type=Path)
    parser.add_argument("reference", type=Path, nargs="?")
    args = parser.parse_args()
    stream = units(args.stream)
    if args.reference is None:
        summarize(stream, str(args.stream))
        return 0
    reference = units(args.reference)
    for at, (got, want) in enumerate(zip(stream, reference)):
        if got != want:
            print(f"first difference at unit {at}: ${got:04X}, "
                  f"reference ${want:04X}")
            print("  reference:", describe(reference, str(args.reference), at))
            lo = max(0, at - 6)
            print("  stream   :", " ".join(f"{u:04X}" for u in stream[lo:at + 7]))
            print("  reference:", " ".join(f"{u:04X}" for u in reference[lo:at + 7]))
            return 1
    if len(stream) != len(reference):
        print(f"streams agree for {min(len(stream), len(reference))} units, "
              f"then one ends: {len(stream)} against {len(reference)}")
        return 1
    summarize(stream, str(args.stream))
    print("identical to the reference")
    return 0


if __name__ == "__main__":
    sys.exit(main())
