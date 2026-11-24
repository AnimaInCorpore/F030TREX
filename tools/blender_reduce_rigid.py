"""Reduce a rigidly skinned high-polygon model to a textured PS1-budget mesh.

Run: blender -b <source.blend> --python tools/blender_reduce_rigid.py -- \
         <mesh object> <armature object> <out.blend> [options]

Options (key=value):
  triangles=1470      triangle target of the whole reduced model
  min_piece=0.045     loose pieces below this share of the model height are dropped
  min_triangles=8     smallest hull kept after decimation
  mirror=_l:_r:X,front_:rear_:Y
                      bone-name substitutions whose targets are mirror images
                      of their sources: only the source is reduced and
                      textured; the targets are mirrored copies sharing its
                      UVs. The mirror plane is midway between the two bones.
  pages=Main;Head,Neck*,canon*,Blaster*;*leg*
                      bone-name patterns per 256x256 texture page (at most six)
  colours=Material:r,g,b;...   8-bit albedo per source material (default grey)
  glow=Material       source materials baked without shading (lamps, windows)
  surfaces=Head,canon*,Blaster*,*leg_004*  simplify source faces on these
                      bones to retain concave profiles and separate toe plates
  ambient=0.5         minimum AO multiplier baked into non-emissive materials
  round_feet=bone     fit the round vertical casting on this bone to its
                      source cross-sections; other pieces keep their toe geometry
  size=height         the length that scales min_piece and the bake distances:
                      "height" (Z extent, for walkers) or "extent" (the longest
                      side, for flat or long vehicles)
  inside=bone         drop a hull inside a larger hull of the same bone, or of
                      any bone with inside=any (rigid models whose parts all
                      move together)
  textures=0          1: bake a material's image texture (its first image node,
                      through the source's UVs) instead of its flat colour
  external=Main:body.obj;...
                      replace every piece of these bones with a mesh made
                      elsewhere (an OBJ in the source's world space, Z up,
                      for example a LATO.2 result), decimated to the bone's
                      budget share and baked like the hulls

For a model whose parts each follow one bone (machines, robots), every loose
piece of the mesh becomes the convex hull of its vertices -- which keeps the
bone weights -- decimated to its share of the triangle budget by surface
area. Pieces lying inside a larger hull of the same bone are dropped.
The hulls are unwrapped per page and the source's detail is baked onto
them with Cycles: material albedo times ambient occlusion, so panel lines and
greebles survive as texture; texels whose rays found no surface take their
neighbours' colour. Pages are quantized to 15-bit colour and 255
palette entries, as the Falcon holds them.

The output .blend holds the armature and the reduced mesh "<object> low"
with vertex groups, a "PS1 UV" map, and one material per page. Put it into a
scene with tools/blender_build_walkers.py (OPTIMIZATION.md 6.6j).
"""
import fnmatch
import hashlib
import math
import sys
from collections import Counter
from pathlib import Path

import bmesh
import bpy
import numpy as np
from mathutils import Vector
from PIL import Image

args = sys.argv[sys.argv.index("--") + 1:]
OBJECT, ARMATURE, OUT = args[0], args[1], Path(args[2]).resolve()
opts = dict(a.split("=", 1) for a in args[3:])
TRIANGLES = int(opts.get("triangles", 1470))
MIN_PIECE = float(opts.get("min_piece", 0.045))
MIN_TRIANGLES = int(opts.get("min_triangles", 8))
MIRRORS = [tuple(m.split(":")) for m in filter(None, opts.get("mirror", "").split(","))]
PAGES = [p.split(",") for p in filter(None, opts.get("pages", "*").split(";"))]
COLOURS = {}
for item in filter(None, opts.get("colours", "").split(";")):
    key, rgb = item.split(":")
    COLOURS[key] = tuple(int(c) / 255 for c in rgb.split(","))
GLOW = set(filter(None, opts.get("glow", "").split(",")))
SURFACES = tuple(filter(None, opts.get("surfaces", "").split(",")))
ROUND_FEET = opts.get("round_feet")
AMBIENT = float(opts.get("ambient", 0.5))
SIZE = opts.get("size", "height")
INSIDE_ANY = opts.get("inside", "bone") == "any"
TEXTURES = opts.get("textures", "0") == "1"
EXTERNAL = dict(item.split(":", 1) for item in filter(None, opts.get("external", "").split(";")))
if SIZE not in ("height", "extent"):
    raise SystemExit("size must be height or extent")
