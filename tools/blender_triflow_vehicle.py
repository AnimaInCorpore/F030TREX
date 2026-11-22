"""Put a TriFlow-reduced rigid vehicle into a copy of the trail scene, flying the route.

Run: blender -b -Y TREX/scene/trex_trail.blend --python tools/blender_triflow_vehicle.py -- \
         <source.obj> <reduced.obj> <out.blend> [options]

<source.obj> is the detailed model (Y-up OBJ with an MTL of diffuse colours
and optional map_Kd textures). <reduced.obj> is TriFlow's output for that
model after a voxel fuse (OPTIMIZATION.md 6.6k). TriFlow writes in its
voxel-grid coordinates, with the same axes as its input, so the reduced mesh
is mapped back onto the source by matching the bounding boxes.

Options (key=value): name=Vehicle  height=7.5 (metres, source Z extent)
forward=-Y (the source's facing axis in Blender axes)  altitude=4.2 (centre
height above the route, metres)  bob=0.3 (metres)  bob_period (frames; default half the lap)
bank=6.0 (roll per radian of yaw change per frame, capped by max_bank)
max_bank=0.5 (radians)  ambient=0.55 (minimum AO multiplier in the bake)

Steps:
  1. imports both meshes, maps the reduced one onto the source and scales both
     to the height, centred on the object origin;
  2. unwraps the reduced mesh into one 256x256 page and bakes the source's
     diffuse colour (or texture) times ambient occlusion onto it with Cycles;
     the page is quantized to 15-bit colour and 255 palette entries;
  3. gives it the Falcon page material ("Falcon DSP shade") and flat Q12
     corner normals ("ps1_normal");
  4. flies it along the T-Rex's route at the altitude, rolling into turns and
     bobbing. The T-Rex object is removed.
Export the result with make model_export (OPTIMIZATION.md 6.6h).
"""
import math
import sys
from pathlib import Path

import bmesh
import bpy
import numpy as np
from mathutils import Matrix, Vector
from PIL import Image

args = sys.argv[sys.argv.index("--") + 1:]
SOURCE, REDUCED, OUT = args[0], args[1], Path(args[2]).resolve()
opts = dict(a.split("=", 1) for a in args[3:])
NAME = opts.get("name", "Vehicle")
HEIGHT = float(opts.get("height", 7.5))
FORWARD = opts.get("forward", "-Y")
ALTITUDE = float(opts.get("altitude", 4.2))
BOB = float(opts.get("bob", 0.3))
BOB_PERIOD = float(opts.get("bob_period", 48))
BANK = float(opts.get("bank", 6.0))
MAX_BANK = float(opts.get("max_bank", 0.5))
AMBIENT = float(opts.get("ambient", 0.55))
BAKE_SIZE, PAGE_SIZE = 1024, 256

scene = bpy.context.scene
trex = bpy.data.objects["T-Rex"]
ENGINE, WORLD = scene.render.engine, scene.world   # the world carries the backdrop


def fail(message):
    raise SystemExit("blender_triflow_vehicle: " + message)


