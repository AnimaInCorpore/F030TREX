"""Fit a normalised mesh (for example a LATO.2 result) back onto one bone's part.

Run: blender -b <source.blend> --python tools/blender_fit_external.py -- \
         <mesh object> <bone> <in.obj> <out.obj> [mirror=+x|-x] [triangles=N] \
         [fill=1|0] [hidden=drop|keep] [two_sided=0|1]

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

fill=1 (default): before the mirror, every hole rim is closed with a face and
the faces are made to wind consistently outwards. LATO.2 leaves small holes,
and with back faces culled a hole shows the background through the part. The
counts of open, non-manifold and unmatched edges are printed before and after.

Last, rays from 66 directions find which faces can be seen from outside the
part at all. hidden=drop (default) deletes the rest: they lie inside it and
would only be drawn and painted over. two_sided=1 also writes a reversed copy
(own vertices) of every face seen from behind somewhere: sheets and flaps that
culling would open up. That copy is drawn whenever the camera faces its side,
hidden or not, so it costs overdraw; leave it off when the scene's camera
does not look at those backs (check by rendering from the game camera).
"""
import sys
from collections import Counter, defaultdict

import bmesh
import bpy
from mathutils import Vector
from mathutils.bvhtree import BVHTree
import numpy as np

a = sys.argv[sys.argv.index("--") + 1:]
src, bone, inp, out = bpy.data.objects[a[0]], a[1], a[2], a[3]
opts = dict(x.split("=", 1) for x in a[4:])
MIRROR = opts.get("mirror")
TRIANGLES = int(opts.get("triangles", 0))
FILL = opts.get("fill", "1") == "1"
TWO_SIDED = opts.get("two_sided", "0") == "1"
HIDDEN = opts.get("hidden", "drop")
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


def unmatched(bm):
    """Half-edges a->b not cancelled by a b->a: the rims of the holes."""
    count = Counter()
    for face in bm.faces:
        vs = face.verts
        for k in range(len(vs)):
            count[vs[k], vs[(k + 1) % len(vs)]] += 1
    return [(a, b) for (a, b), n in list(count.items()) for _ in range(n - count.get((b, a), 0))]


def edge_report(bm, label):
    open_e = sum(1 for e in bm.edges if len(e.link_faces) == 1)
    nonman = sum(1 for e in bm.edges if len(e.link_faces) > 2)
    print("EDGES", label, "open", open_e, "non-manifold", nonman, "unmatched", len(unmatched(bm)))


def close_holes(bm):
    """Fill every hole rim with one face wound against it.

    Blender's holes_fill only follows rims whose vertices each touch two open
    edges; LATO.2's rims run through non-manifold edges (an edge with three
    faces is one matched pair plus one open side). Counting directed
    half-edges instead gives rims that always split into closed cycles, since
    every face enters and leaves each of its vertices once.
    """
    outs = defaultdict(list)
    for a, b in unmatched(bm):
        outs[a].append(b)
    cycles = []
    for start in list(outs):
        while outs[start]:
            path, pos = [start], {start: 0}
            while outs[path[-1]]:
                w = outs[path[-1]].pop()
                if w in pos:                            # split off a simple cycle
                    i = pos[w]
                    cycles.append(path[i:])
                    for x in path[i + 1:]:
                        del pos[x]
                    path = path[:i + 1]
                else:
                    pos[w] = len(path)
                    path.append(w)
    filled = skipped = 0
    for cycle in cycles:
        try:
            bm.faces.new(list(reversed(cycle)))
            filled += 1
        except ValueError:          # a lone triangle whose back would reuse its vertices
            skipped += 1
    bmesh.ops.triangulate(bm, faces=bm.faces[:])
    print("HOLES", len(cycles), "rims", filled, "filled", skipped, "lone triangles left")


bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
edge_report(bm, "input")
if FILL:
    close_holes(bm)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    edge_report(bm, "filled")
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


def visibility(bm, views=66, grid=256):
    """How often each face is the first thing a ray from outside meets.

    The part is viewed orthographically from `views` directions spread over
    the sphere, `grid` x `grid` rays each. Returns per face index the hits on
    its front and on its back.
    """
    tree = BVHTree.FromBMesh(bm)
    radius = 0.6 * float(np.linalg.norm(hi - lo))
    golden = np.pi * (3 - np.sqrt(5))
    front, back = Counter(), Counter()
    steps = np.linspace(-radius, radius, grid)
    for k in range(views):
        z = 1 - 2 * (k + 0.5) / views
        r = np.sqrt(1 - z * z)
        d = Vector((r * np.cos(golden * k), r * np.sin(golden * k), z))
        u = d.orthogonal().normalized()
        w = d.cross(u)
        for s in steps:
            for t in steps:
                hit, normal, index, _ = tree.ray_cast(u * s + w * t - d * (2 * radius), d, 4 * radius)
                if hit is not None:
                    (back if normal.dot(d) > 0 else front)[index] += 1
    return front, back


# Faces no ray reaches are inside the part (LATO.2's overlapping blocks, rims
# filled between them); the painter's order would draw them and paint over
# them. Faces reached from behind (sheets, flaps) would be culled there and
# leave a see-through gap, so they are drawn a second time, the other way
# round. Two back hits are needed, so a ray grazing a seam does not count.
bm.normal_update()
bm.faces.index_update()
front, back = visibility(bm)
hidden = [face for face in bm.faces if not front[face.index] and not back[face.index]]
backs = [face for face in bm.faces if back[face.index] >= 2] if TWO_SIDED else []
if HIDDEN == "drop":
    bmesh.ops.delete(bm, geom=hidden, context="FACES")
    bmesh.ops.delete(bm, geom=[v for v in bm.verts if not v.link_faces], context="VERTS")
print("VISIBILITY", len(hidden), "hidden faces", "dropped" if HIDDEN == "drop" else "kept",
      len(backs), "faces two-sided")
bm.verts.index_update()
out_v = np.array([v.co[:] for v in bm.verts]) + centre
print("SOURCE", lo.round(3), hi.round(3), "FITTED", out_v.min(0).round(3), out_v.max(0).round(3),
      "%d vertices, %d triangles" % (len(bm.verts) + 3 * len(backs), len(bm.faces) + len(backs)))
with open(out, "w") as f:
    for p in out_v:
        f.write("v %.6f %.6f %.6f\n" % tuple(p))
    for face in bm.faces:
        f.write("f " + " ".join(str(v.index + 1) for v in face.verts) + "\n")
    base = len(out_v)                       # the backs get their own vertices
    for k, face in enumerate(backs):
        for v in face.verts:
            f.write("v %.6f %.6f %.6f\n" % tuple(np.array(v.co[:]) + centre))
        f.write("f %d %d %d\n" % (base + 3 * k + 3, base + 3 * k + 2, base + 3 * k + 1))
bm.free()
