"""Export the Falcon trail assets from the Blender source scene (OPTIMIZATION.md 6.6g).

Run: blender -b TREX/scene/trex_trail.blend --python tools/blender_export_falcon.py -- <model dir> <backdrop.bin> [object]

<model dir> holds the model's trex.tmd (TREX/model for the PS1 T-Rex, or a
directory written by tools/blender_export_model.py); the trail assets are
written beside it. [object] is the animated mesh, "T-Rex" by default.

The scene is the reference; the 640x400 backdrop build reproduces it. Per
displayed sample n (Blender frame frame_start + n):

  backdrop_path.bin     four longwords (loop start, focal X, focal Y, centre Y),
                        then 52-byte records: nine Q1.23 matrix entries and three
                        translations, model space to the PS1 camera space of the
                        fixed camera, then the byte offset of the sample's pose
  backdrop_poses.bin    unique full-body XYZ16 deltas from the TMD base vertices
  backdrop_targets.bin  DSP morph targets (shape keys named "DSP ..."): target
                        count, sample count, one 32-bit offset per target, then
                        sample-major Q12 weights, then each target's runs
                        (first vertex, vertex count, XYZ16 deltas; count 0 ends)
  backdrop_shadow.bin   the ground-shadow ellipse rows, format of OPTIMIZATION.md 6.6c;
                        one ellipse per object named "Ground shadow[.NNN]"
  backdrop_gestures.inc the "DSP random <group> ..." targets the 68030 triggers at
                        run time: target, peak weight (the key's slider maximum),
                        group and timing
  backdrop_lights.inc   the DSP light vectors and ambient, camera space, Q1.23
  backdrop_ramp.inc     the 4x16 shade ramp, over 64
  <backdrop.bin>        640x400 big-endian RGB565 picture

Deformation that is not a "DSP ..." shape key (the pose cache, an armature,
other shape keys) is baked into the per-sample pose. The pose is chosen so
that base + pose + sum(floor(delta * weight / 4096)) -- the DSP's own
arithmetic -- equals Blender's evaluated mesh rounded to model units, which
the script checks for every vertex of every sample. The mesh, UVs and
corner normals must still be the model directory's TMD: the Falcon reads
those from trex.tmd and the TIM pages, and the script refuses to export
otherwise (re-export the model after changing them).
"""
import math
import struct
import sys
from pathlib import Path

import bpy
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from blender_seed_data import PAGES, read_tmd  # noqa: E402

args = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
MODEL = Path(args[0]) if args else ROOT / "TREX/model"
BACKDROP = Path(args[1]) if len(args) > 1 else ROOT / "TREX/textures/backdrop_640x400.bin"
OBJECT = args[2] if len(args) > 2 else "T-Rex"
DSP_THRESHOLDS = (1.378, 1.529, 1.649)        # trex_dsp.asm tint classes
TO_BLENDER = np.array([[1, 0, 0], [0, 0, 1], [0, -1, 0]], float)
MIRROR = np.diag([1.0, -1.0, 1.0])
LOCAL = MIRROR @ TO_BLENDER                  # PS1 model -> Blender mesh axes
CAMERA_AXES = np.diag([1.0, -1.0, -1.0])     # Blender camera -> PS1 camera axes


def fail(message):
    raise SystemExit("blender_export_falcon: " + message)


def q23_word(value):
    word = round(value * ((1 << 23) - 1))
    if not -(1 << 23) <= word < (1 << 23):
        fail("Q1.23 overflow: %r" % value)
    return word


def q23_light(value):
    return int(round(value * (1 << 23))) & 0xFFFFFF


scene = bpy.context.scene
scale = 1.0 / scene["falcon_units_per_metre"]
render = scene.render
width, height = render.resolution_x, render.resolution_y
first, last = scene.frame_start, scene.frame_end
count = last - first + 1
laps = [m.frame for m in scene.timeline_markers if m.name == "lap"]
if len(laps) != 1 or not first <= laps[0] <= last:
    fail("need exactly one timeline marker named 'lap' inside the frame range")
lap = laps[0] - first
trex, camera = bpy.data.objects[OBJECT], scene.camera
# One ellipse per object named "Ground shadow", "Ground shadow.001", ...
shadows = sorted((o for o in bpy.data.objects if o.name.split(".")[0] == "Ground shadow"),
                 key=lambda o: o.name)
