#!/usr/bin/env python3
"""Seed the Blender source scene from the procedural trail generators.

The Blender scene in TREX/scene is the source of the 640x400 backdrop
build. This script only (re)creates it from the older procedural tools, so
run it once, or to start over (`make blender_seed`). Inputs are the outputs
of make_backdrop.py and make_backdrop_path.py in <seed dir>, plus the light
set and shade ramp of make_backdrop_light.py:

  * mesh      1,376 TMD vertices, 2,724 triangles, UVs, texture pages,
              untextured base colours, static Q12 corner normals
  * textures  the six 8-bit TIM pages; palette word 0 is transparent
  * poses     each sample's composed pose (neutral gait plus the four run
              lists mixed with the weights the 68030 used to compute at run
              time, same integer arithmetic) as a PC2 point cache
  * targets   PS1 TANM morph targets 5-8 as optional shape keys (weight 0)
  * route     per-sample object transform, the fixed lens and the loop start
  * shadow    ground ellipse centre, heading and axes per sample
  * lighting  camera-fixed light vectors, ambient and 4x16 shade ramp
  * backdrop  the RGB565 picture decoded to PNG

Usage: blender_seed_data.py <seed dir> <output dir>
Then:  blender -b --factory-startup --python tools/blender_build_scene.py -- <output dir> <scene dir>
"""
import json
import math
import struct
import sys
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from make_backdrop_light import tables  # noqa: E402
from make_backdrop_path import CAMERA_HEIGHT, PITCH  # noqa: E402

TMD = ROOT / "TREX/model/trex.tmd"
TANM = ROOT / "TREX/model/trex_animation.bin"
PAGES = (10, 12, 14, 26, 28, 30)
VERTICES = 1376
RECORD = 54                      # route record of make_backdrop_path.py
UNITS_PER_METRE = 2150           # OPTIMIZATION.md 6.6e
SCALE = 1 / UNITS_PER_METRE
GROUND_Y = CAMERA_HEIGHT + 6950  # level-camera depth of the standing sole
W, H = 640, 400
# Contact shadow of make_backdrop_path.shadow_rows: ellipse half-axes across
# and along the heading, centre offset from the hips, three nested rings.
SHADOW_AXES = (3150, 7700)
SHADOW_OFFSET = (700, 450)
SHADOW_RINGS = (1.0, 0.77, 0.51)
HIP_REACH = 6144
# Sparse PS1 targets usable as DSP morph targets (trex_animation.json).
TANM_TARGETS = {5: (0, 147, 34528), 6: (0, 557, 35412), 7: (78, 12, 38756), 8: (0, 557, 38828)}


# --------------------------------------------------------------------- mesh
def read_tmd(path=TMD):
    data = Path(path).read_bytes()
    table = 12
    vert_top, vert_n, norm_top, norm_n, prim_top, prim_n, _ = struct.unpack_from("<7I", data, table)
    vertices = np.frombuffer(data, "<i2", vert_n * 4, table + vert_top).reshape(-1, 4)[:, :3]
    normals = np.frombuffer(data, "<i2", norm_n * 4, table + norm_top).reshape(-1, 4)[:, :3]
    triangles = []
    cursor = table + prim_top
    for _ in range(prim_n):
        ilen, mode = data[cursor + 1], data[cursor + 3]
        body = cursor + 4
        if mode == 0x34:
            u0, v0, cba, u1, v1, tsb, u2, v2 = struct.unpack_from("<BBHBBHBB", data, body)
            pairs = struct.unpack_from("<6H", data, body + 12)
            page = tsb & 0x1F
            assert PAGES[(cba >> 6) - 480] == page, "CLUT and texture page disagree"
            triangles.append(dict(page=page, uv=[(u0, v0), (u1, v1), (u2, v2)],
                                  normals=pairs[0::2], vertices=pairs[1::2]))
        elif mode == 0x30:
            r, g, b = data[body], data[body + 1], data[body + 2]
            pairs = struct.unpack_from("<6H", data, body + 4)
            triangles.append(dict(page=None, colour=(r, g, b),
                                  normals=pairs[0::2], vertices=pairs[1::2]))
        else:
            raise ValueError("unexpected TMD mode %#x" % mode)
        cursor += 4 + ilen * 4
    assert cursor == table + vert_top
    return vertices.astype(np.int32), normals.astype(np.float64) / 4096, triangles


