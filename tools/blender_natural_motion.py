"""Add secondary motion to the trail scene's baked poses: a tail that sways
with the steps and trails through turns.

Run: blender -b TREX/scene/trex_trail.blend --python tools/blender_natural_motion.py -- <out.blend> [strength]

The scene's `pose NNN` shape keys carry the PS1 gait: the legs walk, but the
tail rides rigidly on the object's yaw. This script bends the tail in every
pose and leaves the rest untouched, so foot contact and the route do not
change. The head and neck stay in the gait's own frame on purpose: the run-time
gestures (shape keys named "DSP random ...") are deltas authored for that
frame, and a baked neck bend would make a jaw or a glance shear. It writes a new .blend; export it
with tools/blender_export_falcon.py as usual (the exporter bakes any pose).

Every pose is a function of the route's yaw rate, the feet's fore-aft
positions and the hip height, read over a few neighbouring samples. Samples
from the `lap` marker on read their neighbours around the lap, so the lap
still closes exactly; the approach blends into that over its last samples.
"""
import math
import sys

import bpy
import numpy as np

args = sys.argv[sys.argv.index("--") + 1:]
OUT = args[0]
STRENGTH = float(args[1]) if len(args) > 1 else 1.0

# Model axes: head toward -Y, tail toward +Y, Z up, metres.
TAIL_ROOT = 4.0                      # rest Y where the bend starts
STEP = 0.5                           # spine station spacing
TAIL_TURN = math.radians(12)         # tip angle in a saturated turn
TAIL_SWAY = math.radians(10)         # tip angle from the steps
TAIL_BOB = 1.4                       # tip height follows the hip, times this
YAW_SATURATION = math.radians(4.0)   # yaw rate per sample where the bends level off
TAIL_LAG = 4.0                       # samples, at the tip
BLEND = 15                           # approach samples that blend into the lap

obj = bpy.data.objects["T-Rex"]
if obj.get("secondary_motion"):
    sys.exit("this scene already carries secondary motion; start from the original")
scene = bpy.context.scene
blocks = obj.data.shape_keys.key_blocks
count = sum(1 for k in blocks if k.name.startswith("pose "))
lap = next(m.frame for m in scene.timeline_markers if m.name == "lap") - 1
period = count - lap
nverts = len(obj.data.vertices)


def coords(block):
    data = np.empty(nverts * 3, np.float32)
    block.data.foreach_get("co", data)
    return data.reshape(-1, 3).astype(np.float64)


rest = coords(blocks["Basis"])
poses = np.array([coords(blocks["pose %03d" % i]) for i in range(count)])

# Drivers, one value per sample.
yaw, hip = np.empty(count), np.empty(count)
for i in range(count):
    scene.frame_set(i + 1)
    yaw[i], hip[i] = obj.rotation_euler.z, obj.location.z
feet = rest[:, 2] < rest[:, 2].min() + 0.4
stride = (poses[:, feet & (rest[:, 0] < 0), 1].mean(1)
          - poses[:, feet & (rest[:, 0] > 0), 1].mean(1))
stride /= np.abs(stride).max()


def looped(i):
    """Sample index on the displayed timeline: the lap repeats after the end."""
    i = np.asarray(i)
    return np.where(i >= count, lap + (i - lap) % period, np.clip(i, 0, count - 1))


def around_lap(i):
    return lap + (np.asarray(i) - lap) % period


def sample(signal, t, index):
    """Linear interpolation of a per-sample signal at fractional time t."""
    low = math.floor(t)
    f = t - low
    return (1 - f) * signal[index(low)] + f * signal[index(low + 1)]


def drivers(index):
    rate = np.array([yaw[index(i + 1)] - yaw[index(i)] for i in range(-8, count + 8)])
    rate = (rate + math.pi) % (2 * math.pi) - math.pi
    # Yaw rate between samples i and i+1 sits at i+0.5: centre and smooth it.
    kernel = np.ones(6) / 6
    smooth = np.convolve(rate, kernel, "same")
    turn = {i: smooth[i + 8] for i in range(-6, count + 6)}
    return turn