if not 1 <= len(shadows) <= 256:
    fail("need between 1 and 256 objects named 'Ground shadow'")

# ------------------------------------------------------------------ lens
cam = camera.data
if (width, height) != (640, 400) or cam.sensor_fit != "HORIZONTAL" or cam.type != "PERSP":
    fail("the camera must be a horizontal-fit perspective camera at 640x400")
if cam.shift_x or cam.shift_y:
    fail("camera shift is not supported (the DSP centre X is fixed at 320)")
focal_x = cam.lens / cam.sensor_width * width
focal_y = focal_x * render.pixel_aspect_x / render.pixel_aspect_y
if abs(focal_x - round(focal_x)) > 1e-3 or abs(focal_y - round(focal_y)) > 1e-3:
    fail("focal lengths %.4f / %.4f are not whole pixels" % (focal_x, focal_y))
focal_x, focal_y, centre_y = round(focal_x), round(focal_y), height // 2


def camera_basis():
    matrix = np.array(camera.matrix_world)
    return matrix[:3, :3], matrix[:3, 3]


scene.frame_set(first)
cam_rotation, cam_location = camera_basis()
to_camera = CAMERA_AXES @ cam_rotation.T     # world direction -> PS1 camera space


# ------------------------------------------------------------------ mesh check
base, normals, triangles = read_tmd(MODEL / "trex.tmd")
mesh = trex.data
# The rest mesh as blender_export_model.py saw it: basis shape, modifiers on.
saved = (trex.show_only_shape_key, trex.active_shape_key_index)
rigs = [m.object.data for m in trex.modifiers if m.type == "ARMATURE" and m.object]
poses = [rig.pose_position for rig in rigs]
trex.show_only_shape_key, trex.active_shape_key_index = True, 0
for rig in rigs:
    rig.pose_position = "REST"
rest_mesh = bpy.data.meshes.new_from_object(trex.evaluated_get(bpy.context.evaluated_depsgraph_get()))
trex.show_only_shape_key, trex.active_shape_key_index = saved
for rig, pose in zip(rigs, poses):
    rig.pose_position = pose
if len(rest_mesh.vertices) != len(base) or len(rest_mesh.polygons) != len(triangles):
    fail("%s no longer matches %s's vertex and triangle counts" % (OBJECT, MODEL / "trex.tmd"))
rest = np.array([v.co[:] for v in rest_mesh.vertices]) / scale @ LOCAL   # mesh axes -> PS1
if np.abs(rest - base).max() > 0.51:
    fail("the rest mesh differs from the model's TMD vertices; re-export the model")
uv_layer = rest_mesh.uv_layers.active.data if rest_mesh.uv_layers.active else None
if "ps1_normal" in rest_mesh.attributes:
    corner_normals = np.array([d.vector[:] for d in rest_mesh.attributes["ps1_normal"].data]) @ LOCAL
else:
    corner_normals = np.array([n.vector[:] for n in rest_mesh.corner_normals]) @ LOCAL
    corner_normals /= np.linalg.norm(corner_normals, axis=1, keepdims=True)
corner_q12 = np.clip(np.rint(corner_normals * 4096), -4096, 4096)
for poly, triangle in zip(rest_mesh.polygons, triangles):
    if list(poly.vertices) != list(triangle["vertices"]):
        fail("triangle %d changed its vertices" % poly.index)
    for corner, loop in enumerate(poly.loop_indices):
        if triangle["page"] is not None and uv_layer is not None:
            u, v = triangle["uv"][corner]
            pu, pv = uv_layer[loop].uv[0] * 256, (1 - uv_layer[loop].uv[1]) * 256
            if max(abs(min(255, max(0, round(pu))) - u), abs(min(255, max(0, round(pv))) - v)) > 0:
                fail("triangle %d changed its UVs" % poly.index)
        if np.abs(corner_q12[loop] - np.rint(normals[triangle["normals"][corner]] * 4096)).max() > 0:
            fail("triangle %d changed its corner normals" % poly.index)
bpy.data.meshes.remove(rest_mesh)

