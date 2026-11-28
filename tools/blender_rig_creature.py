"""Rig and animate a static four-legged creature mesh for the trail scene.

Run: blender -b -Y TREX/scene/trex_trail.blend --python tools/blender_rig_creature.py -- \
         <model.glb> <out.blend> [options]

Options (key=value): name=Creature  height=4.5 (metres)  triangles=2400
step=0.5 (stride length / leg length)  lift=0.18 (foot lift / leg length)
wave=0.16 (sideways body wave, radians)  stage=all|landmarks

For an unrigged sculpt (a generated mesh, say) with four feet on the ground:
  1. imports it, scales it to the height and decimates it to the triangle
     budget (one connected organic mesh decimates cleanly);
  2. finds the feet (vertex clusters on the ground), the head and tail tips
     (the farthest geodesic pair; the higher end is the head) and a spine
     centreline (the geodesic between them, averaged across the body);
  3. builds a spine chain and a two-bone leg per foot from the hip on the
     spine, and skins the mesh by distance to the bones;
  4. walks it along the T-Rex's route: diagonal leg pairs step in turn
     (forward kinematics: hip sweep, lift and knee flex), the spine waves
     sideways, the tail follows and the head steadies.
The T-Rex object is removed; export the result with make model_export
(OPTIMIZATION.md 6.6h).
"""
import heapq
import math
import os
import sys

import bmesh
import bpy
import numpy as np
from mathutils import Matrix, Vector

args = sys.argv[sys.argv.index("--") + 1:]
SOURCE, OUT = args[:2]
# Blender resolves a plain relative path against the open .blend's folder
# (TREX/scene), not the working directory, so make both paths absolute.
SOURCE, OUT = os.path.abspath(SOURCE), os.path.abspath(OUT)
opts = dict(a.split("=", 1) for a in args[2:])
NAME = opts.get("name", "Creature")
HEIGHT = float(opts.get("height", 4.5))
TRIANGLES = int(opts.get("triangles", 2400))
STEP = float(opts.get("step", 0.6))
LIFT = float(opts.get("lift", 0.18))
WAVE = float(opts.get("wave", 0.16))
STAGE = opts.get("stage", "all")

scene = bpy.context.scene
before = set(bpy.data.objects)
bpy.ops.import_scene.gltf(filepath=SOURCE)
imported = [o for o in bpy.data.objects if o not in before]
meshes = [o for o in imported if o.type == "MESH"]
if len(meshes) != 1:
    raise SystemExit("blender_rig_creature: expected one mesh, found %d" % len(meshes))
body = meshes[0]
world = body.matrix_world.copy()
body.parent = None
body.data.transform(world)
body.matrix_world = Matrix.Identity(4)
for obj in imported:
    if obj is not body:
        bpy.data.objects.remove(obj)
body.name = body.data.name = NAME

# ------------------------------------------------------------------ scale and decimate
co = np.array([v.co[:] for v in body.data.vertices])
scale = HEIGHT / (co[:, 2].max() - co[:, 2].min())
body.data.transform(Matrix.Translation((0, 0, -co[:, 2].min() * scale)) @ Matrix.Diagonal((scale,) * 3 + (1,)))
# glTF splits vertices along UV seams; weld them (UVs live per corner) so the
# mesh is connected for decimation and for the geodesic landmarks.
bm = bmesh.new()
bm.from_mesh(body.data)
welded = len(bm.verts)
bmesh.ops.remove_doubles(bm, verts=bm.verts[:], dist=1e-4 * HEIGHT)
welded -= len(bm.verts)
bm.to_mesh(body.data)
bm.free()
print("welded %d seam vertices" % welded)
count = len(body.data.polygons)
if count > TRIANGLES:
    mod = body.modifiers.new("decimate", "DECIMATE")
    mod.ratio = TRIANGLES / count
    mod.use_collapse_triangulate = True
    with bpy.context.temp_override(object=body, active_object=body):
        bpy.ops.object.modifier_apply(modifier=mod.name)
bm = bmesh.new()
bm.from_mesh(body.data)
bmesh.ops.triangulate(bm, faces=bm.faces[:])
bm.to_mesh(body.data)
bm.free()
for poly in body.data.polygons:
    poly.use_smooth = True
