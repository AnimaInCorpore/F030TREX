#!/usr/bin/env python3
"""Build the host-side opaque-texture qualification sidecar.

One output byte belongs to one O3D source triangle.  A value of one means a
normal (non-semitransparent) textured packet may use the prepared 16-bit CLUT
and omit the per-pixel PS1-palette-word validity test.  Zero is always safe:
false negatives cost speed only, while a false positive would fill a real
texture hole and is therefore forbidden.

The native TIM page is authoritative.  Pages with no zero palette word among
their referenced indices qualify immediately.  For a holed page, the tool
constructs an integer-only conservative footprint:

* every closed unit texel cell intersected by the affine UV triangle, and
* a two-texel Chebyshev dilation, with 8-bit texture-coordinate wrapping.

The closed-cell test covers the floor operation at an exact edge.  The
dilation is the current 240x224/Q8.8 rasterizer's conservative cost-model
allowance for chain and span-gradient truncation plus the sub-pixel prestep.
It is intentionally larger than the old floating-point M_uv scan.  The
companion tools/opaque_selftest.py gate then checks every available recorded
rasterizer packet directly: no qualified source triangle may report even one
bit-17 rejection.  Enlarging the render target or changing the fixed-point
walk requires regenerating and revalidating this sidecar.
"""

import argparse
import os
import struct
import sys


O3D_HEADER_BYTES = 24
O3D_POINT_BYTES = 12
O3D_NORMAL_BYTES = 12
O3D_POLYGON_WORDS = 16

TIM_CLUT_DATA_OFFSET = 20
TIM_CLUT_ENTRIES = 256
TIM_PIXEL_DATA_OFFSET = 544
TIM_SIZE = TIM_PIXEL_DATA_OFFSET + 256 * 256
TEXTURE_PAGE_IDS = (10, 12, 14, 26, 28, 30)
TPAGE_MASK = 0x1F
FOOTPRINT_DILATION = 2


class QualificationError(Exception):
    pass


def resolve_tpage(raw):
    """Resolve a packet TPage exactly like rasterize_packet."""
    page = raw & TPAGE_MASK
    return page if page in TEXTURE_PAGE_IDS else TEXTURE_PAGE_IDS[0]


def _cross(a, b, c):
    return ((b[0] - a[0]) * (c[1] - a[1])
            - (b[1] - a[1]) * (c[0] - a[0]))


def _point_on_segment(a, b, point):
    return (_cross(a, b, point) == 0
            and min(a[0], b[0]) <= point[0] <= max(a[0], b[0])
            and min(a[1], b[1]) <= point[1] <= max(a[1], b[1]))


def _segments_intersect(a, b, c, d):
    ab_c = _cross(a, b, c)
    ab_d = _cross(a, b, d)
    cd_a = _cross(c, d, a)
    cd_b = _cross(c, d, b)
    if ((ab_c == 0 and _point_on_segment(a, b, c))
            or (ab_d == 0 and _point_on_segment(a, b, d))
            or (cd_a == 0 and _point_on_segment(c, d, a))
            or (cd_b == 0 and _point_on_segment(c, d, b))):
        return True
    return ((ab_c > 0) != (ab_d > 0)
            and (cd_a > 0) != (cd_b > 0))


def _point_in_triangle(point, triangle):
    signs = [_cross(triangle[i], triangle[(i + 1) % 3], point)
             for i in range(3)]
    return all(value >= 0 for value in signs) or all(value <= 0 for value in signs)


def _cell_intersects_triangle(u, v, uvs):
    """Exact closed-cell/triangle intersection using doubled integers."""
    triangle = [(2 * x, 2 * y) for x, y in uvs]
    x0 = 2 * u
    y0 = 2 * v
    square = ((x0, y0), (x0 + 2, y0),
              (x0 + 2, y0 + 2), (x0, y0 + 2))

    if any(x0 <= x <= x0 + 2 and y0 <= y <= y0 + 2
           for x, y in triangle):
        return True
    if any(_point_in_triangle(point, triangle) for point in square):
        return True
    return any(_segments_intersect(triangle[i], triangle[(i + 1) % 3],
                                   square[j], square[(j + 1) % 4])
               for i in range(3) for j in range(4))


def conservative_affine_texels(uvs, dilation=FOOTPRINT_DILATION):
    """Return a conservative set of wrapped (u, v) texels for one triangle."""
    us = [u for u, _v in uvs]
    vs = [v for _u, v in uvs]
    footprint = set()
    # The -1 lower bound is needed because the closed cell immediately below
    # an integer vertex touches it.  It is conservative at a floor boundary.
    for v in range(min(vs) - 1, max(vs) + 1):
        for u in range(min(us) - 1, max(us) + 1):
            if _cell_intersects_triangle(u, v, uvs):
                footprint.add((u & 0xFF, v & 0xFF))

    for _unused in range(dilation):
        footprint = {((u + du) & 0xFF, (v + dv) & 0xFF)
                     for u, v in footprint
                     for du in (-1, 0, 1) for dv in (-1, 0, 1)}
    return footprint