# DSP targets: shape keys named "DSP ...", static deltas in model units.
keys = mesh.shape_keys.key_blocks if mesh.shape_keys else []
reference = keys[0] if keys else None
targets = []
for key in keys[1:]:
    if not key.name.startswith("DSP "):
        continue
    if len(mesh.vertices) != len(base):
        fail("DSP target %r: a topology modifier changes the vertex order; apply it first" % key.name)
    if key.relative_key != reference:
        fail("DSP target %r must be relative to the basis" % key.name)
    co = np.array([v.co[:] for v in key.data]) - np.array([v.co[:] for v in reference.data])
    delta = np.rint(co / scale @ LOCAL).astype(np.int64)
    if np.abs(delta).max() > 32767:
        fail("DSP target %r exceeds 16-bit deltas" % key.name)
    nonzero = np.flatnonzero(np.any(delta != 0, axis=1))
    runs, start = [], None
    for index in range(len(delta) + 1):
        active = index < len(delta) and np.any(delta[index] != 0)
        if active and start is None:
            start = index
        elif not active and start is not None:
            runs.append((start, index))
            start = None
    targets.append(dict(key=key, delta=delta, runs=runs, vertices=len(nonzero)))


# ------------------------------------------------------------------ samples
records, pose_bank, pose_offsets = bytearray(), bytearray(), {}
weights_table, shadow_index, shadow_rows = [], bytearray(), bytearray()
wire_words = []
rings = [[shadow.active_material.node_tree.nodes["ring %d radius" % i].inputs[1].default_value
          for i in range(3)] for shadow in shadows]


