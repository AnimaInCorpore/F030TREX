"""Rig and walk a static upright two-legged character mesh for the trail scene.

Run: blender -b -Y TREX/scene/trex_trail.blend --python tools/blender_rig_biped.py -- \
         <model.glb> <out.blend> [options]

Options (key=value): name=Biped  height=4.5 (metres)  triangles=2400
forward=-Y (the source's facing axis in Blender after the glTF import; glTF's
front, +Z, arrives as -Y, the trail scene's forward axis)  step=0.65 (stride
length / leg length)  lift=0.55 (swing knee flex, radians)  twist=0.06 (pelvis
yaw, radians)  arm=0.3 (arm swing, radians)  tail=0.12 (tail sway per bone,
radians)  stage=all|landmarks

The companion of blender_rig_creature.py for characters that stand on two
feet (a person, a rearing dragon, a cartoon crocodile), which that script's
four-foot search misreads (OPTIMIZATION.md 6.6h). For an unrigged mesh:
  1. imports it, turns its forward axis to -Y, scales it to the height and
     decimates it to the triangle budget, as blender_rig_creature.py does;
  2. finds the two feet: the ground contacts whose surface path up to the
     torso climbs at once, as a leg does. A tail lying on the ground starts
     out level and is left out; toe and heel contacts on one side merge;
  3. finds the crotch (the highest point of the shortest surface path from
     one foot to the other), the hips and knees from the legs'
     cross-sections, and a vertical spine from the pelvis to the head;
  4. finds a tail (the farthest low vertex clear of the feet and pelvis) and
     the arms (per side, the hand farthest from the torso, the shoulder at
     the top of its path back);
  5. skins the feet and legs to thigh and shin, blends the tail chain and
     each arm bone in by geodesic distance, and the rest along the spine;
  6. walks it along the T-Rex's route: thighs swing about the side-to-side
     axis, knees flex in the swing, the body drops so the stance foot stays
     on the ground, the pelvis twists and the chest counter-rotates, each
     arm swings against its leg and the tail sways in a lagging wave.
Wings are not animated; they move with the chest. Elbows do not bend.
The T-Rex object is removed; export the result with make model_export.
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
NAME = opts.get("name", "Biped")
HEIGHT = float(opts.get("height", 4.5))
TRIANGLES = int(opts.get("triangles", 2400))
FORWARD = opts.get("forward", "-Y")
STEP = float(opts.get("step", 0.65))
LIFT = float(opts.get("lift", 0.55))
TWIST = float(opts.get("twist", 0.06))
ARM = float(opts.get("arm", 0.3))
TAIL = float(opts.get("tail", 0.12))
STAGE = opts.get("stage", "all")
AXES = {"+X": (1, 0), "-X": (-1, 0), "+Y": (0, 1), "-Y": (0, -1)}
if FORWARD not in AXES:
    raise SystemExit("blender_rig_biped: forward must be one of %s" % ", ".join(AXES))


def fail(message):
    raise SystemExit("blender_rig_biped: " + message)


scene = bpy.context.scene
before = set(bpy.data.objects)
bpy.ops.import_scene.gltf(filepath=SOURCE)
imported = [o for o in bpy.data.objects if o not in before]
meshes = [o for o in imported if o.type == "MESH"]
if len(meshes) != 1:
    fail("expected one mesh, found %d" % len(meshes))
body = meshes[0]
world = body.matrix_world.copy()
body.parent = None
body.data.transform(world)
body.matrix_world = Matrix.Identity(4)
for obj in imported:
    if obj is not body:
        bpy.data.objects.remove(obj)
body.name = body.data.name = NAME

# ------------------------------------------------------------------ face -Y, scale and decimate
fx, fy = AXES[FORWARD]
body.data.transform(Matrix.Rotation(-math.pi / 2 - math.atan2(fy, fx), 4, "Z"))
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


def geodesic(starts, allowed=None):
    starts = [starts] if np.isscalar(starts) else list(starts)
    dist = np.full(len(co), np.inf)
    prev = np.full(len(co), -1)
    dist[starts] = 0.0
    heap = [(0.0, int(s)) for s in starts]
    while heap:
        d, a = heapq.heappop(heap)
        if d > dist[a]:
            continue
        for b, length in neighbours[a]:
            if allowed is not None and not allowed[b]:
                continue
            if d + length < dist[b]:
                dist[b] = d + length
                prev[b] = a
                heapq.heappush(heap, (d + length, b))
    return dist, prev


# Decimated generated meshes can come in loose pieces (buckles, teeth):
# search the largest connected piece only.
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
in_main = label == int(np.argmax(sizes))
main = np.flatnonzero(in_main)
print("pieces %d, largest %d of %d vertices" % (len(sizes), len(main), len(co)))

# Torso centre: the median of a mid-height slice (robust to wings and arms).
mid = main[(co[main, 2] > 0.45 * HEIGHT) & (co[main, 2] < 0.65 * HEIGHT)]
if len(mid) == 0:
    fail("nothing at mid height")
cx, cy = np.median(co[mid, 0]), np.median(co[mid, 1])
torso = int(mid[np.argmin(np.linalg.norm(co[mid] - (cx, cy, 0.55 * HEIGHT), axis=1))])
dist, prev = geodesic(torso)


def path_up(vertex):
    """The geodesic from a vertex to the torso, as points."""
    path = [vertex]
    while prev[path[-1]] >= 0:
        path.append(int(prev[path[-1]]))
    return co[path]


def climb(vertex, run=0.3 * HEIGHT):
    """Height gained over the first `run` metres of the path to the torso."""
    path = path_up(vertex)
    seg = np.r_[0, np.cumsum(np.linalg.norm(np.diff(path, axis=0), axis=1))]
    return float(np.interp(min(run, seg[-1]), seg, path[:, 2]) - path[0, 2]) / run


# Feet: ground contacts (single-link in the ground plane) whose surface path to
# the torso climbs at once, as a leg does. A tail lying on the ground starts
# out nearly level.
ground = main[co[main, 2] < 0.04 * HEIGHT]
clusters = []
for index in ground:
    near = [c for c in clusters
            if np.min(np.linalg.norm(co[c][:, :2] - co[index, :2], axis=1)) < 0.05 * HEIGHT]
    if near:
        near[0].append(index)
        for other in near[1:]:
            near[0] += other
            clusters.remove(other)
    else:
        clusters.append([index])
contacts = []
for c in clusters:
    rep = c[int(np.argmin(dist[c]))]          # the contact's end nearest the torso
    contacts.append(dict(vertices=c, rep=rep, climb=climb(rep), centre=co[c].mean(axis=0)))
if not contacts:
    fail("no ground contacts")
feet, foot_reps, foot_vertices = {}, {}, {}
for side, test in (("L", lambda x: x > cx), ("R", lambda x: x <= cx)):
    mine = [c for c in contacts if test(c["centre"][0])]
    if not mine:
        fail("no ground contact on the %s side; is forward=%s right?" % (side, FORWARD))
    best = max(mine, key=lambda c: c["climb"])
    # Toe and heel of one foot: steep contacts close to the steepest one.
    chosen = [c for c in mine if c["climb"] > 0.5 * best["climb"]
              and np.linalg.norm(c["centre"][:2] - best["centre"][:2]) < 0.2 * HEIGHT]
    for c in chosen:
        c["foot"] = side
    verts = np.concatenate([c["vertices"] for c in chosen])
    feet[side] = np.array([*co[verts, :2].mean(axis=0), 0.0])
    foot_reps[side], foot_vertices[side] = best["rep"], verts
print("ground contacts (x, y, climb):",
      [(round(float(c["centre"][0]), 2), round(float(c["centre"][1]), 2), round(c["climb"], 2),
        c.get("foot", "-")) for c in contacts])
if min(c["climb"] for c in contacts if "foot" in c) < 0.25:
    fail("a foot's path barely climbs; no clear legs on the ground")
separation = abs(feet["L"][0] - feet["R"][0])

# Crotch: the shortest surface path from one foot to the other runs up one
# leg, over the crotch and down the other, so its highest point is the
# crotch. Low vertices away from the feet are barred, so the path cannot cut
# across a stand between the boots or a tail on the ground. Its two halves run
# up the inner legs and guide the hip and knee search.
allowed = in_main & ((co[:, 2] > 0.1 * HEIGHT)
                     | (np.linalg.norm(co[:, :2] - feet["L"][:2], axis=1) < 0.2 * HEIGHT)
                     | (np.linalg.norm(co[:, :2] - feet["R"][:2], axis=1) < 0.2 * HEIGHT))
_, prev_lr = geodesic(foot_reps["L"], allowed)
if prev_lr[foot_reps["R"]] < 0:
    fail("the two feet are not connected over the legs")
bridge = [foot_reps["R"]]
while bridge[-1] != foot_reps["L"]:
    bridge.append(int(prev_lr[bridge[-1]]))
bridge = co[bridge[::-1]]                     # left foot -> right foot
peak = int(np.argmax(bridge[:, 2]))
crotch = float(bridge[peak, 2])
leg_paths = {"L": bridge[:peak + 1], "R": bridge[peak:][::-1]}
if not 0.12 * HEIGHT < crotch < 0.7 * HEIGHT:
    print("crotch at %.2f of the height is implausible; using 0.4" % (crotch / HEIGHT))
    crotch = 0.4 * HEIGHT


def path_at(path, z):
    """The first point of a path at or above height z."""
    above = np.flatnonzero(path[:, 2] >= z)
    return path[above[0]] if len(above) else path[-1]
foot_y = (feet["L"][1] + feet["R"][1]) / 2
hip_z = crotch + 0.04 * HEIGHT


def leg_centre(side, z, fallback):
    """The centre of one leg's cross-section just below z, around its path."""
    near = path_at(leg_paths[side], z - 0.03 * HEIGHT)
    # 0.08 of the height front to back holds a thick thigh but not a backpack.
    band = main[(co[main, 2] > z - 0.05 * HEIGHT) & (co[main, 2] < z - 0.01 * HEIGHT)
                & (np.abs(co[main, 0] - near[0]) < 0.12 * HEIGHT)
                & (np.abs(co[main, 1] - near[1]) < 0.08 * HEIGHT)]
    mid_x = (feet["L"][0] + feet["R"][0]) / 2
    band = band[(co[band, 0] > mid_x) if side == "L" else (co[band, 0] <= mid_x)]
    return co[band, :2].mean(axis=0) if len(band) else fallback


