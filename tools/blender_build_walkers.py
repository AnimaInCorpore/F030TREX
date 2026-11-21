"""Build the AT-AT patrol from the reduced asset and its original rig.

Run: blender -b -Y TREX/scene/trex_trail.blend --python tools/blender_build_walkers.py -- \
         <walker_low.blend> <mesh object> <armature object> <out.blend> [options]

<walker_low.blend> comes from tools/blender_reduce_rigid.py. The trail scene
supplies the Falcon materials, the DSP shade node group, the ground shadow
and the render settings; its T-Rex is removed.

The default patrol tracks one walker over two gait cycles, with two bolts
and one ground shadow. The leg phases come from assets/Positions.txt.
For the earlier low-detail mesh, second=x,y adds a second actor, and
layout=column swaps two walkers over 4.5 cycles for an endless march.

Camera overrides: camera=x,y,z, yaw and pitch in degrees, focal=x,y in
pixels. units sets model units per metre, step sets gait frames per sample,
and samples sets the loop length.

Check the assembled mesh against the DSP budget with make model_export.
"""
import math
import sys
from pathlib import Path

import bpy
import numpy as np
from mathutils import Matrix, Quaternion, Vector
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from make_snow_backdrop import paint  # noqa: E402

args = sys.argv[sys.argv.index("--") + 1:]
LOW, MESH, RIG, OUT = str(Path(args[0]).resolve()), args[1], args[2], Path(args[3]).resolve()
opts = dict(a.split("=", 1) for a in args[4:])
layout = opts.get("layout", "patrol")
if layout not in ("column", "patrol"):
    raise SystemExit("layout must be patrol or column")
tracking = layout == "patrol"
solo = tracking and "second" not in opts
default_camera, default_yaw = ("14,-30,2.15", -59) if solo else (
    ("6.5,-33,2.15", -69) if tracking else ("8,0,0.7", -30))