def build_from_triflow():
    """Steps 1-2 for a TriFlow OBJ: align, scale, unwrap, bake one page."""
    # ------------------------------------------------------------------ source
    before = set(bpy.data.objects)
    bpy.ops.wm.obj_import(filepath=SOURCE, forward_axis="NEGATIVE_Z", up_axis="Y")
    parts = [o for o in bpy.data.objects if o not in before and o.type == "MESH"]
    if not parts:
        fail("no mesh in " + SOURCE)
    bpy.ops.object.select_all(action="DESELECT")
    for part in parts:
        part.select_set(True)
    bpy.context.view_layer.objects.active = parts[0]
    if len(parts) > 1:
        bpy.ops.object.join()
    source = bpy.context.view_layer.objects.active
    source.name = NAME + " source"
    source.data.transform(source.matrix_world)
    source.matrix_world = Matrix.Identity(4)
    src = np.array([v.co[:] for v in source.data.vertices])
    src_lo, src_hi = src.min(0), src.max(0)

    # ------------------------------------------------------------------ reduced mesh
    verts, faces = [], []
    for line in open(REDUCED):
        p = line.split()
        if p and p[0] == "v":
            x, y, z = (float(c) for c in p[1:4])
            verts.append((x, -z, y))                    # OBJ Y-up -> Blender Z-up
        elif p and p[0] == "f":
            faces.append([int(c.split("/")[0]) - 1 for c in p[1:]])
    low_co = np.array(verts)
    low_lo, low_hi = low_co.min(0), low_co.max(0)
    # One uniform scale (least squares over the three extents) and a centre match.
    src_ext, low_ext = src_hi - src_lo, low_hi - low_lo
    fit = float(src_ext @ low_ext / (low_ext @ low_ext))
    low_co = (low_co - (low_lo + low_hi) / 2) * fit + (src_lo + src_hi) / 2
    print("reduced mesh mapped: scale %.5f, extents %s -> source %s" % (
        fit, np.round(low_ext * fit, 3), np.round(src_ext, 3)))
    mesh = bpy.data.meshes.new(NAME)
    mesh.from_pydata([tuple(v) for v in low_co], [], faces)
    low = bpy.data.objects.new(NAME, mesh)
    scene.collection.objects.link(low)
    bm = bmesh.new()
    bm.from_mesh(mesh)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-5 * float(src_ext.max()))
    bmesh.ops.triangulate(bm, faces=bm.faces[:])
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    bm.to_mesh(mesh)
    bm.free()

    # ------------------------------------------------------------------ scale, centre, face -Y
    scale = HEIGHT / float(src_ext[2])
    turn = {"+X": -math.pi / 2, "-X": math.pi / 2, "+Y": math.pi, "-Y": 0.0}[FORWARD]
    centre = Vector(((src_lo + src_hi) / 2).tolist())
    basis = Matrix.Rotation(turn, 4, "Z") @ Matrix.Diagonal((scale, scale, scale, 1)) @ Matrix.Translation(-centre)
    for obj in (source, low):
        obj.data.transform(basis)
    for poly in mesh.polygons:
        poly.use_smooth = False
    print("%s: %d triangles, %d vertices, scale %.4f, size %s m" % (
        NAME, len(mesh.polygons), len(mesh.vertices), scale, tuple(round(d, 2) for d in low.dimensions)))

    # ------------------------------------------------------------------ unwrap
    bpy.ops.object.select_all(action="DESELECT")
    low.select_set(True)
    bpy.context.view_layer.objects.active = low
    mesh.uv_layers.new(name="PS1 UV")
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.uv.smart_project(angle_limit=1.15, island_margin=0.012, area_weight=0.0,
                             correct_aspect=True, scale_to_bounds=False)
    bpy.ops.uv.pack_islands(margin=0.012, rotate=True)
    bpy.ops.object.mode_set(mode="OBJECT")
    uv = np.array([d.uv[:] for d in mesh.uv_layers["PS1 UV"].data])
    if uv.min() < 0 or uv.max() > 1:
        fail("UVs outside 0..1 after packing")

    # ------------------------------------------------------------------ bake
    scene.render.engine = "CYCLES"
    scene.world = None
    scene.cycles.device = "CPU"
    scene.cycles.samples = 24
    scene.cycles.use_denoising = False
    bake = scene.render.bake
    bake.use_selected_to_active = True
    bake.cage_extrusion = 0.02 * HEIGHT
    bake.max_ray_distance = 0.12 * HEIGHT
    bake.margin = 8
    bake.use_clear = True
    floors = []
    for slot, material in enumerate(list(source.data.materials)):
        colour, image = (0.6, 0.6, 0.6), None
        if material and material.node_tree:
            for node in material.node_tree.nodes:
                if node.type == "BSDF_PRINCIPLED":
                    colour = tuple(node.inputs["Base Color"].default_value[:3])
                if node.type == "TEX_IMAGE" and node.image:
                    image = node.image
        floors.append(max(colour) * AMBIENT * 0.5)
        baked = bpy.data.materials.new("bake %d" % slot)
        baked.use_nodes = True
        tree = baked.node_tree
        tree.nodes.clear()
        out = tree.nodes.new("ShaderNodeOutputMaterial")
        emission = tree.nodes.new("ShaderNodeEmission")
        tree.links.new(emission.outputs[0], out.inputs["Surface"])
        occlusion = tree.nodes.new("ShaderNodeAmbientOcclusion")
        occlusion.samples = 16
        occlusion.only_local = True
        occlusion.inputs["Distance"].default_value = 0.05 * HEIGHT
        shade = tree.nodes.new("ShaderNodeMath")
        shade.operation = "MULTIPLY_ADD"
        tree.links.new(occlusion.outputs["AO"], shade.inputs[0])
        shade.inputs[1].default_value, shade.inputs[2].default_value = 1 - AMBIENT, AMBIENT
        albedo = tree.nodes.new("ShaderNodeMix")
        albedo.data_type = "RGBA"
        albedo.blend_type = "MULTIPLY"
        albedo.inputs["Factor"].default_value = 1.0
        albedo.inputs[6].default_value = (1, 1, 1, 1)
        tree.links.new(shade.outputs[0], albedo.inputs[7])
        if image is not None:
            texture = tree.nodes.new("ShaderNodeTexImage")
            texture.image = image
            tree.links.new(texture.outputs["Color"], albedo.inputs[6])
        else:
            albedo.inputs[6].default_value = (*colour, 1.0)
        tree.links.new(albedo.outputs[2], emission.inputs["Color"])
        source.data.materials[slot] = baked

    page = bpy.data.images.new(NAME + " bake", BAKE_SIZE, BAKE_SIZE, alpha=False)
    page.colorspace_settings.name = "Non-Color"
    target = bpy.data.materials.new(NAME + " bake target")
    target.use_nodes = True
    tree = target.node_tree
    tree.nodes.clear()
    node = tree.nodes.new("ShaderNodeTexImage")
    node.image = page
    tree.nodes.active = node
    mesh.materials.clear()
    mesh.materials.append(target)
    bpy.ops.object.select_all(action="DESELECT")
    source.select_set(True)
    low.select_set(True)
    bpy.context.view_layer.objects.active = low
    bpy.ops.object.bake(type="EMIT")

    pixels = np.array(page.pixels[:], np.float32).reshape(BAKE_SIZE, BAKE_SIZE, 4)[::-1, :, :3]
    # Texels whose rays found no surface stay black: grow neighbouring colours in.
    valid = pixels.max(axis=2) > max(0.0, min(floors, default=0.0) - 1 / 255)
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
    five = np.maximum(np.asarray(rgb).astype(np.int32) * 31 // 255, 1)   # word 0 is transparent
    quantized = Image.fromarray((five * 255 // 31).astype(np.uint8), "RGB").quantize(
        255, Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE).convert("RGB")
    five = np.maximum((np.asarray(quantized).astype(np.int32) * 31 + 127) // 255, 1)
    OUT.parent.mkdir(parents=True, exist_ok=True)
    page_path = OUT.parent / ("%s_page.png" % OUT.stem)
    Image.fromarray((five * 255 // 31).astype(np.uint8), "RGB").save(page_path)
    bpy.data.images.remove(page)
    final = bpy.data.images.load(str(page_path))
    final.name = NAME + " page"
    final.colorspace_settings.name = "Non-Color"
    final.pack()
    print("baked page", page_path)
    node.image = final
    bpy.data.objects.remove(source)
    return low


def load_reduced(path, name):
    """A blender_reduce_rigid.py result: its paged mesh, without the rig."""
    path = str(Path(path).resolve())        # libraries.load is relative to the open file
    with bpy.data.libraries.load(path, link=False) as (src, dst):
        if name not in src.objects:
            fail("no object %r in %s" % (name, path))
        dst.objects = [name]
    obj = dst.objects[0]
    scene.collection.objects.link(obj)
    for mod in list(obj.modifiers):
        obj.modifiers.remove(mod)
    obj.vertex_groups.clear()
    obj.parent = None
    world = obj.matrix_world.copy()
    obj.data = obj.data.copy()
    turn = {"+X": -math.pi / 2, "-X": math.pi / 2, "+Y": math.pi, "-Y": 0.0}[FORWARD]
    scale = float(opts.get("scale", 1.0))
    obj.data.transform(Matrix.Rotation(turn, 4, "Z") @ Matrix.Diagonal((scale, scale, scale, 1)) @ world)
    obj.matrix_world = Matrix.Identity(4)
    obj.name = obj.data.name = NAME
    for poly in obj.data.polygons:
        poly.use_smooth = False
    print("%s: %d triangles, %d vertices, %d pages, size %s m" % (
        NAME, len(obj.data.polygons), len(obj.data.vertices), len(obj.data.materials),
        tuple(round(d, 2) for d in obj.dimensions)))
    return obj


def to_falcon(obj):
    """Step 3: each page material becomes a "Falcon DSP shade" material with
    the same image; flat Q12 corner normals; the T-Rex's world-normal nodes."""
    mesh = obj.data
    for slot, material in enumerate(list(mesh.materials)):
        image = next((n.image for n in material.node_tree.nodes
                      if n.type == "TEX_IMAGE" and n.image), None) if material and material.node_tree else None
        if image is None:
            fail("material %r has no page image" % (material.name if material else None))
        image.colorspace_settings.name = "Non-Color"
        if not image.packed_file:
            image.pack()
        falcon = bpy.data.materials.new("%s page %d (Falcon)" % (NAME, slot))
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
        texture = nodes.new("ShaderNodeTexImage")
        texture.image, texture.interpolation = image, "Closest"
        uvnode = nodes.new("ShaderNodeUVMap")
        uvnode.uv_map = "PS1 UV"
        links.new(uvnode.outputs["UV"], texture.inputs["Vector"])
        links.new(texture.outputs["Color"], group.inputs["Colour"])
        mesh.materials[slot] = falcon
    mesh.update()
    normal_attr = mesh.attributes.new("ps1_normal", "FLOAT_VECTOR", "CORNER")
    for poly in mesh.polygons:
        q = [round(c * 4096) / 4096 for c in poly.normal]
        for loop in poly.loop_indices:
            normal_attr.data[loop].vector = q
    gn = next(m for m in trex.modifiers if m.type == "NODES")
    obj.modifiers.new(gn.name, "NODES").node_group = gn.node_group


low = load_reduced(SOURCE, REDUCED) if SOURCE.endswith(".blend") else build_from_triflow()
to_falcon(low)
for block in (bpy.data.meshes, bpy.data.materials, bpy.data.images):
    for item in list(block):
        if item.users == 0:
            block.remove(item)


# ------------------------------------------------------------------ fly the route
route = {}
for curve in trex.animation_data.action.layers[0].strips[0].channelbags[0].fcurves:
    route[(curve.data_path, curve.array_index)] = curve
first, last = scene.frame_start, scene.frame_end
lap = next(m.frame for m in scene.timeline_markers if m.name == "lap")
period = last - lap + 1          # frame last+1 plays as frame lap: last equals lap-1


def loop_frame(f):
    """Frames past the end continue at the lap; before the start, hold."""
    while f > last:
        f -= period
    return max(first, f)


def yaw_at(f):
    return route[("rotation_euler", 2)].evaluate(loop_frame(f))


def rate_at(f):
    # Yaw change per frame, averaged over seven frames so the roll eases in.
    steps = [math.remainder(yaw_at(g + 1) - yaw_at(g), 2 * math.pi) for g in range(f - 3, f + 4)]
    return sum(steps) / len(steps)


bob_period = BOB_PERIOD if "bob_period" in opts else period / 2
frames = list(range(first, last + 1))
low.rotation_mode = "XYZ"
for f in frames:
    yaw, rate = yaw_at(f), rate_at(f)
    x, y = route[("location", 0)].evaluate(f), route[("location", 1)].evaluate(f)
    z = ALTITUDE + BOB * math.sin(2 * math.pi * (f - lap) / bob_period)
    roll = max(-MAX_BANK, min(MAX_BANK, BANK * rate))
    low.location = (x, y, z)
    low.rotation_euler = (0.0, roll, yaw)
    low.keyframe_insert("location", frame=f)
    low.keyframe_insert("rotation_euler", frame=f)
for layer in low.animation_data.action.layers:
    for strip in layer.strips:
        for bag in strip.channelbags:
            for curve in bag.fcurves:
                for point in curve.keyframe_points:
                    point.interpolation = "LINEAR"

bpy.data.objects.remove(trex)
scene.render.engine, scene.world = ENGINE, WORLD
scene.frame_set(scene.frame_start)
bpy.ops.wm.save_as_mainfile(filepath=str(OUT), relative_remap=True, compress=True)
print("saved", OUT)
