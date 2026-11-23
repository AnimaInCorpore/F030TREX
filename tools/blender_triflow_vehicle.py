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
pages=*  section groups of <reduced.obj> (its usemtl names), one 256x256 page
         each, e.g. pages=Wings_Mat;*  (first matching group wins)
static=<frame>  hold the route position and heading of that frame (no bank,
         no bob) for the whole lap
planar=  sections (patterns) whose faces lie in one plane family, such as a
         TIE's wing panels: faces within planar_angle (degrees, default 35)
         of the area-weighted dominant normal axis are projected onto that
         plane, so every copy along the axis (both wings, front and back)
         shares one island scaled to fill its page. Their other faces (rims,
         struts) move to the last page group, which must be a different page;
         there each gets its own cell in a band at the bottom (strip_band,
         default 0.2 of the height) and the page's own islands take the rest.
two_sided=  sections whose faces get a reversed copy (open panels that the
         source game draws two-sided; the Falcon culls back faces)

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
import fnmatch
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
# Section names come from the reduced OBJ's usemtl lines.
PAGE_GROUPS = [g.split(",") for g in opts.get("pages", "*").split(";") if g]
TWO_SIDED = [g for g in opts.get("two_sided", "").split(",") if g]
PLANAR = [g for g in opts.get("planar", "").split(",") if g]
PLANAR_ANGLE = math.radians(float(opts.get("planar_angle", 35)))
STRIP_BAND = float(opts.get("strip_band", 0.2))
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
    verts, faces, face_section, section = [], [], [], ""
    for line in open(REDUCED):
        p = line.split()
        if p and p[0] == "v":
            x, y, z = (float(c) for c in p[1:4])
            verts.append((x, -z, y))                    # OBJ Y-up -> Blender Z-up
        elif p and p[0] == "usemtl":
            section = " ".join(p[1:])
        elif p and p[0] == "f":
            faces.append([int(c.split("/")[0]) - 1 for c in p[1:]])
            face_section.append(section)
    sections = sorted(set(face_section))
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
    # Each face keeps its section (an index into sections) through the bmesh edits.
    mesh.attributes.new("section", "INT", "FACE").data.foreach_set(
        "value", [sections.index(f) for f in face_section])
    low = bpy.data.objects.new(NAME, mesh)
    scene.collection.objects.link(low)
    bm = bmesh.new()
    bm.from_mesh(mesh)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-5 * float(src_ext.max()))
    bmesh.ops.triangulate(bm, faces=bm.faces[:])
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    bm.to_mesh(mesh)
    bm.free()
    if TWO_SIDED:
        # Open single-sided panels (the game draws them two-sided; the Falcon
        # culls back faces) get a reversed copy on the SAME vertices: normals
        # and UVs are per corner, so no vertex is added (bmesh refuses such
        # duplicate faces, the plain mesh API does not).
        co = [v.co[:] for v in mesh.vertices]
        polys = [list(p.vertices) for p in mesh.polygons]
        sec = np.zeros(len(polys), int)
        mesh.attributes["section"].data.foreach_get("value", sec)
        flip = [i for i, k in enumerate(sec) if any(fnmatch.fnmatchcase(sections[k], p) for p in TWO_SIDED)]
        polys += [polys[i][::-1] for i in flip]
        sec = np.concatenate([sec, sec[flip]])
        mesh.clear_geometry()
        mesh.from_pydata(co, [], polys)
        mesh.attributes.new("section", "INT", "FACE").data.foreach_set("value", sec.tolist())
        mesh.update()
        print("two-sided: %d faces doubled on shared vertices" % len(flip))

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
    # One bake target material (and page) per section group; a face takes the
    # first group with a matching pattern.
    face_sections = np.zeros(len(mesh.polygons), int)
    mesh.attributes["section"].data.foreach_get("value", face_sections)
    page_of = [next((i for i, g in enumerate(PAGE_GROUPS)
                     if any(fnmatch.fnmatchcase(sec, p) for p in g)), len(PAGE_GROUPS) - 1)
               for sec in sections]
    face_page = [page_of[i] for i in face_sections]
    planar_face = np.zeros(len(mesh.polygons), bool)
    strip_face = np.zeros(len(mesh.polygons), bool)
    planar_pages = set()
    if PLANAR:
        # One shared planar island: the faces of the named sections that
        # face the dominant axis. The rest of those sections go to the last
        # page group, so the planar page holds nothing else.
        normals = np.array([poly.normal[:] for poly in mesh.polygons])
        areas = np.array([poly.area for poly in mesh.polygons])
        named = np.array([any(fnmatch.fnmatchcase(sections[k], p) for p in PLANAR) for k in face_sections])
        if not named.any():
            fail("planar=%s matches no section" % ",".join(PLANAR))
        weighted = normals[named] * areas[named, None]
        planar_axis = np.linalg.eigh(weighted.T @ normals[named])[1][:, -1]
        planar_face = named & (np.abs(normals @ planar_axis) >= math.cos(PLANAR_ANGLE))
        rest = len(PAGE_GROUPS) - 1
        planar_pages = {face_page[i] for i in np.nonzero(planar_face)[0]}
        if rest in planar_pages:
            fail("planar faces need their own page group before the last one")
        for i in range(len(face_page)):
            if face_page[i] in planar_pages and not planar_face[i]:
                face_page[i] = rest
        # The moved faces are mostly long thin rims whose hollow islands
        # would set the scale of the whole last page: they get one cell
        # each in a band at its bottom instead (STRIP_BAND of the height).
        strip_face = named & ~planar_face
        print("planar: %d faces about axis %s, %d moved to the last page" % (
            planar_face.sum(), tuple(np.round(planar_axis, 3)), (named & ~planar_face).sum()))
    pages_used = sorted(set(face_page))
    mesh.materials.clear()
    targets = []
    for k, page_index in enumerate(pages_used):
        target = bpy.data.materials.new(NAME + " bake target" + ("" if len(pages_used) == 1 else " %d" % k))
        target.use_nodes = True
        target.node_tree.nodes.clear()
        mesh.materials.append(target)
        targets.append(target)
    for poly, page_index in zip(mesh.polygons, face_page):
        poly.material_index = pages_used.index(page_index)
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.context.tool_settings.mesh_select_mode = (False, False, True)
    edit = bmesh.from_edit_mesh(mesh)
    edit.faces.ensure_lookup_table()

    def select_faces(keep):
        for face in edit.faces:
            face.select_set(False)
        for face in edit.faces:
            if keep(face):
                face.select_set(True)
        edit.select_flush_mode()
        bmesh.update_edit_mesh(mesh)

    for k in range(len(pages_used)):
        if pages_used[k] in planar_pages:
            continue
        strips = strip_face.any() and k == len(pages_used) - 1
        select_faces(lambda f: f.material_index == k and not (strips and strip_face[f.index]))
        bpy.ops.uv.smart_project(angle_limit=1.15, island_margin=0.012, area_weight=0.0,
                                 correct_aspect=True, scale_to_bounds=False)
        bpy.ops.uv.pack_islands(margin=0.012, rotate=True)
        if strips:
            select_faces(lambda f: strip_face[f.index])
            bpy.ops.uv.lightmap_pack(PREF_CONTEXT="SEL_FACES", PREF_PACK_IN_ONE=True,
                                     PREF_NEW_UVLAYER=False, PREF_MARGIN_DIV=0.2)
            edit = bmesh.from_edit_mesh(mesh)
            edit.faces.ensure_lookup_table()
            layer = edit.loops.layers.uv["PS1 UV"]
            for face in edit.faces:
                if face.material_index != k:
                    continue
                for corner in face.loops:
                    u, v = corner[layer].uv
                    corner[layer].uv = ((u, v * STRIP_BAND) if strip_face[face.index]
                                        else (u, STRIP_BAND + v * (1 - STRIP_BAND)))
            bmesh.update_edit_mesh(mesh)
    bpy.ops.object.mode_set(mode="OBJECT")
    if planar_face.any():
        e1 = np.cross(planar_axis, (0, 0, 1) if abs(planar_axis[2]) < 0.9 else (1, 0, 0))
        e1 /= np.linalg.norm(e1)
        e2 = np.cross(planar_axis, e1)
        loops = [l for poly in mesh.polygons if planar_face[poly.index] for l in poly.loop_indices]
        co = np.array([mesh.vertices[mesh.loops[l].vertex_index].co[:] for l in loops])
        flat = np.stack([co @ e1, co @ e2], 1)
        lo, hi = flat.min(0), flat.max(0)
        flat = (flat - (lo + hi) / 2) / (hi - lo).max() * (1 - 2 * 0.012) + 0.5
        layer = mesh.uv_layers["PS1 UV"].data
        for l, (u, v) in zip(loops, flat):
            layer[l].uv = (u, v)
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
            # Raw texel values, as the MTL colours above: the page is shown
            # as-is (Non-Color), so an sRGB decode here would bake every
            # texture about half as bright.
            image.colorspace_settings.name = "Non-Color"
            texture = tree.nodes.new("ShaderNodeTexImage")
            texture.image = image
            tree.links.new(texture.outputs["Color"], albedo.inputs[6])
        else:
            albedo.inputs[6].default_value = (*colour, 1.0)
        tree.links.new(albedo.outputs[2], emission.inputs["Color"])
        source.data.materials[slot] = baked

    bake_nodes = []
    for k, target in enumerate(targets):
        page = bpy.data.images.new(NAME + " bake" + ("" if len(targets) == 1 else " %d" % k),
                                   BAKE_SIZE, BAKE_SIZE, alpha=False)
        page.colorspace_settings.name = "Non-Color"
        node = target.node_tree.nodes.new("ShaderNodeTexImage")
        node.image = page
        target.node_tree.nodes.active = node
        bake_nodes.append(node)
    bpy.ops.object.select_all(action="DESELECT")
    source.select_set(True)
    low.select_set(True)
    bpy.context.view_layer.objects.active = low
    bpy.ops.object.bake(type="EMIT")

    for k, node in enumerate(bake_nodes):
        page = node.image
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
        page_path = OUT.parent / ("%s_page%s.png" % (OUT.stem, "" if len(bake_nodes) == 1 else "_%d" % k))
        Image.fromarray((five * 255 // 31).astype(np.uint8), "RGB").save(page_path)
        bpy.data.images.remove(page)
        final = bpy.data.images.load(str(page_path))
        final.name = NAME + " page" + ("" if len(bake_nodes) == 1 else " %d" % k)
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
STATIC = int(opts["static"]) if "static" in opts else None
for f in frames:
    g = STATIC if STATIC is not None else f      # static=<frame>: hold that route pose
    yaw, rate = yaw_at(g), rate_at(g)
    x, y = route[("location", 0)].evaluate(g), route[("location", 1)].evaluate(g)
    z = ALTITUDE + (0.0 if STATIC is not None else BOB * math.sin(2 * math.pi * (f - lap) / bob_period))
    roll = 0.0 if STATIC is not None else max(-MAX_BANK, min(MAX_BANK, BANK * rate))
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