if not 0 <= AMBIENT <= 1:
    raise SystemExit("ambient must be in 0..1")
PAGE_SIZE, BAKE_SIZE = 256, 1024

scene = bpy.context.scene
source = bpy.data.objects[OBJECT]
rig = bpy.data.objects[ARMATURE]
mesh = source.data
bones = rig.data.bones

# ------------------------------------------------------------------ loose pieces
names = {g.index: g.name for g in source.vertex_groups}
vertex_bone = []
for v in mesh.vertices:
    best = max(v.groups, key=lambda g: g.weight, default=None)
    vertex_bone.append(names[best.group] if best else None)
coords = np.array([v.co[:] for v in mesh.vertices])
height = coords[:, 2].max() - min(0.0, coords[:, 2].min())
if SIZE == "extent":        # every length below scales with this one
    height = float(np.ptp(coords, axis=0).max())

bm = bmesh.new()
bm.from_mesh(mesh)
bm.verts.ensure_lookup_table()
label = -np.ones(len(coords), int)
pieces = 0
for v in bm.verts:
    if label[v.index] >= 0:
        continue
    stack = [v]
    label[v.index] = pieces
    while stack:
        x = stack.pop()
        for e in x.link_edges:
            y = e.other_vert(x)
            if label[y.index] < 0:
                label[y.index] = pieces
                stack.append(y)
    pieces += 1
bm.free()

# The convex envelope still determines visibility and the budget. For a
# selected bone, retain the original triangles of each loose piece so that
# simplification can follow its recesses, stepped barrels and sole profiles.
source_tris = {}
if SURFACES:
    mesh.calc_loop_triangles()
    for tri in mesh.loop_triangles:
        indices = tuple(tri.vertices)
        source_tris.setdefault(label[indices[0]], []).append(indices)


def substitute(name, old, new, known):
    """Replace one occurrence of old so that the result is a known bone, or None."""
    start = name.find(old)
    while start >= 0:
        result = name[:start] + new + name[start + len(old):]
        if result in known:
            return result
        start = name.find(old, start + 1)
    return None


def mirror_target(name):
    """True if a mirror rule produces this bone from another one."""
    return any(substitute(name, new, old, set(names.values())) for old, new, _ in MIRRORS)


def hull_of(indices):
    """Convex hull of some source vertices: (vertex indices, triangles)."""
    hb = bmesh.new()
    verts = [hb.verts.new(coords[i]) for i in indices]
    result = bmesh.ops.convex_hull(hb, input=verts)
    faces = [g for g in result["geom"] if isinstance(g, bmesh.types.BMFace)]
    bmesh.ops.triangulate(hb, faces=faces)
    hb.verts.index_update()
    used = sorted({v.index for f in hb.faces for v in f.verts})
    remap = {old: new for new, old in enumerate(used)}
    tris = [[remap[v.index] for v in f.verts] for f in hb.faces if len(f.verts) == 3]
    hb.verts.ensure_lookup_table()
    points = np.array([hb.verts[i].co[:] for i in used])
    hb.free()
    return points, np.array(tris, int)


def planes(points, tris):
    a, b, c = (points[tris[:, i]] for i in range(3))
    normal = np.cross(b - a, c - a)
    length = np.linalg.norm(normal, axis=1)
    keep = length > 1e-12
    normal = normal[keep] / length[keep, None]
    centre = points.mean(0)
    offset = np.einsum("ij,ij->i", normal, a[keep])
    flip = normal @ centre > offset          # make the normals point outward
    normal[flip] *= -1
    offset[flip] *= -1
    return normal, offset, 0.5 * length.sum()