def scan_texture_pages(texture_dir):
    pages = {}
    for page in TEXTURE_PAGE_IDS:
        path = os.path.join(texture_dir, "trex_texture_page_%d.tim" % page)
        try:
            with open(path, "rb") as handle:
                data = handle.read()
        except OSError as exc:
            raise QualificationError("cannot read %s: %s" % (path, exc))
        if len(data) < TIM_SIZE:
            raise QualificationError("%s is %d bytes, expected at least %d"
                                     % (path, len(data), TIM_SIZE))
        clut = struct.unpack_from("<%dH" % TIM_CLUT_ENTRIES,
                                  data, TIM_CLUT_DATA_OFFSET)
        pixels = data[TIM_PIXEL_DATA_OFFSET:TIM_SIZE]
        used = frozenset(pixels)
        invalid = frozenset(index for index in used if clut[index] == 0)
        pages[page] = {
            "pixels": pixels,
            "invalid_indices": invalid,
            "opaque": not invalid,
            "used_indices": len(used),
            "invalid_texels": sum(1 for index in pixels if index in invalid),
        }
    return pages


def read_o3d_polygons(path):
    try:
        with open(path, "rb") as handle:
            data = handle.read()
    except OSError as exc:
        raise QualificationError("cannot read %s: %s" % (path, exc))
    if len(data) < O3D_HEADER_BYTES:
        raise QualificationError("%s is shorter than the O3D header" % path)
    # Point/normal counts come from the O3D's own header (big-endian u16 at
    # offset 0/2), the same way every JS tool in this pipeline reads them
    # (see o3d2facenormals.js), rather than from constants that silently go
    # stale if the mesh's vertex or normal count ever changes.
    point_count, normal_count = struct.unpack_from(">HH", data, 0)
    offset = (O3D_HEADER_BYTES + point_count * O3D_POINT_BYTES
              + normal_count * O3D_NORMAL_BYTES)
    stride = O3D_POLYGON_WORDS * 2
    if len(data) < offset or (len(data) - offset) % stride:
        raise QualificationError("%s has a malformed polygon block" % path)
    return [struct.unpack_from(">%dH" % O3D_POLYGON_WORDS,
                               data, offset + index * stride)
            for index in range((len(data) - offset) // stride)]


def qualify_o3d(o3d_path, texture_dir, dilation=FOOTPRINT_DILATION):
    pages = scan_texture_pages(texture_dir)
    polygons = read_o3d_polygons(o3d_path)
    sidecar = bytearray(len(polygons))
    tally = {page: [0, 0] for page in TEXTURE_PAGE_IDS}
    untextured = 0

    for index, word in enumerate(polygons):
        if word[15] == 0:
            untextured += 1
            continue
        page = resolve_tpage(word[15])
        tally[page][0] += 1
        info = pages[page]
        qualifies = info["opaque"]
        if not qualifies:
            uvs = ((word[8] & 0xFF, word[9] & 0xFF),
                   (word[10] & 0xFF, word[11] & 0xFF),
                   (word[12] & 0xFF, word[13] & 0xFF))
            qualifies = not any(
                info["pixels"][v * 256 + u] in info["invalid_indices"]
                for u, v in conservative_affine_texels(uvs, dilation))
        if qualifies:
            sidecar[index] = 1
            tally[page][1] += 1
    return sidecar, tally, untextured, pages


def write_sidecar(path, payload):
    # Normal generation runs through make; keep the write atomic so an
    # interrupted qualification cannot leave a plausible truncated table.
    temporary = path + ".tmp"
    with open(temporary, "wb") as handle:
        handle.write(payload)
    os.replace(temporary, path)


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("o3d")
    parser.add_argument("texture_dir")
    parser.add_argument("output")
    parser.add_argument("--dilation", type=int, default=FOOTPRINT_DILATION)
    args = parser.parse_args(argv)
    if args.dilation < 0:
        parser.error("--dilation must be non-negative")
    try:
        sidecar, tally, untextured, pages = qualify_o3d(
            args.o3d, args.texture_dir, args.dilation)
        write_sidecar(args.output, sidecar)
    except (OSError, QualificationError) as exc:
        print("opaque qualification failed: %s" % exc, file=sys.stderr)
        return 1

    print("%s: %d/%d textured triangles qualified; %d untextured stay on the flat path"
          % (args.output, sum(sidecar), len(sidecar) - untextured, untextured))
    for page in TEXTURE_PAGE_IDS:
        count, qualified = tally[page]
        info = pages[page]
        print("  page %2d: %4d/%4d triangles, %5d invalid texels, %3d used indices"
              % (page, qualified, count, info["invalid_texels"],
                 info["used_indices"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
