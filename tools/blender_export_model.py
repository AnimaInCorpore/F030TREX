"""Export a Blender mesh as a Falcon model directory (OPTIMIZATION.md 6.6h).

Run: blender -b <file.blend> --python tools/blender_export_model.py -- <object> <model dir> [tag]

Writes the formats the existing pipeline already reads, so the host, the DSP
and the node tools stay unchanged:

  trex.tmd                    PS1 TMD: vertices, Q12 corner normals, textured
                              (mode 0x34) and untextured (mode 0x30) triangles
  trex.obj                    the same mesh in trex.obj's convention (Y negated,
                              per-corner normals, a 768x512 atlas of the six
                              pages); `make` turns it into trex.o3d and the
                              per-polygon sidecars
  trex_texture_page_NN.tim    six 8-bit 256x256 pages with 256-entry CLUTs
  model.inc / model.mk        mesh sizes for the host, the DSP and make

Build with:  make MODEL_DIR=<model dir> trex_m68030_hires_backdrop_run
(the scene exporter, tools/blender_export_falcon.py, writes the trail assets
into the same directory).

The mesh is the object's basis shape with its modifiers applied (add a
Decimate modifier to meet the budget), triangulated. Corner normals come
from a "ps1_normal" corner attribute when present, else Blender's own.
Each material uses the first image texture in its node tree as one page
(at most six; resized to 256x256, quantized to 15-bit colour and at most
256 palette entries, alpha below one half transparent). A material without
an image is untextured: its colour comes from a "ps1_colour" corner attribute
or the material's base colour. UVs must lie inside 0..1 (pages do not tile).

The DSP RAM budget (computed from trex_dsp.asm's allocations): Y holds
3T + 2*Ny <= 13,888 words, X holds 7V + T + 2*Nx below CHUNK_UVS_BASE,
14,647 words in the 640x400 images. Index fields cap V <= 2,048 and
N, T <= 4,096. The script splits the normals between the banks and refuses a
model that does not fit; the DSP assembler checks the X layout again.
"""
import os
import re
import struct
import sys
from pathlib import Path

import bmesh
import bpy
import numpy as np
from PIL import Image

args = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
if len(args) < 2:
    raise SystemExit(__doc__)
OBJECT, OUT = args[0], Path(args[1])
ROOT = Path(__file__).resolve().parents[1]     # model.mk paths are relative to the Makefile
TAG = args[2] if len(args) > 2 else re.sub(r"[^a-z0-9]", "", OBJECT.lower())[:8] or "model"
PAGES = (10, 12, 14, 26, 28, 30)
TO_BLENDER = np.array([[1, 0, 0], [0, 0, 1], [0, -1, 0]], float)
LOCAL = np.diag([1.0, -1.0, 1.0]) @ TO_BLENDER      # PS1 model -> Blender mesh axes
Y_WINDOW, X_WINDOW_HIRES = 13888, 14647
MAX_VERTICES, MAX_INDEX = 2048, 4096


def fail(message):
    raise SystemExit("blender_export_model: " + message)


scene = bpy.context.scene
scale = 1.0 / scene.get("falcon_units_per_metre", 2150)
obj = bpy.data.objects.get(OBJECT)
if obj is None or obj.type != "MESH":
    fail("no mesh object named %r" % OBJECT)

# ------------------------------------------------------------------ mesh
# The basis shape with the modifiers: pose shape keys belong to the scene.
keys = obj.data.shape_keys
saved = (obj.show_only_shape_key, obj.active_shape_key_index)
obj.show_only_shape_key, obj.active_shape_key_index = True, 0
evaluated = obj.evaluated_get(bpy.context.evaluated_depsgraph_get())
mesh = bpy.data.meshes.new_from_object(evaluated)
obj.show_only_shape_key, obj.active_shape_key_index = saved
if any(len(p.vertices) != 3 for p in mesh.polygons):
    bm = bmesh.new()
    bm.from_mesh(mesh)
    bmesh.ops.triangulate(bm, faces=bm.faces[:], quad_method="BEAUTY", ngon_method="BEAUTY")
    bm.to_mesh(mesh)
    bm.free()