CAMERA = tuple(float(c) for c in opts.get("camera", default_camera).split(","))
YAW = math.radians(float(opts.get("yaw", default_yaw)))
PITCH = math.radians(float(opts.get("pitch", 6 if tracking else 24)))
FOCAL = tuple(int(c) for c in opts.get("focal", "940,867" if tracking else "400,369").split(","))
UNITS = float(opts.get("units", 800 if tracking else 900))
# second=x,y puts the second walker at that offset from the first (metres,
# -Y is ahead) and lets the camera travel with them: see the docstring.
STEP = int(opts.get("step", 8 if tracking else 10))
SAMPLES = int(opts.get("samples", 400 // STEP if tracking else 90))
START = float(opts.get("start", 13.0))        # world Y of the front walker at sample 0

# The walker's rig (assets/Tutorial.blend) and its foot table (assets/Positions.txt).
CYCLE = 200
SLIDE = 0.02328093                              # metres per cycle frame, stance feet
SWING = 50
LIFT = 0.9
LEGS = {                                        # IK bone: swing start, rear Y, front Y
    "front_leg_ik_r": (0, 1.54499, -1.9472),
    "rear_leg_ik_r": (50, 2.04728, -1.44486),
    "front_leg_ik_l": (100, 1.54499, -1.9472),
    "rear_leg_ik_l": (150, 2.04728, -1.44491),
}
MUZZLES = ("canon_l", "canon_r")
SPACING = SAMPLES * STEP * SLIDE                # the loop's travel = the copies' distance
if tracking:
    if (SAMPLES * STEP) % CYCLE:
        raise SystemExit("blender_build_walkers: a travelling-camera loop must last whole cycles")
    BOLT_LENGTH, BOLT_RADIUS, BOLT_PATH = 3.8, 0.17, (0.0, 2.6, 6.8, 12.0)
    # A deliberate pair from the lead, then one reply further up the valley.
    SHOTS = {"": (SAMPLES * 3 // 10, SAMPLES * 4 // 10), "B.": (SAMPLES * 7 // 10,)}
else:
    if (SAMPLES * STEP) % CYCLE != CYCLE // 2:
        raise SystemExit("blender_build_walkers: the loop must last a whole number of cycles plus a half")
    BOLT_LENGTH, BOLT_RADIUS, BOLT_PATH = 4.5, 0.17, (0.0, 6.5, 13.0, 19.5, 26.0)
    SHOTS = {"": (6, 9, 24, 27), "B.": (62, 65, 78, 81)}   # sample of each shot, bolts alternate
BOLT_SAMPLES = len(BOLT_PATH)                   # metres from the muzzle, per sample of a shot
REACH = BOLT_PATH[-1] + BOLT_LENGTH

scene = bpy.context.scene
scene.name = "AT-AT patrol" if tracking else "AT-AT column"
trex = bpy.data.objects["T-Rex"]
shade = bpy.data.node_groups["Falcon DSP shade"]
gn_group = next(m for m in trex.modifiers if m.type == "NODES").node_group
page_template = bpy.data.materials["TIM page 10"]

# ------------------------------------------------------------------ append
with bpy.data.libraries.load(LOW, link=False) as (src, dst):
    dst.objects = [MESH, RIG]
low, rig = dst.objects
collection = bpy.data.collections.new("Walkers")
scene.collection.children.link(collection)
collection.objects.link(rig)
collection.objects.link(low)
bpy.context.view_layer.update()
for constraint in list(rig.constraints):
    rig.constraints.remove(constraint)

mesh = low.data
world = np.array(low.matrix_world)
coords = np.array([v.co[:] for v in mesh.vertices]) @ world[:3, :3].T + world[:3, 3]
ground = coords[:, 2].min()
coords[:, 2] -= ground
rig_drop = rig.matrix_world.translation.z - ground
group_names = {g.index: g.name for g in low.vertex_groups}
vertex_bone = [group_names[v.groups[0].group] for v in mesh.vertices]
faces = [list(p.vertices) for p in mesh.polygons]
face_uv = [[mesh.uv_layers["PS1 UV"].data[l].uv[:] for l in p.loop_indices] for p in mesh.polygons]
face_slot = [p.material_index for p in mesh.polygons]
page_images = [next(n.image for n in m.node_tree.nodes if n.type == "TEX_IMAGE") for m in mesh.materials]

# ------------------------------------------------------------------ bolt bones
bones = rig.data.bones
# Place the socket on the actual forward end of each reduced source barrel.
# Averaging the tip ring keeps the flash centred on its bore.
muzzles = []
for name in MUZZLES:
    barrel_points = coords[np.array(vertex_bone) == name]
    tip_ring = barrel_points[barrel_points[:, 1] <= barrel_points[:, 1].min() + 0.06]
    muzzle = tip_ring.mean(axis=0)
    muzzle[1] = barrel_points[:, 1].min()
    muzzles.append(muzzle)
bpy.ops.object.select_all(action="DESELECT")
rig.select_set(True)
bpy.context.view_layer.objects.active = rig
bpy.ops.object.mode_set(mode="EDIT")
for index, name in enumerate(MUZZLES):
    bone = rig.data.edit_bones.new("Bolt.%d" % index)
    bone.head = Vector(muzzles[index]) - Vector((0, 0, rig_drop))
    bone.tail = bone.head + Vector((0.0, -1.0, 0.0))
bpy.ops.object.mode_set(mode="OBJECT")

# The second rig: a copy whose bones carry a prefix, so that each Armature
# modifier moves only its own walker's vertex groups.
rig.name = rig.data.name = "Walker rig A"
rigs = {"": rig}
if not solo:
    rig_b = rig.copy()
    rig_b.data = rig.data.copy()
    rig_b.name = rig_b.data.name = "Walker rig B"
    collection.objects.link(rig_b)
    bpy.context.view_layer.update()
    for bone in list(rig_b.data.bones):
        bone.name = "B." + bone.name
    rigs["B."] = rig_b

# ------------------------------------------------------------------ the mesh
# Local Y of the two copies, centred on the span from the furthest bolt to
# the rear walker's tail so that it fits 16-bit model units.
front_extent, rear_extent = coords[:, 1].min(), coords[:, 1].max()
behind = (0.0, 0.0) if tracking else (0.0, SPACING)
if tracking and not solo:
    behind = tuple(map(float, opts["second"].split(",")))
local_a = 0.5 * (REACH - front_extent - max(0.0, behind[1]) - rear_extent)
offsets = {"": Vector((-0.5 * behind[0], local_a, 0.0))}
if not solo:
    offsets["B."] = Vector((0.5 * behind[0], local_a + behind[1], 0.0))
span = max(local_a + max(0.0, behind[1]) + rear_extent,
           0.5 * abs(behind[0]) + np.abs(coords[:, 0]).max() + REACH * 0.3) * UNITS
if span > 32700:
    raise SystemExit("blender_build_walkers: %.0f model units exceed 16 bits; lower units=" % span)

vertices, triangles, uvs, slots, groups = [], [], [], [], []
for prefix, offset in offsets.items():
    base = len(vertices)
    vertices += (coords + np.array(offset)).tolist()
    groups += [prefix + name for name in vertex_bone]
    triangles += [[base + v for v in face] for face in faces]
    uvs += face_uv
    slots += face_slot
bolt_slot = len(page_images)
bolt_faces = set()
ring = [(BOLT_RADIUS, 0.0), (0.0, BOLT_RADIUS), (-BOLT_RADIUS, 0.0), (0.0, -BOLT_RADIUS)]
for prefix, offset in offsets.items():
    for index, muzzle in enumerate(muzzles):
        base = len(vertices)
        origin = muzzle + np.array(offset)
        vertices.append((origin + (0.0, -BOLT_LENGTH, 0.0)).tolist())           # nose
        vertices.append(origin.tolist())                                        # tail
        vertices += [(origin + (x, -0.7 * BOLT_LENGTH, z)).tolist() for x, z in ring]
        groups += [prefix + "Bolt.%d" % index] * 6
        for k in range(4):
            a, b = base + 2 + k, base + 2 + (k + 1) % 4
            for face in ([base, a, b], [base + 1, b, a]):
                bolt_faces.add(len(triangles))
                triangles.append(face)
                uvs.append([(0.5, 0.92), (0.08, 0.08), (0.92, 0.08)])
                slots.append(bolt_slot)

walkers_mesh = bpy.data.meshes.new("Walkers")
walkers_mesh.from_pydata(vertices, [], triangles)
walkers_mesh.update()
layer = walkers_mesh.uv_layers.new(name="PS1 UV")
for poly, corner_uvs, slot in zip(walkers_mesh.polygons, uvs, slots):
    poly.use_smooth = False
    poly.material_index = slot
    for loop, value in zip(poly.loop_indices, corner_uvs):
        layer.data[loop].uv = value
walkers = bpy.data.objects.new("Walkers", walkers_mesh)
for key in ("source_blend", "source_mesh_object", "source_vertices", "source_sha256"):
    if key in low:
        walkers[key] = low[key]
collection.objects.link(walkers)
for name in sorted(set(groups)):
    walkers.vertex_groups.new(name=name).add([i for i, g in enumerate(groups) if g == name], 1.0, "REPLACE")
bpy.data.objects.remove(low)

# ------------------------------------------------------------------ lights and ramp
# Overcast: sky light from above, a fill from the camera's side, and snow
# light from below. Red and green are equal, so every triangle is tint 0.
LIGHTS = [0.56 * Vector((0.25, -0.15, 0.95)).normalized(),
          0.30 * Vector((0.45, -0.90, 0.35)).normalized(),
          0.16 * Vector((0.0, 0.0, -1.0))]
for channel in ("red", "green"):
    for index, vector in enumerate(LIGHTS):
        shade.nodes["%s light %d" % (channel, index)].inputs[1].default_value = vector
    shade.nodes["ambient %s" % channel].inputs[1].default_value = 0.25
ramp = np.zeros((4, 16, 4), np.float32)
for level in range(16):
    shade_level = level / 15
    gain = np.array([0.58, 0.66, 0.78]) + shade_level * np.array([0.71, 0.65, 0.55])
    entry = np.minimum(63, np.rint(gain * 64 / 1.5))
    ramp[:, level, :3] = entry * 4 / 255
ramp[..., 3] = 1.0
ramp_image = shade.nodes["shade ramp"].image
ramp_path = OUT.parent / (OUT.stem + "_ramp.png")
Image.fromarray(np.rint(ramp[..., :3] * 255).astype(np.uint8), "RGB").save(ramp_path)
ramp_image.filepath = str(ramp_path)
ramp_image.reload()

# Flat Q12 corner normals of the rest mesh; the bolts face the lights.
walkers_mesh.update()
normal_attr = walkers_mesh.attributes.new("ps1_normal", "FLOAT_VECTOR", "CORNER")
bright = (LIGHTS[0] + LIGHTS[1]).normalized()
for poly in walkers_mesh.polygons:
    normal = bright if poly.index in bolt_faces else poly.normal
    q = [round(c * 4096) / 4096 for c in normal]
    for loop in poly.loop_indices:
        normal_attr.data[loop].vector = q

# ------------------------------------------------------------------ materials
glow = np.zeros((256, 256, 3), np.uint8)
u = np.linspace(-1.0, 1.0, 256)[None, :]
core = np.exp(-5.0 * u**2)
glow[..., 0] = 255
glow[..., 1] = np.rint(30 + 196 * core)
glow[..., 2] = np.rint(62 + 159 * core)
glow_path = OUT.parent / (OUT.stem + "_bolt_page.png")
Image.fromarray(glow, "RGB").save(glow_path)
glow_image = bpy.data.images.load(str(glow_path))
glow_image.name = "Bolt page"
glow_image.colorspace_settings.name = "Non-Color"
for index, image in enumerate(page_images + [glow_image]):
    material = page_template.copy()
    material.name = "Walker page %d" % index if index < len(page_images) else "Bolt page"
    next(n for n in material.node_tree.nodes if n.type == "TEX_IMAGE").image = image
    walkers_mesh.materials.append(material)

for prefix, armature in rigs.items():
    modifier = walkers.modifiers.new("Armature " + (prefix[:1] or "A"), "ARMATURE")
    modifier.object = armature
walkers.modifiers.new(gn_group.name, "NODES").node_group = gn_group

# ------------------------------------------------------------------ scene, camera, backdrop
scene["falcon_units_per_metre"] = UNITS
scene.frame_start, scene.frame_end = 1, SAMPLES
scene.render.fps = 8 if tracking else 12
for marker in list(scene.timeline_markers):
    scene.timeline_markers.remove(marker)
scene.timeline_markers.new("lap", frame=1)
camera = scene.camera
camera.animation_data_clear()
camera.data.lens = FOCAL[0] / scene.render.resolution_x * camera.data.sensor_width
scene.render.pixel_aspect_x, scene.render.pixel_aspect_y = 1.0, FOCAL[0] / FOCAL[1]
forward = Vector((-math.cos(YAW) * math.cos(PITCH), -math.sin(YAW) * math.cos(PITCH), math.sin(PITCH)))
right = forward.cross(Vector((0, 0, 1))).normalized()
up = right.cross(forward)
camera.matrix_world = Matrix.Translation(CAMERA) @ Matrix((right, up, -forward)).transposed().to_4x4()
horizon = scene.render.resolution_y // 2 + round(FOCAL[1] * math.tan(PITCH))
backdrop_path = OUT.parent / (OUT.stem + "_backdrop.png")
Image.fromarray(paint(horizon, travelling=tracking), "RGB").save(backdrop_path)
backdrop = bpy.data.images["backdrop"]
backdrop.filepath = str(backdrop_path)
backdrop.reload()

# ------------------------------------------------------------------ walk cycle
def foot(phase, start, rear, front):
    """IK bone offset (Y, Z) at a cycle frame: swing forward, then slide back."""
    t = (phase - start) % CYCLE
    if t < SWING:
        s = t / SWING
        # Match stance velocity at lift-off and landing; the foot first
        # unloads behind the hull, then reaches forward before taking weight.
        ease = s * s * (3 - 2 * s)
        y = rear + (front - rear) * ease + SWING * SLIDE * (s - ease)
        return y, LIFT * (math.sin(math.pi * s) ** 2) * (1.22 - 0.44 * s)
    return front + (t - SWING) * SLIDE, 0.0


def turned(bone, rotation):
    """A pose bone's basis rotation for a rotation given in armature axes."""
    rest = bone.bone.matrix_local.to_3x3()
    return (rest.inverted() @ rotation.to_matrix() @ rest).to_quaternion()


def head_yaw(phase, sample, shots):
    scan = 0.16 * math.sin(2 * math.pi * phase / CYCLE + 0.8)
    if not tracking:
        return scan
    # Acquire the target before the first flash, hold through the volley,
    # then ease back into the gait. All envelopes close inside the loop.
    def ease(t):
        t = max(0.0, min(1.0, t))
        return t * t * (3 - 2 * t)
    hold = ease((sample - shots[0] + 7) / 7) * ease((shots[-1] + 8 - sample) / 7)
    return (0.10 + scan) * (1 - hold) - 0.24 * hold


Z, Y, X = Vector((0, 0, 1)), Vector((0, 1, 0)), Vector((1, 0, 0))
hidden_at = Vector((0.0, 0.3, 9.3 - ground))
for prefix, armature in rigs.items():
    armature.parent = walkers
    armature.matrix_parent_inverse = Matrix.Identity(4)
    armature.location = offsets[prefix] + Vector((0.0, 0.0, rig_drop))
    armature.animation_data_clear()
    pose = armature.pose.bones
    lead = 0 if prefix == "" else CYCLE // 2
    for name in ("Main", "Neck.001", "Head", "Bolt.0", "Bolt.1"):
        pose[prefix + name].rotation_mode = "QUATERNION"
    shots = SHOTS[prefix]
    for sample in range(SAMPLES):
        frame = scene.frame_start + sample
        phase = sample * STEP + lead
        angle = 2 * math.pi * phase / CYCLE
        for name, (start, rear, front) in LEGS.items():
            y, z = foot(phase, start, rear, front)
            pose[prefix + name].location = (0.0, y, z)
            pose[prefix + name].keyframe_insert("location", frame=frame)
        # The hull leans towards the standing side and heaves once per step.
        main = pose[prefix + "Main"]
        offset = Vector((0.14 * math.sin(angle + 0.4), 0.04 * math.sin(2 * angle),
                         -0.08 + 0.085 * math.cos(4 * angle - 0.5)))
        main.location = main.bone.matrix_local.to_3x3().inverted() @ offset
        main.rotation_quaternion = turned(main, Quaternion(Y, 0.012 * math.sin(angle + 0.4))
                                          @ Quaternion(X, 0.006 * math.sin(4 * angle)))
        main.keyframe_insert("location", frame=frame)
        main.keyframe_insert("rotation_quaternion", frame=frame)
        yaw = head_yaw(phase, sample, shots)
        kick = sum((0.0, -0.065, -0.028, -0.008)[sample - shot]
                   for shot in shots if 0 <= sample - shot < 4)
        nod = 0.12 + 0.025 * math.sin(2 * angle - 0.6) + kick
        for name, part in (("Neck.001", 0.4), ("Head", 0.6)):
            pose[prefix + name].rotation_quaternion = turned(
                pose[prefix + name], Quaternion(Z, part * yaw) @ Quaternion(X, part * nod))
            pose[prefix + name].keyframe_insert("rotation_quaternion", frame=frame)

    # Sample the animated barrel once at ignition. A travelling bolt keeps
    # that launch transform even as the hull settles and the head recoils.
    flights = {0: [], 1: []}
    for number, first in enumerate(shots):
        index = number % 2
        scene.frame_set(scene.frame_start + first)
        barrel = pose[prefix + MUZZLES[index]]
        axis = (barrel.tail - barrel.head).normalized()
        aim = Vector((0, -1, 0)).rotation_difference(axis)
        socket = pose[prefix + "Bolt.%d" % index].bone.head_local
        origin = barrel.matrix @ barrel.bone.matrix_local.inverted() @ socket
        flights[index].append((first, origin, aim))
    for sample in range(SAMPLES):
        frame = scene.frame_start + sample
        for index in (0, 1):
            bolt = pose[prefix + "Bolt.%d" % index]
            rest = bolt.bone.matrix_local
            muzzle = rest.translation
            flight = next(((sample - first, origin, aim) for first, origin, aim in flights[index]
                           if 0 <= sample - first < BOLT_SAMPLES), None)
            if flight is None:
                deform = Matrix.Translation(hidden_at) @ Matrix.Scale(0.01, 4) @ Matrix.Translation(-muzzle)
            else:
                age, origin, aim = flight
                travel = aim @ Vector((0.0, -BOLT_PATH[age], 0.0))
                if not tracking:
                    # The walker advances under the bolt: keep the bolt's own speed over the ground.
                    travel.y += age * STEP * SLIDE
                deform = (Matrix.Translation(origin + travel) @ aim.to_matrix().to_4x4()
                          @ Matrix.Translation(-muzzle))
            bolt.matrix = deform @ rest
            for path in ("location", "rotation_quaternion", "scale"):
                bolt.keyframe_insert(path, frame=frame)

if tracking:
    # The camera travels with the walkers, so in its frame the model stands
    # still, with the first walker over the world origin.
    walkers.location = -offsets[""]
else:
    # The model: straight along -Y at the stance speed.
    for sample in (0, SAMPLES - 1):
        walkers.location = (0.0, START - local_a - sample * STEP * SLIDE, 0.0)
        walkers.keyframe_insert("location", frame=scene.frame_start + sample)


def all_curves(owner):
    curves = []
    data = owner.animation_data
    if data and data.action:
        for layer in data.action.layers:
            for strip in layer.strips:
                for bag in strip.channelbags:
                    curves += list(bag.fcurves)
    return curves


for owner in (walkers, *rigs.values()):
    for curve in all_curves(owner):
        for point in curve.keyframe_points:
            point.interpolation = "LINEAR"
        curve.extrapolation = "LINEAR"

# ------------------------------------------------------------------ ground shadows
shadow = bpy.data.objects["Ground shadow"]
shadow.animation_data_clear()
shadows = [shadow]
if not solo:
    shadows.append(shadow.copy())
    scene.collection.objects.link(shadows[1])
body = coords[np.array([name == "Main" for name in vertex_bone])]
centre = 0.5 * (coords[:, 1].min() * 0.35 + body[:, 1].min() * 0.65 + body[:, 1].max())
for item, prefix in zip(shadows, offsets):
    item.parent = walkers
    item.matrix_parent_inverse = Matrix.Identity(4)
    item.location = offsets[prefix] + Vector((0.0, centre, 0.0))
    item.rotation_euler = (0.0, 0.0, 0.0)
    item.scale = (2.9, 6.3, 1.0)

bpy.data.objects.remove(trex)
for block in (bpy.data.meshes, bpy.data.materials, bpy.data.images, bpy.data.actions):
    for item in list(block):
        if item.users == 0:
            block.remove(item)

# ------------------------------------------------------------------ report
scene.frame_set(scene.frame_start)
view = np.array(camera.matrix_world.inverted())
width, height = scene.render.resolution_x, scene.render.resolution_y
members = {prefix: np.array([g.startswith("B.") == (prefix == "B.") and "Bolt" not in g for g in groups])
           for prefix in offsets}
nearest, shown = 1e9, {prefix: "" for prefix in offsets}
for sample in range(SAMPLES):
    scene.frame_set(scene.frame_start + sample)
    evaluated = walkers.evaluated_get(bpy.context.evaluated_depsgraph_get())
    shaped = evaluated.to_mesh()
    points = np.array([v.co[:] for v in shaped.vertices])
    evaluated.to_mesh_clear()
    points = points @ np.array(walkers.matrix_world)[:3, :3].T + np.array(walkers.matrix_world)[:3, 3]
    cam = points @ view[:3, :3].T + view[:3, 3]
    depth = -cam[:, 2]
    nearest = min(nearest, depth.min())
    for prefix, member in members.items():
        z = np.maximum(depth[member], 1e-3)
        x = width / 2 + FOCAL[0] * cam[member, 0] / z
        y = height / 2 - FOCAL[1] * cam[member, 1] / z
        inside = (depth[member] > 0.1) & (x >= 0) & (x < width) & (y >= 0) & (y < height)
        shown[prefix] += "%d" % min(9, int(10 * inside.mean()))
        if sample in (0, SAMPLES // 2, SAMPLES - 1):
            print("sample %2d walker %s: x %6.0f..%6.0f  y %6.0f..%6.0f  depth %.1f..%.1f m" % (
                sample, prefix[:1] or "A", x.min(), x.max(), y.min(), y.max(),
                depth[member].min(), depth[member].max()))
for prefix, line in shown.items():
    print("in frame, tenths of walker %s per sample: %s" % (prefix[:1] or "A", line))
print("nearest vertex %.2f m, %d vertices, %d triangles, span %.0f units, horizon row %d" % (
    nearest, len(vertices), len(triangles), span, horizon))
scene.frame_set(scene.frame_start)
bpy.ops.object.select_all(action="DESELECT")
walkers.select_set(True)
bpy.context.view_layer.objects.active = walkers
for screen in bpy.data.screens:
    for area in screen.areas:
        if area.type == "VIEW_3D":
            area.spaces.active.region_3d.view_perspective = "CAMERA"
bpy.ops.file.pack_all()
bpy.ops.wm.save_as_mainfile(filepath=str(OUT), compress=True)
print("saved", OUT)
