"""Turn a multi-object vehicle model into a source for blender_reduce_rigid.py.

Run: blender -b --factory-startup --python tools/blender_vehicle_source.py -- \
         <model.obj> <out.blend> [options]

Options (key=value): name=Vehicle  height=5.0 or length=5.0 (metres: the
Z extent or the longest side after scaling; height wins if both are given)

The OBJ's objects (a 3DS file's named parts) are joined into one mesh,
<name>, centred on the origin and scaled. Each source object becomes a vertex
group, and a rest-pose armature, <name> rig, gets one bone per group at that
group's centre. blender_reduce_rigid.py can then treat the parts like the
bones of a rigid walker: hulls per loose piece, "surfaces=" patterns and
"pages=" patterns by object name, and one bake. Every bone stays at rest,
so the vehicle moves as one body.

Textures Blender cannot read (GIF) are converted to PNG next to <out.blend>.
Next to <out.blend> the script writes <out>_colours.txt. It holds the
"colours=" option, with each material's 8-bit diffuse colour from the MTL.
"""
import sys
from pathlib import Path

import bpy
import numpy as np
from mathutils import Matrix, Vector

args = sys.argv[sys.argv.index("--") + 1:]
SOURCE, OUT = Path(args[0]).resolve(), Path(args[1]).resolve()
opts = dict(a.split("=", 1) for a in args[2:])
NAME = opts.get("name", "Vehicle")

bpy.ops.wm.read_homefile(use_empty=True)
scene = bpy.context.scene
bpy.ops.wm.obj_import(filepath=str(SOURCE), forward_axis="NEGATIVE_Z", up_axis="Y")
parts = [o for o in scene.objects if o.type == "MESH" and len(o.data.polygons)]

# Blender reads no GIF (1990s packs use them): convert unreadable textures to
# PNG next to the output so the bake sees them, not Blender's magenta.
from PIL import Image  # noqa: E402
for image in bpy.data.images:
    path = Path(bpy.path.abspath(image.filepath))
    if tuple(image.size) != (0, 0) or not path.exists():
        continue
    try:
        converted = OUT.parent / (path.stem + "_converted.png")
        OUT.parent.mkdir(parents=True, exist_ok=True)
        Image.open(path).convert("RGB").save(converted)
    except OSError as error:
        print("cannot convert", path, error)
        continue
    replacement = bpy.data.images.load(str(converted))
    image.user_remap(replacement)        # a reloaded GIF block keeps no data
    print("converted", path.name, "->", converted.name, tuple(replacement.size))
if not parts:
    raise SystemExit("blender_vehicle_source: no mesh in %s" % SOURCE)

# One vertex group per source object, named after it (names stay unique).
for part in parts:
    part.data.transform(part.matrix_world)
    part.matrix_world = Matrix.Identity(4)
    group = part.vertex_groups.new(name=part.name)
    group.add(range(len(part.data.vertices)), 1.0, "REPLACE")
bpy.ops.object.select_all(action="DESELECT")
for part in parts:
    part.select_set(True)
bpy.context.view_layer.objects.active = parts[0]
bpy.ops.object.join()
body = bpy.context.view_layer.objects.active
body.name = body.data.name = NAME

co = np.array([v.co[:] for v in body.data.vertices])
lo, hi = co.min(0), co.max(0)
extent = hi - lo
if "height" in opts:
    scale = float(opts["height"]) / extent[2]
elif "length" in opts:
    scale = float(opts["length"]) / extent.max()
else:
    scale = 1.0
body.data.transform(Matrix.Diagonal((scale, scale, scale, 1)) @ Matrix.Translation(-Vector((lo + hi) / 2)))
co = np.array([v.co[:] for v in body.data.vertices])
print("%s: %d source objects, %d triangles, size %s m" % (
    NAME, len(body.vertex_groups), sum(len(p.vertices) - 2 for p in body.data.polygons),
    tuple(np.round(np.ptp(co, axis=0), 2))))

# A rest-pose armature: one bone per part at the part's centre.
weights = {g.index: [] for g in body.vertex_groups}
for v in body.data.vertices:
    for g in v.groups:
        weights[g.group].append(v.index)
arm = bpy.data.armatures.new(NAME + " rig")
rig = bpy.data.objects.new(NAME + " rig", arm)
scene.collection.objects.link(rig)
bpy.context.view_layer.objects.active = rig
bpy.ops.object.mode_set(mode="EDIT")
step = 0.02 * float(np.ptp(co, axis=0).max())
for group in body.vertex_groups:
    bone = arm.edit_bones.new(group.name)
    centre = co[weights[group.index]].mean(0) if weights[group.index] else np.zeros(3)
    bone.head = Vector(centre)
    bone.tail = Vector(centre) + Vector((0, 0, step))
bpy.ops.object.mode_set(mode="OBJECT")
modifier = body.modifiers.new("Armature", "ARMATURE")
modifier.object = rig

# Diffuse colours per material, for blender_reduce_rigid.py's colours= option.
colours = {}
mtl = None
for line in open(SOURCE, encoding="utf-8", errors="replace"):
    if line.startswith("mtllib"):
        mtl = SOURCE.parent / line.split(None, 1)[1].strip()
        break
if mtl and mtl.exists():
    current = None
    for line in open(mtl, encoding="utf-8", errors="replace"):
        p = line.split()
        if p and p[0] == "newmtl":
            current = " ".join(p[1:])
        elif p and p[0] == "Kd" and current:
            colours[current] = tuple(int(round(float(c) * 255)) for c in p[1:4])
names = {m.name for m in body.data.materials if m}
option = "colours=" + ";".join("%s:%d,%d,%d" % (k, *v) for k, v in colours.items() if k in names)
(OUT.parent / (OUT.stem + "_colours.txt")).write_text(option)
OUT.parent.mkdir(parents=True, exist_ok=True)
bpy.ops.wm.save_as_mainfile(filepath=str(OUT), compress=True)
print("saved", OUT, "with", len(colours), "material colours")
