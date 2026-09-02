#!/usr/bin/env python3
"""Turn phas_sta.res into the per-phase BUILD ladder (OPTIMIZATION.md 2.4l).

The ladder build sweeps the whole 2,724-triangle mesh through the ordinary
BUILD chunk protocol once per phase mask, with GET_TRIANGLES omitted so that
every level moves the identical 5,762 words over the host port.  Level 0 is
therefore the transport alone and each level above it adds exactly one phase
of the DSP's per-triangle body, over exactly the triangles BUILD runs that
phase on.

All eight levels run in the SAME frame, so the deltas are paired
subtractions over one frame set, not a comparison of runs.

Timers are 200 Hz ticks (5 ms).  Usage:

  decode_phase_stats.py phas_sta.res [more.res ...]
  decode_phase_stats.py --guards ladder.res control.res

--guards prices the instrumentation itself: the ladder image pays seven
JCLRs per triangle that the shipping image does not, and the arm-2 control
sweep against a .lod built WITHOUT the ladder is the same full body without
them.  The difference is the ladder's own overhead, measured.
"""
import struct
import sys

TICK_MS = 5.0
LEVELS = 8

# What each level ADDS to the one below it.  Level 0 executes no phase at
# all: the DSP still receives every chunk and still runs the countdown, so it
# is the chunk protocol and nothing else.
PHASES = [
    "transport only, no phase executed",
    "+ loop, kill test and index unpack",
    "+ make_triangle_area, backface cull",
    "+ make_triangle_bbox, screen cull",
    "+ make_triangle_zkey",
    "+ prelight fetch (shade)",
    "+ make_triangle_span, span_div",
    "+ eighteen-word record pack",
]


def load(path):
    data = open(path, 'rb').read()
    n = len(data) // 4
    expect = 5 + 2 * LEVELS
    if n != expect:
        sys.exit("%s: %d longwords, expected %d -- not a 'PHS1' sidecar of "
                 "this revision" % (path, n, expect))
    v = struct.unpack(">%dI" % n, data[:n * 4])
    if v[0] != 0x50485331:
        sys.exit("%s: magic %08x is not 'PHS1'" % (path, v[0]))
    return {
        "arm": v[1], "frames": v[2], "sweeps": v[3], "fails": v[4],
        "ticks": list(v[5:5 + LEVELS]),
        "survivors": list(v[5 + LEVELS:5 + 2 * LEVELS]),
    }


def per_frame(stats):
    return [t * TICK_MS / stats["frames"] for t in stats["ticks"]]


def report(path):
    s = load(path)
    print("%s  (arm %d)" % (path, s["arm"]))
    if not s["frames"]:
        print("  no completed frames -- the run never got past trex_init")
        return
    print("  frames completed  : %d" % s["frames"])
    print("  sweeps completed  : %d  (%.2f per frame)"
          % (s["sweeps"], s["sweeps"] / s["frames"]))
    print("  protocol failures : %d%s"
          % (s["fails"], "" if not s["fails"] else
             "   <-- FAILED SWEEPS WERE NOT ACCUMULATED; every figure below "
             "is taken over fewer sweeps than frames and must not be quoted"))

    ms = per_frame(s)
    if s["arm"] == 2:
        print("  -- control sweep: the full body with NO ladder guards --")
        print("    %-40s %8.1f ms  %d survivors"
              % ("whole-mesh sweep", ms[LEVELS - 1], s["survivors"][LEVELS - 1]))
        return

    print("  -- ladder, ms/frame over the whole 2,724-triangle mesh --")
    print("    %-2s %-36s %9s %9s %10s" %
          ("lv", "phases executed", "total", "delta", "survivors"))
    for i in range(LEVELS):
        delta = "%9.1f" % (ms[i] - ms[i - 1]) if i else "%9s" % "--"
        print("    %-2d %-36s %9.1f %s %10d"
              % (i, PHASES[i], ms[i], delta, s["survivors"][i]))
    print("    %-2s %-36s %9.1f" % ("", "compute above transport",
                                    ms[LEVELS - 1] - ms[0]))
    # The whole ladder is inside t_packets in this build, so this is what to
    # subtract from that stage's figure to recover the renderer's own packet
    # stage -- a cross-check the run gets for free.
    print("    %-2s %-36s %9.1f" % ("", "all eight sweeps, per frame",
                                    sum(ms)))

    # Gates.  The record write and the counter behind it are the only thing
    # the RECORD bit gates, so every level below the top must report no
    # survivors at all, and the top level must report the same population
    # the frame's real BUILD reports.
    bad = [i for i in range(LEVELS - 1) if s["survivors"][i]]
    if bad:
        print("    GATE FAILED: levels %s reported survivors, and only the "
              "top level writes records.  The usual cause is a host binary "
              "paired with a .lod built WITHOUT the ladder: it decodes the "
              "mask as a CMD_PREPASS arming mode and builds every triangle "
              "regardless.  Re-run with the PHASEPROBE image." % bad)
    else:
        print("    gate: no level below the top reported a survivor")
    print("    gate: top level survivors = %d  (compare render_stats.res "
          "'survivor packets')" % s["survivors"][LEVELS - 1])


def guards(ladder_path, control_path):
    ladder, control = load(ladder_path), load(control_path)
    if ladder["arm"] != 1 or control["arm"] != 2:
        sys.exit("expected an arm-1 ladder and an arm-2 control, got arms "
                 "%d and %d" % (ladder["arm"], control["arm"]))
    # Both figures are per-frame means, so they only subtract when the two
    # runs cover the same stretch of the choreography -- re-converge the two
    # VBL budgets rather than subtracting across different prefixes.
    if ladder["frames"] != control["frames"]:
        sys.exit("the two runs cover %d and %d frames -- re-converge "
                 "MEASURE_PHASE_VBLS and MEASURE_PHASE_CONTROL_VBLS onto the "
                 "same frame count before subtracting"
                 % (ladder["frames"], control["frames"]))
    if ladder["survivors"][LEVELS - 1] != control["survivors"][LEVELS - 1]:
        sys.exit("the two runs' last frames report %d and %d survivors -- "
                 "same frame count, different populations, so the two images "
                 "are not building the same mesh"
                 % (ladder["survivors"][LEVELS - 1],
                    control["survivors"][LEVELS - 1]))
    lad = per_frame(ladder)[LEVELS - 1]
    con = per_frame(control)[LEVELS - 1]
    print("ladder image, full sweep : %8.1f ms/frame  (%d frames)"
          % (lad, ladder["frames"]))
    print("control image, full sweep: %8.1f ms/frame  (%d frames)"
          % (con, control["frames"]))
    print("seven JCLRs per triangle : %8.1f ms/frame  (%.1f%% of the sweep)"
          % (lad - con, 100.0 * (lad - con) / lad if lad else 0.0))
    print("Subtract that from the ladder's total, not from any single delta:")
    print("each level pays the guards of the phases it executes, so the bias")
    print("sits in the deltas in proportion to the triangles reaching them.")


def main(argv):
    if len(argv) > 1 and argv[1] == "--guards":
        if len(argv) != 4:
            sys.exit(__doc__)
        guards(argv[2], argv[3])
        return
    if len(argv) < 2:
        sys.exit(__doc__)
    for path in argv[1:]:
        report(path)


if __name__ == '__main__':
    main(sys.argv)
