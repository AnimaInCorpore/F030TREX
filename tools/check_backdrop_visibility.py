#!/usr/bin/env python3
"""Measure visible head and torso pixels in Hatari's actual textured frames.

make-probes takes a frame-sequence executable and a scratch directory.
Run both resulting probes and the unmodified executable for the same prefix.
check takes the three fbseq.res files in full, no-head, no-torso order.
"""
import argparse
from pathlib import Path
import struct

import numpy as np

MODEL = Path(__file__).resolve().parents[1] / "TREX/model"
WIDTH, HEIGHT = 640, 400


def make_probes(executable, output):
    o3d = (MODEL / "trex.o3d").read_bytes()
    program = executable.read_bytes()
    if program.count(o3d) != 1:
        raise ValueError("Expected one embedded copy of the original full mesh")
    points, normals, triangles = struct.unpack_from(">3H", o3d)
    offset = 24 + 12 * (points + normals)
    polygons = np.frombuffer(o3d, ">u2", offset=offset).reshape(triangles, 16)
    assert np.all(polygons[:, 0] == 3)
    faces = polygons[:, 5:8] // 3
    vertices = np.fromfile(MODEL / "trex.tmd", "<i2", offset=0x125d8,
                           count=points*4).reshape(points, 4)
    centres = vertices[faces].mean(axis=1)
    # Strict subsets: the forward skull/muzzle within the extracted head
    # morph and a trunk region between the neck and tail, above the legs.
    head = (faces.max(axis=1) < 557) & (centres[:, 2] > 0)
    torso = (centres[:, 2] > -11200) & (centres[:, 2] < -3500) & (centres[:, 1] < 1600)
    output.mkdir(parents=True, exist_ok=True)
    for name, part in (("no_head", head), ("no_torso", torso)):
        probe = bytearray(program)
        records = np.frombuffer(probe, ">u2", count=triangles*16,
                                offset=program.index(o3d) + offset).reshape(triangles, 16)
        # Zero area leaves the triangle's global number and all other
        # geometry, lighting, texture data and painter-order ties intact.
        records[part, 6] = records[part, 5]
        records[part, 7] = records[part, 5]
        (output / (name + ".tos")).write_bytes(probe)


def check(full, no_head, no_torso):
    frame_bytes = WIDTH * HEIGHT * 2
    paths = (full, no_head, no_torso)
    size = full.stat().st_size
    if size % frame_bytes or any(path.stat().st_size != size for path in paths):
        raise ValueError("Captures must contain equal numbers of complete frames")
    frames = size // frame_bytes
    path = (MODEL / "backdrop_path.bin").read_bytes()
    lap_start, = struct.unpack_from(">I", path)
    samples = (len(path)-16) // 54
    if frames < samples + 2:
        raise ValueError("Capture the approach, complete lap and both pages after wrap")
    original, *probes = [np.memmap(p, ">u2", "r", shape=(frames, HEIGHT, WIDTH)) for p in paths]
    for name, probe in zip(("head", "torso"), probes):
        counts = [np.count_nonzero(image != omitted) for image, omitted in zip(original, probe)]
        lowest = min(counts)
        print(f"{name}: at least {lowest} distinct visible pixels, minimum at frame {counts.index(lowest)}")
        if lowest == 0:
            raise ValueError(f"{name} disappears")
    for i in range(samples, frames):
        if not np.array_equal(original[i], original[lap_start + (i-samples) % (samples-lap_start)]):
            raise ValueError(f"Lap differs at frame {i}")
    print(f"{frames} frames checked, including {frames-samples} after wrap")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_subparsers(dest="mode", required=True)
    build = modes.add_parser("make-probes")
    build.add_argument("executable", type=Path)
    build.add_argument("output", type=Path)
    compare = modes.add_parser("check")
    for arg in ("full", "no_head", "no_torso"):
        compare.add_argument(arg, type=Path)
    args = parser.parse_args()
    if args.mode == "make-probes":
        make_probes(args.executable, args.output)
    else:
        check(args.full, args.no_head, args.no_torso)
