"""Put a rigged model from another .blend into a copy of the trail scene.

Run: blender -b -Y TREX/scene/trex_trail.blend --python tools/blender_swap_model.py -- \
         <source.blend> <armature> <action> <out.blend> [options]

Options (key=value): name=Walker  height=7.0 (metres)  forward=+X (the source's
facing axis)  triangles=2400 (DSP budget target)  exclude=Floor,Scale_Human
colours=Material:r,g,b;Material:r,g,b (8-bit, for materials whose colour
comes from missing textures).
hull=1 (0: keep each part's own surface and per-face material colours instead
of its convex hull; for a low-poly character rather than a truss; parts are
still decimated if over the budget)
swatches=0 (1: paint every face colour as a solid swatch on one 256x256 page
and give the faces textured UVs on it, so they take the DSP span path rather
than the 68030's flat path, OPTIMIZATION.md 6.6h)
feet= (bone-name patterns, e.g. BackFoot*, for the stance speed; each foot is
tracked by the lower end of its bone and counts as planted within 3% of the
height of its lowest point; default: bones starting with "foot", by their
head below 5% of the height)

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
import fnmatch
import math
import os
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
HULL = opts.get("hull", "1") != "0"
SWATCHES = opts.get("swatches", "0") == "1"
FEET = list(filter(None, opts.get("feet", "").split(",")))
# Blender resolves a plain relative path against the open .blend's folder,
# not the working directory; the swatch page is written beside OUT.
SOURCE, OUT = os.path.abspath(SOURCE), os.path.abspath(OUT)
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
# A glTF import hangs the rig under a root empty that may carry the model's
# scale (x300 for Quaternius's exports). Only the rig and its parts are
# kept, so fold any other parent into the rig's own transform first, from the
# parent chain: appended objects do not report a world matrix until the scene
# is evaluated.
def chain_matrix(obj):
    if obj.parent is None:
        return obj.matrix_basis.copy()
    return chain_matrix(obj.parent) @ obj.matrix_parent_inverse @ obj.matrix_basis


if rig.parent is not None and rig.parent not in parts:
    rig_world = chain_matrix(rig)
    rig.parent = None
    rig.matrix_basis = rig_world
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


# Measured from the vertices: an object's dimensions stay those of its old
# local mesh until the scene is evaluated again after the transform above.
def extent(part):
    co = np.array([v.co[:] for v in part.data.vertices])
    return float(np.ptp(co, axis=0).max()) if len(co) else 0.0


parts = [p for p in parts if extent(p) >= MIN_PART and len(p.data.vertices) >= 4]
if HULL:
    for part in parts:
        hull(part)
else:
    # glTF splits vertices along UV and normal seams; weld them, as the DSP
    # counts positions (UVs, colours and normals live per corner, and merged
    # vertices keep their bone weights).
    for part in parts:
        bm = bmesh.new()
        bm.from_mesh(part.data)
        before = len(bm.verts)
        bmesh.ops.remove_doubles(bm, verts=bm.verts[:], dist=1e-4 * source_height)
        print("%s: welded %d -> %d vertices" % (part.name, before, len(bm.verts)))
        bm.to_mesh(part.data)
        bm.free()
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
print("parts %d, %s triangles %d -> %d" % (len(parts), "hull" if HULL else "surface", counts.sum(),
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
# The rig's own transform (a glTF rig can carry x300 for centimetre bones)
# stays under the route; dropping it would shrink every bone motion by it.
rig_rest = rig.matrix_world.copy()
rig.matrix_world = basis @ rig_rest
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

# The Falcon's untextured material, or a swatch page: each distinct face
# colour becomes a solid 16x16 cell of one 256x256 page (at most 256 colours,
# the page's CLUT), and every corner of a face samples the centre of its cell.
walker.data.materials.clear()
if SWATCHES:
    from PIL import Image

    colour_attr = walker.data.attributes["ps1_colour"]
    corner_rgb = [tuple(int(round(c * 255)) for c in item.color[:3]) for item in colour_attr.data]
    palette = sorted(set(corner_rgb))
    if len(palette) > 256:
        raise SystemExit("blender_swap_model: %d colours do not fit a 256-entry page" % len(palette))
    page = np.zeros((256, 256, 3), np.uint8)
    cell = {rgb: k for k, rgb in enumerate(palette)}
    for rgb, k in cell.items():
        page[16 * (k // 16):16 * (k // 16 + 1), 16 * (k % 16):16 * (k % 16 + 1)] = rgb
    page_path = os.path.join(os.path.dirname(OUT), "%s_swatches.png" % NAME.lower())
    Image.fromarray(page).save(page_path)
    uv_layer = walker.data.uv_layers.new(name="Falcon swatches")
    walker.data.uv_layers.active = uv_layer
    uv_layer.active_render = True
    for loop_index, rgb in enumerate(corner_rgb):
        k = cell[rgb]
        # Image rows run top-down, UV v bottom-up.
        uv_layer.data[loop_index].uv = ((k % 16 + 0.5) / 16, 1 - (k // 16 + 0.5) / 16)
    falcon = bpy.data.materials.new(NAME + " (Falcon swatches)")
    falcon.use_nodes = True
    falcon.use_backface_culling = True
    nodes, links = falcon.node_tree.nodes, falcon.node_tree.links
    nodes.clear()
    out_node = nodes.new("ShaderNodeOutputMaterial")
    shade = nodes.new("ShaderNodeGroup")
    shade.node_tree = bpy.data.node_groups["Falcon DSP shade"]
    emission = nodes.new("ShaderNodeEmission")
    tex = nodes.new("ShaderNodeTexImage")
    tex.image, tex.interpolation = bpy.data.images.load(page_path), "Closest"
    tex.image.colorspace_settings.name = "Non-Color"
    uv_node = nodes.new("ShaderNodeUVMap")
    uv_node.uv_map = uv_layer.name
    links.new(uv_node.outputs["UV"], tex.inputs["Vector"])
    links.new(tex.outputs["Color"], shade.inputs["Colour"])
    links.new(shade.outputs["Shaded"], emission.inputs["Color"])
    links.new(emission.outputs[0], out_node.inputs["Surface"])
    walker.data.materials.append(falcon)
    print("swatches: %d colours on %s" % (len(palette), page_path))
else:
    walker.data.materials.append(bpy.data.materials["Untextured (TMD colour)"])
# The world-normal modifier of the T-Rex.
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
# Animated strip time only applies inside the strip's own frame range; past
# its end HOLD_FORWARD freezes the last pose, so a one-cycle strip would walk
# for one cycle and then slide. Repeat it until it spans the whole lap (with
# animated time the repeat does not change the playback, only the range).
strip.repeat = max(1.0, math.ceil((scene.frame_end + 1 - strip.frame_start) / max(cycle, 1.0)) + 1)

# Stance speed: the lowest foot bone's backward travel per action frame.
old = scene.frame_current
speeds = []
if FEET:
    # Named feet, tracked by the lower end of the bone (an ankle head can sit
    # above any fixed threshold); planted within 3% of the height of the
    # foot's lowest point over the cycle.
    feet = [b.name for b in rig.pose.bones if any(fnmatch.fnmatchcase(b.name, p) for p in FEET)]
    if not feet:
        raise SystemExit("blender_swap_model: no bone matches feet=%s" % ",".join(FEET))
    for name in feet:
        track = []
        for f in range(int(cycle_start), int(cycle_end) + 1):
            strip.strip_time = f
            scene.frame_set(scene.frame_current)
            pb = rig.pose.bones[name]
            ends = [rig.matrix_world @ pb.head, rig.matrix_world @ pb.tail]
            track.append(min(ends, key=lambda p: p.z))
        floor = min(p.z for p in track)
        for prev, point in zip(track[:-1], track[1:]):
            if prev.z < floor + 0.03 * HEIGHT and point.z < floor + 0.03 * HEIGHT:
                speeds.append((prev - point).length)
    print("feet %s" % feet)
feet = [] if FEET else [b.name for b in rig.pose.bones if b.name.lower().startswith("foot")]
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
# Blender clears "animated strip time" on a strip that has no time curve yet
# when the scene is evaluated (the stance measurement above does), and then
# refuses the strip_time keys: switch it on again just before keying.
strip.use_animated_time = True
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
    rig.matrix_world = matrix @ basis @ rig_rest
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
if not strip.fcurves:
    raise SystemExit("blender_swap_model: the action's strip time was not keyed; the walk would not play")
# A wrap of the phase must not interpolate backwards through the cycle.
for curve in strip.fcurves:
    for point in curve.keyframe_points:
        point.interpolation = "CONSTANT"

bpy.data.objects.remove(trex)
scene.frame_set(scene.frame_start)
bpy.ops.wm.save_as_mainfile(filepath=OUT, relative_remap=True, compress=True)
print("saved", OUT)