co = np.array([v.co[:] for v in body.data.vertices])
print("mesh: %d -> %d triangles, %d vertices, scale %.3f" % (count, len(body.data.polygons), len(co), scale))

# ------------------------------------------------------------------ landmarks
edges = np.array([e.vertices[:] for e in body.data.edges])
neighbours = [[] for _ in co]
for a, b in edges:
    length = float(np.linalg.norm(co[a] - co[b]))
    neighbours[a].append((b, length))
    neighbours[b].append((a, length))


def geodesic(start):
    dist = np.full(len(co), np.inf)
    prev = np.full(len(co), -1)
    dist[start] = 0.0
    heap = [(0.0, start)]
    while heap:
        d, a = heapq.heappop(heap)
        if d > dist[a]:
            continue
        for b, length in neighbours[a]:
            if d + length < dist[b]:
                dist[b] = d + length
                prev[b] = a
                heapq.heappush(heap, (d + length, b))
    return dist, prev


# Feet: ground-contact clusters (single-link within a tenth of the height).
ground = np.flatnonzero(co[:, 2] < 0.04 * HEIGHT)
clusters = []
for index in ground:
    for cluster in clusters:
        if np.min(np.linalg.norm(co[cluster][:, :2] - co[index, :2], axis=1)) < 0.1 * HEIGHT:
            cluster.append(index)
            break
    else:
        clusters.append([index])
clusters.sort(key=len, reverse=True)
if len(clusters) < 4:
    raise SystemExit("blender_rig_creature: found %d ground contacts, need four feet" % len(clusters))
feet = [co[c].mean(axis=0) for c in clusters[:4]]

# Generated meshes come in loose pieces (teeth, spikes, eyes): search the
# largest connected piece only.
label = np.full(len(co), -1)
sizes = []
for seed in range(len(co)):
    if label[seed] >= 0:
        continue
    stack, label[seed], size = [seed], len(sizes), 0
    while stack:
        a = stack.pop()
        size += 1
        for b, _ in neighbours[a]:
            if label[b] < 0:
                label[b] = len(sizes)
                stack.append(b)
    sizes.append(size)
main = np.flatnonzero(label == int(np.argmax(sizes)))
print("pieces %d, largest %d of %d vertices" % (len(sizes), len(main), len(co)))

# Head and tail: the farthest geodesic pair, starting from the feet's centre.
centre = int(main[np.argmin(np.linalg.norm(co[main] - np.mean(feet, axis=0), axis=1))])
dist, _ = geodesic(centre)
end_a = int(np.argmax(np.where(np.isfinite(dist), dist, -1)))
dist_a, prev_a = geodesic(end_a)
end_b = int(np.argmax(np.where(np.isfinite(dist_a), dist_a, -1)))
head, tail = (end_a, end_b) if co[end_a, 2] > co[end_b, 2] else (end_b, end_a)
path = [tail if head == end_a else head]
while prev_a[path[-1]] >= 0:
    path.append(int(prev_a[path[-1]]))
path = co[path]
if head != end_a:
    path = path[::-1]          # tail -> head
# Centreline: average the body around each surface-path point, then resample.
radius = 0.14 * HEIGHT
centreline = np.array([co[np.linalg.norm(co - p, axis=1) < radius].mean(axis=0) for p in path])
seg = np.r_[0, np.cumsum(np.linalg.norm(np.diff(centreline, axis=0), axis=1))]
SPINE = 14
samples = np.linspace(0, seg[-1], SPINE + 1)
spine = np.array([[np.interp(s, seg, centreline[:, k]) for k in range(3)] for s in samples])
print("feet", [tuple(np.round(f, 2)) for f in feet])
print("tail tip", tuple(np.round(co[tail], 2)), "head tip", tuple(np.round(co[head], 2)),
      "spine length %.2f m" % seg[-1])
print("spine", [tuple(np.round(p, 2)) for p in spine])

if STAGE == "landmarks":
    marker = bpy.data.materials.new("marker")
    marker.diffuse_color = (1, 0, 0, 1)
    for i, p in enumerate(list(spine) + feet):
        bpy.ops.mesh.primitive_uv_sphere_add(radius=0.12, location=tuple(p))
        bpy.context.active_object.data.materials.append(marker)
    bpy.ops.wm.save_as_mainfile(filepath=OUT)
    raise SystemExit(0)


