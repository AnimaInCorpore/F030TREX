"""Put a rigged model from another .blend into a copy of the trail scene.

Run: blender -b -Y TREX/scene/trex_trail.blend --python tools/blender_swap_model.py -- \
         <source.blend> <armature> <action> <out.blend> [options]

Options (key=value): name=Walker  height=7.0 (metres)  forward=+X (the source's
facing axis)  triangles=2400 (DSP budget target)  exclude=Floor,Scale_Human
colours=Material:r,g,b;Material:r,g,b (8-bit, for materials whose colour
comes from missing textures).

The source's meshes skinned to <armature> are appended, joined, scaled to the
given height and turned to face the T-Rex's forward axis (Blender local -Y,
see blender_seed_data.py). A Decimate modifier is applied to meet the
triangle target, before animation, so the topology stays fixed.
Faces keep their material's colour as a "ps1_colour" corner attribute and get
the Falcon untextured material. Flat Q12 corner normals of the rest mesh are
stored as "ps1_normal" for the DSP light model. The model follows the
T-Rex's route (ground-level location and yaw per frame). Its action is
replayed through an NLA strip whose time advances with the distance walked,
divided by the action's own stance-foot speed, to keep foot slip small on
straight stretches. The T-Rex object is removed. Export it afterwards with
make model_export (OPTIMIZATION.md 6.6h).
"""
import math
import sys

import bmesh
import bpy
import numpy as np
from mathutils import Matrix, Vector

args = sys.argv[sys.argv.index("--") + 1:]
SOURCE, ARMATURE, ACTION, OUT = args[:4]
opts = dict(a.split("=", 1) for a in args[4:])
NAME = opts.get("name", "Walker")
HEIGHT = float(opts.get("height", 7.0))
FORWARD = opts.get("forward", "+X")
TRIANGLES = int(opts.get("triangles", 2400))
EXCLUDE = set(filter(None, opts.get("exclude", "").split(",")))
COLOURS = {}
for item in filter(None, opts.get("colours", "").split(";")):
    key, rgb = item.split(":")
    COLOURS[key] = tuple(int(c) for c in rgb.split(","))

scene = bpy.context.scene
trex = bpy.data.objects["T-Rex"]

# ------------------------------------------------------------------ append
with bpy.data.libraries.load(SOURCE, link=False) as (src, dst):
    dst.objects = list(src.objects)
    dst.actions = [ACTION]
rig = next(o for o in dst.objects if o and o.name.startswith(ARMATURE) and o.type == "ARMATURE")
parts = [o for o in dst.objects if o and o.type == "MESH" and o.name not in EXCLUDE
         and any(m.type == "ARMATURE" and m.object == rig for m in o.modifiers)]
collection = bpy.data.collections.new(NAME)
scene.collection.children.link(collection)
collection.objects.link(rig)
for part in parts:
    collection.objects.link(part)
for obj in dst.objects:
    if obj and obj not in parts and obj != rig and obj.users == 0:
        bpy.data.objects.remove(obj)
# Appended objects report their stored local matrix until the scene is
# evaluated; parts parented to the rig need the parent's offset included.
bpy.context.view_layer.update()

# Material colours, as 8-bit RGB per material.
def colour_of(material):
    if material is None:
        return (200, 200, 200)
    if material.name in COLOURS:
        return COLOURS[material.name]
    colour = material.diffuse_color[:3]
    if material.node_tree:
        for node in material.node_tree.nodes:
            if node.type == "BSDF_PRINCIPLED":
                colour = node.inputs["Base Color"].default_value[:3]
    return tuple(int(round(max(0.0, min(1.0, c)) ** (1 / 2.2) * 255)) for c in colour)


print("materials:", {m.name: colour_of(m) for p in parts for m in p.data.materials if m})

# ------------------------------------------------------------------ reduce, join, normalise
# Freeze each part's transform and keep its colour per face.
for part in parts:
    # Parts are often parented to the rig; unparent them (keeping the world
    # transform) so the joined mesh follows the route on its own.
    world = part.matrix_world.copy()
    part.parent = None
    part.data = part.data.copy()
    part.data.transform(world)
    part.matrix_world = Matrix.Identity(4)
    me = part.data
    attr = me.attributes.new("ps1_colour", "FLOAT_COLOR", "CORNER")
    for poly in me.polygons:
        mat = me.materials[poly.material_index] if me.materials else None
        rgb = [c / 255 for c in colour_of(mat)]
        for loop in poly.loop_indices:
            attr.data[loop].color = (*rgb, 1.0)

