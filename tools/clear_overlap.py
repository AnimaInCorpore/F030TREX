#!/usr/bin/env python3
"""Upper bound on what a coverage-aware clear could save (OPTIMIZATION.md 2.5a).

Reads fbseq.res from the TREX_FB_SEQUENCE build: every rendered frame's whole
256x224 true-colour screen buffer, in order.  Under the page flip, frame N is
drawn into the buffer that showed frame N-2, so before frame N's clear that
buffer holds frame N-2's picture.  For every frame N >= 2 this counts, inside
the 240x224 render window, the pixels each clear scheme has to wipe:

  full     the whole window (what ships, delta_clear_enabled = 0)
  bands    per 8-row band, the x-hull of frame N-2's drawn pixels, rounded
           out to whole longwords -- the shape of the existing delta clear
           (2.5).  The real band table is built from triangle extents, which
           enclose the drawn pixels, so this is a LOWER bound on that scheme.
  dirty    exactly frame N-2's drawn pixels
  ideal    frame N-2's drawn pixels that frame N does not draw: the least a
           clear that knew frame N's coverage in advance must wipe

"Drawn" means non-zero.  The background is zero and the qualified-opaque and
textured paths never store zero (shade_falcon_color keeps every non-black
texel non-black; a transparent texel is skipped, not stored), so a non-zero
pixel was written this frame and a zero pixel was not.

Also reports how many horizontal runs the ideal set falls into, since every
run costs a clear loop its setup.

Usage: clear_overlap.py fbseq.res [--json out.json]
"""
import argparse
import json
import struct
import sys

BUF_W, BUF_H = 256, 224
WIN_W, WIN_H, WIN_X = 240, 224, 8
BAND = 8
FRAME_BYTES = BUF_W * BUF_H * 2


def drawn_rows(frame):
    """Per window row, a bytes object of 0/1 flags for the 240 pixels."""
    rows = []
    for y in range(WIN_H):
        base = (y * BUF_W + WIN_X) * 2
        words = struct.unpack_from(">%dH" % WIN_W, frame, base)
        rows.append(bytes(1 if w else 0 for w in words))
    return rows


def band_area(rows):
    area = 0
    for b in range(0, WIN_H, BAND):
        xs = [x for y in range(b, b + BAND) for x in range(WIN_W) if rows[y][x]]
        if not xs:
            continue
        lo = min(xs) & ~1
        hi = max(xs) | 1
        area += (hi - lo + 1) * BAND
    return area


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("fbseq")
    ap.add_argument("--json")
    args = ap.parse_args()
    data = open(args.fbseq, "rb").read()
    if len(data) % FRAME_BYTES:
        sys.exit("fbseq.res is not a whole number of %d-byte frames" % FRAME_BYTES)
    n = len(data) // FRAME_BYTES
    masks = [drawn_rows(data[i * FRAME_BYTES:(i + 1) * FRAME_BYTES]) for i in range(n)]

    per = []
    for i in range(2, n):
        old, new = masks[i - 2], masks[i]
        dirty = ideal = runs = 0
        for y in range(WIN_H):
            o, w = old[y], new[y]
            inrun = False
            for x in range(WIN_W):
                if o[x]:
                    dirty += 1
                    if not w[x]:
                        ideal += 1
                        if not inrun:
                            runs += 1
                        inrun = True
                        continue
                inrun = False
        per.append({"frame": i, "full": WIN_W * WIN_H, "bands": band_area(old),
                    "dirty": dirty, "ideal": ideal, "ideal_runs": runs})

    def mean(key):
        return sum(p[key] for p in per) / len(per)

    def peak(key):
        return max(p[key] for p in per)

    full = WIN_W * WIN_H
    print("frames compared: %d (frames 2..%d)" % (len(per), n - 1))
    print("%-8s %12s %10s %10s" % ("scheme", "mean px", "of window", "max px"))
    for key in ("full", "bands", "dirty", "ideal"):
        print("%-8s %12.1f %9.1f%% %10d" % (key, mean(key), 100 * mean(key) / full, peak(key)))
    print("ideal / dirty  : %.1f%%" % (100 * sum(p["ideal"] for p in per)
                                       / max(1, sum(p["dirty"] for p in per))))
    print("ideal runs     : %.1f per frame (max %d)" % (mean("ideal_runs"), peak("ideal_runs")))
    if args.json:
        json.dump({"frames": n, "per_frame": per}, open(args.json, "w"), indent=1)


if __name__ == "__main__":
    main()
