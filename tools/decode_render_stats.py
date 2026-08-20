#!/usr/bin/env python3
"""Turn render_stats.res into a readable per-frame report.

The renderer dumps its frame timers and counters as big-endian longwords
(trex_write_render_stats).  All timers are 200 Hz ticks, so one tick is 5 ms.

Field 22 (t_prepass) exists only in -DTREX_PREPASS builds, which is what the
23-vs-24 longword length distinguishes.

Usage: decode_render_stats.py render_stats.res [more.res ...]
       decode_render_stats.py --split normal.res nopix.res norows.res
                              [--expect-frames N]

--split turns the three profile builds of OPTIMIZATION.md 8.2 into the
rasterizer decomposition.  NO_ROWS keeps only the per-packet setup and
NO_PIXELS keeps setup plus the row walk, so the three rasterizer totals
subtract into the three terms.  The subtraction is only meaningful when all
three runs cover the SAME frames -- the choreography is not uniform -- which
is what --expect-frames enforces.
"""
import struct
import sys

BASE = ["frames", "vbl_start", "vbl_end", "hz200_start", "hz200_end",
        "t_setframe", "t_packets", "t_clear", "t_otinsert", "t_raster",
        "t_present", "pixels", "ot_nodes", "dsp_packets", "ot_prims",
        "stream_ready", "dsp_state", "video_mode", "monitor",
        "dsp_x_avail", "dsp_y_avail", "normals"]

STAGES = [("DSP set_frame", "t_setframe"),
          ("DSP readback + packet build", "t_packets"),
          ("Framebuffer clear", "t_clear"),
          ("Ordering Table insertion", "t_otinsert"),
          ("Software span rasterizer", "t_raster"),
          ("Present", "t_present")]

TICK_MS = 5.0

# Cumulative over the run; everything else in the counter block is the last
# completed frame's value, because the renderer clears it per frame.
CUMULATIVE = {"pixels"}


def load(path):
    data = open(path, "rb").read()
    n = len(data) // 4
    values = struct.unpack(">%dI" % n, data[:n * 4])
    fields = list(BASE)
    stages = list(STAGES)
    if n >= 24:                     # -DTREX_PREPASS inserts t_prepass here
        fields.append("t_prepass")
        stages.append(("DSP occlusion prepass", "t_prepass"))
    fields.append("dc_clear_longs")
    return dict(zip(fields, values)), n, stages


def report(path):
    stats, longs, stages = load(path)
    frames = stats["frames"]
    print("%s  (%d longwords)" % (path, longs))
    if not frames:
        print("  no completed frames -- the run never got past trex_init")
        return

    wall_ms = (stats["hz200_end"] - stats["hz200_start"]) * TICK_MS
    per_frame = wall_ms / frames
    print("  frames completed  : %d" % frames)
    print("  wall clock        : %.0f ms  (%.1f ms/frame, %.2f FPS)"
          % (wall_ms, per_frame, 1000.0 * frames / wall_ms))
    print("  VBLs bracketed    : %d" % (stats["vbl_end"] - stats["vbl_start"]))

    print("  -- stages, ms/frame --")
    accounted = 0.0
    for label, key in stages:
        ms = stats[key] * TICK_MS / frames
        accounted += ms
        print("    %-30s %8.1f ms  %5.1f%%" % (label, ms, 100.0 * ms / per_frame))
    print("    %-30s %8.1f ms" % ("accounted", accounted))
    print("    %-30s %8.1f ms" % ("unaccounted", per_frame - accounted))

    print("  -- counters --")
    print("    %-30s %10d  (%.1f per frame)"
          % ("pixels written, cumulative", stats["pixels"], stats["pixels"] / frames))
    for key, label in (("dsp_packets", "survivor packets"),
                       ("ot_nodes", "OT nodes"),
                       ("ot_prims", "OT primitives")):
        print("    %-30s %10d  (last frame)" % (label, stats[key]))

    print("  -- state --")
    for key in ("stream_ready", "dsp_state", "video_mode", "monitor",
                "dsp_x_avail", "dsp_y_avail", "normals", "dc_clear_longs"):
        print("    %-30s %10d" % (key, stats[key]))


def per_frame_ms(stats, key):
    return stats[key] * TICK_MS / stats["frames"]


def frame_ms(stats):
    return (stats["hz200_end"] - stats["hz200_start"]) * TICK_MS / stats["frames"]


def split(paths, expect_frames):
    """Decompose the rasterizer from the normal/NO_PIXELS/NO_ROWS trio."""
    labels = ("normal", "NO_PIXELS", "NO_ROWS")
    runs = [load(path)[0] for path in paths]

    frames = {stats["frames"] for stats in runs}
    if len(frames) != 1:
        sys.exit("runs cover different frame counts %s -- re-converge the VBL "
                 "budgets before subtracting" % sorted(frames))
    frames = frames.pop()
    if expect_frames is not None and frames != expect_frames:
        sys.exit("runs cover %d frames, expected %d -- re-converge the VBL "
                 "budgets" % (frames, expect_frames))

    raster = [per_frame_ms(stats, "t_raster") for stats in runs]
    packet = [per_frame_ms(stats, "t_packets") for stats in runs]
    total = frame_ms(runs[0])

    setup = raster[2]
    rows = raster[1] - raster[2]
    pixels = raster[0] - raster[1]
    other = total - packet[0] - raster[0]

    print("  frames                        : %d (all three runs)" % frames)
    print("  -- patch builds, ms/frame --")
    for label, stats, r in zip(labels, runs, raster):
        print("    %-14s rasterizer %7.1f   frame %7.1f"
              % (label, r, frame_ms(stats)))
    print("  -- packet stage cross-check, ms/frame --")
    print("    %s" % "  ".join("%s %.1f" % (l, p) for l, p in zip(labels, packet)))
    print("    the patches must not move this; a drift here invalidates the split")
    print("  -- split, ms/frame --")
    print("    %-34s %7.1f" % ("DSP setup + readback + packet build", packet[0]))
    print("    %-34s %7.1f" % ("Raster per-packet setup", setup))
    print("    %-34s %7.1f" % ("Raster row/span walk", rows))
    print("    %-34s %7.1f" % ("Raster pixel loops", pixels))
    print("    %-34s %7.1f" % ("set_frame + clear + OT + rounding", other))
    print("    %-34s %7.1f ms / %.2f FPS" % ("Total", total, 1000.0 / total))


if __name__ == "__main__":
    args = sys.argv[1:]
    if not args:
        sys.exit(__doc__)
    if args[0] == "--split":
        args = args[1:]
        expect = None
        if "--expect-frames" in args:
            i = args.index("--expect-frames")
            expect = int(args[i + 1])
            args = args[:i] + args[i + 2:]
        if len(args) != 3:
            sys.exit("--split needs exactly normal.res nopix.res norows.res")
        split(args, expect)
    else:
        for path in args:
            report(path)
