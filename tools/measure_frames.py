#!/usr/bin/env python3
"""Measure an exact frame prefix in an isolated corrected-Hatari run.

The 200 Hz counters measure emulated time. Host polling only chooses the
completed prefix; a missed prefix is an error, never a different workload.
Use a diagnostic binary with per-frame stats enabled. FRAME_HASH binaries
are useful for output comparison but their timings include the hash pass.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import time

from decode_render_stats import report


ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("dsp", type=Path)
    parser.add_argument("output", type=Path, help="new directory for this run")
    parser.add_argument("--frames", type=int, default=265)
    parser.add_argument("--timeout", type=float, default=300)
    parser.add_argument("--hatari", type=Path, default=ROOT.parent /
                        "F030Arcade/third_party/hatari/build/src/hatari")
    parser.add_argument("--tos", type=Path, default=ROOT.parent /
                        "F030Arcade/third_party/tos/tos402.img")
    args = parser.parse_args()
    if args.frames < 1 or args.timeout <= 0:
        parser.error("frames and timeout must be positive")

    paths = {name: getattr(args, name).resolve()
             for name in ("binary", "dsp", "hatari", "tos")}
    blobs = {name: path.read_bytes() for name, path in paths.items()}
    if not blobs["dsp"].strip():
        parser.error("DSP image is empty")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    (output / "RUN.TOS").write_bytes(blobs["binary"])
    # Diagnostic and release binaries deliberately load different names.
    for name in ("trex_dsp.lod", "TREX.LOD"):
        (output / name).write_bytes(blobs["dsp"])

    command = [str(paths["hatari"]), "--machine", "falcon", "--cpulevel", "3",
               "--cpuclock", "16", "--mmu", "true", "--patch-tos", "true",
               "--fast-boot", "true", "--tos", str(paths["tos"]),
               "--dsp", "emu", "--memsize", "4", "--ttram", "0",
               "--monitor", "rgb", "--frameskips", "4", "--sound", "off",
               "--benchmark", "--confirm-quit", "off", "--log-level", "fatal",
               "--alert-level", "fatal", "--harddrive", ".",
               "--auto", "C:\\RUN.TOS", "--run-vbls", "60000"]
    manifest = {
        "frames": args.frames, "command": command,
        "environment": {"SDL_VIDEODRIVER": "dummy"},
        "inputs": {name: {"path": str(paths[name]),
                          "sha256": hashlib.sha256(blob).hexdigest()}
                   for name, blob in blobs.items()},
    }
    manifest_path = output / "run.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    start = time.monotonic()
    with (output / "hatari.log").open("w") as log:
        process = subprocess.Popen(command, cwd=output,
                                   env={**os.environ, "SDL_VIDEODRIVER": "dummy"},
                                   stdout=log, stderr=log)
        try:
            while time.monotonic() - start < args.timeout:
                try:
                    data = (output / "render_stats.res").read_bytes()
                except FileNotFoundError:
                    data = b""
                # Fcreate/Fwrite/Fclose can briefly expose an empty file.
                if len(data) in (92, 96):
                    frames = struct.unpack_from(">I", data)[0]
                    if frames > args.frames:
                        raise RuntimeError("missed exact prefix: got %d, wanted %d"
                                           % (frames, args.frames))
                    if frames == args.frames:
                        # Preserve this snapshot before requesting shutdown;
                        # the live file may be rewritten by a later frame.
                        (output / "render_exact.res").write_bytes(data)
                        break
                if process.poll() is not None:
                    raise RuntimeError("Hatari exited before the target; see "
                                       + str(output / "hatari.log"))
                time.sleep(0.002)
            else:
                raise RuntimeError("timed out before the requested frame prefix")
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
    manifest["host_elapsed_seconds"] = round(time.monotonic() - start, 3)
    manifest["completed"] = True
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    report(output / "render_exact.res")
    framebuffer = output / "fb.res"
    if framebuffer.exists():
        print("  frame-100 SHA256: " + hashlib.sha256(framebuffer.read_bytes()).hexdigest())


if __name__ == "__main__":
    main()