vertex_count, triangle_count = len(mesh.vertices), len(mesh.polygons)
coords = np.array([v.co[:] for v in mesh.vertices]) / scale @ LOCAL
vertices = np.rint(coords).astype(np.int64)
if np.abs(vertices).max() > 32767:
    fail("the model spans more than 16-bit model units at %g units/metre" % (1 / scale))

if "ps1_normal" in mesh.attributes and mesh.attributes["ps1_normal"].domain == "CORNER":
    # Already PS1 Q12 values; they are not exactly unit length, so keep them.
    corner_normals = np.array([d.vector[:] for d in mesh.attributes["ps1_normal"].data]) @ LOCAL
else:
    corner_normals = np.array([n.vector[:] for n in mesh.corner_normals]) @ LOCAL
    corner_normals /= np.linalg.norm(corner_normals, axis=1, keepdims=True)
q12 = np.clip(np.rint(corner_normals * 4096), -4096, 4096).astype(np.int64)
normal_index, normals = {}, []
for value in map(tuple, q12):
    if value not in normal_index:
        normal_index[value] = len(normals)
        normals.append(value)
normal_count = len(normals)

# ------------------------------------------------------------------ budget
# Both banks keep at least one normal: the DSP assembler rejects "ds 0".
if normal_count < 2:
    fail("the model needs at least two distinct corner normals")
