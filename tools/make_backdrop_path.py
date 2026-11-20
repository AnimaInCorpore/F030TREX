#!/usr/bin/env python3
"""Build the fixed-camera trail, projected contact shadow and model-space XYZ16 morph poses."""
import math
import struct
import sys
from pathlib import Path

import numpy as np


FOCAL_X, FOCAL_Y, CENTRE_Y = 1320, 1219, 200
CAMERA_HEIGHT = -3405  # 3545 units above the ground, about 1.65 m.
PITCH = math.radians(-3.4)
ROUTE_YAW = math.radians(1.22)


def pitch_view(y, z):
    """Rotate a world-space direction or camera-relative point into the fixed view."""
    return y * math.cos(PITCH) - z * math.sin(PITCH), y * math.sin(PITCH) + z * math.cos(PITCH)


def shadow_rows(hip_x, depth, c, s, radius):
    """Intersect each screen row's ground-plane depth with an ellipse."""
    width, length = 3150, 7700
    ground_y = CAMERA_HEIGHT + 6950  # Standing foot in the TANM poses.
    centre_x = hip_x + 700  # soft sky key from camera left
    centre_z = depth + 450
    inv_w, inv_l = 1 / width**2, 1 / length**2
    a = c*c*inv_w + s*s*inv_l
    rows = []
    cp, sp = math.cos(PITCH), math.sin(PITCH)
    for y in range(400):
        slope = (y + 0.5 - CENTRE_Y) / FOCAL_Y
        if sp + slope * cp <= 0:
            continue
        z = ground_y * (cp - slope * sp) / (sp + slope * cp)
        camera_z = ground_y * sp + z * cp
        dz = z - centre_z
        b = dz*c*s*(inv_l - inv_w)
        disc = a*radius**2 - dz*dz*inv_w*inv_l
        if disc <= 0:
            continue
        mid = 320 + FOCAL_X * (centre_x - b/a) / camera_z
        half = FOCAL_X * math.sqrt(disc) / (a*camera_z)
        # Two adjacent RGB565 pixels per 68030 longword.
        left = max(0, 2 * round((mid-half)/2))
        right = min(640, 2 * round((mid+half)/2))
        if right > left:
            rows.append((y, left, right))
    return rows


MODEL = Path(__file__).resolve().parents[1] / "TREX/model"
GAIT_FIRST = 52
TURN_START, TURN_END = 40, 112
LAP_START, LAP = 152, 128
FRAMES_PER_STRIDE = 12  # Samples displayed from one 32-key source gait.
TURN_EXTRA_FRAMES = 24


def heading(frame):
    """Walk directly past camera left, then arc right into the patrol."""
    finish = math.radians(-107.44)
    entry = math.radians(-184.45)
    if frame <= TURN_START:
        return 0.0
    if frame < TURN_END:
        t = (frame - TURN_START) / (TURN_END - TURN_START)
        # Spread the departure across more than two strides. The animal
        # still walks towards the viewer during the first part of the arc.
        return finish * t*t*(3-2*t)
    if frame < LAP_START-8:
        t = (frame-TURN_END) / (LAP_START-8-TURN_END)
        # Steer back into the clearing before joining the patrol.
        return finish + (entry-finish)*t*t*(3-2*t) + math.radians(7.59) * math.sin(math.pi*t)**2
    rate = -math.tau / LAP
    if frame < LAP_START:
        return entry + rate*(frame-LAP_START+8)**2/16
    return entry + rate*(4+frame-LAP_START)


def load_stride():
    """Read one period of the extracted TANM gait and its sparse face weights."""
    base = np.fromfile(MODEL / "trex.tmd", "<i2", offset=0x125d8,
                       count=1376*4).reshape(-1, 4)[:, :3].astype(float)
    anim = (MODEL / "trex_animation.bin").read_bytes()
    gait = np.frombuffer(anim, ">i2", offset=64640, count=46*1376*3).reshape(46, 1376, 3)
    poses, brow = [], []
    for i in range(32):
        record = 47104 + (GAIT_FIRST + i) * 64
        pose, = struct.unpack_from(">H", anim, record + 54)
        brow.append(struct.unpack_from(">h", anim, record + 46)[0])
        poses.append(base + gait[pose])
    return base, np.asarray(poses), brow, anim


