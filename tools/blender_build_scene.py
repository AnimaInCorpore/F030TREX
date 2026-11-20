"""Build the Blender source scene of the 640x400 trail from seed data.

Run:  blender -b --factory-startup --python tools/blender_build_scene.py -- <seed data> <scene dir> [fps]

<seed data> comes from tools/blender_seed_data.py. The scene, its textures
and the pose cache are written to <scene dir> (TREX/scene). From then on the
scene is the source: tools/blender_export_falcon.py turns it into the Falcon
assets (OPTIMIZATION.md 6.6g).

What the scene holds, and how the exporter reads it back:
  T-Rex          TMD mesh (mirrored, see blender_seed_data.py), keyed location
                 and rotation per frame; one "pose NNN" shape key per sample.
                 Shape keys named "DSP ..." become DSP morph targets with
                 per-frame Q12 weights; any other deformation (pose keys,
                 armatures, modifiers) is baked into the per-sample XYZ16 pose.
  Camera         fixed lens and pixel aspect of the 640x400 mode.
  Ground shadow  ellipse on the ground; scale = half-axes, three ring radii
                 in its material. It darkens the backdrop with the host's
                 integer arithmetic.
  Lights         camera-fixed world-space vectors and ambient in the
                 "Falcon DSP shade" node group; the 4x16 ramp image.
  Backdrop       the RGB565 picture as the world background.
  Markers        "lap": the first sample of the repeating patrol.
EEVEE renders emission only, with the Raw view transform, so pixel values
are the framebuffer's.
"""
import json
import math
import shutil
import sys
from pathlib import Path

import bpy
import numpy as np
from mathutils import Matrix, Vector

args = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
SEED, OUT = Path(args[0]).resolve(), Path(args[1]).resolve()
FPS = int(args[2]) if len(args) > 2 else 12
OUT.mkdir(parents=True, exist_ok=True)
data = json.loads((SEED / "trex_trail.json").read_text(encoding="utf-8"))
for name in ["backdrop.png", "shade_ramp.png"] + \
        ["page_%d.png" % p for p in (10, 12, 14, 26, 28, 30)]:
    shutil.copyfile(SEED / name, OUT / name)
count = data["sample_count"]
width, height = data["resolution"]
focal_x, focal_y = data["focal"]

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
scene.name = "T-Rex trail"
scene["falcon_units_per_metre"] = data["units_per_metre"]
render = scene.render
render.engine = "BLENDER_EEVEE"
render.resolution_x, render.resolution_y, render.resolution_percentage = width, height, 100
# A 640x400 pixel is focal_y/focal_x as wide as it is tall.
render.pixel_aspect_x, render.pixel_aspect_y = 1.0, focal_x / focal_y
render.fps, render.fps_base = FPS, 1.0
render.filter_size = 0.0
render.film_transparent = False
render.image_settings.file_format = "PNG"
render.filepath = "//render/frame_"
scene.frame_start, scene.frame_end = 1, count
scene.view_settings.view_transform = "Raw"
scene.view_settings.look = "None"
scene.view_settings.exposure, scene.view_settings.gamma = 0.0, 1.0
for name, value in (("taa_render_samples", 1), ("taa_samples", 1), ("use_shadows", False),
                    ("use_raytracing", False), ("use_gtao", False)):
    if hasattr(scene.eevee, name):
        setattr(scene.eevee, name, value)
scene.timeline_markers.new("lap", frame=data["lap_start"] + 1)


def image(name, filepath):
    img = bpy.data.images.load(str(OUT / filepath))
    img.name = name
    img.colorspace_settings.name = "Non-Color"
    img.alpha_mode = "STRAIGHT"
    return img


backdrop_image = image("backdrop", "backdrop.png")

