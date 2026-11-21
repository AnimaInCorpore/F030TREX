#!/usr/bin/env python3
"""Model reusing the row above's texel offsets (OPTIMIZATION.md 7.4j).

Reads one 640x400 span stream (three-unit headers: length - 1,
bank << 9 | y, x; one V << 8 | U unit per pixel; $FFFF per triangle) and
asks: if a span's offsets were rebuilt as "the pixel directly above in the
same triangle plus one packed constant for the whole row", how many would be
right?  The constant is the row's most common packed difference, which is the
best a per-row delta can do.

  direct   each row against the TRUE row above (lossless coverage)
  chained  each row against the REBUILT row above, as a decoder would run
"""
import collections
import struct
import sys


def triangles(path):
    data = open(path, "rb").read()
    u = struct.unpack(f">{len(data) // 2}H", data)
    i, cur = 0, []
    while i < len(u):
        if u[i] == 0xFFFF:
            yield cur
            cur, i = [], i + 1
            continue
        n = u[i] + 1
        cur.append((u[i + 1] & 0x1FF, u[i + 2], list(u[i + 3:i + 3 + n])))
        i += 3 + n


def texel_error(got, want):
    return max(abs((got & 255) - (want & 255)), abs((got >> 8) - (want >> 8)))


def run(path, chained):
    total = above = 0
    err = collections.Counter()
    for tri in triangles(path):
        prev = None
        for y, x, tex in tri:
            total += len(tex)
            rec = list(tex)
            if prev and prev[0] == y - 1:
                pm = {prev[1] + k: v for k, v in enumerate(prev[2])}
                ks = [k for k in range(len(tex)) if x + k in pm]
                if ks:
                    c = collections.Counter((tex[k] - pm[x + k]) & 0xFFFF
                                            for k in ks).most_common(1)[0][0]
                    for k in ks:
                        g = (pm[x + k] + c) & 0xFFFF
                        rec[k] = g
                        above += 1
                        err[min(texel_error(g, tex[k]), 9)] += 1
            prev = (y, x, rec if chained else tex)
    return total, above, err


def main():
    path = sys.argv[1]
    for chained in (False, True):
        total, above, err = run(path, chained)
        name = "chained" if chained else "direct"
        print(f"{name}: {total} pixels, {above} ({100 * above / total:.1f}%) "
              f"have a pixel above in the same triangle")
        for e, n in sorted(err.items()):
            label = f"{e}+" if e == 9 else str(e)
            print(f"  off by {label} texel(s): {n:6d}  {100 * n / above:5.1f}%")


if __name__ == "__main__":
    main()