top = max(max((v.co.z for v in p.data.vertices), default=0.0) for p in parts)
bottom = min(min((v.co.z for v in p.data.vertices), default=0.0) for p in parts)
source_height = top - min(0.0, bottom)


# A PS1-sized budget cannot keep trusses of a hundred struts per part, so each
# part becomes the convex hull of its vertices (the hull reuses them, keeping
# their bone weights), coloured by its largest material, and is decimated on
# its own to its share of the triangle budget by surface area (at least
# MIN_TRIANGLES). Parts smaller than min_part of the height are dropped.
MIN_TRIANGLES = int(opts.get("min_triangles", 12))
MIN_PART = float(opts.get("min_part", 0.02)) * source_height


def hull(part):
    me = part.data
    area = {}
    for poly in me.polygons:
        mat = me.materials[poly.material_index] if me.materials else None
        area[mat] = area.get(mat, 0.0) + poly.area
    colour = [c / 255 for c in colour_of(max(area, key=area.get) if area else None)]
    bm = bmesh.new()
    bm.from_mesh(me)
    result = bmesh.ops.convex_hull(bm, input=bm.verts[:])
    keep = {g for g in result["geom"] if isinstance(g, bmesh.types.BMFace)}
    bmesh.ops.delete(bm, geom=[f for f in bm.faces if f not in keep], context="FACES_ONLY")
    bmesh.ops.delete(bm, geom=[e for e in bm.edges if not e.link_faces], context="EDGES")
    bmesh.ops.delete(bm, geom=[v for v in bm.verts if not v.link_edges], context="VERTS")
    bm.to_mesh(me)
    bm.free()
    attr = me.attributes["ps1_colour"]
    for item in attr.data:
        item.color = (*colour, 1.0)


parts = [p for p in parts if max(p.dimensions) >= MIN_PART and len(p.data.vertices) >= 4]
for part in parts:
    hull(part)
parts = [p for p in parts if len(p.data.polygons) >= 4]
areas = np.array([sum(f.area for f in p.data.polygons) for p in parts])
counts = np.array([sum(len(f.vertices) - 2 for f in p.data.polygons) for p in parts])
share = TRIANGLES
for _ in range(30):
    wanted = np.minimum(counts, np.maximum(MIN_TRIANGLES, np.rint(share * areas / areas.sum())))
    if wanted.sum() <= TRIANGLES:
        break
    share *= TRIANGLES / wanted.sum()
for part, target, current in zip(parts, wanted, counts):
    if target < current:
        mod = part.modifiers.new("decimate", "DECIMATE")
        mod.ratio = float(target) / current
        mod.use_collapse_triangulate = True
        bpy.context.view_layer.objects.active = part
        with bpy.context.temp_override(object=part, active_object=part):
            bpy.ops.object.modifier_move_to_index(modifier=mod.name, index=0)
            bpy.ops.object.modifier_apply(modifier=mod.name)
print("parts %d, hull triangles %d -> %d" % (len(parts), counts.sum(),
                                             sum(len(f.vertices) - 2 for p in parts for f in p.data.polygons)))

bpy.ops.object.select_all(action="DESELECT")
for part in parts:
    part.select_set(True)
bpy.context.view_layer.objects.active = parts[0]
bpy.ops.object.join()
walker = bpy.context.view_layer.objects.active
walker.name = walker.data.name = NAME
for mod in list(walker.modifiers):
    walker.modifiers.remove(mod)
bm = bmesh.new()
bm.from_mesh(walker.data)
bmesh.ops.triangulate(bm, faces=bm.faces[:])
bm.to_mesh(walker.data)
bm.free()

# Scale to the height and turn the forward axis to local -Y.
scale = HEIGHT / source_height
turn = {"+X": -math.pi / 2, "-X": math.pi / 2, "+Y": math.pi, "-Y": 0.0}[FORWARD]
basis = Matrix.Rotation(turn, 4, "Z") @ Matrix.Diagonal((scale, scale, scale, 1))
walker.data.transform(basis)
rig.matrix_world = basis @ rig.matrix_world
for poly in walker.data.polygons:
    poly.use_smooth = False
