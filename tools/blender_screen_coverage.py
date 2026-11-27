"""How large each face of a model appears in a scene's shot, and how many texels it has.

Run: blender -b <scene.blend> --python tools/blender_screen_coverage.py -- <object> <out.json> [page size]

For every frame of the scene's range, each face's projected area in pixels
of the render size (front-facing faces only; occlusion by other faces is
ignored). Writes, per face in the mesh's order: the largest area over the
shot ("pixels") and its texture area in texels of a <page size> (256) page
("texels"). Prints the texel-per-pixel ratio at each face's largest view:
below 1 the page is magnified there (blocky texels), and the share of the
page spent on faces the shot never shows.
"""
import json
import sys

import bpy
import numpy as np
from bpy_extras.object_utils import world_to_camera_view

args = sys.argv[sys.argv.index("--") + 1:]
name, out = args[0], args[1]
page = int(args[2]) if len(args) > 2 else 256
scene = bpy.context.scene
obj, cam = bpy.data.objects[name], scene.camera
W, H = scene.render.resolution_x, scene.render.resolution_y
me = obj.data
faces = [list(p.vertices) for p in me.polygons]
uv = me.uv_layers["PS1 UV"].data if "PS1 UV" in me.uv_layers else me.uv_layers.active.data
def uv_area(p):
    a, b, c = (np.array(uv[l].uv[:]) for l in p.loop_indices[:3])
    return abs((b[0] - a[0]) * (c[1] - a[1]) - (c[0] - a[0]) * (b[1] - a[1])) / 2


texels = np.array([uv_area(p) for p in me.polygons]) * page * page
local = np.array([v.co[:] for v in me.vertices])
best = np.zeros(len(faces))
for frame in range(scene.frame_start, scene.frame_end + 1):
    scene.frame_set(frame)
    m = np.array(obj.matrix_world)
    world = local @ m[:3, :3].T + m[:3, 3]
    cam_loc = np.array(cam.matrix_world.translation)
    from mathutils import Vector
    screen = np.array([world_to_camera_view(scene, cam, Vector(p))[:] for p in world])
    px = screen[:, :2] * [W, H]
    for i, f in enumerate(faces):
        a, b, c = world[f[0]], world[f[1]], world[f[2]]
        n = np.cross(b - a, c - a)
        if np.dot(n, cam_loc - a) <= 0 or (screen[f, 2] <= 0).any():
            continue
        p0, p1, p2 = px[f[0]], px[f[1]], px[f[2]]
        area = abs((p1[0] - p0[0]) * (p2[1] - p0[1]) - (p2[0] - p0[0]) * (p1[1] - p0[1])) / 2
        best[i] = max(best[i], area)
seen = best > 0.5
ratio = texels[seen] / best[seen]
w = best[seen] / best[seen].sum()
print("COVERAGE %s: %d of %d faces seen; texels per pixel at each face's largest view: "
      "pixel-weighted median %.2f, worst 10%% %.2f; page share on unseen faces %.0f%%; "
      "largest face view %.0f px"
      % (name, seen.sum(), len(faces), float(np.median(np.repeat(ratio, np.maximum(1, (w * 1000).astype(int))))),
         float(np.percentile(ratio, 10)), 100 * texels[~seen].sum() / max(1, texels.sum()), best.max()))
json.dump(dict(pixels=best.tolist(), texels=texels.tolist(), width=W, height=H, page=page), open(out, "w"))
