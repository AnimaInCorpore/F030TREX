#!/usr/bin/env python3
"""Paint a 640x400 snowfield backdrop for a fixed, up-tilted camera.

Run: python tools/make_snow_backdrop.py <out.png> [horizon row] [seed]

The horizon row is where the ground plane meets the sky for the scene's
camera (centre row + focal Y * tan(pitch up)); tools/blender_build_walkers.py
passes it. Sky: a pale haze gradient with soft cloud. Far ground: misty
mountains. Ground: snow whose drift streaks stretch with distance. The
picture is dithered to the Falcon's RGB565 so the gradients do not band.
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

WIDTH, HEIGHT = 640, 400


def noise(rng, shape, cells):
    """Smooth value noise in 0..1: a random grid of the given cell counts, bicubic."""
    grid = rng.random((cells[1] + 1, cells[0] + 1)).astype(np.float32)
    image = Image.fromarray(grid, "F").resize((shape[1], shape[0]), Image.BICUBIC)
    return np.clip(np.asarray(image), 0.0, 1.0)


def fractal(rng, shape, cells, octaves=4):
    total, weight, amplitude = np.zeros(shape, np.float32), 0.0, 1.0
    for octave in range(octaves):
        total += amplitude * noise(rng, shape, (cells[0] << octave, cells[1] << octave))
        weight += amplitude
        amplitude *= 0.5
    return total / weight


def glacier(rng, x, y, horizon, peaks, shade, snow, haze):
    """A broken ridge sheds snow down diagonal gullies into valley mist."""
    horizontal = x[0]
    crest = np.interp(horizontal, *zip(*peaks))
    for spacing, amplitude in ((21, 6), (7, 2.8), (2, 1)):
        knots = np.arange(0, WIDTH + spacing, spacing)
        crest += np.interp(horizontal, knots, rng.uniform(-amplitude, amplitude, len(knots)))
    crest = horizon - crest
    depth = np.maximum(y - crest, 0)
    # Sample the source ridge uphill from each pixel. Alternating aspects
    # produce lit snow faces and shaded spurs that follow the peak contour.
    uphill = np.clip(x + depth * 0.55, 0, WIDTH - 1)
    slope = np.interp(uphill, horizontal, np.gradient(crest))
    aspect = np.clip(0.64 + 0.39 * slope, 0, 1)
    grain = fractal(rng, (HEIGHT, WIDTH), (65, 20), 3)
    exposure = np.clip(aspect * 0.83 + grain * 0.32, 0, 1)[..., None]
    colour = shade + (np.array(snow) - shade) * exposure
    mist = np.clip(depth / 78, 0, 0.88)[..., None]
    return crest, colour * (1 - mist) + haze * mist


def outpost(picture, horizon):
    """Tiny dish, access huts and their snow banks at the valley mouth."""
    plate = Image.fromarray((picture * 255).clip(0, 255).astype(np.uint8))
    draw = ImageDraw.Draw(plate)
    y = horizon + 1
    for x, w in ((28, 15), (48, 8), (67, 13)):
        draw.polygon([(x, y), (x+2, y-3), (x+w-3, y-4), (x+w, y)], fill=(162, 184, 192))
        draw.line([(x+1, y-2), (x+4, y-4), (x+w-3, y-4)], fill=(223, 235, 234))
    draw.polygon([(50,y-3), (53,y-12), (55,y-3)], fill=(141, 163, 176))
    draw.polygon([(45,y-17), (60,y-11), (56,y-9), (51,y-10), (47,y-13)], fill=(150, 172, 183))
    draw.line([(46,y-17), (59,y-12)], fill=(227, 236, 233))
    draw.line([(53,y-15), (54,y-18)], fill=(158, 178, 185))
    return np.asarray(plate).astype(np.float32) / 255


def paint(horizon=320, seed=7, travelling=False):
    """Paint a distant ice valley with quieter foreground detail for a tracking camera."""
    if travelling:
        # The authored matte has its snowline at 75% height. Reframe sky
        # and ground separately so the painted and projected horizons agree.
        path = Path(__file__).resolve().parents[1] / "TREX/textures/atat_glacier.png"
        with Image.open(path) as plate:
            horizon_row = max(1, min(HEIGHT - 1, horizon))
            split = round(plate.height * 0.75)
            sky = plate.crop((0, 0, plate.width, split)).resize((WIDTH, horizon_row), Image.Resampling.LANCZOS)
            snow = plate.crop((0, split, plate.width, plate.height)).resize(
                (WIDTH, HEIGHT - horizon_row), Image.Resampling.LANCZOS)
            picture = np.concatenate([np.asarray(sky), np.asarray(snow)]) / 255.0
            distance = (np.arange(HEIGHT)[:, None, None] - horizon_row) / 95
            haze = 0.24 * np.exp(-distance**2)
            picture = picture * (1 - haze) + np.array([0.88, 0.92, 0.93]) * haze
        return rgb565(picture)
    rng = np.random.default_rng(seed)
    rows = np.arange(HEIGHT, dtype=np.float32)[:, None]
    columns = np.arange(WIDTH, dtype=np.float32)[None, :]
    picture = np.zeros((HEIGHT, WIDTH, 3), np.float32)

    # Sky: blue-grey overhead, brightening into haze at the horizon.
    t = np.clip(rows / horizon, 0.0, 1.0) ** 1.6
    top, low = np.array([0.57, 0.75, 0.79]), np.array([0.89, 0.93, 0.92])
    sky = top + (low - top) * t[..., None]
    cloud = fractal(rng, (HEIGHT, WIDTH), (3, 2), 5)
    sky = sky + (cloud[..., None] - 0.5) * 0.10 * (1.0 - 0.6 * t[..., None])
    veil = fractal(rng, (HEIGHT, WIDTH), (3, 13), 4)
    sky += (veil[..., None] - 0.5) * 0.058
    picture[:] = sky

    ranges = [
        ([(0,58), (58,82), (94,60), (130,73), (219,32), (292,50), (368,35),
          (440,68), (506,45), (585,89), (639,59)], (0.65,0.76,0.81), (0.86,0.91,0.92)),
        ([(0,29), (69,46), (118,32), (178,57), (242,22), (334,15), (398,31),
          (455,21), (549,51), (598,38), (639,63)], (0.52,0.64,0.72), (0.87,0.91,0.91)),
    ]
    for peaks, shade, snow_tint in ranges:
        crest, colour = glacier(rng, columns, rows, horizon, peaks, np.array(shade), snow_tint, low)
        picture = np.where((rows >= crest)[..., None], colour, picture)

    # Snow: drift streaks whose scale grows towards the camera.
    below = np.clip((rows - horizon) / max(1.0, HEIGHT - horizon), 0.0, 1.0)
    streak_far = fractal(rng, (HEIGHT, WIDTH), (26, 60), 3)
    streak_near = fractal(rng, (HEIGHT, WIDTH), (7, 26), 4)
    drift = streak_far * (1.0 - below) + streak_near * below
    lit, shade = np.array([0.95, 0.97, 0.98]), np.array([0.70, 0.80, 0.89])
    snow = shade + (lit - shade) * np.clip(0.25 + 1.1 * drift, 0.0, 1.0)[..., None]
    snow = snow * (0.93 + 0.07 * below[..., None])
    # A drift crest across the foreground, with its shaded lee side.
    crest = horizon + (HEIGHT - horizon) * (0.62 + 0.16 * fractal(rng, (1, WIDTH), (4, 1), 3)[0])
    lee = np.clip((rows - crest[None, :]) / 9.0, 0.0, 1.0) * np.clip(1.6 - (rows - crest[None, :]) / 22.0, 0.0, 1.0)
    snow = snow - lee[..., None] * np.array([0.13, 0.09, 0.05])
    haze = np.clip(1.0 - below * 7.0, 0.0, 1.0)[..., None]
    snow = snow + (low - snow) * haze * 0.8
    picture = np.where((rows >= horizon)[..., None], snow, picture)
    return rgb565(outpost(picture, horizon))


def rgb565(picture):
    """Dither before the runtime's integer colour steps become visible bands."""
    bayer = np.array([[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]], np.float32) / 16 - 0.47
    threshold = np.tile(bayer, (HEIGHT // 4, WIDTH // 4))
    levels = np.array([31.0, 63.0, 31.0])
    quantized = np.clip(np.rint(np.clip(picture, 0, 1) * levels + threshold[..., None] * 0.9), 0, levels)
    return np.rint(quantized / levels * 255).astype(np.uint8)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    horizon = int(sys.argv[2]) if len(sys.argv) > 2 else 320
    seed = int(sys.argv[3]) if len(sys.argv) > 3 else 7
    Image.fromarray(paint(horizon, seed), "RGB").save(sys.argv[1])
    print("wrote %s (horizon row %d)" % (sys.argv[1], horizon))