# ---------------------------------------------------------------- camera
cam_data = bpy.data.cameras.new("Falcon 640x400")
cam_data.sensor_fit = "HORIZONTAL"
cam_data.sensor_width = 36.0
cam_data.lens = focal_x / width * cam_data.sensor_width
cam_data.clip_start, cam_data.clip_end = 0.05, 500.0
assert data["centre"] == [width // 2, height // 2], "an off-centre lens needs a camera shift"
camera = bpy.data.objects.new("Camera", cam_data)
camera.matrix_world = Matrix.Translation(Vector(data["camera"]["location"])) @ \
    Matrix(data["camera"]["rotation"]).to_4x4()
scene.collection.objects.link(camera)
scene.camera = camera


# ---------------------------------------------------------------- node helpers
class Nodes:
    def __init__(self, tree):
        self.nodes, self.links = tree.nodes, tree.links

    def new(self, kind, **settings):
        node = self.nodes.new(kind)
        for key, value in settings.items():
            setattr(node, key, value)
        return node

    def feed(self, node, sockets):
        for socket, value in sockets:
            if value is None:
                continue
            if isinstance(value, bpy.types.NodeSocket):
                self.links.new(value, node.inputs[socket])
            else:
                node.inputs[socket].default_value = value

    def math(self, op, a, b=None, name=None):
        node = self.new("ShaderNodeMath", operation=op)
        if name:
            node.name = node.label = name
        self.feed(node, ((0, a), (1, b)))
        return node.outputs[0]

    def vec(self, op, a, b=None):
        node = self.new("ShaderNodeVectorMath", operation=op)
        self.feed(node, ((0, a), (1, b)))
        # Blender 5 keeps only the outputs an operation produces.
        wanted = "Value" if op in ("LENGTH", "DOT_PRODUCT", "DISTANCE") else "Vector"
        return next((o for o in node.outputs if o.name == wanted and o.enabled), node.outputs[0])

    def rounded(self, value, scale):
        """floor(value * scale + 0.5) per component."""
        return self.vec("FLOOR", self.vec("ADD", self.vec("MULTIPLY", value, (scale,) * 3), (0.5,) * 3))


# ---------------------------------------------------------------- mesh
m = data["mesh"]
mesh = bpy.data.meshes.new("T-Rex")
mesh.from_pydata(m["vertices"], [], m["triangles"])
mesh.update()
assert len(mesh.polygons) == len(m["triangles"])
uv = mesh.uv_layers.new(name="PS1 UV")
normal_attr = mesh.attributes.new("ps1_normal", "FLOAT_VECTOR", "CORNER")
colour_attr = mesh.attributes.new("ps1_colour", "FLOAT_COLOR", "CORNER")
pages = sorted({p for p in m["pages"] if p is not None})
for poly, page, uvs, normals, colour in zip(mesh.polygons, m["pages"], m["uvs"],
                                             m["corner_normals"], m["colours"]):
    poly.material_index = pages.index(page) if page is not None else len(pages)
    poly.use_smooth = True
    for corner, loop in enumerate(poly.loop_indices):
        normal_attr.data[loop].vector = normals[corner]
        if uvs:
            u, v = uvs[corner]
            uv.data[loop].uv = (u / 256.0, 1.0 - v / 256.0)
        rgb = [c / 255.0 for c in colour] if colour else [1.0, 1.0, 1.0]
        colour_attr.data[loop].color = (*rgb, 1.0)
trex = bpy.data.objects.new("T-Rex", mesh)
scene.collection.objects.link(trex)
trex.rotation_mode = "XYZ"

# PS1 morph targets as shape keys, off by default. Keys named "DSP ..." are
# exported as DSP targets (static deltas, per-frame weight).
trex.shape_key_add(name="Basis", from_mix=False)
for target in data["targets"]:
    key = trex.shape_key_add(name="DSP " + target["name"], from_mix=False)
    key.value, key.slider_min, key.slider_max = 0.0, -7.99, 7.99
    for offset, delta in enumerate(target["deltas"]):
        index = target["first"] + offset
        key.data[index].co = Vector(m["vertices"][index]) + Vector(delta)

# One shape key per displayed sample holds its baked pose, keyed to 1 on its
# own frame and 0 on its neighbours. Shape keys add exactly; a Mesh Cache
# modifier in "integrate" mode would not (it moves vertices by up to 11 units).
cache = np.fromfile(SEED / "trex_trail.pc2", "<f4", offset=32).reshape(count, len(m["vertices"]), 3)
pose_keys = []
for sample in range(count):
    key = trex.shape_key_add(name="pose %03d" % sample, from_mix=False)
    key.data.foreach_set("co", cache[sample].ravel())
    pose_keys.append(key)

# The DSP lights static corner normals; EEVEE needs them in world space, and
# its shader-side Vector Transform returns a constant for this attribute, so
# geometry nodes rotate them by the object's own rotation.
gn = bpy.data.node_groups.new("PS1 normals to world", "GeometryNodeTree")
gn.interface.new_socket("Geometry", in_out="INPUT", socket_type="NodeSocketGeometry")
gn.interface.new_socket("Geometry", in_out="OUTPUT", socket_type="NodeSocketGeometry")
g = Nodes(gn)
group_in, group_out = g.new("NodeGroupInput"), g.new("NodeGroupOutput")
info = g.new("GeometryNodeObjectInfo", transform_space="ORIGINAL")
g.links.new(g.new("GeometryNodeSelfObject").outputs[0], info.inputs["Object"])
named = g.new("GeometryNodeInputNamedAttribute", data_type="FLOAT_VECTOR")
named.inputs["Name"].default_value = "ps1_normal"
rotate = g.new("FunctionNodeRotateVector")
g.links.new(named.outputs["Attribute"], rotate.inputs["Vector"])
g.links.new(info.outputs["Rotation"], rotate.inputs["Rotation"])
store = g.new("GeometryNodeStoreNamedAttribute", data_type="FLOAT_VECTOR", domain="CORNER")
store.inputs["Name"].default_value = "ps1_normal_world"
g.links.new(group_in.outputs[0], store.inputs["Geometry"])
g.links.new(rotate.outputs[0], store.inputs["Value"])
g.links.new(store.outputs[0], group_out.inputs[0])
trex.modifiers.new("PS1 normals to world", "NODES").node_group = gn


# ---------------------------------------------------------------- shading
def shade_group():
    """make_triangle_shade's light model and the host's preshaded CLUT banks."""
    lights = data["lights"]
    group = bpy.data.node_groups.new("Falcon DSP shade", "ShaderNodeTree")
    group.interface.new_socket("Colour", in_out="INPUT", socket_type="NodeSocketColor")
    group.interface.new_socket("Shaded", in_out="OUTPUT", socket_type="NodeSocketColor")
    s = Nodes(group)
    inp, out = s.new("NodeGroupInput"), s.new("NodeGroupOutput")
    attr = s.new("ShaderNodeAttribute", attribute_type="GEOMETRY", attribute_name="ps1_normal_world")
    normal = s.vec("NORMALIZE", attr.outputs["Vector"])

    def light_sum(channel):
        total = None
        for index, vector in enumerate(lights[channel]):
            product = s.vec("DOT_PRODUCT", normal, vector)
            dot = product.node
            dot.name = dot.label = "%s light %d" % (channel, index)   # world space, camera-fixed
            term = s.math("MAXIMUM", product, 0.0)
            total = term if total is None else s.math("ADD", total, term)
        return s.math("MINIMUM", total, 0.9999999)          # saturated below 1.0

    red, green = light_sum("red"), light_sum("green")
    luminance = s.math("ADD", s.math("MULTIPLY", red, 0.299), s.math("MULTIPLY", green, 0.701))
    level = s.math("MINIMUM", s.math("FLOOR", s.math("MULTIPLY", luminance, 16.0)), 15.0)
    ratio = s.math("DIVIDE", s.math("ADD", red, lights["ambient"][0], name="ambient red"),
                   s.math("ADD", green, lights["ambient"][1], name="ambient green"))
    tint = None
    for index, threshold in enumerate(lights["thresholds"]):
        # The DSP's fixed tint thresholds; the exporter checks them.
        step = s.math("GREATER_THAN", ratio, threshold - 1e-6, name="tint threshold %d" % index)
        tint = step if tint is None else s.math("ADD", tint, step)
    coords = s.new("ShaderNodeCombineXYZ")
    s.feed(coords, ((0, s.math("DIVIDE", s.math("ADD", level, 0.5), 16.0)),
                    (1, s.math("SUBTRACT", 1.0, s.math("DIVIDE", s.math("ADD", tint, 0.5), 4.0)))))
    lut = s.new("ShaderNodeTexImage", interpolation="Closest", extension="EXTEND")
    lut.image = image("shade ramp", "shade_ramp.png")
    lut.name = lut.label = "shade ramp"
    s.links.new(coords.outputs[0], lut.inputs["Vector"])
    # shade_falcon_color: 5-bit channel * ramp/64 * 3/2 (640x400 SHADE_GAIN),
    # truncated, clamped to 31; a non-zero channel stays at least 1. The
    # RGB555X word shows green through the 565 Videl word, overlay bit clear.
    channel = s.rounded(inp.outputs["Colour"], 31.0)
    factor = s.rounded(lut.outputs["Color"], 255.0 / 4.0)
    shaded = s.vec("MINIMUM", s.vec("FLOOR", s.vec("MULTIPLY", s.vec("MULTIPLY", channel, factor),
                                                   (3 / 128,) * 3)), (31.0,) * 3)
    shaded = s.vec("MAXIMUM", shaded, s.vec("MINIMUM", channel, (1.0,) * 3))
    s.links.new(s.vec("MULTIPLY", shaded, (1 / 31, 2 / 63, 1 / 31)), out.inputs["Shaded"])
    return group


group = shade_group()


def new_material(name):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    if hasattr(mat, "surface_render_method"):
        mat.surface_render_method = "DITHERED"
    mat.node_tree.nodes.clear()
    return mat, Nodes(mat.node_tree)


def mesh_material(name, page):
    mat, s = new_material(name)
    mat.use_backface_culling = True
    output = s.new("ShaderNodeOutputMaterial")
    shade = s.new("ShaderNodeGroup")
    shade.node_tree = group
    emission = s.new("ShaderNodeEmission")
    s.links.new(shade.outputs["Shaded"], emission.inputs["Color"])
    if page is None:
        colour = s.new("ShaderNodeAttribute", attribute_type="GEOMETRY", attribute_name="ps1_colour")
        s.links.new(colour.outputs["Color"], shade.inputs["Colour"])
        s.links.new(emission.outputs[0], output.inputs["Surface"])
        return mat
    texture = s.new("ShaderNodeTexImage", interpolation="Closest", extension="REPEAT")
    texture.image = image("page %d" % page, "page_%d.png" % page)
    uvmap = s.new("ShaderNodeUVMap", uv_map="PS1 UV")
    s.links.new(uvmap.outputs["UV"], texture.inputs["Vector"])
    s.links.new(texture.outputs["Color"], shade.inputs["Colour"])
    # Palette word 0 is never drawn (the rasterizer's validity test).
    mix = s.new("ShaderNodeMixShader")
    s.links.new(texture.outputs["Alpha"], mix.inputs["Fac"])
    s.links.new(s.new("ShaderNodeBsdfTransparent").outputs[0], mix.inputs[1])
    s.links.new(emission.outputs[0], mix.inputs[2])
    s.links.new(mix.outputs[0], output.inputs["Surface"])
    return mat


for page in pages:
    mesh.materials.append(mesh_material("TIM page %d" % page, page))
mesh.materials.append(mesh_material("Untextured (TMD colour)", None))


# ---------------------------------------------------------------- backdrop
world = bpy.data.worlds.new("Backdrop")
scene.world = world
world.use_nodes = True
world.node_tree.nodes.clear()
w = Nodes(world.node_tree)
picture = w.new("ShaderNodeTexImage", interpolation="Closest", extension="EXTEND")
picture.image = backdrop_image
w.links.new(w.new("ShaderNodeTexCoord").outputs["Window"], picture.inputs["Vector"])
background = w.new("ShaderNodeBackground")
w.links.new(picture.outputs["Color"], background.inputs["Color"])
w.links.new(background.outputs[0], w.new("ShaderNodeOutputWorld").inputs["Surface"])


# ---------------------------------------------------------------- ground shadow
def shadow_material():
    """draw_ground_shadow: c - c>>4 inside the outer ring, c - c>>3 per inner ring."""
    mat, s = new_material("Ground shadow")
    mat.use_backface_culling = False
    output = s.new("ShaderNodeOutputMaterial")
    picture = s.new("ShaderNodeTexImage", interpolation="Closest", extension="EXTEND")
    picture.image = backdrop_image
    s.links.new(s.new("ShaderNodeTexCoord").outputs["Window"], picture.inputs["Vector"])
    local = s.new("ShaderNodeTexCoord").outputs["Object"]
    radius = s.vec("LENGTH", s.vec("MULTIPLY", local, (1.0, 1.0, 0.0)))
    colour = s.vec("FLOOR", s.vec("ADD", s.vec("MULTIPLY", picture.outputs["Color"], (31.0, 63.0, 31.0)),
                                  (0.5,) * 3))
    rings = data["shadow"]["rings"]
    inside = []
    for index, (ring, shift) in enumerate(zip(rings, (16.0, 8.0, 8.0))):
        mask = s.math("LESS_THAN", radius, ring, name="ring %d radius" % index)
        inside.append(mask)
        cut = s.vec("FLOOR", s.vec("DIVIDE", colour, (shift,) * 3))
        scaled = s.new("ShaderNodeVectorMath", operation="SCALE")
        s.links.new(cut, scaled.inputs[0])
        s.links.new(mask, scaled.inputs["Scale"])
        colour = s.vec("SUBTRACT", colour, scaled.outputs[0])
    emission = s.new("ShaderNodeEmission")
    s.links.new(s.vec("MULTIPLY", colour, (1 / 31, 1 / 63, 1 / 31)), emission.inputs["Color"])
    mix = s.new("ShaderNodeMixShader")
    s.links.new(inside[0], mix.inputs["Fac"])
    s.links.new(s.new("ShaderNodeBsdfTransparent").outputs[0], mix.inputs[1])
    s.links.new(emission.outputs[0], mix.inputs[2])
    s.links.new(mix.outputs[0], output.inputs["Surface"])
    return mat


plane = bpy.data.meshes.new("Ground shadow")
plane.from_pydata([(-1, -1, 0), (1, -1, 0), (1, 1, 0), (-1, 1, 0)], [], [(0, 1, 2, 3)])
plane.materials.append(shadow_material())
shadow = bpy.data.objects.new("Ground shadow", plane)
shadow.scale = (*data["shadow"]["axes"], 1.0)
scene.collection.objects.link(shadow)


# ---------------------------------------------------------------- animation
def unwrap(angle, previous):
    return angle if previous is None else previous + (angle - previous + math.pi) % math.tau - math.pi


yaw = heading = None
for frame in data["frames"]:
    number = frame["sample"] + 1
    rotation = Matrix(frame["rotation"])
    yaw = unwrap(math.atan2(rotation[1][0], rotation[0][0]), yaw)
    heading = unwrap(frame["shadow"]["heading"], heading)
    trex.location, trex.rotation_euler = frame["location"], (0.0, 0.0, yaw)
    shadow.location, shadow.rotation_euler = frame["shadow"]["location"], (0.0, 0.0, heading)
    for obj in (trex, shadow):
        obj.keyframe_insert("location", frame=number)
        obj.keyframe_insert("rotation_euler", frame=number)
    key = pose_keys[frame["sample"]]
    for at, value in ((number - 1, 0.0), (number, 1.0), (number + 1, 0.0)):
        if 1 <= at <= count:
            key.value = value
            key.keyframe_insert("value", frame=at)


def fcurves(action):
    """Blender 4.4+ keeps F-curves in layered channelbags."""
    if hasattr(action, "fcurves") and len(action.fcurves):
        return list(action.fcurves)
    return [curve for layer in action.layers for strip in layer.strips
            for bag in strip.channelbags for curve in bag.fcurves]


for owner in (trex, shadow, mesh.shape_keys):
    for curve in fcurves(owner.animation_data.action):
        for point in curve.keyframe_points:
            point.interpolation = "LINEAR"

scene.frame_set(1)
bpy.ops.wm.save_as_mainfile(filepath=str(OUT / "trex_trail.blend"), relative_remap=True, compress=True)
print("saved", OUT / "trex_trail.blend")