def homography(obj):
    """Shadow-plane (u, v, 1) -> screen homogeneous, through the DSP's projection."""
    matrix = np.array(obj.matrix_world)
    axes = to_camera @ matrix[:3, :3]
    origin = to_camera @ (matrix[:3, 3] - cam_location)
    projection = np.array([[focal_x, 0, width // 2], [0, focal_y, centre_y], [0, 0, 1]], float)
    return projection @ np.column_stack((axes[:, 0], axes[:, 1], origin))


def ellipse_rows(plane, radius):
    """Rows of draw_ground_shadow for one ring: pixel-pair spans at row centres."""
    inverse = np.linalg.inv(plane)
    conic = inverse.T @ np.diag([1.0, 1.0, -radius * radius]) @ inverse
    rows = []
    for y in range(height):
        yc = y + 0.5
        a = conic[0, 0]
        b = conic[0, 1] * yc + conic[0, 2]
        c = conic[1, 1] * yc * yc + 2 * conic[1, 2] * yc + conic[2, 2]
        disc = b * b - a * c
        if a <= 0 or disc <= 0:
            continue
        # Only the part of the conic in front of the camera is ground.
        mid, half = -b / a, math.sqrt(disc) / a
        point = inverse @ np.array([mid, yc, 1.0])
        if point[2] <= 0:
            continue
        left = max(0, 2 * round((mid - half) / 2))
        right = min(width, 2 * round((mid + half) / 2))
        if right > left:
            rows.append((y, left, right))
    return rows


for sample in range(count):
    scene.frame_set(first + sample)
    rotation, location = camera_basis()
    if np.abs(rotation - cam_rotation).max() > 1e-9 or np.abs(location - cam_location).max() > 1e-9:
        fail("the camera moves at frame %d; the backdrop and lights need a fixed camera" % scene.frame_current)

    # Transform: PS1 model -> PS1 camera space (determinant -1, as the demo draws it).
    world = np.array(trex.matrix_world)
    linear = world[:3, :3]
    if np.abs(linear @ linear.T - np.eye(3)).max() > 1e-5:
        fail("the T-Rex transform at frame %d is not a pure rotation" % scene.frame_current)
    matrix = to_camera @ linear @ LOCAL
    translation = to_camera @ (world[:3, 3] - cam_location) / scale
    words = [q23_word(v) for v in matrix.flatten()] + [int(round(t)) for t in translation]

    # Pose: evaluated mesh in model units, less the DSP targets' contribution.
    depsgraph = bpy.context.evaluated_depsgraph_get()
    evaluated = trex.evaluated_get(depsgraph)
    shaped = evaluated.to_mesh()
    model = np.rint(np.array([v.co[:] for v in shaped.vertices]) / scale @ LOCAL).astype(np.int64)
    evaluated.to_mesh_clear()
    if len(model) != len(base):
        fail("the mesh topology changes at frame %d (apply a Decimate or other topology "
             "modifier before animating)" % scene.frame_current)
    weights, frame_words = [], 0
    composed = base.astype(np.int64).copy()
    for target in targets:
        weight = int(round(target["key"].value * 4096))
        if not -32768 <= weight <= 32767:
            fail("DSP target %r weight out of range" % target["key"].name)
        weights.append(weight)
        if weight:
            composed += (target["delta"] * weight) >> 12
            frame_words += sum(4 + 3 * (end - start) for start, end in target["runs"])
    pose = model - composed
    if np.abs(pose).max() > 32767:
        fail("sample %d's pose exceeds 16-bit deltas" % sample)
    blob = pose.astype(">i2").tobytes()
    if blob not in pose_offsets:
        pose_offsets[blob] = len(pose_bank)
        pose_bank += blob
    records += struct.pack(">12iI", *words, pose_offsets[blob])
    weights_table.append(weights)
    wire_words.append(frame_words)
    assert np.array_equal(composed + pose, model)

    # Ground shadows: three rings per ellipse. The index's top byte counts
    # the ellipses after the first; the box covers all of them.
    shadow_index += struct.pack(">I", (len(shadows) - 1) << 24 | (4 * count + len(shadow_rows)))
    ellipses = [[ellipse_rows(homography(shadow), radius) for radius in radii]
                for shadow, radii in zip(shadows, rings)]
    outer = [row for ellipse in ellipses for row in ellipse[0]]
    box = (min(x for _, x, _ in outer), max(x for _, _, x in outer) - 1,
           min(y for y, _, _ in outer), max(y for y, _, _ in outer)) if outer else (0, 0, 1, 0)
    shadow_rows += struct.pack(">4H", *box)
    for ellipse in ellipses:
        for rows in ellipse:
            if rows:
                assert len(rows) == rows[-1][0] - rows[0][0] + 1, "ring rows are not contiguous"
            shadow_rows += struct.pack(">Hh", rows[0][0] if rows else 0, len(rows) - 1)
            for _, left, right in rows:
                shadow_rows += struct.pack(">HH", left * 2, (right - left) // 2 - 1)

# ------------------------------------------------------------------ lights and ramp
group = bpy.data.node_groups["Falcon DSP shade"]
nodes = group.nodes
vectors = {channel: [to_camera @ np.array(nodes["%s light %d" % (channel, i)].inputs[1].default_value)
                     for i in range(3)] for channel in ("red", "green")}
ambient = [nodes["ambient %s" % c].inputs[1].default_value for c in ("red", "green")]
thresholds = [nodes["tint threshold %d" % i].inputs[1].default_value + 1e-6 for i in range(3)]
if np.abs(np.array(thresholds) - DSP_THRESHOLDS).max() > 1e-5:
    fail("the tint thresholds are fixed in the DSP program: %s" % (DSP_THRESHOLDS,))
lights = ["\t; Generated by tools/blender_export_falcon.py from TREX/scene/trex_trail.blend."]
for channel in ("red", "green"):
    for index, vector in enumerate(vectors[channel]):
        lights.append("\tdc.l\t%s\t; %s light %d" % (
            ",".join("$%08x" % q23_light(c) for c in vector), channel, index))
lights.append("\tdc.l\t$%08x,$%08x\t; ambient, red and green" % tuple(q23_light(a) for a in ambient))

ramp_image = nodes["shade ramp"].image
pixels = np.array(ramp_image.pixels[:]).reshape(ramp_image.size[1], ramp_image.size[0], 4)[::-1]
ramp = np.rint(pixels[..., :3] * 255 / 4).astype(int)
if ramp.shape != (4, 16, 3) or ramp.max() > 63:
    fail("the shade ramp must be 16x4 entries of at most 63/64")
ramp_lines = ["\t; Generated by tools/blender_export_falcon.py from TREX/scene/trex_trail.blend."]
for tint in range(4):
    for level in range(16):
        ramp_lines.append("\tdc.w\t%d,%d,%d\t; T%d L%2d" % (*ramp[tint, level], tint, level))

# ------------------------------------------------------------------ backdrop
picture = bpy.data.images["backdrop"]
pixels = np.array(picture.pixels[:]).reshape(picture.size[1], picture.size[0], 4)[::-1, :, :3]
if pixels.shape[:2] != (height, width):
    fail("the backdrop must be 640x400")
r5 = np.rint(pixels[..., 0] * 31).astype(np.uint16)
g6 = np.rint(pixels[..., 1] * 63).astype(np.uint16)
b5 = np.rint(pixels[..., 2] * 31).astype(np.uint16)
picture_words = (r5 << 11) | (g6 << 5) | b5
picture_words[picture_words == 0] = 1        # black stays the cleared screen's

# ------------------------------------------------------------------ write
target_blob = bytearray(struct.pack(">HH", len(targets), count))
offsets_at = len(target_blob)
target_blob += bytes(4 * len(targets))
for weights in weights_table:
    target_blob += struct.pack(">%dh" % len(targets), *weights)
for index, target in enumerate(targets):
    struct.pack_into(">I", target_blob, offsets_at + 4 * index, len(target_blob))
    for start, end in target["runs"]:
        target_blob += struct.pack(">HH", start, end - start)
        target_blob += target["delta"][start:end].astype(">i2").tobytes()
    target_blob += bytes(4)

# Gestures: targets named "DSP random <group> ..." that the 68030 triggers
# itself, on top of the keyed weights. The first word is the group: gestures
# of one group share a channel and never overlap (a head cannot look left and
# right at once), groups run independently (it can glance with its mouth
# open). Timing is per group, in displayed samples: attack, shortest hold,
# hold range mask, release, and extra rest before the group plays again.
GESTURE_TIMING = {"look": (2, 2, 3, 3, 0),   # turn the head, watch, turn back
                  "jaw": (1, 1, 1, 2, 16),   # opens fast, closes slower; half as often
                  "snarl": (2, 2, 3, 2, 0),  # lips drawn back off the teeth
                  "brow": (1, 1, 1, 1, 0)}
gesture_groups = []
gesture_lines = ["; Generated by tools/blender_export_falcon.py from %s" % Path(bpy.data.filepath).name,
                 "; Run-time gestures: DSP target, peak signed Q12 weight, group, attack,",
                 "; shortest hold, hold range mask, release, extra rest (samples). -1 ends",
                 "; the table."]
header = len(gesture_lines)
for index, target in enumerate(targets):
    name = target["key"].name
    if name.startswith("DSP random "):
        group = name[11:].split()[0]
        if group not in gesture_groups:
            gesture_groups.append(group)
        peak = int(round(target["key"].slider_max * 4096))
        if not 0 < peak <= 32767:
            fail("gesture %r: the slider maximum is its peak weight and must be above 0" % name)
        timing = GESTURE_TIMING.get(group, (2, 1, 3, 3, 0))
        gesture_lines.append("\tdc.w\t%d,%d,%d,%d,%d,%d,%d,%d\t; %s" % (
            (index, peak, gesture_groups.index(group)) + timing + (name[11:],)))
gesture_count = len(gesture_lines) - header
gesture_lines.append("\tdc.w\t-1")
gesture_lines.append("GESTURE_GROUPS\t= %d\t; %s" % (len(gesture_groups), ", ".join(gesture_groups) or "none"))

MODEL.mkdir(parents=True, exist_ok=True)
(MODEL / "backdrop_gestures.inc").write_text("\n".join(gesture_lines) + "\n", encoding="utf-8")
(MODEL / "backdrop_path.bin").write_bytes(struct.pack(">4I", lap, focal_x, focal_y, centre_y) + records)
(MODEL / "backdrop_poses.bin").write_bytes(pose_bank)
(MODEL / "backdrop_targets.bin").write_bytes(target_blob)
(MODEL / "backdrop_shadow.bin").write_bytes(shadow_index + shadow_rows)
(MODEL / "backdrop_lights.inc").write_text("\n".join(lights) + "\n", encoding="utf-8")
(MODEL / "backdrop_ramp.inc").write_text("\n".join(ramp_lines) + "\n", encoding="utf-8")
picture_words.astype(">u2").tofile(BACKDROP)

print("exported %d samples (lap from %d), lens %d/%d" % (count, lap, focal_x, focal_y))
print("  poses: %d unique of %d, %d bytes" % (len(pose_offsets), count, len(pose_bank)))
for target in targets:
    used = sum(1 for weights in weights_table if weights[targets.index(target)])
    print("  DSP target %-22s %4d vertices in %d runs, non-zero in %d samples" % (
        target["key"].name[4:], target["vertices"], len(target["runs"]), used))
if any(wire_words):
    print("  DSP target traffic: up to %d host-port words per frame, %.0f on average" % (
        max(wire_words), sum(wire_words) / count))
print("  %d run-time gestures in %d groups" % (gesture_count, len(gesture_groups)))
print("  shadow %d bytes, targets %d bytes" % (len(shadow_index) + len(shadow_rows), len(target_blob)))
