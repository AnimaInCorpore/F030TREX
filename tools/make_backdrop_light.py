#!/usr/bin/env python3
"""Print the light set and the shade ramp of the backdrop build (OPTIMIZATION.md 6.6c).

The DSP's light model is unchanged: three directional lights, each clamped
separately, summed once with a "red" and once with a "green" weight; the
brightness level is 0.299 R + 0.701 G of the direct sums, and the tint class
counts how many of the thresholds 1.378 / 1.529 / 1.649 the ratio
(R + ambient_r) / (G + ambient_g) reaches.  Only the numbers the host sends
and the colours the host shades its CLUT banks with are new.

The trail has a bright canopy opening at camera left and bare earth underfoot.
Three broad light sources shape the animal through its turn. The two weights
select the tint for each face:

  sky     from above and camera left                 R = G    -> ratio falls to 1
  sun     diffuse fill from the open foreground      R = G
  bounce  from the exposed earth, below               R = 4 G  -> ratio rises

  tint 0  lit by sky or sun           daylight
  tint 1  ambient only (ratio 1.45)   shade
  tint 2  a little bounce
  tint 3  lit by the bounce           muted earth reflection from below

Each tint's sixteen levels run from the shade colour to that light's colour.
The image this build pairs with applies no depth cue (NOFOG=1), so a level
means the same at every distance.

Usage: make_backdrop_light.py      (prints the two assembly tables)
"""
import math

from make_backdrop_path import pitch_view

LIGHTS = [
    # name, level-world direction (+X right, +Y down, +Z away), luminance, R/G
    ("sky", (-0.58, -0.76, -0.30), 0.72, 1.0),
    ("sun", (0.18, -0.22, -0.96), 0.36, 1.0),
    ("bounce", (0.05, 0.95, -0.28), 0.16, 4.0),
]
AMBIENT = (0.29, 0.20)                    # ratio 1.45: an unlit face is tint 1
SHADE = (24, 28, 32)                      # level 0 of every tint, over 64
TOP = [(49, 53, 55), (42, 46, 50), (46, 46, 43), (49, 45, 39)]   # level 15 per tint
SHADE_BIAS = [(0, 0, 0), (0, 0, 0), (1, 0, -1), (2, 0, -2)]     # level 0 leans to the tint


def q23(value):
    return "$%08x" % (int(round(value * (1 << 23))) & 0xffffff)


def tables():
    """Light vectors (camera space, red and green sets), ambient and the 4x16 RGB ramp."""
    rows = {"red": [], "green": []}
    for name, direction, luminance, ratio in LIGHTS:
        direction = (direction[0], *pitch_view(*direction[1:]))
        length = math.sqrt(sum(c * c for c in direction))
        unit = [c / length for c in direction]
        green = luminance / (0.299 * ratio + 0.701)
        red = green * ratio
        rows["red"].append((name, [c * red for c in unit]))
        rows["green"].append((name, [c * green for c in unit]))
    ramp = []
    for tint in range(4):
        low = [s + b for s, b in zip(SHADE, SHADE_BIAS[tint])]
        ramp.append([[int(round(lo + (hi - lo) * level / 15.0)) for lo, hi in zip(low, TOP[tint])]
                     for level in range(16)])
    return rows, AMBIENT, ramp


def main():
    rows, ambient, ramp = tables()
    print("	; tools/make_backdrop_light.py")
    for channel in ("red", "green"):
        for name, vector in rows[channel]:
            print("	dc.l	%s	; %-5s %s" % (",".join(q23(c) for c in vector), channel, name))
    print("	dc.l	%s,%s		; ambient, red and green: ratio %.2f" % (
        q23(ambient[0]), q23(ambient[1]), ambient[0] / ambient[1]))
    print()
    for tint in range(4):
        for level in range(16):
            print("	dc.w	%d,%d,%d	; T%d L%2d" % (*ramp[tint][level], tint, level))


if __name__ == "__main__":
    main()