candidates = []
for piece in range(pieces):
    indices = np.flatnonzero(label == piece)
    bone = Counter(vertex_bone[i] for i in indices).most_common(1)[0][0]
    if bone is None or mirror_target(bone) or len(indices) < 4:
        continue
    lo, hi = coords[indices].min(0), coords[indices].max(0)
    if np.linalg.norm(hi - lo) < MIN_PIECE * height:
        continue
    points, tris = hull_of(indices)
    if len(tris) < 4:
        continue
    normal, offset, area = planes(points, tris)
    candidates.append(dict(bone=bone, points=points, tris=tris, normal=normal, offset=offset,
                           area=area, indices=indices, piece=piece))
candidates.sort(key=lambda c: -c["area"])
parts = []
for cand in candidates:
    inside = False
    for other in parts:
        if other["bone"] != cand["bone"] and not INSIDE_ANY:
            continue
        depth = cand["points"] @ other["normal"].T - other["offset"]
        if depth.max() < 0.02 * MIN_PIECE * height + 0.02:
            inside = True
            break
    if not inside:
        parts.append(cand)
print("pieces %d, hull candidates %d, kept %d" % (pieces, len(candidates), len(parts)))


def load_obj(path):
    """Triangulated OBJ vertices and faces, moved into the source's local space."""
    verts, tris = [], []
    for line in open(path):
        p = line.split()
        if p and p[0] == "v":
            verts.append([float(c) for c in p[1:4]])
        elif p and p[0] == "f":
            idx = [int(c.split("/")[0]) - 1 for c in p[1:]]
            tris.extend([idx[0], idx[i], idx[i + 1]] for i in range(1, len(idx) - 1))
    inverse = np.array(source.matrix_world.inverted())
    verts = np.c_[np.array(verts), np.ones(len(verts))] @ inverse.T
    return verts[:, :3], np.array(tris, int)


for bone, path in EXTERNAL.items():
    dropped = sum(p["bone"] == bone for p in parts)
    parts = [p for p in parts if p["bone"] != bone]
    points, tris = load_obj(path)
    a, b, c = (points[tris[:, i]] for i in range(3))
    area = 0.5 * np.linalg.norm(np.cross(b - a, c - a), axis=1).sum()
    parts.append(dict(bone=bone, points=points, tris=tris, area=area, piece=None, external=True))
    print("external %s: %d triangles from %s, replacing %d pieces" % (bone, len(tris), path, dropped))

# ------------------------------------------------------------------ copies per part
def copies_of(bone):
    """Bone names of the mirrored copies of a source bone, with their flips."""
    known = {b.name for b in bones}
    result = [(bone, ())]
    for old, new, axis in MIRRORS:
        for name, flips in list(result):
            target = substitute(name, old, new, known)
            if target:
                result.append((target, flips + ((name, target, axis),)))
    return result


for part in parts:
    part["copies"] = copies_of(part["bone"])
    part["use_surface"] = not part.get("external") and any(
        fnmatch.fnmatchcase(part["bone"], pattern) for pattern in SURFACES)

# ------------------------------------------------------------------ triangle budget
areas = np.array([p["area"] for p in parts])
counts = np.array([len(source_tris[p["piece"]]) if p["use_surface"] else len(p["tris"]) for p in parts])
multiplicity = np.array([len(p["copies"]) for p in parts])
share = float(TRIANGLES)
for _ in range(60):
    wanted = np.minimum(counts, np.maximum(MIN_TRIANGLES, np.rint(share * areas / (areas * multiplicity).sum())))
    total = (wanted * multiplicity).sum()
    if total <= TRIANGLES:
        break
    share *= TRIANGLES / total

collection = scene.collection
objects = []


def collapse(obj, target):
    """Set the ratio from triangles, including quad voxel faces."""
    modifier = obj.modifiers.new("decimate", "DECIMATE")
    modifier.ratio = min(1.0, float(target) / sum(p.loop_total - 2 for p in obj.data.polygons))
    modifier.use_collapse_triangulate = True
    return modifier