# ------------------------------------------------------------------ orient
# Pelvis and shoulders are the spine points nearest the rear and front feet.
feet = np.array(feet)
along = [int(np.argmin(np.linalg.norm(spine[:, :2] - f[:2], axis=1))) for f in feet]
order = np.argsort(along)
rear, front = feet[order[:2]], feet[order[2:]]
pelvis = int(np.argmin(np.linalg.norm(spine[:, :2] - rear[:, :2].mean(0), axis=1)))
shoulder = int(np.argmin(np.linalg.norm(spine[:, :2] - front[:, :2].mean(0), axis=1)))
if shoulder <= pelvis:
    raise SystemExit("blender_rig_creature: the front feet are not nearer the head than the rear feet")
heading = spine[shoulder, :2] - spine[pelvis, :2]
# Turn the body's forward axis to local -Y (the T-Rex convention of the
# trail scene) and centre the hips on the object origin.
turn = math.atan2(-heading[0], heading[1]) + math.pi
centre = np.array([*((spine[pelvis, :2] + spine[shoulder, :2]) / 2), 0.0])
basis = Matrix.Rotation(-turn, 4, "Z") @ Matrix.Translation(Vector(-centre))
body.data.transform(basis)


def to_local(points):
    return np.array([(basis @ Vector(p))[:] for p in points])


spine, feet, co = to_local(spine), to_local(feet), np.array([v.co[:] for v in body.data.vertices])
front_ids = [i for i in range(4) if along[i] >= np.sort(along)[2]]
print("pelvis %d, shoulder %d, front feet %s" % (pelvis, shoulder, front_ids))

# ------------------------------------------------------------------ texture
# The Falcon draws 256x256 pages in 15-bit colour; show Blender the same.
from PIL import Image  # noqa: E402

material = body.data.materials[0] if body.data.materials else None
image = next((n.image for n in material.node_tree.nodes if n.type == "TEX_IMAGE" and n.image), None) \
    if material and material.node_tree else None