def write_textures(out):
    for page in PAGES:
        data = (ROOT / f"TREX/textures/trex_texture_page_{page}.tim").read_bytes()
        clut = np.frombuffer(data, "<u2", 256, 20)
        index = np.frombuffer(data, np.uint8, 65536, 544).reshape(256, 256)
        r5, g5, b5 = clut & 31, (clut >> 5) & 31, (clut >> 10) & 31
        rgba = np.stack([(r5 * 255 + 15) // 31, (g5 * 255 + 15) // 31,
                         (b5 * 255 + 15) // 31, np.where(clut == 0, 0, 255)], axis=1)
        Image.fromarray(rgba[index].astype(np.uint8), "RGBA").save(out / f"page_{page}.png")


def q23(value):
    return round(value * (1 << 23)) / (1 << 23)


# ----------------------------------------------------- composed trail poses
def s16(value):
    value &= 0xFFFF
    return value - 0x10000 if value & 0x8000 else value


def limit(value):
    return max(-4096, min(4096, value))


def crossfade(new, old, phase):
    """trail_crossfade: word subtract, signed multiply, arithmetic shift."""
    return s16(((s16(new - old) * phase) >> 2) + old)


def trail_weights(path, frame, count, lap):
    """The four Q12 weights trail_mix_pose computed for one displayed sample."""
    yaw = lambda sample: struct.unpack_from(">H", path, 16 + sample * RECORD + 52)[0]

    def heading_change(back):
        ref = frame - back
        if lap > frame:
            ref = max(ref, 0)
        elif ref < lap:
            ref += count - lap
        return s16(yaw(frame) - yaw(ref))

    trunk = limit(heading_change(1) * 3)
    tail = limit(heading_change(3))
    cos_q12 = struct.unpack_from(">i", path, 16 + frame * RECORD)[0] >> 11
    gaze = (limit(1000 - cos_q12) * trunk) >> 12
    phase = frame - 12
    if 0 <= phase and 57 - phase >= 0:
        phase = min(phase, 57 - phase, 4)
        look = crossfade((s16(yaw(frame + 2) - yaw(frame))) >> 1, gaze, phase)
        trunk = crossfade(limit((s16(yaw(frame) - yaw(frame - 2)) * 3) >> 1), trunk, phase)
        tail = crossfade(limit(s16(yaw(frame - 2) - yaw(frame - 5))), tail, phase)
        gaze = look
    gaze = s16(gaze)
    return [gaze if gaze >= 0 else 0, -gaze if gaze < 0 else 0, trunk, tail]


def mixed_pose(poses, offset, weights):
    """Copy the neutral XYZ16 gait, then add each weighted run list."""
    words = VERTICES * 3
    pose = np.frombuffer(poses, ">i2", words, offset).astype(np.int32)
    cursor = offset + words * 2
    for weight in weights:
        while True:
            first, length = struct.unpack_from(">HH", poses, cursor)
            cursor += 4
            if length == 0:
                break
            delta = np.frombuffer(poses, ">i2", length, cursor).astype(np.int32)
            cursor += length * 2
            if weight:
                part = delta if weight == 4096 else (delta * weight) >> 12
                pose[first // 2:first // 2 + length] += part
    return ((pose + 0x8000) & 0xFFFF) - 0x8000


# ---------------------------------------------------------------------- seed
def main(seed, out):
    seed, out = Path(seed), Path(out)
    out.mkdir(parents=True, exist_ok=True)
    base, normals, triangles = read_tmd()
    write_textures(out)
    rows, ambient, ramp = tables()

    path = (seed / "backdrop_path.bin").read_bytes()
    poses = (seed / "backdrop_poses.bin").read_bytes()
    lap, focal_x, focal_y, centre_y = struct.unpack_from(">4I", path, 0)
    count = (len(path) - 16) // RECORD

    # PS1 axes (+X right, +Y down, +Z away) to Blender (+X right, +Y away, +Z
    # up); the level camera frame from the pitched one; Blender camera axes.
    to_blender = np.array([[1, 0, 0], [0, 0, 1], [0, -1, 0]], float)
    cp, sp = math.cos(PITCH), math.sin(PITCH)
    pitch = np.array([[1, 0, 0], [0, cp, -sp], [0, sp, cp]])   # level -> camera
    camera_axes = np.diag([1.0, -1.0, -1.0])                   # PS1 camera -> Blender camera
    lift = np.array([0, 0, GROUND_Y * SCALE])                  # ground at Blender Z = 0
    level = to_blender @ pitch.T
    # Every route matrix has determinant -1: the demo draws the model mirrored
    # along its own Z. The mirror lives in the mesh (Blender local -Y), so each
    # object transform is a proper rotation and the TMD corner order is
    # counter-clockwise from outside, as Blender expects.
    mirror = np.diag([1.0, -1.0, 1.0])
    local = mirror @ to_blender

    frames, positions = [], []
    for sample in range(count):
        record = 16 + sample * RECORD
        values = struct.unpack_from(">12iIH", path, record)
        matrix = np.array(values[:9], float).reshape(3, 3) / ((1 << 23) - 1)
        translation = np.array(values[9:12], float)
        weights = trail_weights(path, sample, count, lap)
        vertices = base + mixed_pose(poses, values[12], weights).reshape(-1, 3)
        rotation = level @ matrix @ local.T
        assert np.allclose(rotation @ rotation.T, np.eye(3), atol=1e-5)
        assert np.linalg.det(rotation) > 0
        positions.append(vertices @ local.T * SCALE)
        # Contact shadow: the level-frame heading is row 0 of the route matrix
        # (cos, 0, -sin); the ellipse sits ahead of the hips on the ground.
        level_matrix = pitch.T @ matrix
        cos_h, sin_h = level_matrix[0, 0], -level_matrix[0, 2]
        level_t = pitch.T @ translation
        centre = (level_t[0] + HIP_REACH * sin_h + SHADOW_OFFSET[0],
                  level_t[2] + HIP_REACH * cos_h + SHADOW_OFFSET[1])
        frames.append(dict(sample=sample, weights=weights,
                           rotation=rotation.tolist(),
                           location=(level @ translation * SCALE + lift).tolist(),
                           shadow=dict(location=[centre[0] * SCALE, centre[1] * SCALE, 0.0],
                                       heading=-math.atan2(sin_h, cos_h))))

    positions = np.asarray(positions, "<f4")
    with open(out / "trex_trail.pc2", "wb") as cache:
        cache.write(struct.pack("<12siiffi", b"POINTCACHE2\0", 1, VERTICES, 1.0, 1.0, count))
        cache.write(positions.tobytes())

    words = np.fromfile(seed / "backdrop_640x400.bin", ">u2").reshape(H, W).astype(np.uint32)
    r5, g6, b5 = words >> 11, (words >> 5) & 63, words & 31
    picture = np.dstack([(r5 * 255 + 15) // 31, (g6 * 255 + 31) // 63, (b5 * 255 + 15) // 31])
    Image.fromarray(picture.astype(np.uint8), "RGB").save(out / "backdrop.png")
    # Ramp entries n/64 stored as 4n/255: a raw read times 255/4 is n again.
    Image.fromarray((np.asarray(ramp) * 4).astype(np.uint8), "RGB").save(out / "shade_ramp.png")

    anim = TANM.read_bytes()
    targets = []
    for index, (first, length, offset) in TANM_TARGETS.items():
        delta = np.frombuffer(anim, ">i2", length * 3, offset).reshape(-1, 3).astype(float)
        targets.append(dict(name="PS1 target %d" % index, first=first,
                            deltas=(delta @ local.T * SCALE).tolist()))

    scene = dict(
        units_per_metre=UNITS_PER_METRE,
        resolution=[W, H], focal=[focal_x, focal_y], centre=[W // 2, centre_y],
        lap_start=lap, sample_count=count,
        camera=dict(rotation=(to_blender @ pitch.T @ camera_axes).tolist(), location=lift.tolist()),
        # Camera-fixed light vectors in Blender world axes, rounded to the
        # Q1.23 values the DSP receives.
        lights=dict(red=[(level @ [q23(c) for c in v]).tolist() for _, v in rows["red"]],
                    green=[(level @ [q23(c) for c in v]).tolist() for _, v in rows["green"]],
                    ambient=[q23(a) for a in ambient], thresholds=[1.378, 1.529, 1.649]),
        shadow=dict(axes=[a * SCALE for a in SHADOW_AXES], rings=list(SHADOW_RINGS)),
        mesh=dict(
            vertices=(base @ local.T * SCALE).tolist(),
            triangles=[t["vertices"] for t in triangles],
            corner_normals=[[(local @ normals[n]).tolist() for n in t["normals"]]
                            for t in triangles],
            pages=[t["page"] for t in triangles],
            uvs=[t.get("uv") for t in triangles],
            colours=[t.get("colour") for t in triangles]),
        targets=targets,
        frames=frames)
    (out / "trex_trail.json").write_text(json.dumps(scene), encoding="utf-8")
    print("%s: %d samples, lap from %d, %d triangles" % (out, count, lap, len(triangles)))


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(*sys.argv[1:])
