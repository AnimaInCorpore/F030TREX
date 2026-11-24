"""Fit a normalised mesh (for example a LATO.2 result) back onto one bone's part.

Run: blender -b <source.blend> --python tools/blender_fit_external.py -- \
         <mesh object> <bone> <in.obj> <out.obj>

<in.obj> is Z up and centred, as LATO.2 returns a part after converting its
Y-up output with (x, y, z) -> (x, -z, y). It is moved and scaled uniformly so
that its bounding box matches, by centre and longest side, the rest-shape box
of the source vertices whose strongest group is <bone>. The result is in world
space, ready for blender_reduce_rigid.py's external=<bone>:<out.obj>.
"""
import bpy, sys, numpy as np
a = sys.argv[sys.argv.index("--") + 1:]
src, bone, inp, out = bpy.data.objects[a[0]], a[1], a[2], a[3]
gi = src.vertex_groups[bone].index
mw = np.array(src.matrix_world)
pts = []
for v in src.data.vertices:
    g = max(v.groups, key=lambda g: g.weight, default=None)
    if g and g.group == gi:
        pts.append((mw @ np.r_[v.co[:], 1.0])[:3])
pts = np.array(pts); lo, hi = pts.min(0), pts.max(0)
lines = open(inp).read().splitlines()
V = np.array([[float(c) for c in l.split()[1:4]] for l in lines if l.startswith("v ")])
vlo, vhi = V.min(0), V.max(0)
scale = (hi - lo).max() / (vhi - vlo).max()
W = (V - (vlo + vhi) / 2) * scale + (lo + hi) / 2
print("SOURCE", lo.round(3), hi.round(3), "FITTED", W.min(0).round(3), W.max(0).round(3))
with open(out, "w") as f:
    for p in W: f.write("v %.6f %.6f %.6f\n" % tuple(p))
    for l in lines:
        if l.startswith("f "): f.write("f " + " ".join(c.split("/")[0] for c in l.split()[1:]) + "\n")