legs = {}
for side, foot in feet.items():
    ankle = foot + np.array([0.0, 0.0, 0.05 * HEIGHT])
    hip_xy = leg_centre(side, crotch, (np.array([cx, cy]) + foot[:2]) / 2)
    hip = np.array([*hip_xy, hip_z])
    knee_z = (hip_z + ankle[2]) / 2
    knee_xy = leg_centre(side, knee_z + 0.03 * HEIGHT, (hip_xy + ankle[:2]) / 2)
    # Nudge the knee forward (-Y) so the leg has a bend direction.
    knee = np.array([knee_xy[0], knee_xy[1] - 0.02 * HEIGHT, knee_z])
    legs[side] = dict(hip=hip, knee=knee, ankle=ankle)

# Spine: slice centroids near the body axis, from the pelvis to the head.
pelvis = np.array([(legs["L"]["hip"][0] + legs["R"]["hip"][0]) / 2,
                   (legs["L"]["hip"][1] + legs["R"]["hip"][1]) / 2, hip_z])
top = co[main, 2].max()
spine = [pelvis]
SPINE = 5
for k in range(1, SPINE + 1):
    z = hip_z + (0.96 * top - hip_z) * k / SPINE
    band = main[(np.abs(co[main, 2] - z) < 0.04 * HEIGHT)
                & (np.linalg.norm(co[main, :2] - spine[-1][:2], axis=1) < 0.15 * HEIGHT)]
    xy = co[band, :2].mean(axis=0) if len(band) else spine[-1][:2]
    spine.append(np.array([*xy, z]))
