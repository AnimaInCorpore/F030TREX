#!/usr/bin/env python3
"""Turn render_stats.res into a readable per-frame report.

The renderer dumps its frame timers and counters as big-endian longwords
(trex_write_render_stats).  All timers are 200 Hz ticks, so one tick is 5 ms.

Field 22 (t_prepass) exists only in -DTREX_PREPASS builds, which is what the
23-vs-24 longword length distinguishes.

Usage: decode_render_stats.py render_stats.res [more.res ...]
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


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    for path in sys.argv[1:]:
        report(path)
