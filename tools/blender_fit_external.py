"""Fit a normalised mesh (for example a LATO.2 result) back onto one bone's part.

Run: blender -b <source.blend> --python tools/blender_fit_external.py -- \
         <mesh object> <bone> <in.obj> <out.obj> [mirror=+x|-x] [triangles=N]

<in.obj> is Z up and centred, as LATO.2 returns a part after converting its
Y-up output with (x, y, z) -> (x, -z, y). It is moved and scaled uniformly so
that its bounding box matches, by centre and longest side, the rest-shape box
of the source vertices whose strongest group is <bone>. The result is in world
space, ready for blender_reduce_rigid.py's external=<bone>:<out.obj>.

mirror=+x keeps the half on the +X side of the box centre and mirrors it onto
the other side (-x the other half), welding the cut. Learned remeshers are
not symmetric; a mirrored half makes a left-right symmetric part read as one.
triangles=N then collapses the result to N triangles with Decimate's X
symmetry, so the reducer's own budget pass does not have to break it.
"""
import sys

import bmesh
import bpy
import numpy as np

a = sys.argv[sys.argv.index("--") + 1:]
src, bone, inp, out = bpy.data.objects[a[0]], a[1], a[2], a[3]
opts = dict(x.split("=", 1) for x in a[4:])
MIRROR = opts.get("mirror")
TRIANGLES = int(opts.get("triangles", 0))
if MIRROR not in (None, "+x", "-x"):
    raise SystemExit("mirror must be +x or -x")

gi = src.vertex_groups[bone].index
mw = np.array(src.matrix_world)
pts = []
for v in src.data.vertices:
    g = max(v.groups, key=lambda g: g.weight, default=None)
    if g and g.group == gi:
        pts.append((mw @ np.r_[v.co[:], 1.0])[:3])
pts = np.array(pts)
lo, hi = pts.min(0), pts.max(0)
centre = (lo + hi) / 2

lines = open(inp).read().splitlines()
V = np.array([[float(c) for c in l.split()[1:4]] for l in lines if l.startswith("v ")])
F = [[int(c.split("/")[0]) - 1 for c in l.split()[1:]] for l in lines if l.startswith("f ")]
vlo, vhi = V.min(0), V.max(0)
scale = (hi - lo).max() / (vhi - vlo).max()
W = (V - (vlo + vhi) / 2) * scale + centre

bm = bmesh.new()
verts = [bm.verts.new(p - centre) for p in W]      # mirror plane through x = 0
for f in F:
    try:
        bm.faces.new([verts[i] for i in f])
    except ValueError:                              # duplicate face
        pass
if MIRROR:
    size = float((hi - lo).max())
    geom = bm.verts[:] + bm.edges[:] + bm.faces[:]
    bmesh.ops.bisect_plane(bm, geom=geom, dist=1e-6 * size, plane_co=(0, 0, 0),
                           plane_no=(1, 0, 0), clear_inner=MIRROR == "+x",
                           clear_outer=MIRROR == "-x")
    for v in bm.verts:                              # the cut lies exactly on the plane
        if abs(v.co.x) < 1e-5 * size:
            v.co.x = 0.0
    bmesh.ops.mirror(bm, geom=bm.verts[:] + bm.edges[:] + bm.faces[:], axis="X",
                     merge_dist=1e-5 * size)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
bmesh.ops.triangulate(bm, faces=bm.faces[:])
if TRIANGLES and len(bm.faces) > TRIANGLES:
    me = bpy.data.meshes.new("fit")
    bm.to_mesh(me)
    bm.free()
    obj = bpy.data.objects.new("fit", me)
    bpy.context.scene.collection.objects.link(obj)
    mod = obj.modifiers.new("decimate", "DECIMATE")
    mod.ratio = TRIANGLES / len(me.polygons)
    mod.use_collapse_triangulate = True
    mod.use_symmetry = MIRROR is not None
    mod.symmetry_axis = "X"
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.modifier_apply(modifier=mod.name)
    bm = bmesh.new()
    bm.from_mesh(me)
    bmesh.ops.triangulate(bm, faces=bm.faces[:])
bm.verts.index_update()
out_v = np.array([v.co[:] for v in bm.verts]) + centre
print("SOURCE", lo.round(3), hi.round(3), "FITTED", out_v.min(0).round(3), out_v.max(0).round(3),
      "%d vertices, %d triangles" % (len(bm.verts), len(bm.faces)))
with open(out, "w") as f:
    for p in out_v:
        f.write("v %.6f %.6f %.6f\n" % tuple(p))
    for face in bm.faces:
        f.write("f " + " ".join(str(v.index + 1) for v in face.verts) + "\n")
bm.free()
