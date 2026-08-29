#!/usr/bin/env python3
"""Decode pio_cal.res (trex_m68030_pio_cal) into per-word transport costs.

Solves the two burst sizes per direction for cost = overhead + per_word * N:
the small burst carries the same per-burst overhead (command, two counts,
ack, loop setup) as the large one, so the difference isolates the word rate.
All timings are 200 Hz ticks (5 ms); this is Hatari's port model, not a
physical Falcon.
"""
import struct, sys

data = open(sys.argv[1] if len(sys.argv) > 1 else "pio_cal.res", "rb").read()
v = struct.unpack(">%dI" % (len(data) // 4), data)
assert v[0] == 0x5043414C, "bad magic %08x" % v[0]
assert v[1] == 1, "bad version"

rows = []
for i in range(4):
    m, n, k, ticks, ack, bad, badidx = v[2 + i * 7:2 + (i + 1) * 7]
    ok = ack == 0x700011 and bad == 0
    rows.append((m, n, k, ticks, ok))
    print("M=%5d N=%5d reps=%3d  ticks=%4d (%6.1f ms)  ack %s verify %s"
          % (m, n, k, ticks, ticks * 5.0,
             "ok" if ack == 0x700011 else hex(ack),
             "ok" if bad == 0 else "BAD@%d" % struct.unpack(">i",
                struct.pack(">I", badidx))[0]))

def solve(big, small, label):
    (m0, n0, k0, t0, ok0), (m1, n1, k1, t1, ok1) = big, small
    if not (ok0 and ok1):
        print("%s: verification failed, refusing to solve" % label)
        return
    words0, words1 = max(m0, n0), max(m1, n1)
    per_burst0 = t0 * 5000.0 / k0   # us
    per_burst1 = t1 * 5000.0 / k1
    per_word = (per_burst0 - per_burst1) / (words0 - words1)
    overhead = per_burst1 - per_word * words1
    print("%s: %.3f us/word, %.1f us/burst overhead" % (label, per_word, overhead))
    return per_word

r = solve(rows[0], rows[1], "DSP -> host (record readback direction)")
w = solve(rows[2], rows[3], "host -> DSP (upload direction)      ")