def stations(root, direction, length):
    return root + direction * np.arange(0, length + STEP, STEP)


def bend(pose, sample_index, index, turn):
    """Return the pose with the tail bent for this sample."""
    out = pose.copy()
    for root, direction in ((TAIL_ROOT, 1),):
        along = direction * (rest[:, 1] - root)
        length = along.max()
        ys = stations(root, direction, length)
        n = len(ys)
        # Posed centreline: mean of the vertices near each station.
        centre = np.empty((n, 3))
        for k, y in enumerate(ys):
            near = np.abs(rest[:, 1] - y) < STEP
            centre[k] = pose[near].mean(0)
        angle, lift = np.zeros(n), np.zeros(n)
        for k in range(n):
            u = k * STEP / length                     # 0 at the root, 1 at the tip
            t = sample_index - TAIL_LAG * u
            rate = (1 - (t - math.floor(t))) * turn[int(index(math.floor(t)))] \
                + (t - math.floor(t)) * turn[int(index(math.floor(t) + 1))]
            angle[k] = u ** 1.3 * (-TAIL_TURN * math.tanh(rate / YAW_SATURATION)
                                   + TAIL_SWAY * sample(stride, t, index))
            lift[k] = u * TAIL_BOB * (sample(hip, t, index) - hip[int(index(sample_index))])
        angle *= STRENGTH
        lift *= STRENGTH
        # Rebuild the centreline segment by segment, each turned by its angle.
        moved = centre.copy()
        for k in range(1, n):
            a = 0.5 * (angle[k] + angle[k - 1])
            dx, dy = centre[k, :2] - centre[k - 1, :2]
            moved[k, 0] = moved[k - 1, 0] + dx * math.cos(a) - dy * math.sin(a)
            moved[k, 1] = moved[k - 1, 1] + dx * math.sin(a) + dy * math.cos(a)
            moved[k, 2] = centre[k, 2] + lift[k]
        # Each vertex takes the rigid motion of its station, interpolated.
        pick = along > 0
        position = np.clip(along[pick] / STEP, 0, n - 1 - 1e-9)
        k0 = position.astype(int)
        f = (position - k0)[:, None]
        result = np.zeros((pick.sum(), 3))
        for k, weight in ((k0, 1 - f), (k0 + 1, f)):
            rel = pose[pick] - centre[k]
            c, s = np.cos(angle[k])[:, None], np.sin(angle[k])[:, None]
            turned = np.hstack([rel[:, :1] * c - rel[:, 1:2] * s,
                                rel[:, :1] * s + rel[:, 1:2] * c, rel[:, 2:]])
            result += weight * (moved[k] + turned)
        out[pick] = result
    return out


turn_plain, turn_lap = drivers(looped), drivers(around_lap)
worst = 0.0
for i in range(count):
    if i >= lap:
        new = bend(poses[i], i, around_lap, turn_lap)
    else:
        new = bend(poses[i], i, looped, turn_plain)
        w = min(max((i - (lap - BLEND)) / BLEND, 0), 1)
        if w > 0:
            w = w * w * (3 - 2 * w)
            new = (1 - w) * new + w * bend(poses[i], i, around_lap, turn_lap)
    worst = max(worst, np.abs(new - poses[i]).max())
    blocks["pose %03d" % i].data.foreach_set("co", new.astype(np.float32).ravel())

untouched = rest[:, 1] <= TAIL_ROOT
obj["secondary_motion"] = STRENGTH
obj.data.update()
bpy.ops.wm.save_as_mainfile(filepath=OUT, copy=True)
print("secondary motion: %d poses, lap from %d, %d of %d vertices untouched, largest move %.2f m"
      % (count, lap, untouched.sum(), nverts, worst))