normal_y = min(normal_count - 1, (Y_WINDOW - 3 * triangle_count) // 2)
normal_x = normal_count - normal_y
x_words = 7 * vertex_count + triangle_count + 2 * normal_x
budget = ("V=%d T=%d N=%d: Y %d/%d words, X %d/%d words" % (
    vertex_count, triangle_count, normal_count, 3 * triangle_count + 2 * normal_y, Y_WINDOW,
    x_words, X_WINDOW_HIRES))
if vertex_count > MAX_VERTICES or triangle_count > MAX_INDEX or normal_count > MAX_INDEX:
    fail("index fields allow V <= 2048, T and N <= 4096; " + budget)
if normal_y < 0 or x_words > X_WINDOW_HIRES:
    fail("the model does not fit the DSP RAM (decimate it); " + budget)

# ------------------------------------------------------------------ materials and pages
def material_image(material):
    if material is None or not material.node_tree:
        return None
    images = [n.image for n in material.node_tree.nodes if n.type == "TEX_IMAGE" and n.image]
    return images[0] if images else None


def material_colour(material):
    if material is None:
        return (200, 200, 200)
    colour = material.diffuse_color
    if material.node_tree:
        for node in material.node_tree.nodes:
            if node.type == "BSDF_PRINCIPLED":
                colour = node.inputs["Base Color"].default_value
    return tuple(int(round(max(0.0, min(1.0, c)) * 255)) for c in colour[:3])


materials = list(obj.data.materials) or [None]
page_of_image, page_images = {}, []
for material in materials:
    image = material_image(material)
    if image is not None and image.name not in page_of_image:
        page_of_image[image.name] = len(page_images)
        page_images.append(image)
if len(page_images) > len(PAGES):
    fail("%d texture images; the renderer holds six 256x256 pages" % len(page_images))


def page_pixels(image):
    """256x256 RGBA bytes, top row first."""
    width, height = image.size
    pixels = np.array(image.pixels[:], np.float32).reshape(height, width, image.channels)[::-1]
    if image.channels == 3:
        pixels = np.dstack([pixels, np.ones((height, width), np.float32)])
    rgba = Image.fromarray(np.clip(np.rint(pixels * 255), 0, 255).astype(np.uint8), "RGBA")
    if rgba.size != (256, 256):
        rgba = rgba.resize((256, 256), Image.LANCZOS)
    return np.asarray(rgba)


def write_tim(path, slot, indices, clut):
    data = struct.pack("<II", 0x10, 9)
    data += struct.pack("<I4H", 12 + 512, 0, 480 + slot, 256, 1) + clut.astype("<u2").tobytes()
    data += struct.pack("<I4H", 12 + 65536, 640 + 128 * (slot % 3), 256 * (slot // 3), 128, 256)
    data += indices.astype(np.uint8).tobytes()
    path.write_bytes(data)


OUT.mkdir(parents=True, exist_ok=True)
for slot in range(len(PAGES)):
    if slot < len(page_images):
        rgba = page_pixels(page_images[slot])
        opaque = rgba[..., 3] >= 128
        bgr = ((rgba[..., 0].astype(np.int32) * 31 + 127) // 255
               | ((rgba[..., 1].astype(np.int32) * 31 + 127) // 255) << 5
               | ((rgba[..., 2].astype(np.int32) * 31 + 127) // 255) << 10)
        bgr = np.where(bgr == 0, 0x8000, bgr)          # opaque black keeps a non-zero word
        words = np.where(opaque, bgr, 0)
        unique = list(dict.fromkeys(words.ravel().tolist()))
        if 0 in unique:                                  # transparent sits at index 0
            unique.remove(0)
            unique.insert(0, 0)
        if len(unique) > 256:
            quantized = Image.fromarray(rgba[..., :3]).quantize(255, Image.Quantize.MEDIANCUT,
                                                                dither=Image.Dither.NONE)
            palette = np.array(quantized.getpalette()[:255 * 3]).reshape(-1, 3)
            colours = ((palette[:, 0] * 31 + 127) // 255 | ((palette[:, 1] * 31 + 127) // 255) << 5
                       | ((palette[:, 2] * 31 + 127) // 255) << 10)
            colours = np.where(colours == 0, 0x8000, colours)
            clut = np.zeros(256, np.int64)
            clut[1:256] = colours
            indices = np.where(opaque, np.asarray(quantized) + 1, 0)
        else:
            clut = np.zeros(256, np.int64)
            clut[:len(unique)] = unique
            lookup = {w: i for i, w in enumerate(unique)}
            indices = np.vectorize(lookup.get)(words)
    else:
        clut, indices = np.zeros(256, np.int64), np.zeros((256, 256), np.int64)
        clut[0] = 0x8000
    write_tim(OUT / ("trex_texture_page_%d.tim" % PAGES[slot]), slot, indices, clut)

# ------------------------------------------------------------------ triangles
uv_layer = mesh.uv_layers.active.data if mesh.uv_layers.active else None
colour_attr = mesh.attributes.get("ps1_colour")
triangles = []
for poly in mesh.polygons:
    material = materials[poly.material_index] if poly.material_index < len(materials) else None
    image = material_image(material)
    loops = list(poly.loop_indices)
    entry = dict(vertices=list(poly.vertices), normals=[normal_index[tuple(q12[l])] for l in loops])
    if image is not None and uv_layer is not None:
        slot = page_of_image[image.name]
        uvs = []
        for loop in loops:
            u, v = uv_layer[loop].uv
            if not (-1e-4 <= u <= 1 + 1e-4 and -1e-4 <= v <= 1 + 1e-4):
                fail("triangle %d has UVs outside 0..1 (pages do not tile)" % poly.index)
            uvs.append((min(255, max(0, round(u * 256))), min(255, max(0, round((1 - v) * 256)))))
        entry.update(slot=slot, uv=uvs)
    else:
        if colour_attr is not None and colour_attr.domain == "CORNER":
            entry["colour"] = tuple(int(round(c * 255)) for c in colour_attr.data[loops[0]].color[:3])
        else:
            entry["colour"] = material_colour(material)
    triangles.append(entry)

# ------------------------------------------------------------------ TMD
primitives = bytearray()
for t in triangles:
    pairs = [x for n, v in zip(t["normals"], t["vertices"]) for x in (n, v)]
    if "slot" in t:
        slot = t["slot"]
        (u0, v0), (u1, v1), (u2, v2) = t["uv"]
        cba, tsb = (480 + slot) << 6, PAGES[slot] | 0x80
        primitives += struct.pack("<4B", 9, 6, 0, 0x34)
        primitives += struct.pack("<BBHBBHBBH", u0, v0, cba, u1, v1, tsb, u2, v2, 0)
    else:
        primitives += struct.pack("<4B", 6, 4, 0, 0x30) + struct.pack("<4B", *t["colour"], 0x30)
    primitives += struct.pack("<6H", *pairs)
vertex_block = b"".join(struct.pack("<4h", *v, 0) for v in vertices.tolist())
normal_block = b"".join(struct.pack("<4h", *n, 0) for n in normals)
prim_top = 28
vert_top = prim_top + len(primitives)
normal_top = vert_top + len(vertex_block)
tmd = struct.pack("<3I", 0x41, 0, 1) + struct.pack("<7I", vert_top, vertex_count, normal_top,
                                                   normal_count, prim_top, triangle_count, 0)
(OUT / "trex.tmd").write_bytes(tmd + primitives + vertex_block + normal_block)

# ------------------------------------------------------------------ OBJ (trex.obj's convention)
lines = ["# %s exported by tools/blender_export_model.py" % OBJECT, "o %s" % OBJECT]
lines += ["v %d %d %d" % (x, -y, z) for x, y, z in vertices.tolist()]
lines += ["vn %.8f %.8f %.8f" % (x / 4096, -y / 4096, z / 4096) for x, y, z in normals]
faces, texcoords, current = [], [], None
for t in triangles:
    material = "Color0" if "slot" in t else "Color1"
    if material != current:
        faces.append("usemtl " + material)
        current = material
    corners = []
    for corner in range(3):
        v, n = t["vertices"][corner] + 1, t["normals"][corner] + 1
        if "slot" in t:
            u, vv = t["uv"][corner]
            slot = t["slot"]
            texcoords.append("vt %.8f %.8f" % (((slot % 3) * 256 + u) / 768,
                                              (512 - ((slot // 3) * 256 + vv)) / 512))
            corners.append("%d/%d/%d" % (v, len(texcoords), n))
        else:
            corners.append("%d//%d" % (v, n))
    faces.append("f " + " ".join(corners))
(OUT / "trex.obj").write_text("\n".join(lines + texcoords + faces) + "\n", encoding="utf-8")

# ------------------------------------------------------------------ sizes
(OUT / "model.inc").write_text(
    "; %s, exported by tools/blender_export_model.py (see TREX/model/model.inc).\n"
    "TREX_VERTICES\t\t= %d\nTREX_NORMALS\t\t= %d\nTREX_PRIMITIVES\t\t= %d\nTREX_TMD_NORMALS\t= %d\n"
    "TMD_VERTEX_DATA_OFFSET\t= $%x\nTMD_NORMAL_DATA_OFFSET\t= $%x\nMODEL_PS1_TREX\t\t= 0\n" % (
        OBJECT, vertex_count, normal_count, triangle_count, normal_count, 12 + vert_top, 12 + normal_top),
    encoding="utf-8")
(OUT / "model.mk").write_text(
    "# %s, exported by tools/blender_export_model.py (see TREX/model/model.mk).\n"
    "MODEL_TAG=%s\nMODEL_VERTICES=%d\nMODEL_PRIMITIVES=%d\nMODEL_NORMALS=%d\nMODEL_NORMAL_Y=%d\n"
    "MODEL_TEXTURES=./%s\n" % (OBJECT, TAG, vertex_count, triangle_count, normal_count, normal_y,
                               Path(os.path.relpath(OUT.resolve(), ROOT)).as_posix()), encoding="utf-8")
bpy.data.meshes.remove(mesh)
print("model %s -> %s (tag %s)" % (OBJECT, OUT, TAG))
print("  " + budget + ", %d normals in Y" % normal_y)
print("  %d texture pages, %d untextured triangles" % (
    len(page_images), sum(1 for t in triangles if "slot" not in t)))