print("triangles %d, vertices %d, scale %.4f" % (
    len(walker.data.polygons), len(walker.data.vertices), scale))

# Flat corner normals of the rest mesh, rounded to Q12 as the DSP holds them.
walker.data.update()
normal_attr = walker.data.attributes.new("ps1_normal", "FLOAT_VECTOR", "CORNER")
for poly in walker.data.polygons:
    q = [round(c * 4096) / 4096 for c in poly.normal]
    for loop in poly.loop_indices:
        normal_attr.data[loop].vector = q

# The Falcon's untextured material and the world-normal modifier of the T-Rex.
walker.data.materials.clear()
walker.data.materials.append(bpy.data.materials["Untextured (TMD colour)"])
arm_mod = walker.modifiers.new("Armature", "ARMATURE")
arm_mod.object = rig
gn = next(m for m in trex.modifiers if m.type == "NODES")
walker.modifiers.new(gn.name, "NODES").node_group = gn.node_group

# ------------------------------------------------------------------ route and timing
action = bpy.data.actions[ACTION]
rig.animation_data_create()
rig.animation_data.action = None
track = rig.animation_data.nla_tracks.new()
strip = track.strips.new(ACTION, int(action.frame_range[0]), action)
strip.extrapolation = "HOLD_FORWARD"
strip.use_animated_time = True
cycle_start, cycle_end = action.frame_range
cycle = cycle_end - cycle_start

# Stance speed: the lowest foot bone's backward travel per action frame.
feet = [b.name for b in rig.pose.bones if b.name.lower().startswith("foot")]
old = scene.frame_current
speeds = []
for name in feet:
    prev = None
    for f in range(int(cycle_start), int(cycle_end) + 1):
        strip.strip_time = f
        scene.frame_set(scene.frame_current)
        head = rig.matrix_world @ rig.pose.bones[name].head
        if prev is not None and head.z < 0.05 * HEIGHT and prev.z < 0.05 * HEIGHT:
            speeds.append((prev - head).length)
        prev = head
stance = float(np.median(speeds)) if speeds else 0.05
print("stance speed %.4f m per action frame" % stance)

route_keys = {}
for curve in trex.animation_data.action.layers[0].strips[0].channelbags[0].fcurves:
    route_keys[(curve.data_path, curve.array_index)] = curve
phase = float(cycle_start)
previous = None
for frame in range(scene.frame_start, scene.frame_end + 1):
    x = route_keys[("location", 0)].evaluate(frame)
    y = route_keys[("location", 1)].evaluate(frame)
    yaw = route_keys[("rotation_euler", 2)].evaluate(frame)
    if previous is not None:
        phase += math.hypot(x - previous[0], y - previous[1]) / stance
    previous = (x, y)
    while phase >= cycle_end:
        phase -= cycle
    matrix = Matrix.Translation((x, y, 0.0)) @ Matrix.Rotation(yaw, 4, "Z")
    walker.matrix_world = matrix
    rig.matrix_world = matrix @ basis
    strip.strip_time = phase
    for obj in (walker, rig):
        obj.keyframe_insert("location", frame=frame)
        obj.keyframe_insert("rotation_euler", frame=frame)
    rig.keyframe_insert("scale", frame=frame)
    strip.keyframe_insert("strip_time", frame=frame)

def all_curves(owner):
    data = owner.animation_data
    curves = list(data.drivers)
    if data.action:
        for layer in data.action.layers:
            for st in layer.strips:
                for bag in st.channelbags:
                    curves += list(bag.fcurves)
    return curves


for owner in (walker, rig):
    for curve in all_curves(owner):
        for point in curve.keyframe_points:
            point.interpolation = "LINEAR"
# A wrap of the phase must not interpolate backwards through the cycle.
for curve in strip.fcurves:
    for point in curve.keyframe_points:
        point.interpolation = "CONSTANT"

bpy.data.objects.remove(trex)
scene.frame_set(scene.frame_start)
bpy.ops.wm.save_as_mainfile(filepath=OUT, relative_remap=True, compress=True)
print("saved", OUT)