spine = np.array(spine)
print("feet L %s R %s, separation %.2f m" % (np.round(feet["L"], 2), np.round(feet["R"], 2), separation))
print("crotch %.2f m (%.2f of the height), hips at %.2f m" % (crotch, crotch / HEIGHT, hip_z))
print("spine", [tuple(np.round(p, 2)) for p in spine])


def path_between(start, prev_map, end):
    """Vertex indices of the geodesic from `start`'s tree root back to `end`."""
    path = [end]
    while path[-1] != start and prev_map[path[-1]] >= 0:
        path.append(int(prev_map[path[-1]]))
    return path[::-1]


def centreline(points, radius):
    """Pull surface path points to the centre of the surrounding body."""
    return np.array([co[main[np.linalg.norm(co[main] - p, axis=1) < radius]].mean(axis=0)
                     for p in points])


# Tail: the farthest low vertex that is clear of both feet and well away from
# the pelvis. Its path to the torso runs along the tail to the hips; the tail
# root is the path point nearest the pelvis. Four bones follow the tail's
# centreline; its weight fades into the pelvis near the root.
tail = None
clear = ((co[main, 2] < hip_z) & np.isfinite(dist[main])
         & (np.linalg.norm(co[main, :2] - feet["L"][:2], axis=1) > 0.25 * HEIGHT)
         & (np.linalg.norm(co[main, :2] - feet["R"][:2], axis=1) > 0.25 * HEIGHT)
         & (np.linalg.norm(co[main, :2] - pelvis[:2], axis=1) > 0.35 * HEIGHT))
