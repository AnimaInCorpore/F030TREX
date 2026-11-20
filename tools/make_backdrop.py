#!/usr/bin/env python3
"""Convert a picture into the backdrop of the 640x400 build (OPTIMIZATION.md 6.6c).

The 640x400 mode's pixel is about 0.92 as wide as it is tall on a TV, which is
why the renderer uses different horizontal and vertical focal lengths. The
trail lens retains the reference lens ratio to rounding. For TV,
the source is cropped to 1866/2020 of its width around its centre and
then scaled to 640x400.  In an emulator that draws square pixels both the
model and the picture therefore look about 8% too wide, together.

Output: 640x400 big-endian Falcon true-colour words (RRRRRGGGGGGBBBBB), row
by row, 512,000 bytes, ordered-dithered; optionally a PNG of exactly those
pixels.  The same input gives the same bytes.

Usage: make_backdrop.py <source image> <out.bin> [preview.png] [--trail-camera]
"""
import sys

from make_backdrop_path import CENTRE_Y, FOCAL_X as TRAIL_X, FOCAL_Y as TRAIL_Y, pitch_view

import numpy as np
from PIL import Image

W, H = 640, 400
FOCAL_X, FOCAL_Y = 2020.0, 1866.0

BAYER = np.array([[0, 32, 8, 40, 2, 34, 10, 42], [48, 16, 56, 24, 50, 18, 58, 26],
                  [12, 44, 4, 36, 14, 46, 6, 38], [60, 28, 52, 20, 62, 30, 54, 22],
                  [3, 35, 11, 43, 1, 33, 9, 41], [51, 19, 59, 27, 49, 17, 57, 25],
                  [15, 47, 7, 39, 13, 45, 5, 37], [63, 31, 55, 23, 61, 29, 53, 21]], dtype=np.float32)


def main(argv):
    argv = list(argv)
    reproject = argv[-1] == "--trail-camera"
    if reproject:
        argv.pop()
    if len(argv) not in (3, 4):
        sys.exit(__doc__)
    source = Image.open(argv[1]).convert("RGB")
    sw, sh = source.size
    # The picture's own shape first: the largest centred 16:10 part of it.
    if sw * H > sh * W:
        keep = sh * W // H
        source = source.crop(((sw - keep) // 2, 0, (sw - keep) // 2 + keep, sh))
    else:
        keep = sw * H // W
        source = source.crop((0, (sh - keep) // 2, sw, (sh - keep) // 2 + keep))
    sw, sh = source.size
    # Then the mode's pixel shape: keep 1866/2020 of the width, stretched to 640.
    keep = int(round(sw * FOCAL_Y / FOCAL_X))
    left = (sw - keep) // 2
    source = source.crop((left, 0, left + keep, sh)).resize((W, H), Image.LANCZOS)

    if reproject:
        # Inverse perspective map from the fixed trail camera to the
        # level source plate, calibrated at focal lengths 940 and 868.
        _, c = pitch_view(0, 1)
        _, sn = pitch_view(1, 0)
        # Pillow's output pixel centres and the plate share the same origin.
        z0 = c + sn * CENTRE_Y / TRAIL_Y
        zy = -sn / TRAIL_Y
        coeffs = (
            940 / TRAIL_X / z0, 320 * zy / z0,
            320 - 940 * 320 / TRAIL_X / z0,
            0, (200 * zy + 868 * c / TRAIL_Y) / z0,
            200 + 868 * (sn - c * CENTRE_Y / TRAIL_Y) / z0,
            0, zy / z0,
        )
        source = source.transform((W, H), Image.Transform.PERSPECTIVE, coeffs,
                                  resample=Image.Resampling.BICUBIC)

    rgb = np.asarray(source).astype(np.float32) / 255.0
    dither = (np.tile(BAYER, (H // 8, W // 8)) + 0.5) / 64.0 - 0.5
    r5 = np.clip(np.round(rgb[..., 0] * 31 + dither), 0, 31).astype(np.uint16)
    g6 = np.clip(np.round(rgb[..., 1] * 63 + dither), 0, 63).astype(np.uint16)
    b5 = np.clip(np.round(rgb[..., 2] * 31 + dither), 0, 31).astype(np.uint16)
    words = (r5 << 11) | (g6 << 5) | b5
    # Pure black is the cleared screen of the builds without a backdrop; keep
    # the picture clear of it so a frame dump tells the two apart.
    words[words == 0] = 1
    words.astype(">u2").tofile(argv[2])
    if len(argv) == 4:
        r5, g6, b5 = words >> 11, (words >> 5) & 63, words & 31
        preview = np.dstack([(r5 * 255 + 15) // 31, (g6 * 255 + 31) // 63, (b5 * 255 + 15) // 31])
        Image.fromarray(preview.astype(np.uint8), "RGB").save(argv[3])
    print("%s: %d bytes from %s" % (argv[2], words.size * 2, argv[1]))


if __name__ == "__main__":
    main(sys.argv)