def foot_casting(points, triangles, target):
    """Fit rings to a circular foot drum. Reject the struts and toe plates."""
    low, high = points.min(0), points.max(0)
    size = high - low
    if min(size[:2]) < 0.96 * max(size[:2]) or len(points) < 256:
        return None
    centre = (low[:2] + high[:2]) / 2
    ring_angles = np.arange(8) * (math.tau / 8)
    # Intersect triangle edges with horizontal planes. The outer radius
    # follows the casting even at heights with vertices only in the hub.
    a = points[triangles].reshape(-1, 3)
    b = points[np.roll(triangles, 1, axis=1)].reshape(-1, 3)
    level = np.unique(np.round((points[:, 2] - low[2]) / size[2], 2))
    heights = low[2] + np.clip(level, 0.0001, 0.9999) * size[2]
    profile = []
    for z in heights:
        cut = (np.minimum(a[:, 2], b[:, 2]) < z) & (np.maximum(a[:, 2], b[:, 2]) >= z)
        if cut.any():
            edge = b[cut] - a[cut]
            xy = a[cut, :2] + edge[:, :2] * ((z - a[cut, 2]) / edge[:, 2])[:, None]
            profile.append((z, np.linalg.norm(xy - centre, axis=1).max()))
    profile = np.asarray(profile)
    if len(profile) < 5:
        return None
    # Keep the biggest changes in slope, including steep ledges. With eight
    # sides each additional ring costs 16 triangles.
    selected = [0, len(profile) - 1]
    for _ in range(min(len(profile), max(4, int((target + 4) // 16))) - 2):
        error = np.zeros(len(profile))
        for i, j in zip(selected, selected[1:]):
            dz, dr = profile[j] - profile[i]
            delta = profile[i+1:j] - profile[i]
            error[i+1:j] = abs(dz * delta[:, 1] - dr * delta[:, 0]) / np.hypot(dz, dr)
        if error.max() < 0.012 * size[2]:
            break
        selected.append(int(error.argmax()))
        selected.sort()
    vertices = [(centre[0]+r*np.cos(t), centre[1]+r*np.sin(t), z)
                for z,r in profile[selected] for t in ring_angles]
    faces = []
    for row in range(len(selected)-1):
        for i in range(8):
            a0, b0 = row*8+i, row*8+(i+1)%8
            faces.extend(((a0,b0,b0+8), (a0,b0+8,a0+8)))
    top = len(vertices)-8
    for i in range(1,7):
        faces.extend(((0,i+1,i), (top,top+i,top+i+1)))
    return vertices, faces


for index, (part, target) in enumerate(zip(parts, wanted)):
    me = bpy.data.meshes.new("part %d" % index)
    use_surface = part["use_surface"]
    if use_surface:
        indices = part["indices"]
        tris = np.searchsorted(indices, source_tris[part["piece"]])
        points = coords[indices]
        casting = foot_casting(points, tris, target) if part["bone"] == ROUND_FEET else None
        if casting:
            me.from_pydata(casting[0], [], casting[1])
        else:
            me.from_pydata(points.tolist(), [], tris.tolist())
    else:
        me.from_pydata(part["points"].tolist(), [], part["tris"].tolist())
    me.update()
    obj = bpy.data.objects.new(me.name, me)
    collection.objects.link(obj)
    obj.matrix_world = source.matrix_world
    bmn = bmesh.new()
    bmn.from_mesh(me)
    if use_surface:
        bmesh.ops.remove_doubles(bmn, verts=bmn.verts[:], dist=0.0001 * height)
        bmesh.ops.dissolve_degenerate(bmn, edges=bmn.edges[:], dist=0.00001 * height)
    bmesh.ops.recalc_face_normals(bmn, faces=bmn.faces[:])
    bmn.to_mesh(me)
    bmn.free()
    if target < len(me.polygons):
        mod = collapse(obj, target)
        with bpy.context.temp_override(object=obj, active_object=obj):
            if use_surface:
                result = obj.evaluated_get(bpy.context.evaluated_depsgraph_get())
                if len(result.data.polygons) > target + 3:
                    # A non-manifold detailed casting can stall edge collapse.
                    # Resample only this piece's exterior, then simplify it.
                    obj.modifiers.remove(mod)
                    me.remesh_voxel_size = float(np.ptp(coords[indices], axis=0).max()) / 64
                    bpy.ops.object.voxel_remesh()
                    mod = collapse(obj, target)
            bpy.ops.object.modifier_apply(modifier=mod.name)
    page = next((i for i, patterns in enumerate(PAGES)
                 if any(fnmatch.fnmatchcase(part["bone"], p) for p in patterns)), len(PAGES) - 1)
    part.update(object=obj, page=page)
    objects.append(obj)

# ------------------------------------------------------------------ unwrap per page
page_objects = []
for page in range(len(PAGES)):
    members = [p["object"] for p in parts if p["page"] == page]
    if not members:
        page_objects.append(None)
        continue
    for number, p in enumerate(parts):
        if p["page"] == page:
            attr = p["object"].data.attributes.new("part", "INT", "FACE")
            attr.data.foreach_set("value", [number] * len(p["object"].data.polygons))
    bpy.ops.object.select_all(action="DESELECT")
    for obj in members:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = members[0]
    if len(members) > 1:
        bpy.ops.object.join()
    joined = bpy.context.view_layer.objects.active
    joined.name = "page %d" % page
    joined.data.uv_layers.new(name="PS1 UV")
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.uv.smart_project(angle_limit=1.15, island_margin=0.012, area_weight=0.0,
                             correct_aspect=True, scale_to_bounds=False)
    bpy.ops.uv.pack_islands(margin=0.012, rotate=True)
    bpy.ops.object.mode_set(mode="OBJECT")
    for poly in joined.data.polygons:
        poly.use_smooth = False
    page_objects.append(joined)

# ------------------------------------------------------------------ bake
scene.render.engine = "CYCLES"
scene.world = None  # the emission/AO bake is independent of the source file's studio HDRI
scene.cycles.device = "CPU"
scene.cycles.samples = 24
scene.cycles.use_denoising = False
bake = scene.render.bake
bake.use_selected_to_active = True
bake.cage_extrusion = 0.02 * height / 11.5
bake.max_ray_distance = 0.12 * height
bake.margin = 8
bake.use_clear = True
# The source in its rest shape: no armature, basis shape.
for mod in source.modifiers:
    if mod.type == "ARMATURE":
        mod.show_viewport = mod.show_render = False
source.show_only_shape_key, source.active_shape_key_index = True, 0
bake_floors = []
for slot, material in enumerate(list(mesh.materials)):
    name = material.name if material else ""
    colour = COLOURS.get(name, (0.62, 0.64, 0.66))
    image = None
    if TEXTURES and material and material.node_tree:
        image = next((n.image for n in material.node_tree.nodes
                      if n.type == "TEX_IMAGE" and n.image), None)
        if image is not None and not image.has_data and tuple(image.size) == (0, 0):
            image = None        # a missing file would bake Blender's magenta
    # A texture can be dark anywhere: only an almost black texel counts as a
    # ray that found no surface.
    bake_floors.append(0.02 if image else max(colour) * (1.0 if name in GLOW else AMBIENT * 0.88))
    baked = bpy.data.materials.new("bake " + name)
    baked.use_nodes = True
    tree = baked.node_tree
    tree.nodes.clear()
    out = tree.nodes.new("ShaderNodeOutputMaterial")
    emission = tree.nodes.new("ShaderNodeEmission")
    tree.links.new(emission.outputs[0], out.inputs["Surface"])
    if name in GLOW:
        emission.inputs["Color"].default_value = (*colour, 1.0)
    else:
        occlusion = tree.nodes.new("ShaderNodeAmbientOcclusion")
        occlusion.samples = 16
        occlusion.only_local = True
        occlusion.inputs["Distance"].default_value = 0.05 * height
        noise = tree.nodes.new("ShaderNodeTexNoise")
        noise.inputs["Scale"].default_value = 30.0 / height
        noise.inputs["Detail"].default_value = 6.0
        # Snow bounce lifts occluded armour while the material boundaries remain.
        power = tree.nodes.new("ShaderNodeMath")
        power.operation = "POWER"
        tree.links.new(occlusion.outputs["AO"], power.inputs[0])
        power.inputs[1].default_value = 1.5
        shade = tree.nodes.new("ShaderNodeMath")
        shade.operation = "MULTIPLY_ADD"
        tree.links.new(power.outputs[0], shade.inputs[0])
        shade.inputs[1].default_value, shade.inputs[2].default_value = 1 - AMBIENT, AMBIENT
        grime = tree.nodes.new("ShaderNodeMath")
        grime.operation = "MULTIPLY_ADD"
        tree.links.new(noise.outputs["Factor" if "Factor" in noise.outputs else "Fac"], grime.inputs[0])
        grime.inputs[1].default_value, grime.inputs[2].default_value = 0.24, 0.88
        both = tree.nodes.new("ShaderNodeMath")
        both.operation = "MULTIPLY"
        tree.links.new(shade.outputs[0], both.inputs[0])
        tree.links.new(grime.outputs[0], both.inputs[1])
        scale = tree.nodes.new("ShaderNodeVectorMath")
        scale.operation = "SCALE"
        scale.inputs[0].default_value = colour
        if image is not None:
            texel = tree.nodes.new("ShaderNodeTexImage")
            texel.image = image
            tree.links.new(texel.outputs["Color"], scale.inputs[0])
        tree.links.new(both.outputs[0], scale.inputs["Scale"])
        tree.links.new(scale.outputs[0], emission.inputs["Color"])
    mesh.materials[slot] = baked

OUT.parent.mkdir(parents=True, exist_ok=True)
page_materials = []
for page, low in enumerate(page_objects):
    if low is None:
        page_materials.append(None)
        continue
    image = bpy.data.images.new("bake page %d" % page, BAKE_SIZE, BAKE_SIZE, alpha=False)
    image.colorspace_settings.name = "Non-Color"
    material = bpy.data.materials.new("%s page %d" % (OBJECT, page))
    material.use_nodes = True
    tree = material.node_tree
    tree.nodes.clear()
    texture = tree.nodes.new("ShaderNodeTexImage")
    texture.image = image
    tree.nodes.active = texture
    emission = tree.nodes.new("ShaderNodeEmission")
    tree.links.new(emission.outputs[0], tree.nodes.new("ShaderNodeOutputMaterial").inputs["Surface"])
    low.data.materials.clear()
    low.data.materials.append(material)
    bpy.ops.object.select_all(action="DESELECT")
    source.select_set(True)
    low.select_set(True)
    bpy.context.view_layer.objects.active = low
    bpy.ops.object.bake(type="EMIT")
    # Down to the Falcon's page: 256x256, 15-bit colour, 255 palette entries.
    pixels = np.array(image.pixels[:], np.float32).reshape(BAKE_SIZE, BAKE_SIZE, 4)[::-1, :, :3]
    # Rays that found no surface leave black texels: grow the baked colours
    # into them (the darkest baked shade is half an albedo, never black).
    # Partially covered rays mix with black at seams. The emission material
    # provides a lower bound even for a fully occluded metal surface.
    valid = pixels.max(axis=2) > max(0, min(bake_floors, default=0) - 1/255)
    pixels = pixels.copy()
    for _ in range(BAKE_SIZE // 8):
        if valid.all():
            break
        total = np.zeros_like(pixels)
        count = np.zeros(valid.shape, np.float32)
        for axis, shift in ((0, 1), (0, -1), (1, 1), (1, -1)):
            near = np.roll(valid, shift, axis)
            total += np.roll(pixels, shift, axis) * near[..., None]
            count += near
        grow = ~valid & (count > 0)
        pixels[grow] = total[grow] / count[grow, None]
        valid |= grow
    rgb = Image.fromarray(np.clip(np.rint(pixels * 255), 0, 255).astype(np.uint8), "RGB")
    rgb = rgb.resize((PAGE_SIZE, PAGE_SIZE), Image.LANCZOS)
    five = np.asarray(rgb).astype(np.int32) * 31 // 255
    five = np.maximum(five, 1)                       # palette word 0 is never drawn
    quantized = Image.fromarray((five * 255 // 31).astype(np.uint8), "RGB").quantize(
        255, Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE).convert("RGB")
    five = np.maximum((np.asarray(quantized).astype(np.int32) * 31 + 127) // 255, 1)
    path = OUT.parent / ("%s_page_%d.png" % (OUT.stem, page))
    Image.fromarray((five * 255 // 31).astype(np.uint8), "RGB").save(path)
    bpy.data.images.remove(image)
    final = bpy.data.images.load(str(path))
    final.name = "%s page %d" % (OBJECT, page)
    final.colorspace_settings.name = "Non-Color"
    texture.image = final
    texture.interpolation = "Closest"
    tree.links.new(texture.outputs["Color"], emission.inputs["Color"])
    page_materials.append(material)
    print("baked page %d: %d triangles" % (page, len(low.data.polygons)))

# ------------------------------------------------------------------ copies and join
def mirrored(points, flips):
    """Apply the mirrors that turn the source bone into this copy."""
    points = points.copy()
    for name, target, axis in flips:
        k = "XYZ".index(axis)
        plane = 0.5 * (bones[name].head_local[k] + bones[target].head_local[k])
        points[:, k] = 2 * plane - points[:, k]
    return points


vertices, faces, uvs, face_page, vertex_group = [], [], [], [], []
for page, low in enumerate(page_objects):
    if low is None:
        continue
    me = low.data
    co = np.array([v.co[:] for v in me.vertices])
    part_of_face = np.array([d.value for d in me.attributes["part"].data])
    uv = np.array([d.uv[:] for d in me.uv_layers["PS1 UV"].data])
    for index in sorted(set(part_of_face.tolist())):
        part = parts[index]
        polys = [p for p in me.polygons if part_of_face[p.index] == index]
        used = sorted({v for p in polys for v in p.vertices})
        remap = {old: new for new, old in enumerate(used)}
        for bone, flips in part["copies"]:
            base = len(vertices)
            vertices += mirrored(co[used], flips).tolist()
            vertex_group += [bone] * len(used)
            odd = len(flips) % 2 == 1
            for p in polys:
                corners = list(zip(p.vertices, p.loop_indices))
                if odd:                              # a mirror turns the winding
                    corners.reverse()
                faces.append([base + remap[v] for v, _ in corners])
                uvs.append([uv[loop] for _, loop in corners])
                face_page.append(page)

out_mesh = bpy.data.meshes.new(OBJECT + " low")
out_mesh.from_pydata(vertices, [], faces)
out_mesh.update()
layer = out_mesh.uv_layers.new(name="PS1 UV")
for poly, corner_uvs in zip(out_mesh.polygons, uvs):
    poly.use_smooth = False
    for loop, value in zip(poly.loop_indices, corner_uvs):
        layer.data[loop].uv = np.clip(value, 0.0, 1.0)
slots = {}
for page, material in enumerate(page_materials):
    if material is not None:
        slots[page] = len(out_mesh.materials)
        out_mesh.materials.append(material)
for poly, page in zip(out_mesh.polygons, face_page):
    poly.material_index = slots[page]
low = bpy.data.objects.new(OBJECT + " low", out_mesh)
source_path = Path(bpy.data.filepath)
low["source_blend"] = source_path.name
low["source_mesh_object"] = OBJECT
low["source_vertices"] = len(mesh.vertices)
low["source_sha256"] = hashlib.sha256(source_path.read_bytes()).hexdigest()
collection.objects.link(low)
for bone in sorted(set(vertex_group)):
    group = low.vertex_groups.new(name=bone)
    group.add([i for i, b in enumerate(vertex_group) if b == bone], 1.0, "REPLACE")
low.matrix_world = source.matrix_world
modifier = low.modifiers.new("Armature", "ARMATURE")
modifier.object = rig

for obj in [o for o in page_objects if o is not None] + [source]:
    bpy.data.objects.remove(obj)
for block in (bpy.data.meshes, bpy.data.materials, bpy.data.images):
    for item in list(block):
        if item.users == 0:
            block.remove(item)
print("reduced %s: %d vertices, %d triangles, %d parts, %d with copies" % (
    OBJECT, len(out_mesh.vertices), len(out_mesh.polygons), len(parts),
    sum(1 for p in parts if len(p["copies"]) > 1)))
print("  7V+T = %d words" % (7 * len(out_mesh.vertices) + len(out_mesh.polygons)))
for material in out_mesh.materials:
    next(n.image for n in material.node_tree.nodes if n.type == "TEX_IMAGE").pack()
bpy.ops.wm.save_as_mainfile(filepath=str(OUT), compress=True)
print("saved", OUT)