if clear.any():
    tip = int(main[clear][np.argmax(dist[main[clear]])])
    from_tip, prev_tip = geodesic(tip)
    path = path_between(tip, prev_tip, torso)
    root_at = int(np.argmin(np.linalg.norm(co[path] - pelvis, axis=1)))
    along = co[path[:root_at + 1]][::-1]               # root -> tip on the surface
    seg = np.r_[0, np.cumsum(np.linalg.norm(np.diff(along, axis=0), axis=1))]
    length = float(from_tip[path[root_at]])
    if len(along) > 4 and length > 0.3 * HEIGHT:
        samples = [[np.interp(s, seg, along[:, k]) for k in range(3)] for s in np.linspace(0, seg[-1], 5)]
        chain = centreline(np.array(samples), 0.08 * HEIGHT)
        chain[-1] = co[tip]
        weight = np.clip((length - from_tip) / (0.25 * length), 0.0, 1.0)
        weight[~np.isfinite(weight)] = 0.0
        # How far along the tail each vertex lies, 0 at the root and 1 at the
        # tip, by surface distance: unambiguous where the tail curls back.
        along_tail = np.clip(1.0 - from_tip / length, 0.0, 1.0)
        along_tail[~np.isfinite(along_tail)] = 0.0
        tail = dict(chain=chain, weight=weight, along=along_tail)
        print("tail: tip %s, root %s, %.2f m along the surface" % (
            np.round(co[tip], 2), np.round(chain[0], 2), length))
if tail is None:
    print("no tail")


# Arms: per side, the hand is the vertex farthest along the surface from the
# torso among those
# - out to the side of the body axis (not the head, horns or snout),
# - below three quarters of the height (hands rest below the shoulders; a
#   wing's joint rises above them),
# - at most 0.1 of the height behind that side's foot (not wings or a
#   backpack),
# - outside the tail,
# - and far from the feet along the surface (not a thigh: a hand's way to the
#   feet runs over the shoulder and down the torso).
# The highest point of its path back to the torso is the shoulder: a hanging
# or raised arm climbs to it before the path drops over the chest. The arm
# weight fades from the hand to the shoulder over the geodesic distance from
# the hand.
#
# Decimation can cut a glove or forearm loose, so for the arm search each
# loose piece is bridged to the main piece by one edge between their nearest
# vertices (after the feet, crotch and tail, so a stand on the ground stays
# out of those).
for piece in range(len(sizes)):
    members = np.flatnonzero(label == piece)
    if piece == label[main[0]] or not len(members):
        continue
    gaps = np.linalg.norm(co[members][:, None, :] - co[main][None, :, :], axis=2)
    a, b = np.unravel_index(np.argmin(gaps), gaps.shape)
    a, b = int(members[a]), int(main[b])
    neighbours[a].append((b, float(gaps.min())))
    neighbours[b].append((a, float(gaps.min())))