if image is not None:
    w, h = image.size
    pixels = np.array(image.pixels[:], np.float32).reshape(h, w, image.channels)[::-1, :, :3]
    rgb = Image.fromarray(np.clip(np.rint(pixels * 255), 0, 255).astype(np.uint8)).resize((256, 256), Image.LANCZOS)
    five = (np.asarray(rgb).astype(np.int32) * 31 + 127) // 255
    rgb = Image.fromarray(((five * 255 + 15) // 31).astype(np.uint8))
    rgb = rgb.quantize(256, Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE).convert("RGB")
    texture_path = os.path.join(os.path.dirname(OUT), "%s_page.png" % NAME.lower())
    rgb.save(texture_path)
    page_image = bpy.data.images.load(texture_path)
    page_image.colorspace_settings.name = "Non-Color"
uv_name = body.data.uv_layers.active.name if body.data.uv_layers.active else None
uv = np.array([d.uv[:] for d in body.data.uv_layers.active.data]) if uv_name else None
if uv is not None and (uv.min() < -1e-4 or uv.max() > 1 + 1e-4):
    raise SystemExit("blender_rig_creature: UVs outside 0..1 (pages do not tile)")

falcon = bpy.data.materials.new(NAME + " (Falcon page)")
falcon.use_nodes = True
falcon.use_backface_culling = True
nodes, links = falcon.node_tree.nodes, falcon.node_tree.links
nodes.clear()
out_node = nodes.new("ShaderNodeOutputMaterial")
group = nodes.new("ShaderNodeGroup")
group.node_tree = bpy.data.node_groups["Falcon DSP shade"]
emission = nodes.new("ShaderNodeEmission")
links.new(group.outputs["Shaded"], emission.inputs["Color"])
links.new(emission.outputs[0], out_node.inputs["Surface"])
if image is not None and uv_name:
    tex = nodes.new("ShaderNodeTexImage")
    tex.image, tex.interpolation = page_image, "Closest"
    uvnode = nodes.new("ShaderNodeUVMap")
    uvnode.uv_map = uv_name
    links.new(uvnode.outputs["UV"], tex.inputs["Vector"])
    links.new(tex.outputs["Color"], group.inputs["Colour"])
body.data.materials.clear()
body.data.materials.append(falcon)

# Smooth Q12 corner normals of the rest mesh, as the DSP will hold them.
attr = body.data.attributes.new("ps1_normal", "FLOAT_VECTOR", "CORNER")
for loop, normal in zip(attr.data, body.data.corner_normals):
    loop.vector = [round(c * 4096) / 4096 for c in normal.vector]

# ------------------------------------------------------------------ armature
arm_data = bpy.data.armatures.new(NAME + " rig")
rig = bpy.data.objects.new(NAME + " rig", arm_data)
scene.collection.objects.link(rig)
bpy.context.view_layer.objects.active = rig
bpy.ops.object.mode_set(mode="EDIT")
eb = arm_data.edit_bones
root = eb.new("root")
root.head, root.tail = (0, 0, 0), (0, -0.5, 0)
deform = []


def chain(indices, prefix):
    parent, bones = root, []
    for k, (a, b) in enumerate(zip(indices[:-1], indices[1:])):
        bone = eb.new("%s%02d" % (prefix, k))
        bone.head, bone.tail = Vector(spine[a]), Vector(spine[b])
        bone.parent, bone.use_connect = parent, k > 0
        parent = bone
        bones.append(bone.name)
    return bones


torso = chain(list(range(pelvis, len(spine))), "spine")      # pelvis -> head
tail = chain(list(range(pelvis, -1, -1)), "tail")            # pelvis -> tail tip
deform += torso + tail
legs = []
for i, foot in enumerate(feet):
    attach = shoulder if i in front_ids else pelvis
    hip = spine[attach] + 0.45 * np.array([foot[0] - spine[attach][0], foot[1] - spine[attach][1], 0])
    hip[2] = spine[attach][2] * 0.85
    outward = np.array([np.sign(foot[0] - spine[attach][0]) or 1.0, 0.0, 0.0])
    knee = (hip + foot) / 2 + outward * 0.15 * HEIGHT + np.array([0, 0, 0.12 * HEIGHT])
    side = ("L" if foot[0] > 0 else "R") + ("F" if i in front_ids else "B")
    upper, lower = eb.new("leg_%s_upper" % side), eb.new("leg_%s_lower" % side)
    upper.head, upper.tail = Vector(hip), Vector(knee)
    lower.head, lower.tail = Vector(knee), Vector(foot + np.array([0, 0, 0.02]))
    attach_bone = torso[0] if attach == pelvis else torso[min(shoulder - pelvis, len(torso) - 1)]
    upper.parent, lower.parent, lower.use_connect = eb[attach_bone], upper, True
    legs.append(dict(side=side, upper=upper.name, lower=lower.name, rest=foot.copy(), attach=attach_bone,
                     knee=knee.copy(), length=float(np.linalg.norm(knee - hip) + np.linalg.norm(foot - knee))))
    deform += [upper.name, lower.name]
segments = {name: (np.array(eb[name].head[:]), np.array(eb[name].tail[:])) for name in deform}
bpy.ops.object.mode_set(mode="OBJECT")

# Skin by region. A vertex belongs to a leg only when it is clearly nearer
# that leg than the spine and below the hip; it blends along the leg and into
# the spine bone the leg hangs from. Every other vertex blends between the two
# neighbouring bones of the spine or tail chain it lies along. Two nearest
# bones overall would tie belly and flank vertices to legs and tear them.
def segment_projection(points, a, b):
    ab = b - a
    t = np.clip(((points - a) @ ab) / max(ab @ ab, 1e-9), 0, 1)
    return np.linalg.norm(points - (a + t[:, None] * ab), axis=1), t


groups = {n: body.vertex_groups.new(name=n) for n in segments}
chain_bones = torso + tail
chain_d = np.stack([segment_projection(co, *segments[n])[0] for n in chain_bones], axis=1)
best_chain = np.argmin(chain_d, axis=1)
d_spine = chain_d[np.arange(len(co)), best_chain]
leg_d = []
for leg in legs:
    du, tu = segment_projection(co, *segments[leg["upper"]])
    dl, tl = segment_projection(co, *segments[leg["lower"]])
    leg_d.append((np.minimum(du, dl), du, dl, tu))
assigned = np.zeros(len(co), bool)
for leg, (d, du, dl, tu) in zip(legs, leg_d):
    hip_z = segments[leg["upper"]][0][2]
    others = np.min([o[0] for o in leg_d if o is not (d, du, dl, tu)], axis=0) if len(leg_d) > 1 else np.inf
    mine = (d < 0.7 * d_spine) & (co[:, 2] < hip_z + 0.05 * HEIGHT) & (d <= others) & ~assigned
    assigned |= mine
    attach = leg["attach"]
    for v in np.flatnonzero(mine):
        if dl[v] < du[v]:
            groups[leg["lower"]].add([int(v)], 1.0, "REPLACE")
            continue
        # Upper leg: ease into the spine near the hip socket.
        into_body = max(0.0, 1.0 - tu[v] / 0.35)
        groups[leg["upper"]].add([int(v)], 1.0 - 0.5 * into_body, "REPLACE")
        if into_body > 0:
            groups[attach].add([int(v)], 0.5 * into_body, "REPLACE")
for v in np.flatnonzero(~assigned):
    k = best_chain[v]
    name = chain_bones[k]
    chain = torso if name in torso else tail
    i = chain.index(name)
    _, t = segment_projection(co[v:v + 1], *segments[name])
    t = float(t[0])
    # Blend half a bone into the neighbour on the near end.
    if t > 0.5 and i + 1 < len(chain):
        w = (t - 0.5)
        groups[name].add([int(v)], 1.0 - w, "REPLACE")
        groups[chain[i + 1]].add([int(v)], w, "REPLACE")
    elif t < 0.5 and i > 0:
        w = (0.5 - t)
        groups[name].add([int(v)], 1.0 - w, "REPLACE")
        groups[chain[i - 1]].add([int(v)], w, "REPLACE")
    else:
        groups[name].add([int(v)], 1.0, "REPLACE")
# Diffuse the weights over the mesh so no triangle straddles a hard boundary
# between bones that move apart (leg and flank, upper and lower leg).
bone_names = list(groups)
W = np.zeros((len(co), len(bone_names)))
for v in body.data.vertices:
    for g in v.groups:
        W[v.index, bone_names.index(body.vertex_groups[g.group].name)] = g.weight
for _ in range(int(opts.get("smooth", 6))):
    mean = np.array([W[[b for b, _ in neighbours[a]]].mean(axis=0) if neighbours[a] else W[a]
                     for a in range(len(co))])
    W = 0.5 * W + 0.5 * mean
W[W < 0.02] = 0.0
W /= np.maximum(W.sum(axis=1, keepdims=True), 1e-9)
for k, name in enumerate(bone_names):
    group = groups[name]
    group.remove(list(range(len(co))))
    for v in np.flatnonzero(W[:, k] > 0):
        group.add([int(v)], float(W[v, k]), "REPLACE")
print("skinned: %d leg vertices, %d body vertices, weights diffused" % (assigned.sum(), (~assigned).sum()))
mod = body.modifiers.new("Armature", "ARMATURE")
mod.object = rig
trex = bpy.data.objects["T-Rex"]
gn = next(m for m in trex.modifiers if m.type == "NODES")
body.modifiers.new(gn.name, "NODES").node_group = gn.node_group

# ------------------------------------------------------------------ walk the route
route = {}
for curve in trex.animation_data.action.layers[0].strips[0].channelbags[0].fcurves:
    route[(curve.data_path, curve.array_index)] = curve
frames = list(range(scene.frame_start, scene.frame_end + 1))
transforms = {}
for f in frames:
    x, y = route[("location", 0)].evaluate(f), route[("location", 1)].evaluate(f)
    yaw = route[("rotation_euler", 2)].evaluate(f)
    transforms[f] = Matrix.Translation((x, y, 0.0)) @ Matrix.Rotation(yaw, 4, "Z")

leg_length = float(np.mean([leg["length"] for leg in legs]))
stride = STEP * 2 * leg_length          # body travel per gait cycle
duty = 0.65
forward = np.array([0.0, -1.0, 0.0])
phase_offset = {}
for leg in legs:      # diagonal pairs: left-front with right-back, and so on
    phase_offset[leg["side"]] = 0.0 if leg["side"] in ("LF", "RB") else 0.5

travel = [0.0]
for a, b in zip(frames[:-1], frames[1:]):
    travel.append(travel[-1] + (transforms[b].translation - transforms[a].translation).length)
cycles = np.array(travel) / stride
print("leg length %.2f m, stride %.2f m, %.1f gait cycles over %d frames" % (
    leg_length, stride, cycles[-1], len(frames)))


# Legs by forward kinematics: the upper leg sweeps fore and aft about the
# vertical through the hip (back in stance, forward with a lift in swing),
# the lower leg flexes during the swing. Angles come from the stride and the
# hip-to-foot reach, capped; IK on auto-placed legs over-reached and tore.
def local_rotation(bone, axis, angle):
    """A rotation about an armature-space axis, expressed in the bone's rest frame."""
    rest = bone.bone.matrix_local.to_3x3()
    world = Matrix.Rotation(angle, 3, Vector(axis))
    return (rest.transposed() @ world @ rest).to_quaternion()


for leg in legs:
    hip = segments[leg["upper"]][0]
    reach = max(0.3, float(np.linalg.norm((leg["rest"] - hip)[:2])))
    sweep = min(0.45, math.atan2(duty * stride / 2, reach))
    side = 1.0 if leg["rest"][0] > hip[0] else -1.0
    upper, lower = rig.pose.bones[leg["upper"]], rig.pose.bones[leg["lower"]]
    upper.rotation_mode = lower.rotation_mode = "QUATERNION"
    phase = cycles + phase_offset[leg["side"]]
    for idx, f in enumerate(frames):
        u = phase[idx] % 1.0
        if u < duty:
            angle, lift, flex = sweep * (1 - 2 * u / duty), 0.0, 0.0
        else:
            t = (u - duty) / (1 - duty)
            angle = sweep * (2 * t - 1)
            lift, flex = LIFT * 1.7 * math.sin(math.pi * t), 0.45 * math.sin(math.pi * t)
        # Forward is local -Y: a positive turn about +Z moves a left foot back,
        # so mirror it for the right side.
        q = local_rotation(upper, (0, 0, 1), -side * angle) @ local_rotation(upper, (0, 1, 0), side * lift)
        upper.rotation_quaternion = q
        lower.rotation_quaternion = local_rotation(lower, (0, 1, 0), -side * flex)
        upper.keyframe_insert("rotation_quaternion", frame=f)
        lower.keyframe_insert("rotation_quaternion", frame=f)

# Body wave: a standing sideways wave through torso and tail, the head held
# forward; plus the route transform for mesh and rig.
for idx, f in enumerate(frames):
    for obj in (body, rig):
        obj.matrix_world = transforms[f]
        obj.keyframe_insert("location", frame=f)
        obj.keyframe_insert("rotation_euler", frame=f)
    swing = math.sin(2 * math.pi * cycles[idx])
    for k, name in enumerate(torso):
        pb = rig.pose.bones[name]
        pb.rotation_mode = "XYZ"
        weight = 1.0 - k / max(len(torso) - 1, 1) * 2.2      # counter-rotate the neck
        pb.rotation_euler = (0.04 * math.cos(4 * math.pi * cycles[idx]) * (k == len(torso) - 1), 0.0,
                             WAVE * swing * weight / len(torso) * 2)
        pb.keyframe_insert("rotation_euler", frame=f)
    for k, name in enumerate(tail):
        pb = rig.pose.bones[name]
        pb.rotation_mode = "XYZ"
        lag = math.sin(2 * math.pi * cycles[idx] - 0.35 * (k + 1))
        pb.rotation_euler = (0.0, 0.0, -WAVE * lag * (0.4 + k / len(tail)) / len(tail) * 3)
        pb.keyframe_insert("rotation_euler", frame=f)


def curves_of(owner):
    data = owner.animation_data
    out = []
    if data and data.action:
        for layer in data.action.layers:
            for st in layer.strips:
                for bag in st.channelbags:
                    out += list(bag.fcurves)
    return out


for owner in [body, rig]:
    for curve in curves_of(owner):
        for point in curve.keyframe_points:
            point.interpolation = "LINEAR"

bpy.data.objects.remove(trex)
for obj in list(bpy.data.objects):
    if obj.name.startswith("mark"):
        bpy.data.objects.remove(obj)
scene.frame_set(scene.frame_start)
bpy.ops.wm.save_as_mainfile(filepath=OUT, relative_remap=True, compress=True)
print("saved", OUT)