def stride_path(feet):
    """Move the root so the stance foot holds its ground as the body turns."""

    def yaw_axes(frame):
        c, s = math.cos(heading(frame)), math.sin(heading(frame))
        return np.array([[c, -s], [-s, -c]])

    roots = [np.zeros(2)]
    for i in range(LAP_START+LAP):
        old, new = feet[i], feet[i+1]
        backward = old[:, 1] - new[:, 1]
        # The foot sweeping backwards relative to the torso bears the weight.
        # Crossfade where the left and right stance velocities meet.
        left = np.clip(0.5 + (backward[0]-backward[1])/500, 0, 1)
        step = old @ yaw_axes(i) - new @ yaw_axes(i+1)
        roots.append(roots[-1] + left*step[0] + (1-left)*step[1])
    roots = np.asarray(roots)
    assert np.allclose(roots[-1], roots[LAP_START], atol=0.001)
    # Place the entire track once. Camera, lens and horizon stay fixed.
    roots += np.array([5624, 23500]) - roots[TURN_START]
    return roots


def steady_stride(roots, steps, base):
    """Carry the hips through support changes while keeping the soles planted."""
    keys = np.arange(len(roots))
    yaw = np.array([heading(k) for k in keys])
    forward = np.column_stack((-np.sin(yaw), -np.cos(yaw)))
    hips = roots - 6144 * forward
    offsets = np.arange(-15, 16)
    weights = np.exp(-0.5 * (offsets / 5)**2)
    weights /= weights.sum()
    samples = keys[:, None] + offsets
    wrapped = LAP_START + (samples - LAP_START) % LAP
    ids = np.where(samples >= len(hips), wrapped, np.maximum(samples, 0))
    extended = hips[ids] + np.minimum(samples, 0)[:, :, None] * (hips[8] - hips[0]) / 8
    steady = weights @ extended
    periodic = weights @ hips[wrapped]
    join = smoothstep((keys - LAP_START + 15) / 15)[:, None]
    steady += join * (periodic - steady)
    delta = steady - hips
    # Bring the soles back to their stance positions in mesh coordinates.
    # Ease the correction up the leg to leave the load-bearing hip free.
    leg = smoothstep((base[:, 1] - 1200) / 3800)
    local_x = delta[:, 0] * np.cos(yaw) - delta[:, 1] * np.sin(yaw)
    local_z = (delta * forward).sum(axis=1)
    steps[:, :, 0] -= local_x[:, None] * leg
    steps[:, :, 2] -= local_z[:, None] * leg
    assert np.all((np.diff(steady, axis=0) * (forward[1:] + forward[:-1])).sum(axis=1) > 0)
    return roots + delta


def smoothstep(value):
    t = np.clip(value, 0, 1)
    return t * t * (3 - 2 * t)


def presentation_time(key):
    """Ease into a shorter, slower stride around the closest part of the turn."""
    t = np.clip((key - TURN_START) / (TURN_END - TURN_START), 0, 1)
    ease = t**3 * (10 - 15 * t + 6 * t**2)
    # Increase sampling gradually into the lap. Eighteen displayed poses
    # per stride keep cruising yaw at five degrees per presented frame.
    ramp = np.clip((key - TURN_END) / (LAP_START - TURN_END), 0, 1)
    extra = (LAP_START - TURN_END) * ramp**2 / 2 + np.maximum(key - LAP_START, 0)
    times = key * FRAMES_PER_STRIDE / 32 + TURN_EXTRA_FRAMES * ease + 6 * extra / 32
    # Allocate extra displayed poses wherever the shorter return turns more
    # quickly. End on an integer sample so both pages repeat the same lap.
    delta = np.abs(np.diff([math.degrees(heading(k)) for k in key[:LAP_START+1]]))
    durations = np.maximum(np.diff(times[:LAP_START+1]), delta / 4.85)
    end = durations.sum()
    durations *= math.ceil(end) / end
    times[LAP_START+1:] += math.ceil(end) - times[LAP_START]
    times[:LAP_START+1] = np.r_[0, durations.cumsum()]
    times[LAP_START] = math.ceil(end)
    return times