dist, prev = geodesic(torso)
from_feet, _ = geodesic(np.concatenate([foot_vertices["L"], foot_vertices["R"]]))
in_tail = tail["weight"] > 0 if tail else np.zeros(len(co), bool)
everything = np.arange(len(co))
arms = {}
for side in ("L", "R"):
    offset = (co[:, 0] - pelvis[0]) * (1 if side == "L" else -1)
    pick = everything[(offset > 0.15 * HEIGHT) & (co[:, 2] > 0.75 * crotch) & (co[:, 2] < 0.75 * top)
                      & (co[:, 1] < feet[side][1] + 0.1 * HEIGHT) & np.isfinite(dist)
                      & ~in_tail & (from_feet > 1.3 * hip_z)]
    if not len(pick):
        continue
    tip = int(pick[np.argmax(dist[pick])])
    if dist[tip] < 0.3 * HEIGHT:
        continue                                      # nothing sticks out on this side
    from_hand, prev_hand = geodesic(tip)
    path = path_between(tip, prev_hand, torso)
    peak = path[int(np.argmax(co[path, 2]))]
    reach = float(from_hand[peak])                    # hand to shoulder along the surface
    if reach < 0.15 * HEIGHT:
        continue
    ring = main[(from_hand[main] > 0.8 * reach) & (from_hand[main] < 0.95 * reach)]
    pivot = co[ring].mean(axis=0) if len(ring) else co[peak]
    weight = np.clip((reach - from_hand) / (0.35 * reach), 0.0, 1.0)
    weight[~np.isfinite(weight)] = 0.0
    arms[side] = dict(shoulder=pivot, hand=co[tip].copy(), weight=weight)
    print("arm %s: hand %s, shoulder %s, %.2f m along the surface" % (
        side, np.round(co[tip], 2), np.round(pivot, 2), reach))

if STAGE == "landmarks":
    marker = bpy.data.materials.new("marker")
    marker.diffuse_color = (1, 0, 0, 1)
    points = list(spine) + [p for leg in legs.values() for p in leg.values()]
    points += [p for arm in arms.values() for p in (arm["shoulder"], arm["hand"])]
    points += list(tail["chain"]) if tail else []
    for p in points:
        bpy.ops.mesh.primitive_uv_sphere_add(radius=0.08, location=tuple(p))
        bpy.context.active_object.data.materials.append(marker)
    bpy.ops.wm.save_as_mainfile(filepath=OUT)
    raise SystemExit(0)

# Centre the pelvis on the object origin; the model already faces -Y.
shift = np.array([pelvis[0], pelvis[1], 0.0])
body.data.transform(Matrix.Translation(Vector(-shift)))
co -= shift
spine -= shift
for leg in legs.values():
    for key in leg:
        leg[key] = leg[key] - shift
for arm in arms.values():
    arm["shoulder"], arm["hand"] = arm["shoulder"] - shift, arm["hand"] - shift
if tail:
    tail["chain"] = tail["chain"] - shift

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
    fail("UVs outside 0..1 (pages do not tile)")

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
torso_bones = []
parent = root
for k, (a, b) in enumerate(zip(spine[:-1], spine[1:])):
    bone = eb.new("pelvis" if k == 0 else "spine%02d" % k)
    bone.head, bone.tail = Vector(a), Vector(b)
    bone.parent, bone.use_connect = parent, k > 0
    parent = bone
    torso_bones.append(bone.name)
for side, leg in legs.items():
    thigh, shin = eb.new("thigh_" + side), eb.new("shin_" + side)
    thigh.head, thigh.tail = Vector(leg["hip"]), Vector(leg["knee"])
    shin.head, shin.tail = Vector(leg["knee"]), Vector(leg["ankle"])
    thigh.parent, shin.parent, shin.use_connect = eb["pelvis"], thigh, True
    leg.update(thigh=thigh.name, shin=shin.name,
               length=float(np.linalg.norm(leg["knee"] - leg["hip"]) + np.linalg.norm(leg["ankle"] - leg["knee"])))
