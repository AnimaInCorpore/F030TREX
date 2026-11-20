"""Render frames of the Blender source scene for comparison with a Hatari capture.

Run: blender -b TREX/scene/trex_trail.blend --python tools/blender_check_scene.py -- <out dir> frame [...]

Writes <out dir>/frame_NNNN.png (Blender frame numbers; sample = frame - 1).
Compare them with tools/compare_blender_render.py.
"""
import sys
from pathlib import Path

import bpy

args = sys.argv[sys.argv.index("--") + 1:]
out = Path(args[0]).resolve()
scene = bpy.context.scene
for frame in [int(a) for a in args[1:]]:
    scene.frame_set(frame)
    scene.render.filepath = str(out / ("frame_%04d" % frame))
    bpy.ops.render.render(write_still=True)