def turning_steps(base, gait, feet):
    """Shorten the inside step and gather both feet through the near bend."""
    leg = smoothstep((base[:, 1] - 850) / 4200) * smoothstep((-base[:, 2] - 2800) / 1600)
    side = (base[:, 0] > 0).astype(int)
    poses = []
    mean_foot_z = feet[:, :, 1].mean(axis=0)
    for frame in range(LAP_START + LAP + 1):
        phase = frame % 32
        # Look ahead to place the foot, then ease back into a full stride.
        bend = smoothstep((frame - TURN_START + 5) / 13) * smoothstep((TURN_END + 9 - frame) / 15)
        on_lap = smoothstep((frame - LAP_START + 8) / 8)
        reduction = np.array([0.50, 0.77]) * bend + np.array([0.16, 0.30]) * on_lap
        pose = gait[phase].copy()
        excursion = feet[phase, :, 1] - mean_foot_z
        pose[:, 2] -= leg * (excursion * reduction)[side]
        poses.append(pose)
    return np.asarray(poses)


def trail_poses(base, gait, steps, feet, lift, brow, anim, look=0, body=0, tail=0):
    """Compose signed vertex deltas in model space, before camera projection."""
    y, z = base[:, 1], base[:, 2]
    upper = smoothstep((4800 - y) / 4200)
    skull = smoothstep((z + 4800) / 3900) * upper
    chest = smoothstep((z + 13300) / 5500) * upper
    ribs = smoothstep((z + 7500) / 3900) * (1 - 0.85 * skull) * upper
    muzzle = z > 1200
    muzzle_height = gait[:, muzzle, 1].mean(axis=1) + lift
    # Ground-relative head height includes the lift used to plant the feet.
    bob = muzzle_height - muzzle_height.mean()
    tip = gait[:, z < -19600].mean(axis=1)
    tail_elevation = np.arctan2(-900 - tip[:, 1], -8500 - tip[:, 2])
    velocity = (np.roll(feet[:, :, 1], -1, axis=0) - np.roll(feet[:, :, 1], 1, axis=0))
    support = velocity[:, 0] - velocity[:, 1]  # positive = right foot retreats
    support = (np.roll(support, 1) + 2 * support + np.roll(support, -1)) / 4
    support /= np.max(np.abs(support))
    head_delta = np.frombuffer(anim, ">i2", offset=35412, count=557*3).reshape(557, 3).astype(np.int32)
    right_delta = np.frombuffer(anim, ">i2", offset=38828, count=557*3).reshape(557, 3).astype(np.int32)
    brow_delta = np.frombuffer(anim, ">i2", offset=38756, count=12*3).reshape(12, 3).astype(np.int32)

    for frame in range(LAP_START + LAP + 1):
        phase = frame % 32
        pose = steps[frame].copy()
        angle = heading(frame)
        rear = smoothstep((-math.cos(angle) - 0.15) / 0.75)
        delta = head_delta if look >= 0 else right_delta
        pose[:557] += (delta * abs(look)) >> 12
        pose[78:90] += (brow_delta * brow[phase]) >> 12

        # Roll around the hips as the load crosses from leg to leg. Fade
        # the correction down the thighs and let the neck steady the eyes.
        roll = (math.radians(2.8) * support[phase] - 0.025 * body)
        roll = roll * chest * (1 - 0.65 * skull)
        c, s = np.cos(roll), np.sin(roll)
        side, height = pose[:, 0].copy(), pose[:, 1] - 1600
        pose[:, 0] = side * c - height * s + 130 * support[phase] * chest
        pose[:, 1] += side * s + height * (c - 1) - 0.43 * bob[phase] * skull

        # Bend through the ribs ahead of the pelvis, with both feet still
        # governed by the source gait and the inside/outside step lengths.
        # Keep the head mostly free of the torso bend so it can look ahead.
        rib_yaw = math.radians(6) * body * ribs
        side, reach = pose[:, 0].copy(), pose[:, 2] + 6400
        pose[:, 0] = side * np.cos(rib_yaw) - reach * np.sin(rib_yaw)
        pose[:, 2] = -6400 + side * np.sin(rib_yaw) + reach * np.cos(rib_yaw)
        lean = -math.radians(3.75) * body * ribs
        side, height = pose[:, 0].copy(), pose[:, 1] - 1600
        pose[:, 0] = side * np.cos(lean) - height * np.sin(lean)
        pose[:, 1] = 1600 + side * np.sin(lean) + height * np.cos(lean)

        # Raise the neck from its base while sighting the return trail.
        # The flex tapers into the shoulders and the head follows as a unit.
        # Counter-rotate the skull at the upper joint to keep the gaze low.
        nod = -0.58 * rear * smoothstep((z + 1250) / 2100) * upper
        c, s = np.cos(nod), np.sin(nod)
        height, reach = pose[:, 1] + 100, pose[:, 2] - 1800
        pose[:, 1] = -100 + height * c - reach * s
        pose[:, 2] = 1800 + height * s + reach * c
        yaw = 0.05 * rear * skull
        c, s = np.cos(yaw), np.sin(yaw)
        side, reach = pose[:, 0].copy(), pose[:, 2] + 4600
        pose[:, 0] = side * c - reach * s
        pose[:, 2] = -4600 + side * s + reach * c
        neck = 0.85 * rear * skull
        c, s = np.cos(neck), np.sin(neck)
        height, reach = pose[:, 1] - 450, pose[:, 2] + 4600
        pose[:, 1] = 450 + height * c - reach * s
        pose[:, 2] = -4600 + height * s + reach * c

        # Bend the tail along a circular arc of the same centreline length.
        # The base follows the pelvis, the tip retains several poses of yaw.
        bend = 0.42 * tail
        # The display gait flicks the tip upward. Settle it nearer the hip
        # line while retaining a quarter of its angular rise on each step.
        settle = 0.75 * (tail_elevation[phase] - math.radians(6)) * smoothstep((-z - 8500) / 5300)
        c, s = np.cos(settle), np.sin(settle)
        height, reach = pose[:, 1] + 900, pose[:, 2] + 8500
        pose[:, 1] = -900 + height * c - reach * s
        pose[:, 2] = -8500 + height * s + reach * c
        length = np.maximum(-8700 - pose[:, 2], 0)
        tail_angle = bend * length / 13000
        side = pose[:, 0].copy()
        pose[:, 0] = (side * np.cos(tail_angle)
                      - length * tail_angle / 2 * np.sinc(tail_angle / (2 * math.pi))**2)
        pose[:, 2] += length * (1 - np.sinc(tail_angle / math.pi)) - side * np.sin(tail_angle)
        # Look through the inside of the patrol on broadside passes.
        # Keep the face free to look ahead on the camera-facing stretch.
        inside = math.radians(37) * smoothstep((frame - TURN_START) / 36) * math.sin(angle)**2 * skull
        side, reach = pose[:, 0].copy(), pose[:, 2] + 4600
        c, s = np.cos(inside), np.sin(inside)
        pose[:, 0] = side * c + reach * s
        pose[:, 2] = -4600 - side * s + reach * c
        pose[y >= 4800] = steps[frame, y >= 4800]
        yield pose - base