# One bone per arm, from the shoulder pivot to the hand, hanging from the
# torso bone nearest the shoulder; a four-bone tail chain from the pelvis.
for side, arm in arms.items():
    bone = eb.new("arm_" + side)
    bone.head, bone.tail = Vector(arm["shoulder"]), Vector(arm["hand"])
    nearest = min(torso_bones, key=lambda n: np.linalg.norm(
        (np.array(eb[n].head[:]) + np.array(eb[n].tail[:])) / 2 - arm["shoulder"]))
    bone.parent = eb[nearest]
    arm["bone"] = bone.name
tail_bones = []
if tail:
    parent = eb["pelvis"]
    for k, (a, b) in enumerate(zip(tail["chain"][:-1], tail["chain"][1:])):
        bone = eb.new("tail%02d" % k)
        bone.head, bone.tail = Vector(a), Vector(b)
        bone.parent, bone.use_connect = parent, k > 0
        parent = bone
        tail_bones.append(bone.name)
segments = {name: (np.array(eb[name].head[:]), np.array(eb[name].tail[:]))
            for name in torso_bones + [leg[k] for leg in legs.values() for k in ("thigh", "shin")]
            + [arm["bone"] for arm in arms.values()] + tail_bones}
bpy.ops.object.mode_set(mode="OBJECT")


# Skin by region, as blender_rig_creature.py does: a vertex below the hips
# that is clearly nearer one leg than the other leg and the spine belongs to
# that leg (shin below the knee, thigh above, easing into the pelvis near the
# hip); every other vertex blends between neighbouring torso bones.
def segment_projection(points, a, b):
    ab = b - a
    t = np.clip(((points - a) @ ab) / max(ab @ ab, 1e-9), 0, 1)
    return np.linalg.norm(points - (a + t[:, None] * ab), axis=1), t


groups = {n: body.vertex_groups.new(name=n) for n in segments}
chain_d = np.stack([segment_projection(co, *segments[n])[0] for n in torso_bones], axis=1)
best_chain = np.argmin(chain_d, axis=1)
d_spine = chain_d[np.arange(len(co)), best_chain]
leg_d = {}
for side, leg in legs.items():
    du, tu = segment_projection(co, *segments[leg["thigh"]])
    dl, _ = segment_projection(co, *segments[leg["shin"]])
    leg_d[side] = (np.minimum(du, dl), du, dl, tu)
# A foot is everything its ground contacts reach without climbing above the
# knee: long toes and claws, but not a tail lying beside it, which joins the
# body only above the hips.
below_knee = {side: np.isfinite(geodesic(foot_vertices[side],
                                         in_main & (co[:, 2] < legs[side]["knee"][2]))[0])
              for side in legs}
assigned = np.zeros(len(co), bool)
for side, leg in legs.items():
    d, du, dl, tu = leg_d[side]
    other_side = "R" if side == "L" else "L"
    other = leg_d[other_side][0]
    foot = below_knee[side] & ~below_knee[other_side]
    # Elsewhere a vertex must be clearly nearer this leg than the other one;
    # parts between the legs would otherwise tear as the legs part.
    mine = foot | ((d < 0.8 * d_spine) & (d < 0.7 * other) & (d < 0.18 * HEIGHT)
                   & (co[:, 2] < hip_z + 0.02 * HEIGHT))
    mine &= ~assigned
    assigned |= mine
    for v in np.flatnonzero(mine):
        if foot[v] or dl[v] < du[v]:
            groups[leg["shin"]].add([int(v)], 1.0, "REPLACE")
            continue
        into_body = max(0.0, 1.0 - tu[v] / 0.35)
        groups[leg["thigh"]].add([int(v)], 1.0 - 0.5 * into_body, "REPLACE")
        if into_body > 0:
            groups["pelvis"].add([int(v)], 0.5 * into_body, "REPLACE")
