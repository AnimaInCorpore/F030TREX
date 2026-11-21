#!/usr/bin/env python3
"""Compare Blender renders of the source scene with a Hatari fbseq.res capture.

Usage: compare_blender_render.py [--model <model dir>] <fbseq.res> <render dir> <blender frame> [...]

--model names a directory written by make model_export (its backdrop and
shadow); the default is the T-Rex trail's.

fbseq.res holds one 640x400 big-endian RGB565 framebuffer per displayed
frame; capture frame k is trail sample k, Blender frame k+1 on the first
pass. The ground (backdrop plus the exported shadow rings, darkened with the
host's integer arithmetic) separates model pixels from background. For each
frame the script reports exact and within-one-step pixel matches, background
matches, the silhouette overlap, and the mean colour difference inside both
silhouettes; it writes <render dir>/compare_NNNN.png (Hatari | Blender | diff).
"""
import struct
import sys
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
W, H = 640, 400


def channels(words):
    return np.dstack([words >> 11, (words >> 5) & 63, words & 31]).astype(np.int32)


BACKDROP = ROOT / "TREX/textures/backdrop_640x400.bin"
SHADOW = ROOT / "TREX/model/backdrop_shadow.bin"


def ground(sample):
    """draw_ground_shadow applied to the backdrop for one sample."""
    words = np.fromfile(BACKDROP, ">u2").reshape(H, W).astype(np.int32)
    rgb = channels(words)
    data = SHADOW.read_bytes()
    index = struct.unpack_from(">I", data, sample * 4)[0]
    cursor = (index & 0xFFFFFF) + 8
    for ellipse in range((index >> 24) + 1):
        for ring in range(3):
            first, rows = struct.unpack_from(">Hh", data, cursor)
            cursor += 4
            shift = 4 if ring == 0 else 3
            for row in range(rows + 1):
                column, longs = struct.unpack_from(">HH", data, cursor)
                cursor += 4
                span = rgb[first + row, column // 2:column // 2 + 2 * (longs + 1)]
                span -= span >> shift
    return rgb


def main(fbseq, renders, frames):
    renders = Path(renders)
    for frame in frames:
        words = np.fromfile(fbseq, ">u2", W * H, offset=(frame - 1) * W * H * 2).reshape(H, W)
        hatari = channels(words.astype(np.int32))
        render = np.asarray(Image.open(renders / ("frame_%04d.png" % frame)).convert("RGB")).astype(np.int32)
        blender = np.dstack([(render[..., 0] * 31 + 127) // 255, (render[..., 1] * 63 + 127) // 255,
                             (render[..., 2] * 31 + 127) // 255])
        floor = ground(frame - 1)
        model_h = np.abs(hatari - floor).max(axis=2) > 0
        model_b = np.abs(blender - floor).max(axis=2) > 1
        diff = np.abs(hatari - blender).max(axis=2)
        background = ~model_h & ~model_b
        both = model_h & model_b
        print("frame %d: exact %.1f%%, within one step %.1f%%, background exact %.2f%%; "
              "silhouettes %d / %d px, IoU %.3f; inside both mean |d| R %.2f G %.2f B %.2f, "
              "bias %+.2f %+.2f %+.2f" % (
                  frame, 100 * (diff == 0).mean(), 100 * (diff <= 1).mean(),
                  100 * (diff[background] <= 1).mean(), model_h.sum(), model_b.sum(),
                  both.sum() / max((model_h | model_b).sum(), 1),
                  *np.abs(hatari - blender)[both].mean(axis=0), *(blender - hatari)[both].mean(axis=0)))
        to8 = lambda c: np.dstack([c[..., 0] * 255 // 31, c[..., 1] * 255 // 63, c[..., 2] * 255 // 31])
        heat = np.clip(diff * 16, 0, 255)
        strip = np.hstack([to8(hatari), to8(blender), np.dstack([heat, heat, heat])]).astype(np.uint8)
        Image.fromarray(strip, "RGB").save(renders / ("compare_%04d.png" % frame))


if __name__ == "__main__":
    argv = sys.argv[1:]
    if argv[:1] == ["--model"]:
        BACKDROP, SHADOW = Path(argv[1]) / "backdrop_640x400.bin", Path(argv[1]) / "backdrop_shadow.bin"
        argv = argv[2:]
    if len(argv) < 3:
        sys.exit(__doc__)
    main(argv[0], argv[1], [int(f) for f in argv[2:]])