def main(output, shadow_output, pose_output):
    base, gait, brow, anim = load_stride()
    soles = [(base[:, 1] > 5900) & (sign * base[:, 0] > 0) for sign in (-1, 1)]
    feet = np.stack([gait[:, sole].mean(axis=1)[:, [0, 2]] for sole in soles], axis=1)
    lift = 6950 - gait[:, :, 1].max(axis=1)
    steps = turning_steps(base, gait, feet)
    placed_feet = np.stack([steps[:, sole].mean(axis=1)[:, [0, 2]] for sole in soles], axis=1)
    roots = steady_stride(stride_path(placed_feet), steps, base)
    poses = list(trail_poses(base, gait, steps, feet, lift, brow, anim))
    assert np.allclose(poses[-1], poses[LAP_START], atol=1e-7, rtol=0)
    targets = [np.asarray(list(trail_poses(base, gait, steps, feet, lift, brow, anim, **control)))
               for control in (dict(look=4096), dict(look=-4096), dict(body=1), dict(tail=1))]
    key_times = presentation_time(np.arange(len(poses)))
    sample_count = int(key_times[-1])
    lap_sample = int(key_times[LAP_START])
    pose_bank = bytearray()
    records = bytearray(struct.pack(">4I", lap_sample, FOCAL_X, FOCAL_Y, CENTRE_Y))
    shadow_index = bytearray()
    shadows = bytearray()
    for sample in range(sample_count):
        # Interpolate geometry, root and yaw at the same source time.
        key = np.searchsorted(key_times, sample, side="right") - 1
        t = (sample - key_times[key]) / (key_times[key + 1] - key_times[key])
        tx, z = roots[key] + t * (roots[key + 1] - roots[key])
        body_y = (1 - t) * lift[key % 32] + t * lift[(key + 1) % 32]
        angle = heading(key + t) + ROUTE_YAW
        c_route, s_route = math.cos(ROUTE_YAW), math.sin(ROUTE_YAW)
        tx, z = c_route * tx + s_route * z - 11250, -s_route * tx + c_route * z + 6086
        c, s = math.cos(angle), math.sin(angle)
        # The yaw puts model +Z along the horizontal tangent. Apply the
        # same camera pitch to its three axes, translation and shadow.
        yx, zx = pitch_view(0, -s)
        yy, zy = pitch_view(1, 0)
        yz, zz = pitch_view(0, -c)
        matrix = (c, 0, -s, yx, yy, yz, zx, zy, zz)
        ty, tz = pitch_view(CAMERA_HEIGHT + body_y, z)
        q23 = [round(v * ((1 << 23) - 1)) for v in matrix]
        records.extend(struct.pack(">12i", *q23, round(tx), round(ty), round(tz)))
        records.extend(struct.pack(">IH", len(pose_bank), round(angle * 65536 / math.tau) & 65535))
        pose = np.rint(poses[key] + t * (poses[key + 1] - poses[key]))
        assert pose.min() >= -32768 and pose.max() <= 32767
        pose_bank.extend(pose.astype(">i2").tobytes())
        # Store difference shapes in contiguous vertex runs. The 030
        # supplies their weights each frame before the normal gait upload.
        for shape in targets:
            delta = np.rint(shape[key] + t * (shape[key + 1] - shape[key])) - pose
            assert np.max(np.abs(delta)) < 32768
            active = np.any(delta != 0, axis=1)
            edges = np.flatnonzero(np.diff(np.r_[False, active, False])).reshape(-1, 2)
            for first, end in edges:
                pose_bank.extend(struct.pack(">HH", first * 6, (end - first) * 3))
                pose_bank.extend(delta[first:end].astype(">i2").tobytes())
            pose_bank.extend(bytes(4))
        hip_x = tx + 6144*s
        depth = z + 6144*c
        # Only geometry is baked. The live renderer darkens the ground first,
        # then draws the fully textured mesh over it.
        shadow_index.extend(struct.pack(">I", 4*sample_count + len(shadows)))
        for scale in (1.0, 0.77, 0.51):
            rows = shadow_rows(hip_x, depth, c, s, scale)
            if rows:
                y0, y1 = rows[0][0], rows[-1][0]
                assert len(rows) == y1 - y0 + 1
            if scale == 1.0:
                box = (min(x for _, x, _ in rows), max(x for _, _, x in rows)-1,
                       y0, y1) if rows else (0, 0, 1, 0)
                shadows.extend(struct.pack(">4H", *box))
            shadows.extend(struct.pack(">Hh", rows[0][0] if rows else 0, len(rows)-1))
            for _, left, right in rows:
                shadows.extend(struct.pack(">HH", left*2, (right-left)//2-1))
    Path(output).write_bytes(records)
    Path(shadow_output).write_bytes(shadow_index + shadows)
    Path(pose_output).write_bytes(pose_bank)


if __name__ == "__main__":
    main(*sys.argv[1:])