for v in np.flatnonzero(~assigned):
    i = int(best_chain[v])
    name = torso_bones[i]
    _, t = segment_projection(co[v:v + 1], *segments[name])
    t = float(t[0])
    if t > 0.5 and i + 1 < len(torso_bones):
        groups[name].add([int(v)], 1.5 - t, "REPLACE")
        groups[torso_bones[i + 1]].add([int(v)], t - 0.5, "REPLACE")
    elif t < 0.5 and i > 0:
        groups[name].add([int(v)], 0.5 + t, "REPLACE")
        groups[torso_bones[i - 1]].add([int(v)], 0.5 - t, "REPLACE")
    else:
        groups[name].add([int(v)], 1.0, "REPLACE")
# Diffuse the weights over the mesh so no triangle straddles a hard boundary
# between bones that move apart (thigh and belly, thigh and shin).
bone_names = list(groups)
W = np.zeros((len(co), len(bone_names)))
for v in body.data.vertices:
    for g in v.groups:
        W[v.index, bone_names.index(body.vertex_groups[g.group].name)] = g.weight
column = {name: k for k, name in enumerate(bone_names)}


def blend_in(weight, bones, along=None):
    """Hand each vertex `weight` of the bones, scaling the torso weights it had.

    With `along` (0 at the chain's root, 1 at its tip) the vertex blends
    linearly between the two bones it lies between; otherwise all goes to one.
    """
    weight = np.where(assigned, 0.0, weight)          # the legs keep theirs
    for v in np.flatnonzero(weight > 0):
        W[v] *= 1.0 - weight[v]
        if along is None:
            W[v, column[bones[0]]] += weight[v]
            continue
        x = float(np.clip(along[v] * len(bones) - 0.5, 0, len(bones) - 1))
        k = min(int(x), len(bones) - 2) if len(bones) > 1 else 0
        f = x - k if len(bones) > 1 else 0.0
        W[v, column[bones[k]]] += weight[v] * (1.0 - f)
        if len(bones) > 1:
            W[v, column[bones[k + 1]]] += weight[v] * f
    return int((weight > 0).sum())


# Tail and arms take over from the torso bones by their geodesic fade.
if tail:
    print("tail: %d vertices" % blend_in(tail["weight"], tail_bones, tail["along"]))
for side, arm in arms.items():
    print("arm %s: %d vertices" % (side, blend_in(arm["weight"], [arm["bone"]])))
for _ in range(int(opts.get("smooth", 6))):
    mean = np.array([W[[b for b, _ in neighbours[a]]].mean(axis=0) if neighbours[a] else W[a]
                     for a in range(len(co))])
    W = 0.5 * W + 0.5 * mean
W[W < 0.02] = 0.0
W /= np.maximum(W.sum(axis=1, keepdims=True), 1e-9)
# Loose pieces (buckles, straps, a stand) move rigidly with the weights of
# the main-piece vertex nearest their centre, so they cannot stretch.
for piece in range(len(sizes)):
    members = np.flatnonzero(label == piece)
    if piece == label[main[0]] or not len(members):
        continue
    anchor = main[np.argmin(np.linalg.norm(co[main] - co[members].mean(axis=0), axis=1))]
    W[members] = W[anchor]
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

leg_length = float(np.mean([leg["length"] for leg in legs.values()]))
stride = STEP * 2 * leg_length          # body travel per gait cycle (two steps)
duty = 0.6
travel = [0.0]
for a, b in zip(frames[:-1], frames[1:]):
    travel.append(travel[-1] + (transforms[b].translation - transforms[a].translation).length)
cycles = np.array(travel) / stride
print("leg length %.2f m, stride %.2f m, %.1f gait cycles over %d frames" % (
    leg_length, stride, cycles[-1], len(frames)))


def local_rotation(bone, axis, angle):
    """A rotation about an armature-space axis, expressed in the bone's rest frame."""
    rest = bone.bone.matrix_local.to_3x3()
    world = Matrix.Rotation(angle, 3, Vector(axis))
    return (rest.transposed() @ world @ rest).to_quaternion()


# The stance foot moves back under the hip by the body's travel over the
# stance: duty * stride, so the thigh sweeps +-atan(duty * stride / 2 / leg).
sweep = min(0.5, math.atan2(duty * stride / 2, leg_length))
phase_offset = {"L": 0.0, "R": 0.5}
drops = np.zeros(len(frames))
stance_angle = {side: np.full(len(frames), np.inf) for side in legs}
leg_forward = {side: np.zeros(len(frames)) for side in legs}
for side, leg in legs.items():
    thigh, shin = rig.pose.bones[leg["thigh"]], rig.pose.bones[leg["shin"]]
    thigh.rotation_mode = shin.rotation_mode = "QUATERNION"
    phase = cycles + phase_offset[side]
    for idx, f in enumerate(frames):
        u = phase[idx] % 1.0
        if u < duty:
            # Stance: foot planted, from in front of the hip to behind it.
            forward, flex = sweep * (1 - 2 * u / duty), 0.0
            stance_angle[side][idx] = forward
        else:
            # Swing: forward again, the knee flexing to clear the ground and
            # the hip flexing a little more to carry the foot.
            t = (u - duty) / (1 - duty)
            flex = LIFT * math.sin(math.pi * t)
            forward = sweep * (2 * t - 1) + 0.35 * flex
        leg_forward[side][idx] = forward
        # Rotating a downward thigh about +X moves the foot to +Y, backwards.
        thigh.rotation_quaternion = local_rotation(thigh, (1, 0, 0), -forward)
        shin.rotation_quaternion = local_rotation(shin, (1, 0, 0), flex)
        thigh.keyframe_insert("rotation_quaternion", frame=f)
        shin.keyframe_insert("rotation_quaternion", frame=f)
# A swept straight leg reaches less far down: drop the body by the shortfall of
# the most upright stance leg, so a planted foot touches the ground.
for idx in range(len(frames)):
    angle = min(abs(stance_angle[side][idx]) for side in legs)
    drops[idx] = leg_length * (1 - math.cos(angle)) if np.isfinite(angle) else 0.0

pelvis_bone = rig.pose.bones["pelvis"]
pelvis_bone.rotation_mode = "QUATERNION"
upper = [rig.pose.bones[name] for name in torso_bones[1:]]
for pb in upper:
    pb.rotation_mode = "QUATERNION"
for idx, f in enumerate(frames):
    for obj in (body, rig):
        obj.matrix_world = transforms[f] @ Matrix.Translation((0.0, 0.0, -drops[idx]))
        obj.keyframe_insert("location", frame=f)
        obj.keyframe_insert("rotation_euler", frame=f)
    # The pelvis turns towards the forward leg; the chest turns back.
    twist = TWIST * math.sin(2 * math.pi * cycles[idx])
    pelvis_bone.rotation_quaternion = local_rotation(pelvis_bone, (0, 0, 1), twist)
    pelvis_bone.keyframe_insert("rotation_quaternion", frame=f)
    for pb in upper:
        pb.rotation_quaternion = local_rotation(pb, (0, 0, 1), -twist / max(len(upper), 1))
        pb.keyframe_insert("rotation_quaternion", frame=f)
    # Each arm swings against the leg on its side, about the side-to-side axis.
    for side, arm in arms.items():
        pb = rig.pose.bones[arm["bone"]]
        pb.rotation_mode = "QUATERNION"
        swing = -ARM * leg_forward[side][idx] / max(sweep, 1e-6)
        pb.rotation_quaternion = local_rotation(pb, (1, 0, 0), -swing)
        pb.keyframe_insert("rotation_quaternion", frame=f)
    # The tail sways about the vertical in a wave running to the tip, so a
    # tail on the ground stays on it.
    for k, name in enumerate(tail_bones):
        pb = rig.pose.bones[name]
        pb.rotation_mode = "QUATERNION"
        lag = math.sin(2 * math.pi * cycles[idx] - 0.7 * (k + 1))
        pb.rotation_quaternion = local_rotation(pb, (0, 0, 1), TAIL * (0.5 + k / max(len(tail_bones) - 1, 1)) * lag)
        pb.keyframe_insert("rotation_quaternion", frame=f)


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
